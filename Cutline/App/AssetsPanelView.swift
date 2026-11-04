import SwiftUI

struct AssetsPanelView: View {
    @EnvironmentObject var editor: EditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Assets").font(.headline)
                Spacer()
                Button("Import…") { AssetImporter.presentOpenPanel(for: editor, window: NSApp.keyWindow) }
            }
            .padding(10)
            Divider()
            List(editor.project.assets) { asset in
                Label(asset.name, systemImage: icon(asset.kind))
            }
        }
    }

    private func icon(_ kind: AssetKind) -> String {
        switch kind {
        case .video: "film"
        case .image: "photo"
        case .audio: "waveform"
        case .lyrics: "text.quote"
        }
    }
}
