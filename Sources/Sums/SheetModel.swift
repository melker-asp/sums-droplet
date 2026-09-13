//
//  SheetModel.swift
//  Sums
//

import Foundation
import SoulverCore

/// SoulverCore's answer for one line of a sheet.
struct LineResult: Equatable {
    /// What the answer column shows, formatted for the user's locale.
    let formatted: String
    /// What a copy puts on the pasteboard: no grouping, so it pastes cleanly
    /// into a spreadsheet.
    let raw: String

    var isEmpty: Bool { formatted.isEmpty }
}

/// One sheet: its text, and an answer for every line.
@MainActor
final class SheetModel: ObservableObject {
    static let sample = """
    # Budget
    Rent: 8 500
    Food 3 200 + 15%
    Transport 970
    total

    Invoice 1 000 + 25%
    """

    @Published private(set) var text = ""
    @Published private(set) var results: [LineResult] = []

    private let customization: EngineCustomization = .soulver

    /// Re-evaluates the whole sheet. Sheets are short, so this stays well
    /// under a frame; incremental evaluation comes with the real editor.
    func update(text: String) {
        self.text = text
        let lines = LineCollection(multiLineText: MarkdownMask.calculable(text), customization: customization)
        lines.evaluateAll()
        results = (0..<lines.lineCount).map { index in
            LineResult(
                formatted: lines.lines[index].formattedResult,
                raw: lines.unformattedResultFor(lineIndex: index)
            )
        }
    }

    /// The bottom-most answer, which the compact card shows.
    var lastResult: LineResult? {
        results.last { !$0.isEmpty }
    }

    /// The line that produced ``lastResult``.
    var lastExpression: String? {
        guard let index = results.lastIndex(where: { !$0.isEmpty }) else { return nil }
        let lines = text.components(separatedBy: "\n")
        return lines.indices.contains(index) ? lines[index] : nil
    }
}
