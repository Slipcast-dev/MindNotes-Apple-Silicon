import SwiftUI

struct HomeScreen: View {
    @EnvironmentObject private var shell: ShellModel
    @State private var coverHover = false

    private var dateLine: String {
        let f = DateFormatter()
        f.locale = Locale.current
        f.setLocalizedDateFormatFromTemplate("EEEEdMMMM")
        return f.string(from: Date())
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if shell.look.coverKind != .none {
                    CoverView()
                        .overlay(alignment: .topTrailing) {
                            Button("Настроить") { shell.showsLookSheet = true }
                                .buttonStyle(NotesButtonStyle())
                                .opacity(coverHover ? 1 : 0)
                                .padding(12)
                        }
                        .onHover { coverHover = $0 }
                        .padding(.bottom, 26)
                } else {
                    Button { shell.showsLookSheet = true } label: { Label("Добавить обложку", systemImage: "photo") }
                        .buttonStyle(NotesButtonStyle(kind: .plain))
                        .padding(.bottom, 10)
                }
                Eyebrow(text: dateLine)
                ScreenTitle(text: shell.workspaceName).padding(.top, 8).padding(.bottom, 9)
                Text("Заметки, проекты и задачи — в одном месте.")
                    .font(.system(size: 14))
                    .foregroundColor(Tokens.muted)
                    .padding(.bottom, 24)
                Button { shell.createPage() } label: { Label("Новая страница", systemImage: "plus") }
                    .buttonStyle(NotesButtonStyle(kind: .primary))

                let top = shell.children(of: nil).prefix(3)
                if !top.isEmpty {
                    sectionTitle(L("Быстрый доступ"))
                    HStack(alignment: .top, spacing: 13) {
                        ForEach(Array(top)) { page in
                            QuickCard(page: page, kids: shell.children(of: page.id).count, cover: shell.image(for: page.coverAssetID)) { shell.openPage(page.id) }
                                .onAppear { if let asset = page.coverAssetID { shell.loadImage(asset: asset) } }
                        }
                        ForEach(0..<(3 - top.count), id: \.self) { _ in Color.clear.frame(maxWidth: .infinity, maxHeight: 1) }
                    }
                }
                if !shell.recent.isEmpty {
                    sectionTitle(L("Недавние"))
                    VStack(spacing: 0) {
                        ForEach(shell.recent) { page in
                            RecentRow(page: page, parents: shell.path(of: page.id).map(\.title)) { shell.openPage(page.id) }
                        }
                    }
                }
            }
            .padding(.horizontal, Tokens.contentPadding)
            .padding(.top, 32)
            .padding(.bottom, 42)
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text).font(.system(size: 17, weight: .semibold)).padding(.top, 24).padding(.bottom, 10)
    }
}

struct QuickCard: View {
    let page: Page
    let kids: Int
    /// Обложка страницы сверху карточки; без обложки — мягкий фон темы той же высоты, чтобы карточки стояли ровно.
    var cover: NSImage? = nil
    let action: () -> Void
    @State private var hover = false

    private static let coverHeight: CGFloat = 96
    private static let iconSize: CGFloat = 40

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                header
                VStack(alignment: .leading, spacing: 4) {
                    Text(page.title.isEmpty ? L("Без названия") : page.title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(Tokens.ink)
                        .lineLimit(1)
                    Text(kids == 0 ? L("Страница") : String(format: L("Подстраниц: %d"), kids))
                        .font(.system(size: 12))
                        .foregroundColor(Tokens.muted)
                }
                .padding(.horizontal, 16)
                .padding(.top, Self.iconSize / 2 + 10) // Место под значок, наполовину заходящий на обложку.
                .padding(.bottom, 16)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .topLeading) { icon.padding(.leading, 16).padding(.top, Self.coverHeight - Self.iconSize / 2) }
            .background(Tokens.card)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Tokens.line.opacity(hover ? 0.4 : 1)))
            .shadow(color: .black.opacity(hover ? 0.12 : 0.04), radius: hover ? 14 : 4, y: hover ? 6 : 1)
            .scaleEffect(hover ? 1.012 : 1)
            .animation(.easeOut(duration: 0.18), value: hover)
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .accessibilityLabel(Text(page.title.isEmpty ? L("Без названия") : page.title))
    }

    @ViewBuilder private var header: some View {
        ZStack {
            if let cover {
                Image(nsImage: cover)
                    .resizable()
                    .scaledToFill()
                    .scaleEffect(hover ? 1.04 : 1)
                    .animation(.easeOut(duration: 0.3), value: hover)
            } else {
                LinearGradient(colors: [Tokens.soft, Tokens.soft.opacity(0.45)], startPoint: .topLeading, endPoint: .bottomTrailing)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: Self.coverHeight)
        .clipped()
    }

    /// Значок страницы на границе обложки: emoji страницы или символ документа.
    private var icon: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Tokens.card)
                .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
            if let emoji = page.emoji {
                Text(emoji).font(.system(size: 20))
            } else {
                Image(systemName: page.isFolder ? "folder" : "doc.text")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(Tokens.muted)
            }
        }
        .frame(width: Self.iconSize, height: Self.iconSize)
    }
}

struct RecentRow: View {
    let page: Page
    let parents: [String]
    let action: () -> Void

    private var subtitle: String {
        let when = page.lastOpenedAt.map { Date(timeIntervalSince1970: Double($0) / 1000) } ?? Date()
        let f = RelativeDateTimeFormatter()
        f.dateTimeStyle = .named
        let relative = f.localizedString(for: when, relativeTo: Date())
        return (parents + [relative]).joined(separator: parents.isEmpty ? "" : " · ")
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "doc.text")
                .font(.system(size: 11))
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 6).fill(Tokens.soft))
            VStack(alignment: .leading, spacing: 2) {
                Text(page.title.isEmpty ? L("Без названия") : page.title).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                Text(subtitle).font(.system(size: 12)).foregroundColor(Tokens.muted).lineLimit(1)
            }
            Spacer()
            Button("Открыть", action: action).buttonStyle(NotesButtonStyle(kind: .plain))
        }
        .padding(.vertical, 11)
    }
}
