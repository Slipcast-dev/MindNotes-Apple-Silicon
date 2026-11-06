import SwiftUI

struct WelcomeScreen: View {
    @EnvironmentObject private var shell: ShellModel

    var body: some View {
        VStack(spacing: 0) {
            Image(systemName: "sparkle")
                .font(.system(size: 19, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 35, height: 35)
                .background(RoundedRectangle(cornerRadius: 11).fill(Tokens.logo))
                .padding(.bottom, 15)
            Eyebrow(text: L("Первый запуск"))
            ScreenTitle(text: L("Добро пожаловать")).padding(.top, 8).padding(.bottom, 9)
            Text("Создайте личное пространство или откройте существующее.")
                .font(.system(size: 14))
                .foregroundColor(Tokens.muted)
                .padding(.bottom, 24)
            HStack(spacing: 9) {
                Button("Создать пространство") { shell.presentCreate() }.buttonStyle(NotesButtonStyle(kind: .primary))
                Button("Открыть пространство…") { shell.presentOpen() }.buttonStyle(NotesButtonStyle())
                Button("Восстановить из копии…") { shell.presentRestore() }.buttonStyle(NotesButtonStyle())
            }
            Button("Открыть файлы на диске") { shell.goFiles() }
                .buttonStyle(NotesButtonStyle(kind: .plain))
                .padding(.top, 9)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
