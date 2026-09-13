//
//  SheetSyntax.swift
//  Sums
//

import Foundation

/// The syntax Sums adds on top of SoulverCore: line anchors and references,
/// finance function calls, tables and charts. Pure text functions; the engine
/// decides what they mean.
enum SheetSyntax {
    // MARK: Anchors and references

    /// ` ^rent` at the end of a line names that line.
    private static let anchorPattern = try! NSRegularExpression(pattern: #"\s\^([\p{L}\p{N}_-]+)\s*$"#)
    /// `@rent` anywhere refers to the answer of the line named `rent`.
    private static let referencePattern = try! NSRegularExpression(pattern: #"(?<![\p{L}\p{N}_@])@([\p{L}\p{N}_-]+)"#)

    /// The name a line is anchored with, and where the anchor (with its
    /// leading space) sits in the line.
    static func anchor(in line: String) -> (name: String, range: NSRange)? {
        let text = line as NSString
        guard let match = anchorPattern.firstMatch(in: line, range: NSRange(location: 0, length: text.length)) else { return nil }
        return (text.substring(with: match.range(at: 1)).lowercased(), match.range)
    }

    static func references(in line: String) -> [(name: String, range: NSRange)] {
        let text = line as NSString
        return referencePattern
            .matches(in: line, range: NSRange(location: 0, length: text.length))
            .map { (text.substring(with: $0.range(at: 1)).lowercased(), $0.range) }
    }

    /// A short, readable anchor for a line, unique among `existing`:
    /// `Rent: 8 500 kr` becomes `rent`, `Food 3 200 + 15%` becomes `food`.
    static func suggestedAnchor(for line: String, existing: Set<String>) -> String {
        let label = line.split(separator: ":", maxSplits: 1).count > 1
            ? String(line.split(separator: ":", maxSplits: 1)[0])
            : line
        let words = label
            .replacingOccurrences(of: #"^\s*(?:#+|[-*+]|\d+[.)])\s+(?:\[[ xX]\]\s+)?"#, with: "", options: .regularExpression)
            .lowercased()
            .components(separatedBy: CharacterSet.letters.inverted)
            .filter { !$0.isEmpty }
            .prefix(3)
        let base = words.isEmpty ? "line" : words.joined(separator: "-")
        var name = base
        var number = 2
        while existing.contains(name) {
            name = "\(base)-\(number)"
            number += 1
        }
        return name
    }

    // MARK: Finance functions

    static let financeFunctions: Set<String> = ["pmt", "fv", "pv", "npv", "irr"]

    struct FunctionCall: Equatable {
        let name: String
        /// The whole call, `pmt(…)`, in UTF-16 offsets within the line.
        let range: NSRange
        let arguments: [String]
    }

    /// Finance calls in a line, outermost first. Arguments are separated by
    /// `;`, and also by `,` when the number format does not use `,` for
    /// decimals.
    static func functionCalls(in line: String, commaSeparates: Bool) -> [FunctionCall] {
        let characters = Array(line.utf16)
        var calls: [FunctionCall] = []
        var index = 0
        while index < characters.count {
            guard let (name, open) = functionName(endingBefore: index, in: characters) else {
                index += 1
                continue
            }
            // Find the matching bracket, noting where arguments could split
            // at depth one. Semicolons win: when a call has them, its commas
            // belong to the numbers (1,000 or 1,5).
            var depth = 0
            var semicolons: [Int] = []
            var commas: [Int] = []
            var close: Int?
            var cursor = open
            while cursor < characters.count {
                let character = characters[cursor]
                if character == 0x28 {                         // (
                    depth += 1
                } else if character == 0x29 {                  // )
                    depth -= 1
                    if depth == 0 { close = cursor; break }
                } else if depth == 1, character == 0x3B {      // ;
                    semicolons.append(cursor)
                } else if depth == 1, character == 0x2C {      // ,
                    commas.append(cursor)
                }
                cursor += 1
            }
            guard let close else { break }
            let splits = !semicolons.isEmpty ? semicolons : (commaSeparates ? commas : [])
            var arguments: [String] = []
            var argumentStart = open + 1
            for split in splits {
                arguments.append(string(characters[argumentStart..<split]))
                argumentStart = split + 1
            }
            arguments.append(string(characters[argumentStart..<close]))
            let start = open - name.utf16.count
            calls.append(FunctionCall(
                name: name,
                range: NSRange(location: start, length: close + 1 - start),
                arguments: arguments.map { $0.trimmingCharacters(in: .whitespaces) }
            ))
            index = close + 1
        }
        return calls
    }

    /// When `characters[index]` is the `(` of a finance call, its name and
    /// the bracket's index.
    private static func functionName(endingBefore index: Int, in characters: [UInt16]) -> (String, Int)? {
        guard characters[index] == 0x28 else { return nil }
        var start = index
        while start > 0, let scalar = Unicode.Scalar(characters[start - 1]), CharacterSet.letters.contains(scalar) {
            start -= 1
        }
        guard start < index else { return nil }
        if start > 0, let before = Unicode.Scalar(characters[start - 1]),
           CharacterSet.alphanumerics.contains(before) || before == "_" {
            return nil
        }
        let name = string(characters[start..<index]).lowercased()
        return financeFunctions.contains(name) ? (name, index) : nil
    }

    private static func string(_ units: ArraySlice<UInt16>) -> String {
        String(decoding: units, as: UTF16.self)
    }

    // MARK: Tables

    static func isTableLine(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces).hasPrefix("|")
    }

    /// `|---|:--:|` under a table's header.
    static func isTableSeparator(_ line: String) -> Bool {
        line.range(of: #"^\s*\|?\s*:?-{2,}:?\s*(\|\s*:?-{2,}:?\s*)*\|?\s*$"#, options: .regularExpression) != nil
    }

    /// The cells of a table row, trimmed, without the outer pipes.
    static func cells(of line: String) -> [String] {
        var trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("|") { trimmed.removeFirst() }
        if trimmed.hasSuffix("|") { trimmed.removeLast() }
        return trimmed.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// Rows pasted from a spreadsheet, tab-separated, as a Markdown table,
    /// or `nil` when the text is not tabular.
    static func markdownTable(fromTabSeparated text: String) -> String? {
        let rows = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.components(separatedBy: "\t").map { $0.trimmingCharacters(in: .whitespaces) } }
        guard rows.count >= 2, rows.contains(where: { $0.count >= 2 }) else { return nil }
        let width = rows.map(\.count).max() ?? 0
        let padded = rows.map { $0 + Array(repeating: "", count: width - $0.count) }
        var lines = [row(padded[0]), row(Array(repeating: "---", count: width))]
        lines += padded.dropFirst().map(row)
        return lines.joined(separator: "\n")
    }

    static func row(_ cells: [String]) -> String {
        "| " + cells.joined(separator: " | ") + " |"
    }

    // MARK: Charts

    enum ChartKind: Equatable {
        case bars
        case line
    }

    /// `chart`, `bar chart`, `line chart`, `sparkline`, each optionally
    /// followed by `above`.
    static func chartKind(of line: String) -> ChartKind? {
        let words = line
            .trimmingCharacters(in: .whitespaces)
            .lowercased()
            .replacingOccurrences(of: #"\s+above$"#, with: "", options: .regularExpression)
        switch words {
        case "chart", "bar chart", "bars": return .bars
        case "line chart", "sparkline": return .line
        default: return nil
        }
    }
}
