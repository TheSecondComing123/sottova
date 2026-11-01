import SwiftUI
import SottovaCore

/// − value + in one bordered strip, for whole numbers.
struct ValueStepper: View {
    var label: String?
    @Binding var value: Double
    let range: ClosedRange<Double>
    let unit: String
    var step: Double = 1

    var body: some View {
        HStack(spacing: 0) {
            if let label {
                Text(label)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.muted)
                    .padding(.leading, 12)
                    .padding(.trailing, 8)
            }
            step(.minus, by: -step)
            Text("\(Int(value)) \(unit)")
                .font(.system(size: 13, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(Theme.text)
                .frame(minWidth: 64)
                .contentTransition(.numericText(value: value))
            step(.plus, by: step)
        }
        .frame(height: 32)
        .background(Theme.raised, in: .rect(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border))
        .accessibilityRepresentation {
            Stepper("\(label ?? "") \(Int(value)) \(unit)", value: $value, in: range, step: step)
        }
    }

    private func step(_ icon: Ph, by delta: Double) -> some View {
        Button {
            withAnimation(Theme.quick) { value = min(max(value + delta, range.lowerBound), range.upperBound) }
        } label: {
            icon.icon(.bold, size: 12)
                .foregroundStyle(Theme.muted)
                .frame(width: 32, height: 32)
                .hoverable(radius: 8)
        }
        .buttonRepeatBehavior(.enabled)
        .buttonStyle(PressStyle())
        .disabled(delta < 0 ? value <= range.lowerBound : value >= range.upperBound)
    }
}

/// The switch itself, square like the rest of the app, without a card around it.
struct SwitchKnob: View {
    let on: Bool

    var body: some View {
        // the new look's checkbox, for what's left on this name until the switch
        ZStack {
            if on {
                RoundedRectangle(cornerRadius: 3.5).fill(Theme.muted)
                Ph.check.icon(.bold, size: 10).foregroundStyle(Theme.background)
            } else {
                RoundedRectangle(cornerRadius: 3.5).strokeBorder(Theme.frame, lineWidth: 1)
            }
        }
        .frame(width: 14, height: 14)
    }
}

/// A preset to make, or the one it changes.
struct PresetEdit: Identifiable {
    let id = UUID()
    var preset: SottovaCore.Settings
    var replacing: String?
    /// Silence for one collection rather than a preset: its name, and where it goes.
    var collection: (name: String, apply: (SottovaCore.Settings) -> Void)?
}
