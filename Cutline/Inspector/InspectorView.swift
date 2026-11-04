import SwiftUI

struct InspectorView: View {
    @EnvironmentObject var editor: EditorModel

    var body: some View {
        if editor.selection == .none {
            ShortcutsView()
        } else {
            VStack(alignment: .leading) {
                Text("Inspector").font(.headline)
                Spacer()
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
