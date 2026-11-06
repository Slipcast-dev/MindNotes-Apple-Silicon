import Foundation

/// A small binary delta (rsync-style): the new file is described as pieces copied from the old file plus new bytes.
/// Used for update patches, so an update downloads only what changed instead of the whole application.
enum BinaryDelta {
    struct Failure: Error { let reason: String }

    /// Size of the blocks of the old file that are looked up while scanning the new one.
    private static let block = 256
    private static let modulus: UInt32 = 1 << 16

    // Operation tags in the delta stream.
    private static let opCopy: UInt8 = 0
    private static let opInsert: UInt8 = 1
    private static let opEnd: UInt8 = 2

    // MARK: Building

    static func make(old: Data, new: Data) -> Data {
        var out = Data()
        putVarint(UInt64(new.count), to: &out)
        let oldBytes = [UInt8](old), newBytes = [UInt8](new)
        let n = newBytes.count

        // Index of the old file: weak checksum of every aligned block -> offsets.
        var index: [UInt32: [Int]] = [:]
        if oldBytes.count >= block {
            var offset = 0
            while offset + block <= oldBytes.count {
                index[weak(oldBytes, offset, block).value, default: []].append(offset)
                offset += block
            }
        }

        var literalStart = 0
        func flushLiteral(upTo end: Int) {
            guard end > literalStart else { return }
            out.append(opInsert)
            putVarint(UInt64(end - literalStart), to: &out)
            out.append(contentsOf: newBytes[literalStart..<end])
        }

        var i = 0
        var rolling: Weak?
        while i + block <= n {
            let w = rolling ?? weak(newBytes, i, block)
            var matchOffset = -1
            if let candidates = index[w.value] {
                for c in candidates where equal(oldBytes, c, newBytes, i, block) { matchOffset = c; break }
            }
            if matchOffset >= 0 {
                // Grow the match forward as far as the bytes agree.
                var length = block
                while matchOffset + length < oldBytes.count, i + length < n,
                      oldBytes[matchOffset + length] == newBytes[i + length] { length += 1 }
                flushLiteral(upTo: i)
                out.append(opCopy)
                putVarint(UInt64(matchOffset), to: &out)
                putVarint(UInt64(length), to: &out)
                i += length
                literalStart = i
                rolling = nil
            } else {
                if i + block < n { rolling = w.rolled(out: newBytes[i], in: newBytes[i + block], size: block) } else { rolling = nil }
                i += 1
            }
        }
        flushLiteral(upTo: n)
        out.append(opEnd)
        return out
    }

    // MARK: Applying

    static func apply(old: Data, delta: Data) throws -> Data {
        let d = [UInt8](delta)
        var pos = 0
        guard let size = getVarint(d, &pos), size < (1 << 31) else { throw Failure(reason: "size") }
        var out = Data()
        out.reserveCapacity(Int(size))
        while true {
            guard pos < d.count else { throw Failure(reason: "truncated") }
            let op = d[pos]; pos += 1
            switch op {
            case opCopy:
                guard let offset = getVarint(d, &pos), let length = getVarint(d, &pos),
                      offset <= UInt64(old.count), length <= UInt64(old.count) - offset else { throw Failure(reason: "copy") }
                let start = old.startIndex + Int(offset)
                out.append(old[start..<start + Int(length)])
            case opInsert:
                guard let length = getVarint(d, &pos), length <= UInt64(d.count - pos) else { throw Failure(reason: "insert") }
                out.append(contentsOf: d[pos..<pos + Int(length)])
                pos += Int(length)
            case opEnd:
                guard out.count == Int(size) else { throw Failure(reason: "length") }
                return out
            default:
                throw Failure(reason: "operation")
            }
            if out.count > Int(size) { throw Failure(reason: "overrun") }
        }
    }

    // MARK: Internals

    private struct Weak {
        var a: UInt32
        var b: UInt32
        var value: UInt32 { (b << 16) | a }

        /// The window moves one byte: `out` leaves on the left, `in` enters on the right.
        func rolled(out: UInt8, in incoming: UInt8, size: Int) -> Weak {
            let m = BinaryDelta.modulus
            let na = (a &+ m &- UInt32(out) &+ UInt32(incoming)) % m
            let nb = (b &+ m &- ((UInt32(size) &* UInt32(out)) % m) &+ na) % m
            return Weak(a: na, b: nb)
        }
    }

    private static func weak(_ bytes: [UInt8], _ start: Int, _ length: Int) -> Weak {
        var a: UInt32 = 0, b: UInt32 = 0
        for k in 0..<length {
            a = (a &+ UInt32(bytes[start + k])) % modulus
            b = (b &+ a) % modulus
        }
        return Weak(a: a, b: b)
    }

    private static func equal(_ x: [UInt8], _ xs: Int, _ y: [UInt8], _ ys: Int, _ length: Int) -> Bool {
        for k in 0..<length where x[xs + k] != y[ys + k] { return false }
        return true
    }

    private static func putVarint(_ value: UInt64, to data: inout Data) {
        var v = value
        while v >= 0x80 { data.append(UInt8(v & 0x7F) | 0x80); v >>= 7 }
        data.append(UInt8(v))
    }

    private static func getVarint(_ bytes: [UInt8], _ pos: inout Int) -> UInt64? {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while pos < bytes.count, shift < 64 {
            let b = bytes[pos]; pos += 1
            result |= UInt64(b & 0x7F) << shift
            if b & 0x80 == 0 { return result }
            shift += 7
        }
        return nil
    }
}
