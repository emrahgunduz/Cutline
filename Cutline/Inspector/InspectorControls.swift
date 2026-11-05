import SwiftUI

/// A titled group of inspector controls, optionally with an on/off switch in its header.
struct InspectorSection<Content: View>: View {
    let title: String
    let icon: String
    var isOn: Binding<Bool>?
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: icon).foregroundStyle(.secondary).frame(width: 18)
                Text(title).font(.system(size: 13, weight: .semibold))
                Spacer()
                if let isOn { Toggle("", isOn: isOn).toggleStyle(.switch).controlSize(.mini).labelsHidden() }
            }
            if isOn?.wrappedValue ?? true {
                VStack(alignment: .leading, spacing: 6) { content() }
                    .padding(.leading, 26)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
    }
}

/// Slider plus an editable number field. Dragging updates live; the whole drag (or one
/// typed value) becomes a single undo step.
struct ValueRow: View {
    let label: String
    let value: Double
    let range: ClosedRange<Double>
    var step: Double? = nil
    var format: String = "%.2f"
    /// When set, a reset arrow appears while the value differs from it.
    var defaultValue: Double? = nil
    let onChange: (Double) -> Void
    let onCommit: () -> Void

    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Text(label).font(.system(size: 12)).frame(width: 76, alignment: .leading)
            Slider(value: Binding(get: { value }, set: { v in
                // Grabbing the slider ends typing in the field, so the field follows the slider.
                if focused { focused = false }
                onChange(quantized(v))
                text = String(format: format, quantized(v))
            }), in: range) { editing in
                if editing { focused = false } else { onCommit() }
            }
            .controlSize(.small)
            TextField("", text: $text)
                .font(.system(size: 11).monospacedDigit())
                .multilineTextAlignment(.trailing)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .frame(width: 58)
                .focused($focused)
                .onSubmit(commitText)
                .onChange(of: focused) { _, f in if !f { commitText() } }
            Button {
                if let d = defaultValue { onChange(d); onCommit() }
            } label: { Image(systemName: "arrow.counterclockwise").font(.system(size: 10)) }
            .buttonStyle(.borderless)
            .help("Reset \(label)")
            .opacity(isDefault ? 0 : 1)
            .disabled(isDefault)
        }
        .onAppear { text = String(format: format, value) }
        .onChange(of: value) { _, v in if !focused { text = String(format: format, v) } }
    }

    private var isDefault: Bool { defaultValue.map { abs($0 - value) < 1e-9 } ?? true }

    private func quantized(_ v: Double) -> Double {
        guard let step else { return v }
        return (v / step).rounded() * step
    }

    private func commitText() {
        // Accept "0,5", "12°", "0.50s" or "40%": keep digits, sign and decimal point.
        let cleaned = String(text.replacingOccurrences(of: ",", with: ".").filter { "0123456789.-".contains($0) })
        guard let v = Double(cleaned) else { text = String(format: format, value); return }
        onChange(min(max(v, range.lowerBound), range.upperBound))
        onCommit()
        text = String(format: format, min(max(v, range.lowerBound), range.upperBound))
    }
}

/// Arrow-key nudging in the preview, with the step ⇧ + arrows use (one app-wide setting).
struct NudgeSection: View {
    let what: String
    @AppStorage(NudgeStep.key) private var step = NudgeStep.defaultValue

    var body: some View {
        InspectorSection(title: "Nudge", icon: "arrow.up.and.down.and.arrow.left.and.right") {
            ValueRow(label: "⇧ step", value: step, range: 1...200, step: 1, format: "%.0f px", defaultValue: NudgeStep.defaultValue,
                     onChange: { step = $0.rounded() }, onCommit: {})
            Text("After clicking the preview or this inspector, ← → ↑ ↓ move \(what) 1 px; with ⇧ they move it by the step.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}
