import AppKit
import SwiftUI

/// The blurred, see-through layer behind the content of the window (the "glass" of macOS).
struct VisualEffect: NSViewRepresentable {
    let material: NSVisualEffectView.Material

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) { view.material = material }
}

/// A window only shows what is behind it when it is not opaque; with the effect off it goes back to a normal window.
struct GlassWindowConfigurator: NSViewRepresentable {
    let enabled: Bool

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.isOpaque = !enabled
            window.backgroundColor = enabled ? .clear : .windowBackgroundColor
        }
    }
}

private struct SurfaceOpacityKey: EnvironmentKey { static let defaultValue = 1.0 }

private struct TabsOpacityKey: EnvironmentKey { static let defaultValue = 1.0 }

extension EnvironmentValues {
    /// How opaque the tab bar is.
    var tabsOpacity: Double {
        get { self[TabsOpacityKey.self] }
        set { self[TabsOpacityKey.self] = newValue }
    }

    /// How opaque the document backgrounds are: below 1 the glass behind the window shows through.
    var surfaceOpacity: Double {
        get { self[SurfaceOpacityKey.self] }
        set { self[SurfaceOpacityKey.self] = newValue }
    }
}
