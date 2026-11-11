import AVKit
import SwiftUI

/// Видео со страницы. Файл лежит в пространстве; проигрывается без копирования.
struct PlayingVideo: Identifiable {
    let id = UUID()
    let url: URL
    let name: String
}

/// Проигрыватель в окне приложения: воспроизведение начинается сразу и останавливается при закрытии.
struct VideoPlayerSheet: View {
    @Environment(\.dismiss) private var dismiss
    let video: PlayingVideo
    @State private var player: AVPlayer?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(video.name).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                Spacer()
                Button("Открыть в QuickTime") { NSWorkspace.shared.open(video.url) }.buttonStyle(NotesButtonStyle(kind: .plain))
                Button("Закрыть") { dismiss() }.buttonStyle(NotesButtonStyle()).keyboardShortcut(.cancelAction)
            }
            .padding(12)
            PlayerView(player: player)
                .frame(minWidth: 720, minHeight: 405)
                .background(Color.black)
        }
        .frame(width: 860, height: 540)
        .background(Tokens.paper)
        .onAppear {
            let created = AVPlayer(url: video.url)
            player = created
            created.play()
        }
        .onDisappear {
            player?.pause()
            player = nil
        }
    }
}

/// Системный проигрыватель AppKit. Обёртка SwiftUI `VideoPlayer` не годится: её класс лежит в отдельном модуле,
/// который сборка через swiftc не подключает, и приложение падало при показе.
struct PlayerView: NSViewRepresentable {
    let player: AVPlayer?

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .floating
        view.showsFullScreenToggleButton = true
        view.player = player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }
}
