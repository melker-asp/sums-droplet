//
//  CalculatorEditor.swift
//  Sums
//

import AppKit
import DroppyKit
import SwiftUI

/// The sheet editor: text on the left, each line's answer on the right.
///
/// AppKit rather than SwiftUI's `TextEditor`, because the answer column has to
/// line up with lines that wrap, which needs the layout manager's geometry.
struct CalculatorEditor: NSViewRepresentable {
    @ObservedObject var sheet: SheetModel
    /// Bumped by the droplet to ask for keyboard focus.
    let focusRequest: Int
    let onCopy: (LineResult) -> Void
    let onFocusChange: (Bool) -> Void
    let onFocusReport: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> NSScrollView {
        let coordinator = context.coordinator
        let textView = SumsTextView(usingTextLayoutManager: false)
        textView.configureForSums()
        textView.string = sheet.text
        textView.results = sheet.results
        textView.delegate = coordinator
        textView.onCopy = { [weak coordinator] in coordinator?.parent.onCopy($0) }
        textView.onFocusChange = { [weak coordinator] focused, status in
            coordinator?.parent.onFocusChange(focused)
            coordinator?.parent.onFocusReport(status)
        }

        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? SumsTextView else { return }

        if textView.string != sheet.text {
            textView.string = sheet.text
        }
        if textView.results != sheet.results {
            textView.results = sheet.results
        }
        if focusRequest != context.coordinator.lastFocusRequest {
            context.coordinator.lastFocusRequest = focusRequest
            let report = onFocusReport
            Task { @MainActor in
                // Let the shelf finish presenting before asking for key.
                try? await Task.sleep(for: .milliseconds(150))
                report(textView.takeFocus())
            }
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CalculatorEditor
        var lastFocusRequest = 0

        init(parent: CalculatorEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.sheet.update(text: textView.string)
        }
    }
}

/// A plain-text view that reserves a right-hand column and draws each line's
/// answer in it, level with the first line fragment of that line.
final class SumsTextView: NSTextView {
    var results: [LineResult] = [] {
        didSet { resizeAnswerColumn() }
    }
    var onCopy: ((LineResult) -> Void)?
    var onFocusChange: ((Bool, String) -> Void)?

    private let bodyFont = NSFont.systemFont(ofSize: 13)
    private let answerFont = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
    private var answerColumnWidth: CGFloat = 64

    func configureForSums() {
        let primary = NSColor(AdaptiveColors.notchSurfacePrimaryText)
        isRichText = false
        importsGraphics = false
        allowsUndo = true
        drawsBackground = false
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        isContinuousSpellCheckingEnabled = false
        isGrammarCheckingEnabled = false
        smartInsertDeleteEnabled = false
        font = bodyFont
        textColor = primary
        insertionPointColor = primary
        typingAttributes = [.font: bodyFont, .foregroundColor: primary]
        textContainerInset = NSSize(width: 0, height: 2)
        textContainer?.lineFragmentPadding = 0
        textContainer?.widthTracksTextView = true
        textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        minSize = .zero
        maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        isVerticallyResizable = true
        isHorizontallyResizable = false
        autoresizingMask = [.width]
    }

    // MARK: Focus

    /// Tries to become the keyboard target and says what happened.
    func takeFocus() -> String {
        guard let window else { return "focus: no window" }
        window.makeKey()
        let accepted = window.makeFirstResponder(self)
        return status(prefix: accepted ? "shortcut" : "shortcut refused")
    }

    private func status(prefix: String) -> String {
        guard let window else { return "\(prefix): no window" }
        return "\(prefix): \(type(of: window)) key=\(window.isKeyWindow) canKey=\(window.canBecomeKey)"
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { onFocusChange?(true, status(prefix: "focused")) }
        return became
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { onFocusChange?(false, status(prefix: "resigned")) }
        return resigned
    }

    // MARK: Answer column

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        // The column's cap is a share of the width, and the first results
        // arrive before the view has any width at all.
        resizeAnswerColumn()
    }

    override func didChangeText() {
        super.didChangeText()
        // A wrap can move every line below the edit, answers included.
        needsDisplay = true
    }

    private func resizeAnswerColumn() {
        let widest = results
            .map { ($0.formatted as NSString).size(withAttributes: [.font: answerFont]).width }
            .max() ?? 0
        answerColumnWidth = min(max(64, ceil(widest) + 12), bounds.width * 0.45)
        updateExclusion()
        needsDisplay = true
    }

    /// Keeps text out of the answer column so long lines wrap before it.
    private func updateExclusion() {
        guard let textContainer else { return }
        let width = textContainer.size.width
        guard width > answerColumnWidth else { return }
        textContainer.exclusionPaths = [
            NSBezierPath(rect: NSRect(x: width - answerColumnWidth, y: 0, width: answerColumnWidth, height: 1_000_000))
        ]
    }

    /// Calls `body` with the rectangle of every non-empty answer, in view
    /// coordinates.
    private func enumerateAnswers(_ body: (NSRect, LineResult) -> Void) {
        guard let layoutManager, let textContainer else { return }
        let text = string as NSString
        let origin = textContainerOrigin
        let columnX = origin.x + textContainer.size.width - answerColumnWidth
        // One result per "\n"-separated line, the same split SoulverCore uses.
        var location = 0
        for result in results {
            let line = text.lineRange(for: NSRange(location: location, length: 0))
            if !result.isEmpty, line.location < text.length {
                let glyph = layoutManager.glyphIndexForCharacter(at: line.location)
                let fragment = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
                let rect = NSRect(x: columnX, y: origin.y + fragment.minY, width: answerColumnWidth, height: fragment.height)
                body(rect, result)
            }
            guard line.length > 0 else { break }
            location = NSMaxRange(line)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let style = NSMutableParagraphStyle()
        style.alignment = .right
        style.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [
            .font: answerFont,
            .foregroundColor: NSColor(AdaptiveColors.notchSurfacePrimaryText),
            .paragraphStyle: style
        ]
        enumerateAnswers { rect, result in
            guard rect.intersects(dirtyRect) else { return }
            (result.formatted as NSString).draw(in: rect, withAttributes: attributes)
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        var hit: LineResult?
        enumerateAnswers { rect, result in
            if hit == nil, rect.contains(point) { hit = result }
        }
        if let hit {
            onCopy?(hit)
            return
        }
        super.mouseDown(with: event)
    }
}
