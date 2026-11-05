import AppKit
import SwiftUI

/// The New Dummy sheet: title, font, length and color, with a live preview of the card. Every
/// choice is remembered for this project as it changes; Add puts the dummy in the assets.
enum NewDummySheet {
    @MainActor
    static func present(editor: EditorModel, window: NSWindow?) {
        guard let window, window.attachedSheet == nil else { return }
        let sheet = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        // Swift owns it; AppKit releasing it on close as well crashes the app.
        sheet.isReleasedWhenClosed = false
        let host = NSHostingController(rootView: NewDummyView(editor: editor) { add in
            window.endSheet(sheet)
            if let add { MainActor.assumeIsolated { _ = editor.createDummy(add.defaults, description: add.description) } }
        })
        host.sizingOptions = [.preferredContentSize]
        sheet.contentViewController = host
        window.beginSheet(sheet)
    }
}

struct NewDummyView: View {
    let editor: EditorModel
    let finish: ((defaults: DummyDefaults, description: String)?) -> Void
    @State private var d: DummyDefaults
    /// What the scene is: for this dummy only (not remembered).
    @State private var sceneDescription = ""
    private let autoName: String
    private static let families = NSFontManager.shared.availableFontFamilies
    private static let swatches: [RGBA] = [
        RGBA(r: 0.20, g: 0.24, b: 0.32, a: 1), RGBA(r: 0.12, g: 0.12, b: 0.13, a: 1), RGBA(r: 0.85, g: 0.30, b: 0.25, a: 1),
        RGBA(r: 0.95, g: 0.62, b: 0.20, a: 1), RGBA(r: 0.96, g: 0.85, b: 0.35, a: 1), RGBA(r: 0.30, g: 0.70, b: 0.45, a: 1),
        RGBA(r: 0.25, g: 0.55, b: 0.90, a: 1), RGBA(r: 0.55, g: 0.40, b: 0.85, a: 1), RGBA(r: 0.92, g: 0.92, b: 0.93, a: 1),
    ]

    init(editor: EditorModel, finish: @escaping ((defaults: DummyDefaults, description: String)?) -> Void) {
        self.editor = editor
        self.finish = finish
        _d = State(initialValue: editor.project.dummyDefaults ?? DummyDefaults())
        autoName = editor.project.nextDummyName
    }

    private var card: DummyCard {
        let t = d.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return DummyCard(title: t.isEmpty ? autoName : t, sceneDescription: sceneDescription.trimmingCharacters(in: .whitespacesAndNewlines),
                         fontName: d.fontName, length: max(0.1, d.length), color: d.color)
    }

    private var canvas: CGSize { editor.project.canvas.cgSize }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: "rectangle.dashed").font(.system(size: 30, weight: .medium)).foregroundStyle(.tint)
                    .frame(width: 44, height: 44)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.accentColor.opacity(0.15)))
                VStack(alignment: .leading, spacing: 2) {
                    Text("New Dummy").font(.title2.bold())
                    Text("A placeholder card for a shot you haven't made yet: title, what happens in it, and how long it lasts. It goes to the assets.")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }

            preview

            VStack(alignment: .leading, spacing: 12) {
                field("Title", alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 4) {
                        TextField(autoName, text: $d.title).textFieldStyle(.roundedBorder)
                        Text("If left empty, it will be named \(autoName).").font(.caption).foregroundStyle(.secondary)
                    }
                }
                // The text box draws its first line 5 pt below its top edge.
                field("Scene", alignment: .top, labelTop: 5) {
                    ZStack(alignment: .topLeading) {
                        TextEditor(text: $sceneDescription)
                            .font(.body).scrollContentBackground(.hidden)
                            .padding(.horizontal, 2).padding(.vertical, 4)
                            .frame(height: 68)
                        if sceneDescription.isEmpty {
                            Text("What happens in this shot (optional)").foregroundStyle(.tertiary)
                                .padding(.horizontal, 7).padding(.vertical, 5).allowsHitTesting(false)
                        }
                    }
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.15)))
                }
                field("Font") {
                    Picker("", selection: $d.fontName) {
                        if !Self.families.contains(d.fontName) { Text(d.fontName).tag(d.fontName) }
                        ForEach(Self.families, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden().frame(maxWidth: 260, alignment: .leading)
                }
                field("Length") {
                    HStack(spacing: 6) {
                        TextField("", value: $d.length, format: .number.precision(.fractionLength(0...2)))
                            .textFieldStyle(.roundedBorder).frame(width: 70).multilineTextAlignment(.trailing)
                        Stepper("", value: $d.length, in: 0.1...3600, step: 1).labelsHidden()
                        Text("seconds").foregroundStyle(.secondary)
                    }
                }
                field("Color") {
                    HStack(spacing: 6) {
                        ForEach(Self.swatches, id: \.self) { c in
                            Button { d.color = c } label: {
                                Circle().fill(Color(cgColor: c.cgColor)).frame(width: 20, height: 20)
                                    .overlay(Circle().strokeBorder(Color.primary.opacity(0.25)))
                                    .overlay(Circle().strokeBorder(Color.accentColor, lineWidth: 2).padding(-3).opacity(c == d.color ? 1 : 0))
                            }
                            .buttonStyle(.plain)
                        }
                        ColorPicker("", selection: Binding(get: { Color(cgColor: d.color.cgColor) }, set: { d.color = RGBA($0) }), supportsOpacity: false)
                            .labelsHidden()
                    }
                }
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.08)))

            HStack {
                Text(verbatim: "\(editor.project.canvas.width)×\(editor.project.canvas.height), the project's size").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { finish(nil) }.keyboardShortcut(.cancelAction).controlSize(.large)
                // ⌘↩ adds: plain Return makes new lines in the scene description.
                Button("Add to Assets") { finish((normalized, sceneDescription)) }
                    .keyboardShortcut(.return, modifiers: .command).buttonStyle(.borderedProminent).controlSize(.large)
                    .help("Add to Assets (⌘↩)")
            }
        }
        .padding(Self.sheetPadding)
        .frame(width: Self.sheetWidth)
        // Remembered for this project as soon as it changes (font, title, length, color).
        .onChange(of: d) { _, v in editor.rememberDummyDefaults(Self.normalize(v)) }
    }

    private var normalized: DummyDefaults { Self.normalize(d) }

    static func normalize(_ v: DummyDefaults) -> DummyDefaults {
        var n = v
        n.length = min(max(0.1, v.length), 3600)
        n.color.a = 1
        return n
    }

    /// The card at the sheet's full inner width (portrait projects: centred), exactly as wide
    /// as the form box under it.
    private var preview: some View {
        let aspect = canvas.width / max(1, canvas.height)
        let h: CGFloat = aspect >= 1 ? Self.contentWidth / aspect : 220
        let w = h * aspect
        return Group {
            if let img = DummyRenderer.image(card, size: CGSize(width: w * 2, height: h * 2)) {
                Image(decorative: img, scale: 2).resizable().aspectRatio(contentMode: .fit)
            } else {
                Color(cgColor: d.color.cgColor)
            }
        }
        .frame(width: w, height: h)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.15)))
        .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
        .frame(maxWidth: .infinity)
    }

    static let sheetWidth: CGFloat = 520
    static let sheetPadding: CGFloat = 24
    static var contentWidth: CGFloat { sheetWidth - sheetPadding * 2 }

    /// A labelled row. Single-line controls are centred on the label; a taller control
    /// (the scene text) lines its first line up with the label.
    private func field<C: View>(_ label: String, alignment: VerticalAlignment = .center, labelTop: CGFloat = 0,
                                @ViewBuilder content: () -> C) -> some View {
        HStack(alignment: alignment, spacing: 12) {
            Text(label).frame(width: 60, alignment: .leading).padding(.top, labelTop)
            content()
            Spacer(minLength: 0)
        }
    }
}

extension RGBA {
    /// From a SwiftUI color (sRGB).
    init(_ c: Color) {
        let ns = NSColor(c).usingColorSpace(.sRGB) ?? .gray
        self.init(r: Double(ns.redComponent), g: Double(ns.greenComponent), b: Double(ns.blueComponent), a: 1)
    }
}
