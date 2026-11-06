import AppKit
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
    /// Values the text field accepts, when wider than the slider's range (nil = the range).
    var typedRange: ClosedRange<Double>? = nil
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
            }), in: range.lowerBound...max(range.upperBound, value)) { editing in
                if editing { focused = false } else { onCommit() }
            }
            .controlSize(.small)
            // The scroll wheel over the slider moves it one step a click (see ScrollWheelSteps).
            .background(ScrollWheelSteps(onStep: { direction in
                if focused { focused = false }
                let v = Self.stepped(value, direction: direction, step: wheelStep, range: range)
                onChange(v)
                text = String(format: format, v)
            }, onEnd: onCommit))
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

    /// One wheel click: the row's step, else the smallest change its field shows (1 for
    /// "%.0f px", 0.1 for "%.1f%%", 0.01 for "%.2fs").
    private var wheelStep: Double { step ?? Self.displayStep(format) }

    static func displayStep(_ format: String) -> Double {
        guard let r = format.range(of: #"%\.(\d)f"#, options: .regularExpression),
              let digits = Int(format[r].dropFirst(2).dropLast()) else { return 1 }
        return pow(10, -Double(digits))
    }

    /// `value` moved one `step` up or down, on the step's grid and inside `range`.
    static func stepped(_ value: Double, direction: Int, step: Double, range: ClosedRange<Double>) -> Double {
        let v = ((value / step).rounded() + Double(direction.signum())) * step
        return min(max(v, range.lowerBound), range.upperBound)
    }

    private func quantized(_ v: Double) -> Double {
        guard let step else { return v }
        return (v / step).rounded() * step
    }

    private func commitText() {
        // Accept "0,5", "12°", "0.50s" or "40%": keep digits, sign and decimal point.
        let cleaned = String(text.replacingOccurrences(of: ",", with: ".").filter { "0123456789.-".contains($0) })
        guard let v = Double(cleaned) else { text = String(format: format, value); return }
        let limits = typedRange ?? range
        let clamped = min(max(v, limits.lowerBound), limits.upperBound)
        onChange(clamped)
        onCommit()
        text = String(format: format, clamped)
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

/// Scroll wheel steps over a control: each mouse wheel click is one step up (wheel up) or down,
/// whatever the scroll speed; a trackpad swipe steps once per 12 points it travels (momentum
/// is ignored). The control keeps its clicks and drags: this view only watches scroll events
/// over its own area. `onEnd` runs once the scrolling stops (one undo step).
struct ScrollWheelSteps: NSViewRepresentable {
    let onStep: (Int) -> Void
    let onEnd: () -> Void

    func makeNSView(context: Context) -> WheelView { WheelView() }

    func updateNSView(_ view: WheelView, context: Context) {
        view.onStep = onStep
        view.onEnd = onEnd
    }

    final class WheelView: NSView {
        var onStep: ((Int) -> Void)?
        var onEnd: (() -> Void)?
        private var monitor: Any?
        private var travel: CGFloat = 0
        private var endWork: DispatchWorkItem?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }   // clicks go to the control

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, event.window === self.window, !self.isHiddenOrHasHiddenAncestor,
                      self.bounds.contains(self.convert(event.locationInWindow, from: nil)) else { return event }
                self.handle(event)
                return nil
            }
        }

        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }

        /// Wheel up (or a swipe up) is +1, with natural scrolling too.
        func handle(_ event: NSEvent) {
            guard event.momentumPhase.isEmpty else { return }
            let dy = event.isDirectionInvertedFromDevice ? -event.scrollingDeltaY : event.scrollingDeltaY
            guard dy != 0 else { return }
            if event.hasPreciseScrollingDeltas {
                travel += dy
                while abs(travel) >= 12 {
                    onStep?(travel > 0 ? 1 : -1)
                    travel -= travel > 0 ? 12 : -12
                }
            } else {
                onStep?(dy > 0 ? 1 : -1)
            }
            endWork?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.travel = 0; self?.onEnd?() }
            endWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
        }
    }
}

