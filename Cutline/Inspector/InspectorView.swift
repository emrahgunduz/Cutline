import SwiftUI

struct InspectorView: View {
    @EnvironmentObject var editor: EditorModel

    var body: some View {
        switch editor.selection {
        case .none:
            ShortcutsView()
        case .clip(let id):
            ClipInspectorView(clipID: id)
        case .lyricLine, .lyricWord:
            LyricStyleView()
        case .audio:
            VStack(alignment: .leading, spacing: 8) {
                Text("Audio").font(.headline)
                Text(editor.project.audio.flatMap { editor.project.asset($0.assetID)?.name } ?? "")
                Text("Drop another audio file on the audio track to replace it, or press ⌫ to remove it.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
