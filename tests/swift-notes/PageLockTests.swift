import Foundation

/// Порядок разделов с «Страницами» и замки страниц (ADR-0017).
func runPageLockTests() async {
    await test("Разделы: «Страницы» на своей позиции, перенос на место другого раздела") {
        let a = PageSection(id: UUID(), name: "A", sortKey: "a"), b = PageSection(id: UUID(), name: "B", sortKey: "b")
        checkEqual(SectionSlot.order([a, b], pagesIndex: 0), [.pages, .custom(a.id), .custom(b.id)])
        checkEqual(SectionSlot.order([a, b], pagesIndex: 9), [.custom(a.id), .custom(b.id), .pages], "позиция за краем — в конец")
        checkEqual(SectionSlot.order([a, b], pagesIndex: -3).first, .pages, "отрицательная — в начало")
        let order = SectionSlot.order([a, b], pagesIndex: 0)
        let down = SectionSlot.move(order, .pages, onto: .custom(b.id))
        checkEqual(down, [.custom(a.id), .custom(b.id), .pages], "сверху вниз — после цели")
        let up = SectionSlot.move(down, .custom(b.id), onto: .custom(a.id))
        checkEqual(up, [.custom(b.id), .custom(a.id), .pages], "снизу вверх — перед целью")
        checkEqual(SectionSlot.move(order, .pages, onto: .pages), order, "на себя — без изменений")
        checkEqual(SectionSlot.customPredecessor(of: a.id, in: up), b.id)
        checkEqual(SectionSlot.customPredecessor(of: b.id, in: up), nil, "первым среди своих")
        checkEqual(SectionSlot.customPredecessor(of: a.id, in: [.custom(a.id), .pages, .custom(b.id)]), nil, "«Страницы» не считаются")
    }

    await test("Замки: поиск по предкам, открытые замки, цикл, кодирование") {
        let root = UUID(), child = UUID(), grand = UUID(), other = UUID()
        let parents: [UUID: UUID] = [child: root, grand: child]
        let parent: (UUID) -> UUID? = { parents[$0] }
        check(PageLock.isClosed(grand, locked: [root], unlocked: [], parent: parent), "замок предка закрывает потомка")
        check(!PageLock.isClosed(grand, locked: [root], unlocked: [root], parent: parent), "открытый замок не закрывает")
        check(PageLock.isClosed(grand, locked: [root, child], unlocked: [root], parent: parent), "второй замок ниже ещё закрыт")
        check(!PageLock.isClosed(other, locked: [root], unlocked: [], parent: parent), "чужая ветка открыта")
        checkEqual(PageLock.lockingPage(of: grand, locked: [root, child], parent: parent), child, "ближайший замок")
        let loop: (UUID) -> UUID? = { $0 == root ? child : root }
        check(!PageLock.isClosed(root, locked: [other], unlocked: [], parent: loop), "цикл в данных не зависает")
        let lock = PageLock(page: root, salt: "c2FsdA==", hash: "aGFzaA==", rounds: 10)
        checkEqual(PageLock.decode(PageLock.encode([root: lock])), [root: lock], "запись и чтение")
        checkEqual(PageLock.decode("не json"), [:])
        checkEqual(PageLock.decode(#"[{"page":"\#(root.uuidString)","salt":"","hash":"","rounds":0}]"#), [:], "пустой замок отбрасывается")
    }
}
