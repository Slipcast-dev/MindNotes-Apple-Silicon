import AppKit

/// The editor's text view: besides editing it takes clicks on the things User mode draws in the margin (folding arrows,
/// check boxes) and adds the formatting commands to the right-click menu.
final class LiveTextView: NSTextView {
    var live = false
    var isMarkdown = false
    /// The file being edited; attachments are placed next to it.
    var documentURL: URL?
    var onFold: ((String) -> Void)?
    var onTask: ((Int) -> Void)?
    /// The view became the one being typed in: its pane becomes the focused one.
    var onFocus: (() -> Void)?

    override func becomeFirstResponder() -> Bool {
        onFocus?()
        return super.becomeFirstResponder()
    }

    override func mouseDown(with event: NSEvent) {
        if live, handleMarginClick(event) { return }
        if live, handleAttachmentClick(event) { return }
        if live, event.modifierFlags.contains(.command), openLink(at: event) { return }
        super.mouseDown(with: event)
    }

    /// The attachment line under the pointer: its info and the range of the line.
    private func attachment(at event: NSEvent) -> (info: AttachmentInfo, line: NSRange)? {
        guard let storage = textStorage, storage.length > 0, let lm = layoutManager, let tc = textContainer else { return nil }
        let p = convert(event.locationInWindow, from: nil)
        let local = NSPoint(x: p.x - textContainerOrigin.x, y: p.y - textContainerOrigin.y)
        var fraction: CGFloat = 0
        let index = lm.characterIndex(for: local, in: tc, fractionOfDistanceBetweenInsertionPoints: &fraction)
        guard index < storage.length else { return nil }
        let rect = lm.lineFragmentRect(forGlyphAt: lm.glyphIndexForCharacter(at: index), effectiveRange: nil)
        guard local.y >= rect.minY, local.y <= rect.maxY, local.x >= -2, local.x <= AttachmentCache.maxWidth + 4 else { return nil }
        let line = (storage.string as NSString).lineRange(for: NSRange(location: index, length: 0))
        guard let info = storage.attribute(.grizzlyAttachment, at: line.location, effectiveRange: nil) as? AttachmentInfo else { return nil }
        return (info, line)
    }

    /// A click on a video, PDF or file card opens it; a photo opens on a double click (a single click places the caret).
    private func handleAttachmentClick(_ event: NSEvent) -> Bool {
        guard let (info, _) = attachment(at: event), info.exists, let url = info.url else { return false }
        if info.kind == .image && event.clickCount < 2 { return false }
        NSWorkspace.shared.open(url)
        return true
    }

    /// ⌘-click on a link to a web page opens it.
    private func openLink(at event: NSEvent) -> Bool {
        guard let storage = textStorage, storage.length > 0 else { return false }
        let index = characterIndexForInsertion(at: convert(event.locationInWindow, from: nil))
        for i in [index, index - 1] where i >= 0 && i < storage.length {
            if let address = storage.attribute(.grizzlyLink, at: i, effectiveRange: nil) as? String, let url = URL(string: address) {
                NSWorkspace.shared.open(url)
                return true
            }
        }
        return false
    }

    // MARK: Dropped and pasted attachments

    private static func fileURLs(_ pasteboard: NSPasteboard) -> [URL] {
        (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }

    /// Files dropped on a Markdown document are attached (a folder or a text file is opened as before).
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = Self.fileURLs(sender.draggingPasteboard)
        guard isMarkdown, !urls.isEmpty else { return super.performDragOperation(sender) }
        let point = convert(sender.draggingLocation, from: nil)
        setSelectedRange(NSRange(location: characterIndexForInsertion(at: point), length: 0))
        let supported = Set(FileType.allExtensions)
        let isDocument: (URL) -> Bool = { url in
            (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true || supported.contains(url.pathExtension.lowercased())
        }
        let documents = urls.filter(isDocument), files = urls.filter { !isDocument($0) }
        if !documents.isEmpty { AppState.shared.open(urls: documents) }
        if !files.isEmpty { FormatActions.attach(files, to: self) }
        return true
    }

    override func paste(_ sender: Any?) {
        let pb = NSPasteboard.general
        guard isMarkdown else { super.paste(sender); return }
        let files = Self.fileURLs(pb)
        if !files.isEmpty {
            FormatActions.attach(files, to: self)
        } else if pb.string(forType: .string) == nil, let data = pb.data(forType: .png) ?? pb.data(forType: .tiff),
                  let png = NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:]) {
            FormatActions.attachImage(png, to: self)
        } else if selectedRange().length > 0, let text = pb.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  Attachments.webLink(title: "", address: text) != nil, text.lowercased().hasPrefix("http") {
            // A web address pasted over selected text makes the text a link.
            if let edit = RichFormat.linkEdit(("", text), text: string, selection: selectedRange()) { FormatActions.apply(edit, to: self) }
        } else {
            super.paste(sender)
        }
    }

    /// A click on a folding arrow (left of the text) or on the circle of a check list item.
    private func handleMarginClick(_ event: NSEvent) -> Bool {
        guard let storage = textStorage, storage.length > 0, let lm = layoutManager, let tc = textContainer else { return false }
        let p = convert(event.locationInWindow, from: nil)
        let local = NSPoint(x: p.x - textContainerOrigin.x, y: p.y - textContainerOrigin.y)
        guard local.x > -30, local.x < 30 else { return false }
        var fraction: CGFloat = 0
        let index = lm.characterIndex(for: NSPoint(x: max(local.x, 1), y: local.y), in: tc, fractionOfDistanceBetweenInsertionPoints: &fraction)
        guard index < storage.length else { return false }
        let rect = lm.lineFragmentRect(forGlyphAt: lm.glyphIndexForCharacter(at: index), effectiveRange: nil)
        guard local.y >= rect.minY, local.y <= rect.maxY else { return false }
        let lineStart = (storage.string as NSString).lineRange(for: NSRange(location: index, length: 0)).location
        if local.x < 0, let key = storage.attribute(.grizzlyFold, at: lineStart, effectiveRange: nil) as? String {
            onFold?(key)
            return true
        }
        if local.x >= 0, local.x < 28, let box = storage.attribute(.grizzlyTaskBox, at: lineStart, effectiveRange: nil) as? Int {
            onTask?(box)
            return true
        }
        return false
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        if live, let (info, line) = attachment(at: event) {
            // The attachment under the pointer comes first in the menu.
            var items: [NSMenuItem] = []
            if info.exists, let url = info.url {
                items.append(ClosureItem(L("Открыть вложение")) { NSWorkspace.shared.open(url) })
                items.append(ClosureItem(L("Показать в Finder")) { NSWorkspace.shared.activateFileViewerSelecting([url]) })
            }
            items.append(ClosureItem(L("Удалить вложение")) { [weak self] in
                guard let self else { return }
                FormatActions.apply(TextEdit(range: line, text: "", selection: NSRange(location: line.location, length: 0)), to: self)
            })
            for (i, item) in items.enumerated() { menu.insertItem(item, at: i) }
            menu.insertItem(.separator(), at: items.count)
        }
        FormatMenu.append(to: menu, markdown: isMarkdown)
        return menu
    }
}

/// A menu item that runs a closure.
final class ClosureItem: NSMenuItem {
    private var handler: (() -> Void)?

    init(_ title: String, checked: Bool = false, image: NSImage? = nil, handler: @escaping () -> Void) {
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
        self.handler = handler
        self.state = checked ? .on : .off
        self.image = image
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func fire() { handler?() }
}

/// The right-click menu of the editor: modes, every formatting command, tables, font and size, settings.
enum FormatMenu {
    private static func sub(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let menu = NSMenu(title: title)
        items.forEach(menu.addItem)
        item.submenu = menu
        return item
    }

    private static func command(_ title: String, _ c: FormatCommand) -> NSMenuItem {
        ClosureItem(title) { FormatActions.perform(c) }
    }

    static func append(to menu: NSMenu, markdown: Bool) {
        let state = AppState.shared, prefs = Preferences.shared
        menu.addItem(.separator())
        menu.addItem(sub(L("Режим"), [
            ClosureItem(L("Пользователь"), checked: state.mode == .user) { state.mode = .user },
            ClosureItem(L("Разработчик"), checked: state.mode == .developer) { state.mode = .developer },
        ]))

        if markdown {
            menu.addItem(sub(L("Стиль абзаца"), [
                command(L("Название"), .paragraph(.title)),
                command(L("Заголовок"), .paragraph(.heading)),
                command(L("Подзаголовок"), .paragraph(.subheading)),
                command(L("Основной текст"), .paragraph(.body)),
                command(L("Моноширинный"), .paragraph(.monospaced)),
            ]))
            menu.addItem(sub(L("Начертание"), [
                command(L("Жирный"), .inline(.bold)),
                command(L("Курсив"), .inline(.italic)),
                command(L("Подчёркнутый"), .inline(.underline)),
                command(L("Зачёркнутый"), .inline(.strike)),
            ]))
            var colors: [NSMenuItem] = InlineMarkup.highlightNames.enumerated().map { i, name in
                ClosureItem(NSLocalizedString(Self.colorKey(name), comment: ""), image: FormatBar.swatch(i)) { FormatActions.perform(.highlight(name)) }
            }
            colors.append(.separator())
            colors.append(command(L("Без выделения"), .highlight(nil)))
            menu.addItem(sub(L("Цветной маркер"), colors))
            menu.addItem(sub(L("Выравнивание"), [
                command(L("По левому краю"), .align(.left)),
                command(L("По центру"), .align(.center)),
                command(L("По правому краю"), .align(.right)),
                command(L("По ширине"), .align(.justify)),
            ]))
            menu.addItem(sub(L("Списки"), [
                command(L("Маркированный список"), .list(.bullet)),
                command(L("Штриховой список"), .list(.dash)),
                command(L("Нумерованный список"), .list(.numbered)),
                command(L("Список задач"), .list(.checklist)),
            ]))
            menu.addItem(sub(L("Вставить"), [
                ClosureItem(L("Фото…")) { FormatActions.attach(.image) },
                ClosureItem(L("Видео…")) { FormatActions.attach(.video) },
                ClosureItem(L("PDF…")) { FormatActions.attach(.pdf) },
                ClosureItem(L("Файл…")) { FormatActions.attach(.file) },
                ClosureItem(L("Ссылка на сайт…")) { FormatActions.insertWebLink() },
            ]))
            menu.addItem(command(L("Цитата"), .quote))
            menu.addItem(command(L("Линия-разделитель"), .rule))
            menu.addItem(sub(L("Таблица"), [
                command(L("Вставить таблицу"), .table(.insert)), .separator(),
                command(L("Добавить строку"), .table(.addRow)),
                command(L("Добавить столбец"), .table(.addColumn)),
                command(L("Удалить строку"), .table(.deleteRow)),
                command(L("Удалить столбец"), .table(.deleteColumn)), .separator(),
                command(L("Строку вверх"), .table(.moveRowUp)),
                command(L("Строку вниз"), .table(.moveRowDown)),
                command(L("Столбец влево"), .table(.moveColumnLeft)),
                command(L("Столбец вправо"), .table(.moveColumnRight)), .separator(),
                command(L("Преобразовать таблицу в текст"), .table(.toText)),
            ]))
        }

        menu.addItem(.separator())
        menu.addItem(sub(L("Шрифт"), Preferences.fonts.map { name in
            ClosureItem(name == Preferences.systemFont ? L("Системный") : name, checked: prefs.fontName == name) { prefs.fontName = name }
        }))
        var sizes: [NSMenuItem] = [
            ClosureItem(L("Крупнее")) { prefs.resizeFont(by: 1) },
            ClosureItem(L("Мельче")) { prefs.resizeFont(by: -1) },
            .separator(),
        ]
        sizes += [12, 14, 15, 16, 18, 20, 24].map { size in
            ClosureItem("\(size) pt", checked: Int(prefs.fontSize) == size) { prefs.fontSize = Double(size) }
        }
        menu.addItem(sub(L("Размер текста"), sizes))
        menu.addItem(ClosureItem(L("Эмодзи и символы")) { NSApp.orderFrontCharacterPalette(nil) })
        menu.addItem(ClosureItem(L("Настройки…")) { SettingsOpener.show() })
    }

    private static func colorKey(_ name: String) -> String {
        switch name {
        case "violet": return "Фиолетовый"
        case "pink": return "Розовый"
        case "orange": return "Оранжевый"
        case "mint": return "Мятный"
        default: return "Синий"
        }
    }
}
