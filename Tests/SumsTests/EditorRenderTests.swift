//
//  EditorRenderTests.swift
//  SumsTests
//

import AppKit
import Foundation
import Testing
@testable import Sums

/// Draws the sheet editor off screen with every kind of line Sums styles
/// or draws for: charts, tables, references, finance, hints. It must not
/// crash or hang; set SUMS_RENDER_PATH to a .png path to look at the result.
@Suite @MainActor struct EditorRenderTests {
    @Test func editorDrawsEverything() throws {
        let text = """
        # Budget
        Rent: 8 500 kr ^rent
        Food: 3 200 kr
        Transport: 970 kr
        total
        chart above
        Half the rent: @rent / 2
        payment = pmt(4% / 12; 30 × 12; 2 000 000 kr)
        1.5 * 2
        | Item | Amount |
        |---|---|
        | Rent | 8 500 kr |
        | total | |
        - [x] Pay rent
        """
        var settings = SumsSettings()
        settings.numberFormat = .spaceComma
        let engine = SheetEngine(settings: settings)
        engine.evaluate(text)

        // In a window that is never shown: a layer-backed view outside any
        // window will not render into a bitmap.
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 600),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let view = SumsTextView(usingTextLayoutManager: false)
        view.frame = NSRect(x: 0, y: 0, width: 440, height: 600)
        window.contentView?.addSubview(view)
        view.configureForSums()
        // The editor draws light text on the shelf's black; paint that black
        // behind it here so the picture reads.
        view.drawsBackground = true
        view.backgroundColor = .black
        view.string = text
        view.syntaxTokens = engine.tokens
        view.hints = engine.hints
        view.charts = engine.charts
        view.results = engine.results
        view.restyle(tokens: engine.tokens)
        // The editor sizes its height to the text it has laid out, so lay out
        // all of it and make the view that tall before drawing.
        let container = try #require(view.textContainer)
        let layoutManager = try #require(view.layoutManager)
        layoutManager.ensureLayout(for: container)
        let height = ceil(layoutManager.usedRect(for: container).height + view.textContainerInset.height * 2 + 8)
        view.frame = NSRect(x: 0, y: 0, width: 440, height: max(height, 100))
        layoutManager.ensureLayout(for: container)

        #expect(engine.charts[5] != nil)
        #expect(engine.hints[8] != nil)

        let size = view.bounds.size
        let rep = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width) * 2,
            pixelsHigh: Int(size.height) * 2,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        rep.size = size
        view.cacheDisplay(in: view.bounds, to: rep)

        guard let path = ProcessInfo.processInfo.environment["SUMS_RENDER_PATH"] else { return }
        let png = try #require(rep.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: path))
    }
}
