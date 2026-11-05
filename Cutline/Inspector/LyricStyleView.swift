import AppKit
import SwiftUI

/// The single project-wide lyric style: font, size, color and drop shadow.
struct LyricStyleView: View {
    @EnvironmentObject var editor: EditorModel
    @AppStorage("lyricAlignPadding") private var padding = 60.0
    @AppStorage("lyricLineGap") private var gap = 0.0
    private static let families = NSFontManager.shared.availableFontFamilies

    var body: some View {
        let style = editor.project.lyricStyle
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if let text = selectedText { Text(text).font(.headline).lineLimit(3) }
                placement
                InspectorSection(title: "Text", icon: "textformat") {
                    Picker("Font", selection: binding(\.fontName, "Font")) {
                        ForEach(fontChoices(current: style.fontName), id: \.self) { Text($0).tag($0) }
                    }
                    .controlSize(.small)
                    row("Size", style.sizeFraction * 100, 2...20, format: "%.1f%%", reset: LyricStyle().sizeFraction * 100) { $0.sizeFraction = $1 / 100 }
                    ColorPicker("Color", selection: color(\.color, "Lyric Color")).font(.system(size: 12))
                    row("Position", style.verticalPosition * 100, 5...95, format: "%.0f%%", reset: LyricStyle().verticalPosition * 100) { $0.verticalPosition = $1 / 100 }
                }
                InspectorSection(title: "Animation", icon: "sparkles") {
                    Picker("", selection: Binding(get: { style.letterByLetter }, set: { v in update("Animation Mode") { $0.letterByLetter = v } })) {
                        Text("Whole word").tag(false)
                        Text("Letter by letter").tag(true)
                    }
                    .pickerStyle(.segmented).labelsHidden().controlSize(.small)
                    let d = LyricAnimation.defaultFade(fps: editor.project.fps)
                    row("Fade in", style.fadeInValue ?? d, 0...2, format: "%.2fs", reset: d) { $0.fadeInValue = $1 }
                    row("Fade out", style.fadeOutValue ?? d, 0...2, format: "%.2fs", reset: d) { $0.fadeOutValue = $1 }
                    if style.letterByLetter {
                        row("Overlap", style.letterOverlap * 100, 0...100, format: "%.0f%%", reset: 50) { $0.letterOverlap = $1 / 100 }
                    }
                    ValueRow(label: "Lead-in", value: style.leadIn, range: 0...0.5, step: 0.01, format: "%.2fs", defaultValue: 0.15,
                             onChange: { v in editor.liveEdit { $0.lyricStyle.leadIn = v; $0.applyLeadIn() } },
                             onCommit: { editor.endLiveEdit("Lyric Lead-in") })
                        .help("Aligned words appear this much before they are sung. Confirmed and hand-placed words don't move.")
                    Text(style.letterByLetter ? "Letters fade one after another and the whole word still appears within the fade time. Overlap: how much each letter overlaps the next." : "The same fades apply to every word.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
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

    @ViewBuilder private var placement: some View {
        let ids = editor.placementLineIDs
        if !ids.isEmpty {
            InspectorSection(title: ids.count > 1 ? "Placement · \(ids.count) lines" : "Placement", icon: "rectangle.dashed") {
                HStack(spacing: 4) {
                    alignButton("align.horizontal.left", "Align left") { editor.alignLines(horizontal: .left, vertical: nil, padding: padding, gap: gap) }
                    alignButton("align.horizontal.center", "Center horizontally") { editor.alignLines(horizontal: .center, vertical: nil, padding: padding, gap: gap) }
                    alignButton("align.horizontal.right", "Align right") { editor.alignLines(horizontal: .right, vertical: nil, padding: padding, gap: gap) }
                    Divider().frame(height: 18)
                    alignButton("align.vertical.top", ids.count > 1 ? "Stack at top" : "Align top") { editor.alignLines(horizontal: nil, vertical: .top, padding: padding, gap: gap) }
                    alignButton("align.vertical.center", ids.count > 1 ? "Stack in the middle" : "Center vertically") { editor.alignLines(horizontal: nil, vertical: .center, padding: padding, gap: gap) }
                    alignButton("align.vertical.bottom", ids.count > 1 ? "Stack at bottom" : "Align bottom") { editor.alignLines(horizontal: nil, vertical: .bottom, padding: padding, gap: gap) }
                }
                ValueRow(label: "Padding", value: padding, range: 0...400, step: 1, format: "%.0f px", defaultValue: 60,
                         onChange: { padding = $0 }, onCommit: {})
                if ids.count > 1 {
                    ValueRow(label: "Line gap", value: gap, range: -20...200, step: 1, format: "%.0f px", defaultValue: 0,
                             onChange: { gap = $0 }, onCommit: {})
                }
                HStack {
                    Text(ids.count > 1 ? "Selected lines stack under each other." : "Drag the line in the preview to move it.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Auto Position") { editor.resetLinePositions() }
                        .controlSize(.small)
                        .disabled(!ids.contains { editor.line($0)?.hasPosition == true })
                }
            }
        }
    }

    private func alignButton(_ symbol: String, _ tip: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).frame(width: 22, height: 18) }
            .buttonStyle(.bordered).controlSize(.small).help(tip)
    }

    private var selectedText: String? {
        switch editor.selection {
        case .lyricLine(let id): editor.selectedLineIDs.count > 1 ? "\(editor.selectedLineIDs.count) lines selected" : editor.line(id)?.text
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
