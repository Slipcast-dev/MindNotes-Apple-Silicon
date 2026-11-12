import AppKit
import SwiftUI

@main
struct WebClipperInstallerApp: App {
    @NSApplicationDelegateAdaptor(InstallerDelegate.self) private var delegate

    var body: some Scene {
        Window("MindNotes Web Clipper", id: "main") {
            InstallerView().environmentObject(delegate.model)
        }
        .windowResizability(.contentSize)
    }
}

@MainActor
final class InstallerDelegate: NSObject, NSApplicationDelegate {
    let model = InstallerModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // --check: только показать, что найдено на этом Mac, ничего не меняя (для диагностики).
        if CommandLine.arguments.contains("--check") {
            Task { @MainActor in
                print(await InstallerModel.report())
                exit(0)
            }
            return
        }
        // --no-auto: только окно и состояние, без переноса в «Программы» и без установки (для проверки вида).
        let auto = !CommandLine.arguments.contains("--no-auto")
        if auto, Relocation.moveToApplicationsIfNeeded() { return }
        LSRegisterURL(Bundle.main.bundleURL as CFURL, true) // Safari находит расширение через регистрацию программы.
        NSApp.activate(ignoringOtherApps: true)
        model.start(auto: auto)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

struct InstallerView: View {
    @EnvironmentObject var model: InstallerModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 48, height: 48)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Web Clipper").font(.system(size: 20, weight: .semibold))
                    Text(tr("Сохраняйте статьи, выделенное, закладки и скриншоты из браузера в MindNotes.",
                            "Save articles, selections, bookmarks and screenshots from your browser to MindNotes."))
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }

            VStack(spacing: 0) {
                mindNotesRow
                ForEach(model.browsers) { browser in
                    Divider()
                    browserRow(browser)
                }
            }
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(nsColor: .separatorColor)))

            if let browser = model.guiding { ChromeGuide(browser: browser) }

            if let message = model.message {
                Text(message).font(.system(size: 12)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Text(tr("Подключение к MindNotes настраивается само.", "The connection to MindNotes sets itself up."))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                if model.allDone {
                    Label(tr("Всё готово", "All set"), systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    Button(tr("Закрыть", "Close")) { NSApp.terminate(nil) }.keyboardShortcut(.defaultAction)
                } else {
                    Button(model.running ? tr("Устанавливаю…", "Installing…") : tr("Установить всё", "Install Everything")) {
                        Task { await model.installAll() }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.running || !model.canInstall)
                }
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    private var mindNotesRow: some View {
        row(icon: model.mindNotesURL.map { NSWorkspace.shared.icon(forFile: $0.path) }, name: "MindNotes",
            done: model.pluginReady,
            status: model.mindNotesURL == nil ? tr("MindNotes не найден — сначала установите приложение", "MindNotes not found — install the app first")
                : model.mindNotesOutdated ? tr("Эта версия MindNotes не поддерживает плагины — обновите приложение", "This MindNotes version does not support plugins — update the app")
                : model.pluginReady ? tr("Плагин установлен", "Plugin installed") : tr("Плагин ещё не добавлен", "Plugin not added yet")) {
            if model.canInstall, !model.pluginReady {
                Button(tr("Добавить", "Add")) { model.addToMindNotes() }
            }
        }
    }

    private func browserRow(_ browser: Browser) -> some View {
        let done = browser.isSafari ? model.safariEnabled : model.chromeInstalled.contains(browser.id)
        let status = browser.isSafari
            ? (done ? tr("Расширение включено", "Extension enabled") : tr("Нужно включить в настройках Safari", "Turn it on in Safari Settings"))
            : (done ? tr("Расширение установлено", "Extension installed") : tr("Не установлено", "Not installed"))
        return row(icon: NSWorkspace.shared.icon(forFile: browser.appURL.path), name: browser.name, done: done, status: status) {
            if !done {
                Button(tr("Установить", "Install")) {
                    if browser.isSafari { Task { await model.installSafari() } } else { model.installChromium(browser) }
                }
                .disabled(!model.pluginReady)
            }
        }
    }

    private func row<Action: View>(icon: NSImage?, name: String, done: Bool, status: String, @ViewBuilder action: () -> Action) -> some View {
        HStack(spacing: 10) {
            if let icon { Image(nsImage: icon).resizable().frame(width: 28, height: 28) } else { Image(systemName: "app.dashed").frame(width: 28, height: 28) }
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(.system(size: 13, weight: .medium))
                Text(status).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if done { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) } else { action() }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
    }
}

/// Chrome и браузеры на его основе не дают программам ставить расширения сами (кроме магазина Chrome):
/// остаётся одно движение — перетащить папку на страницу расширений.
struct ChromeGuide: View {
    @EnvironmentObject var model: InstallerModel
    let browser: Browser

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(spacing: 4) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: Paths.chromeExtension.path)).resizable().frame(width: 56, height: 56)
                Text("Web Clipper").font(.system(size: 11, weight: .medium))
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.12)))
            .onDrag { NSItemProvider(object: Paths.chromeExtension as NSURL) }
            .help(tr("Перетащите на страницу расширений", "Drag onto the extensions page"))

            VStack(alignment: .leading, spacing: 6) {
                Text(String(format: tr("Последний шаг в %@", "Last step in %@"), browser.name)).font(.system(size: 13, weight: .semibold))
                Text(tr("1. На открывшейся странице расширений включите «Режим разработчика» (справа вверху).",
                        "1. On the extensions page that opened, turn on Developer mode (top right)."))
                Text(tr("2. Перетащите значок Web Clipper слева в окно браузера.", "2. Drag the Web Clipper icon on the left into the browser window."))
                Text(tr("Или нажмите «Загрузить распакованное», затем ⌘⇧G и вставьте путь.", "Or click Load unpacked, press ⌘⇧G and paste the path."))
                    .foregroundStyle(.secondary)
                HStack {
                    Button(tr("Скопировать путь", "Copy Path")) { model.copyChromePath() }
                    Button(tr("Открыть страницу ещё раз", "Open the Page Again")) { browser.openExtensionsPage() }
                    Button(tr("Пропустить", "Skip")) { model.guiding = nil }
                }
                .controlSize(.small)
            }
            .font(.system(size: 12))
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).stroke(Color.accentColor.opacity(0.5)))
    }
}
