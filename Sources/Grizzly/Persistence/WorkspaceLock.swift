import Foundation

/// Блокировка пространства на всю сессию. Ядро снимает её при аварии процесса, поэтому файл не удаляется:
/// удаление создало бы гонку между двумя открытиями.
final class WorkspaceLock {
    private var fd: Int32 = -1

    init(url: URL) throws {
        fd = open(url.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o644)
        guard fd >= 0 else {
            if errno == EACCES || errno == EROFS || errno == EPERM { throw WorkspaceError.noPermission(url.deletingLastPathComponent().path) }
            throw WorkspaceError.storage(code: errno, detail: String(cString: strerror(errno)))
        }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            Darwin.close(fd)
            fd = -1
            if code == EWOULDBLOCK { throw WorkspaceError.alreadyOpen }
            if code == ENOTSUP || code == ENOLCK { throw WorkspaceError.lockUnsupported }
            throw WorkspaceError.storage(code: code, detail: String(cString: strerror(code)))
        }
    }

    deinit { release() }

    func release() {
        if fd >= 0 { Darwin.close(fd) }
        fd = -1
    }
}

/// Расположение файлов пространства.
struct WorkspaceLayout {
    let root: URL
    var database: URL { root.appendingPathComponent("workspace.sqlite") }
    var assets: URL { root.appendingPathComponent("assets", isDirectory: true) }
    var tmp: URL { root.appendingPathComponent("tmp", isDirectory: true) }
    var lock: URL { root.appendingPathComponent(".workspace.lock") }
}
