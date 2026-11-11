import AppKit
import LocalAuthentication
import SwiftUI

extension ShellModel {
    private func parentOf(_ id: UUID) -> UUID? { pages.first { $0.id == id }?.parentID }

    /// Закрыта сейчас: на пути к корню есть неоткрытый замок.
    func isClosed(_ id: UUID) -> Bool {
        guard !pageLocks.isEmpty else { return false }
        return PageLock.isClosed(id, locked: Set(pageLocks.keys), unlocked: unlockedPages, parent: parentOf)
    }

    /// Под замком (открытым или нет): такая страница не уходит ИИ и не показывается в чужих местах без явного действия.
    func isProtected(_ id: UUID) -> Bool {
        guard !pageLocks.isEmpty else { return false }
        return PageLock.lockingPage(of: id, locked: Set(pageLocks.keys), parent: parentOf) != nil
    }

    func hasOwnLock(_ id: UUID) -> Bool { pageLocks[id] != nil }

    /// Копия, шаблон и экспорт не должны выносить закрытый текст: ни саму страницу, ни закрытые страницы внутри неё.
    func allowsCopy(of id: UUID) -> Bool {
        guard !pageLocks.isEmpty else { return true }
        if isClosed(id) || pages.contains(where: { $0.id != id && isClosed($0.id) && isDescendant($0.id, of: id) }) {
            notice = L("Сначала откройте паролем страницу и закрытые страницы внутри неё.")
            return false
        }
        return true
    }

    /// Закрытую страницу нельзя вынести из-под замка предка: перенос внутри того же родителя можно.
    func allowsMove(_ id: UUID, toParent parent: UUID?) -> Bool {
        guard isClosed(id), parentOf(id) != parent else { return true }
        notice = L("Сначала откройте паролем страницу, из которой её переносите.")
        return false
    }

    /// Замки, которые сейчас закрыты: дерево не раскрывает их поддерево.
    var closedLockIDs: Set<UUID> { Set(pageLocks.keys.filter { !unlockedPages.contains($0) }) }

    private func isDescendant(_ page: UUID, of ancestor: UUID) -> Bool {
        var current = parentOf(page)
        var seen: Set<UUID> = []
        while let id = current, seen.insert(id).inserted {
            if id == ancestor { return true }
            current = parentOf(id)
        }
        return false
    }

    /// Ближайший неоткрытый замок — его и просит окно ввода.
    func closedLock(of id: UUID) -> UUID? {
        var current: UUID? = id
        var seen: Set<UUID> = []
        while let page = current, seen.insert(page).inserted {
            if pageLocks[page] != nil, !unlockedPages.contains(page) { return page }
            current = parentOf(page)
        }
        return nil
    }

    private func saveLocks() {
        let value = PageLock.encode(pageLocks)
        enqueue { try await self.store?.setMeta(PageLock.metaKey, value) }
    }

    // MARK: Действия

    func setLock(_ id: UUID) {
        guard let password = PasswordPrompt.askNew(title: L("Пароль на страницу"),
                                                   detail: L("Пароль нужен, чтобы открыть страницу и всё, что внутри неё. Это замок приложения, а не шифрование: файл пространства и резервные копии остаются читаемыми. Забытый пароль снимается через Touch ID или пароль Mac.")) else { return }
        pageLocks[id] = PageLockCrypto.make(page: id, password: password)
        unlockedPages.insert(id) // Кто поставил пароль, тот уже открыл страницу.
        saveLocks()
        notice = L("Пароль поставлен. Страница закроется после сна экрана или перезапуска; «Закрыть на замок» — сразу.")
    }

    func changeLock(_ id: UUID) {
        Task { @MainActor in
            guard await confirmOwner(id, reason: L("изменить пароль страницы")) else { return }
            guard let password = PasswordPrompt.askNew(title: L("Новый пароль"), detail: "") else { return }
            pageLocks[id] = PageLockCrypto.make(page: id, password: password)
            saveLocks()
            notice = L("Пароль изменён.")
        }
    }

    func removeLock(_ id: UUID) {
        Task { @MainActor in
            guard await confirmOwner(id, reason: L("снять пароль со страницы")) else { return }
            pageLocks[id] = nil
            unlockedPages.remove(id)
            saveLocks()
            notice = L("Пароль снят.")
        }
    }

    /// Пароль страницы или, если он забыт, Touch ID / пароль Mac.
    private func confirmOwner(_ id: UUID, reason: String) async -> Bool {
        guard let lock = pageLocks[id] else { return false }
        switch PasswordPrompt.askCurrent(title: L("Введите пароль страницы")) {
        case .password(let text):
            if PageLockCrypto.verify(text, lock) { return true }
            errorMessage = L("Неверный пароль.")
            return false
        case .deviceOwner:
            return await Self.deviceOwner(reason: reason)
        case .cancel:
            return false
        }
    }

    /// Открывает замок паролем; при удаче открывается и сама страница.
    func unlock(_ id: UUID, password: String) -> Bool {
        guard let lock = closedLock(of: id), let entry = pageLocks[lock], PageLockCrypto.verify(password, entry) else { return false }
        unlockedPages.insert(lock)
        continueAfterUnlock(id)
        return true
    }

    func unlockWithDeviceOwner(_ id: UUID) {
        guard let lock = closedLock(of: id) else { return continueAfterUnlock(id) }
        Task { @MainActor in
            guard await Self.deviceOwner(reason: L("открыть страницу под паролем")) else { return }
            unlockedPages.insert(lock)
            continueAfterUnlock(id)
        }
    }

    /// Выше мог быть ещё один замок: тогда окно спросит и его.
    private func continueAfterUnlock(_ id: UUID) {
        openPage(id)
    }

    /// «Закрыть на замок»: все открытые замки снова закрыты; открытая защищённая страница уходит под окно ввода.
    func lockAll() {
        guard !unlockedPages.isEmpty else { return }
        unlockedPages = []
        enqueue {
            if let peek = self.peek, self.isClosed(peek.pageID) { try await self.closePeekForLock() }
            switch self.section {
            case .page(let id), .database(let id):
                if self.isClosed(id) { try await self.showLocked(id) }
            default: break
            }
        }
    }

    static func deviceOwner(reason: String) async -> Bool {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else { return false }
        return (try? await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) ?? false
    }

    /// Сон экрана и блокировка сеанса закрывают все замки (вызывается из AppDelegate).
    func observeLockEvents() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.lockAll() }
            }
        }
        DistributedNotificationCenter.default().addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.lockAll() }
        }
    }
}

/// Окна ввода пароля: новый (дважды) и текущий (или Touch ID / пароль Mac).
enum PasswordPrompt {
    enum Answer { case password(String), deviceOwner, cancel }

    @MainActor
    static func askNew(title: String, detail: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        let first = NSSecureTextField(frame: NSRect(x: 0, y: 30, width: 260, height: 24))
        first.placeholderString = L("Пароль")
        let second = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        second.placeholderString = L("Ещё раз")
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 54))
        box.addSubview(first)
        box.addSubview(second)
        alert.accessoryView = box
        alert.addButton(withTitle: L("Поставить"))
        alert.addButton(withTitle: L("Отмена"))
        alert.window.initialFirstResponder = first
        first.nextKeyView = second
        while alert.runModal() == .alertFirstButtonReturn {
            let a = first.stringValue, b = second.stringValue
            if a.count < PageLock.minPassword {
                alert.informativeText = String(format: L("Нужно не меньше %d символов."), PageLock.minPassword)
            } else if a != b {
                alert.informativeText = L("Пароли не совпадают.")
            } else {
                return a
            }
            second.stringValue = ""
        }
        return nil
    }

    @MainActor
    static func askCurrent(title: String) -> Answer {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = L("Забыли пароль — подтвердите Touch ID или паролем Mac.")
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        alert.accessoryView = field
        alert.addButton(withTitle: L("Готово"))
        alert.addButton(withTitle: L("Отмена"))
        alert.addButton(withTitle: L("Touch ID или пароль Mac"))
        alert.window.initialFirstResponder = field
        switch alert.runModal() {
        case .alertFirstButtonReturn: return field.stringValue.isEmpty ? .cancel : .password(field.stringValue)
        case .alertThirdButtonReturn: return .deviceOwner
        default: return .cancel
        }
    }
}

/// Вместо содержимого закрытой страницы: название и поле пароля.
struct LockedPageScreen: View {
    @EnvironmentObject private var shell: ShellModel
    let id: UUID
    @State private var password = ""
    @State private var wrong = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "lock.fill").font(.system(size: 34, weight: .regular)).foregroundColor(Tokens.muted)
            Text(shell.pageTree.page(id)?.title.isEmpty == false ? shell.pageTree.page(id)!.title : L("Без названия"))
                .font(.system(size: 20, weight: .semibold)).foregroundColor(Tokens.ink)
            Text(lockedHere ? L("Страница защищена паролем.") : L("Страница внутри защищённой паролем страницы."))
                .font(.system(size: 13)).foregroundColor(Tokens.muted)
            SecureField(L("Пароль"), text: $password)
                .textFieldStyle(.roundedBorder)
                .frame(width: 240)
                .focused($focused)
                .onSubmit(submit)
                .onChange(of: password) { _, _ in wrong = false }
            if wrong { Text("Неверный пароль.").font(.system(size: 12)).foregroundColor(Tokens.danger) }
            HStack(spacing: 10) {
                Button("Touch ID или пароль Mac") { shell.unlockWithDeviceOwner(id) }.buttonStyle(NotesButtonStyle())
                Button("Открыть") { submit() }.buttonStyle(NotesButtonStyle(kind: .primary)).keyboardShortcut(.defaultAction)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Tokens.paper)
        .onAppear { focused = true }
    }

    private var lockedHere: Bool { shell.closedLock(of: id) == id }

    private func submit() {
        guard !password.isEmpty else { return }
        let ok = shell.unlock(id, password: password)
        password = ""
        wrong = !ok
    }
}

/// Пункты меню страницы: поставить, изменить или снять пароль, закрыть на замок.
struct PageLockMenuItems: View {
    @EnvironmentObject private var shell: ShellModel
    let page: UUID

    var body: some View {
        if shell.hasOwnLock(page) {
            Menu("Пароль") {
                Button("Изменить пароль…") { shell.changeLock(page) }
                Button("Снять пароль…") { shell.removeLock(page) }
            }
        } else {
            Button("Поставить пароль…") { shell.setLock(page) }
        }
        if !shell.unlockedPages.isEmpty { Button("Закрыть на замок") { shell.lockAll() } }
    }
}
