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
            PlayerLayerView(player: controller.player)
                .aspectRatio(editor.project.canvas.cgSize, contentMode: .fit)
                .padding(12)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .underPageBackgroundColor))
            Divider()
            HStack(spacing: 14) {
                Button(action: editor.goToStart) { Image(systemName: "backward.end.fill") }.help("Go to start (Home)")
                Button { editor.stepFrame(-1) } label: { Image(systemName: "backward.frame.fill") }.help("Previous frame (←)")
                Button(action: editor.togglePlay) { Image(systemName: editor.isPlaying ? "pause.fill" : "play.fill") }
                    .help("Play / pause (Space)")
                Button { editor.stepFrame(1) } label: { Image(systemName: "forward.frame.fill") }.help("Next frame (→)")
                Button(action: editor.goToEnd) { Image(systemName: "forward.end.fill") }.help("Go to end (End)")
                Spacer()
                Text("\(Timecode.string(editor.playhead, fps: editor.project.fps)) / \(Timecode.string(editor.project.duration, fps: editor.project.fps))")
                    .font(.system(.body, design: .monospaced))
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 12).padding(.vertical, 8)
        }
    }
}

private struct PlayerLayerView: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        v.wantsLayer = true
        let layer = AVPlayerLayer(player: player)
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = NSColor.black.cgColor
        v.layer = layer
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
