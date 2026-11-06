import AppKit
import SwiftUI

struct BlockKind {
    let type: BlockType
    let title: String
    static var all: [BlockKind] {
        [BlockKind(type: .paragraph, title: L("Текст")), BlockKind(type: .heading1, title: L("Заголовок 1")),
         BlockKind(type: .heading2, title: L("Заголовок 2")), BlockKind(type: .heading3, title: L("Заголовок 3")),
         BlockKind(type: .task, title: L("Задача"))]
    }
}

/// Модель открытой страницы для интерфейса. Правки идут только через команды.
@MainActor
final class PageEditorModel: ObservableObject {
    private let session: EditorSession
    private let onError: (String) -> Void
    @Published private(set) var blocks: [Block]
    /// Куда поставить курсор после структурной правки.
    @Published var focus: BlockSelection?

    var pageID: UUID { session.pageID }

    init(session: EditorSession, onError: @escaping (String) -> Void) {
        self.session = session
        self.onError = onError
        blocks = session.document.blocks
        session.onChange = { [weak self] in
            guard let self else { return }
            self.blocks = self.session.document.blocks
        }
    }

    private func run(_ command: EditCommand, moveFocus: Bool = true) {
        do {
            let result = try session.perform(command)
            if moveFocus, let s = result.selection { focus = s }
        } catch {
            onError((error as? LocalizedError)?.errorDescription ?? "\(error)")
        }
    }

    func setText(_ id: UUID, _ text: String) { run(.setPlainText(block: id, text: text), moveFocus: false) }
    func split(_ id: UUID, at offset: Int) { run(.splitBlock(BlockPoint(blockID: id, offset: offset))) }
    func merge(_ id: UUID) {
        guard let i = blocks.firstIndex(where: { $0.id == id }), i > 0 else { return }
        run(.mergeBackward(block: id))
    }
    func setChecked(_ id: UUID, _ value: Bool) { run(.setChecked(block: id, checked: value), moveFocus: false) }
    func changeType(_ id: UUID, _ type: BlockType) { run(.changeType(block: id, type: type), moveFocus: false) }
    func delete(_ id: UUID) { run(.deleteBlock(id)) }
    func insert(_ type: BlockType) { run(.insertBlock(after: focusedBlockAnchor, type: type)) }

    private var focusedBlockAnchor: UUID? { focus?.focus.blockID ?? blocks.last?.id }

    func noteFocus(_ id: UUID, offset: Int) { focus = BlockSelection(block: id, offset: offset) }

    func moveFocus(from id: UUID, by delta: Int) {
        guard let i = blocks.firstIndex(where: { $0.id == id }) else { return }
        let target = i + delta
        guard blocks.indices.contains(target) else { return }
        focus = BlockSelection(block: blocks[target].id, offset: delta < 0 ? blocks[target].plainText.utf16.count : 0)
    }

    func undo() {
        session.undoStep()
        if let s = session.selection { focus = s }
    }

    func redo() {
        session.redoStep()
        if let s = session.selection { focus = s }
    }

    var canUndo: Bool { session.canUndo }
    var canRedo: Bool { session.canRedo }

    func emergencyText(title: String) -> String { session.emergencyText(title: title) }
}

/// Временный редактор M2: блок — отдельное поле, выделения через блоки нет.
/// Настоящий путь данных; в M3 заменяется только этот каталог.
struct InterimPageEditor: View {
    @ObservedObject var editor: PageEditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(editor.blocks) { block in
                BlockRow(block: block, editor: editor)
            }
        }
    }
}

struct BlockRow: View {
    let block: Block
    @ObservedObject var editor: PageEditorModel

    var body: some View {
        if block.isEditable {
            HStack(alignment: .top, spacing: 8) {
                if block.type == .task {
                    Toggle("", isOn: Binding(get: { block.content?.checked == true }, set: { editor.setChecked(block.id, $0) }))
                        .toggleStyle(.checkbox)
                        .labelsHidden()
                        .accessibilityLabel(Text("Задача выполнена"))
                }
                BlockTextField(block: block, editor: editor)
            }
            .padding(.vertical, 5)
            .contextMenu {
                Menu("Преобразовать") {
                    ForEach(BlockKind.all, id: \.type) { kind in
                        Button(kind.title) { editor.changeType(block.id, kind.type) }
                    }
                }
                Button("Удалить блок") { editor.delete(block.id) }
            }
        } else {
            // Неизвестный тип показывается, не меняется и не теряется (FR-05).
            HStack(spacing: 8) {
                Image(systemName: "questionmark.square.dashed")
                VStack(alignment: .leading, spacing: 2) {
                    Text("Блок не поддерживается этой версией").font(.system(size: 13, weight: .semibold))
                    if !block.plainText.isEmpty { Text(block.plainText).font(.system(size: 13)) }
                }
            }
            .foregroundColor(Tokens.muted)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 9).stroke(Tokens.line))
        }
    }
}

/// Многострочное поле блока на NSTextView: системный ввод, IME и раскладки работают штатно.
struct BlockTextField: NSViewRepresentable {
    let block: Block
    @ObservedObject var editor: PageEditorModel

    /// Интерлиньяж основного текста по макету: 1,6.
    private var textAttributes: [NSAttributedString.Key: Any] {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = block.type == .paragraph || block.type == .task ? 5 : 2
        return [.font: font, .foregroundColor: Tokens.inkNS, .paragraphStyle: style]
    }

    private var font: NSFont {
        switch block.type {
        case .heading1: return .systemFont(ofSize: 26, weight: .bold)
        case .heading2: return .systemFont(ofSize: 21, weight: .semibold)
        case .heading3: return .systemFont(ofSize: 17, weight: .semibold)
        default: return .systemFont(ofSize: 14)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> BlockNSTextView {
        let view = BlockNSTextView()
        view.delegate = context.coordinator
        view.owner = context.coordinator
        view.drawsBackground = false
        view.isRichText = false
        view.allowsUndo = false
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.isVerticallyResizable = false
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.textContainer?.containerSize = NSSize(width: 100, height: 10_000_000)
        view.setAccessibilityLabel(L("Текст блока"))
        return view
    }

    func updateNSView(_ view: BlockNSTextView, context: Context) {
        context.coordinator.parent = self
        let attributes = textAttributes
        view.typingAttributes = attributes
        view.insertionPointColor = Tokens.inkNS
        // Модель обновляет поле только при внешней правке (отмена, разделение): обычный ввод текст не заменяет.
        if view.string != block.plainText, !view.hasMarkedText() {
            view.string = block.plainText
            view.invalidateIntrinsicContentSize()
        }
        // Оформление зависит от типа блока; при составном вводе атрибуты не трогаем.
        if !view.hasMarkedText(), let storage = view.textStorage, storage.length > 0 {
            storage.setAttributes(attributes, range: NSRange(location: 0, length: storage.length))
        }
        if let focus = editor.focus, focus.focus.blockID == block.id, context.coordinator.appliedFocus != focus {
            context.coordinator.appliedFocus = focus
            DispatchQueue.main.async {
                view.window?.makeFirstResponder(view)
                let length = (view.string as NSString).length
                view.setSelectedRange(NSRange(location: min(focus.focus.offset, length), length: 0))
            }
        }
    }

    /// Высота считается отдельно: реальный текстовый контейнер менять при измерении нельзя.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: BlockNSTextView, context: Context) -> CGSize? {
        let width = proposal.width ?? Tokens.editorWidth
        var text = nsView.hasMarkedText() ? nsView.string : block.plainText
        if text.isEmpty || text.hasSuffix("\n") { text += " " }
        let rect = (text as NSString).boundingRect(with: NSSize(width: width, height: 10_000_000),
                                                   options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: textAttributes)
        return CGSize(width: width, height: ceil(rect.height))
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: BlockTextField
        var appliedFocus: BlockSelection?

        init(_ parent: BlockTextField) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView, !view.hasMarkedText() else { return }
            parent.editor.setText(parent.block.id, view.string)
            view.invalidateIntrinsicContentSize()
        }

        func textDidBeginEditing(_ notification: Notification) { noteFocus(notification) }

        func textViewDidChangeSelection(_ notification: Notification) { noteFocus(notification) }

        private func noteFocus(_ notification: Notification) {
            guard let view = notification.object as? NSTextView, view.window?.firstResponder === view else { return }
            let s = BlockSelection(block: parent.block.id, offset: view.selectedRange().location)
            appliedFocus = s
            parent.editor.noteFocus(parent.block.id, offset: s.focus.offset)
        }

        func textView(_ view: NSTextView, doCommandBy selector: Selector) -> Bool {
            let id = parent.block.id
            let range = view.selectedRange()
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                // Текст ещё мог не попасть в модель, если шёл составной ввод.
                parent.editor.setText(id, view.string)
                parent.editor.split(id, at: range.location)
                return true
            case #selector(NSResponder.insertLineBreak(_:)):
                view.insertText("\n", replacementRange: range)
                return true
            case #selector(NSResponder.deleteBackward(_:)):
                if range.location == 0 && range.length == 0 {
                    parent.editor.merge(id)
                    return true
                }
                return false
            case #selector(NSResponder.moveUp(_:)):
                if range.location == 0 || isOnFirstLine(view, range) {
                    parent.editor.moveFocus(from: id, by: -1)
                    return true
                }
                return false
            case #selector(NSResponder.moveDown(_:)):
                if range.location == (view.string as NSString).length || isOnLastLine(view, range) {
                    parent.editor.moveFocus(from: id, by: 1)
                    return true
                }
                return false
            default:
                return false
            }
        }

        private func lineRect(_ view: NSTextView, _ location: Int) -> NSRect {
            guard let manager = view.layoutManager, manager.numberOfGlyphs > 0 else { return .zero }
            let glyph = manager.glyphIndexForCharacter(at: min(location, max(0, (view.string as NSString).length - 1)))
            return manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        }

        private func isOnFirstLine(_ view: NSTextView, _ r: NSRange) -> Bool {
            lineRect(view, r.location).minY <= 0.5
        }

        private func isOnLastLine(_ view: NSTextView, _ r: NSRange) -> Bool {
            guard let manager = view.layoutManager else { return true }
            return lineRect(view, r.location).maxY >= manager.usedRect(for: view.textContainer!).maxY - 0.5
        }
    }
}

/// Отмена текста идёт через стек команд, а не через отмену NSTextView.
final class BlockNSTextView: NSTextView {
    weak var owner: BlockTextField.Coordinator?

    override var intrinsicContentSize: NSSize {
        guard let container = textContainer, let manager = layoutManager else { return super.intrinsicContentSize }
        manager.ensureLayout(for: container)
        return NSSize(width: NSView.noIntrinsicMetric, height: ceil(manager.usedRect(for: container).height))
    }

    @MainActor @objc func undo(_ sender: Any?) { owner?.parent.editor.undo() }
    @MainActor @objc func redo(_ sender: Any?) { owner?.parent.editor.redo() }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(undo(_:)) { return MainActor.assumeIsolated_compat_bool { self.owner?.parent.editor.canUndo ?? false } }
        if item.action == #selector(redo(_:)) { return MainActor.assumeIsolated_compat_bool { self.owner?.parent.editor.canRedo ?? false } }
        return super.validateUserInterfaceItem(item)
    }
}

extension MainActor {
    /// Проверка пунктов меню всегда приходит на главном потоке; `assumeIsolated` доступен только с Swift 5.9.
    static func assumeIsolated_compat_bool(_ body: @MainActor () -> Bool) -> Bool {
        withoutActuallyEscaping(body) { b in
            unsafeBitCast(b, to: (() -> Bool).self)()
        }
    }
}
