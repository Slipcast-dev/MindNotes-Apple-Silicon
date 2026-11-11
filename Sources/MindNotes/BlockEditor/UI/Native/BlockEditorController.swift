import AppKit
import AVFoundation
import ImageIO
import UniformTypeIdentifiers

/// Связывает единый NSTextView с документом страницы.
///
/// Текст вида — видимые блоки через "\n". Правка внутри блока идёт штатным путём NSTextView, поэтому IME, раскладки
/// и emoji работают системно; модель догоняет вид. Всё, что меняет структуру, выполняется командой, и в вид
/// вносится только изменившийся участок: выделение и прокрутка не сбрасываются.
@MainActor
final class BlockEditorController: NSObject, NSTextViewDelegate {
    struct Span {
        var id: UUID
        var location: Int
        var length: Int
        var end: Int { location + length }
    }

    /// Открытое меню «/»: где стоит косая черта и что введено после неё.
    struct SlashState: Equatable {
        enum Kind { case blocks, pageLink, mention }
        var kind: Kind = .blocks
        var blockID: UUID
        var slashOffset: Int
        var query: String
        var selected: Int
    }

    static let pasteboardType = NSPasteboard.PasteboardType("local.personal.MindNotes.blocks")
    /// Левое поле вида: ручка блока находится вне колонки текста.
    static let gutter: CGFloat = 26

    let session: EditorSession
    let textView: BlockTextView
    var style: BlockTextStyle
    /// Высота содержимого изменилась.
    var onHeightChange: ((CGFloat) -> Void)?
    var onError: ((String) -> Void)?
    /// Изменилось меню «/»; прямоугольник в экранных координатах.
    var onSlashChange: ((SlashState?, [EditorAction.Item], NSRect) -> Void)?
    /// Изменилось выделение текста: прямоугольник для панели форматирования или nil.
    var onSelectionRect: ((NSRect?) -> Void)?
    /// Нужен адрес ссылки: интерфейс спрашивает и возвращает значение.
    var requestLink: ((String?, @escaping (String?) -> Void) -> Void)?
    /// Страницы для «[[»: запрос → найденные.
    var pageSearch: ((String) -> [(id: UUID, title: String)])?
    /// Что сделать с вставленным адресом: ссылка, закладка или встраивание; nil — обычный текст (меню закрыто).
    var chooseLinkKind: ((URL) -> BlockType?)?
    /// Превью закладки: заголовок, описание и сохранённая картинка; nil — сеть выключена или запрос не удался.
    var fetchLinkPreview: ((URL) async -> (title: String?, description: String?, asset: UUID?)?)?
    /// Живое представление базы для блока (M13); nil — показывается прежняя карточка.
    var liveView: ((Block) -> NSView?)?
    /// Показанные живые представления по ID блока; nil в словаре — вид не получился, нужна карточка.
    private var liveViews: [UUID: LiveViewHost?] = [:]
    /// Открыть адрес закладки или окно встраивания.
    var onOpenURL: ((URL, BlockType) -> Void)?
    /// Заголовок открытой страницы: текст напоминания.
    var pageTitle: (() -> String)?
    /// Справочник людей для «@».
    var peopleSource: (() -> [Person])?
    /// Выбор даты для «@»: окно возвращает дату (`ГГГГ-ММ-ДД` или с временем) и время напоминания или nil.
    var requestMentionDate: ((@escaping (String, String?) -> Void) -> Void)?
    /// Напоминание к дате упоминания: время `ГГГГ-ММ-ДДTЧЧ:ММ` и текст уведомления.
    var scheduleReminder: ((String, String) -> Void)?
    /// Курсор до последнего перемещения: по нему видно, с какой стороны он вошёл в упоминание.
    private var lastCaret = 0
    /// Нажата внутренняя ссылка: страница и, возможно, блок.
    var onOpenLink: ((UUID, UUID?) -> Void)?
    /// Комментарий к выделенному: оболочка спрашивает текст и записывает ветку; nil — отменено.
    var requestComment: ((_ block: UUID, _ anchor: String, _ thread: UUID) async -> Bool)?
    /// Щелчок по прокомментированному тексту: открыть ветку.
    var onOpenComment: ((UUID) -> Void)?
    /// ⌥-щелчок по ссылке на страницу: открыть её сбоку.
    var onPeekLink: ((UUID) -> Void)?
    /// Копирует файл в пространство; ошибки показывает вызывающий.
    var addAttachment: ((URL) async throws -> AssetRecord)?
    /// Адрес вложения на диске.
    var assetURL: ((UUID) -> URL?)?
    /// Выбор файла пользователем.
    var pickFile: ((BlockType) -> URL?)?
    /// Открыть таблицу в редакторе.
    var onEditTable: ((Block) -> Void)?
    /// Нажатие на видео: проигрыватель в окне приложения.
    var onPlayVideo: ((URL, String) -> Void)?
    /// Выбор базы для встроенного представления; nil — отменено.
    var pickDatabaseView: (() -> BlockFragment?)?
    /// Предпросмотр встроенного представления: nil, пока данные не загружены.
    var embedSummary: ((Block) -> EmbedSummary?)?
    var onOpenEmbed: ((Block) -> Void)?
    /// ИИ (ADR-0016): доступен ли сейчас; nil или false — пробел и ⌘J работают как без ИИ.
    var aiAvailable: (() -> Bool)?
    /// Запрос к ИИ: редактор (основной или поле колонки) и выделенный диапазон или курсор на пустой строке.
    var onAIRequest: ((BlockEditorController, NSRange) -> Void)?
    /// Миниатюры занимают много памяти: кэш ограничен.
    private let imageCache: NSCache<NSUUID, NSImage> = {
        let cache = NSCache<NSUUID, NSImage>()
        cache.countLimit = 40
        return cache
    }()
    private var loadingImages: Set<UUID> = []
    private var failedImages: Set<UUID> = []
    /// Длительность видео по вложению, секунды.
    private var videoDurations: [UUID: Double] = [:]

    private(set) var spans: [Span] = []
    private(set) var visible: [Block] = []
    private var depths: [UUID: Int] = [:]
    private var numbers: [UUID: Int] = [:]
    private var applying = false
    private var editingIndex: Int?
    /// Блок правки между shouldChange и textDidChange. AppKit сообщает о новом выделении раньше, чем о новом
    /// тексте: в этот момент разбиение устарело, и определять блок по выделению нельзя.
    private var pendingIndex: Int?
    /// Что было до правки: для Markdown-сокращений и меню «/» нужен только введённый символ.
    private var typedText: String?
    private var lastHeight: CGFloat = 0
    private(set) var slash: SlashState?
    /// Метки для следующего ввода, включённые при пустом выделении (⌘B перед набором).
    private(set) var pendingMarks: Set<String> = []
    /// Метки, снятые для следующего ввода (⌘B в конце жирного текста).
    private(set) var pendingRemoved: Set<String> = []

    /// Поле одной колонки (ADR-0013): показывает только потомков этого блока-колонки. nil — вся страница.
    let scope: UUID?
    /// Настройка поля колонки так же, как основного редактора (ссылки, вложения, меню); задаёт оболочка.
    var configureColumnEditor: ((BlockEditorController) -> Void)?
    /// Ряды колонок: ID ряда → вид с полями колонок поверх места в тексте.
    private var columnHosts: [UUID: ColumnsHost] = [:]
    private var syncPending = false

    init(session: EditorSession, style: BlockTextStyle = BlockTextStyle(), scope: UUID? = nil) {
        self.session = session
        self.style = style
        self.scope = scope
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 600, height: 10_000_000))
        container.widthTracksTextView = false
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        textView = BlockTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 100), textContainer: container)
        super.init()
        self.style.atomCell = { [weak self] in self?.cell(for: $0) }
        // Живые представления едут вместе с текстом: после любой правки и при смене ширины их места пересчитываются.
        textView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: textView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleLiveLayout() }
        }
        if let storage = textView.textStorage {
            NotificationCenter.default.addObserver(forName: NSTextStorage.didProcessEditingNotification, object: storage, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleLiveLayout() }
            }
        }
        textView.controller = self
        textView.delegate = self
        // Правка в другом поле той же страницы (колонка или основной текст): вид перестраивается по модели.
        session.observeSelection(self) { [weak self] in MainActor.assumeIsolated { self?.textView.needsDisplay = true } }
        // Отложенно: свой редактор к этому моменту уже совпадает с моделью, и перестройка ничего не меняет.
        session.observe(self) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.syncPending else { return }
                self.syncPending = true
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.syncPending = false
                    guard !self.applying, !self.textView.hasMarkedText() else { return }
                    self.syncView()
                    self.layoutColumns()
                }
            }
        }
        textView.drawsBackground = false
        textView.isRichText = false // Оформление задаёт модель: панель шрифтов и ⌘B не должны менять только вид.
        textView.importsGraphics = false
        textView.allowsUndo = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.textContainerInset = NSSize(width: Self.gutter, height: 0) // Поле для ручки перетаскивания.
        textView.isVerticallyResizable = false
        textView.isHorizontallyResizable = false
        textView.linkTextAttributes = [.cursor: NSCursor.pointingHand]
        textView.setAccessibilityLabel(NSLocalizedString("Текст страницы", comment: ""))
        SystemAI.disableWritingTools(on: textView)
        renderAll()
    }

    var document: BlockDocument { session.document }

    // MARK: Отображение

    /// Блоки, не скрытые свёрнутым родителем, с глубиной и номерами списков.
    private func computeVisible() -> [Block] {
        var depth: [UUID: Int] = [:]
        var hidden: Set<UUID> = []
        var nums: [UUID: Int] = [:]
        var lastNumber: [UUID?: (id: UUID, value: Int)] = [:]
        var previousSibling: [UUID?: UUID] = [:]
        var out: [Block] = []
        // Колонки: основной редактор не показывает содержимое рядов, поле колонки — только своё (ADR-0013).
        var outside: Set<UUID> = []
        if let scope { depth[scope] = -1 }
        for block in document.blocks {
            let parent = block.parentID.flatMap { document.block($0) }
            if scope != nil {
                // Глубина есть только у самой колонки (−1) и у уже взятых блоков: берём только её потомков.
                guard let p = block.parentID, depth[p] != nil else { continue }
            } else if let p = parent, p.type == .columnList || outside.contains(p.id) {
                outside.insert(block.id)
                continue
            }
            depth[block.id] = parent.map { (depth[$0.id] ?? 0) + 1 } ?? 0
            if block.type == .numbered {
                let key = block.parentID
                if let last = lastNumber[key], previousSibling[key] == last.id {
                    lastNumber[key] = (block.id, last.value + 1)
                } else {
                    lastNumber[key] = (block.id, 1)
                }
                nums[block.id] = lastNumber[key]?.value
            }
            previousSibling[block.parentID] = block.id
            if let p = parent, hidden.contains(p.id) || p.isCollapsed {
                hidden.insert(block.id)
            } else {
                out.append(block)
            }
        }
        depths = depth
        numbers = nums
        return out
    }

    func renderAll() {
        visible = computeVisible()
        let out = NSMutableAttributedString()
        spans = []
        for (i, block) in visible.enumerated() {
            if i > 0 { out.append(separator(after: visible[i - 1])) }
            let piece = style.render(block, depth: depths[block.id] ?? 0)
            spans.append(Span(id: block.id, location: out.length, length: piece.length))
            out.append(piece)
        }
        applying = true
        textView.textStorage?.setAttributedString(out)
        applying = false
        updateHeight()
    }

    private func separator(after block: Block) -> NSAttributedString {
        NSAttributedString(string: "\n", attributes: style.attributes(for: block.type, depth: depths[block.id] ?? 0))
    }

    private func rebuildSpans() {
        var location = 0
        spans = visible.map { block in
            let length = block.content.map { BlockTextMapping.toView($0.plainText).utf16.count } ?? 1
            defer { location += length + 1 }
            return Span(id: block.id, location: location, length: length)
        }
    }

    /// Вносит в вид только изменившийся участок.
    private func syncView() {
        let oldBlocks = visible
        let oldDepths = depths
        let oldSpans = spans
        let new = computeVisible()
        let newDepths = depths
        func same(_ a: Block, _ b: Block) -> Bool {
            a.id == b.id && a.type == b.type && a.payload == b.payload && oldDepths[a.id] == newDepths[b.id]
        }
        var prefix = 0
        while prefix < oldBlocks.count, prefix < new.count, same(oldBlocks[prefix], new[prefix]) { prefix += 1 }
        var suffix = 0
        while suffix < oldBlocks.count - prefix, suffix < new.count - prefix,
              same(oldBlocks[oldBlocks.count - 1 - suffix], new[new.count - 1 - suffix]) { suffix += 1 }
        visible = new
        guard prefix < oldBlocks.count || prefix < new.count else {
            rebuildSpans()
            textView.needsDisplay = true
            return
        }
        let storage = textView.textStorage!
        // Заменяемый участок вместе с разделителями на его краях.
        let hasBefore = prefix > 0
        let hasAfter = suffix > 0
        let lower = hasBefore ? oldSpans[prefix - 1].end : 0
        let upper = hasAfter ? oldSpans[oldBlocks.count - suffix].location : storage.length
        let piece = NSMutableAttributedString()
        if hasBefore, prefix < new.count - suffix || hasAfter {
            piece.append(separator(after: new[prefix - 1]))
        }
        for i in prefix..<(new.count - suffix) {
            piece.append(style.render(new[i], depth: depths[new[i].id] ?? 0))
            if i < new.count - 1 { piece.append(separator(after: new[i])) }
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
        defer { layoutLiveViews(); layoutColumns() }
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

    func depth(of id: UUID) -> Int { depths[id] ?? 0 }
    func number(of id: UUID) -> Int { numbers[id] ?? 1 }

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

    var currentBlock: Block? { spans.isEmpty ? nil : document.block(spans[spanIndex(at: textView.selectedRange().location)].id) }

    // MARK: Команды

    /// Выполняет команду и переносит её результат в вид.
    @discardableResult
    func perform(_ command: EditCommand) -> Bool {
        do {
            let result = try session.perform(command)
            guard !result.changes.isEmpty else {
                if let s = result.selection, let r = range(for: s) { textView.setSelectedRange(r) }
                return false
            }
            syncView()
            restoreSelection()
            loadNewSyncedCopies()
            updateAIHint()
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

    // MARK: Живые представления (M13, ADR-0013)

    private func liveHost(for block: Block) -> LiveViewHost? {
        if let known = liveViews[block.id] { return known }
        guard let provider = liveView, block.contentVersion <= 1 else { return nil }
        guard let view = provider(block) else {
            liveViews[block.id] = .some(nil)
            return nil
        }
        let host = LiveViewHost(content: view)
        host.onResize = { [weak self] height in self?.setLiveHeight(block.id, Double(height)) }
        liveViews[block.id] = host
        return host
    }

    /// Высота живого представления: одна правка, ⌘Z возвращает прежнюю.
    func setLiveHeight(_ id: UUID, _ height: Double) {
        guard let block = document.block(id), block.type == .databaseView else { return }
        _ = try? session.perform(.setAtomData(block: id, json: AtomData.withViewHeight(block, height), plain: block.plainText))
        syncView()
        layoutLiveViews()
    }

    /// Состояние встроенного представления (фильтр, вид) меняется без прокрутки к курсору: правка идёт из самого вида.
    func updateEmbedded(_ id: UUID, json: String) {
        guard let block = document.block(id) else { return }
        _ = try? session.perform(.setAtomData(block: id, json: json, plain: block.plainText))
        syncView()
        layoutLiveViews()
    }

    private var liveLayoutPending = false

    private func scheduleLiveLayout() {
        guard !liveViews.isEmpty || !columnHosts.isEmpty, !liveLayoutPending else { return }
        liveLayoutPending = true
        DispatchQueue.main.async { [weak self] in
            self?.liveLayoutPending = false
            self?.layoutLiveViews()
            self?.layoutColumns()
        }
    }

    // MARK: Колонки (M13, ADR-0013)

    /// Ставит ряды колонок на их места: поле на каждую колонку, состав колонок — по модели.
    func layoutColumns() {
        guard scope == nil, let manager = textView.layoutManager, let container = textView.textContainer else { return }
        let rows = visible.filter { $0.type == .columnList }
        for (id, host) in columnHosts where !rows.contains(where: { $0.id == id }) {
            host.removeFromSuperview()
            for c in host.columns { session.stopObserving(c.editor) }
            columnHosts[id] = nil
        }
        guard !rows.isEmpty else { return }
        manager.ensureLayout(for: container)
        let shown = Dictionary(spans.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for row in rows {
            guard let span = shown[row.id] else { continue }
            let host = columnHosts[row.id] ?? makeColumnsHost(row.id)
            let columns = document.blocks.filter { $0.parentID == row.id && $0.type == .column }
            if host.columnIDs != columns.map(\.id) {
                let reuse = Dictionary(host.columns.map { ($0.id, $0.editor) }, uniquingKeysWith: { a, _ in a })
                host.setColumns(columns.map { c in
                    if let editor = reuse[c.id] { return ColumnsHost.Column(id: c.id, editor: editor) }
                    let editor = BlockEditorController(session: session, style: style, scope: c.id)
                    editor.inherit(from: self)
                    configureColumnEditor?(editor)
                    editor.renderAll()
                    return ColumnsHost.Column(id: c.id, editor: editor)
                })
            }
            host.ratios = AtomData.normalizedRatios(columns.map(AtomData.columnRatio(of:)))
            let glyphs = manager.glyphRange(forCharacterRange: NSRange(location: span.location, length: 1), actualCharacterRange: nil)
            var rect = manager.boundingRect(forGlyphRange: glyphs, in: container)
                .offsetBy(dx: textView.textContainerOrigin.x, dy: textView.textContainerOrigin.y)
            rect.size.height = host.contentHeight
            // У поля колонки своё поле под ручку блока: ряд сдвигается на него влево, текст колонок встаёт по краю страницы.
            rect.origin.x -= Self.gutter
            rect.size.width += Self.gutter
            if host.superview !== textView { textView.addSubview(host) }
            if host.frame != rect { host.frame = rect }
            host.needsLayout = true
        }
    }

    /// Поле колонки умеет то же, что основной редактор: ссылки, вложения, упоминания, превью, представления.
    func inherit(from main: BlockEditorController) {
        onError = main.onError
        pageSearch = main.pageSearch
        chooseLinkKind = main.chooseLinkKind
        fetchLinkPreview = main.fetchLinkPreview
        liveView = main.liveView
        onOpenURL = main.onOpenURL
        pageTitle = main.pageTitle
        peopleSource = main.peopleSource
        requestMentionDate = main.requestMentionDate
        scheduleReminder = main.scheduleReminder
        onOpenLink = main.onOpenLink
        onPeekLink = main.onPeekLink
        requestComment = main.requestComment
        onOpenComment = main.onOpenComment
        style.activeComments = main.style.activeComments
        addAttachment = main.addAttachment
        assetURL = main.assetURL
        pickFile = main.pickFile
        onEditTable = main.onEditTable
        onPlayVideo = main.onPlayVideo
        pickDatabaseView = main.pickDatabaseView
        embedSummary = main.embedSummary
        onOpenEmbed = main.onOpenEmbed
        requestLink = main.requestLink
        aiAvailable = main.aiAvailable
        onAIRequest = main.onAIRequest
    }

    private func makeColumnsHost(_ rowID: UUID) -> ColumnsHost {
        let host = ColumnsHost()
        host.onHeight = { [weak self] in self?.columnsHeightChanged(rowID) }
        host.onRatios = { [weak self] ratios in _ = self?.perform(.setColumnRatios(rowID, ratios)) }
        columnHosts[rowID] = host
        return host
    }

    /// Колонка выросла или уменьшилась: место ряда в тексте пересчитывается.
    private func columnsHeightChanged(_ rowID: UUID) {
        guard let span = spans.first(where: { $0.id == rowID }), let manager = textView.layoutManager else { return }
        manager.invalidateLayout(forCharacterRange: NSRange(location: span.location, length: 1), actualCharacterRange: nil)
        updateHeight()
        textView.needsDisplay = true
    }

    /// Бросок блока на левый или правый край другого блока: блок встаёт колонкой рядом (как в Notion).
    func columnDrop(at point: NSPoint, dragging id: UUID) -> (target: UUID, left: Bool, rect: NSRect)? {
        guard let span = block(atY: point.y), span.id != id, let target = document.block(span.id),
              target.type != .columnList, let rect = blockRect(for: span) else { return nil }
        let left = textView.textContainerOrigin.x + CGFloat(depths[span.id] ?? 0) * BlockTextStyle.nestIndent
        let width = (textView.textContainer?.size.width ?? textView.bounds.width) - CGFloat(depths[span.id] ?? 0) * BlockTextStyle.nestIndent
        let zone = min(60, width * 0.15)
        // Только над самим блоком и внутри текста: ручка левее, обычный перенос вверх-вниз колонок не создаёт.
        guard point.y >= rect.minY, point.y <= rect.maxY, point.x >= left + 6 else { return nil }
        if point.x < left + zone { return (span.id, true, NSRect(x: left - 4, y: rect.minY, width: 3, height: rect.height)) }
        if point.x > left + width - zone { return (span.id, false, NSRect(x: left + width, y: rect.minY, width: 3, height: rect.height)) }
        return nil
    }

    /// Ставит живые представления на места их блоков; лишние убирает.
    func layoutLiveViews() {
        guard !liveViews.isEmpty, let manager = textView.layoutManager, let container = textView.textContainer else { return }
        manager.ensureLayout(for: container)
        let shown = Dictionary(spans.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for (id, entry) in liveViews {
            guard let host = entry else { continue }
            guard let span = shown[id], span.length > 0, document.block(id)?.type == .databaseView else {
                host.removeFromSuperview()
                if document.block(id) == nil { liveViews[id] = nil }
                continue
            }
            let glyphs = manager.glyphRange(forCharacterRange: NSRange(location: span.location, length: 1), actualCharacterRange: nil)
            var rect = manager.boundingRect(forGlyphRange: glyphs, in: container)
                .offsetBy(dx: textView.textContainerOrigin.x, dy: textView.textContainerOrigin.y)
            // Строка с местом выше самого места на межстрочный интервал: высота — из блока.
            if let block = document.block(id) { rect.size.height = CGFloat(AtomData.viewHeight(of: block)) }
            if host.superview !== textView { textView.addSubview(host) }
            if host.frame != rect { host.frame = rect }
        }
    }

    /// Вставленная копия синхронизированного блока получает содержимое оригинала из хранилища.
    private func loadNewSyncedCopies() {
        guard document.blocks.contains(where: { $0.type == .syncedRef && session.syncedRefs[$0.id] == nil }) else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            try? await self.session.loadSyncedSources()
            self.syncView()
            self.textView.needsDisplay = true
        }
    }

    /// Документ сессии заменён целиком (восстановление версии): вид перестраивается по нему.
    func reloadFromSession() {
        syncView()
        restoreSelection()
    }

    func undo() {
        session.undoStep()
        syncView()
        restoreSelection()
        updateAIHint()
    }

    func redo() {
        session.redoStep()
        syncView()
        restoreSelection()
        updateAIHint()
    }

    var canUndo: Bool { session.canUndo }
    var canRedo: Bool { session.canRedo }

    private func replaceCurrentSelection(with fragments: [BlockFragment]) {
        perform(.replaceRange(selection(for: textView.selectedRange()), fragments))
    }

    /// Выполняет действие из единого меню.
    func run(_ action: EditorAction) {
        let range = textView.selectedRange()
        let sel = selection(for: range)
        let id = point(at: range.location).blockID
        switch action {
        case .turnInto(let type):
            perform(.batch(selectedBlockIDs().map { .changeType(block: $0, type: type) }))
        case .insert(let type):
            perform(.insertBlock(after: id, type: type))
            if document.blocks.last?.type.isAtom == true || type.isAtom { ensureTextAfterAtom() }
        case .mark(let mark):
            if range.length == 0 {
                if isMarked(mark) {
                    pendingMarks.remove(mark)
                    if markAtCaret(mark) { pendingRemoved.insert(mark) }
                } else {
                    pendingRemoved.remove(mark)
                    if !markAtCaret(mark) { pendingMarks.insert(mark) }
                }
                applyTypingAttributes()
            } else {
                perform(.formatText(sel, .toggle(mark)))
            }
        case .color(let name):
            perform(.formatText(sel, .setValue(prefix: "c:", value: name)))
        case .highlight(let name):
            perform(.formatText(sel, .setValue(prefix: "bg:", value: name)))
        case .blockColor(let color):
            let ids = selectedBlockIDs().filter { document.block($0)?.isEditable == true }
            if !ids.isEmpty {
                perform(.batch(ids.map { .setBlockColor(block: $0, color: color) }))
                caretKeep(range)
                textView.needsDisplay = true // фон накрывает и вложенные блоки, их строки не перерисовываются сами
            }
        case .link:
            guard range.length > 0 else { return }
            requestLink?(currentLink(in: range)) { [weak self] url in
                guard let self else { return }
                let value = url.flatMap { Self.encodedAddress($0.trimmingCharacters(in: .whitespaces)) }
                self.perform(.formatText(sel, .setValue(prefix: "a:", value: value?.isEmpty == false ? value : nil)))
            }
        case .clearFormat:
            perform(.formatText(sel, .clear))
        case .indent:
            perform(.batch(topSelectedBlockIDs().map { .indent($0) }))
            caretKeep(range)
        case .outdent:
            perform(.batch(topSelectedBlockIDs().reversed().map { .outdent($0) }))
            caretKeep(range)
        case .deleteBlock:
            perform(.batch(topSelectedBlockIDs().map { .deleteBlock($0) }))
            // Опустевшая колонка убирается; ряд из одной колонки распускается.
            if let scope, !document.blocks.contains(where: { $0.parentID == scope }), let row = document.block(scope)?.parentID {
                perform(.tidyColumns(row))
                return
            }
            if document.blocks.isEmpty { perform(.insertBlock(after: nil, type: .paragraph)) }
        case .linkPage, .beginPageLink:
            if case .beginPageLink = action {
                textView.insertText("[[", replacementRange: range)
            }
        case .insertBookmark, .insertEmbed:
            requestLink?(nil) { [weak self] text in
                guard let self, let text, let url = LinkCard.url(text) else { return }
                self.insertLinkCard(action == .insertBookmark ? .bookmark : .embed, url: url)
            }
        case .comment:
            guard range.length > 0, let ask = requestComment else { return }
            let thread = UUID()
            let anchor = (textView.string as NSString).substring(with: range)
            Task { @MainActor [weak self] in
                guard let self, await ask(id, anchor, thread) else { return }
                // Ветка записана: выделенный текст получает её метку одной правкой.
                self.perform(.formatText(sel, .toggle(Comment.mark(thread))))
            }
        case .makeSynced:
            let ids = topSelectedBlockIDs()
            perform(.makeSynced(ids))
            caretKeep(range)
        case .unsyncCopy:
            if let block = document.block(id), block.type == .syncedRef { perform(.unsync(block.id)) }
            else if let ref = document.blocks.first(where: { $0.type == .syncedRef && document.descendants(of: $0.id).contains { $0.id == id } }) { perform(.unsync(ref.id)) }
        case .refreshLinkPreview:
            if let block = document.block(id), block.type == .bookmark, let url = AtomData.url(of: block) { loadPreview(block: block.id, url: url) }
        case .mentionPage(let page, let title):
            insertMention(Mention.page(page, title: title), at: range)
        case .mentionPerson(let person):
            insertMention(Mention.person(person), at: range)
        case .mentionDate(let iso):
            if let run = Mention.date(iso, label: Self.dateLabel(iso)) { insertMention(run, at: range) }
        case .pickMentionDate:
            requestMentionDate? { [weak self] iso, reminder in
                guard let self, let run = Mention.date(iso, label: Self.dateLabel(iso), reminder: reminder) else { return }
                self.insertMention(run, at: self.textView.selectedRange())
                if let reminder {
                    let page = self.pageTitle?() ?? ""
                    self.scheduleReminder?(reminder, page.isEmpty ? run.text : "\(run.text) — \(page)")
                }
            }
        case .attach(let type):
            guard let url = pickFile?(type) else { return }
            insertFiles([url], type: type)
        case .insertTable:
            insertFragments([AtomData.table([["", "", ""], ["", "", ""]])])
        case .insertDatabaseView:
            if let fragment = pickDatabaseView?() { insertFragments([fragment]) }
        case .copyBlockLink:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(PageLink.url(page: document.pageID, block: id), forType: .string)
        case .moveBlockUp, .moveBlockDown:
            moveCurrentBlock(down: action == .moveBlockDown)
        case .duplicateBlock:
            let fragments = topSelectedBlockIDs().compactMap { document.block($0) }.map { b in
                b.content.map { BlockFragment(type: b.type, content: $0) } ?? BlockFragment(opaque: b)
            }
            guard let last = topSelectedBlockIDs().last, let tail = document.block(last) else { return }
            perform(.insertBlock(after: tail.id, type: .paragraph))
            if let s = session.selection { perform(.replaceRange(s, fragments)) }
        }
    }

    var isInsideSyncedCopy: Bool {
        let id = point(at: textView.selectedRange().location).blockID
        if document.block(id)?.type == .syncedRef { return true }
        return document.blocks.contains { $0.type == .syncedRef && document.descendants(of: $0.id).contains { $0.id == id } }
    }

    var isBookmarkAtCaret: Bool { document.block(point(at: textView.selectedRange().location).blockID)?.type == .bookmark }

    /// Закладка или встраивание на месте выделения; превью закладки загружается следом и не мешает набору.
    func insertLinkCard(_ type: BlockType, url: URL) {
        let before = Set(document.blocks.map(\.id))
        insertFragments([type == .embed ? AtomData.embed(url: url) : AtomData.bookmark(url: url, title: url.host)])
        guard type == .bookmark, let added = document.blocks.first(where: { !before.contains($0.id) && $0.type == .bookmark }) else { return }
        loadPreview(block: added.id, url: url)
    }

    private func loadPreview(block id: UUID, url: URL) {
        guard let fetch = fetchLinkPreview else { return }
        Task { @MainActor [weak self] in
            guard let result = await fetch(url), let self, let block = self.document.block(id), block.type == .bookmark else { return }
            let json = AtomData.bookmarkJSON(url: url, title: result.title ?? url.host, description: result.description,
                                             asset: result.asset ?? block.assetID, keeping: block.atomJSON)
            // Превью — не правка пользователя: без шага отмены.
            _ = try? self.session.perform(.setAtomData(block: id, json: json, plain: AtomData.linkPlain(url: url, title: result.title)), recordUndo: false)
            self.syncView()
        }
    }

    /// Открытые ветки комментариев: их текст подсвечен; поле колонок получают то же.
    func setActiveComments(_ threads: Set<UUID>) {
        let marks = Set(threads.map(Comment.mark))
        guard marks != style.activeComments else { return }
        style.activeComments = marks
        renderAll()
        for host in columnHosts.values { for c in host.columns { c.editor.setActiveComments(threads) } }
    }

    /// Переименование страницы или человека: подписи на открытой странице меняются без шага отмены,
    /// иначе следующая правка блока записала бы прежнюю подпись поверх обновлённой в хранилище.
    func relabel(_ command: EditCommand) {
        let caret = textView.selectedRange()
        do {
            guard try !session.perform(command, recordUndo: false, quiet: true).changes.isEmpty else { return }
        } catch { return }
        syncView()
        let length = textView.textStorage?.length ?? 0
        textView.setSelectedRange(NSRange(location: min(caret.location, length), length: 0))
    }

    /// Упоминание и пробел после него встают на место выделения; набор дальше идёт обычным текстом.
    private func insertMention(_ run: TextRun, at range: NSRange) {
        let sel = selection(for: range)
        perform(.replaceRange(sel, [BlockFragment(type: .paragraph, content: BlockContent(runs: [run, TextRun(" ")]))]))
    }

    /// Подпись даты упоминания на языке интерфейса: «12 ноября 2026 г.» или с временем.
    static func dateLabel(_ iso: String) -> String {
        let parts = iso.split(separator: "T")
        guard let day = LocalDate(iso: String(parts[0])) else { return iso }
        let f = DateFormatter()
        f.locale = Locale.current
        f.timeZone = .current
        f.dateStyle = .long
        f.timeStyle = .none
        var text = f.string(from: day.date(in: .current))
        if parts.count == 2 { text += ", " + parts[1] }
        return text
    }

    /// Неделимые блоки встают на место выделения; ниже всегда остаётся строка для ввода.
    func insertFragments(_ fragments: [BlockFragment]) {
        if textView.hasMarkedText() { textView.unmarkText() }
        let range = textView.selectedRange()
        let end = point(at: range.location + range.length)
        // В конце страницы ниже нужна строка для ввода; одна правка отмены.
        let atDocumentEnd = spans.last.map { $0.id == end.blockID && end.offset == $0.length } ?? false
        let tail = atDocumentEnd ? [BlockFragment(type: .paragraph, content: BlockContent())] : []
        perform(.replaceRange(selection(for: range), fragments + tail))
        if !atDocumentEnd { ensureTextAfterAtom() }
    }

    /// Копирует файлы в пространство и вставляет блоки: сначала файл, затем ссылка (FR-08).
    /// `cleanup` — временная папка с полученными файлами: удаляется, когда они скопированы в пространство.
    func insertFiles(_ urls: [URL], type: BlockType? = nil, cleanup: URL? = nil) {
        guard let add = addAttachment else {
            if let cleanup { try? FileManager.default.removeItem(at: cleanup) }
            return
        }
        Task { @MainActor in
            var fragments: [BlockFragment] = []
            defer { if let cleanup { try? FileManager.default.removeItem(at: cleanup) } }
            for url in urls {
                do {
                    let asset = try await add(url)
                    fragments.append(AtomData.attachment(type: type ?? Self.attachmentType(for: url), asset: asset))
                } catch {
                    self.onError?((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
                }
            }
            if !fragments.isEmpty { self.insertFragments(fragments) }
        }
    }

    /// Что редактор принимает при перетаскивании: файлы с диска, «обещанные» файлы (Фото, браузер, снимки экрана)
    /// и данные изображения.
    static let droppableTypes: [NSPasteboard.PasteboardType] =
        [.fileURL, .png, .tiff] + NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }

    /// Курсор в конец страницы: туда встаёт то, что брошено ниже текста.
    func moveCaretToEnd() {
        textView.window?.makeFirstResponder(textView)
        textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
    }

    /// Файлы и картинки из перетаскивания или буфера становятся вложениями на месте курсора.
    /// `imageData: false` — данные изображения не берутся (при вставке, где рядом есть текст).
    @discardableResult
    func receiveFiles(from pasteboard: NSPasteboard, imageData: Bool = true) -> Bool {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            insertFiles(urls)
            return true
        }
        let fm = FileManager.default
        if let promises = pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self]) as? [NSFilePromiseReceiver], !promises.isEmpty {
            let dir = fm.temporaryDirectory.appendingPathComponent("drop-\(UUID().uuidString)", isDirectory: true)
            guard (try? fm.createDirectory(at: dir, withIntermediateDirectories: true)) != nil else { return false }
            let queue = OperationQueue()
            queue.qualityOfService = .userInitiated
            let group = DispatchGroup()
            let lock = NSLock()
            var received: [URL] = []
            for promise in promises {
                // Обработчик вызывается для каждого файла обещания.
                for _ in 0..<max(1, promise.fileNames.count) { group.enter() }
                promise.receivePromisedFiles(atDestination: dir, options: [:], operationQueue: queue) { url, error in
                    if error == nil { lock.lock(); received.append(url); lock.unlock() }
                    group.leave()
                }
            }
            group.notify(queue: .main) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { try? fm.removeItem(at: dir); return }
                    if received.isEmpty {
                        try? fm.removeItem(at: dir)
                        self.onError?(NSLocalizedString("Не удалось получить файл от другого приложения.", comment: ""))
                    } else {
                        self.insertFiles(received.sorted { $0.lastPathComponent < $1.lastPathComponent }, cleanup: dir)
                    }
                }
            }
            return true
        }
        if imageData, let data = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff) {
            let dir = fm.temporaryDirectory.appendingPathComponent("drop-\(UUID().uuidString)", isDirectory: true)
            let file = dir.appendingPathComponent(NSLocalizedString("Изображение", comment: "") + ".png")
            let png = NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:]) ?? data
            guard (try? fm.createDirectory(at: dir, withIntermediateDirectories: true)) != nil, (try? png.write(to: file)) != nil else { return false }
            insertFiles([file], type: .image, cleanup: dir)
            return true
        }
        return false
    }

    /// Программы и сценарии не запускаются одним нажатием: файл показывается в Finder.
    static func isExecutable(_ url: URL) -> Bool {
        let risky: Set<String> = ["app", "command", "tool", "terminal", "sh", "bash", "zsh", "py", "pl", "rb", "scpt", "applescript", "workflow", "pkg", "mpkg", "dmg", "jar"]
        if risky.contains(url.pathExtension.lowercased()) { return true }
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .executable) || type.conforms(to: .application) || type.conforms(to: .script)
    }

    private func openAttachment(_ url: URL) {
        if Self.isExecutable(url) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    /// Тип блока для файла: картинка, видео или файл.
    static func attachmentType(for url: URL) -> BlockType {
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased()) else { return .file }
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .movie) { return .video }
        return .file
    }

    /// Видео: новый блок или карточка файла с видео, вставленная до появления проигрывателя.
    static func isVideo(_ block: Block) -> Bool {
        block.type == .video || (block.type == .file && attachmentType(for: URL(fileURLWithPath: AtomData.name(of: block))) == .video)
    }

    /// Плашка неделимого блока.
    private func cell(for block: Block) -> NSTextAttachmentCell? {
        if Self.isVideo(block) {
            let poster = poster(for: block)
            let failed = block.assetID.map(failedImages.contains) ?? true
            let duration = block.assetID.flatMap { videoDurations[$0] }.map(Self.durationText)
            return VideoBlockCell(poster: poster, loading: poster == nil && !failed, name: AtomData.name(of: block), duration: duration,
                                  ink: style.ink, muted: style.muted, line: style.line, soft: style.soft)
        }
        switch block.type {
        case .image:
            let picture = picture(for: block)
            return ImageBlockCell(picture: picture, loading: picture == nil && !failedImages.contains(block.assetID ?? UUID()), name: AtomData.name(of: block), ink: style.muted, line: style.line, soft: style.soft)
        case .file:
            let size = ByteCountFormatter.string(fromByteCount: AtomData.size(of: block), countStyle: .file)
            return FileBlockCell(name: AtomData.name(of: block), detail: size, ink: style.ink, muted: style.muted, line: style.line)
        case .table:
            return TableBlockCell(rows: AtomData.rows(of: block), ink: style.ink, line: style.line, soft: style.soft)
        case .synced:
            return SyncedCaptionCell(text: NSLocalizedString("Синхронизированный блок", comment: ""), color: style.accent)
        case .syncedRef:
            let info = session.syncedRefs[block.id]
            let t: (String) -> String = { NSLocalizedString($0, comment: "") }
            let text: String
            switch info?.reason {
            case .shown?: text = String(format: t("Копия синхронизированного блока · %@"), info?.title.isEmpty == false ? info!.title : t("Без названия"))
            case .samePage?: text = t("Копия синхронизированного блока: оригинал на этой странице")
            case .repeated?: text = t("Копия синхронизированного блока: содержимое показано выше")
            case .unavailable?: text = t("Оригинал недоступен: удалён или в корзине")
            case nil: text = t("Загрузка синхронизированного блока…")
            }
            return SyncedCaptionCell(text: text, color: info?.reason == .unavailable ? style.muted : style.accent)
        case .bookmark:
            let url = AtomData.url(of: block)
            return BookmarkBlockCell(title: AtomData.string("title", of: block) ?? url?.host ?? block.plainText,
                                     about: AtomData.string("description", of: block), address: url?.absoluteString ?? "",
                                     picture: picture(for: block), ink: style.ink, muted: style.muted, line: style.line)
        case .embed:
            let url = AtomData.url(of: block)
            return EmbedBlockCell(provider: url.map { LinkCard.embed($0).provider } ?? "", address: url?.absoluteString ?? block.plainText,
                                  ink: style.ink, muted: style.muted, line: style.line, soft: style.soft)
        case .columnList:
            let id = block.id
            return ColumnsPlaceholderCell { [weak self] in self?.columnHosts[id]?.contentHeight ?? 40 }
        case .databaseView where liveHost(for: block) != nil:
            return LiveViewPlaceholderCell(height: CGFloat(AtomData.viewHeight(of: block)), line: style.line)
        case .databaseView:
            // Ячейка спрашивает данные при каждой отрисовке: загрузка не меняет высоту и не сдвигает текст.
            return DatabaseViewBlockCell(summary: { [weak self] in self?.embedSummary?(block) }, ink: style.ink, muted: style.muted, line: style.line, soft: style.soft)
        default:
            return nil
        }
    }

    /// Миниатюра из кэша; при промахе загружается вне главного потока, затем плашка заменяется.
    private func picture(for block: Block) -> NSImage? {
        guard let id = block.assetID else { return nil }
        if let cached = imageCache.object(forKey: id as NSUUID) { return cached }
        guard !loadingImages.contains(id), !failedImages.contains(id) else { return nil }
        guard let url = assetURL?(id) else {
            failedImages.insert(id)
            return nil
        }
        loadingImages.insert(id)
        Task { @MainActor [weak self] in
            let image = await Task.detached(priority: .userInitiated) { () -> NSImage? in
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
                let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 1800]
                guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
                return NSImage(cgImage: cg, size: NSSize(width: CGFloat(cg.width) / 2, height: CGFloat(cg.height) / 2))
            }.value
            guard let self else { return }
            self.loadingImages.remove(id)
            if let image { self.imageCache.setObject(image, forKey: id as NSUUID) } else { self.failedImages.insert(id) }
            self.reloadAtoms(asset: id)
        }
        return nil
    }

    static func durationText(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return total >= 3600 ? String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60) : String(format: "%d:%02d", total / 60, total % 60)
    }

    /// Кадр-обложка видео: из кэша или загружается вне главного потока, затем плашка заменяется.
    private func poster(for block: Block) -> NSImage? {
        guard let id = block.assetID else { return nil }
        if let cached = imageCache.object(forKey: id as NSUUID) { return cached }
        guard !loadingImages.contains(id), !failedImages.contains(id) else { return nil }
        guard let url = assetURL?(id) else {
            failedImages.insert(id)
            return nil
        }
        loadingImages.insert(id)
        Task { @MainActor [weak self] in
            let result = await Task.detached(priority: .userInitiated) { () -> (NSImage, Double)? in
                let asset = AVURLAsset(url: url)
                guard let duration = try? await asset.load(.duration), duration.seconds.isFinite else { return nil }
                let generator = AVAssetImageGenerator(asset: asset)
                generator.appliesPreferredTrackTransform = true
                generator.maximumSize = CGSize(width: 1200, height: 1200)
                // Первый кадр часто чёрный: берётся кадр через секунду, у коротких — из середины.
                let at = CMTime(seconds: min(1, duration.seconds / 2), preferredTimescale: 600)
                guard let frame = try? await generator.image(at: at).image else { return nil }
                return (NSImage(cgImage: frame, size: NSSize(width: CGFloat(frame.width) / 2, height: CGFloat(frame.height) / 2)), duration.seconds)
            }.value
            guard let self else { return }
            self.loadingImages.remove(id)
            if let (image, seconds) = result {
                self.imageCache.setObject(image, forKey: id as NSUUID)
                self.videoDurations[id] = seconds
            } else {
                self.failedImages.insert(id)
            }
            self.reloadAtoms(asset: id)
        }
        return nil
    }

    /// Заменяет плашки блоков с этим вложением; текст и выделение не меняются.
    private func reloadAtoms(asset: UUID) {
        guard let storage = textView.textStorage, !textView.hasMarkedText() else { return }
        let selected = textView.selectedRange()
        applying = true
        for span in spans {
            guard let block = document.block(span.id), block.assetID == asset, span.end <= storage.length else { continue }
            storage.replaceCharacters(in: NSRange(location: span.location, length: span.length), with: style.render(block, depth: depths[block.id] ?? 0))
        }
        textView.setSelectedRange(selected)
        applying = false
        updateHeight()
    }

    private func moveCurrentBlock(down: Bool) {
        guard let id = topSelectedBlockIDs().first, let block = document.block(id) else { return }
        let siblings = document.blocks.filter { $0.parentID == block.parentID }
        guard let i = siblings.firstIndex(where: { $0.id == id }) else { return }
        if down {
            guard i + 1 < siblings.count else { return }
            perform(.moveBlock(id, parent: block.parentID, after: siblings[i + 1].id))
        } else {
            guard i > 0 else { return }
            perform(.moveBlock(id, parent: block.parentID, after: i >= 2 ? siblings[i - 2].id : nil))
        }
        // Курсор остаётся внутри перемещённого блока.
        restoreCaret(block: id, offset: 0)
    }

    // MARK: Перетаскивание блоков

    /// Куда встанет блок при отпускании в точке: выше или ниже блока под ней.
    func dropTarget(at point: NSPoint) -> (after: UUID?, parent: UUID?, y: CGFloat)? {
        guard !spans.isEmpty else { return nil }
        var best: (span: Span, rect: NSRect)?
        for span in spans {
            guard let rect = blockRect(for: span) else { continue }
            best = (span, rect)
            if point.y < rect.maxY { break }
        }
        guard let (span, rect) = best, let block = document.block(span.id) else { return nil }
        if point.y < rect.midY {
            let siblings = document.blocks.filter { $0.parentID == block.parentID }
            let i = siblings.firstIndex { $0.id == block.id } ?? 0
            return (i > 0 ? siblings[i - 1].id : nil, block.parentID, rect.minY)
        }
        return (block.id, block.parentID, rect.maxY)
    }

    func finishDrag(_ id: UUID, at point: NSPoint) {
        // Ряд колонок в колонку не кладётся: колонки внутри колонок не поддерживаются.
        if scope != nil, document.block(id)?.type == .columnList { return }
        if let edge = columnDrop(at: point, dragging: id) {
            // Блок уходит из своей колонки: опустевшая колонка убирается тем же шагом отмены.
            var commands: [EditCommand] = [.makeColumns(target: edge.target, dropped: id, left: edge.left)]
            if let column = document.block(id)?.parentID.flatMap({ document.block($0) }), column.type == .column, let row = column.parentID {
                commands.append(.tidyColumns(row))
            }
            perform(.batch(commands))
            return
        }
        guard let target = dropTarget(at: point), target.after != id, let block = document.block(id) else { return }
        // То же место — не правка: нет записи и лишнего шага отмены.
        let siblings = document.blocks.filter { $0.parentID == block.parentID }
        let previous = siblings.firstIndex { $0.id == id }.flatMap { $0 > 0 ? siblings[$0 - 1].id : nil }
        if target.parent == block.parentID, target.after == previous { return }
        // Блок мог прийти из колонки (из другого поля): опустевшая колонка убирается тем же шагом отмены.
        var commands: [EditCommand] = [.moveBlock(id, parent: target.parent, after: target.after)]
        if let column = block.parentID.flatMap({ document.block($0) }), column.type == .column, let row = column.parentID, target.parent != column.id {
            commands.append(.tidyColumns(row))
        }
        perform(commands.count == 1 ? commands[0] : .batch(commands))
    }

    // MARK: Выделение блоков через поля (M13)

    /// Выделение мышью ушло в другое поле: выделяются целые блоки от первого до последнего, как в Notion.
    func selectBlocks(from a: UUID, to b: UUID) {
        guard let i = document.index(of: a), let j = document.index(of: b) else { return }
        let range = document.blocks[min(i, j)...max(i, j)]
        session.setBlockSelection(range.filter { $0.type != .column && $0.type != .columnList }.map(\.id))
        textView.setSelectedRange(NSRange(location: textView.selectedRange().location, length: 0))
    }

    var hasBlockSelection: Bool { !session.blockSelection.isEmpty }

    func clearBlockSelection() { if hasBlockSelection { session.setBlockSelection([]) } }

    /// Фрагменты выделенных блоков: с начала первого до конца последнего, колонки — по очереди.
    private func blockSelectionFragments() -> [BlockFragment] {
        let ids = session.blockSelection
        guard let first = ids.first, let last = ids.last, let end = document.block(last) else { return [] }
        var sel = BlockSelection(block: first, offset: 0)
        sel.focus = BlockPoint(blockID: last, offset: RichText.length(end.content?.runs ?? []) + (end.content == nil ? 1 : 0))
        return document.fragments(in: sel)
    }

    /// Удаление выделенных блоков одной правкой; опустевшие колонки убираются.
    func deleteBlockSelection() {
        let chosen = Set(session.blockSelection)
        let top = session.blockSelection.compactMap { document.block($0) }.filter { b in
            var p = b.parentID
            while let id = p { if chosen.contains(id) { return false }; p = document.block(id)?.parentID }
            return true
        }
        var rows: [UUID] = []
        for b in top {
            if let c = b.parentID.flatMap({ document.block($0) }), c.type == .column, let row = c.parentID, !rows.contains(row) { rows.append(row) }
        }
        session.setBlockSelection([])
        guard !top.isEmpty else { return }
        // Страница без строк получает пустой абзац той же правкой: одна отмена возвращает всё.
        var gone = Set(top.map(\.id))
        for b in top { gone.formUnion(document.descendants(of: b.id).map(\.id)) }
        let left = document.blocks.contains { !gone.contains($0.id) && $0.type != .column && $0.type != .columnList }
        var commands: [EditCommand] = top.map { .deleteBlock($0.id) } + rows.map { .tidyColumns($0) }
        if !left { commands.append(.insertBlock(after: nil, type: .paragraph)) }
        perform(.batch(commands))
    }

    /// Ручка блока в левом поле.
    func handleRect(for span: Span) -> NSRect? {
        guard let line = firstLineRect(for: span), let block = document.block(span.id) else { return nil }
        let x = textView.textContainerOrigin.x + CGFloat(depths[block.id] ?? 0) * BlockTextStyle.nestIndent - 20
        return NSRect(x: x, y: line.minY, width: 16, height: 18)
    }

    /// Блок на высоте курсора мыши. Вызывается на каждое движение, поэтому без перебора всех блоков.
    func block(atY y: CGFloat) -> Span? {
        guard let manager = textView.layoutManager, let container = textView.textContainer, !spans.isEmpty else { return nil }
        let glyphs = manager.glyphRange(forBoundingRect: NSRect(x: 0, y: max(0, y - textView.textContainerOrigin.y - 1), width: container.size.width, height: 2), in: container)
        guard glyphs.length > 0 else { return spans.last }
        return spans[spanIndex(at: manager.characterIndexForGlyph(at: glyphs.location))]
    }

    func span(withID id: UUID) -> Span? { spans.first { $0.id == id } }

    func drawHandle(for span: Span) {
        guard let rect = handleRect(for: span) else { return }
        style.muted.setFill()
        for row in 0..<3 {
            for column in 0..<2 {
                NSBezierPath(ovalIn: NSRect(x: rect.minX + 4 + CGFloat(column) * 5, y: rect.minY + 3 + CGFloat(row) * 5, width: 2.5, height: 2.5)).fill()
            }
        }
    }

    /// После разделителя нужна строка для ввода, если он оказался последним.
    private func ensureTextAfterAtom() {
        if let last = document.blocks.last, last.type.isAtom {
            perform(.insertBlock(after: last.id, type: .paragraph))
        } else if let at = session.selection?.anchor.blockID, let i = document.index(of: at), i + 1 < document.blocks.count {
            textView.setSelectedRange(NSRange(location: spans.first { $0.id == document.blocks[i + 1].id }?.location ?? 0, length: 0))
        }
    }

    private func caretKeep(_ range: NSRange) {
        textView.setSelectedRange(NSRange(location: min(range.location, textView.textStorage?.length ?? 0), length: range.length))
    }

    private func selectedBlockIDs() -> [UUID] {
        let range = textView.selectedRange()
        let a = spanIndex(at: range.location)
        var b = spanIndex(at: range.location + range.length)
        // Строка целиком заканчивается в начале следующего блока; он не выделен.
        if range.length > 0, b > a, spans[b].location == range.location + range.length { b -= 1 }
        return spans[a...b].map(\.id)
    }

    /// Выбранные блоки без потомков других выбранных: вложенность и удаление применяются к поддереву целиком.
    private func topSelectedBlockIDs() -> [UUID] {
        let ids = selectedBlockIDs()
        let set = Set(ids)
        return ids.filter { id in
            var p = document.block(id)?.parentID
            while let current = p {
                if set.contains(current) { return false }
                p = document.block(current)?.parentID
            }
            return true
        }
    }

    private func currentLink(in range: NSRange) -> String? {
        (textView.textStorage?.attribute(.link, at: range.location, effectiveRange: nil) as? URL)?.absoluteString
    }

    /// Метка символа слева от курсора: набор продолжает его оформление.
    private func markAtCaret(_ mark: String) -> Bool {
        let here = point(at: textView.selectedRange().location)
        guard here.offset > 0, let c = document.block(here.blockID)?.content else { return false }
        return RichText.hasMark(c.runs, range: (here.offset - 1)..<here.offset, mark)
    }

    func isMarked(_ mark: String) -> Bool {
        let range = textView.selectedRange()
        if range.length == 0 { return (markAtCaret(mark) && !pendingRemoved.contains(mark)) || pendingMarks.contains(mark) }
        let sel = selection(for: range)
        guard let (start, end) = document.ordered(sel), let si = document.index(of: start.blockID), let ei = document.index(of: end.blockID) else { return false }
        for b in document.blocks[si...ei] {
            guard let c = b.content else { continue }
            let lower = b.id == start.blockID ? start.offset : 0
            let upper = b.id == end.blockID ? end.offset : RichText.length(c.runs)
            if upper > lower, !RichText.hasMark(c.runs, range: lower..<upper, mark) { return false }
        }
        return true
    }

    // MARK: Правка текста внутри блока

    /// Несколько диапазонов одной правкой (прямоугольное выделение, поиск): разбиение на блоки так не обновить.
    func textView(_ view: NSTextView, shouldChangeTextInRanges ranges: [NSValue], replacementStrings: [String]?) -> Bool {
        guard ranges.count == 1 else { return applying }
        return self.textView(view, shouldChangeTextIn: ranges[0].rangeValue, replacementString: replacementStrings?.first)
    }

    func textView(_ view: NSTextView, shouldChangeTextIn range: NSRange, replacementString: String?) -> Bool {
        if applying { return true }
        clearBlockSelection()
        guard let text = replacementString else { return false } // Только атрибуты: их источник — модель.
        let start = spanIndex(at: range.location)
        pendingIndex = start
        editingIndex = start
        typedText = range.length == 0 ? text : nil
        // Если AppKit не сообщит об изменении (правка оказалась пустой), выделение не должно замолчать.
        DispatchQueue.main.async { [weak self] in self?.pendingIndex = nil }
        if view.hasMarkedText() { return true }
        let endIndex = spanIndex(at: range.location + range.length)
        let block = document.block(spans[start].id)
        // Пробел в пустом абзаце открывает поле ИИ (FR-AI-4); сам пробел не вводится и не попадает в отмену.
        if text == " ", range.length == 0, slash == nil, block?.type == .paragraph, block?.content != nil, spans[start].length == 0,
           aiAvailable?() == true, let ask = onAIRequest {
            pendingIndex = nil
            typedText = nil
            DispatchQueue.main.async { [weak self] in if let self { ask(self, range) } }
            return false
        }
        // Упоминание неделимо: правка его части берёт его целиком, вставка внутрь уходит за его конец.
        if start == endIndex, let content = block?.content {
            let local = (range.location - spans[start].location)..<(range.location + range.length - spans[start].location)
            if let whole = Mention.atomic(local, in: content.runs) {
                pendingIndex = nil
                typedText = nil
                replaceWithCommand(range: NSRange(location: spans[start].location + whole.lowerBound, length: whole.count), text: text)
                return false
            }
        }
        if start == endIndex, block?.isEditable == true, !BlockFragment.containsLineSeparator(text) { return true }
        // Граница блока или неделимый блок: штатная правка испортила бы структуру.
        pendingIndex = nil
        replaceWithCommand(range: range, text: text)
        return false
    }

    /// В блоке кода перевод строки остаётся внутри блока.
    private func isInsideCode(_ range: NSRange) -> Bool {
        let a = spanIndex(at: range.location)
        return a == spanIndex(at: range.location + range.length) && document.block(spans[a].id)?.type == .code
    }

    private func replaceWithCommand(range: NSRange, text: String) {
        let fragments = text.isEmpty ? [] : (isInsideCode(range) ? BlockFragment.codeText(text) : BlockFragment.lines(text))
        perform(.replaceRange(selection(for: range), fragments))
    }

    func textDidChange(_ notification: Notification) {
        guard !applying, let index = pendingIndex ?? editingIndex, spans.indices.contains(index) else { return }
        pendingIndex = nil
        adjustSpans(at: index)
        if !textView.hasMarkedText() { commitText(at: index) }
        applyTypingAttributes()
        updateHeight()
        updateAIHint()
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
            let before = document.block(span.id)?.plainText ?? ""
            try session.perform(.setPlainText(block: span.id, text: BlockTextMapping.toModel(text)))
            visible = computeVisible()
            session.updateSelection(selection(for: textView.selectedRange()))
            applyPendingMarks(block: span.id, before: before)
            afterTyping(block: span.id)
        } catch {
            onError?((error as? LocalizedError)?.errorDescription ?? "\(error)")
        }
    }

    /// ⌘B при пустом выделении действует на следующий введённый текст.
    private func applyPendingMarks(block id: UUID, before: String) {
        guard !pendingMarks.isEmpty || !pendingRemoved.isEmpty, let typed = typedText, !typed.isEmpty else { return }
        let caret = textView.selectedRange().location
        let length = typed.utf16.count
        var sel = selection(for: NSRange(location: max(0, caret - length), length: 0))
        sel.focus = point(at: caret)
        let edit = EditCommand.typedMarks(sel, add: Array(pendingMarks), remove: Array(pendingRemoved))
        do { try session.perform(edit) } catch { return }
        syncView()
        textView.setSelectedRange(NSRange(location: caret, length: 0))
    }

    /// Markdown-сокращения и меню «/» срабатывают только на только что введённый символ.
    private func afterTyping(block id: UUID) {
        guard let typed = typedText else { updateSlash(); return }
        typedText = nil
        guard let block = document.block(id), let content = block.content else { return }
        let caret = textView.selectedRange().location
        guard let span = spans.first(where: { $0.id == id }) else { return }
        let offset = caret - span.location
        let text = content.plainText

        if typed == "/", block.type != .code, slash == nil {
            let before = (text as NSString).substring(to: max(0, offset - 1))
            if before.isEmpty || before.last?.isWhitespace == true {
                slash = SlashState(blockID: id, slashOffset: offset - 1, query: "", selected: 0)
            }
        }
        if typed == "[", block.type != .code, slash == nil, offset >= 2, (text as NSString).substring(with: NSRange(location: offset - 2, length: 2)) == "[[" {
            slash = SlashState(kind: .pageLink, blockID: id, slashOffset: offset - 2, query: "", selected: 0)
        }
        if typed == "@", block.type != .code, slash == nil {
            let before = (text as NSString).substring(to: max(0, offset - 1))
            if before.isEmpty || before.last?.isWhitespace == true {
                slash = SlashState(kind: .mention, blockID: id, slashOffset: offset - 1, query: "", selected: 0)
            }
        }
        if slash != nil { updateSlash(); return }

        guard block.type == .paragraph else { return }
        let shortcuts: [(String, BlockType)] = [("# ", .heading1), ("## ", .heading2), ("### ", .heading3), ("- ", .bullet), ("* ", .bullet),
                                                ("1. ", .numbered), ("[] ", .task), ("[ ] ", .task), ("> ", .quote), ("``` ", .code)]
        if typed == " ", let hit = shortcuts.first(where: { $0.0.utf16.count == offset && text.hasPrefix($0.0) }) {
            var range = BlockSelection(block: id, offset: 0)
            range.focus = BlockPoint(blockID: id, offset: offset)
            perform(.batch([.replaceRange(range, []), .changeType(block: id, type: hit.1)]))
            return
        }
        if typed == "-", text == "---", !document.blocks.contains(where: { $0.parentID == id }) {
            // Текст убирается, блок становится разделителем, ввод продолжается ниже.
            perform(.batch([.insertBlock(after: id, type: .divider), .deleteBlock(id)]))
            ensureTextAfterAtom()
        }
    }

    // MARK: Меню «/»

    private func updateSlash() {
        guard var state = slash else { return }
        guard let block = document.block(state.blockID), let content = block.content else { return closeSlash() }
        let caret = textView.selectedRange().location
        let trigger = state.kind == .blocks ? "/" : state.kind == .mention ? "@" : "[["
        guard let span = spans.first(where: { $0.id == state.blockID }), caret >= span.location + state.slashOffset + trigger.utf16.count, caret <= span.end else { return closeSlash() }
        let text = content.plainText as NSString
        guard text.length >= state.slashOffset + trigger.utf16.count, text.substring(with: NSRange(location: state.slashOffset, length: trigger.utf16.count)) == trigger else { return closeSlash() }
        let queryStart = state.slashOffset + trigger.utf16.count
        state.query = text.substring(with: NSRange(location: queryStart, length: caret - span.location - queryStart))
        let items = slashItems(state)
        guard !items.isEmpty, !state.query.contains("\n") else { return closeSlash() }
        state.selected = min(state.selected, items.count - 1)
        slash = state
        onSlashChange?(state, items, caretRectOnScreen())
    }

    private func slashItems(_ state: SlashState) -> [EditorAction.Item] {
        switch state.kind {
        case .blocks: return EditorAction.filterSlash(state.query)
        case .pageLink:
            return (pageSearch?(state.query) ?? []).map { EditorAction.Item(title: $0.title.isEmpty ? NSLocalizedString("Без названия", comment: "") : $0.title, action: .linkPage($0.id, $0.title)) }
        case .mention:
            return mentionItems(state.query)
        }
    }

    /// Пункты «@»: даты, люди, страницы — как в Notion; запрос сужает все три списка.
    private func mentionItems(_ query: String) -> [EditorAction.Item] {
        let t: (String) -> String = { NSLocalizedString($0, comment: "") }
        let key = SearchText.normalize(query.trimmingCharacters(in: .whitespaces))
        func fits(_ text: String, _ aliases: [String] = []) -> Bool {
            key.isEmpty || ([text] + aliases).contains { SearchText.normalize($0).contains(key) }
        }
        let today = LocalDate(date: Date(), in: .current)
        var items: [EditorAction.Item] = []
        if fits(t("Сегодня"), ["today", "дата"]) { items.append(EditorAction.Item(title: t("Сегодня"), action: .mentionDate(today.iso))) }
        if fits(t("Завтра"), ["tomorrow", "дата"]) { items.append(EditorAction.Item(title: t("Завтра"), action: .mentionDate(today.adding(days: 1).iso))) }
        if fits(t("Дата или напоминание…"), ["date", "remind", "дата", "напомнить"]) {
            items.append(EditorAction.Item(title: t("Дата или напоминание…"), action: .pickMentionDate))
        }
        for person in (peopleSource?() ?? []) where fits(person.name) {
            items.append(EditorAction.Item(title: "@" + person.name, action: .mentionPerson(person)))
        }
        for page in (pageSearch?(query) ?? []).prefix(8) {
            items.append(EditorAction.Item(title: "↗ " + (page.title.isEmpty ? t("Без названия") : page.title), action: .mentionPage(page.id, page.title)))
        }
        return items
    }

    func closeSlash() {
        guard slash != nil else { return }
        slash = nil
        onSlashChange?(nil, [], .zero)
    }

    func moveSlashSelection(by delta: Int) {
        guard var state = slash else { return }
        let items = slashItems(state)
        guard !items.isEmpty else { return }
        state.selected = (state.selected + delta + items.count) % items.count
        slash = state
        onSlashChange?(state, items, caretRectOnScreen())
    }

    /// Применяет пункт меню: убирает «/запрос» и выполняет действие одной правкой.
    func chooseSlash(_ index: Int? = nil) {
        guard let state = slash else { return }
        let items = slashItems(state)
        let i = index ?? state.selected
        guard items.indices.contains(i), let span = spans.first(where: { $0.id == state.blockID }) else { return closeSlash() }
        let action = items[i].action
        closeSlash()
        var cut = BlockSelection(block: state.blockID, offset: state.slashOffset)
        cut.focus = BlockPoint(blockID: state.blockID, offset: span.length)
        let tailLength = span.end - textView.selectedRange().location
        cut.focus.offset = span.length - tailLength
        switch action {
        case let .linkPage(id, title):
            let shown = title.isEmpty ? NSLocalizedString("Без названия", comment: "") : title
            perform(.replaceRange(cut, [BlockFragment(type: .paragraph, content: BlockContent(runs: [TextRun(shown, marks: [PageLink.mark(id)])]))]))
            // Набор после ссылки идёт обычным текстом.
            pendingRemoved.insert(PageLink.mark(id))
        case .beginPageLink:
            perform(.replaceRange(cut, []))
            run(.beginPageLink)
        case .mentionPage, .mentionPerson, .mentionDate:
            // «@запрос» заменяется упоминанием одной правкой.
            let run: TextRun?
            switch action {
            case let .mentionPage(page, title): run = Mention.page(page, title: title)
            case let .mentionPerson(person): run = Mention.person(person)
            case let .mentionDate(iso): run = Mention.date(iso, label: Self.dateLabel(iso))
            default: run = nil
            }
            if let run { perform(.replaceRange(cut, [BlockFragment(type: .paragraph, content: BlockContent(runs: [run, TextRun(" ")]))])) }
        case .turnInto(let type):
            perform(.batch([.replaceRange(cut, []), .changeType(block: state.blockID, type: type)]))
        case .insert(let type):
            let wholeText = span.length == state.slashOffset + (cut.focus.offset - state.slashOffset) && state.slashOffset == 0
            let hasChildren = document.blocks.contains { $0.parentID == state.blockID }
            var commands: [EditCommand] = [.replaceRange(cut, []), .insertBlock(after: state.blockID, type: type)]
            if wholeText, !hasChildren { commands.append(.deleteBlock(state.blockID)) } // Пустая строка заменяется блоком.
            perform(.batch(commands))
            ensureTextAfterAtom()
        default:
            perform(.replaceRange(cut, []))
            run(action)
        }
    }

    private func caretRectOnScreen() -> NSRect {
        var actual = NSRange()
        return textView.firstRect(forCharacterRange: textView.selectedRange(), actualRange: &actual)
    }

    /// Прямоугольник диапазона на экране: под ним встаёт панель ИИ.
    func screenRect(for range: NSRange) -> NSRect {
        var actual = NSRange()
        let first = textView.firstRect(forCharacterRange: NSRange(location: range.location, length: 0), actualRange: &actual)
        guard range.length > 0 else { return first }
        let last = textView.firstRect(forCharacterRange: NSRange(location: range.location + range.length, length: 0), actualRange: &actual)
        return NSRect(x: first.minX, y: min(first.minY, last.minY), width: max(first.width, 1), height: abs(first.maxY - min(first.minY, last.minY)))
    }

    /// ⌘J и кнопка «Спросить ИИ»: выделенный текст или текущая строка.
    func requestAI() {
        guard aiAvailable?() == true, let ask = onAIRequest, !spans.isEmpty else { return }
        if textView.hasMarkedText() { textView.unmarkText() }
        closeSlash()
        ask(self, textView.selectedRange())
    }

    /// Применяет ответ ИИ одной правкой отмены: замена диапазона или вставка блоков ниже него.
    /// Диапазон сверяется с исходным текстом: если текст изменился, правка не выполняется.
    @discardableResult
    func applyAI(range: NSRange, expected: String, fragments: [BlockFragment], below: Bool) -> Bool {
        let length = (textView.string as NSString).length
        guard range.location + range.length <= length, (textView.string as NSString).substring(with: range) == expected else {
            onError?(NSLocalizedString("Текст изменился, пока ИИ отвечал. Попробуйте снова.", comment: ""))
            return false
        }
        guard !fragments.isEmpty else { return false }
        if below {
            let end = point(at: range.location + range.length)
            let span = spans[spanIndex(at: range.location + range.length)]
            let atEnd = BlockSelection(block: end.blockID, offset: span.length)
            // Пустой первый фрагмент оставляет блок как есть: ответ встаёт следующими блоками.
            let empty = BlockFragment(type: .paragraph, content: BlockContent())
            return perform(.replaceRange(atEnd, [empty] + fragments))
        }
        return perform(.replaceRange(selection(for: range), fragments))
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
        if snapCaretOutOfMention() { return }
        if !textView.hasMarkedText() {
            editingIndex = spanIndex(at: textView.selectedRange().location)
            session.updateSelection(selection(for: textView.selectedRange()))
            // Движение курсора сбрасывает ожидание; новый ввод его не сбрасывает.
            if typedText == nil { pendingMarks = []; pendingRemoved = [] }
        }
        applyTypingAttributes()
        if slash != nil { updateSlash() }
        reportSelection()
        updateAIHint()
    }

    /// Подсказка «пробел для ИИ» у курсора в пустом абзаце (FR-AI-4); без ИИ её нет.
    func updateAIHint() {
        textView.aiHintRect = aiHintRect()
    }

    private func aiHintRect() -> NSRect? {
        guard aiAvailable?() == true, textView.window?.firstResponder === textView, !textView.hasMarkedText(), slash == nil, !spans.isEmpty else { return nil }
        let range = textView.selectedRange()
        guard range.length == 0 else { return nil }
        let span = spans[spanIndex(at: range.location)]
        guard span.length == 0, let block = document.block(span.id), block.type == .paragraph, block.content != nil,
              let window = textView.window else { return nil }
        var actual = NSRange()
        let screen = textView.firstRect(forCharacterRange: range, actualRange: &actual)
        let local = textView.convert(window.convertFromScreen(screen), from: nil)
        let size = (BlockTextView.aiHint as NSString).size(withAttributes: textView.aiHintAttributes)
        return NSRect(x: local.minX + 1, y: min(local.minY, local.maxY), width: size.width + 2, height: max(size.height, abs(local.height)))
    }

    /// Курсор не останавливается внутри упоминания: выходит к краю в сторону движения.
    private func snapCaretOutOfMention() -> Bool {
        let range = textView.selectedRange()
        defer { lastCaret = textView.selectedRange().location }
        guard range.length == 0, !textView.hasMarkedText() else { return false }
        let index = spanIndex(at: range.location)
        guard spans.indices.contains(index), let content = document.block(spans[index].id)?.content else { return false }
        let local = range.location - spans[index].location
        guard let hit = Mention.ranges(in: content.runs).first(where: { $0.lowerBound < local && local < $0.upperBound }) else { return false }
        let forward = range.location >= lastCaret
        let target = spans[index].location + (forward ? hit.upperBound : hit.lowerBound)
        textView.setSelectedRange(NSRange(location: target, length: 0))
        return true
    }

    private func reportSelection() {
        let range = textView.selectedRange()
        guard range.length > 0, textView.window != nil else { return onSelectionRect?(nil) ?? () }
        var actual = NSRange()
        onSelectionRect?(textView.firstRect(forCharacterRange: range, actualRange: &actual))
    }

    /// Новый текст получает оформление своего блока, а не соседнего.
    private func applyTypingAttributes() {
        guard !textView.hasMarkedText(), !spans.isEmpty,
              let block = document.block(spans[spanIndex(at: textView.selectedRange().location)].id) else { return }
        // Набор продолжает оформление символа слева, как и правка в модели.
        let location = textView.selectedRange().location
        let span = spans[spanIndex(at: location)]
        var attrs: [NSAttributedString.Key: Any]
        if location > span.location, block.isEditable, let storage = textView.textStorage, location <= storage.length {
            attrs = storage.attributes(at: location - 1, effectiveRange: nil)
            attrs[.link] = nil
            if attrs[BlockTextStyle.mentionKey] != nil { attrs = style.attributes(for: block.type, depth: depths[block.id] ?? 0) }
        } else {
            attrs = style.attributes(for: block.type, depth: depths[block.id] ?? 0)
        }
        if !pendingMarks.isEmpty { attrs = style.attributes(base: attrs, marks: Array(pendingMarks)) }
        textView.typingAttributes = attrs
    }

    func textDidEndEditing(_ notification: Notification) {
        closeSlash()
        onSelectionRect?(nil)
        if !textView.hasMarkedText(), let index = editingIndex { commitText(at: index) }
    }

    /// Внутренние ссылки открывают страницу; внешние — системный браузер, только по нажатию.
    func textView(_ view: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        let url = (link as? URL) ?? (link as? String).flatMap(URL.init(string:))
        if let url, url.absoluteString.hasPrefix("notes://comment/"), let thread = UUID(uuidString: url.lastPathComponent) {
            onOpenComment?(thread)
            return true
        }
        guard let url, let page = PageLink.page(from: url) else { return false }
        // ⌥-щелчок открывает страницу сбоку (Peek), не уходя с текущей.
        if NSEvent.modifierFlags.contains(.option), let peek = onPeekLink { peek(page); return true }
        onOpenLink?(page, PageLink.block(from: url))
        return true
    }

    /// Показывает блок: переход из поиска и обратных ссылок.
    func reveal(_ block: UUID) {
        guard let span = spans.first(where: { $0.id == block }) else { return }
        textView.setSelectedRange(NSRange(location: span.location, length: 0))
        textView.scrollRangeToVisible(NSRange(location: span.location, length: span.length))
        textView.showFindIndicator(for: NSRange(location: span.location, length: span.length))
    }

    // MARK: Клавиши

    func textView(_ view: NSTextView, doCommandBy selector: Selector) -> Bool {
        if slash != nil {
            switch selector {
            case #selector(NSResponder.moveDown(_:)): moveSlashSelection(by: 1); return true
            case #selector(NSResponder.moveUp(_:)): moveSlashSelection(by: -1); return true
            case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertTab(_:)): chooseSlash(); return true
            case #selector(NSResponder.cancelOperation(_:)): closeSlash(); return true
            default: break
            }
        }
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
            } else if block?.type == .code {
                view.insertText(BlockTextMapping.lineBreak, replacementRange: range) // В коде Enter — новая строка.
            } else if let b = block, b.plainText.isEmpty, [.task, .bullet, .numbered, .toggle].contains(b.type) {
                if b.parentID != nil {
                    perform(.outdent(b.id))
                    restoreCaret(block: b.id, offset: 0)
                } else {
                    perform(.changeType(block: b.id, type: .paragraph))
                }
            } else {
                perform(.splitBlock(here))
            }
            return true
        case #selector(NSResponder.insertLineBreak(_:)):
            view.insertText(BlockTextMapping.lineBreak, replacementRange: range)
            return true
        case #selector(NSResponder.insertTab(_:)):
            if block?.type == .code { view.insertText("    ", replacementRange: range) } else { run(.indent) }
            return true
        case #selector(NSResponder.insertBacktab(_:)):
            run(.outdent)
            return true
        case #selector(NSResponder.deleteBackward(_:)) where hasBlockSelection, #selector(NSResponder.deleteForward(_:)) where hasBlockSelection:
            deleteBlockSelection()
            return true
        case #selector(NSResponder.cancelOperation(_:)) where hasBlockSelection:
            clearBlockSelection()
            return true
        case #selector(NSResponder.deleteBackward(_:)):
            guard range.length == 0, here.offset == 0 else { return false }
            if let b = block, b.isEditable, b.type != .paragraph {
                perform(.changeType(block: b.id, type: .paragraph)) // Сначала снимается тип блока.
            } else if let b = block, b.isEditable, let parent = b.parentID, document.block(parent)?.type != .column {
                perform(.outdent(b.id)) // Затем уменьшается вложенность.
                restoreCaret(block: b.id, offset: 0)
            } else if let b = block, b.isEditable {
                perform(.mergeBackward(block: b.id)) // Команда сама выбирает предыдущий видимый блок.
            } else {
                return false
            }
            return true
        case #selector(NSResponder.deleteForward(_:)):
            guard range.length == 0, let i = spans.firstIndex(where: { $0.id == here.blockID }),
                  here.offset == spans[i].length, i + 1 < spans.count, block?.isEditable == true else { return false }
            // Со следующим неделимым блоком не объединяем: его данные важнее.
            guard document.block(spans[i + 1].id)?.isEditable == true, block?.isCollapsed != true else { return true }
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

    /// Адрес с кириллицей кодируется: иначе URL не разберётся и ссылка не откроется.
    static func encodedAddress(_ text: String) -> String? {
        if text.isEmpty { return "" }
        if URL(string: text) != nil { return text }
        return text.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed.union(.urlPathAllowed).union(CharacterSet(charactersIn: ":?#")))
    }

    // MARK: Буфер обмена

    func copy(to pasteboard: NSPasteboard) {
        let range = textView.selectedRange()
        let fragments: [BlockFragment]
        if hasBlockSelection {
            fragments = blockSelectionFragments()
        } else {
            guard range.length > 0 else { return }
            fragments = document.fragments(in: selection(for: range))
        }
        pasteboard.clearContents()
        pasteboard.declareTypes([Self.pasteboardType, .string], owner: nil)
        if let data = try? JSONEncoder().encode(fragments) { pasteboard.setData(data, forType: Self.pasteboardType) }
        pasteboard.setString(BlockFragment.plainText(fragments), forType: .string)
    }

    func cut(to pasteboard: NSPasteboard) {
        if hasBlockSelection {
            copy(to: pasteboard)
            deleteBlockSelection()
            return
        }
        guard textView.selectedRange().length > 0 else { return }
        copy(to: pasteboard)
        replaceCurrentSelection(with: [])
    }

    func paste(from pasteboard: NSPasteboard) {
        // Файлы и картинки из буфера становятся вложениями; картинка — только если рядом нет текста.
        let onlyImage = pasteboard.data(forType: Self.pasteboardType) == nil && pasteboard.string(forType: .string) == nil
        if receiveFiles(from: pasteboard, imageData: onlyImage) { return }
        if pasteboard.data(forType: Self.pasteboardType) == nil, let text = pasteboard.string(forType: .string) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if let url = URL(string: trimmed), let page = PageLink.page(from: url) {
                // Ссылка на блок: подпись — заголовок страницы.
                let title = pageSearch?("").first { $0.id == page }?.title ?? NSLocalizedString("Ссылка", comment: "")
                let mark = "a:\(trimmed)"
                return replaceCurrentSelection(with: [BlockFragment(type: .paragraph, content: BlockContent(runs: [TextRun(title, marks: [mark])]))])
            }
            // Один адрес без выделения: ссылка, закладка или встраивание, как в Notion.
            if textView.selectedRange().length == 0, let url = LinkCard.url(trimmed), trimmed.hasPrefix("http"), let choose = chooseLinkKind {
                switch choose(url) {
                case .bookmark?: return insertLinkCard(.bookmark, url: url)
                case .embed?: return insertLinkCard(.embed, url: url)
                case .paragraph?:
                    return replaceCurrentSelection(with: [BlockFragment(type: .paragraph, content: BlockContent(runs: [TextRun(trimmed, marks: ["a:" + url.absoluteString])]))])
                default: break
                }
            }
            // Адрес поверх выделенного текста делает его ссылкой.
            if textView.selectedRange().length > 0, let address = Self.encodedAddress(trimmed), let scheme = URL(string: address)?.scheme, ["http", "https", "mailto"].contains(scheme) {
                perform(.formatText(selection(for: textView.selectedRange()), .setValue(prefix: "a:", value: address)))
                return
            }
        }
        if let data = pasteboard.data(forType: Self.pasteboardType),
           let fragments = try? JSONDecoder().decode([BlockFragment].self, from: data), !fragments.isEmpty {
            replaceCurrentSelection(with: fragments)
        } else if let text = pasteboard.string(forType: .string), !text.isEmpty {
            replaceCurrentSelection(with: isInsideCode(textView.selectedRange()) ? BlockFragment.codeText(text) : BlockFragment.lines(text))
        }
    }

    // MARK: Декор блоков

    /// Строка начала блока в координатах вида.
    private func firstLineRect(for span: Span) -> NSRect? {
        guard let manager = textView.layoutManager, let storage = textView.textStorage else { return nil }
        var line: NSRect
        if span.location >= storage.length {
            line = manager.extraLineFragmentUsedRect
        } else {
            line = manager.lineFragmentUsedRect(forGlyphAt: manager.glyphIndexForCharacter(at: span.location), effectiveRange: nil)
        }
        if line == .zero { return nil }
        line.origin.y += textView.textContainerOrigin.y
        return line
    }

    /// Весь блок в координатах вида.
    private func blockRect(for span: Span) -> NSRect? {
        guard let manager = textView.layoutManager, let container = textView.textContainer, var first = firstLineRect(for: span) else { return nil }
        if span.length > 0, span.end <= manager.numberOfGlyphs {
            let glyphs = manager.glyphRange(forCharacterRange: NSRange(location: span.location, length: span.length), actualCharacterRange: nil)
            first = first.union(manager.boundingRect(forGlyphRange: glyphs, in: container).offsetBy(dx: 0, dy: textView.textContainerOrigin.y))
        }
        return first
    }

    /// Квадрат маркера слева от текста блока.
    func markerRect(for span: Span) -> NSRect? {
        guard let line = firstLineRect(for: span), let block = document.block(span.id) else { return nil }
        let size = BlockTextStyle.checkboxSize
        let font = style.font(for: block.type)
        let top = line.minY + max(0, (font.ascender - font.descender - size) / 2)
        let x = textView.textContainerOrigin.x + CGFloat(depths[span.id] ?? 0) * BlockTextStyle.nestIndent
        return NSRect(x: x, y: top, width: size, height: size)
    }

    /// Нажатие на отметку или треугольник; true — нажатие обработано.
    func handleClick(at point: NSPoint, clickCount: Int = 1) -> Bool {
        guard let manager = textView.layoutManager, let container = textView.textContainer, !spans.isEmpty else { return false }
        let glyphRange = manager.glyphRange(forBoundingRect: NSRect(x: 0, y: point.y - 2, width: textView.bounds.width, height: 4), in: container)
        let index: Int
        if glyphRange.length == 0 {
            index = spans.count - 1 // Пустая последняя строка.
        } else {
            index = spanIndex(at: manager.characterIndexForGlyph(at: glyphRange.location))
        }
        let span = spans[index]
        guard let block = document.block(span.id), true else { return false }
        if block.content == nil {
            guard let rect = blockRect(for: span), rect.contains(point) else { return false }
            if Self.isVideo(block) {
                if let id = block.assetID, let url = assetURL?(id) {
                    if let play = onPlayVideo { play(url, AtomData.name(of: block)) } else { openAttachment(url) }
                }
                return true
            }
            switch block.type {
            case .file:
                if let id = block.assetID, let url = assetURL?(id) { openAttachment(url) }
                return true
            case .image:
                if clickCount >= 2, let id = block.assetID, let url = assetURL?(id) { openAttachment(url); return true }
                return false
            case .table:
                onEditTable?(block)
                return true
            case .databaseView:
                onOpenEmbed?(block)
                return true
            case .bookmark, .embed:
                if let url = AtomData.url(of: block) { onOpenURL?(url, block.type) }
                return true
            case .syncedRef:
                // Подпись копии ведёт к оригиналу.
                if let info = session.syncedRefs[block.id], info.reason != .unavailable { onOpenLink?(info.page, info.source) }
                return true
            default:
                return false
            }
        }
        guard let rect = markerRect(for: span), rect.insetBy(dx: -4, dy: -4).contains(point) else { return false }
        if block.type == .task {
            perform(.setChecked(block: block.id, checked: block.content?.checked != true))
            return true
        }
        if block.type == .toggle {
            let caret = textView.selectedRange()
            perform(.setCollapsed(block: block.id, collapsed: !block.isCollapsed))
            textView.setSelectedRange(NSRange(location: min(caret.location, textView.textStorage?.length ?? 0), length: 0))
            return true
        }
        return false
    }

    /// Фон выноски и кода, полоска цитаты: рисуются под текстом.
    func drawBackgrounds(in dirty: NSRect) {
        if hasBlockSelection {
            let chosen = Set(session.blockSelection)
            NSColor.controlAccentColor.withAlphaComponent(0.16).setFill()
            for span in spans where chosen.contains(span.id) {
                if let r = blockRect(for: span), r.intersects(dirty) {
                    NSBezierPath(roundedRect: NSRect(x: textView.textContainerOrigin.x - 4, y: r.minY - 2, width: textView.bounds.width - textView.textContainerOrigin.x, height: r.height + 4), xRadius: 4, yRadius: 4).fill()
                }
            }
        }
        drawBlockColors(in: dirty)
        drawSyncedFrames(in: dirty)
        guard let (first, last) = visibleSpanRange(in: dirty) else { return }
        for i in first...last {
            guard let block = document.block(spans[i].id), [.callout, .code, .quote].contains(block.type), let rect = blockRect(for: spans[i]) else { continue }
            let x = textView.textContainerOrigin.x + CGFloat(depths[block.id] ?? 0) * BlockTextStyle.nestIndent
            let width = textView.bounds.width - x
            switch block.type {
            case .quote:
                style.ink.setFill()
                NSRect(x: x + 2, y: rect.minY + 1, width: 3, height: rect.height - 1).fill()
            default:
                let box = NSRect(x: x, y: rect.minY - 10, width: width, height: rect.height + 20)
                style.soft.setFill()
                NSBezierPath(roundedRect: box, xRadius: 9, yRadius: 9).fill()
            }
        }
    }

    /// Фон цвета блока (M12): на всю ширину, вместе с вложенными блоками, как в Notion.
    private func drawBlockColors(in dirty: NSRect) {
        let colored = document.blocks.filter { $0.content?.color.map(BlockColor.isBackground) == true }
        guard !colored.isEmpty else { return }
        let index = Dictionary(spans.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
        for block in colored {
            guard let color = block.content?.color, let i = index[block.id], let top = blockRect(for: spans[i]) else { continue }
            var box = top
            for child in document.descendants(of: block.id) {
                if let j = index[child.id], let r = blockRect(for: spans[j]) { box = box.union(r) }
            }
            let x = textView.textContainerOrigin.x + CGFloat(depths[block.id] ?? 0) * BlockTextStyle.nestIndent - 4
            let frame = NSRect(x: x, y: box.minY - 2, width: textView.bounds.width - x - 4, height: box.height + 4)
            guard frame.intersects(dirty), let fill = BlockTextStyle.background(of: BlockColor.name(color)) else { continue }
            fill.setFill()
            NSBezierPath(roundedRect: frame, xRadius: 4, yRadius: 4).fill()
        }
    }

    /// Рамка синхронизированного блока и его копии: подпись и всё содержимое (ADR-0012).
    private func drawSyncedFrames(in dirty: NSRect) {
        let framed = document.blocks.filter { $0.type == .synced || $0.type == .syncedRef }
        guard !framed.isEmpty else { return }
        let index = Dictionary(spans.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
        for block in framed {
            guard let i = index[block.id], var box = blockRect(for: spans[i]) else { continue }
            for child in document.descendants(of: block.id) {
                if let j = index[child.id], let r = blockRect(for: spans[j]) { box = box.union(r) }
            }
            let x = textView.textContainerOrigin.x + CGFloat(depths[block.id] ?? 0) * BlockTextStyle.nestIndent - 8
            let frame = NSRect(x: x, y: box.minY - 4, width: textView.bounds.width - x - 4, height: box.height + 8)
            guard frame.intersects(dirty) else { continue }
            style.accent.withAlphaComponent(0.55).setStroke()
            let path = NSBezierPath(roundedRect: frame.insetBy(dx: 0.75, dy: 0.75), xRadius: 5, yRadius: 5)
            path.lineWidth = 1.5
            path.stroke()
        }
    }

    /// Маркеры поверх текста.
    func drawMarkers(in dirty: NSRect) {
        guard let (first, last) = visibleSpanRange(in: dirty) else { return }
        for i in first...last {
            guard let block = document.block(spans[i].id), let rect = markerRect(for: spans[i]) else { continue }
            switch block.type {
            case .task: drawCheckbox(rect, checked: block.content?.checked == true)
            case .bullet:
                style.ink.setFill()
                NSBezierPath(ovalIn: NSRect(x: rect.minX + 4.5, y: rect.midY - 2.5, width: 5, height: 5)).fill()
            case .numbered:
                let text = "\(numbers[block.id] ?? 1)." as NSString
                let attrs: [NSAttributedString.Key: Any] = [.font: style.font(for: .numbered), .foregroundColor: style.muted]
                text.draw(at: NSPoint(x: rect.minX, y: rect.minY - 1), withAttributes: attrs)
            case .toggle:
                let triangle = NSBezierPath()
                if block.isCollapsed {
                    triangle.move(to: NSPoint(x: rect.minX + 4, y: rect.minY + 3))
                    triangle.line(to: NSPoint(x: rect.minX + 11, y: rect.midY))
                    triangle.line(to: NSPoint(x: rect.minX + 4, y: rect.maxY - 3))
                } else {
                    triangle.move(to: NSPoint(x: rect.minX + 3, y: rect.minY + 4))
                    triangle.line(to: NSPoint(x: rect.minX + 11, y: rect.minY + 4))
                    triangle.line(to: NSPoint(x: rect.midX, y: rect.maxY - 3))
                }
                triangle.close()
                style.muted.setFill()
                triangle.fill()
            case .callout:
                let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 15), .foregroundColor: style.accent]
                ("✦" as NSString).draw(at: NSPoint(x: rect.minX + 14, y: rect.minY - 2), withAttributes: attrs)
            default: break
            }
        }
    }

    private func drawCheckbox(_ rect: NSRect, checked: Bool) {
        let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 3.5, yRadius: 3.5)
        if checked {
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

    private func visibleSpanRange(in dirty: NSRect) -> (Int, Int)? {
        guard let manager = textView.layoutManager, let container = textView.textContainer, !spans.isEmpty else { return nil }
        let glyphs = manager.glyphRange(forBoundingRect: dirty, in: container)
        let characters = manager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        let first = spanIndex(at: characters.location)
        let last = spanIndex(at: characters.location + characters.length)
        // Последняя пустая строка не имеет символов.
        return (first, min(max(first, last), spans.count - 1))
    }

    func containerWidthChanged(_ width: CGFloat) {
        guard let container = textView.textContainer, width > 0, abs(container.size.width - (width - Self.gutter * 2)) > 0.5 else { return }
        container.size = NSSize(width: max(40, width - Self.gutter * 2), height: 10_000_000)
        updateHeight()
    }
}

/// Системный ИИ не входит в продукт (FR-16).
enum SystemAI {
    static func disableWritingTools(on view: NSTextView) {
        view.writingToolsBehavior = .none
    }
}

/// Текстовый вид страницы: системные действия с текстом направляются в команды.
@MainActor
final class BlockTextView: NSTextView {
    weak var controller: BlockEditorController?

    static var aiHint: String { NSLocalizedString("Нажмите «пробел» для ИИ или «/» для команд", comment: "") }
    var aiHintAttributes: [NSAttributedString.Key: Any] {
        [.font: (typingAttributes[.font] as? NSFont) ?? font ?? NSFont.systemFont(ofSize: 15), .foregroundColor: NSColor.placeholderTextColor]
    }
    /// Где нарисована подсказка ИИ; nil — её нет. Перерисовывается только её место.
    var aiHintRect: NSRect? {
        didSet {
            guard oldValue != aiHintRect else { return }
            for rect in [oldValue, aiHintRect].compactMap({ $0 }) { setNeedsDisplay(rect.insetBy(dx: -2, dy: -2)) }
        }
    }

    override func resignFirstResponder() -> Bool {
        let done = super.resignFirstResponder()
        if done { aiHintRect = nil }
        return done
    }

    override func becomeFirstResponder() -> Bool {
        let done = super.becomeFirstResponder()
        if done { DispatchQueue.main.async { [weak self] in self?.controller?.updateAIHint() } }
        return done
    }

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

    // Текст не перетаскивается: штатное удаляет источник по устаревшему диапазону. Принимаются только файлы.
    override var acceptableDragTypes: [NSPasteboard.PasteboardType] { BlockEditorController.droppableTypes }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let controller else { return false }
        let at = characterIndexForInsertion(at: convert(sender.draggingLocation, from: nil))
        setSelectedRange(NSRange(location: at, length: 0))
        return controller.receiveFiles(from: sender.draggingPasteboard)
    }
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

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        run { $0.drawBackgrounds(in: rect) }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        run { $0.drawMarkers(in: dirtyRect) }
        if let id = hoveredBlock { run { c in if let span = c.span(withID: id) { c.drawHandle(for: span) } } }
        if let y = dropLine {
            NSColor.controlAccentColor.setFill()
            NSRect(x: textContainerOrigin.x, y: y, width: bounds.width - textContainerOrigin.x, height: 2).fill()
        }
        if let edge = dropEdge {
            NSColor.controlAccentColor.setFill()
            edge.fill()
        }
        if let rect = aiHintRect, rect.intersects(dirtyRect) {
            (Self.aiHint as NSString).draw(at: rect.origin, withAttributes: aiHintAttributes)
        }
    }

    private var hoveredBlock: UUID? {
        didSet { if oldValue != hoveredBlock { needsDisplay = true } }
    }
    fileprivate var dropLine: CGFloat? {
        didSet { needsDisplay = true }
    }
    /// Бросок на край блока: вертикальная черта — блок встанет колонкой.
    fileprivate var dropEdge: NSRect? {
        didSet { needsDisplay = true }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        let at = convert(event.locationInWindow, from: nil)
        run { self.hoveredBlock = $0.block(atY: at.y)?.id }
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        hoveredBlock = nil
    }

    override func mouseDown(with event: NSEvent) {
        let at = convert(event.locationInWindow, from: nil)
        var grabbed: BlockEditorController.Span?
        run { c in
            if let span = c.block(atY: at.y), let rect = c.handleRect(for: span), rect.insetBy(dx: -3, dy: -3).contains(at) { grabbed = span }
        }
        if let span = grabbed {
            trackDrag(of: span)
            return
        }
        var handled = false
        run { $0.clearBlockSelection() }
        run { handled = $0.handleClick(at: at, clickCount: event.clickCount) }
        if !handled {
            super.mouseDown(with: event) // Своё выделение текста; цикл мыши внутри NSTextView.
            finishSelection(startedAt: at)
        }
    }

    /// Поле редактора (основное или колонки) под точкой окна.
    private func editorView(atWindowPoint point: NSPoint) -> BlockTextView? {
        var view = window?.contentView?.hitTest(point)
        while let v = view, !(v is BlockTextView) { view = v.superview }
        return view as? BlockTextView
    }

    /// Выделение отпущено над другим полем: целые блоки от начального до блока под курсором.
    private func finishSelection(startedAt start: NSPoint) {
        guard let window, let target = editorView(atWindowPoint: window.mouseLocationOutsideOfEventStream), target !== self,
              let mine = controller, let other = target.controller else { return }
        let end = target.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        guard let a = mine.block(atY: start.y)?.id, let b = other.block(atY: end.y)?.id else { return }
        mine.selectBlocks(from: a, to: b)
    }

    /// Перетаскивание блока за ручку: линия показывает место, отпускание выполняет одну команду.
    private func trackDrag(of span: BlockEditorController.Span) {
        guard let window else { return }
        guard let start = window.currentEvent.map({ convert($0.locationInWindow, from: nil) }) else { return }
        var last = start
        var moved = false
        // Поле, над которым курсор: блок можно перенести в другую колонку или в основной текст.
        var target: BlockTextView = self
        while let event = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            let local = convert(event.locationInWindow, from: nil)
            if abs(local.y - start.y) > 3 || abs(local.x - start.x) > 3 { moved = true }
            let over = editorView(atWindowPoint: event.locationInWindow) ?? self
            if over !== target {
                target.dropLine = nil
                target.dropEdge = nil
                target = over
            }
            last = target.convert(event.locationInWindow, from: nil)
            if event.type == .leftMouseUp { break }
            if let c = target.controller {
                if let edge = c.columnDrop(at: last, dragging: span.id) {
                    target.dropEdge = edge.rect
                    target.dropLine = nil
                } else {
                    target.dropEdge = nil
                    target.dropLine = c.dropTarget(at: last)?.y
                }
            }
            autoscroll(with: event)
        }
        target.dropLine = nil
        target.dropEdge = nil
        if moved { target.controller?.finishDrag(span.id, at: last) } // Простое нажатие на ручку ничего не двигает.
    }

    // MARK: Единое меню

    /// Правый клик: те же действия, что в меню «Формат».
    override func menu(for event: NSEvent) -> NSMenu? {
        // Действия меню относятся к блоку под курсором мыши.
        let index = characterIndexForInsertion(at: convert(event.locationInWindow, from: nil))
        let selected = selectedRange()
        if index < selected.location || index > selected.location + selected.length { setSelectedRange(NSRange(location: index, length: 0)) }
        let menu = super.menu(for: event) ?? NSMenu()
        var at = 0
        func add(_ item: NSMenuItem) {
            menu.insertItem(item, at: at)
            at += 1
        }
        func sub(_ title: String, _ items: [EditorAction.Item]) -> NSMenuItem {
            let head = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let m = NSMenu()
            for it in items { m.addItem(menuItem(it)) }
            head.submenu = m
            return head
        }
        let t: (String) -> String = { NSLocalizedString($0, comment: "") }
        add(sub(t("Преобразовать"), EditorAction.blockTypes))
        add(sub(t("Начертание"), EditorAction.marks))
        add(sub(t("Цвет текста"), EditorAction.colors))
        add(sub(t("Цветной маркер"), EditorAction.highlights))
        add(sub(t("Цвет блока"), EditorAction.blockColors))
        if selected.length > 0 { add(menuItem(EditorAction.Item(title: t("Комментировать…"), action: .comment))) }
        if let controller, controller.isInsideSyncedCopy {
            add(menuItem(EditorAction.Item(title: t("Отвязать копию"), action: .unsyncCopy)))
        }
        if let controller, controller.fetchLinkPreview != nil, controller.isBookmarkAtCaret {
            add(menuItem(EditorAction.Item(title: t("Обновить превью"), action: .refreshLinkPreview)))
        }
        add(sub(t("Вставить блок"), EditorAction.inserts))
        for item in EditorAction.blockActions { add(menuItem(item)) }
        add(.separator())
        return menu
    }

    private func menuItem(_ item: EditorAction.Item) -> NSMenuItem {
        let m = NSMenuItem(title: item.title, action: #selector(performMenuAction(_:)), keyEquivalent: "")
        m.target = self
        m.representedObject = EditorActionBox(item.action)
        return m
    }

    @objc private func performMenuAction(_ sender: NSMenuItem) {
        guard let box = sender.representedObject as? EditorActionBox else { return }
        run { $0.run(box.action) }
    }
}

final class EditorActionBox: NSObject {
    let action: EditorAction
    init(_ action: EditorAction) { self.action = action }
}

/// Место под текстом страницы: принимает файлы и картинки и ставит курсор в конец по нажатию.
/// Без него у короткой страницы почти вся площадь не принимала перетаскивание.
final class EditorTailView: NSView {
    weak var controller: BlockEditorController?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes(BlockEditorController.droppableTypes)
    }

    required init?(coder: NSCoder) { nil }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { controller == nil ? [] : .copy }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { controller == nil ? [] : .copy }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let controller else { return false }
        controller.moveCaretToEnd()
        return controller.receiveFiles(from: sender.draggingPasteboard)
    }

    override func mouseDown(with event: NSEvent) { controller?.moveCaretToEnd() }
}
