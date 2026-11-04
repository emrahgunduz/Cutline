import AppKit

enum TimelineContainer {
    static func make(editor: EditorModel) -> NSView { TimelineView(editor: editor) }
}
