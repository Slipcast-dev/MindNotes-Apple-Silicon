import Foundation
import CryptoKit

/// Минимальный ustar: только обычные файлы. Архив читается и штатным `tar` как запасной путь.
enum Tar {
    static let blockSize = 512

    static func header(path: String, size: Int64, mtime: Int64) throws -> Data {
        let name = Array(path.utf8)
        guard name.count <= 100 else { throw WorkspaceError.backupInvalid("слишком длинный путь: \(path)") }
        var h = [UInt8](repeating: 0, count: blockSize)
        h.replaceSubrange(0..<name.count, with: name)
        put(&h, 100, octal(0o644, 7))
        put(&h, 108, octal(0, 7))
        put(&h, 116, octal(0, 7))
        if size < 0o77777777777 {
            put(&h, 124, octal(size, 11))
        } else {
            // base-256 для файлов от 8 ГиБ.
            h[124] = 0x80
            var v = size
            for i in stride(from: 135, to: 124, by: -1) { h[i] = UInt8(v & 0xFF); v >>= 8 }
        }
        put(&h, 136, octal(mtime, 11))
        put(&h, 148, Array("        ".utf8))
        h[156] = UInt8(ascii: "0")
        put(&h, 257, Array("ustar\0".utf8))
        put(&h, 263, Array("00".utf8))
        let sum = h.reduce(0) { $0 + Int($1) }
        put(&h, 148, octal(Int64(sum), 6) + [0, UInt8(ascii: " ")])
        return Data(h)
    }

    private static func put(_ h: inout [UInt8], _ at: Int, _ bytes: [UInt8]) {
        h.replaceSubrange(at..<(at + bytes.count), with: bytes)
    }

    private static func octal(_ v: Int64, _ width: Int) -> [UInt8] {
        let s = String(v, radix: 8)
        return Array((String(repeating: "0", count: max(0, width - s.count)) + s).utf8)
    }

    struct Entry {
        var path: String
        var size: Int64
    }

    /// Разбирает заголовок. nil — нулевой блок. Записи другого типа (ссылки, каталоги) отклоняются.
    static func parse(_ block: Data) throws -> Entry? {
        let h = [UInt8](block)
        guard h.count == blockSize else { throw WorkspaceError.backupInvalid("обрезанный заголовок") }
        if h.allSatisfy({ $0 == 0 }) { return nil }
        var sum = 0
        for (i, b) in h.enumerated() { sum += (148..<156).contains(i) ? 32 : Int(b) }
        guard readOctal(Array(h[148..<156])) == Int64(sum) else { throw WorkspaceError.backupInvalid("неверная контрольная сумма заголовка") }
        guard h[156] == UInt8(ascii: "0") || h[156] == 0 else { throw WorkspaceError.backupInvalid("запись не является обычным файлом") }
        let nameEnd = h[0..<100].firstIndex(of: 0) ?? 100
        guard let path = String(bytes: h[0..<nameEnd], encoding: .utf8) else { throw WorkspaceError.backupInvalid("неверное имя файла") }
        var size: Int64
        if h[124] & 0x80 != 0 {
            size = 0
            for b in h[125..<136] {
                guard size <= (Int64.max >> 8) else { throw WorkspaceError.backupInvalid("неверный размер") }
                size = (size << 8) | Int64(b)
            }
        } else {
            guard let v = readOctal(Array(h[124..<136])) else { throw WorkspaceError.backupInvalid("неверный размер") }
            size = v
        }
        return Entry(path: path, size: size)
    }

    private static func readOctal(_ bytes: [UInt8]) -> Int64? {
        let digits = bytes.drop { $0 == 32 }.prefix { $0 >= 48 && $0 <= 55 }
        guard !digits.isEmpty, digits.count <= 20 else { return nil }
        var v: Int64 = 0
        for d in digits { v = v * 8 + Int64(d - 48) }
        return v
    }

    static func padding(_ size: Int64) -> Int {
        let r = Int(size % Int64(blockSize))
        return r == 0 ? 0 : blockSize - r
    }

    static func hex(_ digest: SHA256.Digest) -> String { digest.map { String(format: "%02x", $0) }.joined() }
}
