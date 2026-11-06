import AppKit

/// Связывает единый NSTextView с документом страницы.
///
/// Текст вида — блоки через "\n". Правка внутри блока идёт штатным путём NSTextView, поэтому IME, раскладки и
/// emoji работают системно; модель догоняет вид. Всё, что меняет структуру, выполняется командой, и в вид
/// вносится только изменившийся участок: выделение и прокрутка не сбрасываются.
@MainActor
final class BlockEditorController: NSObject, NSTextViewDelegate {
    struct Span {
        var id: UUID
        var location: Int
        var length: Int
        var end: Int { location + length }
    }

    static let pasteboardType = NSPasteboard.PasteboardType("local.personal.GrizzlyNotes.blocks")

    let session: EditorSession
    let textView: BlockTextView
    var style: BlockTextStyle
    /// Высота содержимого изменилась.
    var onHeightChange: ((CGFloat) -> Void)?
    var onError: ((String) -> Void)?

    private(set) var spans: [Span] = []
    private var applying = false
    private var editingIndex: Int?
    /// Блок правки между shouldChange и textDidChange. AppKit сообщает о новом выделении раньше, чем о новом
    /// тексте: в этот момент разбиение устарело, и определять блок по выделению нельзя.
    private var pendingIndex: Int?
    private var lastHeight: CGFloat = 0

    init(session: EditorSession, style: BlockTextStyle = BlockTextStyle()) {
        self.session = session
        self.style = style
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 600, height: 10_000_000))
        container.widthTracksTextView = false
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        textView = BlockTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 100), textContainer: container)
        super.init()
        textView.controller = self
        textView.delegate = self
        textView.drawsBackground = false
        textView.isRichText = false // Оформление задаёт модель: панель шрифтов и ⌘B не должны менять только вид.
        textView.importsGraphics = false
        textView.allowsUndo = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.textContainerInset = .zero
        textView.isVerticallyResizable = false
        textView.isHorizontallyResizable = false
        textView.setAccessibilityLabel(NSLocalizedString("Текст страницы", comment: ""))
        SystemAI.disableWritingTools(on: textView)
        renderAll()
    }

    var document: BlockDocument { session.document }

    // MARK: Отображение

    func renderAll() {
        let out = NSMutableAttributedString()
        spans = []
        for (i, block) in document.blocks.enumerated() {
            if i > 0 { out.append(separator(after: document.blocks[i - 1])) }
            let piece = style.render(block)
            spans.append(Span(id: block.id, location: out.length, length: piece.length))
            out.append(piece)
        }
        applying = true
        textView.textStorage?.setAttributedString(out)
        applying = false
        updateHeight()
    }

    private func separator(after block: Block) -> NSAttributedString {
        NSAttributedString(string: "\n", attributes: style.attributes(for: block.type))
    }

    private func rebuildSpans() {
        var location = 0
        spans = document.blocks.map { block in
            let length = block.content.map { BlockTextMapping.toView($0.plainText).utf16.count } ?? 1
            defer { location += length + 1 }
            return Span(id: block.id, location: location, length: length)
        }
    }

    /// Вносит в вид только изменившийся участок.
    private func syncView(from old: BlockDocument) {
        let new = document
        func same(_ a: Block, _ b: Block) -> Bool { a.id == b.id && a.type == b.type && a.payload == b.payload }
        var prefix = 0
        while prefix < old.blocks.count, prefix < new.blocks.count, same(old.blocks[prefix], new.blocks[prefix]) { prefix += 1 }
        var suffix = 0
        while suffix < old.blocks.count - prefix, suffix < new.blocks.count - prefix,
              same(old.blocks[old.blocks.count - 1 - suffix], new.blocks[new.blocks.count - 1 - suffix]) { suffix += 1 }
        guard prefix < old.blocks.count || prefix < new.blocks.count else { return }

        let storage = textView.textStorage!
        let oldSpans = spans
        // Заменяемый участок вместе с разделителями на его краях.
        let hasBefore = prefix > 0
        let hasAfter = suffix > 0
        let lower = hasBefore ? oldSpans[prefix - 1].end : 0
        let upper = hasAfter ? oldSpans[old.blocks.count - suffix].location : storage.length
        let piece = NSMutableAttributedString()
        if hasBefore, prefix < new.blocks.count - suffix || hasAfter {
            piece.append(separator(after: new.blocks[prefix - 1]))
        }
        let middle = prefix..<(new.blocks.count - suffix)
        for i in middle {
            piece.append(style.render(new.blocks[i]))
            if i < new.blocks.count - 1 { piece.append(separator(after: new.blocks[i])) }
        }
        applying = true
        storage.beginEditing()
        storage.replaceCharacters(in: NSRange(location: lower, length: upper - lower), with: piece)
        storage.endEditing()
        applying = false
        rebuildSpans()
        textView.needsDisplay = true
        updateHeight()
    }

    /// `force`: сообщить высоту, даже если она не менялась (подписчик появился позже первого расчёта).
    func updateHeight(force: Bool = false) {
        guard let manager = textView.layoutManager, let container = textView.textContainer else { return }
        manager.ensureLayout(for: container)
        var height = manager.usedRect(for: container).height
        if height == 0 { height = manager.defaultLineHeight(for: style.font(for: .paragraph)) }
        height = ceil(height) + 4
        if height != lastHeight || force {
            lastHeight = height
            onHeightChange?(height)
        }
    }

    // MARK: Координаты

    func offset(of point: BlockPoint) -> Int? {
        guard let i = spans.firstIndex(where: { $0.id == point.blockID }) else { return nil }
        return spans[i].location + min(point.offset, spans[i].length)
    }

    func spanIndex(at location: Int) -> Int {
        var low = 0, high = spans.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if spans[mid].location <= location { low = mid } else { high = mid - 1 }
        }
        return low
    }

    func point(at location: Int) -> BlockPoint {
        let span = spans[spanIndex(at: location)]
        return BlockPoint(blockID: span.id, offset: min(location - span.location, span.length))
    }

    func selection(for range: NSRange) -> BlockSelection {
        var s = BlockSelection(point(at: range.location))
        s.focus = point(at: range.location + range.length)
        return s
    }

    func range(for selection: BlockSelection) -> NSRange? {
        guard let a = offset(of: selection.anchor), let f = offset(of: selection.focus) else { return nil }
        return NSRange(location: min(a, f), length: abs(a - f))
    }

    // MARK: Команды

    /// Выполняет команду и переносит её результат в вид.
    @discardableResult
    func perform(_ command: EditCommand) -> Bool {
        let old = document
        do {
            let result = try session.perform(command)
            guard !result.changes.isEmpty else {
                if let s = result.selection, let r = range(for: s) { textView.setSelectedRange(r) }
                return false
            }
            syncView(from: old)
            restoreSelection()
            return true
        } catch {
            onError?((error as? LocalizedError)?.errorDescription ?? "\(error)")
            return false
        }
    }

    private func restoreSelection() {
        guard let s = session.selection, let r = range(for: s) else { return }
        applying = true
        textView.setSelectedRange(r)
        applying = false
        applyTypingAttributes()
        textView.scrollRangeToVisible(r)
    }

    func undo() {
        let old = document
        session.undoStep()
        syncView(from: old)
        restoreSelection()
    }

    func redo() {
        let old = document
        session.redoStep()
        syncView(from: old)
        restoreSelection()
    }

    var canUndo: Bool { session.canUndo }
    var canRedo: Bool { session.canRedo }

    private func replaceCurrentSelection(with fragments: [BlockFragment]) {
        perform(.replaceRange(selection(for: textView.selectedRange()), fragments))
    }

    func insertBlock(_ type: BlockType) {
        let anchor = point(at: textView.selectedRange().location).blockID
        perform(.insertBlock(after: anchor, type: type))
    }

    func changeBlockType(_ type: BlockType) {
        perform(.changeType(block: point(at: textView.selectedRange().location).blockID, type: type))
    }

    func deleteCurrentBlock() {
        let id = point(at: textView.selectedRange().location).blockID
        perform(.deleteBlock(id))
        if document.blocks.isEmpty { perform(.insertBlock(after: nil, type: .paragraph)) }
    }

    // MARK: Правка текста внутри блока

    /// Несколько диапазонов одной правкой (прямоугольное выделение, поиск): разбиение на блоки так не обновить.
    func textView(_ view: NSTextView, shouldChangeTextInRanges ranges: [NSValue], replacementStrings: [String]?) -> Bool {
        guard ranges.count == 1 else { return applying }
        return self.textView(view, shouldChangeTextIn: ranges[0].rangeValue, replacementString: replacementStrings?.first)
    }

    func textView(_ view: NSTextView, shouldChangeTextIn range: NSRange, replacementString: String?) -> Bool {
        if applying { return true }
        guard let text = replacementString else { return false } // Только атрибуты: их источник — модель.
        let start = spanIndex(at: range.location)
        pendingIndex = start
        editingIndex = start
        // Если AppKit не сообщит об изменении (правка оказалась пустой), выделение не должно замолчать.
        DispatchQueue.main.async { [weak self] in self?.pendingIndex = nil }
        if view.hasMarkedText() { return true }
        let endIndex = spanIndex(at: range.location + range.length)
        let block = document.block(spans[start].id)
        if start == endIndex, block?.isEditable == true, !BlockFragment.containsLineSeparator(text) { return true }
        // Граница блока или непонятный блок: штатная правка испортила бы структуру.
        pendingIndex = nil
        replaceWithCommand(range: range, text: text)
        return false
    }

    private func replaceWithCommand(range: NSRange, text: String) {
        let fragments = text.isEmpty ? [] : BlockFragment.lines(text)
        perform(.replaceRange(selection(for: range), fragments))
    }

    func textDidChange(_ notification: Notification) {
        guard !applying, let index = pendingIndex ?? editingIndex, spans.indices.contains(index) else { return }
        pendingIndex = nil
        adjustSpans(at: index)
        if !textView.hasMarkedText() { commitText(at: index) }
        applyTypingAttributes()
        updateHeight()
    }

    /// Длина блока считается по фактическому тексту вида: при составном вводе модель ещё не менялась.
    private func adjustSpans(at index: Int) {
        let total = textView.textStorage?.length ?? 0
        let others = spans.enumerated().reduce(0) { $0 + ($1.offset == index ? 0 : $1.element.length) } + max(0, spans.count - 1)
        spans[index].length = max(0, total - others)
        var location = spans[index].end + 1
        for i in (index + 1)..<max(index + 1, spans.count) {
            spans[i].location = location
            location += spans[i].length + 1
        }
    }

    /// AppKit не сообщает об изменении текста при составном вводе.
    func markedTextChanged() {
        guard !applying, let index = pendingIndex ?? editingIndex, spans.indices.contains(index) else { return }
        pendingIndex = nil
        adjustSpans(at: index)
        updateHeight()
    }

    /// Переносит текст блока из вида в модель. Пока идёт составной ввод, модель не меняется.
    private func commitText(at index: Int) {
        guard spans.indices.contains(index), let storage = textView.textStorage else { return }
        let span = spans[index]
        guard document.block(span.id)?.isEditable == true, span.end <= storage.length else { return }
        let text = (storage.string as NSString).substring(with: NSRange(location: span.location, length: span.length))
        do {
            try session.perform(.setPlainText(block: span.id, text: BlockTextMapping.toModel(text)))
            session.updateSelection(selection(for: textView.selectedRange()))
        } catch {
            onError?((error as? LocalizedError)?.errorDescription ?? "\(error)")
        }
    }

    /// Составной ввод завершился без обычного изменения текста.
    func markedTextEnded() {
        guard !applying else { return }
        let index = editingIndex ?? spanIndex(at: textView.selectedRange().location)
        guard spans.indices.contains(index) else { return }
        adjustSpans(at: index) // Итоговый текст может быть короче составного.
        commitText(at: index)
    }

    /// Составной ввод поверх выделения через блоки: сначала выделение удаляется командой.
    func prepareForMarkedText() {
        guard !textView.hasMarkedText() else { return }
        let range = textView.selectedRange()
        guard range.length > 0, spanIndex(at: range.location) != spanIndex(at: range.location + range.length) else { return }
        replaceCurrentSelection(with: [])
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        guard !applying, !spans.isEmpty, pendingIndex == nil else { return }
        if !textView.hasMarkedText() {
            editingIndex = spanIndex(at: textView.selectedRange().location)
            session.updateSelection(selection(for: textView.selectedRange()))
        }
        applyTypingAttributes()
    }

    /// Новый текст получает оформление своего блока, а не соседнего.
    private func applyTypingAttributes() {
        guard !textView.hasMarkedText(), !spans.isEmpty,
              let block = document.block(spans[spanIndex(at: textView.selectedRange().location)].id) else { return }
        // Набор продолжает оформление символа слева, как и правка в модели.
        let location = textView.selectedRange().location
        let span = spans[spanIndex(at: location)]
        if location > span.location, block.isEditable, let storage = textView.textStorage, location <= storage.length {
            textView.typingAttributes = storage.attributes(at: location - 1, effectiveRange: nil)
        } else {
            textView.typingAttributes = style.attributes(for: block.type)
        }
    }

    func textDidEndEditing(_ notification: Notification) {
        if !textView.hasMarkedText(), let index = editingIndex { commitText(at: index) }
    }

    // MARK: Клавиши

    func textView(_ view: NSTextView, doCommandBy selector: Selector) -> Bool {
        let range = view.selectedRange()
        let here = point(at: range.location)
        let block = document.block(here.blockID)
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            if range.length > 0 {
                let empty = BlockFragment(type: .paragraph, content: BlockContent())
                replaceCurrentSelection(with: [empty, empty])
            } else if block?.isEditable != true {
                perform(.insertBlock(after: here.blockID, type: .paragraph))
            } else if block?.type == .task, block?.plainText.isEmpty == true {
                perform(.changeType(block: here.blockID, type: .paragraph))
            } else {
                perform(.splitBlock(here))
            }
            return true
        case #selector(NSResponder.insertLineBreak(_:)):
            view.insertText(BlockTextMapping.lineBreak, replacementRange: range)
            return true
        case #selector(NSResponder.insertTab(_:)), #selector(NSResponder.insertBacktab(_:)):
            return true // Вложенность появится вместе со списками (этап M4).
        case #selector(NSResponder.deleteBackward(_:)):
            guard range.length == 0, here.offset == 0 else { return false }
            if let block, block.isEditable, block.type != .paragraph {
                perform(.changeType(block: block.id, type: .paragraph)) // Сначала снимается тип блока.
            } else if let block, block.isEditable {
                perform(.mergeBackward(block: block.id))
            } else {
                return false
            }
            return true
        case #selector(NSResponder.deleteForward(_:)):
            guard range.length == 0, let i = spans.firstIndex(where: { $0.id == here.blockID }),
                  here.offset == spans[i].length, i + 1 < spans.count, block?.isEditable == true else { return false }
            // Со следующим непонятным блоком не объединяем: его данные важнее.
            guard document.block(spans[i + 1].id)?.isEditable == true else { return true }
            perform(.mergeBackward(block: spans[i + 1].id))
            restoreCaret(block: here.blockID, offset: here.offset)
            return true
        default:
            return false
        }
    }

    private func restoreCaret(block: UUID, offset: Int) {
        if let at = self.offset(of: BlockPoint(blockID: block, offset: offset)) {
            textView.setSelectedRange(NSRange(location: at, length: 0))
        }
    }

    // MARK: Буфер обмена

    func copy(to pasteboard: NSPasteboard) {
        let range = textView.selectedRange()
        guard range.length > 0 else { return }
        let fragments = document.fragments(in: selection(for: range))
        pasteboard.clearContents()
        pasteboard.declareTypes([Self.pasteboardType, .string], owner: nil)
        if let data = try? JSONEncoder().encode(fragments) { pasteboard.setData(data, forType: Self.pasteboardType) }
        pasteboard.setString(BlockFragment.plainText(fragments), forType: .string)
    }

    func cut(to pasteboard: NSPasteboard) {
        guard textView.selectedRange().length > 0 else { return }
        copy(to: pasteboard)
        replaceCurrentSelection(with: [])
    }

    func paste(from pasteboard: NSPasteboard) {
        if let data = pasteboard.data(forType: Self.pasteboardType),
           let fragments = try? JSONDecoder().decode([BlockFragment].self, from: data), !fragments.isEmpty {
            replaceCurrentSelection(with: fragments)
        } else if let text = pasteboard.string(forType: .string), !text.isEmpty {
            replaceCurrentSelection(with: BlockFragment.lines(text))
        }
    }

    // MARK: Задачи

    /// Прямоугольник отметки задачи в координатах вида.
    func checkboxRect(for span: Span) -> NSRect? {
        guard let manager = textView.layoutManager, let storage = textView.textStorage else { return nil }
        var line: NSRect
        if span.location >= storage.length {
            line = manager.extraLineFragmentUsedRect
        } else {
            line = manager.lineFragmentUsedRect(forGlyphAt: manager.glyphIndexForCharacter(at: span.location), effectiveRange: nil)
        }
        if line == .zero { return nil }
        line.origin.y += textView.textContainerOrigin.y
        let size = BlockTextStyle.checkboxSize
        let font = style.font(for: .task)
        let top = line.minY + max(0, (font.ascender - font.descender - size) / 2)
        return NSRect(x: textView.textContainerOrigin.x, y: top, width: size, height: size)
    }

    /// Нажатие на отметку; true — нажатие обработано.
    func handleClick(at point: NSPoint) -> Bool {
        guard let glyphRange = textView.layoutManager?.glyphRange(forBoundingRect: NSRect(x: 0, y: point.y - 2, width: textView.bounds.width, height: 4), in: textView.textContainer!),
              let manager = textView.layoutManager else { return false }
        let character = manager.characterIndexForGlyph(at: glyphRange.location)
        let span = spans[spanIndex(at: character)]
        guard let block = document.block(span.id), block.type == .task, let rect = checkboxRect(for: span),
              rect.insetBy(dx: -4, dy: -4).contains(point) else { return false }
        perform(.setChecked(block: block.id, checked: block.content?.checked != true))
        return true
    }

    func drawCheckboxes(in dirty: NSRect) {
        guard let manager = textView.layoutManager, let container = textView.textContainer else { return }
        let glyphs = manager.glyphRange(forBoundingRect: dirty, in: container)
        let characters = manager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        var i = spanIndex(at: characters.location)
        while i < spans.count, spans[i].location <= characters.location + characters.length {
            if let block = document.block(spans[i].id), block.type == .task, let rect = checkboxRect(for: spans[i]) {
                let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 3.5, yRadius: 3.5)
                if block.content?.checked == true {
                    style.accent.setFill()
                    path.fill()
                    let tick = NSBezierPath()
                    tick.move(to: NSPoint(x: rect.minX + 3.2, y: rect.midY + 0.3))
                    tick.line(to: NSPoint(x: rect.minX + 6, y: rect.maxY - 3.6))
                    tick.line(to: NSPoint(x: rect.maxX - 3, y: rect.minY + 3.8))
                    tick.lineWidth = 1.7
                    tick.lineCapStyle = .round
                    NSColor.white.setStroke()
                    tick.stroke()
                } else {
                    style.muted.withAlphaComponent(0.6).setStroke()
                    path.stroke()
                }
            }
            i += 1
        }
    }

    func containerWidthChanged(_ width: CGFloat) {
        guard let container = textView.textContainer, width > 0, abs(container.size.width - width) > 0.5 else { return }
        container.size = NSSize(width: width, height: 10_000_000)
        updateHeight()
    }
}

/// Системный ИИ не входит в продукт (FR-16). API доступен с macOS 15, поэтому свойство задаётся по имени.
enum SystemAI {
    static func disableWritingTools(on view: NSTextView) {
        let setter = NSSelectorFromString("setWritingToolsBehavior:")
        guard view.responds(to: setter) else { return }
        view.setValue(-1, forKey: "writingToolsBehavior") // NSWritingToolsBehaviorNone
    }
}

/// Текстовый вид страницы: системные действия с текстом направляются в команды.
@MainActor
final class BlockTextView: NSTextView {
    weak var controller: BlockEditorController?

    private func run(_ body: (BlockEditorController) -> Void) {
        guard let controller else { return }
        body(controller)
    }

    @objc func undo(_ sender: Any?) { run { $0.undo() } }
    @objc func redo(_ sender: Any?) { run { $0.redo() } }
    override func copy(_ sender: Any?) { run { $0.copy(to: .general) } }
    override func cut(_ sender: Any?) { run { $0.cut(to: .general) } }
    override func paste(_ sender: Any?) { run { $0.paste(from: .general) } }
    override func pasteAsPlainText(_ sender: Any?) { run { $0.paste(from: .general) } }
    override func pasteAsRichText(_ sender: Any?) { run { $0.paste(from: .general) } }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(undo(_:)) { var ok = false; run { ok = $0.canUndo }; return ok }
        if item.action == #selector(redo(_:)) { var ok = false; run { ok = $0.canRedo }; return ok }
        return super.validateUserInterfaceItem(item)
    }

    // Панель шрифтов не меняет вид в обход модели.
    override func changeFont(_ sender: Any?) {}
    override func changeAttributes(_ sender: Any?) {}

    // Перетаскивание появится вместе с блоками (M4): штатное удаляет источник по устаревшему диапазону.
    override var acceptableDragTypes: [NSPasteboard.PasteboardType] { [] }
    override func dragSelection(with event: NSEvent, offset mouseOffset: NSSize, slideBack: Bool) -> Bool { false }

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        run { $0.prepareForMarkedText() }
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        run { $0.markedTextChanged() }
    }

    override func unmarkText() {
        super.unmarkText()
        run { $0.markedTextEnded() }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        run { $0.containerWidthChanged(newSize.width) }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        run { $0.drawCheckboxes(in: dirtyRect) }
    }

    override func mouseDown(with event: NSEvent) {
        let at = convert(event.locationInWindow, from: nil)
        var handled = false
        run { handled = $0.handleClick(at: at) }
        if !handled { super.mouseDown(with: event) }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        // Действия меню относятся к блоку под курсором мыши.
        let index = characterIndexForInsertion(at: convert(event.locationInWindow, from: nil))
        let selected = selectedRange()
        if index < selected.location || index > selected.location + selected.length { setSelectedRange(NSRange(location: index, length: 0)) }
        let menu = super.menu(for: event) ?? NSMenu()
        let convert = NSMenu()
        for (type, title) in [(BlockType.paragraph, "Текст"), (.heading1, "Заголовок 1"), (.heading2, "Заголовок 2"), (.heading3, "Заголовок 3"), (.task, "Задача")] {
            let item = NSMenuItem(title: NSLocalizedString(title, comment: ""), action: #selector(convertBlock(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = type.rawValue
            convert.addItem(item)
        }
        let head = NSMenuItem(title: NSLocalizedString("Преобразовать", comment: ""), action: nil, keyEquivalent: "")
        head.submenu = convert
        let remove = NSMenuItem(title: NSLocalizedString("Удалить блок", comment: ""), action: #selector(removeBlock(_:)), keyEquivalent: "")
        remove.target = self
        menu.insertItem(.separator(), at: 0)
        menu.insertItem(remove, at: 0)
        menu.insertItem(head, at: 0)
        // Системные пункты письма и ИИ не показываются: продукт без ИИ.
        return menu
    }

    @objc private func convertBlock(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String else { return }
        run { $0.changeBlockType(BlockType(rawValue: raw)) }
    }

    @objc private func removeBlock(_ sender: NSMenuItem) { run { $0.deleteCurrentBlock() } }
}
