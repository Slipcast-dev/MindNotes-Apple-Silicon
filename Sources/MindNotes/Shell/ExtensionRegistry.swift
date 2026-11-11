import AppKit
import SwiftUI

/// Установленные расширения (ADR-0015): папка `Extensions` в каталоге данных приложения.
/// Только описания и картинки; испорченное расширение помечается и не мешает запуску.
@MainActor
final class ExtensionRegistry: ObservableObject {
    static let shared = ExtensionRegistry()

    struct Item: Identifiable {
        let manifest: ExtensionManifest
        let folder: URL
        var problem: String?
        var theme: ThemeColors?
        var icon: NSImage?
        var id: String { manifest.id }
    }

    @Published private(set) var items: [Item] = []
    /// Папки, которые не удалось прочитать как расширение: имя и причина.
    @Published private(set) var broken: [(name: String, reason: String)] = []

    var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(AppEdition.supportDirectoryName, isDirectory: true)
            .appendingPathComponent("Extensions", isDirectory: true)
    }

    var themes: [Item] { items.filter { $0.theme != nil && $0.problem == nil } }
    var icons: [Item] { items.filter { $0.icon != nil && $0.problem == nil } }

    func theme(_ id: String?) -> ThemeColors? { themes.first { $0.id == id }?.theme }
    func icon(_ id: String?) -> NSImage? { icons.first { $0.id == id }?.icon }

    func reload() {
        let fm = FileManager.default
        let app = AppVersion((Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "")
        var found: [Item] = [], bad: [(String, String)] = []
        let dirs = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        for dir in dirs.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard (try? dir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            guard let data = try? Data(contentsOf: dir.appendingPathComponent("manifest.json")), let manifest = ExtensionManifest.parse(data) else {
                bad.append((dir.lastPathComponent, L("нет manifest.json или он испорчен")))
                continue
            }
            guard !found.contains(where: { $0.id == manifest.id }) else {
                bad.append((dir.lastPathComponent, L("такой id уже установлен")))
                continue
            }
            var item = Item(manifest: manifest, folder: dir)
            if !manifest.supported(by: app) {
                item.problem = L("не поддерживается этой версией приложения")
            } else if manifest.kind == .theme {
                let parsed = (try? Data(contentsOf: dir.appendingPathComponent("theme.json"))).map(ThemeColors.parse) ?? (nil, L("нет theme.json"))
                item.theme = parsed.colors
                item.problem = parsed.error
            } else if manifest.kind == .appIcon {
                let file = dir.appendingPathComponent("icon.png")
                let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                if size > 0, size <= 5 << 20, let image = NSImage(contentsOf: file) { item.icon = image } else { item.problem = L("нет icon.png или он больше 5 МБ") }
            }
            found.append(item)
        }
        items = found
        broken = bad
    }

    /// Папка создаётся при первом открытии; в ней лежит пример описания.
    func openFolder() {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([folder])
    }
}

/// Раздел «Расширения» в настройках: список, причины ошибок, папка.
struct ExtensionsSettings: View {
    @ObservedObject var registry = ExtensionRegistry.shared

    private func kindTitle(_ kind: ExtensionManifest.Kind) -> String {
        switch kind {
        case .theme: return L("Тема")
        case .appIcon: return L("Иконка приложения")
        case .unsupported(let k): return k
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Расширения").font(.system(size: 17, weight: .semibold)).padding(.top, 24).padding(.bottom, 10)
            VStack(alignment: .leading, spacing: 10) {
                Text("Свои темы и иконки приложения: папка с manifest.json в папке расширений. Код из расширений не исполняется.")
                    .font(.system(size: 12)).foregroundColor(Tokens.muted)
                if registry.items.isEmpty && registry.broken.isEmpty {
                    Text("Расширений нет.").font(.system(size: 13)).foregroundColor(Tokens.muted)
                }
                ForEach(registry.items) { item in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.manifest.name).font(.system(size: 13, weight: .semibold))
                            Text("\(kindTitle(item.manifest.kind)) · \(item.manifest.version)").font(.system(size: 11)).foregroundColor(Tokens.muted)
                        }
                        Spacer()
                        if let problem = item.problem { Text(problem).font(.system(size: 11)).foregroundColor(Tokens.danger) }
                        else { Chip(text: L("Работает")) }
                    }
                }
                ForEach(Array(registry.broken.enumerated()), id: \.offset) { _, b in
                    HStack {
                        Text(b.name).font(.system(size: 13))
                        Spacer()
                        Text(b.reason).font(.system(size: 11)).foregroundColor(Tokens.danger)
                    }
                }
                HStack {
                    Button("Открыть папку расширений") { registry.openFolder() }.buttonStyle(NotesButtonStyle())
                    Button("Обновить список") { registry.reload() }.buttonStyle(NotesButtonStyle(kind: .plain))
                }
            }
            .padding(18)
            .background(RoundedRectangle(cornerRadius: 12).fill(Tokens.card))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Tokens.line))
        }
    }
}
