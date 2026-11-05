import SwiftUI

/// Size, placement and filters of the selected clip. Each filter section has an on/off switch;
/// its controls show only while it is on, and switching it off removes the effect.
struct ClipInspectorView: View {
    @EnvironmentObject var editor: EditorModel
    let clipID: UUID
    @AppStorage(NudgeStep.key) private var nudgeStep = NudgeStep.defaultValue

    var body: some View {
        if let clip = editor.clip(clipID) {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(editor.project.asset(clip.assetID)?.name ?? "Clip").font(.headline).lineLimit(1).truncationMode(.middle)
                        Text("\(Timecode.string(clip.start, fps: editor.project.fps)) – \(Timecode.string(clip.end, fps: editor.project.fps))")
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    InspectorSection(title: "Size & Position", icon: "arrow.up.left.and.arrow.down.right") {
                        let fill = editor.project.asset(clip.assetID).map { Project.fillScale(for: $0, canvas: editor.project.canvas) } ?? 1
                        row("Scale", clip.transform.scale, 0.05...max(4, fill * 1.5), step: 0.01, reset: fill) { $0.transform.scale = $1 }
                        row("X", clip.transform.offsetX, -Double(editor.project.canvas.width)...Double(editor.project.canvas.width), step: 1, format: "%.0f", reset: 0) { $0.transform.offsetX = $1 }
                        row("Y", clip.transform.offsetY, -Double(editor.project.canvas.height)...Double(editor.project.canvas.height), step: 1, format: "%.0f", reset: 0) { $0.transform.offsetY = $1 }
                        HStack {
                            Spacer()
                            // Fill covers the whole frame (cropping the overflow); Fit shows the whole picture.
                            Button("Fill") { editor.edit("Fill Frame") { $0.updateClip(clipID) { $0.transform.scale = fill; $0.transform.offsetX = 0; $0.transform.offsetY = 0 } } }
                                .controlSize(.small).help("Scale to cover the whole frame, centred (the overflow is cropped)")
                            Button("Fit") { editor.edit("Fit Frame") { $0.updateClip(clipID) { $0.transform.scale = 1; $0.transform.offsetX = 0; $0.transform.offsetY = 0 } } }
                                .controlSize(.small).help("Scale to show the whole picture, centred")
                            Button("Reset Position") { editor.edit("Reset Position") { $0.updateClip(clipID) { $0.transform.offsetX = 0; $0.transform.offsetY = 0 } } }
                                .controlSize(.small).disabled(clip.transform.offsetX == 0 && clip.transform.offsetY == 0)
                        }
                        ValueRow(label: "⇧ Nudge", value: nudgeStep, range: 1...200, step: 1, format: "%.0f px", defaultValue: NudgeStep.defaultValue,
                                 onChange: { nudgeStep = $0.rounded() }, onCommit: {})
                            .help("Arrow keys move the selection 1 px in the preview; with ⇧ they move it this far.")
                    }
                    InspectorSection(title: "Color", icon: "paintpalette", isOn: toggle(clip.filters.color.enabled, "Color") { $0.filters.color.enabled = $1 }) {
                        row("Hue", clip.filters.color.hue, -180...180, step: 1, format: "%.0f°", reset: 0) { $0.filters.color.hue = $1 }
                        row("Saturation", clip.filters.color.saturation, 0...2, reset: 1) { $0.filters.color.saturation = $1 }
                        row("Brightness", clip.filters.color.brightness, -1...1, reset: 0) { $0.filters.color.brightness = $1 }
                        row("Contrast", clip.filters.color.contrast, 0...2, reset: 1) { $0.filters.color.contrast = $1 }
                        HStack {
                            Spacer()
                            Button("Reset") { editor.edit("Reset Color") { $0.updateClip(clipID) { $0.filters.color = ColorFilter(enabled: true) } } }
                                .controlSize(.small)
                        }
                    }
                    InspectorSection(title: "Fade In / Out", icon: "circle.lefthalf.filled", isOn: toggle(clip.filters.fade.enabled, "Fade") { $0.filters.fade.enabled = $1 }) {
                        row("Fade in", clip.filters.fade.fadeIn, 0...min(5, clip.duration), step: 0.01, format: "%.2fs", reset: 0.5) { $0.filters.fade.fadeIn = $1 }
                        row("Fade out", clip.filters.fade.fadeOut, 0...min(5, clip.duration), step: 0.01, format: "%.2fs", reset: 0.5) { $0.filters.fade.fadeOut = $1 }
                    }
                }
                .padding(12)
            }
        }
    }

    private func toggle(_ on: Bool, _ name: String, set: @escaping (inout Clip, Bool) -> Void) -> Binding<Bool> {
        Binding(get: { on }, set: { v in editor.edit(v ? "Enable \(name)" : "Disable \(name)") { $0.updateClip(clipID) { set(&$0, v) } } })
    }

    private func row(_ label: String, _ value: Double, _ range: ClosedRange<Double>, step: Double? = nil, format: String = "%.2f",
                     reset: Double? = nil, set: @escaping (inout Clip, Double) -> Void) -> some View {
        ValueRow(label: label, value: value, range: range, step: step, format: format, defaultValue: reset,
                 onChange: { v in editor.liveEdit { $0.updateClip(clipID) { set(&$0, v) } } },
                 onCommit: { editor.endLiveEdit(label) })
    }
}
