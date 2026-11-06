import Foundation

/// Ошибки пространства. Сообщения показываются пользователю и не маскируются пустым пространством.
enum WorkspaceError: Error, Equatable, LocalizedError {
    case notADirectory(String)
    case noPermission(String)
    case alreadyOpen
    case lockUnsupported
    case directoryNotEmpty(String)
    case notAWorkspace(String)
    case schemaTooNew(found: Int, supported: Int)
    case corrupted(String)
    case migrationFailed(version: Int, detail: String)
    case wouldCreateCycle
    case pageNotFound(UUID)
    case storage(code: Int32, detail: String)
    case diskFull
    case backupInvalid(String)
    case restoreTargetNotEmpty(String)

    private func t(_ key: String) -> String { NSLocalizedString(key, comment: "") }

    var errorDescription: String? {
        switch self {
        case .notADirectory(let p): return String(format: t("Папка пространства не найдена: %@"), p)
        case .noPermission(let p): return String(format: t("Нет прав на запись в папку: %@"), p)
        case .alreadyOpen: return t("Это пространство уже открыто в другом окне или приложении.")
        case .lockUnsupported: return t("Файловая система этой папки не поддерживает блокировку. Выберите папку на локальном диске.")
        case .directoryNotEmpty(let p): return String(format: t("Папка не пуста. Для нового пространства выберите пустую папку: %@"), p)
        case .notAWorkspace(let p): return String(format: t("В этой папке нет пространства Grizzly Notes: %@"), p)
        case .schemaTooNew(let found, let supported):
            return String(format: t("Пространство создано более новой версией (формат %d, поддерживается %d). Откройте его в новой сборке; данные не изменены."), found, supported)
        case .corrupted(let d): return String(format: t("База пространства повреждена: %@. Восстановите её из резервной копии."), d)
        case .migrationFailed(let v, let d): return String(format: t("Не удалось обновить формат до версии %d: %@. Изменения отменены, резервная копия сохранена."), v, d)
        case .wouldCreateCycle: return t("Нельзя переместить страницу в неё саму или в её подстраницу.")
        case .pageNotFound: return t("Страница не найдена.")
        case .storage(let code, let d): return String(format: t("Ошибка хранилища (%d): %@"), code, d)
        case .diskFull: return t("Не удалось сохранить: нет свободного места. Правки остаются в приложении.")
        case .backupInvalid(let d): return String(format: t("Резервная копия не прошла проверку: %@"), d)
        case .restoreTargetNotEmpty(let p): return String(format: t("Восстанавливать можно только в новую или пустую папку: %@"), p)
        }
    }
}
