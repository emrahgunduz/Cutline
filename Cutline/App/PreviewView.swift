import AVFoundation
import AppKit
import SwiftUI

enum PreviewContainer {
    static func make(editor: EditorModel) -> NSView {
        NSHostingView(rootView: PreviewView(controller: PreviewController(editor: editor)).environmentObject(editor))
    }
}

struct PreviewView: View {
    @EnvironmentObject var editor: EditorModel
    @StateObject var controller: PreviewController

    var body: some View {
        VStack(spacing: 0) {
            CanvasRepresentable(controller: controller, editor: editor)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            HStack(spacing: 12) {
                Group {
                    Button(action: editor.goToStart) { Image(systemName: "backward.end.fill") }.help("Go to start (Home)")
                    Button { editor.stepFrame(-1) } label: { Image(systemName: "backward.frame.fill") }.help("Previous frame (←)")
                    Button(action: editor.togglePlay) { Image(systemName: editor.isPlaying ? "pause.fill" : "play.fill").frame(width: 18) }
                        .help("Play / pause (Space)")
                    Button { editor.stepFrame(1) } label: { Image(systemName: "forward.frame.fill") }.help("Next frame (→)")
                    Button(action: editor.goToEnd) { Image(systemName: "forward.end.fill") }.help("Go to end (End)")
                }
                .font(.system(size: 14))
                Spacer()
                Text("\(Timecode.string(editor.playhead, fps: editor.project.fps)) / \(Timecode.string(editor.project.duration, fps: editor.project.fps))")
                    .font(.system(.body, design: .monospaced))
                Spacer()
                Button { controller.stepZoom(1 / 1.25) } label: { Image(systemName: "minus.magnifyingglass") }.help("Zoom out (⌥-scroll or pinch)")
                Menu(zoomLabel) {
                    Button("Fit") { controller.resetView() }
                    Divider()
                    ForEach([25.0, 50, 100, 200, 400], id: \.self) { p in Button("\(Int(p))%") { controller.setZoom(percent: p) } }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                Button { controller.stepZoom(1.25) } label: { Image(systemName: "plus.magnifyingglass") }.help("Zoom in")
                Button { controller.resetView() } label: { Image(systemName: "arrow.up.left.and.down.right.magnifyingglass") }
                    .help("Fit and center (reset zoom and pan)")
                    .disabled(controller.zoom == nil && controller.pan == .zero)
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 12).padding(.vertical, 8)
        }
    }

    private var zoomLabel: String {
        controller.zoom.map { "\(Int(($0 * 100).rounded()))%" } ?? "Fit (\(controller.fitPercent)%)"
    }
}

private struct CanvasRepresentable: NSViewRepresentable {
    let controller: PreviewController
    let editor: EditorModel
    func makeNSView(context: Context) -> PreviewCanvasView { PreviewCanvasView(controller: controller, editor: editor) }
    func updateNSView(_ nsView: PreviewCanvasView, context: Context) {}
}
