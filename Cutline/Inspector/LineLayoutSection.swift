import SwiftUI

/// Line Layout (per lyric line): single line with automatic width, or wrapped at a width with
/// automatic height, and the text alignment. Applies to every selected line; shows the first
/// one's values.
struct LineLayoutSection: View {
    @EnvironmentObject var editor: EditorModel

    var body: some View {
        let ids = editor.placementLineIDs
        if let first = ids.first.flatMap(editor.line) {
            let layout = first.layout
            let mixed = ids.compactMap(editor.line).contains { $0.layout != layout }
            InspectorSection(title: ids.count > 1 ? "Line Layout · \(ids.count) lines" : "Line Layout", icon: "text.justify.left") {
                Picker("", selection: Binding(get: { layout.mode }, set: { editor.setLineMode($0) })) {
                    Label("Auto width", systemImage: "arrow.left.and.right.text.vertical").tag(LineLayout.Mode.singleLine)
                    Label("Auto height", systemImage: "text.word.spacing").tag(LineLayout.Mode.wrapped)
                }
                .pickerStyle(.segmented).labelsHidden().controlSize(.small)
                Text(layout.mode == .singleLine
                     ? "One line, as wide as the text (it can be wider than the frame)."
                     : "Wraps at the width; as tall as its lines.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if layout.mode == .wrapped {
                    ValueRow(label: "Width", value: layout.width, range: 0...max(Double(editor.project.canvas.width) * 1.5, layout.width),
                             step: 1, format: "%.0f px", typedRange: 0...100_000,
                             onChange: { v in editor.setLineLayout("Line Width", live: true) { $0.width = v.rounded() } },
                             onCommit: { editor.endLiveEdit("Line Width") })
                        .help("Wrap width in pixels (no upper limit; type a value for more than the slider reaches)")
                }
                HStack(spacing: 8) {
                    Text("Text align").font(.system(size: 12)).frame(width: 76, alignment: .leading)
                    Picker("", selection: Binding(get: { layout.align }, set: { a in editor.setLineLayout("Text Alignment") { $0.align = a } })) {
                        Image(systemName: "text.alignleft").tag(LineLayout.Align.left).help("Left")
                        Image(systemName: "text.aligncenter").tag(LineLayout.Align.center).help("Center")
                        Image(systemName: "text.alignright").tag(LineLayout.Align.right).help("Right")
                    }
                    .pickerStyle(.segmented).labelsHidden().controlSize(.small).fixedSize()
                    Spacer()
                }
                if mixed {
                    Text("The selected lines differ; changes apply to all of them.")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
        }
    }
}
