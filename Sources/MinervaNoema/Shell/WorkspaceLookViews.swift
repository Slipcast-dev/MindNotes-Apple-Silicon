import AppKit
import SwiftUI

/// Логотип пространства.
struct BrandLogo: View {
    @EnvironmentObject private var shell: ShellModel
    var size: CGFloat = 35
    /// Предпросмотр в окне настройки; иначе — текущий вид пространства.
    var look: WorkspaceLook?

    private var current: WorkspaceLook { look ?? shell.look }

    var body: some View {
        let l = current
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.31).fill(Tokens.swatch(l.logoColor)?.fg ?? Tokens.logo)
            switch l.logoKind {
            case .symbol:
                Image(systemName: l.logoValue)
                    .font(.system(size: size * 0.49, weight: .semibold))
                    .foregroundColor(.white)
            case .emoji:
                Text(l.logoValue).font(.system(size: size * 0.6))
            case .image:
                if let image = shell.image(for: l.logoAsset) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: size, height: size)
                        .clipShape(RoundedRectangle(cornerRadius: size * 0.31))
                }
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// Обложка главного экрана.
struct CoverView: View {
    @EnvironmentObject private var shell: ShellModel
    var look: WorkspaceLook?
    var height: CGFloat = 205
    var showsLabel = true

    private var current: WorkspaceLook { look ?? shell.look }

    var body: some View {
        let l = current
        ZStack(alignment: .topLeading) {
            if l.coverKind == .image, let image = shell.image(for: l.coverAsset) {
                Color.clear.overlay(Image(nsImage: image).resizable().scaledToFill()).clipped()
            } else {
                CoverArt(preset: CoverPreset.find(l.coverPreset))
            }
            if showsLabel, let text = Optional(l.coverLabel ?? L("ЛИЧНОЕ ПРОСТРАНСТВО")), !text.isEmpty {
                Text(text)
                    .font(.system(size: 10))
                    .tracking(2)
                    .foregroundColor(.black.opacity(0.7))
                    .padding(.leading, 24)
                    .padding(.top, 20)
            }
        }
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

/// Настройка внешнего вида пространства; изменения видны сразу и сохраняются кнопкой.
struct WorkspaceLookSheet: View {
    @EnvironmentObject private var shell: ShellModel
    @Environment(\.dismiss) private var dismiss
    @State private var draft = WorkspaceLook()
    @State private var name = ""
    @State private var emoji = ""
    @State private var label = ""
    /// Картинки, загруженные в этом окне: неиспользованные удаляются при закрытии.
    @State private var picked: Set<UUID> = []
    @State private var picking = false

    private static let symbols = ["sparkle", "leaf", "mountain.2", "star", "book", "heart", "bolt", "flame", "pawprint", "briefcase", "house", "graduationcap"]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Настроить пространство").font(Tokens.titleFont(26)).padding(.bottom, 16)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    CoverView(look: draft, height: 120)
                    section(L("Название")) {
                        TextField(L("Название"), text: $name).textFieldStyle(.roundedBorder)
                    }
                    section(L("Логотип")) {
                        HStack(spacing: 12) {
                            BrandLogo(size: 48, look: draft)
                            VStack(alignment: .leading, spacing: 8) {
                                symbolGrid
                                HStack(spacing: 8) {
                                    TextField(L("Emoji"), text: $emoji)
                                        .textFieldStyle(.roundedBorder)
                                        .frame(width: 70)
                                        .onChange(of: emoji) { value in
                                            guard let first = value.first else { return }
                                            draft.logoKind = .emoji
                                            draft.logoValue = String(first)
                                        }
                                    Button(L("Своё изображение…")) { pick { draft.logoKind = .image; draft.logoAsset = $0 } }
                                        .buttonStyle(NotesButtonStyle())
                                }
                            }
                        }
                        colorRow
                    }
                    section(L("Обложка")) {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                            ForEach(CoverPreset.all) { preset in
                                coverTile(preset.title, selected: draft.coverKind == .preset && CoverPreset.find(draft.coverPreset).id == preset.id) {
                                    draft.coverKind = .preset
                                    draft.coverPreset = preset.id
                                } content: { CoverArt(preset: preset) }
                            }
                        }
                        HStack(spacing: 8) {
                            Button(L("Своё изображение…")) { pick { draft.coverKind = .image; draft.coverAsset = $0 } }
                                .buttonStyle(NotesButtonStyle())
                            Button(L("Без обложки")) { draft.coverKind = .none }
                                .buttonStyle(NotesButtonStyle(kind: draft.coverKind == .none ? .primary : .normal))
                        }
                        TextField(L("Подпись на обложке"), text: $label)
                            .textFieldStyle(.roundedBorder)
                            .onChange(of: label) { draft.coverLabel = $0 }
                    }
                }
                .padding(.trailing, 8)
            }
            HStack {
                Spacer()
                Button(L("Отмена")) {
                    shell.discardAssets(picked)
                    dismiss()
                }.buttonStyle(NotesButtonStyle()).keyboardShortcut(.cancelAction)
                Button(L("Готово")) {
                    shell.saveLook(draft, name: name, candidates: picked)
                    dismiss()
                }
                .buttonStyle(NotesButtonStyle(kind: .primary))
                .keyboardShortcut(.defaultAction)
                .disabled(picking)
            }
            .padding(.top, 14)
        }
        .padding(23)
        .frame(width: 560, height: 640)
        .background(Tokens.paper)
        .onAppear {
            draft = shell.look
            name = shell.workspaceName
            label = shell.look.coverLabel ?? L("ЛИЧНОЕ ПРОСТРАНСТВО")
            if shell.look.logoKind == .emoji { emoji = shell.look.logoValue }
        }
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 14, weight: .semibold))
            content()
        }
    }

    private var symbolGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(30), spacing: 4), count: 8), alignment: .leading, spacing: 4) {
            ForEach(Self.symbols, id: \.self) { symbol in
                let selected = draft.logoKind == .symbol && draft.logoValue == symbol
                Button {
                    draft.logoKind = .symbol
                    draft.logoValue = symbol
                    emoji = ""
                } label: {
                    Image(systemName: symbol)
                        .font(.system(size: 13))
                        .foregroundColor(Tokens.ink)
                        .frame(width: 30, height: 30)
                        .background(RoundedRectangle(cornerRadius: 7).fill(selected ? Tokens.soft : .clear))
                        .overlay(RoundedRectangle(cornerRadius: 7).stroke(selected ? Tokens.accent : Tokens.line))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(symbol))
            }
        }
    }

    private var colorRow: some View {
        HStack(spacing: 6) {
            swatch(nil, Tokens.logo)
            ForEach(BlockTextStyle.colors, id: \.name) { c in
                swatch(c.name, Tokens.swatch(c.name)?.fg ?? Tokens.logo)
            }
        }
    }

    private func swatch(_ name: String?, _ color: Color) -> some View {
        Button { draft.logoColor = name } label: {
            Circle()
                .fill(color)
                .frame(width: 20, height: 20)
                .overlay(Circle().stroke(draft.logoColor == name ? Tokens.ink : .clear, lineWidth: 2).padding(-3))
        }
        .buttonStyle(.plain)
        .padding(3)
        .accessibilityLabel(Text(name ?? L("Цвет темы")))
    }

    private func coverTile<C: View>(_ title: String, selected: Bool, action: @escaping () -> Void, @ViewBuilder content: () -> C) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                content()
                    .frame(height: 56)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(selected ? Tokens.accent : Tokens.line, lineWidth: selected ? 2 : 1))
                Text(title).font(.system(size: 11)).foregroundColor(Tokens.muted)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func pick(_ done: @escaping (UUID) -> Void) {
        picking = true
        shell.pickImage { id in
            picking = false
            guard let id else { return }
            picked.insert(id)
            done(id)
        }
    }
}
