import SwiftUI

struct ShortcutGroup: Identifiable {
    let section: String
    let items: [(keys: String, action: String)]
    var id: String { section }
}

enum Shortcuts {
    static let groups: [ShortcutGroup] = [
        ShortcutGroup(section: "Assets", items: [
            ("⌘I", "Import media"),
            ("Drag to timeline", "Place a clip"),
        ]),
        ShortcutGroup(section: "Preview", items: [
            ("Space", "Play / pause"),
            ("Home", "Go to start"),
            ("End", "Go to end"),
            ("← / →", "Previous / next frame"),
        ]),
        ShortcutGroup(section: "Timeline", items: [
            ("⌘B", "Split at playhead"),
            ("⌫", "Delete selection"),
            ("⌘= / ⌘−", "Zoom in / out"),
            ("⌘0", "Zoom to fit"),
            ("⌘Z / ⇧⌘Z", "Undo / redo"),
            ("Hold ⌘ while dragging", "Disable snapping"),
        ]),
        ShortcutGroup(section: "Lyrics", items: [
            ("Drag edge", "Change word or line start/end"),
            ("Drag line", "Move line (and its words)"),
        ]),
        ShortcutGroup(section: "Export", items: [
            ("⌘E", "Export"),
            ("⌘S", "Save project"),
        ]),
    ]
}

struct ShortcutsView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Keyboard Shortcuts").font(.headline)
                ForEach(Shortcuts.groups) { group in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(group.section.uppercased()).font(.caption).foregroundStyle(.secondary)
                        ForEach(group.items.indices, id: \.self) { i in
                            HStack(alignment: .firstTextBaseline) {
                                Text(group.items[i].keys).font(.system(.body, design: .monospaced))
                                    .frame(width: 120, alignment: .leading)
                                Text(group.items[i].action)
                            }
                        }
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
