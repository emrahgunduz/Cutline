import AppKit
import SwiftUI

/// The Settings window (⌘,): one tab per section.
final class SettingsWindow: NSObject {
    static let shared = SettingsWindow()
    private var window: NSWindow?

    @objc func show(_ sender: Any?) {
        if window == nil {
            let w = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "Cutline Settings"
            w.isReleasedWhenClosed = false
            let host = NSHostingController(rootView: SettingsView())
            host.sizingOptions = [.preferredContentSize]
            w.contentViewController = host
            w.center()
            window = w
        }
        window?.makeKeyAndOrderFront(nil)
    }
}

struct SettingsView: View {
    var body: some View {
        TabView {
            PresetsSettingsView().tabItem { Label("Presets", systemImage: "slider.horizontal.3") }
            ModelsSettingsView(store: .shared).padding(.vertical, 8).tabItem { Label("Models", systemImage: "square.stack.3d.down.right") }
        }
        .padding(.top, 8)
    }
}
