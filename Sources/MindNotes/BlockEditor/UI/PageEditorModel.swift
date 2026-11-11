import AppKit
import SwiftUI

/// Открытая страница для интерфейса: контроллер живёт столько же, сколько сессия редактора.
@MainActor
final class PageEditorModel: ObservableObject {
    private let session: EditorSession
    let controller: BlockEditorController
    @Published private(set) var contentHeight: CGFloat = 60
    /// Открытая в редакторе таблица.
    @Published var editingTable: EditingTable?
    /// Открытое встроенное представление.
    @Published var editingEmbed: Block?
    private let panels: EditorPanels
    /// Панели «/» и форматирования у полей колонок (ADR-0013).
    private var columnPanels: [EditorPanels] = []

    var pageID: UUID { session.pageID }

    init(session: EditorSession, style: BlockTextStyle, onError: @escaping (String) -> Void) {
        self.session = session
        controller = BlockEditorController(session: session, style: style)
        panels = EditorPanels(controller: controller)
        controller.onError = onError
        controller.configureColumnEditor = { [weak self] editor in
            // Свои панели у поля колонки; набор настроек уже унаследован, панели переопределяют свои пункты.
            self?.columnPanels.append(EditorPanels(controller: editor))
        }
        controller.onHeightChange = { [weak self] in self?.contentHeight = $0 }
        controller.updateHeight(force: true)
        controller.onEditTable = { [weak self] block in
            guard AtomData.isEditableTable(block) else {
                onError(L("Эта таблица создана более новой версией и здесь не редактируется."))
                return
            }
            self?.editingTable = EditingTable(id: block.id, rows: AtomData.rows(of: block), extra: block.atomJSON)
        }
        controller.onOpenEmbed = { [weak self] block in
            guard block.contentVersion <= 1, AtomData.viewPage(of: block) != nil else {
                onError(L("Это представление создано более новой версией и здесь не открывается."))
                return
            }
            self?.editingEmbed = block
        }
    }

    func insert(_ type: BlockType) {
        controller.run(type.isAtom ? .insert(type) : .turnInto(type))
        controller.textView.window?.makeFirstResponder(controller.textView)
    }

    func emergencyText(title: String) -> String { session.emergencyText(title: title) }

    func closePanels() {
        panels.close()
        columnPanels.forEach { $0.close() }
    }
}

struct EditingTable: Identifiable {
    let id: UUID
    var rows: [[String]]
    /// Все поля блока: неизвестные сохраняются при записи.
    var extra: [String: JSONValue]
}

/// Редактор простой таблицы: строки и столбцы, первая строка — заголовок.
struct TableEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State var rows: [[String]]
    let save: ([[String]]) -> Void

    private var columns: Int { rows.map(\.count).max() ?? 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Таблица").font(Tokens.titleFont(26))
            ScrollView([.vertical, .horizontal]) {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(rows.indices, id: \.self) { r in
                        HStack(spacing: 4) {
                            ForEach(0..<columns, id: \.self) { c in
                                TextField("", text: cell(r, c))
                                    .textFieldStyle(.roundedBorder)
                                    .font(.system(size: 13, weight: r == 0 ? .semibold : .regular))
                                    .frame(width: 150)
                            }
                            Button { rows.remove(at: r) } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.plain)
                                .disabled(rows.count <= 1)
                                .help(L("Удалить строку"))
                        }
                    }
                    HStack(spacing: 4) {
                        ForEach(0..<columns, id: \.self) { c in
                            Button { rows.indices.forEach { if rows[$0].count > c { rows[$0].remove(at: c) } } } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.plain)
                                .disabled(columns <= 1)
                                .frame(width: 150)
                                .help(L("Удалить столбец"))
                        }
                    }
                }
            }
            HStack {
                Button(L("Добавить строку")) { rows.append(Array(repeating: "", count: columns)) }.buttonStyle(NotesButtonStyle())
                Button(L("Добавить столбец")) { rows.indices.forEach { rows[$0].append("") } }.buttonStyle(NotesButtonStyle())
                Spacer()
                Button(L("Отмена")) { dismiss() }.buttonStyle(NotesButtonStyle()).keyboardShortcut(.cancelAction)
                Button(L("Готово")) {
                    save(rows)
                    dismiss()
                }
                .buttonStyle(NotesButtonStyle(kind: .primary))
            }
        }
        .padding(23)
        .frame(width: 720, height: 460)
        .background(Tokens.paper)
    }

    private func cell(_ r: Int, _ c: Int) -> Binding<String> {
        Binding(get: { rows.indices.contains(r) && rows[r].indices.contains(c) ? rows[r][c] : "" },
                set: { value in
                    guard rows.indices.contains(r) else { return }
                    while rows[r].count <= c { rows[r].append("") }
                    rows[r][c] = value
                })
    }
}

/// Единый текстовый вид страницы.
/// Пустое место под текстом страницы.
struct EditorTail: NSViewRepresentable {
    let controller: BlockEditorController

    func makeNSView(context: Context) -> EditorTailView {
        let view = EditorTailView(frame: .zero)
        view.controller = controller
        return view
    }

    func updateNSView(_ view: EditorTailView, context: Context) { view.controller = controller }
}

struct NativeBlockEditor: NSViewRepresentable {
    @ObservedObject var editor: PageEditorModel

    func makeNSView(context: Context) -> BlockTextView { editor.controller.textView }

    func updateNSView(_ view: BlockTextView, context: Context) {}
}

/// Плавающие панели редактора: меню «/» и панель форматирования при выделении.
@MainActor
final class EditorPanels {
    private let controller: BlockEditorController
    private var slashPanel: NSPanel?
    private var toolbarPanel: NSPanel?

    init(controller: BlockEditorController) {
        self.controller = controller
        controller.onSlashChange = { [weak self] state, items, rect in self?.showSlash(state, items, rect) }
        controller.onSelectionRect = { [weak self] rect in self?.showToolbar(rect) }
        controller.requestLink = { current, done in
            let alert = NSAlert()
            alert.messageText = L("Ссылка")
            alert.informativeText = L("Пустой адрес убирает ссылку.")
            let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
            field.stringValue = current ?? ""
            field.placeholderString = "https://"
            alert.accessoryView = field
            alert.window.initialFirstResponder = field
            alert.addButton(withTitle: L("Готово"))
            alert.addButton(withTitle: L("Отмена"))
            if alert.runModal() == .alertFirstButtonReturn { done(field.stringValue) }
        }
        controller.chooseLinkKind = { [weak controller] _ in
            // Меню у курсора, как в Notion: «Ссылка», «Закладка», «Встроить»; Esc — вставить обычным текстом.
            guard let view = controller?.textView else { return nil }
            final class Pick: NSObject {
                var kind: BlockType?
                @objc func choose(_ sender: NSMenuItem) { kind = sender.representedObject as? BlockType }
            }
            let pick = Pick()
            let menu = NSMenu()
            for (title, kind) in [(L("Ссылка"), BlockType.paragraph), (L("Закладка"), .bookmark), (L("Встроить"), .embed)] {
                let item = NSMenuItem(title: title, action: #selector(Pick.choose(_:)), keyEquivalent: "")
                item.target = pick
                item.representedObject = kind
                menu.addItem(item)
            }
            var actual = NSRange()
            let screen = view.firstRect(forCharacterRange: view.selectedRange(), actualRange: &actual)
            let inWindow = view.window?.convertFromScreen(screen) ?? .zero
            let point = view.convert(NSPoint(x: inWindow.minX, y: inWindow.minY), from: nil)
            menu.popUp(positioning: nil, at: point, in: view)
            return pick.kind
        }
        controller.requestMentionDate = { done in
            let alert = NSAlert()
            alert.messageText = L("Дата или напоминание")
            let picker = NSDatePicker(frame: NSRect(x: 0, y: 52, width: 260, height: 24))
            picker.datePickerStyle = .textFieldAndStepper
            picker.datePickerElements = [.yearMonthDay, .hourMinute]
            picker.dateValue = Date()
            let withTime = NSButton(checkboxWithTitle: L("Указать время"), target: nil, action: nil)
            withTime.frame = NSRect(x: 0, y: 26, width: 260, height: 20)
            let remind = NSButton(checkboxWithTitle: L("Напомнить в это время"), target: nil, action: nil)
            remind.frame = NSRect(x: 0, y: 0, width: 260, height: 20)
            let box = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 78))
            [picker, withTime, remind].forEach(box.addSubview)
            alert.accessoryView = box
            alert.addButton(withTitle: L("Вставить"))
            alert.addButton(withTitle: L("Отмена"))
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            let c = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: picker.dateValue)
            let day = String(format: "%04d-%02d-%02d", c.year ?? 1, c.month ?? 1, c.day ?? 1)
            let moment = day + String(format: "T%02d:%02d", c.hour ?? 0, c.minute ?? 0)
            // Напоминание всегда со временем; без него дата — просто день.
            let timed = withTime.state == .on || remind.state == .on
            done(timed ? moment : day, remind.state == .on ? moment : nil)
        }
    }

    /// Панель держит контроллер, поэтому при уходе со страницы её нужно отсоединить от окна.
    func close() {
        for panel in [slashPanel, toolbarPanel].compactMap({ $0 }) {
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
            panel.contentView = nil
        }
        slashPanel = nil
        toolbarPanel = nil
    }

    private func panel(_ size: NSSize) -> NSPanel {
        let p = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        p.isFloatingPanel = true
        p.level = .popUpMenu
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        return p
    }

    private func showSlash(_ state: BlockEditorController.SlashState?, _ items: [EditorAction.Item], _ rect: NSRect) {
        guard let state else {
            slashPanel?.orderOut(nil)
            return
        }
        let height = min(CGFloat(items.count) * 30 + 12, 320)
        let size = NSSize(width: 260, height: height)
        let view = SlashMenuView(items: items, selected: state.selected) { [weak self] i in self?.controller.chooseSlash(i) }
        let p = slashPanel ?? panel(size)
        p.contentView = NSHostingView(rootView: view)
        p.setContentSize(size)
        p.setFrameOrigin(NSPoint(x: rect.minX, y: rect.minY - height - 4))
        controller.textView.window?.addChildWindow(p, ordered: .above)
        slashPanel = p
    }

    private func showToolbar(_ rect: NSRect?) {
        guard let rect, controller.slash == nil, NSEvent.pressedMouseButtons == 0 else {
            toolbarPanel?.orderOut(nil)
            return
        }
        let size = NSSize(width: 376, height: 40)
        let view = FormatToolbarView(controller: controller)
        let p = toolbarPanel ?? panel(size)
        p.contentView = NSHostingView(rootView: view)
        p.setContentSize(size)
        p.setFrameOrigin(NSPoint(x: rect.minX, y: rect.maxY + 6))
        controller.textView.window?.addChildWindow(p, ordered: .above)
        toolbarPanel = p
    }
}

struct SlashMenuView: View {
    let items: [EditorAction.Item]
    let selected: Int
    let choose: (Int) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                        Button { choose(i) } label: {
                            Text(item.title)
                                .font(.system(size: 13))
                                .foregroundColor(Tokens.ink)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 10)
                                .frame(height: 30)
                                .background(RoundedRectangle(cornerRadius: 6).fill(i == selected ? Tokens.soft : .clear))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .id(i)
                    }
                }
                .padding(6)
            }
            .onAppear { proxy.scrollTo(selected) }
            .onChange(of: selected) { _, new in proxy.scrollTo(new) }
        }
        .background(RoundedRectangle(cornerRadius: 10).fill(Tokens.card))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Tokens.line))
    }
}

/// Панель при выделении: те же действия, что в меню.
@MainActor
struct FormatToolbarView: View {
    let controller: BlockEditorController

    var body: some View {
        HStack(spacing: 2) {
            Menu(L("Тип")) {
                ForEach(Array(EditorAction.blockTypes.enumerated()), id: \.offset) { _, item in
                    Button(item.title) { controller.run(item.action) }
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            mark("bold", "b", L("Жирный"))
            mark("italic", "i", L("Курсив"))
            mark("underline", "u", L("Подчёркнутый"))
            mark("strikethrough", "s", L("Зачёркнутый"))
            mark("chevron.left.forwardslash.chevron.right", "code", L("Встроенный код"))
            icon("link", L("Ссылка…")) { controller.run(.link) }
            Menu {
                Section(L("Цвет текста")) {
                    ForEach(Array(EditorAction.colors.enumerated()), id: \.offset) { _, item in
                        Button(item.title) { controller.run(item.action) }
                    }
                }
                Section(L("Цветной маркер")) {
                    ForEach(Array(EditorAction.highlights.enumerated()), id: \.offset) { _, item in
                        Button(item.title) { controller.run(item.action) }
                    }
                }
            } label: { Image(systemName: "paintpalette") }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.horizontal, 8)
        .frame(height: 40)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 10).fill(Tokens.card))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Tokens.line))
    }

    private func mark(_ symbol: String, _ mark: String, _ help: String) -> some View {
        icon(symbol, help) { controller.run(.mark(mark)) }
    }

    private func icon(_ symbol: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .foregroundColor(Tokens.ink)
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(Text(help))
    }
}

/// Меню «Формат» в строке меню: тот же список действий, что в правом клике.
struct FormatCommands: Commands {
    private func run(_ action: EditorAction) {
        Task { @MainActor in (NSApp.keyWindow?.firstResponder as? BlockTextView)?.controller?.run(action) }
    }

    @ViewBuilder private func buttons(_ items: [EditorAction.Item]) -> some View {
        ForEach(Array(items.enumerated()), id: \.offset) { _, item in
            if item.key.isEmpty {
                Button(item.title) { run(item.action) }
            } else {
                Button(item.title) { run(item.action) }
                    .keyboardShortcut(KeyEquivalent(Character(item.key)), modifiers: Self.modifiers(item.modifiers))
            }
        }
    }

    private static func modifiers(_ flags: NSEvent.ModifierFlags) -> EventModifiers {
        var out: EventModifiers = []
        if flags.contains(.command) { out.insert(.command) }
        if flags.contains(.shift) { out.insert(.shift) }
        if flags.contains(.option) { out.insert(.option) }
        return out
    }

    var body: some Commands {
        CommandMenu(L("Формат")) {
            Menu(L("Преобразовать")) { buttons(EditorAction.blockTypes) }
            Divider()
            buttons(EditorAction.marks)
            Divider()
            Menu(L("Цвет текста")) { buttons(EditorAction.colors) }
            Menu(L("Цветной маркер")) { buttons(EditorAction.highlights) }
            Divider()
            Menu(L("Вставить блок")) { buttons(EditorAction.inserts) }
            Divider()
            buttons(EditorAction.blockActions)
        }
    }
}
