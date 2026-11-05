import AppKit
import SwiftUI

/// The single project-wide lyric style: font, size, color and drop shadow.
struct LyricStyleView: View {
    @EnvironmentObject var editor: EditorModel
    private static let families = NSFontManager.shared.availableFontFamilies

    var body: some View {
        let style = editor.project.lyricStyle
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if let text = selectedText { Text(text).font(.headline).lineLimit(3) }
                InspectorSection(title: "Text", icon: "textformat") {
                    Picker("Font", selection: binding(\.fontName, "Font")) {
                        ForEach(fontChoices(current: style.fontName), id: \.self) { Text($0).tag($0) }
                    }
                    .controlSize(.small)
                    row("Size", style.sizeFraction * 100, 2...20, format: "%.1f%%", reset: LyricStyle().sizeFraction * 100) { $0.sizeFraction = $1 / 100 }
                    ColorPicker("Color", selection: color(\.color, "Lyric Color")).font(.system(size: 12))
                    row("Position", style.verticalPosition * 100, 5...95, format: "%.0f%%", reset: LyricStyle().verticalPosition * 100) { $0.verticalPosition = $1 / 100 }
                }
                InspectorSection(title: "Drop Shadow", icon: "shadow", isOn: binding(\.shadowEnabled, "Drop Shadow")) {
                    row("Blur", style.shadowBlur, 0...40, format: "%.1f", reset: LyricStyle().shadowBlur) { $0.shadowBlur = $1 }
                    row("Strength", style.shadowStrength * 100, 0...400, format: "%.0f%%", reset: 100) { $0.shadowStrength = $1 / 100 }
                    row("Distance X", style.shadowDX, -50...50, format: "%.0f", reset: LyricStyle().shadowDX) { $0.shadowDX = $1 }
                    row("Distance Y", style.shadowDY, -50...50, format: "%.0f", reset: LyricStyle().shadowDY) { $0.shadowDY = $1 }
                    ColorPicker("Color", selection: color(\.shadowColor, "Shadow Color")).font(.system(size: 12))
                }
            }
            .padding(12)
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

    private func row(_ label: String, _ value: Double, _ range: ClosedRange<Double>, format: String, reset: Double? = nil,
                     set: @escaping (inout LyricStyle, Double) -> Void) -> some View {
        ValueRow(label: label, value: value, range: range, format: format, defaultValue: reset,
                 onChange: { v in editor.liveEdit { set(&$0.lyricStyle, v) } },
                 onCommit: { editor.endLiveEdit(label) })
    }
}
