//
//  SumsTests.swift
//  SumsTests
//

import Foundation
import Testing
@testable import Sums

/// Swedish formatting, so the expectations do not depend on the Mac's region.
@MainActor
private func engine(decimals: Int = 2) -> SheetEngine {
    var settings = SumsSettings()
    settings.numberFormat = .spaceComma
    settings.decimals = decimals
    return SheetEngine(settings: settings)
}

@MainActor
private func raw(_ text: String) -> [String] {
    let engine = engine()
    engine.evaluate(text)
    return engine.results.map(\.raw)
}

// MARK: - Markdown

@Suite struct MarkdownMaskTests {
    @Test func listMarkersAreNotMinus() {
        #expect(MarkdownMask.calculable("- 500") == "  500")
        #expect(MarkdownMask.calculable("* 300") == "  300")
        #expect(MarkdownMask.calculable("1. 400") == "   400")
        #expect(MarkdownMask.calculable("- [x] 3 * 4") == "      3 * 4")
    }

    @Test func mathIsLeftAlone() {
        #expect(MarkdownMask.calculable("-500") == "-500")
        #expect(MarkdownMask.calculable("3 * 4 * 5") == "3 * 4 * 5")
        #expect(MarkdownMask.calculable("1.5 + 2") == "1.5 + 2")
    }

    @Test func codeAndTablesAreBlanked() {
        let masked = MarkdownMask.calculable("```\n5 + 5\n```\n| 1 | 2 |\n7 + 1")
        #expect(masked == "   \n     \n   \n         \n7 + 1")
    }
}

@Suite struct AggregateTests {
    @Test func recognisesKeywords() {
        #expect(Aggregate(line: "total")?.statistic == .total)
        #expect(Aggregate(line: "  Average ")?.statistic == .average)
        #expect(Aggregate(line: "std dev")?.statistic == .standardDeviation)
        #expect(Aggregate(line: "expenses = total")?.prefix == "expenses = ")
        #expect(Aggregate(line: "Spread: std dev")?.statistic == .standardDeviation)
    }

    @Test func ignoresOrdinaryLines() {
        #expect(Aggregate(line: "Rent: 8 500") == nil)
        #expect(Aggregate(line: "average of 12, 15") == nil)
        #expect(Aggregate(line: "max(3, 4)") == nil)
        #expect(Aggregate(line: "Transport") == nil)
    }
}

// MARK: - Engine

@Suite @MainActor struct EngineTests {
    @Test func totalsCountTheLinesAboveBackToABlankLine() {
        let results = raw("ignored 100\n\n8 500\n3 200\n970\ntotal")
        #expect(results[5] == "12670")
    }

    @Test func statisticsSkipOtherAggregates() {
        let results = raw("12\n15\n9\n22\naverage\nmedian\ncount\nmin\nmax")
        #expect(results[4] == "14,5")
        #expect(results[5] == "13,5")
        #expect(results[6] == "4")
        #expect(results[7] == "9")
        #expect(results[8] == "22")
    }

    @Test func aTotalCanBeAssignedAndUsed() {
        let results = raw("income = 32 000 kr\n\nRent: 8 500 kr\nFood: 3 200 kr\nexpenses = total\n\nleft = income - expenses")
        #expect(results[4] == "11700")
        #expect(results[6] == "20300")
    }

    @Test func prevIsTheAnswerAbove() {
        let results = raw("10\n\nprev × 2")
        #expect(results[2] == "20")
    }

    @Test func listItemsCalculateAsTheirContent() {
        #expect(raw("- 500")[0] == "500")
    }

    @Test func quickStatsNeedTwoLines() {
        let engine = engine()
        engine.evaluate("12\n15\n9\n22")
        #expect(engine.stats(for: IndexSet(integer: 0)) == nil)
        let stats = engine.stats(for: IndexSet(0...3))
        #expect(stats?.count == 4)
        #expect(stats?.total == "58")
        #expect(stats?.median == "13,5")
    }

    @Test func inputsAreVariablesWithPlainValues() {
        let engine = engine()
        engine.evaluate("price = 1 000 kr\nvat rate = 25%\nvat = price × vat rate\ntotal = price + vat")
        #expect(engine.inputs.map(\.name) == ["price", "vat rate"])
        #expect(engine.inputs.first?.value == "1 000 kr")
        #expect(engine.outputs.map(\.label) == ["vat", "total"])
        #expect(engine.results[3].raw == "1250")
    }

    @Test func largeAmountsAreWrittenInFull() {
        let engine = engine()
        engine.evaluate("2 000 000 kr")
        // SoulverCore groups with no-break spaces.
        let shown = engine.results[0].formatted
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: "\u{202F}", with: " ")
        #expect(shown.contains("2 000 000"))
        #expect(engine.results[0].raw == "2000000")
    }

    @Test func copiesArePlainNumbers() {
        let engine = engine()
        #expect(engine.plainNumber("1\u{00A0}250,00 kr") == "1250")
        #expect(engine.plainNumber("€91,28") == "91,28")
        #expect(engine.plainNumber("−500") == "-500")
        #expect(engine.plainNumber("25 %") == "25%")
        #expect(engine.plainNumber("8 hours 25 min") == "8 hours 25 min")
    }
}

// MARK: - Templates

@Suite @MainActor struct TemplateTests {
    @Test func everyTemplateCalculates() throws {
        for template in Templates.all {
            let engine = engine()
            engine.evaluate(template.text)
            #expect(engine.summary != nil, "\(template.title) has no answer")
        }
    }

    @Test func financeTemplatesGiveTheRightAnswers() throws {
        func summary(_ id: String) throws -> String {
            let template = try #require(Templates.all.first { $0.id == id })
            let engine = engine()
            engine.evaluate(template.text)
            return try #require(engine.summary).raw
        }
        #expect(try summary("vat") == "1250")
        #expect(try summary("reverse-vat") == "250")
        #expect(try summary("discount") == "120")
        #expect(try summary("break-even") == "125000")
        #expect(try summary("budget") == "19031")
        #expect(try summary("loan").hasPrefix("1437"))
    }

    @Test func pointDecimalConversion() {
        #expect(SheetTemplate.toPointDecimals("1 234,50 kr") == "1,234.50 kr")
        #expect(SheetTemplate.toPointDecimals("2 000 000 kr") == "2,000,000 kr")
        #expect(SheetTemplate.toPointDecimals("average of 12, 15, 9") == "average of 12, 15, 9")
        #expect(SheetTemplate.toPointDecimals("0,04 / 12") == "0.04 / 12")
    }
}

// MARK: - Export

@Suite struct ExporterTests {
    @Test func csvUsesSemicolonsWithDecimalCommas() {
        let csv = SheetExporter.export(
            .csv,
            title: "T",
            lines: ["a 1,5", "note"],
            results: [LineResult(formatted: "1,5", raw: "1,5")],
            decimalSeparator: ","
        )
        #expect(csv == "Line;Answer\n\"a 1,5\";\"1,5\"\nnote;\n")
    }

    @Test func plainTextPutsAnswersAfterLines() {
        let text = SheetExporter.plainText(
            lines: ["price = 100", "# Heading"],
            results: [LineResult(formatted: "100", raw: "100"), LineResult(formatted: "", raw: "")]
        )
        #expect(text == "price = 100 = 100\n# Heading")
    }

    @Test func fileNamesAreSafe() {
        #expect(SheetExporter.fileName(for: "VAT: 25/12", format: .csv) == "VAT- 25-12.csv")
    }
}

// MARK: - Store

@Suite @MainActor struct StoreTests {
    private func folder() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("SumsTests-\(UUID().uuidString)", isDirectory: true)
    }

    @Test func sheetsSurviveAReload() {
        let directory = folder()
        let store = SheetStore()
        #expect(store.load(directory: directory))
        let sheet = store.create(title: "Budget", text: "1 + 1")
        store.rename(sheet.id, to: "  Budget september ")
        store.flush()

        let reopened = SheetStore()
        #expect(!reopened.load(directory: directory))
        #expect(reopened.displayTitle(sheet.id) == "Budget september")
        #expect(reopened.text(sheet.id) == "1 + 1")
    }

    @Test func untitledSheetsAreNamedByTheirFirstLine() {
        let store = SheetStore()
        store.load(directory: folder())
        let sheet = store.create(text: "\n## Trip to Oslo\n100 kr")
        #expect(store.displayTitle(sheet.id) == "Trip to Oslo")
    }

    @Test func trashKeepsSheetsFor30Days() {
        let directory = folder()
        let store = SheetStore()
        store.load(directory: directory)
        let old = store.create(text: "old")
        let recent = store.create(text: "recent")
        let now = Date()
        store.moveToTrash(old.id, now: now.addingTimeInterval(-31 * 24 * 60 * 60))
        store.moveToTrash(recent.id, now: now)
        store.flush()

        let reopened = SheetStore()
        reopened.load(directory: directory, now: now)
        #expect(reopened.sheet(old.id) == nil)
        #expect(reopened.recentlyDeleted.map(\.id) == [recent.id])
        reopened.restore(recent.id)
        #expect(reopened.active.map(\.id) == [recent.id])
    }
}
