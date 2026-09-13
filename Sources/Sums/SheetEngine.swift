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

struct ChartPoint: Equatable {
    let label: String
    let value: Double
}

/// A chart line: the values of the lines above it.
struct ChartSpec: Equatable {
    let kind: SheetSyntax.ChartKind
    let points: [ChartPoint]
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

    /// Every keyword, for autocomplete.
    static var keywords: [String] { words.keys.sorted() }

    static func statistic(named word: String) -> StatisticType? {
        words[word.trimmingCharacters(in: .whitespaces).lowercased()]
    }

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
/// statistics of the lines above, `prev` and `@references`, finance
/// functions, tables, charts, shared variables, hints, syntax colours, and
/// the inputs and outputs the inputs view shows.
@MainActor
final class SheetEngine {
    private(set) var results: [LineResult] = []
    private(set) var tokens: [[SyntaxToken]] = []
    private(set) var inputs: [SheetInput] = []
    private(set) var outputs: [SheetOutput] = []
    /// Why a line that looks like math has no answer.
    private(set) var hints: [Int: String] = [:]
    private(set) var charts: [Int: ChartSpec] = [:]
    /// Names worth completing: variables, `@anchors`, keywords, functions.
    private(set) var names: [String] = []
    /// Every variable the sheet declares, with its answer. What a shared
    /// sheet gives the others.
    private(set) var declarations: [(name: String, value: String)] = []

    private var collection: LineCollection?
    private var aggregateLines = Set<Int>()
    /// How many hidden lines of shared declarations sit above the sheet in
    /// the collection. Sheet line `i` is collection line `i + offset`.
    private var offset = 0
    private var customization: EngineCustomization = .soulver
    private var formatting = FormattingPreferences()
    private var decimalSeparator = ","
    private var globals: [(name: String, value: String)] = []

    private static let prevPattern = try! NSRegularExpression(pattern: #"(?i)\b(prev|ans)\b"#)
    /// An amount with an optional currency or unit: `1 250,00 kr`, `€91,28`,
    /// `25 %`. Anything else (`8 hours 25 min`, a date) copies as shown.
    private static let amountPattern = try! NSRegularExpression(
        pattern: #"^\s*([^\d\s−-]{0,3})\s*([−-]?\d[\d\s  .,']*)\s*(\p{L}{1,4}|%)?\s*$"#
    )
    private static let functionNames = SheetSyntax.financeFunctions.sorted().map { $0 + "(" }

    init(settings: SumsSettings = SumsSettings()) {
        configure(settings)
    }

    func configure(_ settings: SumsSettings, currencyRates: (any CurrencyRateProvider)? = nil) {
        var customization = EngineCustomization.soulver.convertTo(locale: settings.numberFormat.locale)
        customization.currencyRateProvider = currencyRates
        self.customization = customization
        decimalSeparator = settings.numberFormat.decimalSeparator
        var preferences = FormattingPreferences()
        preferences.dp = settings.decimals
        // Money reads in full: 2 000 000 kr, never 2M kr.
        preferences.notationPreferences = .off
        preferences.currencyFormattingPreferences.showTrailingZeros = false
        formatting = preferences
    }

    /// Variables every sheet can use, from the sheets marked as shared.
    /// A sheet's own declaration of the same name wins.
    func setGlobals(_ variables: [(name: String, value: String)]) {
        globals = variables
    }

    // MARK: Evaluation

    func evaluate(_ text: String) {
        let lines = text.components(separatedBy: "\n")
        let masked = MarkdownMask.calculable(text).components(separatedBy: "\n")
        let commaSeparates = decimalSeparator != ","

        var anchors: [String: Int] = [:]
        var tableLines = Set<Int>()
        for (index, line) in lines.enumerated() {
            if let anchor = SheetSyntax.anchor(in: line) { anchors[anchor.name] = index }
            if SheetSyntax.isTableLine(line) { tableLines.insert(index) }
        }

        // Lines Sums fills in after a first pass, because they need the
        // answers above them.
        var aggregates: [Int: Aggregate] = [:]
        var fillIns = Set<Int>()
        var chartLines: [Int: SheetSyntax.ChartKind] = [:]
        var expressions = masked
        for (index, line) in masked.enumerated() {
            if let kind = SheetSyntax.chartKind(of: line) {
                chartLines[index] = kind
                expressions[index] = ""
            } else if let aggregate = Aggregate(line: line) {
                aggregates[index] = aggregate
                expressions[index] = ""
            } else if Self.needsFillIn(line, commaSeparates: commaSeparates) {
                fillIns.insert(index)
                expressions[index] = ""
            }
        }

        // Shared variables are declared on hidden lines above the sheet, so
        // SoulverCore treats them exactly like the sheet's own: units survive,
        // and a later declaration in the sheet wins. The blank line after them
        // keeps totals from counting them.
        let globalLines = globals.isEmpty ? [] : globals.map { "\($0.name) = \($0.value)" } + [""]
        let offset = globalLines.count
        self.offset = offset
        let collection = LineCollection(
            multiLineText: (globalLines + expressions).joined(separator: "\n"),
            customization: customization
        )
        collection.setFormatting(formattingPreferences: formatting)
        collection.evaluateAll()

        var hints: [Int: String] = [:]
        let pending = fillIns.union(aggregates.keys)
        if !pending.isEmpty {
            let aggregateIndexes = Set(aggregates.keys)
            // Two rounds, so a line built on another filled-in line settles.
            for _ in 0..<2 {
                for index in pending.sorted() where index + offset < collection.lineCount {
                    let expression: String
                    if let aggregate = aggregates[index] {
                        let section = Self.section(above: index, lines: lines, collection: collection, offset: offset, excluding: aggregateIndexes)
                        let value = section.isEmpty
                            ? nil
                            : collection.calculateQuickStatistic(
                                statisticType: aggregate.statistic,
                                limitToIndexes: IndexSet(section.map { $0 + offset })
                            )?.stringValue
                        expression = value.map { aggregate.prefix + Self.bracketed($0) } ?? ""
                    } else {
                        expression = fillIn(masked[index], at: index, collection: collection, anchors: anchors, hints: &hints)
                    }
                    collection.setExpression(expression: expression, forLineAt: index + offset)
                    _ = collection.evaluateLinesAt(indexes: IndexSet(integer: index + offset))
                }
                collection.evaluateAll()
            }
        }

        self.collection = collection
        aggregateLines = Set(aggregates.keys)
        let count = min(collection.lineCount - offset, lines.count)
        var results = (0..<count).map { index in
            let formatted = collection.lines[index + offset].formattedResult
            return LineResult(formatted: formatted, raw: plainNumber(formatted))
        }
        for (index, result) in tableResults(lines: lines, tableLines: tableLines, collection: collection) where index < count {
            results[index] = result
        }
        self.results = results

        tokens = (0..<count).map { index in
            if let aggregate = aggregates[index] {
                return [SyntaxToken(range: aggregate.keywordRange, kind: .keyword)]
            }
            if fillIns.contains(index) {
                return Self.fillInTokens(in: lines[index], commaSeparates: commaSeparates)
            }
            return Self.syntaxTokens(for: collection.lines[index + offset])
        }

        charts = [:]
        for (index, kind) in chartLines where index < count {
            let section = Self.section(above: index, lines: lines, collection: collection, offset: offset, excluding: Set(aggregates.keys))
            let points = section.sorted().compactMap { line -> ChartPoint? in
                guard let value = Self.double(from: results[line].raw) else { return nil }
                return ChartPoint(label: Self.chartLabel(lines[line]), value: value)
            }
            if points.count >= 2 { charts[index] = ChartSpec(kind: kind, points: points) }
        }

        for index in 0..<count where results[index].isEmpty && hints[index] == nil {
            guard !tableLines.contains(index), chartLines[index] == nil, aggregates[index] == nil else { continue }
            if let hint = Self.hint(for: masked[index], decimalSeparator: decimalSeparator) { hints[index] = hint }
        }
        self.hints = hints

        var variableNames = Set(collection.finalVariableState.allVariables().map(\.name))
        variableNames.formUnion(globals.map(\.name))
        names = variableNames.sorted()
            + anchors.keys.sorted().map { "@" + $0 }
            + Aggregate.keywords
            + ["prev", "chart above", "sparkline"]
            + Self.functionNames

        collectInputsAndOutputs(lines: lines, collection: collection, excluded: fillIns.union(aggregates.keys))
    }

    /// Sum, average, median and standard deviation of the chosen lines, or
    /// `nil` when fewer than two of them have an answer.
    func stats(for lineIndexes: IndexSet) -> QuickStats? {
        guard let collection else { return nil }
        let valid = IndexSet(lineIndexes.filter { $0 < results.count && !results[$0].isEmpty && !aggregateLines.contains($0) })
        guard valid.count >= 2 else { return nil }
        let shifted = IndexSet(valid.map { $0 + offset })
        func statistic(_ type: StatisticType) -> String {
            guard let value = collection.calculateQuickStatistic(
                statisticType: type,
                limitToIndexes: shifted,
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

    /// Evaluates a single expression, for quick calc.
    func evaluateLine(_ expression: String) -> LineResult {
        evaluate(expression)
        return results.first ?? LineResult(formatted: "", raw: "")
    }

    // MARK: Fill-ins: prev, references, finance

    private static func needsFillIn(_ line: String, commaSeparates: Bool) -> Bool {
        let range = NSRange(location: 0, length: (line as NSString).length)
        return prevPattern.firstMatch(in: line, range: range) != nil
            || !SheetSyntax.references(in: line).isEmpty
            || !SheetSyntax.functionCalls(in: line, commaSeparates: commaSeparates).isEmpty
    }

    private func fillIn(
        _ expression: String,
        at index: Int,
        collection: LineCollection,
        anchors: [String: Int],
        hints: inout [Int: String]
    ) -> String {
        var text = Self.substitutingPrev(in: expression, before: index + offset, floor: offset, collection: collection)
        for reference in SheetSyntax.references(in: text).reversed() {
            guard let line = anchors[reference.name], line != index, line + offset < collection.lineCount else {
                hints[index] = "There is no line named ^\(reference.name)."
                continue
            }
            let answer = collection.lines[line + offset].formattedResult
            guard !answer.isEmpty else { continue }
            text = (text as NSString).replacingCharacters(in: reference.range, with: Self.bracketed(answer))
        }
        let variables = collection.variableStateOnLine(index + offset)
        for call in SheetSyntax.functionCalls(in: text, commaSeparates: decimalSeparator != ",").reversed() {
            guard let value = financeValue(call, variables: variables) else {
                hints[index] = Self.financeUsage[call.name]
                continue
            }
            text = (text as NSString).replacingCharacters(in: call.range, with: Self.bracketed(value))
        }
        return text
    }

    /// A value to put back into an expression, bracketed so it binds as one
    /// operand. Percentages stay bare: SoulverCore reads `8,9 %` but not
    /// `(8,9 %)`.
    private static func bracketed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespaces).hasSuffix("%") ? value : "(" + value + ")"
    }

    private static let financeUsage: [String: String] = [
        "pmt": "pmt(rate; periods; loan): the payment per period.",
        "fv": "fv(rate; periods; payment; today): what savings grow to.",
        "pv": "pv(rate; periods; payment): what payments are worth today.",
        "npv": "npv(rate; flow 1; flow 2; …): cash flows discounted to today.",
        "irr": "irr(flow today; flow 1; flow 2; …): the return that makes them break even."
    ]

    private func financeValue(_ call: SheetSyntax.FunctionCall, variables: VariableList) -> String? {
        let arguments = call.arguments.map { argument($0, variables: variables) }
        guard !arguments.isEmpty, arguments.allSatisfy({ $0 != nil }) else { return nil }
        let numbers = arguments.map { $0!.value }
        let unit = arguments.compactMap { $0?.unit }.first
        let value: Double
        switch call.name {
        case "pmt" where (3...4).contains(numbers.count):
            value = Finance.payment(rate: numbers[0], periods: numbers[1], presentValue: numbers[2], futureValue: numbers.count > 3 ? numbers[3] : 0)
        case "fv" where (3...4).contains(numbers.count):
            value = Finance.futureValue(rate: numbers[0], periods: numbers[1], payment: numbers[2], presentValue: numbers.count > 3 ? numbers[3] : 0)
        case "pv" where (3...4).contains(numbers.count):
            value = Finance.presentValue(rate: numbers[0], periods: numbers[1], payment: numbers[2], futureValue: numbers.count > 3 ? numbers[3] : 0)
        case "npv" where numbers.count >= 2:
            value = Finance.netPresentValue(rate: numbers[0], cashFlows: Array(numbers.dropFirst()))
        case "irr" where numbers.count >= 2:
            guard let rate = Finance.internalRateOfReturn(numbers) else { return nil }
            return number(rate * 100) + "%"
        default:
            return nil
        }
        guard value.isFinite else { return nil }
        guard let unit else { return number(value) }
        return unit.prefix + number(value) + (unit.suffix.isEmpty ? "" : " " + unit.suffix)
    }

    /// A finance argument's exact value, and its currency or unit if it has
    /// one. Evaluated with the variables in scope on the calling line.
    private func argument(_ expression: String, variables: VariableList) -> (value: Double, unit: (prefix: String, suffix: String)?)? {
        guard let result = evaluateSingle(expression, variables: variables),
              let decimal = result.evaluationResult.decimalValue
        else { return nil }
        let value = NSDecimalNumber(decimal: decimal).doubleValue
        if case .unitExpression = result.evaluationResult {
            return (value, Self.unitAffixes(of: result.stringValue))
        }
        return (value, nil)
    }

    private func evaluateSingle(_ expression: String, variables: VariableList?) -> CalculationResult? {
        let single = LineCollection(multiLineText: expression, customization: customization)
        single.setFormatting(formattingPreferences: formatting)
        if let variables { single.variableList = variables }
        single.evaluateAll()
        guard let result = single.lines.first?.result, !result.isEmptyResult, !result.isFailedResult else { return nil }
        return result
    }

    // MARK: Tables

    /// Answers for table rows that ask for a statistic: `| total | | |`
    /// gets each numeric column's total, joined with ` · `.
    private func tableResults(lines: [String], tableLines: Set<Int>, collection: LineCollection) -> [Int: LineResult] {
        var results: [Int: LineResult] = [:]
        var index = 0
        while index < lines.count {
            guard tableLines.contains(index) else { index += 1; continue }
            var block: [Int] = []
            while index < lines.count, tableLines.contains(index) {
                block.append(index)
                index += 1
            }
            let hasHeader = block.count > 1 && SheetSyntax.isTableSeparator(lines[block[1]])
            let rows = block.dropFirst(hasHeader ? 2 : 0).filter { !SheetSyntax.isTableSeparator(lines[$0]) }
            var dataRows: [(line: Int, cells: [String])] = []
            for row in rows {
                let cells = SheetSyntax.cells(of: lines[row])
                guard let first = cells.first, let statistic = Aggregate.statistic(named: first) else {
                    dataRows.append((row, cells))
                    continue
                }
                let width = max(cells.count, dataRows.map(\.cells.count).max() ?? 0)
                let columns = width == 1 ? [0] : Array(1..<width)
                var parts: [String] = []
                var firstRaw = ""
                for column in columns {
                    let values = dataRows.compactMap { data -> (value: Double, unit: (prefix: String, suffix: String)?)? in
                        guard column < data.cells.count, !data.cells[column].isEmpty else { return nil }
                        return argument(data.cells[column], variables: collection.variableStateOnLine(data.line + offset))
                    }
                    guard !values.isEmpty, let value = Self.compute(statistic, values.map(\.value)) else { continue }
                    let unit = statistic == .count ? nil : values.compactMap(\.unit).first
                    let expression = (unit?.prefix ?? "") + number(value) + (unit.map { $0.suffix.isEmpty ? "" : " " + $0.suffix } ?? "")
                    let formatted = reformat(expression)
                    if parts.isEmpty { firstRaw = plainNumber(formatted) }
                    parts.append(formatted)
                }
                if !parts.isEmpty {
                    results[row] = LineResult(formatted: parts.joined(separator: " · "), raw: firstRaw)
                }
            }
        }
        return results
    }

    static func compute(_ statistic: StatisticType, _ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sum = values.reduce(0, +)
        switch statistic {
        case .total: return sum
        case .average: return sum / Double(values.count)
        case .count: return Double(values.count)
        case .lesser: return values.min()
        case .greater: return values.max()
        case .median:
            let sorted = values.sorted()
            let middle = sorted.count / 2
            return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
        case .standardDeviation:
            guard values.count > 1 else { return nil }
            let mean = sum / Double(values.count)
            let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count - 1)
            return variance.squareRoot()
        default:
            return nil
        }
    }

    // MARK: Formatting helpers

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

    /// A number as text the engine reads back exactly, in the sheet's
    /// decimal format and without grouping.
    private func number(_ value: Double) -> String {
        var text = String(format: "%.10f", value)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        if text == "-0" { text = "0" }
        return decimalSeparator == "," ? text.replacingOccurrences(of: ".", with: ",") : text
    }

    /// Runs a value through the sheet's formatting so it matches the answer
    /// column.
    private func reformat(_ value: String) -> String {
        evaluateSingle(value, variables: nil).map { collection in
            let single = LineCollection(multiLineText: value, customization: customization)
            single.setFormatting(formattingPreferences: formatting)
            single.evaluateAll()
            return single.lines.first?.formattedResult ?? collection.stringValue
        } ?? value
    }

    private static func unitAffixes(of formatted: String) -> (prefix: String, suffix: String)? {
        let text = formatted as NSString
        guard let match = amountPattern.firstMatch(in: formatted, range: NSRange(location: 0, length: text.length)) else { return nil }
        let prefix = match.range(at: 1).location == NSNotFound ? "" : text.substring(with: match.range(at: 1))
        let suffix = match.range(at: 3).location == NSNotFound ? "" : text.substring(with: match.range(at: 3))
        return prefix.isEmpty && suffix.isEmpty ? nil : (prefix, suffix)
    }

    /// A plain number from a copy value: `1250,5` or `25%` (as 25).
    private static func double(from raw: String) -> Double? {
        let cleaned = raw
            .replacingOccurrences(of: "%", with: "")
            .replacingOccurrences(of: ",", with: ".")
        return Double(cleaned)
    }

    // MARK: Sections, prev, tokens

    /// The sheet lines an aggregate or chart on `index` covers: those above
    /// it back to a blank line or a heading. Sheet indexes, not collection
    /// indexes.
    private static func section(
        above index: Int,
        lines: [String],
        collection: LineCollection,
        offset: Int,
        excluding aggregates: Set<Int>
    ) -> IndexSet {
        var section = IndexSet()
        var cursor = index - 1
        while cursor >= 0, cursor < lines.count {
            let trimmed = lines[cursor].trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { break }
            if !aggregates.contains(cursor), cursor + offset < collection.lineCount,
               !collection.lines[cursor + offset].formattedResult.isEmpty {
                section.insert(cursor)
            }
            cursor -= 1
        }
        return section
    }

    /// Replaces `prev` with the nearest answer above collection line
    /// `index`, never reaching into the hidden lines below `floor`.
    private static func substitutingPrev(in expression: String, before index: Int, floor: Int, collection: LineCollection) -> String {
        var cursor = index - 1
        while cursor >= floor, collection.lines[cursor].formattedResult.isEmpty {
            cursor -= 1
        }
        guard cursor >= floor else { return expression }
        let value = bracketed(collection.lines[cursor].formattedResult)
        return prevPattern.stringByReplacingMatches(
            in: expression,
            range: NSRange(location: 0, length: (expression as NSString).length),
            withTemplate: NSRegularExpression.escapedTemplate(for: value)
        )
    }

    private static func fillInTokens(in line: String, commaSeparates: Bool) -> [SyntaxToken] {
        let whole = NSRange(location: 0, length: (line as NSString).length)
        var tokens = prevPattern.matches(in: line, range: whole).map { SyntaxToken(range: $0.range, kind: .keyword) }
        tokens += SheetSyntax.references(in: line).map { SyntaxToken(range: $0.range, kind: .keyword) }
        tokens += SheetSyntax.functionCalls(in: line, commaSeparates: commaSeparates).map {
            SyntaxToken(range: NSRange(location: $0.range.location, length: $0.name.utf16.count), kind: .function)
        }
        return tokens
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

    // MARK: Hints

    /// Why a line that looks like math has no answer, when a likely reason
    /// can be named.
    static func hint(for line: String, decimalSeparator: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), !trimmed.hasPrefix(">"),
              trimmed.rangeOfCharacter(from: .decimalDigits) != nil
        else { return nil }
        let hasOperator = trimmed.range(of: #"[\d)]\s*[-+×x*/÷^−]\s*[\d(]"#, options: .regularExpression) != nil
        if decimalSeparator == ",", trimmed.range(of: #"\d\.\d"#, options: .regularExpression) != nil {
            return "Your number format uses a comma for decimals: write 1,5, not 1.5."
        }
        if decimalSeparator == ".", hasOperator, trimmed.range(of: #"\d,\d{1,2}(?!\d)"#, options: .regularExpression) != nil {
            return "Your number format uses a point for decimals: write 1.5, not 1,5."
        }
        if trimmed.filter({ $0 == "(" }).count != trimmed.filter({ $0 == ")" }).count {
            return "A bracket is missing."
        }
        return hasOperator ? "Sums couldn't calculate this line." : nil
    }

    // MARK: Inputs

    private func collectInputsAndOutputs(lines: [String], collection: LineCollection, excluded: Set<Int>) {
        var inputs: [SheetInput] = []
        var outputs: [SheetOutput] = []
        var declarations: [(name: String, value: String)] = []
        defer { self.declarations = declarations }
        for index in results.indices where !results[index].isEmpty {
            let line = lines[index] as NSString
            let equals = line.range(of: "=")
            let declares = collection.lines[index + offset].apparentLineType == .variableDeclaration && equals.location != NSNotFound
            guard declares else {
                outputs.append(SheetOutput(lineIndex: index, label: Self.label(lines[index]), value: results[index].formatted))
                continue
            }
            let name = Self.label(line.substring(to: equals.location))
            declarations.append((name, results[index].formatted))
            let usesOtherVariables = tokens[index].contains { $0.kind == .variable && $0.range.location > equals.location }
            if !excluded.contains(index), !usesOtherVariables {
                var start = NSMaxRange(equals)
                var end = line.length
                if let anchor = SheetSyntax.anchor(in: lines[index]) { end = anchor.range.location }
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

    /// A line or variable name without Markdown marks, anchors or a
    /// trailing colon.
    static func label(_ text: String) -> String {
        var text = text
        if let anchor = SheetSyntax.anchor(in: text) {
            text = (text as NSString).replacingCharacters(in: anchor.range, with: "")
        }
        return text
            .replacingOccurrences(of: #"^\s*(?:#+|[-*+]|\d+[.)])\s+(?:\[[ xX]\]\s+)?"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ":")))
    }

    /// A chart bar's name: the line's label, or its words without numbers.
    private static func chartLabel(_ line: String) -> String {
        let text = label(line)
        if let colon = text.firstIndex(of: ":") { return String(text[..<colon]) }
        let words = text.components(separatedBy: CharacterSet.letters.inverted).filter { $0.count > 1 && $0 != "kr" }
        return words.prefix(2).joined(separator: " ")
    }

    private static func isSpace(_ character: unichar) -> Bool {
        character == 0x20 || character == 0x09 || character == 0xA0
    }
}
