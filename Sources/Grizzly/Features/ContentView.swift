import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var prefs: Preferences
    @ObservedObject private var updater = UpdateManager.shared

    var body: some View {
        let theme = prefs.theme

        NavigationSplitView {
            SidebarView()
                .background(theme.background.opacity(prefs.sidebarTint))
                .id(prefs.uiFontKey)
                .navigationSplitViewColumnWidth(min: 190, ideal: 230, max: 320)
        } detail: {
            DetailView(fontSize: CGFloat(prefs.fontSize))
                .id(prefs.uiFontKey)
                .background(theme.background.opacity(prefs.surfaceOpacity))
                .background { if prefs.glassEnabled { VisualEffect(material: .underWindowBackground) } }
        }
        .environment(\.font, AppFont.body)
        .background(WindowFrameSaver(name: "GrizzlyMainWindow"))
        .background(GlassWindowConfigurator(enabled: prefs.glassEnabled))
        .navigationTitle(state.current?.name ?? "Grizzly")
        .toolbar {
            // The view mode switch sits in the middle of the title bar; everything else for the current file is on the right.
            ToolbarItem(placement: .principal) {
                Picker("Режим", selection: $state.mode) {
                    Text("Пользователь").tag(ReadMode.user)
                    Text("Разработчик").tag(ReadMode.developer)
                }
                .pickerStyle(.segmented)
                .frame(width: 230)
                .help("Пользователь: текст без кода форматирования. Разработчик: исходный текст с разметкой, подсветкой и номерами строк.")
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button { state.toggleSplit() } label: {
                    Image(systemName: state.isSplit ? "rectangle.split.2x1.fill" : "rectangle.split.2x1")
                }
                .buttonStyle(.hover)
                .help("Два файла рядом (⌘\\)")
                .disabled(state.documents.isEmpty)

                Button { state.showFind() } label: { Image(systemName: "magnifyingglass") }
                    .buttonStyle(.hover)
                    .help("Найти (⌘F)")
                    .disabled(state.documents.isEmpty)

                BookmarksButton()

                Button { prefs.resizeFont(by: -1) } label: { Image(systemName: "textformat.size.smaller") }
                    .buttonStyle(.hover)
                    .help("Уменьшить текст")
                Button { prefs.resizeFont(by: 1) } label: { Image(systemName: "textformat.size.larger") }
                    .buttonStyle(.hover)
                    .help("Увеличить текст")
                // Rightmost: the system emoji picker, for the text being edited.
                Button { NSApp.orderFrontCharacterPalette(nil) } label: { Text("😀") }
                    .buttonStyle(.hover)
                    .help("Эмодзи и символы (⌃⌘Пробел)")
                    .disabled(state.documents.isEmpty)
                // Rightmost of all: the Settings window.
                Button { SettingsOpener.show() } label: { Image(systemName: "gearshape") }
                    .buttonStyle(.hover)
                    .help("Настройки (⌘,)")
            }
        }
        .environment(\.theme, theme)
        .environment(\.surfaceOpacity, prefs.surfaceOpacity)
        .environment(\.tabsOpacity, prefs.tabsOpacity)
        .preferredColorScheme(theme.isDark ? .dark : .light)
        .onChange(of: state.mode) { _ in
            state.recomputeMatches(reset: false)
        }
        .onChange(of: state.current?.id) { _ in
            state.recomputeMatches(reset: true)
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            for provider in providers {
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    guard let data = item as? Data,
                          let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                    DispatchQueue.main.async { state.open(urls: [url]) }
                }
            }
            return true
        }
        .overlay(alignment: .bottom) {
            if let toast = state.toast {
                ToastView(toast: toast)
                    .padding(.bottom, 46)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .allowsHitTesting(false)
            }
        }
        .animation(.easeOut(duration: 0.2), value: state.toast?.id)
        .sheet(isPresented: $updater.sheetVisible) { UpdateSheet(updater: updater) }
        .sheet(item: $state.contentsPreview) { ContentsPreviewView(model: $0) }
        .alert("Ошибка", isPresented: Binding(
            get: { state.errorMessage != nil },
            set: { if !$0 { state.errorMessage = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(state.errorMessage ?? "")
        }
    }
}

/// Opens the Settings window (the same as ⌘,).
enum SettingsOpener {
    static func show() {
        NSApp.activate(ignoringOtherApps: true)
        // The system menu item does the same as ⌘,; looking it up works on every macOS version (sending the action
        // to nobody finds no target when no window of the Settings scene exists yet).
        if let appMenu = NSApp.mainMenu?.items.first?.submenu,
           let index = appMenu.items.firstIndex(where: { $0.keyEquivalent == "," && $0.isEnabled }) {
            appMenu.performActionForItem(at: index)
        } else if !NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) {
            NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
        }
    }
}

struct DetailView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.theme) private var theme
    let fontSize: CGFloat
    /// Share of the width that the left pane takes in split view; the divider changes it and it is remembered.
    @AppStorage("splitFraction") private var splitFraction = 0.5

    var body: some View {
        if state.documents.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.system(size: 44, weight: .light))
                    .foregroundColor(theme.secondary)
                Text("Откройте файл")
                    .font(AppFont.title3)
                Text("Перетащите Markdown или текстовый файл в окно\nили нажмите ⌘O.")
                    .multilineTextAlignment(.center)
                    .foregroundColor(theme.secondary)
                Button("Открыть…") { state.presentOpenPanel() }
                    .padding(.top, 4)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 0) {
                TabBar()
                if state.isFindVisible { FindBar() }
                GeometryReader { geo in
                    HStack(spacing: 0) {
                        PaneView(pane: .left, fontSize: fontSize)
                            .frame(width: state.isSplit ? max(240, min(geo.size.width - 240, geo.size.width * splitFraction)) : geo.size.width)
                        if state.isSplit {
                            SplitHandle(fraction: $splitFraction, total: geo.size.width)
                            PaneView(pane: .right, fontSize: fontSize)
                        }
                    }
                }
            }
        }
    }
}

/// The divider between the two panes: drag it to change their widths, double-click to make them equal.
struct SplitHandle: View {
    @Binding var fraction: Double
    let total: CGFloat
    @State private var startFraction: Double?
    @State private var hovering = false
    @Environment(\.theme) private var theme

    var body: some View {
        Rectangle()
            .fill(hovering ? theme.accent.opacity(0.6) : theme.rule.opacity(0.6))
            .frame(width: hovering ? 3 : 1)
            .frame(width: 9)
            .contentShape(Rectangle())
            .onHover { inside in
                hovering = inside
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .onDisappear { if hovering { NSCursor.pop() } }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { drag in
                        let start = startFraction ?? fraction
                        startFraction = start
                        guard total > 0 else { return }
                        fraction = min(max(start + Double(drag.translation.width / total), 240 / Double(total)), 1 - 240 / Double(total))
                    }
                    .onEnded { _ in startFraction = nil })
            .onTapGesture(count: 2) { fraction = 0.5 }
    }
}

/// Remembers the window's size and position between launches (AppKit stores it under `name`).
struct WindowFrameSaver: NSViewRepresentable {
    let name: String

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { view.window?.setFrameAutosaveName(name) }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {}
}

/// A small rounded notification near the bottom of the window.
struct ToastView: View {
    let toast: Toast
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: toast.symbol).foregroundColor(theme.accent)
            Text(toast.text).font(AppFont.callout).lineLimit(2)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().stroke(Color.primary.opacity(0.12)))
        .shadow(color: .black.opacity(0.18), radius: 10, y: 3)
        .frame(maxWidth: 520)
    }
}
