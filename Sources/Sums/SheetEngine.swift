//
//  SheetEngine.swift
//  Sums
//

import Foundation
import SoulverCore

/// SoulverCore's answer for one line of a sheet.
struct LineResult: Equatable {
    /// What the answer column shows, formatted for the chosen number format.
    let formatted: String
    /// What a copy puts on the pasteboard: no grouping, so it pastes cleanly
    /// into a spreadsheet.
    let raw: String

    var isEmpty: Bool { formatted.isEmpty }
}

/// A variable with a plain value, which the inputs view turns into a field.
struct SheetInput: Identifiable, Equatable {
    let lineIndex: Int
    let name: String
    let value: String
    /// Where `value` sits in its line, in UTF-16 offsets.
    let valueRange: NSRange

    var id: Int { lineIndex }
}

/// A line whose answer the inputs view lists under the fields.
struct SheetOutput: Identifiable, Equatable {
    let lineIndex: Int
    let label: String
    let value: String

    var id: Int { lineIndex }
}

/// Statistics over the lines the user selected.
struct QuickStats: Equatable {
    let count: Int
    let total: String
    let average: String
    let median: String
    let standardDeviation: String
}

/// A line that asks for a statistic of the lines above it: `total`,
/// `expenses = sum`, `Spread: std dev`.
///
/// SoulverCore has the statistics but no words for "the lines above", so Sums
/// supplies them: an aggregate covers the lines above it back to a blank
/// line or a heading.
struct Aggregate {
    let statistic: StatisticType
    /// What stays in front of the value, such as `expenses = `.
    let prefix: String
    /// Where the keyword sits in its line, in UTF-16 offsets.
    let keywordRange: NSRange

    private static let words: [String: StatisticType] = [
        "total": .total, "sum": .total, "subtotal": .total, "summa": .total,
        "average": .average, "avg": .average, "mean": .average, "medel": .average, "medelvärde": .average,
        "median": .median,
        "std dev": .standardDeviation, "stdev": .standardDeviation, "stddev": .standardDeviation,
        "standard deviation": .standardDeviation, "sd": .standardDeviation,
        "count": .count, "antal": .count,
        "min": .lesser, "minimum": .lesser, "lowest": .lesser,
        "max": .greater, "maximum": .greater, "highest": .greater
    ]

    private static let pattern = try! NSRegularExpression(
        pattern: #"^(\s*(?:[^=:]+?\s*=|[^=:]+?:)\s*)?\s*(\p{L}[\p{L} ]*?)\s*$"#
    )

    init?(line: String) {
        let text = line as NSString
        guard let match = Self.pattern.firstMatch(in: line, range: NSRange(location: 0, length: text.length)),
              let statistic = Self.words[text.substring(with: match.range(at: 2)).lowercased()]
        else { return nil }
        self.statistic = statistic
        self.prefix = match.range(at: 1).location == NSNotFound ? "" : text.substring(with: match.range(at: 1))
        self.keywordRange = match.range(at: 2)
    }
}

/// Evaluates a sheet with SoulverCore and adds what Sums layers on top:
/// totals and statistics of the lines above, `prev`, syntax colours, and
/// the inputs and outputs the inputs view shows.
@MainActor
final class SheetEngine {
    private(set) var results: [LineResult] = []
    private(set) var tokens: [[SyntaxToken]] = []
    private(set) var inputs: [SheetInput] = []
    private(set) var outputs: [SheetOutput] = []

    private var collection: LineCollection?
    private var aggregateLines = Set<Int>()
    private var customization: EngineCustomization = .soulver
    private var formatting = FormattingPreferences()
    private var decimalSeparator = ","

    private static let prevPattern = try! NSRegularExpression(pattern: #"(?i)\b(prev|ans)\b"#)
    /// An amount with an optional currency or unit: `1 250,00 kr`, `€91,28`,
    /// `25 %`. Anything else (`8 hours 25 min`, a date) copies as shown.
    private static let amountPattern = try! NSRegularExpression(
        pattern: #"^\s*([^\d\s−-]{0,3})\s*([−-]?\d[\d\s  .,']*)\s*(\p{L}{1,4}|%)?\s*$"#
    )

    init(settings: SumsSettings = SumsSettings()) {
        configure(settings)
    }

    func configure(_ settings: SumsSettings) {
        customization = EngineCustomization.soulver.convertTo(locale: settings.numberFormat.locale)
        decimalSeparator = settings.numberFormat.decimalSeparator
        var preferences = FormattingPreferences()
        preferences.dp = settings.decimals
        // Money reads in full: 2 000 000 kr, never 2M kr.
        preferences.notationPreferences = .off
        preferences.currencyFormattingPreferences.showTrailingZeros = false
        formatting = preferences
    }

    func evaluate(_ text: String) {
        let lines = text.components(separatedBy: "\n")
        let masked = MarkdownMask.calculable(text).components(separatedBy: "\n")

        var aggregates: [Int: Aggregate] = [:]
        var usesPrev = Set<Int>()
        var expressions = masked
        for (index, line) in masked.enumerated() {
            if let aggregate = Aggregate(line: line) {
                aggregates[index] = aggregate
                expressions[index] = ""
            } else if Self.prevPattern.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) != nil {
                usesPrev.insert(index)
            }
        }

        let collection = LineCollection(multiLineText: expressions.joined(separator: "\n"), customization: customization)
        collection.setFormatting(formattingPreferences: formatting)
        collection.evaluateAll()

        // Aggregates and `prev` need the answers above them, so they are
        // filled in after a first pass, and everything is evaluated again so
        // variables built on them follow. A second round lets a total of
        // lines that themselves use `prev` settle.
        if !aggregates.isEmpty || !usesPrev.isEmpty {
            let aggregateIndexes = Set(aggregates.keys)
            for _ in 0..<2 {
                for index in 0..<collection.lineCount where aggregates[index] != nil || usesPrev.contains(index) {
                    let expression: String
                    if let aggregate = aggregates[index] {
                        let section = Self.section(above: index, lines: lines, collection: collection, excluding: aggregateIndexes)
                        let value = section.isEmpty
                            ? nil
                            : collection.calculateQuickStatistic(statisticType: aggregate.statistic, limitToIndexes: section)?.stringValue
                        expression = value.map { aggregate.prefix + "(" + $0 + ")" } ?? ""
                    } else {
                        expression = Self.substitutingPrev(in: masked[index], before: index, collection: collection)
                    }
                    collection.setExpression(expression: expression, forLineAt: index)
                    _ = collection.evaluateLinesAt(indexes: IndexSet(integer: index))
                }
                collection.evaluateAll()
            }
        }

        self.collection = collection
        aggregateLines = Set(aggregates.keys)
        let count = min(collection.lineCount, lines.count)
        results = (0..<count).map { index in
            let formatted = collection.lines[index].formattedResult
            return LineResult(formatted: formatted, raw: plainNumber(formatted))
        }
        tokens = (0..<count).map { index in
            if let aggregate = aggregates[index] {
                return [SyntaxToken(range: aggregate.keywordRange, kind: .keyword)]
            }
            if usesPrev.contains(index) {
                let line = lines[index]
                return Self.prevPattern
                    .matches(in: line, range: NSRange(location: 0, length: (line as NSString).length))
                    .map { SyntaxToken(range: $0.range, kind: .keyword) }
            }
            return Self.syntaxTokens(for: collection.lines[index])
        }
        collectInputsAndOutputs(lines: lines, collection: collection, aggregates: aggregates)
    }

    /// Sum, average, median and standard deviation of the chosen lines, or
    /// `nil` when fewer than two of them have an answer.
    func stats(for lineIndexes: IndexSet) -> QuickStats? {
        guard let collection else { return nil }
        let valid = IndexSet(lineIndexes.filter { $0 < results.count && !results[$0].isEmpty && !aggregateLines.contains($0) })
        guard valid.count >= 2 else { return nil }
        func statistic(_ type: StatisticType) -> String {
            guard let value = collection.calculateQuickStatistic(
                statisticType: type,
                limitToIndexes: valid,
                ignoreVariableDeclaration: false
            )?.stringValue else { return "–" }
            return reformat(value)
        }
        return QuickStats(
            count: valid.count,
            total: statistic(.total),
            average: statistic(.average),
            median: statistic(.median),
            standardDeviation: statistic(.standardDeviation)
        )
    }

    /// The bottom-most answer, which the list and the compact card show.
    var summary: LineResult? {
        results.last { !$0.isEmpty }
    }

    // MARK: Helpers

    /// What a copy puts on the pasteboard: the number alone, without
    /// grouping or currency, in the sheet's decimal format, so it pastes into
    /// a spreadsheet as a number. `1 250,00 kr` becomes `1250`, `25 %` stays
    /// a percentage.
    func plainNumber(_ formatted: String) -> String {
        let text = formatted as NSString
        guard let match = Self.amountPattern.firstMatch(in: formatted, range: NSRange(location: 0, length: text.length)) else {
            return formatted
        }
        let grouping: Character = decimalSeparator == "," ? "." : ","
        let decimal = Character(decimalSeparator)
        var number = String(text.substring(with: match.range(at: 2)).compactMap { character -> Character? in
            if character.isNumber || character == decimal { return character }
            if character == "−" || character == "-" { return "-" }
            if character == grouping || character.isWhitespace || character == "'" { return nil }
            return nil
        })
        if number.contains(decimal) {
            while number.last == "0" { number.removeLast() }
            if number.last == decimal { number.removeLast() }
        }
        let unit = match.range(at: 3).location == NSNotFound ? "" : text.substring(with: match.range(at: 3))
        return unit == "%" ? number + "%" : number
    }

    /// Quick statistics come back unrounded; run them through the sheet's
    /// formatting so they match the answer column.
    private func reformat(_ value: String) -> String {
        let single = LineCollection(multiLineText: value, customization: customization)
        single.setFormatting(formattingPreferences: formatting)
        single.evaluateAll()
        let formatted = single.lines.first?.formattedResult ?? ""
        return formatted.isEmpty ? value : formatted
    }

    private static func section(above index: Int, lines: [String], collection: LineCollection, excluding aggregates: Set<Int>) -> IndexSet {
        var section = IndexSet()
        var cursor = index - 1
        while cursor >= 0, cursor < lines.count {
            let trimmed = lines[cursor].trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { break }
            if !aggregates.contains(cursor), cursor < collection.lineCount, !collection.lines[cursor].formattedResult.isEmpty {
                section.insert(cursor)
            }
            cursor -= 1
        }
        return section
    }

    private static func substitutingPrev(in expression: String, before index: Int, collection: LineCollection) -> String {
        var cursor = index - 1
        while cursor >= 0, collection.lines[cursor].formattedResult.isEmpty {
            cursor -= 1
        }
        guard cursor >= 0 else { return expression }
        let value = "(" + collection.lines[cursor].formattedResult + ")"
        return prevPattern.stringByReplacingMatches(
            in: expression,
            range: NSRange(location: 0, length: (expression as NSString).length),
            withTemplate: NSRegularExpression.escapedTemplate(for: value)
        )
    }

    private static func syntaxTokens(for line: Line) -> [SyntaxToken] {
        guard let parsed = line.parsedExpression else { return [] }
        let expression = line.expression
        var tokens: [SyntaxToken] = []
        parsed.metadata.semantics.enumerate(.meaningfulTokens) { token in
            guard let kind = kind(for: token.type),
                  token.range.lowerBound >= expression.startIndex,
                  token.range.upperBound <= expression.endIndex
            else { return }
            tokens.append(SyntaxToken(range: NSRange(token.range, in: expression), kind: kind))
        }
        return tokens
    }

    private static func kind(for part: SemanticToken.PartOfExpression) -> SyntaxKind? {
        switch part {
        case .number, .negativeAmount: .number
        case .operator, .parenthesis: .operatorSymbol
        case .unit: .unit
        case .variable: .variable
        case .functionName, .phraseFunction, .converterWord, .formSpecifier: .function
        case .date, .timezone: .date
        default: nil
        }
    }

    private func collectInputsAndOutputs(lines: [String], collection: LineCollection, aggregates: [Int: Aggregate]) {
        var inputs: [SheetInput] = []
        var outputs: [SheetOutput] = []
        for index in results.indices where !results[index].isEmpty {
            let line = lines[index] as NSString
            let equals = line.range(of: "=")
            let declares = collection.lines[index].apparentLineType == .variableDeclaration && equals.location != NSNotFound
            guard declares else {
                outputs.append(SheetOutput(lineIndex: index, label: Self.label(lines[index]), value: results[index].formatted))
                continue
            }
            let name = Self.label(line.substring(to: equals.location))
            let usesOtherVariables = tokens[index].contains { $0.kind == .variable && $0.range.location > equals.location }
            if aggregates[index] == nil, !usesOtherVariables {
                var start = NSMaxRange(equals)
                var end = line.length
                while start < end, Self.isSpace(line.character(at: start)) { start += 1 }
                while end > start, Self.isSpace(line.character(at: end - 1)) { end -= 1 }
                let range = NSRange(location: start, length: end - start)
                inputs.append(SheetInput(lineIndex: index, name: name, value: line.substring(with: range), valueRange: range))
            } else {
                outputs.append(SheetOutput(lineIndex: index, label: name, value: results[index].formatted))
            }
        }
        self.inputs = inputs
        self.outputs = outputs
    }

    /// A line or variable name without Markdown marks or a trailing colon.
    private static func label(_ text: String) -> String {
        text
            .replacingOccurrences(of: #"^\s*(?:#+|[-*+]|\d+[.)])\s+(?:\[[ xX]\]\s+)?"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ":")))
    }

    private static func isSpace(_ character: unichar) -> Bool {
        character == 0x20 || character == 0x09 || character == 0xA0
    }
}
