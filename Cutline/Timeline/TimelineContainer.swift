import AppKit

enum TimelineContainer {
    static func make(editor: EditorModel) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        return view
    }
}
