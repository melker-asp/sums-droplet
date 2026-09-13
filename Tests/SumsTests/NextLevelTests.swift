//
//  NextLevelTests.swift
//  SumsTests
//

import Foundation
import Testing
@testable import Sums

@MainActor
private func swedish() -> SheetEngine {
    var settings = SumsSettings()
    settings.numberFormat = .spaceComma
    return SheetEngine(settings: settings)
}

// MARK: - Finance

@Suite struct FinanceTests {
    @Test func loanPayment() {
        let payment = Finance.payment(rate: 0.04 / 12, periods: 360, presentValue: 2_000_000)
        #expect(abs(payment - 9548.3059) < 0.001)
        #expect(Finance.payment(rate: 0, periods: 10, presentValue: 1000) == 100)
    }

    @Test func savingsAndPresentValue() {
        let future = Finance.futureValue(rate: 0.07 / 12, periods: 240, payment: 1500)
        #expect(abs(future - 781_390.6) < 1)
        let present = Finance.presentValue(rate: 0.05, periods: 10, payment: 1000)
        #expect(abs(present - 7721.73) < 0.01)
    }

    @Test func netPresentValueAndIRR() {
        // A spreadsheet's NPV: the first flow is one period away.
        let npv = Finance.netPresentValue(rate: 0.1, cashFlows: [-1000, 300, 400, 500])
        #expect(abs(npv - -19.12) < 0.01)
        let irr = Finance.internalRateOfReturn([-1000, 300, 400, 500])
        #expect(abs((irr ?? 0) - 0.0889633947) < 1e-6)
        #expect(Finance.internalRateOfReturn([100, 200]) == nil)
    }
}

// MARK: - Syntax

@Suite struct SyntaxTests {
    @Test func anchorsAndReferences() {
        #expect(SheetSyntax.anchor(in: "Rent: 8 500 kr ^rent")?.name == "rent")
        #expect(SheetSyntax.anchor(in: "2^10") == nil)
        #expect(SheetSyntax.references(in: "@rent × 2 + @food").map(\.name) == ["rent", "food"])
        #expect(SheetSyntax.references(in: "mail@example.com").isEmpty)
    }

    @Test func suggestedAnchorsAreReadableAndUnique() {
        #expect(SheetSyntax.suggestedAnchor(for: "Rent: 8 500 kr", existing: []) == "rent")
        #expect(SheetSyntax.suggestedAnchor(for: "- Food 3 200 + 15%", existing: ["food"]) == "food-2")
        #expect(SheetSyntax.suggestedAnchor(for: "120 + 80", existing: []) == "line")
    }

    @Test func functionCallsSplitOnSemicolons() {
        let calls = SheetSyntax.functionCalls(in: "pay = pmt(4% / 12; 30 × 12; loan) × 2", commaSeparates: false)
        #expect(calls.count == 1)
        #expect(calls.first?.name == "pmt")
        #expect(calls.first?.arguments == ["4% / 12", "30 × 12", "loan"])
        let nested = SheetSyntax.functionCalls(in: "npv(8%; (100 + 50); 200)", commaSeparates: true)
        #expect(nested.first?.arguments == ["8%", "(100 + 50)", "200"])
        #expect(SheetSyntax.functionCalls(in: "npv(8%, 1,5)", commaSeparates: false).first?.arguments == ["8%, 1,5"])
        // With semicolons, commas are thousands separators, even in English.
        #expect(SheetSyntax.functionCalls(in: "npv(8%; 3,000; 4,000)", commaSeparates: true).first?.arguments
                == ["8%", "3,000", "4,000"])
        #expect(SheetSyntax.functionCalls(in: "npv(8%, 300, 400)", commaSeparates: true).first?.arguments
                == ["8%", "300", "400"])
        #expect(SheetSyntax.functionCalls(in: "happy(1)", commaSeparates: true).isEmpty)
    }

    @Test func tables() {
        #expect(SheetSyntax.isTableSeparator("|---|:--:|"))
        #expect(!SheetSyntax.isTableSeparator("| a | b |"))
        #expect(SheetSyntax.cells(of: "| Rent | 8 500 |") == ["Rent", "8 500"])
        #expect(SheetSyntax.markdownTable(fromTabSeparated: "Item\tAmount\nRent\t8500\nFood\t3200")
                == "| Item | Amount |\n| --- | --- |\n| Rent | 8500 |\n| Food | 3200 |")
        #expect(SheetSyntax.markdownTable(fromTabSeparated: "just one line") == nil)
    }

    @Test func chartLines() {
        #expect(SheetSyntax.chartKind(of: "chart above") == .bars)
        #expect(SheetSyntax.chartKind(of: "  Sparkline ") == .line)
        #expect(SheetSyntax.chartKind(of: "chart of sales") == nil)
    }
}

// MARK: - Engine

@Suite @MainActor struct NextLevelEngineTests {
    @Test func financeFunctionsKeepTheCurrency() {
        let engine = swedish()
        engine.evaluate("loan = 2 000 000 kr\npayment = pmt(4% / 12; 30 × 12; loan)\nirr(-1 000; 300; 400; 500)")
        #expect(engine.results[1].raw == "9548,31")
        #expect(engine.results[1].formatted.hasSuffix("kr"))
        #expect(engine.results[2].raw.hasPrefix("8,9"))
        #expect(engine.results[2].raw.hasSuffix("%"))
    }

    @Test func referencesFollowTheirLine() {
        let engine = swedish()
        engine.evaluate("Rent: 8 500 kr ^rent\n\n@rent × 2")
        #expect(engine.results[0].raw == "8500")
        #expect(engine.results[2].raw == "17000")
        engine.evaluate("Moved down\nRent: 8 500 kr ^rent\n\n@rent × 2")
        #expect(engine.results[3].raw == "17000")
    }

    @Test func unknownReferencesGetAHint() {
        let engine = swedish()
        engine.evaluate("@nothing × 2")
        #expect(engine.hints[0]?.contains("nothing") == true)
    }

    @Test func sharedVariablesKeepTheirUnits() {
        let engine = swedish()
        engine.setGlobals([(name: "hourly rate", value: "650 kr")])
        engine.evaluate("hours = 7,5\nhourly rate × hours\nhourly rate = 700 kr\nhourly rate × 2")
        #expect(engine.results[1].raw == "4875")
        #expect(engine.results[1].formatted.contains("kr"))
        #expect(engine.results[3].raw == "1400")
        #expect(engine.names.contains("hourly rate"))
    }

    @Test func tablesTotalTheirColumns() {
        let engine = swedish()
        engine.evaluate("| Item | Amount | Hours |\n|---|---|---|\n| Rent | 8 500 kr | 2 |\n| Food | 3 200 + 15% | 3 |\n| total | | |\n| average | | |")
        #expect(engine.results[4].raw == "12180")
        #expect(engine.results[4].formatted.contains("·"))
        #expect(engine.results[5].formatted.contains("2,5"))
    }

    @Test func chartsCollectTheLinesAbove() {
        let engine = swedish()
        engine.evaluate("Rent: 8 500\nFood: 3 200\nFun: 970\nchart above")
        #expect(engine.charts[3]?.kind == .bars)
        #expect(engine.charts[3]?.points.map(\.value) == [8500, 3200, 970])
        #expect(engine.charts[3]?.points.map(\.label) == ["Rent", "Food", "Fun"])
    }

    @Test func hintsNameTheLikelyMistake() {
        #expect(SheetEngine.hint(for: "1.5 * 2", decimalSeparator: ",")?.contains("comma") == true)
        #expect(SheetEngine.hint(for: "(2 + 3 * 4", decimalSeparator: ",")?.contains("bracket") == true)
        #expect(SheetEngine.hint(for: "Meeting at 3 with Anna", decimalSeparator: ",") == nil)
    }

    @Test func anchorsDoNotReachTheEngine() {
        let engine = swedish()
        engine.evaluate("price = 1 000 kr ^price")
        #expect(engine.results[0].raw == "1000")
        #expect(engine.inputs.first?.value == "1 000 kr")
    }
}
