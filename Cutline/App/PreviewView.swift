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
                    Button(action: editor.goToStart) { Image(systemName: "backward.end.fill") }.tip("Go to start (Home)")
                    Button { editor.stepFrame(-1) } label: { Image(systemName: "backward.frame.fill") }.tip("Previous frame (←)")
                    Button(action: editor.togglePlay) { Image(systemName: editor.isPlaying ? "pause.fill" : "play.fill").frame(width: 18) }
                        .tip("Play / pause (Space)")
                    Button { editor.stepFrame(1) } label: { Image(systemName: "forward.frame.fill") }.tip("Next frame (→)")
                    Button(action: editor.goToEnd) { Image(systemName: "forward.end.fill") }.tip("Go to end (End)")
                }
                .font(.system(size: 14))
                Spacer()
                Text("\(Timecode.string(editor.playhead, fps: editor.project.fps)) / \(Timecode.string(editor.project.duration, fps: editor.project.fps))")
                    .font(.system(.body, design: .monospaced))
                Spacer()
                Button { controller.stepZoom(1 / 1.25) } label: { Image(systemName: "minus.magnifyingglass") }.tip("Zoom out (mouse wheel or pinch zooms at the pointer)")
                Menu(zoomLabel) {
                    Button("Fit") { controller.resetView() }
                    Divider()
                    ForEach([25.0, 50, 100, 200, 400], id: \.self) { p in Button("\(Int(p))%") { controller.setZoom(percent: p) } }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .tip("Preview zoom")
                Button { controller.stepZoom(1.25) } label: { Image(systemName: "plus.magnifyingglass") }.tip("Zoom in")
                Button { controller.center() } label: { Image(systemName: "scope") }
                    .tip("Center the canvas (keep zoom)")
                    .disabled(controller.pan == .zero)
                Button { controller.resetView() } label: { Image(systemName: "arrow.up.left.and.down.right.magnifyingglass") }
                    .tip("Fit to view and center")
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

/// Tooltip backed by AppKit's toolTip, which shows reliably inside hosted SwiftUI views.
private struct ToolTipView: NSViewRepresentable {
    let text: String
    func makeNSView(context: Context) -> NSView { let v = PassthroughView(); v.toolTip = text; return v }
    func updateNSView(_ nsView: NSView, context: Context) { nsView.toolTip = text }
    final class PassthroughView: NSView { override func hitTest(_ point: NSPoint) -> NSView? { nil } }
}

extension View {
    func tip(_ text: String) -> some View { help(text).overlay(ToolTipView(text: text)) }
}
