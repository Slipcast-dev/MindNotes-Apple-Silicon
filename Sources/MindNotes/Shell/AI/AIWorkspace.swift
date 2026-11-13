import AppKit
import SwiftUI

/// Данные ИИ открытого пространства (ADR-0016): скрытые от ИИ страницы, страница инструкций и история чатов.
/// Хранятся в `workspace_meta`, поэтому входят в резервную копию и не требуют новой схемы.
@MainActor
final class AIWorkspace: ObservableObject {
    static let shared = AIWorkspace()

    private static let excludedKey = "ai_excluded_pages"
    private static let instructionsKey = "ai_instructions_page"

    @Published private(set) var excluded: Set<UUID> = []
    @Published private(set) var instructionsPage: UUID?
    @Published private(set) var chats: [AIStoredChat] = []
    private weak var store: SQLiteWorkspace?
    private var saveChats: Task<Void, Never>?

    func attach(_ store: SQLiteWorkspace) {
        self.store = store
        excluded = []
        instructionsPage = nil
        chats = []
        Task { @MainActor in
            guard self.store === store else { return }
            excluded = AIExclusion.decode(try? await store.meta(Self.excludedKey))
            instructionsPage = (try? await store.meta(Self.instructionsKey)).flatMap(UUID.init(uuidString:))
            chats = AIStoredChat.decode(try? await store.meta(AIStoredChat.metaKey))
        }
    }

    func detach() {
        store = nil
        excluded = []
        instructionsPage = nil
        chats = []
    }

    private func write(_ key: String, _ value: String) {
        guard let store else { return }
        Task { try? await store.setMeta(key, value) }
    }

    // MARK: Исключения

    func isExcluded(_ page: UUID, shell: ShellModel) -> Bool {
        // Страница под паролем (ADR-0017) никогда не уходит ИИ сама, даже открытая.
        AIExclusion.isHidden(page, excluded: excluded, locked: Set(shell.pageLocks.keys)) { id in shell.pages.first { $0.id == id }?.parentID }
    }

    /// Отмечена сама страница (а не её предок): от этого зависит подпись пункта меню.
    func isMarked(_ page: UUID) -> Bool { excluded.contains(page) }

    func setExcluded(_ page: UUID, _ on: Bool) {
        if on { excluded.insert(page) } else { excluded.remove(page) }
        write(Self.excludedKey, AIExclusion.encode(excluded))
    }

    // MARK: Инструкции

    static let instructionsTitle = "Инструкции для ИИ"

    /// Открывает страницу инструкций, создавая её при первом обращении.
    func openInstructions(shell: ShellModel) {
        Task { @MainActor in
            if let id = instructionsPage, shell.pages.contains(where: { $0.id == id }) {
                shell.openPage(id)
                return
            }
            let template = L("Опишите, как ИИ должен работать в этом пространстве: стиль ответов, язык, что где лежит, что нельзя менять.")
            guard let id = try? await shell.aiCreatePage(parent: nil, title: L(Self.instructionsTitle), fragments: MarkdownImport.fragments(from: template)) else { return }
            instructionsPage = id
            write(Self.instructionsKey, id.uuidString.lowercased())
        }
    }

    /// Текст инструкций для системного промпта чата и панели помощи; пусто, если страницы нет или она скрыта от ИИ
    /// (сама, через предка или паролем) — та же политика, что для контекста и инструментов.
    func instructions(shell: ShellModel) async -> String {
        await AIExclusion.instructions(page: instructionsPage, exists: { id in shell.pages.contains { $0.id == id } },
                                       hidden: { self.isExcluded($0, shell: shell) }, blocks: { try await shell.aiBlocks(of: $0) })
    }

    // MARK: История

    func save(_ chat: AIStoredChat) {
        chats.removeAll { $0.id == chat.id }
        chats.insert(chat, at: 0)
        persistChats()
    }

    func deleteChat(_ id: UUID) {
        chats.removeAll { $0.id == id }
        persistChats()
    }

    func deleteAllChats() {
        chats = []
        persistChats()
    }

    /// Запись откладывается на полсекунды: потоковый ответ не пишет базу на каждое слово.
    private func persistChats() {
        saveChats?.cancel()
        let snapshot = chats
        saveChats = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            write(AIStoredChat.metaKey, AIStoredChat.encode(snapshot))
        }
    }
}

/// Пункт меню страницы: скрыть её и подстраницы от ИИ (FR-AI-2).
struct AIExcludeMenuItem: View {
    let page: UUID
    @EnvironmentObject private var shell: ShellModel

    var body: some View {
        let data = AIWorkspace.shared
        if data.isMarked(page) {
            Button(L("Снова разрешить ИИ")) { data.setExcluded(page, false) }
        } else if data.isExcluded(page, shell: shell) {
            Button(L("Скрыта от ИИ вместе с родителем")) {}.disabled(true)
        } else {
            Button(L("Не отправлять ИИ")) { data.setExcluded(page, true) }
        }
    }
}
