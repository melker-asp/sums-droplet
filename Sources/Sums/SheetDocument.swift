//
//  SheetDocument.swift
//  Sums
//

import Foundation

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
    @Published private(set) var stats: QuickStats?

    private let engine = SheetEngine()
    private var selectedLines = IndexSet()

    var lines: [String] { text.components(separatedBy: "\n") }

    func configure(_ settings: SumsSettings) {
        engine.configure(settings)
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
        stats = engine.stats(for: selectedLines)
    }
}
