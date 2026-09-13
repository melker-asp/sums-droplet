//
//  SheetDocument.swift
//  Sums
//

import Foundation
import SoulverCore

/// The sheet that is open in the editor, with everything the engine derived
/// from it.
@MainActor
final class SheetDocument: ObservableObject {
    @Published private(set) var sheetID: UUID?
    @Published private(set) var text = ""
    @Published private(set) var results: [LineResult] = []
    @Published private(set) var tokens: [[SyntaxToken]] = []
    @Published private(set) var inputs: [SheetInput] = []
    @Published private(set) var outputs: [SheetOutput] = []
    @Published private(set) var hints: [Int: String] = [:]
    @Published private(set) var charts: [Int: ChartSpec] = [:]
    @Published private(set) var names: [String] = []
    @Published private(set) var stats: QuickStats?

    private let engine = SheetEngine()
    private var selectedLines = IndexSet()

    var lines: [String] { text.components(separatedBy: "\n") }

    func configure(_ settings: SumsSettings, currencyRates: (any CurrencyRateProvider)?, globals: [(name: String, value: String)]) {
        engine.configure(settings, currencyRates: currencyRates)
        engine.setGlobals(globals)
        if sheetID != nil { evaluate() }
    }

    func open(_ id: UUID, text: String) {
        sheetID = id
        selectedLines = []
        self.text = text
        evaluate()
    }

    func close() {
        sheetID = nil
        selectedLines = []
        stats = nil
    }

    /// Takes new text, from the editor or from an input field.
    func update(_ text: String) {
        guard text != self.text else { return }
        self.text = text
        evaluate()
    }

    func select(lines: IndexSet) {
        guard lines != selectedLines else { return }
        selectedLines = lines
        stats = engine.stats(for: lines)
    }

    private func evaluate() {
        engine.evaluate(text)
        results = engine.results
        tokens = engine.tokens
        inputs = engine.inputs
        outputs = engine.outputs
        hints = engine.hints
        charts = engine.charts
        names = engine.names
        stats = engine.stats(for: selectedLines)
    }
}
