//
//  QuickCalc.swift
//  Sums
//

import DroppyKit
import SoulverCore
import SwiftUI

/// The one-line calculator a shortcut opens in the notch.
@MainActor
final class QuickCalc: ObservableObject {
    static let historyLimit = 30

    @Published var input = "" {
        didSet { if input != oldValue { evaluate() } }
    }
    @Published private(set) var result: LineResult?
    @Published private(set) var hint: String?
    /// Earlier calculations, newest first.
    private(set) var history: [String] = []
    private var historyIndex: Int?
    private let engine = SheetEngine()

    func configure(_ settings: SumsSettings, currencyRates: (any CurrencyRateProvider)?, globals: [(name: String, value: String)]) {
        engine.configure(settings, currencyRates: currencyRates)
        engine.setGlobals(globals)
        evaluate()
    }

    func restore(history: [String]) {
        self.history = Array(history.prefix(Self.historyLimit))
    }

    func reset() {
        historyIndex = nil
        input = ""
    }

    /// Records the current calculation at the top of the history.
    func remember() {
        let calculation = input.trimmingCharacters(in: .whitespaces)
        guard !calculation.isEmpty else { return }
        history.removeAll { $0 == calculation }
        history.insert(calculation, at: 0)
        history = Array(history.prefix(Self.historyLimit))
        historyIndex = nil
    }

    /// ↑: one calculation further back.
    func previous() {
        let next = (historyIndex ?? -1) + 1
        guard next < history.count else { return }
        historyIndex = next
        input = history[next]
    }

    /// ↓: one calculation forward, and back to an empty line after the newest.
    func next() {
        guard let index = historyIndex else { return }
        if index == 0 {
            historyIndex = nil
            input = ""
        } else {
            historyIndex = index - 1
            input = history[index - 1]
        }
    }

    private func evaluate() {
        let calculation = input.trimmingCharacters(in: .whitespaces)
        guard !calculation.isEmpty else {
            result = nil
            hint = nil
            return
        }
        engine.evaluate(calculation)
        let first = engine.results.first
        result = (first?.isEmpty ?? true) ? nil : first
        hint = result == nil ? engine.hints[0] : nil
    }
}

/// Quick calc's surface: a field, the answer rolling in beside it, and the
/// keys that act on it.
struct QuickCalcView: View {
    @ObservedObject var model: QuickCalc
    let isPreview: Bool
    let onCopy: @MainActor () -> Void
    let onAddToSheet: @MainActor () -> Void
    let onClose: @MainActor () -> Void

    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: DroppySpacing.xsm) {
            HStack(spacing: DroppySpacing.sm) {
                Image(systemName: "sum")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                TextField("Calculate anything", text: $model.input)
                    .textFieldStyle(.plain)
                    .font(.system(size: 17))
                    .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
                    .focused($focused)
                    .onSubmit { onCopy() }
                    .onKeyPress(.tab) {
                        onAddToSheet()
                        return .handled
                    }
                    .onKeyPress(.upArrow) {
                        model.previous()
                        return .handled
                    }
                    .onKeyPress(.downArrow) {
                        model.next()
                        return .handled
                    }
                    .onKeyPress(.escape) {
                        onClose()
                        return .handled
                    }
                Text(verbatim: model.result?.formatted ?? (model.hint == nil ? "" : "?"))
                    .font(.system(size: 17, weight: .semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .foregroundStyle(model.result == nil ? AdaptiveColors.notchSurfaceTertiaryText : AdaptiveColors.notchSurfacePrimaryText)
                    .contentTransition(.numericText())
                    .animation(.snappy(duration: 0.25), value: model.result?.formatted)
            }
            HStack(spacing: DroppySpacing.md) {
                if let hint = model.hint {
                    Text(hint)
                } else {
                    keycap("⏎", "Copy")
                    keycap("⇥", "Add to sheet")
                    keycap("↑", "Earlier")
                    keycap("esc", "Close")
                }
                Spacer(minLength: 0)
            }
            .font(.system(size: 10.5))
            .foregroundStyle(AdaptiveColors.notchSurfaceTertiaryText)
            .lineLimit(1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            if !isPreview { focused = true }
        }
    }

    private func keycap(_ key: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(key)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(
                    RoundedRectangle(cornerRadius: DroppyRadius.xs, style: .continuous)
                        .fill(AdaptiveColors.notchSurfaceCardFill)
                )
            Text(label)
        }
    }
}
