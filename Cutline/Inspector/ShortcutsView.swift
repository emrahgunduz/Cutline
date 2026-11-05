import SwiftUI

struct ShortcutGroup: Identifiable {
    let section: String
    let icon: String
    let items: [(keys: String, action: String)]
    var id: String { section }
}

/// Every shortcut, grouped by where it applies. Keep in sync with the key handlers.
enum Shortcuts {
    static let groups: [ShortcutGroup] = [
        ShortcutGroup(section: "Playback", icon: "play.circle", items: [
            ("Space", "Play / pause"),
            ("← / →", "Previous / next frame"),
            ("⇧← / ⇧→", "Back / forward 1 second"),
            ("↑ / ↓", "Previous / next edit point"),
            ("Home / End", "Go to start / end"),
        ]),
        ShortcutGroup(section: "Editing", icon: "scissors", items: [
            ("C", "Cut at playhead (also ⌘B)"),
            ("⌫", "Delete selection"),
            ("⌘Z / ⇧⌘Z", "Undo / redo"),
            ("⌘-click", "Add to / remove from selection"),
            ("⇧-drag", "Selection box on empty timeline"),
            ("Drag song", "Moves clips, lyrics and markers with it"),
            ("⌥-drag song", "Move the song alone"),
        ]),
        ShortcutGroup(section: "Timeline", icon: "rectangle.split.3x1", items: [
            ("S", "Snapping on / off"),
            ("⌘ while dragging", "Bypass snapping"),
            ("Bar toggles", "Snap to sections, downbeats, beats, edges"),
            ("= / −", "Zoom in / out"),
            ("⌘0", "Zoom to fit"),
            ("⌥-scroll / pinch", "Zoom at pointer"),
            ("Middle-drag", "Pan the timeline"),
            ("Double-click header", "Collapse / expand track"),
            ("Drag header ≡", "Reorder tracks"),
        ]),
        ShortcutGroup(section: "Lyrics", icon: "text.quote", items: [
            ("N / ⇧N", "Next / previous unsure word (loops it)"),
            ("Return", "Confirm the selected word"),
            ("Esc", "Stop looping"),
            ("T", "Tap mode: Space times each word in turn"),
            ("1 / 2 / 3", "Tap mode speed 100% / 75% / 50%"),
            ("⌥⌘L", "Align words to the song"),
        ]),
        ShortcutGroup(section: "Preview", icon: "rectangle.on.rectangle", items: [
            ("Scroll / pinch", "Zoom at pointer"),
            ("Drag empty area", "Pan when zoomed"),
            ("Drag clip / corner", "Move / scale clip"),
            ("⌥← → ↑ ↓", "Nudge clip (⇧ for 10 px)"),
            ("Click lyric", "Select the whole line"),
        ]),
        ShortcutGroup(section: "Project", icon: "doc", items: [
            ("⌘N", "New project"),
            ("⌘O", "Open project"),
            ("⌘I", "Import media"),
            ("⌘S", "Save"),
            ("⌘E", "Export"),
        ]),
    ]
}

struct ShortcutsView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Keyboard Shortcuts").font(.headline)
                ForEach(Shortcuts.groups) { group in
                    VStack(alignment: .leading, spacing: 6) {
                        Label(group.section, systemImage: group.icon).font(.system(size: 12, weight: .semibold))
                        ForEach(group.items.indices, id: \.self) { i in
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Text(group.items[i].keys)
                                    .font(.system(size: 11, weight: .medium, design: .rounded))
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.08)))
                                    .frame(width: 130, alignment: .leading)
                                Text(group.items[i].action).font(.system(size: 12))
                            }
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
                }
            }
            .padding(12)
        }
    }
}
