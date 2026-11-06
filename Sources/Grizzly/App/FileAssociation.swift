import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Lets the user choose Grizzly as the system's default app for file extensions (what Finder's
/// "Open with → Change All…" does), from Settings.
final class FileAssociations: ObservableObject {
    static let shared = FileAssociations()

    @Published private(set) var handlers: [String: String] = [:]
    @Published var customExtensions: [String] {
        didSet { UserDefaults.standard.set(customExtensions, forKey: "customExtensions") }
    }
    @Published var message: String?

    private init() {
        customExtensions = UserDefaults.standard.stringArray(forKey: "customExtensions") ?? []
        refresh()
    }

    var extensions: [String] { Array(Set(FileType.allExtensions + customExtensions)).sorted() }

    func isDefault(_ ext: String) -> Bool { handlers[ext] == Bundle.main.bundleIdentifier }

    func handlerName(_ ext: String) -> String {
        guard let id = handlers[ext], let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else {
            return L("не выбрано")
        }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    func refresh() {
        var result: [String: String] = [:]
        for ext in extensions {
            guard let type = UTType(filenameExtension: ext),
                  let app = NSWorkspace.shared.urlForApplication(toOpen: type),
                  let id = Bundle(url: app)?.bundleIdentifier else { continue }
            result[ext] = id
        }
        handlers = result
    }

    func addCustom(_ raw: String) {
        let ext = raw.trimmingCharacters(in: CharacterSet(charactersIn: ". ").union(.whitespacesAndNewlines)).lowercased()
        guard !ext.isEmpty, !extensions.contains(ext) else { return }
        customExtensions.append(ext)
        makeDefault([ext])
    }

    func removeCustom(_ ext: String) { customExtensions.removeAll { $0 == ext } }

    func makeDefault(_ exts: [String]) {
        message = nil
        let app = Bundle.main.bundleURL
        let group = DispatchGroup()
        var failed: [String] = []
        for ext in exts {
            guard let type = UTType(filenameExtension: ext) else { failed.append(ext); continue }
            group.enter()
            NSWorkspace.shared.setDefaultApplication(at: app, toOpen: type) { error in
                if error != nil { failed.append(ext) }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            self.refresh()
            if !failed.isEmpty { self.message = L("Не удалось назначить: %@", failed.joined(separator: ", ")) }
        }
    }
}

/// The "File types" block of the Settings window.
struct FileAssociationsView: View {
    @ObservedObject private var assoc = FileAssociations.shared
    @State private var newExtension = ""

    private let columns = [GridItem(.adaptive(minimum: 120), spacing: 8)]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button("Сделать Grizzly приложением по умолчанию для всех") { assoc.makeDefault(assoc.extensions) }
                    .buttonStyle(.hoverFilled)
                Spacer()
            }
            Text("Нажмите на расширение, чтобы открывать такие файлы в Grizzly. macOS может запросить подтверждение.")
                .font(AppFont.caption).foregroundColor(.secondary)

            LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                ForEach(assoc.extensions, id: \.self) { ext in chip(ext) }
            }

            HStack {
                TextField("Другое расширение, например py", text: $newExtension, onCommit: add)
                    .textFieldStyle(.roundedBorder).frame(width: 240)
                Button("Добавить", action: add)
                    .buttonStyle(.hoverFilled)
                    .disabled(newExtension.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            if let message = assoc.message {
                Text(message).font(AppFont.caption).foregroundColor(.red)
            }
        }
        .onAppear { assoc.refresh() }
    }

    private func add() {
        assoc.addCustom(newExtension)
        newExtension = ""
    }

    private func chip(_ ext: String) -> some View {
        let isDefault = assoc.isDefault(ext)
        return Button { assoc.makeDefault([ext]) } label: {
            HStack(spacing: 5) {
                Image(systemName: isDefault ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(isDefault ? .green : .secondary)
                Text(".\(ext)").font(.system(.callout, design: .monospaced))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
        }
        .buttonStyle(HoverButtonStyle(size: .row, base: 0.08))
        .help(isDefault ? L("Открывается в Grizzly") : L("Сейчас: %@", assoc.handlerName(ext)))
        .contextMenu {
            if assoc.customExtensions.contains(ext) { Button("Убрать из списка") { assoc.removeCustom(ext) } }
        }
    }
}
