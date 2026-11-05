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
                TransportControls(transport: editor.transport)
                Spacer()
                if editor.project.type.isPortrait { PlatformOverlayMenu() }
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

/// Play controls and timecode. Observes only the transport, so playback ticks redraw
/// this bar and nothing else in the preview panel.
private struct TransportControls: View {
    @EnvironmentObject var editor: EditorModel
    @ObservedObject var transport: TransportState

    var body: some View {
        Group {
            Button(action: editor.goToStart) { Image(systemName: "backward.end.fill") }.tip("Go to start (Home)")
            Button { editor.stepFrame(-1) } label: { Image(systemName: "backward.frame.fill") }.tip("Previous frame (←)")
            Button(action: editor.togglePlay) { Image(systemName: transport.isPlaying ? "pause.fill" : "play.fill").frame(width: 18) }
                .tip("Play / pause (Space)")
            Button { editor.stepFrame(1) } label: { Image(systemName: "forward.frame.fill") }.tip("Next frame (→)")
            Button(action: editor.goToEnd) { Image(systemName: "forward.end.fill") }.tip("Go to end (End)")
        }
        .font(.system(size: 14))
        Spacer()
        Text("\(Timecode.string(transport.playhead, fps: editor.project.fps)) / \(Timecode.string(editor.project.duration, fps: editor.project.fps))")
            .font(.system(.body, design: .monospaced))
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

/// Portrait projects: switch the TikTok / Reels / Shorts screen zones on and off in the preview.
private struct PlatformOverlayMenu: View {
    @EnvironmentObject var editor: EditorModel

    private var on: Set<String> { Set(editor.project.platformOverlays ?? []) }

    var body: some View {
        Menu {
            ForEach(PlatformOverlay.all) { o in
                Toggle(o.name, isOn: Binding(get: { on.contains(o.id) }, set: { show in
                    editor.edit(show ? "Show \(o.name) Zones" : "Hide \(o.name) Zones") { p in
                        var ids = p.platformOverlays ?? []
                        ids.removeAll { $0 == o.id }
                        if show { ids.append(o.id) }
                        p.platformOverlays = ids.isEmpty ? nil : ids
                    }
                }))
            }
        } label: {
            Label(on.isEmpty ? "Platform UI" : "Platform UI (\(on.count))", systemImage: "rectangle.dashed")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .tip("Show where TikTok, Reels and Shorts draw their buttons and captions. Automatically placed lyrics stay clear of the zones you switch on. Preview only, never exported.")
    }
}
