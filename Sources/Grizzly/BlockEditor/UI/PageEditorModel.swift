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

/// Открытая страница для интерфейса: контроллер живёт столько же, сколько сессия редактора.
@MainActor
final class PageEditorModel: ObservableObject {
    private let session: EditorSession
    let controller: BlockEditorController
    @Published private(set) var contentHeight: CGFloat = 60

    var pageID: UUID { session.pageID }

    init(session: EditorSession, style: BlockTextStyle, onError: @escaping (String) -> Void) {
        self.session = session
        controller = BlockEditorController(session: session, style: style)
        controller.onError = onError
        controller.onHeightChange = { [weak self] in self?.contentHeight = $0 }
        controller.updateHeight(force: true)
    }

    func insert(_ type: BlockType) {
        controller.insertBlock(type)
        controller.textView.window?.makeFirstResponder(controller.textView)
    }

    func emergencyText(title: String) -> String { session.emergencyText(title: title) }
}

/// Единый текстовый вид страницы.
struct NativeBlockEditor: NSViewRepresentable {
    @ObservedObject var editor: PageEditorModel

    func makeNSView(context: Context) -> BlockTextView { editor.controller.textView }

    func updateNSView(_ view: BlockTextView, context: Context) {}
}
