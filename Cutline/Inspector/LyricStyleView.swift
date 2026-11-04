import AppKit
import SwiftUI

/// The single project-wide lyric style: font, size, color and drop shadow.
struct LyricStyleView: View {
    @EnvironmentObject var editor: EditorModel
    private static let families = NSFontManager.shared.availableFontFamilies

    var body: some View {
        let style = editor.project.lyricStyle
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let text = selectedText { Text(text).font(.headline).lineLimit(3) }
                Text("Lyric Style").font(.subheadline.bold())
                Picker("Font", selection: binding(\.fontName, "Font")) {
                    ForEach(fontChoices(current: style.fontName), id: \.self) { Text($0).tag($0) }
                }
                slider("Size", style.sizeFraction * 100, 2...20, "%.1f%%") { $0.sizeFraction = $1 / 100 }
                ColorPicker("Color", selection: color(\.color, "Lyric Color"))
                slider("Position", style.verticalPosition * 100, 5...95, "%.0f%%") { $0.verticalPosition = $1 / 100 }
                Divider()
                Toggle("Drop Shadow", isOn: binding(\.shadowEnabled, "Drop Shadow")).toggleStyle(.switch).font(.subheadline.bold())
                if style.shadowEnabled {
                    slider("Blur", style.shadowBlur, 0...40, "%.1f") { $0.shadowBlur = $1 }
                    slider("Distance X", style.shadowDX, -50...50, "%.0f") { $0.shadowDX = $1 }
                    slider("Distance Y", style.shadowDY, -50...50, "%.0f") { $0.shadowDY = $1 }
                    ColorPicker("Shadow Color", selection: color(\.shadowColor, "Shadow Color"))
                }
            }
            .padding(14)
        }
    }

    private var selectedText: String? {
        switch editor.selection {
        case .lyricLine(let id): editor.line(id)?.text
        case .lyricWord(let id): editor.word(id)?.text
        default: nil
        }
    }

    /// Bold/regular faces of installed families, plus the current font.
    private func fontChoices(current: String) -> [String] {
        var names = Self.families.flatMap { fam in
            (NSFontManager.shared.availableMembers(ofFontFamily: fam) ?? []).compactMap { $0.first as? String }
        }
        if !names.contains(current) { names.insert(current, at: 0) }
        return names
    }

    private func update(_ name: String, _ change: @escaping (inout LyricStyle) -> Void) {
        editor.edit(name) { change(&$0.lyricStyle) }
    }

    private func binding<T: Equatable>(_ kp: WritableKeyPath<LyricStyle, T>, _ name: String) -> Binding<T> {
        Binding(get: { editor.project.lyricStyle[keyPath: kp] }, set: { v in update(name) { $0[keyPath: kp] = v } })
    }

    private func color(_ kp: WritableKeyPath<LyricStyle, RGBA>, _ name: String) -> Binding<Color> {
        Binding(get: {
            let c = editor.project.lyricStyle[keyPath: kp]
            return Color(.sRGB, red: c.r, green: c.g, blue: c.b, opacity: c.a)
        }, set: { new in
            guard let ns = NSColor(new).usingColorSpace(.sRGB) else { return }
            update(name) { $0[keyPath: kp] = RGBA(r: ns.redComponent, g: ns.greenComponent, b: ns.blueComponent, a: ns.alphaComponent) }
        })
    }

    private func slider(_ label: String, _ value: Double, _ range: ClosedRange<Double>, _ fmt: String,
                        set: @escaping (inout LyricStyle, Double) -> Void) -> some View {
        HStack {
            Text(label).frame(width: 84, alignment: .leading)
            Slider(value: Binding(get: { value }, set: { v in update(label) { set(&$0, v) } }), in: range)
            Text(String(format: fmt, value)).font(.caption.monospacedDigit()).frame(width: 52, alignment: .trailing)
        }
    }
}
