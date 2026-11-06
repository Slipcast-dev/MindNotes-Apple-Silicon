// Plain executable test (XCTest needs full Xcode). Run: ./scripts/test.sh
import Foundation

var failures = 0
func check(_ ok: Bool, _ what: String) {
    if !ok { failures += 1; print("FAIL: \(what)") } else { print("ok: \(what)") }
}

// Quick Look HTML: links and quotes
let evil = HTMLRenderer.markdown(["[x](a\"onmouseover=\"alert(1))", "[js](javascript:alert(1))", "[ok](https://example.com)"])
check(!evil.contains("\"onmouseover"), "quote in link target cannot open an attribute")
check(!evil.contains("javascript:alert(1)\">"), "javascript: link is not an anchor")
check(evil.contains("<a href=\"https://example.com\">ok</a>"), "https link stays clickable")
check(HTMLRenderer.escape("<a href=\"x\">&'") == "&lt;a href=&quot;x&quot;&gt;&amp;&#39;", "escape covers < > & quotes")

// Encodings
let dir = FileManager.default.temporaryDirectory.appendingPathComponent("grizzly-test-\(getpid())")
try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
for (enc, text) in [("UTF-8", "Привет"), ("UTF-16", "Привет"), ("Windows-1251", "Привет")] {
    let url = dir.appendingPathComponent("t.txt")
    try FileLoader.write(text, to: url, encoding: enc)
    let back = try FileLoader.read(url)
    check(back.text == text && back.encoding == enc, "\(enc) round trip")
}
do { try FileLoader.write("日本", to: dir.appendingPathComponent("x.txt"), encoding: "Windows-1251"); check(false, "unmappable text throws") }
catch { check(true, "unmappable text throws") }

// File types and CSV
check(FileType(url: URL(fileURLWithPath: "/a/B.MD")) == .markdown, "md type")
check(FileType(url: URL(fileURLWithPath: "/a/b.xyz")) == .text, "unknown ext is text")
let table = CSVTable(lines: ["a;b", "1;\"x;y\""], delimiter: CSVTable.detectDelimiter(url: URL(fileURLWithPath: "/a.csv"), lines: ["a;b", "1;\"x;y\""]))
check(table.rows.count == 2 && table.rows[1].cells.contains("x;y"), "csv quoted cell with delimiter")
check(!MarkdownParser.parse(["# T", "", "- a", "- b"]).isEmpty, "markdown parses")

// History survives removing the file from the library
let histFile = dir.appendingPathComponent("h.md")
try "# hi".write(to: histFile, atomically: true, encoding: .utf8)
let lib = LibraryStore(storeURL: dir.appendingPathComponent("lib.json"))
let entry = lib.add(url: histFile)
lib.recordOpened(histFile)
check(lib.recents.count == 1, "opened file is in history")
lib.remove(entry.id)
check(lib.recents.count == 1 && lib.file(atPath: histFile.standardizedFileURL.path) == nil, "history keeps a file removed from the library")
lib.recordOpened(histFile)
check(lib.recents.count == 1, "history has no duplicates")
lib.flush()
check(LibraryStore(storeURL: dir.appendingPathComponent("lib.json")).recents.count == 1, "history is saved to disk")
lib.clearRecents()
check(lib.recents.isEmpty, "clear empties history")

// Syntax highlighting of programming languages
func roles(_ line: String, _ type: FileType, state: Int = 0) -> [(String, SyntaxRole)] {
    let ns = line as NSString
    return SyntaxEngine.spans(line, type: type, state: state).spans.map { (ns.substring(with: $0.range), $0.role) }
}
func has(_ list: [(String, SyntaxRole)], _ text: String, _ role: SyntaxRole) -> Bool { list.contains { $0.0.trimmingCharacters(in: .whitespaces) == text && $0.1 == role } }

check(FileType(url: URL(fileURLWithPath: "/a/x.py")) == .python && FileType(url: URL(fileURLWithPath: "/a/x.hpp")) == .cpp
      && FileType(url: URL(fileURLWithPath: "/a/x.tsx")) == .typescript && FileType(url: URL(fileURLWithPath: "/a/x.cs")) == .csharp, "code extensions map to types")
let py = roles("def run(x): # go", .python)
check(has(py, "def", .keyword) && has(py, "# go", .comment), "python keyword and comment")
check(SyntaxEngine.states(["x = \"\"\"doc", "more", "end\"\"\"", "y = 1"], type: .python) == [0, 1, 1, 0], "python triple-quoted string spans lines")
check(SyntaxEngine.states(["a /* b", "c */ d", "e"], type: .cpp) == [0, 1, 0], "C block comment spans lines")
check(has(roles("c */ d", .cpp, state: 1), "c */", .comment), "closing line of a block comment is colored")
check(has(roles("#include <vector>", .cpp), "#include", .keyword) && has(roles("int x = 0x1F;", .cpp), "0x1F", .number), "C++ preprocessor and hex number")
check(has(roles("let s = \"a // b\" // c", .swift), "\"a // b\"", .string) && has(roles("let s = \"a // b\" // c", .swift), "// c", .comment), "comment marker inside a string is not a comment")
check(has(roles("public class Foo : Bar", .csharp), "class", .keyword) && has(roles("public class Foo : Bar", .csharp), "Foo", .key), "C# keyword and type")
check(SyntaxEngine.states(["const a = `x", "y`;", "z"], type: .javascript) == [0, 1, 0], "JS template literal spans lines")
check(has(roles("const n = null;", .typescript), "null", .number) && has(roles("interface A {}", .typescript), "interface", .keyword), "TypeScript literals and keywords")
check(has(roles("  color: #fff;", .css), "color", .key) && has(roles("  color: #fff;", .css), "#fff", .number), "CSS property and color")
check(!has(roles("a:hover {", .css), "a", .key), "CSS selector with pseudo-class is not a property")
check(has(roles("$x = 1; // c", .php), "$x", .key) && has(roles("$x = 1; // c", .php), "// c", .comment), "PHP variable and comment")
check(SyntaxEngine.states(["a", "b"], type: .json).isEmpty, "stateless formats carry no state")
check(FileType.fromFenceTag("Python title=x") == .python && FileType.fromFenceTag("c++") == .cpp && FileType.fromFenceTag("nope") == nil, "fenced code language tags")
check(FileType.template(forExtension: "json") == "{\n  \n}\n" && FileType.template(forExtension: "xyz") == "", "new file templates")

// Tags
let tagFile = lib.add(url: histFile)
check(lib.createTag("#Работа") == "Работа" && lib.createTag("работа") == "Работа" && lib.createTag("  ") == nil, "tags are cleaned and not duplicated")
lib.toggleTag(tagFile.id, "Работа")
check(lib.files(withTag: "работа").count == 1 && lib.hasTag(tagFile.id, "РАБОТА"), "files are found by tag, case-insensitively")
lib.flush()
check(LibraryStore(storeURL: dir.appendingPathComponent("lib.json")).files(withTag: "Работа").count == 1, "tags are saved to disk")
lib.renameTag("Работа", to: "Дом")
check(lib.files(withTag: "Дом").count == 1 && lib.files(withTag: "Работа").isEmpty, "renaming a tag moves its files")
lib.deleteTag("Дом")
check(lib.allTags.isEmpty && lib.files(withTag: "Дом").isEmpty, "deleting a tag removes it from files")

check(LibraryStore.extractTags(from: "# Title\n#12 and #работа, #Work-1 and #work. See a#b, http://x.y/#frag, &#39; #")
      == ["12", "работа", "Work-1", "work"], "hashtags are read from text, headings and fragments are not tags")
let textTagFile = lib.add(url: histFile)
lib.setInlineTags(textTagFile.id, ["идея"])
check(lib.files(withTag: "Идея").count == 1 && lib.allTags.contains("идея") && lib.hasTag(textTagFile.id, "идея"), "tags written in the text are tags of the file")

check(LibraryStore.replaceTag("work", with: "дом", in: "#Work and #workshop, a#work, #work.\n#WORK") == "#дом and #workshop, a#work, #дом.\n#дом", "renaming a tag changes only whole #tags")
check(LibraryStore.replaceTag("work", with: nil, in: "x #work y, #work") == "x y, ", "deleting a tag removes it with the following space")
check(LibraryStore.countTag("work", in: "#work #Work #works") == 2, "tag occurrences are counted")
let tm = LibraryStore.tagMatches(in: "a #one-, #два")
check(tm.map(\.tag) == ["one", "два"] && (("a #one-, #два" as NSString).substring(with: tm[0].range) == "#one"), "tag ranges exclude trailing dashes")
let f2 = lib.add(url: dir.appendingPathComponent("second.md"))
lib.setInlineTags(f2.id, ["идея", "план"]); lib.setInlineTags(textTagFile.id, ["идея"])
check(lib.files(withAllTags: ["идея"]).count == 2 && lib.files(withAllTags: ["идея", "план"]).map(\.id) == [f2.id] && lib.files(withAllTags: []).isEmpty, "several tags narrow the list down")

check(LibraryStore.extractTags(from: "#🍕 и #идея💡 и #a_b, 😀#x") == ["🍕", "идея💡", "a_b", "x"], "emoji can be part of a tag name")
check(LibraryStore.replaceTag("🍕", with: "пицца", in: "ем #🍕 и #🍕х") == "ем #пицца и #🍕х", "renaming an emoji tag")

// Updates
check(UpdateCheck.isNewer("1.2.0", than: "1.1.0") && UpdateCheck.isNewer("v1.10.0", than: "1.9.9") && UpdateCheck.isNewer("2.0", than: "1.99.9"), "newer versions are detected")
check(!UpdateCheck.isNewer("1.1.0", than: "1.1.0") && !UpdateCheck.isNewer("1.1", than: "1.1.0") && !UpdateCheck.isNewer("1.0.9", than: "1.1.0"), "same or older versions are not updates")
let notes = "## SHA-256\n`\(String(repeating: "A", count: 64))`  Grizzly-1.2.0-arm64.dmg\n\(String(repeating: "b", count: 64)) Grizzly-1.2.0-x64.dmg"
check(UpdateCheck.checksum(in: notes, for: "Grizzly-1.2.0-arm64.dmg") == String(repeating: "a", count: 64)
      && UpdateCheck.checksum(in: notes, for: "Grizzly-1.2.0-x64.dmg") == String(repeating: "b", count: 64)
      && UpdateCheck.checksum(in: notes, for: "other.dmg") == nil, "checksum is read from the release notes")
let base = "https://github.com/Slipcast-dev/Grizzly/releases/download/v1.2.0/"
let release = "{\"tag_name\":\"v1.2.0\",\"body\":\"notes\",\"assets\":[{\"name\":\"Grizzly-1.2.0-x64.dmg\",\"browser_download_url\":\"\(base)Grizzly-1.2.0-x64.dmg\"},{\"name\":\"Grizzly-1.2.0-arm64.dmg\",\"browser_download_url\":\"\(base)Grizzly-1.2.0-arm64.dmg\"}]}"
let parsed = try UpdateCheck.parse(Data(release.utf8), assetSuffix: "-arm64.dmg")
check(parsed?.version == "1.2.0" && parsed?.assetName == "Grizzly-1.2.0-arm64.dmg", "release JSON: version and the asset for this architecture")
check(try UpdateCheck.parse(Data(release.utf8), assetSuffix: "-win.exe") == nil, "release without a matching asset is ignored")
check(!UpdateCheck.isTrustedDownload(URL(string: "https://evil.example/a.dmg")!) && !UpdateCheck.isTrustedDownload(URL(string: "http://github.com/a.dmg")!)
      && UpdateCheck.isTrustedDownload(URL(string: "https://objects.githubusercontent.com/a.dmg")!), "downloads are limited to GitHub over HTTPS")


// Rich text: parser
let rich = MarkdownParser.parse([
    "# Title", "<div align=\"center\">Centered</div>", "", "* dot", "* dot 2", "- dash", "- [ ] todo", "- [x] done", "", "> quote",
])
func kinds(_ blocks: [MDBlock]) -> [String] {
    blocks.map { b -> String in
        switch b {
        case .heading: return "heading"
        case .paragraph: return "paragraph"
        case .bullets: return "bullets"
        case .dashes: return "dashes"
        case .numbered: return "numbered"
        case .tasks: return "tasks"
        case .code: return "code"
        case .quote: return "quote"
        case .rule: return "rule"
        case .table: return "table"
        case .aligned(let a, _): return "aligned-\(a.rawValue)"
        }
    }
}
check(kinds(rich) == ["heading", "aligned-center", "bullets", "dashes", "tasks", "quote"], "blocks: headings, alignment, dot / dash / check lists, quote")
if case .tasks(let items) = rich[4] { check(items.count == 2 && !items[0].done && items[1].done && items[1].line == 7, "check list items know their line") }
check(MarkdownParser.splitAlignment("<div align=\"right\">x</div>").0 == .right && MarkdownParser.splitAlignment("plain").0 == nil, "alignment wrapper is read")
check(MarkdownParser.sectionKeys(MarkdownParser.parse(["# A", "## B", "### C", "# A"])).count == 3, "only Title and Heading lines fold, equal ones get their own key")
check(InlineMarkup.stripped(InlineMarkup.prepare("a <u>b</u> <mark class=\"pink\">c</mark> `<u>`")) == "a b c `<u>`", "underline and highlight tags are placeholders, code is left alone")

// Rich text: editor commands
func run(_ command: FormatCommand, _ text: String, _ sel: NSRange) -> (String, NSRange)? {
    guard let e = RichFormat.apply(command, text: text, selection: sel) else { return nil }
    return ((text as NSString).replacingCharacters(in: e.range, with: e.text), e.selection)
}
check(run(.paragraph(.title), "Hello", NSRange(location: 2, length: 0))?.0 == "# Hello", "Title")
check(run(.paragraph(.subheading), "## Hello", NSRange(location: 0, length: 0))?.0 == "### Hello", "Subheading replaces Heading")
check(run(.paragraph(.body), "## Hello", NSRange(location: 0, length: 0))?.0 == "Hello", "Body removes the heading")
check(run(.paragraph(.monospaced), "code", NSRange(location: 0, length: 4))?.0 == "```\ncode\n```", "Monospaced fences the lines")
check(run(.paragraph(.monospaced), "```\ncode\n```", NSRange(location: 4, length: 4))?.0 == "code", "Monospaced again takes the fence off")
check(run(.inline(.bold), "a word b", NSRange(location: 2, length: 4))?.0 == "a **word** b", "bold")
check(run(.inline(.bold), "a **word** b", NSRange(location: 4, length: 4))?.0 == "a word b", "bold off")
check(run(.inline(.italic), "a **word** b", NSRange(location: 4, length: 4))?.0 == "a ***word*** b", "italic inside bold")
check(run(.inline(.italic), "a ***word*** b", NSRange(location: 5, length: 4))?.0 == "a **word** b", "italic off inside bold")
check(run(.inline(.bold), "a word b", NSRange(location: 4, length: 0))?.0 == "a **word** b", "no selection: the word under the caret")
check(run(.inline(.underline), "x", NSRange(location: 0, length: 1))?.0 == "<u>x</u>" && run(.inline(.underline), "<u>x</u>", NSRange(location: 3, length: 1))?.0 == "x", "underline on and off")
check(run(.inline(.strike), "x", NSRange(location: 0, length: 1))?.0 == "~~x~~", "strikethrough")
check(run(.highlight("mint"), "a b", NSRange(location: 2, length: 1))?.0 == "a <mark class=\"mint\">b</mark>", "highlight")
check(run(.highlight("blue"), "<mark class=\"mint\">b</mark>", NSRange(location: 19, length: 1))?.0 == "<mark class=\"blue\">b</mark>", "highlight color changes")
check(run(.highlight(nil), "<mark class=\"mint\">b</mark>", NSRange(location: 19, length: 1))?.0 == "b", "highlight removed")
check(run(.align(.center), "## Hi", NSRange(location: 0, length: 0))?.0 == "## <div align=\"center\">Hi</div>", "alignment keeps the heading marker")
check(run(.align(.left), "<div align=\"right\">Hi</div>", NSRange(location: 0, length: 0))?.0 == "Hi", "left alignment removes the wrapper")
check(run(.list(.bullet), "a\nb", NSRange(location: 0, length: 3))?.0 == "* a\n* b", "bullets")
check(run(.list(.numbered), "a\nb", NSRange(location: 0, length: 3))?.0 == "1. a\n2. b", "numbered list")
check(run(.list(.checklist), "- a", NSRange(location: 0, length: 3))?.0 == "- [ ] a", "check list replaces a dash list")
check(run(.list(.dash), "- a\n- b", NSRange(location: 0, length: 7))?.0 == "a\nb", "dash list off")
check(run(.quote, "a\nb", NSRange(location: 0, length: 3))?.0 == "> a\n> b" && run(.quote, "> a", NSRange(location: 0, length: 3))?.0 == "a", "quote on and off")
check(run(.rule, "text", NSRange(location: 4, length: 0))?.0 == "text\n\n---\n", "rule goes after a blank line")
check(RichFormat.returnEdit(text: "- a", caret: 3)?.text == "\n- " && RichFormat.returnEdit(text: "1. a", caret: 4)?.text == "\n2. " && RichFormat.returnEdit(text: "- [x] a", caret: 7)?.text == "\n- [ ] ", "Return continues a list")
check(RichFormat.returnEdit(text: "- ", caret: 2)?.text == "" && RichFormat.returnEdit(text: "plain", caret: 5) == nil, "Return on an empty item ends the list")
let tableText = "| A | B |\n| --- | --- |\n| 1 | 2 |"
check(RichFormat.isInTable(text: tableText, caret: 14) && !RichFormat.isInTable(text: "no table", caret: 2), "the caret in a table is found")
check(run(.table(.addRow), tableText, NSRange(location: 25, length: 0))?.0.components(separatedBy: "\n").count == 4, "table: add a row")
check(run(.table(.addColumn), tableText, NSRange(location: 25, length: 0))?.0.components(separatedBy: "\n")[0].filter { $0 == "|" }.count == 4, "table: add a column")
check(run(.table(.moveColumnRight), tableText, NSRange(location: 2, length: 0))?.0.hasPrefix("| B   | A   |") == true, "table: move a column")
check(run(.table(.toText), tableText, NSRange(location: 2, length: 0))?.0 == "A\tB\n1\t2", "table back to plain text")
check(run(.table(.insert), "", NSRange(location: 0, length: 0))?.0.hasPrefix("| Колонка 1") == true, "table: insert")
check(RichFormat.movingTaskToEnd(of: ["- [x] a", "- [ ] b", "- [ ] c"], at: 0) == ["- [ ] b", "- [ ] c", "- [x] a"], "a ticked item moves to the end of its list")
check(RichFormat.toggledTask("- [ ] a")?.text == "- [x] a" && RichFormat.toggledTask("  * [x] b")?.done == false && RichFormat.toggledTask("- a") == nil, "check list line is ticked and unticked")

let tasks = "- [ ] a\n- [ ] b\n- [ ] c"
let tick = RichFormat.toggleTaskEdit(text: tasks, boxIndex: 3, moveDone: true)
check(tick.map { (tasks as NSString).replacingCharacters(in: $0.range, with: $0.text) } == "- [ ] b\n- [ ] c\n- [x] a", "ticking a box moves the item down")
let tickStay = RichFormat.toggleTaskEdit(text: tasks, boxIndex: 11, moveDone: false)
check(tickStay.map { (tasks as NSString).replacingCharacters(in: $0.range, with: $0.text) } == "- [ ] a\n- [x] b\n- [ ] c", "ticking a box in place")
check(RichFormat.emptyMarks(in: "a **** b").count == 1 && RichFormat.emptyMarks(in: "****").isEmpty && RichFormat.emptyMarks(in: "x <u></u>").count == 1, "empty formatting marks are found")

// Attachments
check(Attachments.parse(line: "![Фото](a.assets/p%201.png)") == .init(kind: .image, title: "Фото", target: "a.assets/p%201.png"), "image line")
check(Attachments.parse(line: "![v](a.assets/v.MOV)")?.kind == .video && Attachments.parse(line: "[doc](a.assets/x.pdf)")?.kind == .pdf && Attachments.parse(line: "[z](a.assets/x.zip)")?.kind == .file, "video, pdf and other files")
check(Attachments.parse(line: "[site](https://example.com)") == nil && Attachments.parse(line: "text [a](b.pdf)") == nil && Attachments.parse(line: "[p](a.png)")?.kind == .file, "web links and inline links are not attachments")
check(Attachments.markdown(title: "My photo", path: "Notes.assets/my photo (1).png", kind: .image) == "![My photo](Notes.assets/my%20photo%20%281%29.png)", "path is percent-encoded")
check(Attachments.decode("Notes.assets/my%20photo%20%281%29.png") == "Notes.assets/my photo (1).png", "path is decoded")
check(Attachments.resolve(target: "n.assets/a%20b.png", relativeTo: URL(fileURLWithPath: "/tmp/docs/n.md"))?.path == "/tmp/docs/n.assets/a b.png", "relative target is resolved next to the document")
check(Attachments.assetsFolderName(for: URL(fileURLWithPath: "/x/Notes.md")) == "Notes.assets", "assets folder name")
check(Attachments.webLink(title: "", address: "example.com/page") == "[example.com](https://example.com/page)" && Attachments.webLink(title: "Site", address: "ftp://x.y") == nil && Attachments.webLink(title: "x", address: "not a url") == nil, "web link")
let linkEdit = RichFormat.linkEdit(("", "https://example.com"), text: "see docs here", selection: NSRange(location: 4, length: 4))
check(linkEdit.map { ("see docs here" as NSString).replacingCharacters(in: $0.range, with: $0.text) } == "see [docs](https://example.com) here", "selected text becomes a link")
check(RichFormat.insertBlock("![a](b.png)", text: "text", selection: NSRange(location: 2, length: 0)).text == "\n\n![a](b.png)\n", "attachment goes after a blank line")

// Binary delta and update patches
var oldBytes = Data((0..<20_000).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ ($0 >> 5)) })
var newBytes = oldBytes
newBytes.replaceSubrange(5_000..<5_040, with: Data(repeating: 7, count: 100))
newBytes.append(Data("tail".utf8))
newBytes.insert(contentsOf: Data("head".utf8), at: 0)
let delta = BinaryDelta.make(old: oldBytes, new: newBytes)
check((try? BinaryDelta.apply(old: oldBytes, delta: delta)) == newBytes && delta.count < newBytes.count / 4, "delta rebuilds the new file and is much smaller")
check((try? BinaryDelta.apply(old: Data(), delta: BinaryDelta.make(old: Data(), new: Data("abc".utf8)))) == Data("abc".utf8), "delta against an empty file")
check((try? BinaryDelta.apply(old: oldBytes, delta: Data(delta.dropLast(3)))) == nil, "a truncated delta is refused")

func makeApp(_ root: URL, version: String, files: [String: String]) throws {
    try FileManager.default.createDirectory(at: root.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
    let plist = ["CFBundleIdentifier": "app.grizzly.Grizzly", "CFBundleShortVersionString": version] as NSDictionary
    plist.write(to: root.appendingPathComponent("Contents/Info.plist"), atomically: true)
    for (path, body) in files {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try body.write(to: url, atomically: true, encoding: .utf8)
    }
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.appendingPathComponent("Contents/MacOS/Grizzly").path)
}
do {
    let big = String(repeating: "grizzly binary content ", count: 3000)
    let oldApp = dir.appendingPathComponent("old/Grizzly.app"), newApp = dir.appendingPathComponent("new/Grizzly.app")
    try makeApp(oldApp, version: "1.0.0", files: ["Contents/MacOS/Grizzly": big, "Contents/Resources/a.txt": "same", "Contents/Resources/gone.txt": "bye"])
    try makeApp(newApp, version: "1.1.0", files: ["Contents/MacOS/Grizzly": big + "new code", "Contents/Resources/a.txt": "same", "Contents/Resources/fresh.txt": "hello"])
    let patch = dir.appendingPathComponent("patch.zip")
    try AppPatch.build(oldApp: oldApp, newApp: newApp, output: patch)
    let work = dir.appendingPathComponent("work")
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    let staged = try AppPatch.apply(patch: patch, to: oldApp, from: "1.0.0", to: "1.1.0", bundleID: "app.grizzly.Grizzly", work: work)
    let a = try AppPatch.listFiles(in: staged), b = try AppPatch.listFiles(in: newApp)
    check(a == b, "patched app has exactly the files of the new version")
    check(try a.allSatisfy { try Data(contentsOf: staged.appendingPathComponent($0)) == Data(contentsOf: newApp.appendingPathComponent($0)) }, "patched files are identical to the new build")
    check((try FileManager.default.attributesOfItem(atPath: staged.appendingPathComponent("Contents/MacOS/Grizzly").path))[.posixPermissions] as? Int == 0o755, "executable bit survives the patch")
    check((try? Data(contentsOf: patch).count) ?? Int.max < big.utf8.count / 3, "the patch is much smaller than the app")
    let other = dir.appendingPathComponent("other/Grizzly.app")
    try makeApp(other, version: "1.0.0", files: ["Contents/MacOS/Grizzly": big + "tampered", "Contents/Resources/a.txt": "same"])
    check((try? AppPatch.apply(patch: patch, to: other, from: "1.0.0", to: "1.1.0", bundleID: "app.grizzly.Grizzly", work: dir.appendingPathComponent("work2"))) == nil, "a patch does not apply to a changed installation")
    check((try? AppPatch.apply(patch: patch, to: oldApp, from: "0.9.0", to: "1.1.0", bundleID: "app.grizzly.Grizzly", work: dir.appendingPathComponent("work3"))) == nil, "a patch for another version is refused")
    check(!AppPatch.isSafe("../x") && !AppPatch.isSafe("/etc/passwd") && AppPatch.isSafe("Contents/Info.plist"), "patch paths must stay inside the app")
} catch {
    check(false, "patch round trip: \(error)")
}
let withPatch = "{\"tag_name\":\"v1.3.0\",\"body\":\"\(String(repeating: "c", count: 64)) Grizzly-patch-1.2.2-to-1.3.0-arm64.zip\\n\(String(repeating: "d", count: 64)) Grizzly-1.3.0-arm64.dmg\",\"assets\":[{\"name\":\"Grizzly-patch-1.2.2-to-1.3.0-arm64.zip\",\"browser_download_url\":\"https://github.com/Slipcast-dev/Grizzly/releases/download/v1.3.0/Grizzly-patch-1.2.2-to-1.3.0-arm64.zip\"},{\"name\":\"Grizzly-1.3.0-arm64.dmg\",\"browser_download_url\":\"https://github.com/Slipcast-dev/Grizzly/releases/download/v1.3.0/Grizzly-1.3.0-arm64.dmg\"}]}"
let withPatchInfo = try UpdateCheck.parse(Data(withPatch.utf8), assetSuffix: "-arm64.dmg", patchFrom: ("1.2.2", "arm64"))
check(withPatchInfo?.patch?.name == "Grizzly-patch-1.2.2-to-1.3.0-arm64.zip" && withPatchInfo?.patch?.sha256 == String(repeating: "c", count: 64), "the release patch for the installed version is found")
check(try UpdateCheck.parse(Data(withPatch.utf8), assetSuffix: "-arm64.dmg", patchFrom: ("1.2.0", "arm64"))?.patch == nil, "no patch for another installed version")

// Big folders: one import step, counts and tags stay right
let bigLib = LibraryStore(storeURL: dir.appendingPathComponent("big.json"))
let bigRoot = dir.appendingPathComponent("big")
var bigFiles: [URL] = []
for d in 0..<30 { for f in 0..<100 { bigFiles.append(bigRoot.appendingPathComponent("d\(d)/sub/f\(f).md")) } }
let started = Date()
let imported = bigLib.importTree(root: bigRoot, files: bigFiles)
check(imported.added == 3000 && bigLib.fileCount(in: imported.folderID) == 3000, "3000 files are imported in one step")
check(bigLib.folders(in: imported.folderID).count == 30 && bigLib.files(in: imported.folderID).isEmpty, "the directory tree becomes folders inside folders")
check(bigLib.importTree(root: bigRoot, files: bigFiles).added == 0, "importing the same folder again adds nothing")
check(bigLib.folder(bigLib.folders(in: imported.folderID)[0].id)?.isExpanded == false && bigLib.folder(imported.folderID)?.isExpanded == true, "only the top folder starts open")
check(Date().timeIntervalSince(started) < 3, "importing and counting 3000 files is quick")
check(LibraryStore.extractTags(from: "#14b1f2 #a1b #123 #idea") == ["123", "idea"], "color codes are not tags")

// Nested folders
let nestLib = LibraryStore(storeURL: dir.appendingPathComponent("nest.json"))
let top = nestLib.createFolder("Work")
let child = nestLib.createFolder("2026", parent: top.id)
let grand = nestLib.createFolder("Reports", parent: child.id)
check(nestLib.folders(in: nil).map(\.id) == [top.id] && nestLib.folders(in: top.id).map(\.id) == [child.id], "folders nest")
check(nestLib.folderPath(grand.id) == "Work / 2026 / Reports", "folder path")
let nestedFile = nestLib.add(url: dir.appendingPathComponent("n.md"))
nestLib.move(nestedFile.id, to: grand.id)
check(nestLib.fileCount(in: top.id) == 1 && nestLib.fileCount(in: child.id) == 1, "files are counted through subfolders")
check(!nestLib.moveFolder(top.id, to: grand.id) && !nestLib.moveFolder(child.id, to: child.id), "a folder cannot go into itself or its own subfolder")
check(nestLib.moveFolder(grand.id, to: nil) && nestLib.folders(in: nil).count == 2, "a folder can move to the top level")
nestLib.move(nestedFile.id, to: nil)
let removed = nestLib.deleteFolder(child.id)
check(nestLib.folders(in: top.id).isEmpty && nestLib.folder(child.id) == nil && nestLib.folder(grand.id) != nil && removed.isEmpty, "deleting a folder leaves folders that live elsewhere alone")
let top2 = nestLib.createFolder("Inbox")
let sub2 = nestLib.createFolder("Old", parent: top2.id)
let doomedFile = nestLib.add(url: dir.appendingPathComponent("doomed.md"))
nestLib.move(doomedFile.id, to: sub2.id)
check(nestLib.deleteFolder(top2.id) == [doomedFile.id] && nestLib.file(doomedFile.id) == nil && nestLib.folder(sub2.id) == nil, "deleting a folder removes the files inside it from the library")
nestLib.flush()
check(LibraryStore(storeURL: dir.appendingPathComponent("nest.json")).folders(in: nil).count == 2, "nesting is saved to disk")

// Smart folders collect files by tag and type
let smartLib = LibraryStore(storeURL: dir.appendingPathComponent("smart.json"))
let sNote = smartLib.add(url: dir.appendingPathComponent("note.md"))
let sPlain = smartLib.add(url: dir.appendingPathComponent("plain.txt"))
let sCode = smartLib.add(url: dir.appendingPathComponent("tool.py"))
let sHome = smartLib.createFolder("Home")
smartLib.move(sNote.id, to: sHome.id)
smartLib.setInlineTags([(sNote.id, ["проект"]), (sPlain.id, ["Проект", "идея"])])
let byTag = smartLib.createSmartFolder("Проекты", rule: SmartRule(tags: ["ПРОЕКТ"]))
check(smartLib.files(in: byTag.id).map(\.id).sorted { $0.uuidString < $1.uuidString } == [sNote.id, sPlain.id].sorted { $0.uuidString < $1.uuidString },
      "a smart folder collects the files that carry its tag, whatever their case and folder")
check(smartLib.fileCount(in: byTag.id) == 2 && smartLib.files(in: sHome.id).map(\.id) == [sNote.id], "files stay in their own folders")
smartLib.setInlineTags(sCode.id, ["проект"])
check(smartLib.files(in: byTag.id).count == 3, "a tag that appears in a text brings the file into the folder")
smartLib.setInlineTags(sCode.id, [])
check(smartLib.files(in: byTag.id).count == 2, "and takes it out again when the tag is gone")
let both = smartLib.createSmartFolder("Обе", rule: SmartRule(tags: ["проект", "идея"], matchAllTags: true))
let either = smartLib.createSmartFolder("Любая", rule: SmartRule(tags: ["идея", "нет такого"], matchAllTags: false))
check(smartLib.files(in: both.id).map(\.id) == [sPlain.id] && smartLib.files(in: either.id).map(\.id) == [sPlain.id], "match all / match any tags")
let byType = smartLib.createSmartFolder("Заметки", rule: SmartRule(types: ["markdown"]))
check(smartLib.files(in: byType.id).map(\.id) == [sNote.id], "a smart folder with no tag collects files of the chosen type")
let typeAndTag = smartLib.createSmartFolder("Текст с тегом", rule: SmartRule(tags: ["идея"], types: ["text", "markdown"]))
check(smartLib.files(in: typeAndTag.id).map(\.id) == [sPlain.id], "tag and type conditions are combined")
let anyType = smartLib.createSmartFolder("Всё", rule: SmartRule())
check(smartLib.files(in: anyType.id).isEmpty, "a rule with no condition collects nothing")
let sortedByType = smartLib.createSmartFolder("По типу", rule: SmartRule(types: ["python", "markdown", "text"], sort: .type))
check(smartLib.files(in: sortedByType.id).map(\.id) == [sNote.id, sCode.id, sPlain.id], "sorting by file type")
smartLib.move(sPlain.id, to: byTag.id)
check(smartLib.file(sPlain.id)?.folderID == nil, "files cannot be moved into a smart folder")
check(!smartLib.moveFolder(sHome.id, to: byTag.id) && !smartLib.folderChoices.contains { $0.folder.isSmart }, "folders cannot go into a smart folder and it is not a move target")
smartLib.renameTag("проект", to: "work")
check(smartLib.folder(byTag.id)?.smart?.tags == ["work"] && smartLib.files(in: byTag.id).count == 2, "renaming a tag updates smart folders")
smartLib.deleteTag("идея")
check(smartLib.folder(both.id)?.smart?.tags == ["work"], "deleting a tag removes it from smart folders")
smartLib.updateSmartFolder(byTag.id, name: "Work", rule: SmartRule(types: ["python"]))
check(smartLib.folder(byTag.id)?.name == "Work" && smartLib.files(in: byTag.id).map(\.id) == [sCode.id], "editing a smart folder changes its rule")
check(smartLib.deleteFolder(byTag.id).isEmpty && smartLib.file(sCode.id) != nil, "deleting a smart folder keeps the files")
smartLib.flush()
let reloaded = LibraryStore(storeURL: dir.appendingPathComponent("smart.json"))
check(reloaded.folder(typeAndTag.id)?.smart?.types == ["text", "markdown"] && reloaded.folder(typeAndTag.id)?.isSmart == true, "smart folders are saved to disk")

// Contents of folders, archives and disk images, read without opening them
let peek = dir.appendingPathComponent("peek", isDirectory: true)
try FileManager.default.createDirectory(at: peek.appendingPathComponent("src/deep"), withIntermediateDirectories: true)
try "hello".write(to: peek.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
try String(repeating: "x", count: 2000).write(to: peek.appendingPathComponent("src/deep/Привет мир.md"), atomically: true, encoding: .utf8)
try "hidden".write(to: peek.appendingPathComponent(".secret"), atomically: true, encoding: .utf8)
let folderListing = ContentsLister.listFolder(peek)
check(folderListing.files == 2 && folderListing.folders == 2 && folderListing.size == 2005, "folder listing counts files, folders and bytes (hidden files skipped)")
check(folderListing.entries.first?.name == "src" && folderListing.entries.first?.children?.first?.children?.first?.name == "Привет мир.md", "folders come first and nest")
check(folderListing.entries.first?.size == 2000, "a folder's size is the sum of what is inside")
func shell(_ path: String, _ args: [String], in directory: URL? = nil) -> Bool {
    let p = Process(); p.executableURL = URL(fileURLWithPath: path); p.arguments = args; p.currentDirectoryURL = directory
    p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return false }
    p.waitUntilExit(); return p.terminationStatus == 0
}
let zipURL = dir.appendingPathComponent("sample.zip")
check(shell("/usr/bin/zip", ["-qr", zipURL.path, "a.txt", "src"], in: peek), "test zip is created")
if let listing = try? ContentsLister.list(zipURL) {
    check(listing.files == 2 && listing.folders == 2 && listing.entries.contains { $0.name == "a.txt" && $0.size == 5 }, "zip contents are listed")
    check(listing.entries.first?.children?.first?.children?.first?.name == "Привет мир.md", "non-ASCII names with spaces survive in a zip listing")
} else { check(false, "zip contents are listed") }
let tgzURL = dir.appendingPathComponent("sample.tar.gz")
check(shell("/usr/bin/tar", ["-czf", tgzURL.path, "a.txt", "src"], in: peek), "test tar.gz is created")
check((try? ContentsLister.list(tgzURL))?.files == 2, "tar.gz contents are listed")
let notArchive = dir.appendingPathComponent("broken.zip")
try "not a zip".write(to: notArchive, atomically: true, encoding: .utf8)
check((try? ContentsLister.list(notArchive)) == nil, "a broken archive is an error, not an empty listing")
check(ContentsLister.kind(of: URL(fileURLWithPath: "/a/b.DMG")) == .diskImage && ContentsLister.kind(of: URL(fileURLWithPath: "/a/b.tar.xz")) == .archive
      && ContentsLister.kind(of: URL(fileURLWithPath: "/a/b.md")) == nil, "containers are recognised by name")
let dmgURL = dir.appendingPathComponent("sample.dmg")
if shell("/usr/bin/hdiutil", ["create", "-quiet", "-srcfolder", peek.path, "-format", "UDZO", "-volname", "PeekTest", dmgURL.path]) {
    if let listing = try? ContentsLister.list(dmgURL) {
        check(listing.files == 2 && listing.entries.contains { $0.name == "a.txt" }, "dmg contents are listed")
    } else { check(false, "dmg contents are listed") }
    let info = (try? ContentsLister.run("/usr/bin/hdiutil", ["info"], timeout: 30))?.out ?? Data()
    check(!String(decoding: info, as: UTF8.self).contains("sample.dmg"), "the dmg is detached again")
} else { print("skip: hdiutil cannot create an image here") }

try? FileManager.default.removeItem(at: dir)
exit(failures == 0 ? 0 : 1)
