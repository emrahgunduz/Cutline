import AppKit
import SwiftUI

enum PreviewContainer {
    static func make(editor: EditorModel) -> NSView {
        NSHostingView(rootView: PreviewView().environmentObject(editor))
    }
}

struct PreviewView: View {
    @EnvironmentObject var editor: EditorModel

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Color(nsColor: .underPageBackgroundColor)
                Rectangle().fill(.black)
                    .aspectRatio(editor.project.canvas.cgSize, contentMode: .fit)
                    .padding(12)
            }
            Divider()
            Text(Timecode.string(editor.playhead, fps: editor.project.fps)).font(.system(.body, design: .monospaced)).padding(8)
        }
    }

    private func timecode(_ t: Double) -> String {
        let fps = editor.project.fps
        let frames = Int((t * fps).rounded())
        let f = frames % Int(fps.rounded())
        let s = frames / Int(fps.rounded())
        return String(format: "%02d:%02d:%02d", s / 60, s % 60, f)
    }
}
