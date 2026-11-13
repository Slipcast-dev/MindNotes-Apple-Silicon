import Foundation

/// Страница инструкций ИИ подчиняется общей политике приватности (аудит: ai-instructions-privacy-bypass).
/// Проверяется собранное тело запроса чата и панели помощи; сеть не используется.
func runAIInstructionsTests() async {
    await test("ИИ: скрытая или закрытая паролем страница инструкций не попадает в запрос") {
        let root = UUID(), folder = UUID(), page = UUID()
        let parents: [UUID: UUID] = [page: folder, folder: root]
        let marker = "MARKER-\(UUID().uuidString)"
        let block = Block(id: UUID(), pageID: page, sortKey: "a0", content: BlockContent(text: "Пиши кратко. " + marker), createdAt: 1)
        var reads = 0

        /// Тело запросов чата и панели помощи так, как их собирает приложение.
        func bodies(excluded: Set<UUID>, locked: Set<UUID>) async throws -> [String] {
            let rules = await AIExclusion.instructions(
                page: page, exists: { $0 == page },
                hidden: { AIExclusion.isHidden($0, excluded: excluded, locked: locked) { parents[$0] } },
                blocks: { _ in reads += 1; return [block] })
            let chat = AIRequest.body(system: AIPrompts.agent(instructions: rules, today: ""), messages: [AIRequest.userText("привет")], effort: .low)
            let assist = AIRequest.body(system: AIPrompts.writing(instructions: rules), messages: [AIRequest.userText("текст")], effort: .low)
            return try [chat, assist].map { String(decoding: try JSONEncoder().encode($0), as: UTF8.self) }
        }

        let allowed = try await bodies(excluded: [], locked: [])
        check(allowed.allSatisfy { $0.contains(marker) }, "разрешённые инструкции передаются в чат и панель помощи")
        checkEqual(reads, 1)

        for (name, excluded, locked) in [
            ("исключена сама страница", Set([page]), Set<UUID>()),
            ("исключён предок", Set([root]), Set<UUID>()),
            ("пароль на странице", Set<UUID>(), Set([page])),
            ("пароль на предке", Set<UUID>(), Set([folder])),
        ] {
            reads = 0
            let sent = try await bodies(excluded: excluded, locked: locked)
            check(sent.allSatisfy { !$0.contains(marker) }, "\(name): маркера нет в теле запроса")
            check(sent.allSatisfy { !$0.contains("<instructions>") }, "\(name): блока инструкций нет")
            checkEqual(reads, 0, "\(name): текст страницы не читается")
        }

        // Открытый пользователем замок политику не меняет: isHidden не зависит от разблокировки.
        check(AIExclusion.isHidden(page, excluded: [], locked: [folder]) { parents[$0] })
        check(!AIExclusion.isHidden(page, excluded: [UUID()], locked: [UUID()]) { parents[$0] }, "чужие исключения не действуют")
        // Удалённая или не назначенная страница — пустые инструкции.
        checkEqual(await AIExclusion.instructions(page: nil, exists: { _ in true }, hidden: { _ in false }, blocks: { _ in [block] }), "")
        checkEqual(await AIExclusion.instructions(page: page, exists: { _ in false }, hidden: { _ in false }, blocks: { _ in [block] }), "")
        checkEqual(AIPrompts.writing(instructions: ""), AIPrompts.writing, "без инструкций — прежний промпт")
    }
}
