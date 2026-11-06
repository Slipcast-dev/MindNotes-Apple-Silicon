import SwiftUI

struct HomeScreen: View {
    @EnvironmentObject private var shell: ShellModel

    private var dateLine: String {
        let f = DateFormatter()
        f.locale = Locale.current
        f.setLocalizedDateFormatFromTemplate("EEEEdMMMM")
        return f.string(from: Date())
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                CoverArt().padding(.bottom, 26)
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
                            QuickCard(page: page, kids: shell.children(of: page.id).count) { shell.openPage(page.id) }
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
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 5) {
                Image(systemName: "doc.text")
                    .font(.system(size: 11))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Tokens.soft))
                    .padding(.bottom, 2)
                Text(page.title.isEmpty ? L("Без названия") : page.title)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                Text(kids == 0 ? L("Страница") : String(format: L("Подстраниц: %d"), kids))
                    .font(.system(size: 12))
                    .foregroundColor(Tokens.muted)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(hover ? Tokens.soft : Tokens.card))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Tokens.line))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
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
