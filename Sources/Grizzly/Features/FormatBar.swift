import SwiftUI
import AppKit

/// Applies the formatting commands to the text view that is being edited.
enum FormatActions {
    /// The editable text view of the window: the focused one, or else the only one on screen.
    static func editor() -> NSTextView? {
        guard let window = NSApp.keyWindow else { return nil }
        if let focused = window.firstResponder as? NSTextView, focused.isEditable { return focused }
        func find(_ v: NSView) -> NSTextView? {
            if let t = v as? NSTextView, t.isEditable { return t }
            for s in v.subviews { if let t = find(s) { return t } }
            return nil
        }
        return window.contentView.flatMap(find)
    }

    static func perform(_ command: FormatCommand) {
        guard let view = editor() else { return }
        if case .table(let table) = command, table != .insert,
           !RichFormat.isInTable(text: view.string, caret: view.selectedRange().location) {
            AppState.shared.notify(L("Поставьте курсор в таблицу."), symbol: "tablecells")
            return
        }
        guard let edit = RichFormat.apply(command, text: view.string, selection: view.selectedRange()) else { return }
        view.window?.makeFirstResponder(view)
        apply(edit, to: view)
    }

    // MARK: Attachments

    private static func liveEditor() -> LiveTextView? {
        guard let view = editor() as? LiveTextView, view.isMarkdown, view.documentURL != nil else { return nil }
        return view
    }

    /// Asks for photos, videos, PDF files or any files and puts them into the document.
    static func attach(_ kind: AttachmentKind) {
        guard let view = liveEditor() else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        switch kind {
        case .image: panel.allowedContentTypes = [.image]
        case .video: panel.allowedContentTypes = [.movie]
        case .pdf: panel.allowedContentTypes = [.pdf]
        case .file: break
        }
        if panel.runModal() == .OK { attach(panel.urls, to: view) }
    }

    /// Copies the files next to the document (`<name>.assets`) and writes a line for each into the text.
    static func attach(_ urls: [URL], to view: LiveTextView) {
        guard let document = view.documentURL else { return }
        var blocks: [String] = []
        for url in urls {
            do {
                let path = try AttachmentStore.place(url, for: document)
                blocks.append(Attachments.markdown(title: url.deletingPathExtension().lastPathComponent, path: path,
                                                   kind: Attachments.kind(ofExtension: url.pathExtension)))
            } catch {
                AppState.shared.errorMessage = L("Не удалось добавить «%@».", url.lastPathComponent)
            }
        }
        insert(blocks, in: view)
    }

    static func attachImage(_ png: Data, to view: LiveTextView) {
        guard let document = view.documentURL else { return }
        do {
            let path = try AttachmentStore.place(imageData: png, ext: "png", for: document)
            insert([Attachments.markdown(title: L("Изображение"), path: path, kind: .image)], in: view)
        } catch {
            AppState.shared.errorMessage = L("Не удалось добавить изображение.")
        }
    }

    private static func insert(_ blocks: [String], in view: NSTextView) {
        guard !blocks.isEmpty else { return }
        view.window?.makeFirstResponder(view)
        apply(RichFormat.insertBlock(blocks.joined(separator: "\n\n"), text: view.string, selection: view.selectedRange()), to: view)
        AppState.shared.notify(L("Вложение добавлено."), symbol: "paperclip")
    }

    /// A link to a web page: the selected text becomes its title; with no selection the address's site name is used.
    static func insertWebLink() {
        guard let view = editor() else { return }
        guard let address = TextPrompt.ask(title: L("Ссылка на сайт"), message: L("Адрес страницы, например https://example.com"), confirm: L("Вставить")),
              let edit = RichFormat.linkEdit(("", address), text: view.string, selection: view.selectedRange()) else {
            return
        }
        view.window?.makeFirstResponder(view)
        apply(edit, to: view)
    }

    /// One undo step: the replacement goes through the text view, so the draft, undo and the tags all follow.
    static func apply(_ edit: TextEdit, to view: NSTextView) {
        guard view.shouldChangeText(in: edit.range, replacementString: edit.text) else { return }
        view.breakUndoCoalescing()
        view.textStorage?.replaceCharacters(in: edit.range, with: edit.text)
        view.didChangeText()
        view.setSelectedRange(edit.selection)
        view.breakUndoCoalescing()
    }
}

/// The formatting row above the editor: styles, bold / italic / underline / strikethrough, highlight, alignment,
/// lists, quote, divider and tables. Everything is written into the Markdown text.
struct FormatBar: View {
    var body: some View {
        HStack(spacing: 2) {
            Menu {
                item("Название", .paragraph(.title))
                item("Заголовок", .paragraph(.heading))
                item("Подзаголовок", .paragraph(.subheading))
                item("Основной текст", .paragraph(.body))
                item("Моноширинный", .paragraph(.monospaced))
            } label: { Image(systemName: "textformat.size") }
                .help("Стиль абзаца")
                .modifier(BarMenu())

            separator
            button("bold", .inline(.bold), "Жирный (⌘B)")
            button("italic", .inline(.italic), "Курсив (⌘I)")
            button("underline", .inline(.underline), "Подчёркнутый (⌘U)")
            button("strikethrough", .inline(.strike), "Зачёркнутый (⇧⌘X)")

            Menu {
                ForEach(Array(InlineMarkup.highlightNames.enumerated()), id: \.offset) { i, name in
                    Button { FormatActions.perform(.highlight(name)) } label: {
                        Label { Text(Self.colorTitle(name)) } icon: { Image(nsImage: Self.swatch(i)) }
                    }
                }
                Divider()
                item("Без выделения", .highlight(nil))
            } label: { Image(systemName: "highlighter") }
                .help("Цветной маркер")
                .modifier(BarMenu())

            Menu {
                item("По левому краю", .align(.left))
                item("По центру", .align(.center))
                item("По правому краю", .align(.right))
                item("По ширине", .align(.justify))
            } label: { Image(systemName: "text.alignleft") }
                .help("Выравнивание")
                .modifier(BarMenu())

            separator
            Menu {
                item("Маркированный список", .list(.bullet))
                item("Штриховой список", .list(.dash))
                item("Нумерованный список", .list(.numbered))
                item("Список задач", .list(.checklist))
            } label: { Image(systemName: "list.bullet") }
                .help("Списки")
                .modifier(BarMenu())
            button("text.quote", .quote, "Цитата (⌘')")
            button("minus", .rule, "Линия-разделитель")

            Menu {
                item("Вставить таблицу", .table(.insert))
                Divider()
                item("Добавить строку", .table(.addRow))
                item("Добавить столбец", .table(.addColumn))
                item("Удалить строку", .table(.deleteRow))
                item("Удалить столбец", .table(.deleteColumn))
                Divider()
                item("Строку вверх", .table(.moveRowUp))
                item("Строку вниз", .table(.moveRowDown))
                item("Столбец влево", .table(.moveColumnLeft))
                item("Столбец вправо", .table(.moveColumnRight))
                Divider()
                item("Преобразовать таблицу в текст", .table(.toText))
            } label: { Image(systemName: "tablecells") }
                .help("Таблица")
                .modifier(BarMenu())

            Menu {
                Button { FormatActions.attach(.image) } label: { Text("Фото…") }
                Button { FormatActions.attach(.video) } label: { Text("Видео…") }
                Button { FormatActions.attach(.pdf) } label: { Text("PDF…") }
                Button { FormatActions.attach(.file) } label: { Text("Файл…") }
                Divider()
                Button { FormatActions.insertWebLink() } label: { Text("Ссылка на сайт…") }
            } label: { Image(systemName: "paperclip") }
                .help("Вложения: фото, видео, PDF, файлы и ссылки")
                .modifier(BarMenu())
        }
    }

    private var separator: some View {
        Divider().frame(height: 16).padding(.horizontal, 4)
    }

    private func button(_ symbol: String, _ command: FormatCommand, _ help: LocalizedStringKey) -> some View {
        Button { FormatActions.perform(command) } label: { Image(systemName: symbol) }
            .buttonStyle(.hover)
            .help(help)
    }

    private func item(_ title: LocalizedStringKey, _ command: FormatCommand) -> some View {
        Button { FormatActions.perform(command) } label: { Text(title) }
    }

    static func colorTitle(_ name: String) -> LocalizedStringKey {
        switch name {
        case "violet": return "Фиолетовый"
        case "pink": return "Розовый"
        case "orange": return "Оранжевый"
        case "mint": return "Мятный"
        default: return "Синий"
        }
    }

    /// A small round swatch in the color of a highlight, for the menu.
    static func swatch(_ index: Int) -> NSImage {
        let image = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
            TextBuilder.highlightColor(index, dark: false).withAlphaComponent(1).setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
        image.isTemplate = false
        return image
    }
}

/// A menu button that looks like the other buttons of the bar.
private struct BarMenu: ViewModifier {
    func body(content: Content) -> some View {
        content
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .frame(minWidth: 30, minHeight: 28)
    }
}
