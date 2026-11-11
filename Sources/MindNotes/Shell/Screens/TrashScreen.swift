import SwiftUI

/// Корзина: страницы возвращаются вместе с подстраницами.
struct TrashScreen: View {
    @EnvironmentObject private var shell: ShellModel

    private func detail(_ item: TrashItem) -> String {
        let f = DateFormatter()
        f.locale = Locale.current
        f.setLocalizedDateFormatFromTemplate("dMMMM")
        let date = f.string(from: Date(timeIntervalSince1970: Double(item.page.deletedAt ?? 0) / 1000))
        let base = String(format: L("Удалено %@"), date)
        return item.descendants > 0 ? "\(base) · \(String(format: L("Подстраниц: %d"), item.descendants))" : base
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Eyebrow(text: L("Пространство"))
                ScreenTitle(text: L("Корзина")).padding(.top, 8).padding(.bottom, 9)
                Text("Страницы можно вернуть вместе с подстраницами.")
                    .font(.system(size: 14))
                    .foregroundColor(Tokens.muted)
                    .padding(.bottom, 24)
                VStack(spacing: 0) {
                    if shell.trashItems.isEmpty {
                        Text("Корзина пуста.")
                            .foregroundColor(Tokens.muted)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 45)
                    }
                    ForEach(shell.trashItems) { item in
                        HStack(spacing: 10) {
                            Image(systemName: "doc.text")
                                .font(.system(size: 11))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .background(RoundedRectangle(cornerRadius: 6).fill(Tokens.soft))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.page.title.isEmpty ? L("Без названия") : item.page.title)
                                    .font(.system(size: 14, weight: .semibold))
                                    .lineLimit(1)
                                Text(detail(item)).font(.system(size: 12)).foregroundColor(Tokens.muted)
                            }
                            Spacer()
                            Button("Восстановить") { shell.restoreFromTrash(item) }.buttonStyle(NotesButtonStyle())
                            Button { shell.purgeFromTrash(item) } label: { Text("Удалить…").foregroundColor(Tokens.danger) }
                                .buttonStyle(NotesButtonStyle())
                        }
                        .padding(.vertical, 11)
                    }
                }
                .padding(.horizontal, 18)
                .background(RoundedRectangle(cornerRadius: 12).fill(Tokens.card))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Tokens.line))
            }
            .padding(.horizontal, Tokens.contentPadding)
            .padding(.top, 32)
            .padding(.bottom, 42)
        }
    }
}
