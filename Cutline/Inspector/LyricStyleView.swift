import SwiftUI

struct LyricStyleView: View {
    @EnvironmentObject var editor: EditorModel
    var body: some View {
        VStack(alignment: .leading) {
            Text("Lyrics").font(.headline)
            Spacer()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
