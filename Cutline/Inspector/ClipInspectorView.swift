import SwiftUI

/// Size, placement and filters of the selected clip. Each filter has an on/off switch;
/// its controls show only while it is on, and switching it off removes the effect.
struct ClipInspectorView: View {
    @EnvironmentObject var editor: EditorModel
    let clipID: UUID

    var body: some View {
        if let clip = editor.clip(clipID) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(editor.project.asset(clip.assetID)?.name ?? "Clip").font(.headline).lineLimit(1)
                    section("Size & Position") {
                        slider("Scale", clip.transform.scale, 0.1...4) { $0.transform.scale = $1 }
                        slider("X", clip.transform.offsetX, -Double(editor.project.canvas.width)...Double(editor.project.canvas.width)) { $0.transform.offsetX = $1 }
                        slider("Y", clip.transform.offsetY, -Double(editor.project.canvas.height)...Double(editor.project.canvas.height)) { $0.transform.offsetY = $1 }
                        Button("Reset") { update("Reset Transform") { $0.transform = ClipTransform() } }
                    }
                    toggleSection("Color", clip.filters.color.enabled) { $0.filters.color.enabled = $1 } content: {
                        slider("Hue", clip.filters.color.hue, -180...180) { $0.filters.color.hue = $1 }
                        slider("Saturation", clip.filters.color.saturation, 0...2) { $0.filters.color.saturation = $1 }
                        slider("Brightness", clip.filters.color.brightness, -1...1) { $0.filters.color.brightness = $1 }
                        slider("Contrast", clip.filters.color.contrast, 0...2) { $0.filters.color.contrast = $1 }
                    }
                    toggleSection("Fade In / Out", clip.filters.fade.enabled) { $0.filters.fade.enabled = $1 } content: {
                        slider("Fade in (s)", clip.filters.fade.fadeIn, 0...min(5, clip.duration)) { $0.filters.fade.fadeIn = $1 }
                        slider("Fade out (s)", clip.filters.fade.fadeOut, 0...min(5, clip.duration)) { $0.filters.fade.fadeOut = $1 }
                    }
                }
                .padding(14)
            }
        }
    }

    private func update(_ name: String, _ change: @escaping (inout Clip) -> Void) {
        editor.edit(name) { $0.updateClip(clipID, change) }
    }

    @ViewBuilder
    private func section<C: View>(_ title: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline.bold())
            content()
        }
    }

    @ViewBuilder
    private func toggleSection<C: View>(_ title: String, _ on: Bool, set: @escaping (inout Clip, Bool) -> Void,
                                        @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(title, isOn: Binding(get: { on }, set: { v in update(v ? "Enable \(title)" : "Disable \(title)") { set(&$0, v) } }))
                .toggleStyle(.switch).font(.subheadline.bold())
            if on { content() }
        }
    }

    private func slider(_ label: String, _ value: Double, _ range: ClosedRange<Double>, set: @escaping (inout Clip, Double) -> Void) -> some View {
        HStack {
            Text(label).frame(width: 84, alignment: .leading)
            Slider(value: Binding(get: { value }, set: { v in update(label) { set(&$0, v) } }), in: range)
            Text(String(format: "%.2f", value)).font(.caption.monospacedDigit()).frame(width: 52, alignment: .trailing)
        }
    }
}
