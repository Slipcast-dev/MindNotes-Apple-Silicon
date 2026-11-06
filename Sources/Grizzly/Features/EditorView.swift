import SwiftUI
import AppKit

/// Line numbers with bookmarks for the editor's gutter (Developer mode).
struct LineNumbers {
    let size: CGFloat
    let bookmarks: Set<Int>
    let toggle: (Int) -> Void
}

/// The editor of the open file. The draft lives in `AppState.drafts`, so switching tabs or modes keeps it.
/// User mode hides the formatting code of Markdown and draws the document as it reads; Developer mode shows the text
/// exactly as it is in the file, with syntax colors and line numbers.
struct EditorView: View {
    let document: Document
    let size: CGFloat
    /// The mode of the pane this editor sits in.
    let mode: ReadMode
    let highlight: SearchHighlight?
    let isScrollTarget: Bool
    var onFocus: () -> Void = {}

    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var prefs: Preferences
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.theme) private var theme
    @Environment(\.surfaceOpacity) private var surface

    /// The newest version of the document: after a save the file is re-read under the same id, and the
    /// copy this view was created with would still hold the text from before the edit.
    private var live: Document { state.documents.first { $0.id == document.id } ?? document }

    var body: some View {
        let doc = live
        let userMode = mode == .user
        let isLive = userMode && doc.type == .markdown
        let prose = userMode && EditorView.isProse(doc.type)
        let bookmarked = Set(library.bookmarks(for: doc.libraryID))
        let numbers: LineNumbers? = !userMode && prefs.showLineNumbers
            ? LineNumbers(size: size - 2, bookmarks: bookmarked, toggle: { line in
                library.toggleBookmark(doc.libraryID, line: line)
                state.notify(bookmarked.contains(line) ? L("Закладка убрана.") : L("Закладка добавлена: строка %lld.", line), symbol: "bookmark.fill")
            })
            : nil
        VStack(spacing: 0) {
            bar(doc)
            EditorTextView(
                text: Binding(
                    get: { state.text(for: doc) },
                    set: { state.setDraft($0, for: doc) }),
                font: prose ? TextBuilder.font(prefs, size: size) : .monospacedSystemFont(ofSize: size - 2, weight: .regular),
                textColor: NSColor(theme.text),
                type: doc.type,
                live: isLive,
                highlightOn: prefs.highlights(doc.type),
                spellCheck: prefs.spellCheck && EditorView.isProse(doc.type),
                theme: theme,
                background: NSColor(theme.background).withAlphaComponent(surface),
                find: highlight,
                scrollTarget: isScrollTarget ? state.scrollTarget : nil,
                initialScrollID: state.scrollTarget?.id,
                numbers: numbers,
                column: prose ? 760 : nil,
                collapsed: state.collapsedSections[doc.id] ?? [],
                onFold: { state.toggleSection(doc.id, key: $0) },
                moveDoneTasks: prefs.moveDoneTasks,
                onFocus: onFocus,
                documentURL: doc.url,
                styleKey: "\(prefs.themeID)|\(prefs.wantsDark)|\(prefs.syntaxEnabled)|\(prefs.syntaxOff.sorted().joined(separator: ","))|\(prefs.fontName)|\(size)")
                .id("\(doc.id)-\(isLive)-\(prose)-\(numbers != nil)")
        }
    }

    /// Spelling and grammar are checked in prose; in source code and data files every identifier would be an "error".
    static func isProse(_ type: FileType) -> Bool { [.markdown, .text, .rtf, .tex].contains(type) }

    /// Formatting, Undo and Save, in the same style as the other buttons. Saving and similar events are announced
    /// by notifications instead of a status line.
    private func bar(_ document: Document) -> some View {
        let dirty = state.isDirty(document.id)
        return HStack(spacing: 8) {
            if document.type == .markdown {
                ScrollView(.horizontal, showsIndicators: false) { FormatBar() }
            }
            Spacer()
            Button { NSApp.sendAction(Selector(("undo:")), to: nil, from: nil) } label: {
                Label("Отменить", systemImage: "arrow.uturn.backward")
            }
            .help("Отменить последний шаг (⌘Z)")
            Button { state.save(document.id) } label: {
                Label("Сохранить", systemImage: "square.and.arrow.down")
            }
            .help("Сохранить (⌘S)")
            .disabled(!dirty)
        }
        .buttonStyle(.hoverFilled)
        .font(AppFont.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }
}

/// NSTextView instead of SwiftUI's TextEditor so smart quotes, dash and text replacement stay off: this is a file editor.
private struct EditorTextView: NSViewRepresentable {
    @Binding var text: String
    let font: NSFont
    let textColor: NSColor
    let type: FileType
    /// User mode of a Markdown file: the formatting code is hidden (see `LiveStyler`).
    let live: Bool
    let highlightOn: Bool
    let spellCheck: Bool
    let theme: Theme
    let background: NSColor
    let find: SearchHighlight?
    /// Set when this pane should jump to the current hit; compared by id with the last one handled.
    let scrollTarget: ScrollTarget?
    let initialScrollID: UUID?
    let numbers: LineNumbers?
    /// Reading column width (nil: the text fills the pane).
    let column: CGFloat?
    let collapsed: Set<String>
    let onFold: (String) -> Void
    let moveDoneTasks: Bool
    let onFocus: () -> Void
    /// The file being edited: attachments are placed next to it.
    let documentURL: URL
    /// Changes with anything outside the text that changes how it is painted (theme, font settings).
    let styleKey: String

    func makeCoordinator() -> Coordinator { Coordinator(self, handledScroll: initialScrollID) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        let storage = NSTextStorage()
        let layout = LiveLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layout.addTextContainer(container)
        let view = LiveTextView(frame: .zero, textContainer: container)
        view.minSize = .zero
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        scroll.documentView = view
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = false
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsetsZero
        scroll.wantsLayer = true
        scroll.layer?.masksToBounds = true

        view.delegate = context.coordinator
        view.isRichText = false
        view.allowsUndo = true
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.isAutomaticLinkDetectionEnabled = false
        view.textContainerInset = NSSize(width: 14, height: 12)
        view.string = text
        view.onFocus = { [weak coordinator = context.coordinator] in coordinator?.parent.onFocus() }
        view.onFold = { [weak coordinator = context.coordinator] key in coordinator?.parent.onFold(key) }
        view.onTask = { [weak coordinator = context.coordinator] box in coordinator?.toggleTask(at: box) }
        // Russian and English are both checked: the checker picks the language of each phrase.
        NSSpellChecker.shared.automaticallyIdentifiesLanguages = true
        if column != nil || live {
            scroll.contentView.postsFrameChangedNotifications = true
            NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.frameChanged),
                                                   name: NSView.frameDidChangeNotification, object: scroll.contentView)
        }
        context.coordinator.scroll = scroll
        context.coordinator.view = view
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.attachmentReady),
                                               name: .grizzlyAttachmentReady, object: nil)
        style(view, scroll, context.coordinator)
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView else { return }
        context.coordinator.parent = self
        // The text changed from outside (save, reload, revert): replace it and keep the caret in range.
        if view.string != text {
            let caret = view.selectedRange()
            view.string = text
            view.setSelectedRange(NSRange(location: min(caret.location, (text as NSString).length), length: 0))
        }
        style(view, scroll, context.coordinator)
        context.coordinator.updateInset()
        context.coordinator.configureRuler(scroll, view)
        context.coordinator.applyFind(to: view)
    }

    private func style(_ view: NSTextView, _ scroll: NSScrollView, _ coordinator: Coordinator) {
        view.insertionPointColor = textColor
        // With the glass effect the background is partly see-through: the scroll view then paints nothing of its own.
        let translucent = background.alphaComponent < 0.999
        view.drawsBackground = true
        view.backgroundColor = background
        scroll.backgroundColor = background
        scroll.drawsBackground = !translucent
        scroll.contentView.drawsBackground = !translucent
        if let layout = view.layoutManager as? LiveLayoutManager {
            layout.live = live
            layout.theme = theme
        }
        (view as? LiveTextView)?.live = live
        (view as? LiveTextView)?.isMarkdown = type == .markdown
        (view as? LiveTextView)?.documentURL = documentURL
        if view.isContinuousSpellCheckingEnabled != spellCheck { view.isContinuousSpellCheckingEnabled = spellCheck }
        if view.isGrammarCheckingEnabled != spellCheck { view.isGrammarCheckingEnabled = spellCheck }

        // Painting the whole text is the expensive part: it is done only when the text or a setting that changes
        // its look is different from last time (SwiftUI asks for an update on every change anywhere in the window).
        let key = [styleKey, "\(live)", "\(highlightOn)", "\(type)", collapsed.sorted().joined(separator: ","),
                   documentURL.path, "\(view.string.hashValue)", "\(view.string.utf16.count)"].joined(separator: "|")
        guard key != coordinator.paintedStyleKey else { return }
        coordinator.paintedStyleKey = key
        view.font = font
        view.textColor = textColor
        colorize(view)
        coordinator.ruler?.setText(view.string)
        view.needsDisplay = true
    }

    /// Syntax colors for the whole text (skipped for very large files, where rescanning on every key would lag).
    private func colorize(_ view: NSTextView) {
        if type == .markdown, let storage = view.textStorage, storage.length <= 150_000 {
            // Headings, bold, italic, highlights, lists and quotes show in the text as they will read.
            storage.beginEditing()
            if live {
                LiveStyler.apply(to: storage, base: font, textColor: textColor, theme: theme, collapsed: collapsed, document: documentURL)
            } else {
                MarkdownStyler.apply(to: storage, base: font, textColor: textColor, theme: theme)
            }
            storage.endEditing()
        }
        if EditorView.isProse(type), let storage = view.textStorage {
            // #tags are colored like tokens.
            storage.beginEditing()
            if type != .markdown { storage.removeAttribute(.backgroundColor, range: NSRange(location: 0, length: storage.length)) }
            for (range, _) in LibraryStore.tagMatches(in: storage.string) where storage.attribute(.grizzlyHidden, at: range.location, effectiveRange: nil) == nil {
                storage.addAttributes([.foregroundColor: NSColor(theme.accent),
                                       .backgroundColor: NSColor(theme.accent).withAlphaComponent(0.16)], range: range)
            }
            storage.endEditing()
        }
        guard highlightOn, SyntaxEngine.hasHighlighting(type), let storage = view.textStorage else { return }
        let text = view.string
        guard text.utf16.count <= 200_000 else { return }
        let lines = text.components(separatedBy: "\n")
        let states = SyntaxEngine.states(lines, type: type)
        storage.beginEditing()
        var offset = 0
        for (i, line) in lines.enumerated() {
            for span in SyntaxEngine.spans(line, type: type, state: states.isEmpty ? 0 : states[i]).spans {
                let range = NSRange(location: offset + span.range.location, length: span.range.length)
                storage.addAttribute(.foregroundColor, value: NSColor(Syntax.color(span.role, theme)), range: range)
            }
            offset += line.utf16.count + 1
        }
        storage.endEditing()
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: EditorTextView
        weak var scroll: NSScrollView?
        weak var view: NSTextView?
        var ruler: LineNumberRuler?
        var paintedStyleKey = ""
        private var handledScroll: UUID?
        private var paintedKey = ""

        deinit { NotificationCenter.default.removeObserver(self) }

        @objc func frameChanged() { updateInset() }
        @objc func attachmentReady() { view?.needsDisplay = true }

        /// Centers a column of at most `column` points in the pane; User mode also leaves room for the folding arrows.
        func updateInset() {
            guard let view, let scroll else { return }
            guard let column = parent.column else {
                let side: CGFloat = parent.live ? 44 : 14
                if view.textContainerInset.width != side { view.textContainerInset = NSSize(width: side, height: 12) }
                return
            }
            let side = max(parent.live ? 44 : 36, (scroll.contentView.bounds.width - column) / 2)
            if abs(view.textContainerInset.width - side) > 0.5 { view.textContainerInset = NSSize(width: side, height: 20) }
        }

        /// The gutter with line numbers and bookmarks (Developer mode).
        func configureRuler(_ scroll: NSScrollView, _ view: NSTextView) {
            guard let numbers = parent.numbers else {
                if scroll.hasVerticalRuler { scroll.hasVerticalRuler = false; scroll.rulersVisible = false }
                ruler = nil
                return
            }
            if ruler == nil {
                let r = LineNumberRuler(scrollView: scroll, orientation: .verticalRuler)
                r.clientView = view
                r.ruleThickness = 58
                scroll.verticalRulerView = r
                scroll.hasVerticalRuler = true
                scroll.rulersVisible = true
                r.setText(view.string)
                ruler = r
            }
            guard let r = ruler else { return }
            r.numberFont = .monospacedSystemFont(ofSize: numbers.size * 0.8, weight: .regular)
            r.numberColor = NSColor(parent.theme.gutter)
            r.bookmarkColor = NSColor(parent.theme.bookmark)
            r.background = parent.background
            r.onToggle = numbers.toggle
            if r.bookmarks != numbers.bookmarks { r.bookmarks = numbers.bookmarks }
        }

        /// A click on the circle of a check list item ticks it; with "move done tasks down" the item goes to the end of its list.
        func toggleTask(at box: Int) {
            guard let view, let edit = RichFormat.toggleTaskEdit(text: view.string, boxIndex: box, moveDone: parent.moveDoneTasks) else { return }
            let caret = view.selectedRange()
            FormatActions.apply(edit, to: view)
            view.setSelectedRange(NSRange(location: min(caret.location, (view.string as NSString).length), length: 0))
        }

        private func isHidden(_ storage: NSTextStorage, _ i: Int) -> Bool {
            i >= 0 && i < storage.length && storage.attribute(.grizzlyHidden, at: i, effectiveRange: nil) != nil
        }

        /// The caret never rests inside invisible code: it jumps over it in the direction of the move, and a line
        /// that starts with hidden code (`# `, a list marker) puts the caret behind it.
        func textView(_ textView: NSTextView, willChangeSelectionFromCharacterRange old: NSRange,
                      toCharacterRange new: NSRange) -> NSRange {
            guard parent.live, new.length == 0, let storage = textView.textStorage, storage.length > 0 else { return new }
            var p = new.location
            let ns = storage.string as NSString
            let atLineStart = p == 0 || (p <= ns.length && ns.character(at: p - 1) == 10)
            if isHidden(storage, p), atLineStart {
                while isHidden(storage, p), p < storage.length { p += 1 }
                return NSRange(location: p, length: 0)
            }
            guard isHidden(storage, p - 1), isHidden(storage, p) else { return new }
            if new.location >= old.location { while isHidden(storage, p) { p += 1 } } else { while isHidden(storage, p - 1) { p -= 1 } }
            return NSRange(location: p, length: 0)
        }

        init(_ parent: EditorTextView, handledScroll: UUID?) {
            self.parent = parent
            self.handledScroll = handledScroll
        }

        private var isCompleting = false
        private var lastKind = 0
        private var lastWasSpace = false
        private var lastEdit = Date.distantPast

        /// Undo goes step by step: macOS merges a whole run of typing into one undo step, so a new step is started
        /// at every word, after a pause, when switching between typing and deleting, and for paste or Return.
        func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString: String?) -> Bool {
            let s = replacementString ?? ""
            // Backspace or Delete next to invisible code removes the visible character beyond it, never the code itself.
            if parent.live, s.isEmpty, range.length == 1, let storage = textView.textStorage, isHidden(storage, range.location),
               let event = NSApp.currentEvent, event.type == .keyDown, [51, 117].contains(event.keyCode) {
                var i = range.location
                if event.keyCode == 51 { while isHidden(storage, i) { i -= 1 } } else { while isHidden(storage, i) { i += 1 } }
                if i >= 0, i < storage.length {
                    let target = NSRange(location: i, length: 1)
                    if textView.shouldChangeText(in: target, replacementString: "") {
                        storage.replaceCharacters(in: target, with: "")
                        textView.didChangeText()
                        textView.setSelectedRange(NSRange(location: i, length: 0))
                    }
                }
                return false
            }
            let isSpace = s.utf16.count == 1 && s.rangeOfCharacter(from: .whitespaces) != nil
            // 1 typing one character, 2 deleting, 3 anything else (Return, paste, replacing a selection)
            let kind = s.isEmpty ? 2 : (s.utf16.count == 1 && !s.contains("\n") && range.length == 0 ? 1 : 3)
            let now = Date()
            if kind != lastKind || kind == 3 || (kind == 1 && lastWasSpace && !isSpace) || now.timeIntervalSince(lastEdit) > 1 {
                textView.breakUndoCoalescing()
            }
            lastKind = kind
            lastWasSpace = isSpace
            lastEdit = now
            return true
        }

        /// Return in a list or a quote continues it (a new bullet, number, box or `>`); on an empty item it ends the list.
        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.insertNewline(_:)), parent.type == .markdown,
                  textView.selectedRange().length == 0, textView.hasMarkedText() == false,
                  let edit = RichFormat.returnEdit(text: textView.string, caret: textView.selectedRange().location) else { return false }
            FormatActions.apply(edit, to: textView)
            return true
        }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            // Formatting that lost its last character (`****`, `<u></u>`) is removed with it.
            if parent.live, let storage = view.textStorage {
                for r in RichFormat.emptyMarks(in: view.string).reversed() { storage.replaceCharacters(in: r, with: "") }
            }
            parent.text = view.string
            suggestTagIfTyping(in: view)
        }

        /// Typing `#` or `#wo` opens the list of known tags under the caret, like Apple Notes.
        private func suggestTagIfTyping(in view: NSTextView) {
            guard EditorView.isProse(parent.type), !isCompleting, view.selectedRange().length == 0,
                  let event = NSApp.currentEvent, event.type == .keyDown,
                  ![51, 117].contains(event.keyCode), event.characters?.isEmpty == false else { return }
            let ns = view.string as NSString
            var i = view.selectedRange().location
            while i > 0, Self.isTagChar(ns.character(at: i - 1)) { i -= 1 }
            guard i > 0, ns.character(at: i - 1) == 35 else { return }
            if i > 1, Self.isWordChar(ns.character(at: i - 2)) { return }
            isCompleting = true
            view.complete(nil)
            isCompleting = false
        }

        private static func isWordChar(_ c: unichar) -> Bool {
            // A lone surrogate is half of an emoji (or another astral character).
            guard let u = Unicode.Scalar(c) else { return true }
            return CharacterSet.alphanumerics.contains(u) || c == 95 || u.properties.isEmojiPresentation || c == 0x200D || c == 0xFE0F
        }
        private static func isTagChar(_ c: unichar) -> Bool { isWordChar(c) || c == 45 }

        func textView(_ textView: NSTextView, completions words: [String], forPartialWordRange charRange: NSRange,
                      indexOfSelectedItem index: UnsafeMutablePointer<Int>?) -> [String] {
            let ns = textView.string as NSString
            guard EditorView.isProse(parent.type), charRange.location > 0, ns.character(at: charRange.location - 1) == 35 else { return [] }
            let typed = ns.substring(with: charRange)
            let known = Set(AppState.shared.library.allTags + LibraryStore.extractTags(from: textView.string))
            return known
                .filter { $0.range(of: typed, options: [.caseInsensitive, .anchored]) != nil && $0.caseInsensitiveCompare(typed) != .orderedSame }
                .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        }

        /// Paints every hit of the find query (temporary attributes: they never become part of the text),
        /// marks the current one and scrolls to it when asked to.
        func applyFind(to view: NSTextView) {
            guard let layout = view.layoutManager else { return }
            let query = parent.find?.query ?? ""
            let text = view.string
            let current = parent.find?.current
            let key = "\(query)|\(current.map { "\($0.unit):\($0.occurrence)" } ?? "-")|\(text.hashValue)"

            if key != paintedKey {
                paintedKey = key
                let full = NSRange(location: 0, length: (text as NSString).length)
                layout.removeTemporaryAttribute(.backgroundColor, forCharacterRange: full)
                if !query.isEmpty {
                    let lines = text.components(separatedBy: "\n")
                    var offset = 0
                    for (i, line) in lines.enumerated() {
                        for (k, r) in Searcher.ranges(of: query, in: line).enumerated() {
                            let ns = NSRange(r, in: line)
                            let isCurrent = current == SearchMatch(unit: i, occurrence: k)
                            layout.addTemporaryAttribute(
                                .backgroundColor,
                                value: NSColor(isCurrent ? parent.theme.currentMatch : parent.theme.match),
                                forCharacterRange: NSRange(location: offset + ns.location, length: ns.length))
                        }
                        offset += line.utf16.count + 1
                    }
                }
            }

            if let target = parent.scrollTarget, target.id != handledScroll {
                handledScroll = target.id
                if let current, current.unit == target.unit, let range = Self.range(of: current, query: query, in: text) {
                    view.scrollRangeToVisible(range)
                    view.showFindIndicator(for: range)
                } else {
                    // A bookmark: go to the start of the line.
                    let lines = text.components(separatedBy: "\n")
                    if lines.indices.contains(target.unit) {
                        let offset = lines[..<target.unit].reduce(0) { $0 + $1.utf16.count + 1 }
                        view.setSelectedRange(NSRange(location: offset, length: 0))
                        view.scrollRangeToVisible(NSRange(location: offset, length: 0))
                    }
                }
            }
        }

        static func range(of match: SearchMatch, query: String, in text: String) -> NSRange? {
            let lines = text.components(separatedBy: "\n")
            guard lines.indices.contains(match.unit) else { return nil }
            let found = Searcher.ranges(of: query, in: lines[match.unit])
            guard found.indices.contains(match.occurrence) else { return nil }
            let ns = NSRange(found[match.occurrence], in: lines[match.unit])
            let offset = lines[..<match.unit].reduce(0) { $0 + $1.utf16.count + 1 }
            return NSRange(location: offset + ns.location, length: ns.length)
        }
    }
}
