import Foundation

/// ZIP без сжатия с режимом Unix у каждой записи: так создаются ссылки и особые файлы для проверки оглавления.
func unixZip(_ entries: [(name: String, body: String, mode: UInt32)]) -> Data {
    unixZipData(entries.map { ($0.name, Data($0.body.utf8), $0.mode) })
}

func unixZipData(_ entries: [(name: String, body: Data, mode: UInt32)]) -> Data {
    var table = [UInt32](repeating: 0, count: 256)
    for i in 0..<256 {
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1 }
        table[i] = c
    }
    func crc(_ bytes: [UInt8]) -> UInt32 { ~bytes.reduce(UInt32.max) { table[Int(($0 ^ UInt32($1)) & 0xFF)] ^ ($0 >> 8) } }
    func le16(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)] }
    func le32(_ v: UInt32) -> [UInt8] { (0..<4).map { UInt8((v >> (8 * $0)) & 0xFF) } }
    var out: [UInt8] = [], central: [UInt8] = []
    for entry in entries {
        let n = Array(entry.name.utf8), body = [UInt8](entry.body), sum = crc(body), offset = UInt32(out.count)
        let common = le16(20) + le16(0) + le16(0) + le16(0) + le16(0) + le32(sum) + le32(UInt32(body.count)) + le32(UInt32(body.count)) + le16(n.count) + le16(0)
        out += le32(0x04034b50) + common + n + body
        // Создано в Unix (3), внешние атрибуты — режим файла в старших 16 битах.
        central += le32(0x02014b50) + le16(3 << 8 | 20) + common + le16(0) + le16(0) + le16(0) + le32(entry.mode << 16) + le32(offset) + n
    }
    let start = UInt32(out.count)
    out += central
    out += le32(0x06054b50) + le16(0) + le16(0) + le16(entries.count) + le16(entries.count) + le32(UInt32(central.count)) + le32(start) + le16(0)
    return Data(out)
}

/// Вложенные части ZIP не должны писать через ссылки за пределы папки распаковки (аудит: CWE-61).
func runArchiveSafetyTests() async {
    let fm = FileManager.default
    func ditto(_ folder: URL, _ out: URL) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-c", "-k", folder.path, out.path]
        try p.run(); p.waitUntilExit()
    }
    /// Следов распаковки (import-*, .part-*) в `dir` не остаётся.
    func leftovers(_ dir: URL) -> [String] {
        ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasPrefix("import-") || $0.hasPrefix(".part-") }
    }

    await test("ZIP: ссылка во внешнем архиве и запись через неё во вложенной части не меняют внешний файл") {
        try await withTempDir { dir in
            let outside = dir.appendingPathComponent("outside")
            try fm.createDirectory(at: outside, withIntermediateDirectories: true)
            let marker = outside.appendingPathComponent("synthetic.txt")
            try Data("original-audit-marker".utf8).write(to: marker)

            // Вариант из аудита: внешний архив собран системным ditto (ссылка pivot → outside и part.zip),
            // во вложенной части — только файл pivot/synthetic.txt без записи каталога: так прежний код писал через ссылку.
            let part = unixZip([("pivot/synthetic.txt", "overwritten-audit-marker", 0o100644)])
            let outerSrc = dir.appendingPathComponent("outer-src")
            try fm.createDirectory(at: outerSrc, withIntermediateDirectories: true)
            try part.write(to: outerSrc.appendingPathComponent("part.zip"))
            try fm.createSymbolicLink(at: outerSrc.appendingPathComponent("pivot"), withDestinationURL: outside)
            let outer = dir.appendingPathComponent("outer.zip")
            try ditto(outerSrc, outer)
            let work = dir.appendingPathComponent("work")
            try fm.createDirectory(at: work, withIntermediateDirectories: true)
            let error = await checkThrows("ditto: ссылка + вложенная часть") { try ArchiveExtract.extract(outer, into: work) }
            check(error is ImportError, "понятная ошибка импорта: \(String(describing: error))")

            // Тот же приём в архиве, собранном вручную (ссылка с относительной целью).
                        let crafted = unixZipData([("pivot", Data("../../outside".utf8), 0o120777), ("part.zip", part, 0o100644)])
            let craftedURL = dir.appendingPathComponent("crafted.zip")
            try crafted.write(to: craftedURL)
            await checkThrows("ручной архив: ссылка + вложенная часть") { try ArchiveExtract.extract(craftedURL, into: work) }

            checkEqual(try String(contentsOf: marker, encoding: .utf8), "original-audit-marker", "внешний маркер не перезаписан")
            checkEqual(try fm.contentsOfDirectory(atPath: outside.path), ["synthetic.txt"], "во внешней папке ничего не появилось")
            checkEqual(leftovers(work), [], "временные папки удалены")
        }
    }

    await test("ZIP: оглавление отклоняет ссылки и особые файлы до распаковки") {
        try await withTempDir { dir in
            let work = dir.appendingPathComponent("work")
            try fm.createDirectory(at: work, withIntermediateDirectories: true)
            for (name, entries) in [
                ("ссылка", [(name: "a", body: "/etc/hosts", mode: UInt32(0o120777))]),
                ("FIFO", [(name: "f", body: "", mode: UInt32(0o010644))]),
                ("устройство", [(name: "d", body: "", mode: UInt32(0o020644))]),
            ] {
                let url = dir.appendingPathComponent("\(name).zip")
                try unixZip(entries).write(to: url)
                let error = await checkThrows(name) { try ZipDirectory.read(url) }
                check(error is ImportError, "\(name): ошибка импорта")
                await checkThrows("\(name): extract") { try ArchiveExtract.extract(url, into: work) }
            }
            // Вложенная часть, представленная ссылкой на файл вне архива.
            let elsewhere = dir.appendingPathComponent("elsewhere.zip")
            try unixZip([("x.md", "x", 0o100644)]).write(to: elsewhere)
            let linked = dir.appendingPathComponent("linked.zip")
            try unixZip([("Export-Part-1.zip", elsewhere.path, 0o120644)]).write(to: linked)
            await checkThrows("часть-ссылка") { try ArchiveExtract.extract(linked, into: work) }

            let ok = dir.appendingPathComponent("ok.zip")
            try unixZip([("Папка/", "", 0o040755), ("Папка/Стр.md", "текст", 0o100644), ("b.md", "бэ", 0)]).write(to: ok)
            let summary = try ZipDirectory.read(ok)
            checkEqual(summary, ZipDirectory.Summary(entries: 3, uncompressed: Int64("текст".utf8.count + "бэ".utf8.count)))
            for broken in [Data(), Data("не архив".utf8), Data(unixZip([("a", "b", 0o100644)]).dropLast(5))] {
                let url = dir.appendingPathComponent("broken.zip")
                try broken.write(to: url)
                await checkThrows("повреждённое оглавление") { try ZipDirectory.read(url) }
            }
            checkEqual(leftovers(work), [], "временные папки удалены")
        }
    }

    await test("ZIP: многочастный экспорт сливается, общий предел объёма считает все части") {
        try await withTempDir { dir in
            let work = dir.appendingPathComponent("work")
            try fm.createDirectory(at: work, withIntermediateDirectories: true)
            let one = dir.appendingPathComponent("one")
            try fm.createDirectory(at: one.appendingPathComponent("Экспорт/Папка"), withIntermediateDirectories: true)
            try Data("первая".utf8).write(to: one.appendingPathComponent("Экспорт/Папка/A.md"))
            try Data("старая".utf8).write(to: one.appendingPathComponent("Экспорт/общая.md"))
            let two = dir.appendingPathComponent("two")
            try fm.createDirectory(at: two.appendingPathComponent("Экспорт/Папка"), withIntermediateDirectories: true)
            try Data("вторая".utf8).write(to: two.appendingPathComponent("Экспорт/Папка/B.md"))
            try Data("новая".utf8).write(to: two.appendingPathComponent("Экспорт/общая.md"))
            let outerSrc = dir.appendingPathComponent("outer")
            try fm.createDirectory(at: outerSrc, withIntermediateDirectories: true)
            try ditto(one, outerSrc.appendingPathComponent("Export-Part-1.zip"))
            try ditto(two, outerSrc.appendingPathComponent("Export-Part-2.zip"))
            let archive = dir.appendingPathComponent("export.zip")
            try ditto(outerSrc, archive)

            let out = try ArchiveExtract.extract(archive, into: work)
            checkEqual(try String(contentsOf: out.appendingPathComponent("Экспорт/Папка/A.md"), encoding: .utf8), "первая")
            checkEqual(try String(contentsOf: out.appendingPathComponent("Экспорт/Папка/B.md"), encoding: .utf8), "вторая", "папки частей слиты")
            let shared = try String(contentsOf: out.appendingPathComponent("Экспорт/общая.md"), encoding: .utf8)
            checkEqual(shared, "новая", "повторяющийся путь: последняя часть заменяет файл, как прежде")
            check(!fm.fileExists(atPath: out.appendingPathComponent("Export-Part-1.zip").path), "части удалены")
            checkEqual(leftovers(work), [out.lastPathComponent], "кроме результата временных папок нет")
            try fm.removeItem(at: out)

            // Каждая часть по отдельности укладывается в предел, вместе — нет.
            // Части сжаты: сам внешний архив мал, а содержимое частей вместе превышает предел.
            let big = Data(String(repeating: "x", count: 4000).utf8)
            let p1 = dir.appendingPathComponent("p1.zip"), p2 = dir.appendingPathComponent("p2.zip")
            for (url, name) in [(p1, "a.md"), (p2, "b.md")] {
                let src = dir.appendingPathComponent("src-" + name)
                try fm.createDirectory(at: src, withIntermediateDirectories: true)
                try big.write(to: src.appendingPathComponent(name))
                try ditto(src, url)
            }
            let pair = dir.appendingPathComponent("pair")
            try fm.createDirectory(at: pair, withIntermediateDirectories: true)
            try fm.copyItem(at: p1, to: pair.appendingPathComponent("Part-1.zip"))
            try fm.copyItem(at: p2, to: pair.appendingPathComponent("Part-2.zip"))
            let pairZip = dir.appendingPathComponent("pair.zip")
            try ditto(pair, pairZip)
            let single = try ArchiveExtract.extract(p1, into: work, maxBytes: 6000)
            try fm.removeItem(at: single)
            let error = await checkThrows("общий предел") { try ArchiveExtract.extract(pairZip, into: work, maxBytes: 6000) }
            check(error.map { if case ImportError.tooLarge = $0 { return true } else { return false } } ?? false, "ошибка объёма: \(String(describing: error))")

            // Файл в одной части и папка с тем же именем в другой — понятная ошибка.
            let fileSide = dir.appendingPathComponent("f.zip"), dirSide = dir.appendingPathComponent("d.zip")
            try unixZip([("X", "файл", 0o100644)]).write(to: fileSide)
            try unixZip([("X/", "", 0o040755), ("X/y.md", "y", 0o100644)]).write(to: dirSide)
            let clash = dir.appendingPathComponent("clash")
            try fm.createDirectory(at: clash, withIntermediateDirectories: true)
            try fm.copyItem(at: fileSide, to: clash.appendingPathComponent("1.zip"))
            try fm.copyItem(at: dirSide, to: clash.appendingPathComponent("2.zip"))
            let clashZip = dir.appendingPathComponent("clash.zip")
            try ditto(clash, clashZip)
            await checkThrows("файл и папка с одним именем") { try ArchiveExtract.extract(clashZip, into: work) }
            checkEqual(leftovers(work), [], "временные папки удалены")
        }
    }
}
