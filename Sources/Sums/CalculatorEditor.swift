//
//  CalculatorEditor.swift
//  Sums
//

import AppKit
import DroppyKit
import QuartzCore
import SwiftUI

/// What the editor asks of the droplet.
struct EditorActions {
    var textChanged: @MainActor (String) -> Void
    /// The caret location and the lines the selection covers.
    var selectionChanged: @MainActor (Int, IndexSet) -> Void
    var copyAnswer: @MainActor (LineResult) -> Void
    /// Copies text as it is, and says so with the given message.
    var copyText: @MainActor (String, String) -> Void
    var showMessage: @MainActor (String) -> Void
    var focusChanged: @MainActor (Bool) -> Void
    var back: @MainActor () -> Void
    var newSheet: @MainActor () -> Void
}

/// The worksheet editor: styled Markdown on the left, each line's answer on
/// the right.
///
/// AppKit rather than SwiftUI's `TextEditor`, because the answer column has to
/// line up with lines that wrap, which needs the layout manager's geometry.
struct CalculatorEditor: NSViewRepresentable {
    @ObservedObject var document: SheetDocument
    /// Bumped by the droplet to ask for keyboard focus.
    let focusRequest: Int
    /// Caret location to restore when a sheet opens.
    let restoreSelection: Int?
    /// The number format's decimal mark, for scrubbing numbers.
    let decimalSeparator: String
    let actions: EditorActions

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> NSScrollView {
        let coordinator = context.coordinator
        let textView = SumsTextView(usingTextLayoutManager: false)
        textView.configureForSums()
        textView.delegate = coordinator
        textView.onCopy = { [weak coordinator] in coordinator?.parent.actions.copyAnswer($0) }
        textView.onCopyText = { [weak coordinator] in coordinator?.parent.actions.copyText($0, $1) }
        textView.onMessage = { [weak coordinator] in coordinator?.parent.actions.showMessage($0) }
        textView.onFocusChange = { [weak coordinator] in coordinator?.parent.actions.focusChanged($0) }
        textView.onBack = { [weak coordinator] in coordinator?.parent.actions.back() }
        textView.onNewSheet = { [weak coordinator] in coordinator?.parent.actions.newSheet() }

        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.documentView = textView
        return scrollView
    }

    /// The editor fills whatever it is offered. Left to SwiftUI, sizing would
    /// measure the scroll view's content, which the text layout keeps
    /// changing, and layout would never settle.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 300, height: proposal.height ?? 120)
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        guard let textView = scrollView.documentView as? SumsTextView else { return }

        coordinator.isUpdating = true
        defer { coordinator.isUpdating = false }

        var needsRestyle = false
        if coordinator.sheetID != document.sheetID {
            // A different sheet: new text, the caret where it was left, no
            // undo history from the previous sheet, and no answers animating
            // in as if they had changed.
            coordinator.sheetID = document.sheetID
            textView.animatesChanges = false
            textView.string = document.text
            textView.undoManager?.removeAllActions()
            let location = min(restoreSelection ?? 0, (document.text as NSString).length)
            textView.setSelectedRange(NSRange(location: location, length: 0))
            textView.scrollRangeToVisible(NSRange(location: location, length: 0))
            needsRestyle = true
        } else if textView.string != document.text {
            // Changed from outside the editor, by an input field.
            let selection = textView.selectedRange()
            textView.string = document.text
            let length = (document.text as NSString).length
            textView.setSelectedRange(NSRange(location: min(selection.location, length), length: 0))
            needsRestyle = true
        }
        textView.decimalSeparator = decimalSeparator
        textView.syntaxTokens = document.tokens
        textView.completionNames = document.names
        if textView.hints != document.hints { textView.hints = document.hints }
        if textView.charts != document.charts { textView.charts = document.charts }
        if textView.results != document.results { textView.results = document.results }
        textView.animatesChanges = true
        if needsRestyle || coordinator.tokens != document.tokens {
            coordinator.tokens = document.tokens
            coordinator.scheduleRestyle(of: textView)
        }
        if focusRequest != coordinator.lastFocusRequest {
            coordinator.lastFocusRequest = focusRequest
            Task { @MainActor in
                // Let the shelf finish presenting before asking for key.
                try? await Task.sleep(for: .milliseconds(150))
                textView.takeFocus()
            }
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CalculatorEditor
        var lastFocusRequest = 0
        var sheetID: UUID?
        var tokens: [[SyntaxToken]] = []
        /// True while SwiftUI is pushing state into the view, when changes
        /// the view reports back are echoes rather than the user's.
        var isUpdating = false
        private var restyleIsScheduled = false

        init(parent: CalculatorEditor) {
            self.parent = parent
        }

        /// Restyles after the current SwiftUI pass rather than inside it.
        /// Restyling changes the text layout, and doing that from within a
        /// layout pass let the host's layout re-enter the editor.
        func scheduleRestyle(of textView: SumsTextView) {
            guard !restyleIsScheduled else { return }
            restyleIsScheduled = true
            Task { @MainActor [weak self, weak textView] in
                guard let self else { return }
                self.restyleIsScheduled = false
                textView?.restyle(tokens: self.tokens)
            }
        }

        func textDidChange(_ notification: Notification) {
            guard !isUpdating, let textView = notification.object as? NSTextView else { return }
            parent.actions.textChanged(textView.string)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard !isUpdating, let textView = notification.object as? NSTextView else { return }
            let range = textView.selectedRange()
            let text = textView.string as NSString
            var lines = IndexSet()
            if range.length > 0 {
                let first = SumsTextView.lineIndex(at: range.location, in: text)
                let last = SumsTextView.lineIndex(at: NSMaxRange(range) - 1, in: text)
                lines = IndexSet(integersIn: first...last)
            }
            parent.actions.selectionChanged(range.location, lines)
        }
    }
}

/// A plain-text view that styles its Markdown, reserves a right-hand column
/// and draws each line's answer in it, and adds Sums' direct manipulation:
/// scrubbing numbers, acting on and dragging answers, references, inline
/// completion, spreadsheet pastes, charts and hints.
final class SumsTextView: NSTextView {
    var results: [LineResult] = [] {
        didSet {
            resizeAnswerColumn()
            window?.invalidateCursorRects(for: self)
            if animatesChanges { animateChanges(from: oldValue) }
        }
    }
    var hints: [Int: String] = [:] {
        didSet {
            needsDisplay = true
            window?.invalidateCursorRects(for: self)
        }
    }
    var charts: [Int: ChartSpec] = [:] {
        didSet { needsDisplay = true }
    }
    var syntaxTokens: [[SyntaxToken]] = []
    var completionNames: [String] = []
    var decimalSeparator = ","
    /// Off while a sheet loads, so its answers do not animate in.
    var animatesChanges = false

    var onCopy: (@MainActor (LineResult) -> Void)?
    var onCopyText: (@MainActor (String, String) -> Void)?
    var onMessage: (@MainActor (String) -> Void)?
    var onFocusChange: (@MainActor (Bool) -> Void)?
    var onBack: (@MainActor () -> Void)?
    var onNewSheet: (@MainActor () -> Void)?

    private let answerFont = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
    private var answerColumnWidth: CGFloat = 64
    private let placeholder = "Type a note or a calculation…"

    private var styledText: String?
    private var styledTokens: [[SyntaxToken]] = []

    /// Answers mid-roll, drawn by their layer instead of `draw(_:)`.
    private var rollingLines = Set<Int>()
    private var actionBar: NSHostingView<AnyView>?
    private var actionBarLine: Int?
    private var hoverTracking: NSTrackingArea?
    private var pendingAnswerClick: (line: Int, result: LineResult, point: NSPoint)?
    private let dragSource = AnswerDragSource()
    private var scrub: Scrub?
    private var suggestion: (text: String, location: Int)? {
        didSet { if oldValue?.text != suggestion?.text || oldValue?.location != suggestion?.location { needsDisplay = true } }
    }

    private struct Scrub {
        var range: NSRange
        let start: Double
        let decimals: Int
        let step: Double
        let groups: Bool
        let startX: CGFloat
    }

    func configureForSums() {
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
        font = SheetStyler.bodyFont
        textColor = SheetStyler.primary
        insertionPointColor = SheetStyler.primary
        typingAttributes = SheetStyler.typingAttributes
        textContainerInset = NSSize(width: 0, height: 2)
        textContainer?.lineFragmentPadding = 0
        textContainer?.widthTracksTextView = true
        textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        minSize = .zero
        maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        isVerticallyResizable = true
        isHorizontallyResizable = false
        autoresizingMask = [.width]
        wantsLayer = true
    }

    /// Repaints Markdown and syntax colours. Skipped while an input method is
    /// composing a character, which restyling would interrupt.
    func restyle(tokens: [[SyntaxToken]]) {
        guard let textStorage, !hasMarkedText() else { return }
        // Styling relays out every line, so never redo identical work.
        let text = string
        guard text != styledText || tokens != styledTokens else { return }
        SheetStyler.apply(to: textStorage, tokens: tokens)
        styledText = text
        styledTokens = tokens
        typingAttributes = SheetStyler.typingAttributes
        needsDisplay = true
    }

    // MARK: Focus and keys

    func takeFocus() {
        guard let window else { return }
        window.makeKey()
        window.makeFirstResponder(self)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { onFocusChange?(true) }
        return became
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned {
            onFocusChange?(false)
            suggestion = nil
        }
        return resigned
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers == .command, let key = event.charactersIgnoringModifiers {
            switch key {
            case "[":
                onBack?()
                return true
            case "n":
                onNewSheet?()
                return true
            default:
                break
            }
        }
        return super.performKeyEquivalent(with: event)
    }

    /// Tab accepts the grey completion; otherwise it is a tab.
    override func insertTab(_ sender: Any?) {
        guard let suggestion, suggestion.location == selectedRange().location else {
            super.insertTab(sender)
            return
        }
        self.suggestion = nil
        insertText(suggestion.text, replacementRange: selectedRange())
    }

    override func cancelOperation(_ sender: Any?) {
        if suggestion != nil {
            suggestion = nil
        } else {
            super.cancelOperation(sender)
        }
    }

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        // A completion only makes sense right where the user is typing.
        if let suggestion, selectedRange() != NSRange(location: suggestion.location, length: 0) {
            self.suggestion = nil
        }
    }

    // MARK: Pasting from a spreadsheet

    /// Cells copied from Excel or Numbers arrive tab-separated; they become a
    /// Markdown table with a total row, so the sums are there at once.
    override func paste(_ sender: Any?) {
        guard let pasted = NSPasteboard.general.string(forType: .string),
              pasted.contains("\t"),
              let table = SheetSyntax.markdownTable(fromTabSeparated: pasted)
        else {
            super.paste(sender)
            return
        }
        let width = SheetSyntax.cells(of: table.components(separatedBy: "\n")[0]).count
        let total = SheetSyntax.row(["total"] + Array(repeating: "", count: max(width - 1, 0)))
        let selection = selectedRange()
        let text = string as NSString
        let atLineStart = selection.location == 0 || text.character(at: selection.location - 1) == 0x0A
        insertText((atLineStart ? "" : "\n") + table + "\n" + total, replacementRange: selection)
    }

    // MARK: Answer column

    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = newSize.width != frame.width
        super.setFrameSize(newSize)
        // The column's cap is a share of the width, and the first results
        // arrive before the view has any width at all. Only a new width
        // matters: the height follows the text, so reacting to it would
        // relay out the text, change the height, and go round forever.
        if widthChanged { resizeAnswerColumn() }
    }

    override func didChangeText() {
        super.didChangeText()
        // A wrap can move every line below the edit, answers included.
        needsDisplay = true
        updateSuggestion()
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
        let column = NSRect(x: width - answerColumnWidth, y: 0, width: answerColumnWidth, height: 1_000_000)
        // Assigning paths relays out all the text even when they are the same.
        guard textContainer.exclusionPaths.first?.bounds != column else { return }
        textContainer.exclusionPaths = [NSBezierPath(rect: column)]
    }

    private var columnX: CGFloat {
        textContainerOrigin.x + (textContainer?.size.width ?? bounds.width) - answerColumnWidth
    }

    /// Calls `body` with each line's index, its characters without the line
    /// break, and its first line fragment, in view coordinates.
    private func enumerateLines(_ body: (Int, NSRange, NSRect) -> Void) {
        guard let layoutManager else { return }
        let text = string as NSString
        let origin = textContainerOrigin
        var location = 0
        var index = 0
        while location < text.length {
            let line = text.lineRange(for: NSRange(location: location, length: 0))
            var content = line
            if content.length > 0, text.character(at: NSMaxRange(content) - 1) == 0x0A { content.length -= 1 }
            let glyph = layoutManager.glyphIndexForCharacter(at: line.location)
            var fragment = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            fragment.origin.x += origin.x
            fragment.origin.y += origin.y
            body(index, content, fragment)
            location = NSMaxRange(line)
            index += 1
        }
    }

    private func answerRect(in fragment: NSRect) -> NSRect {
        NSRect(x: columnX, y: fragment.minY, width: answerColumnWidth, height: min(fragment.height, 20))
    }

    /// The right-aligned rectangle an answer's text actually covers.
    private func answerTextRect(_ result: LineResult, in fragment: NSRect) -> NSRect {
        let width = min(ceil((result.formatted as NSString).size(withAttributes: [.font: answerFont]).width), answerColumnWidth)
        let column = answerRect(in: fragment)
        return NSRect(x: column.maxX - width, y: column.minY, width: width, height: 17)
    }

    private func answerHit(at point: NSPoint) -> (line: Int, result: LineResult, rect: NSRect)? {
        var hit: (Int, LineResult, NSRect)?
        enumerateLines { index, _, fragment in
            guard hit == nil, index < results.count, !results[index].isEmpty else { return }
            let rect = answerRect(in: fragment)
            if rect.contains(point) { hit = (index, results[index], answerTextRect(results[index], in: fragment)) }
        }
        return hit
    }

    private func hintHit(at point: NSPoint) -> String? {
        var hit: String?
        enumerateLines { index, _, fragment in
            guard hit == nil, let hint = hints[index] else { return }
            if answerRect(in: fragment).contains(point) { hit = hint }
        }
        return hit
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if string.isEmpty {
            (placeholder as NSString).draw(
                at: textContainerOrigin,
                withAttributes: [.font: SheetStyler.bodyFont, .foregroundColor: SheetStyler.tertiary]
            )
        }
        let style = NSMutableParagraphStyle()
        style.alignment = .right
        style.lineBreakMode = .byTruncatingTail
        let answerAttributes: [NSAttributedString.Key: Any] = [
            .font: answerFont,
            .foregroundColor: SheetStyler.primary,
            .paragraphStyle: style
        ]
        let hintAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: SheetStyler.tertiary,
            .paragraphStyle: style
        ]
        let text = string as NSString
        enumerateLines { index, content, fragment in
            guard fragment.intersects(dirtyRect) else { return }
            if let chart = charts[index] {
                let words = (text.substring(with: content) as NSString).size(withAttributes: [.font: SheetStyler.bodyFont]).width
                let x = fragment.minX + words + 16
                let area = NSRect(x: x, y: fragment.minY + 6, width: columnX + answerColumnWidth - x, height: fragment.height - 10)
                ChartRenderer.draw(chart, in: area)
            }
            if index < results.count, !results[index].isEmpty, !rollingLines.contains(index) {
                (results[index].formatted as NSString).draw(in: answerRect(in: fragment), withAttributes: answerAttributes)
            } else if hints[index] != nil {
                ("?" as NSString).draw(in: answerRect(in: fragment), withAttributes: hintAttributes)
            }
        }
        drawSuggestion()
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        removeAllToolTips()
        enumerateLines { index, _, fragment in
            let rect = answerRect(in: fragment)
            if index < results.count, !results[index].isEmpty {
                addCursorRect(rect, cursor: .pointingHand)
            } else if let hint = hints[index] {
                addToolTip(rect, owner: hint as NSString, userData: nil)
            }
        }
    }

    // MARK: Animation

    /// Answers that changed because of an edit elsewhere roll in and glow
    /// briefly, so a total that moved is noticed. The line being typed on
    /// does not animate, and a change in line count is a reshuffle, not news.
    private func animateChanges(from old: [LineResult]) {
        guard window != nil, results.count == old.count else { return }
        let caretLine = Self.lineIndex(at: selectedRange().location, in: string as NSString)
        let changed = results.indices.filter { index in
            index != caretLine && !results[index].isEmpty && old[index].formatted != results[index].formatted
        }
        guard !changed.isEmpty, changed.count <= 12 else { return }
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        // After the text has laid out, so the rectangles are current.
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.enumerateLines { index, _, fragment in
                guard changed.contains(index), index < self.results.count else { return }
                let rect = self.answerTextRect(self.results[index], in: fragment)
                self.glow(at: rect)
                if !reduceMotion { self.roll(self.results[index].formatted, line: index, in: rect) }
            }
        }
    }

    private func glow(at rect: NSRect) {
        guard let layer else { return }
        let glow = CALayer()
        glow.frame = rect.insetBy(dx: -4, dy: -1)
        glow.cornerRadius = 5
        glow.backgroundColor = SheetStyler.color(for: .number).withAlphaComponent(0.26).cgColor
        glow.opacity = 0
        layer.addSublayer(glow)
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        fade.duration = 0.9
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        CATransaction.begin()
        CATransaction.setCompletionBlock { glow.removeFromSuperlayer() }
        glow.add(fade, forKey: "fade")
        CATransaction.commit()
    }

    private func roll(_ value: String, line: Int, in rect: NSRect) {
        guard let layer else { return }
        let text = CATextLayer()
        text.frame = rect.insetBy(dx: 0, dy: 0)
        text.string = NSAttributedString(string: value, attributes: [.font: answerFont, .foregroundColor: SheetStyler.primary])
        text.alignmentMode = .right
        text.contentsScale = window?.backingScaleFactor ?? 2
        layer.addSublayer(text)
        rollingLines.insert(line)
        needsDisplay = true

        let rise = CABasicAnimation(keyPath: "transform.translation.y")
        rise.fromValue = 7
        rise.toValue = 0
        let appear = CABasicAnimation(keyPath: "opacity")
        appear.fromValue = 0
        appear.toValue = 1
        let group = CAAnimationGroup()
        group.animations = [rise, appear]
        group.duration = 0.28
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            text.removeFromSuperlayer()
            self?.rollingLines.remove(line)
            self?.needsDisplay = true
        }
        text.add(group, forKey: "roll")
        CATransaction.commit()
    }

    // MARK: Hover actions

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        hoverTracking = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        let point = convert(event.locationInWindow, from: nil)
        if let hit = answerHit(at: point) {
            showActions(forLine: hit.line, near: hit.rect)
        } else if let bar = actionBar, bar.frame.insetBy(dx: -8, dy: -6).contains(point) {
            // Moving onto the bar keeps it.
        } else {
            hideActions()
        }
        if event.modifierFlags.contains(.command), numberToken(at: point) != nil {
            NSCursor.resizeLeftRight.set()
        }
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        hideActions()
    }

    override func flagsChanged(with event: NSEvent) {
        super.flagsChanged(with: event)
        guard let window else { return }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        if event.modifierFlags.contains(.command), numberToken(at: point) != nil {
            NSCursor.resizeLeftRight.set()
        }
    }

    private func showActions(forLine line: Int, near rect: NSRect) {
        guard actionBarLine != line || actionBar == nil else { return }
        hideActions()
        let bar = NSHostingView(rootView: AnyView(AnswerActionsBar(
            onCopy: { [weak self] in self?.copyAnswer(line: line, withUnit: false) },
            onCopyWithUnit: { [weak self] in self?.copyAnswer(line: line, withUnit: true) },
            onReference: { [weak self] in self?.insertReference(toLine: line) },
            onName: { [weak self] in self?.nameLine(line) }
        )))
        let size = bar.fittingSize
        bar.frame = NSRect(
            x: max(textContainerOrigin.x, rect.minX - size.width - 6),
            y: rect.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
        addSubview(bar)
        actionBar = bar
        actionBarLine = line
    }

    private func hideActions() {
        actionBar?.removeFromSuperview()
        actionBar = nil
        actionBarLine = nil
    }

    private func copyAnswer(line: Int, withUnit: Bool) {
        guard line < results.count, !results[line].isEmpty else { return }
        if withUnit {
            onCopyText?(results[line].formatted, "Copied \(results[line].formatted)")
        } else {
            onCopy?(results[line])
        }
    }

    // MARK: Clicks, drags and scrubbing

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if event.modifierFlags.contains(.command), beginScrub(at: point) { return }
        if let hit = answerHit(at: point) {
            if event.modifierFlags.contains(.option) {
                insertReference(toLine: hit.line)
            } else {
                // A click copies; a drag carries the number out.
                pendingAnswerClick = (hit.line, hit.result, point)
            }
            return
        }
        if let hint = hintHit(at: point) {
            onMessage?(hint)
            return
        }
        if toggleCheckbox(at: point) { return }
        super.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if scrub != nil {
            continueScrub(to: point, faster: event.modifierFlags.contains(.shift))
            return
        }
        if let pending = pendingAnswerClick {
            if hypot(point.x - pending.point.x, point.y - pending.point.y) > 3 {
                pendingAnswerClick = nil
                dragAnswer(line: pending.line, result: pending.result, event: event)
            }
            return
        }
        super.mouseDragged(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        if scrub != nil {
            scrub = nil
            undoManager?.endUndoGrouping()
            return
        }
        if let pending = pendingAnswerClick {
            pendingAnswerClick = nil
            onCopy?(pending.result)
            return
        }
        super.mouseUp(with: event)
    }

    private func dragAnswer(line: Int, result: LineResult, event: NSEvent) {
        var frame = NSRect.zero
        enumerateLines { index, _, fragment in
            if index == line { frame = answerTextRect(result, in: fragment) }
        }
        let item = NSPasteboardItem()
        item.setString(result.raw, forType: .string)
        let dragging = NSDraggingItem(pasteboardWriter: item)
        let attributes: [NSAttributedString.Key: Any] = [.font: answerFont, .foregroundColor: SheetStyler.primary]
        let image = NSImage(size: frame.size, flipped: false) { rect in
            (result.formatted as NSString).draw(in: rect, withAttributes: attributes)
            return true
        }
        dragging.setDraggingFrame(frame, contents: image)
        hideActions()
        beginDraggingSession(with: [dragging], event: event, source: dragSource)
    }

    /// The number token under a point, as a range in the text.
    private func numberToken(at point: NSPoint) -> NSRange? {
        let text = string as NSString
        let index = characterIndexForInsertion(at: point)
        guard index <= text.length else { return nil }
        let line = Self.lineIndex(at: index, in: text)
        guard line < syntaxTokens.count else { return nil }
        let lineStart = text.lineRange(for: NSRange(location: min(index, max(text.length - 1, 0)), length: 0)).location
        let local = index - lineStart
        guard let token = syntaxTokens[line].first(where: {
            $0.kind == .number && local >= $0.range.location && local <= NSMaxRange($0.range)
        }) else { return nil }
        let range = NSRange(location: lineStart + token.range.location, length: token.range.length)
        return NSMaxRange(range) <= text.length ? range : nil
    }

    /// ⌘-drag on a number nudges it. Steps follow the number's precision
    /// and size; ⇧ moves ten times as fast. The whole drag is one undo.
    private func beginScrub(at point: NSPoint) -> Bool {
        guard let range = numberToken(at: point) else { return false }
        let original = (string as NSString).substring(with: range)
        let groups = original.contains(" ") || original.contains("\u{00A0}")
        let cleaned = original
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "\u{00A0}", with: "")
            .replacingOccurrences(of: "−", with: "-")
        let grouping = decimalSeparator == "," ? "." : ","
        let normalised = cleaned
            .replacingOccurrences(of: grouping, with: "")
            .replacingOccurrences(of: decimalSeparator, with: ".")
        guard let value = Double(normalised) else { return false }
        let decimals = normalised.split(separator: ".", maxSplits: 1).dropFirst().first?.count ?? 0
        let magnitude = abs(value)
        let step = decimals > 0 ? pow(10, -Double(decimals)) : (magnitude >= 10_000 ? 100 : magnitude >= 1_000 ? 10 : 1)
        scrub = Scrub(range: range, start: value, decimals: decimals, step: step, groups: groups || magnitude >= 10_000, startX: point.x)
        hideActions()
        undoManager?.beginUndoGrouping()
        NSCursor.resizeLeftRight.set()
        return true
    }

    private func continueScrub(to point: NSPoint, faster: Bool) {
        guard var scrub else { return }
        let steps = ((point.x - scrub.startX) / 4).rounded()
        let value = scrub.start + Double(steps) * scrub.step * (faster ? 10 : 1)
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = scrub.decimals
        formatter.maximumFractionDigits = scrub.decimals
        formatter.decimalSeparator = decimalSeparator
        formatter.groupingSeparator = " "
        formatter.usesGroupingSeparator = scrub.groups
        guard let replacement = formatter.string(from: NSNumber(value: value)),
              replacement != (string as NSString).substring(with: scrub.range),
              shouldChangeText(in: scrub.range, replacementString: replacement)
        else { return }
        textStorage?.replaceCharacters(in: scrub.range, with: replacement)
        didChangeText()
        scrub.range.length = replacement.utf16.count
        self.scrub = scrub
        NSCursor.resizeLeftRight.set()
    }

    /// Ticks or unticks a `- [ ]` task when its box is clicked.
    private func toggleCheckbox(at point: NSPoint) -> Bool {
        let text = string as NSString
        let index = characterIndexForInsertion(at: point)
        guard index <= text.length else { return false }
        let lineRange = text.lineRange(for: NSRange(location: min(index, text.length), length: 0))
        let line = text.substring(with: lineRange)
        guard let box = SheetStyler.checkboxRange(in: line) else { return false }
        let boxRange = NSRange(location: lineRange.location + box.location, length: box.length)
        // The insertion index is the nearest caret slot, so a click on the
        // box lands on one of its edges or inside it.
        guard index >= boxRange.location, index <= NSMaxRange(boxRange) else { return false }
        let mark = NSRange(location: boxRange.location + 1, length: 1)
        let replacement = text.substring(with: mark) == " " ? "x" : " "
        replace(mark, with: replacement)
        return true
    }

    // MARK: References and names

    private static let declaredName = try! NSRegularExpression(
        pattern: #"^\s*(?:[-*+]\s+)?([\p{L}][\p{L}\p{N} ]*?)\s*=(?!=)"#
    )

    /// The characters of a line, without its line break.
    private func contentRange(ofLine line: Int) -> NSRange? {
        var found: NSRange?
        enumerateLines { index, content, _ in
            if index == line { found = content }
        }
        return found
    }

    /// Puts a live reference to `line` at the cursor: the variable's name
    /// when the line declares one, otherwise `@name`, adding `^name` to the
    /// line if it has no anchor yet. One undo takes it all back.
    func insertReference(toLine line: Int) {
        let text = string as NSString
        guard let lineRange = contentRange(ofLine: line) else { return }
        var caret = selectedRange()
        if Self.lineIndex(at: caret.location, in: text) == line {
            onMessage?("Put the cursor on another line to refer to this one.")
            return
        }
        let lineText = text.substring(with: lineRange)
        if let match = Self.declaredName.firstMatch(in: lineText, range: NSRange(location: 0, length: (lineText as NSString).length)) {
            insertText((lineText as NSString).substring(with: match.range(at: 1)), replacementRange: caret)
            return
        }
        undoManager?.beginUndoGrouping()
        defer { undoManager?.endUndoGrouping() }
        let name: String
        if let anchor = SheetSyntax.anchor(in: lineText) {
            name = anchor.name
        } else {
            let existing = Set(string.components(separatedBy: "\n").compactMap { SheetSyntax.anchor(in: $0)?.name })
            name = SheetSyntax.suggestedAnchor(for: lineText, existing: existing)
            let anchorText = " ^" + name
            let end = NSRange(location: NSMaxRange(lineRange), length: 0)
            replace(end, with: anchorText)
            if caret.location >= end.location { caret.location += anchorText.utf16.count }
        }
        let reference = "@" + name
        replace(caret, with: reference)
        setSelectedRange(NSRange(location: caret.location + reference.utf16.count, length: 0))
        window?.makeFirstResponder(self)
    }

    /// Turns a line into a variable and selects the name to type over:
    /// `Rent: 8 500 kr` becomes `rent = 8 500 kr`.
    private func nameLine(_ line: Int) {
        let text = string as NSString
        guard let lineRange = contentRange(ofLine: line) else { return }
        let lineText = text.substring(with: lineRange) as NSString
        guard Self.declaredName.firstMatch(in: lineText as String, range: NSRange(location: 0, length: lineText.length)) == nil else {
            onMessage?("This line already has a name.")
            return
        }
        let marker = (lineText as String).range(of: #"^\s*(?:[-*+]|\d+[.)])\s+(?:\[[ xX]\]\s+)?"#, options: .regularExpression)
        let start = marker.map { NSRange($0, in: lineText as String).length } ?? 0
        let rest = lineText.substring(from: start)
        let name: String
        let replaced: NSRange
        if let colon = rest.firstIndex(of: ":"), rest[..<colon].allSatisfy({ $0.isLetter || $0 == " " }), !rest[..<colon].isEmpty {
            name = rest[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            replaced = NSRange(location: lineRange.location + start, length: NSRange(rest.startIndex...colon, in: rest).length)
        } else {
            name = "value"
            replaced = NSRange(location: lineRange.location + start, length: 0)
        }
        let replacement = replaced.length > 0 ? name + " =" : name + " = "
        replace(replaced, with: replacement)
        window?.makeFirstResponder(self)
        setSelectedRange(NSRange(location: replaced.location, length: name.utf16.count))
    }

    /// An edit that goes through undo and tells the delegate.
    private func replace(_ range: NSRange, with replacement: String) {
        guard shouldChangeText(in: range, replacementString: replacement) else { return }
        textStorage?.replaceCharacters(in: range, with: replacement)
        didChangeText()
    }

    // MARK: Completion

    /// Offers the rest of a variable, `@anchor`, keyword or function name
    /// in grey after the caret, for Tab to accept.
    private func updateSuggestion() {
        suggestion = nil
        let selection = selectedRange()
        guard selection.length == 0, !hasMarkedText(), !completionNames.isEmpty else { return }
        let text = string as NSString
        let caret = selection.location
        // Only at the end of a word.
        if caret < text.length, let next = Unicode.Scalar(text.character(at: caret)),
           CharacterSet.alphanumerics.contains(next) {
            return
        }
        let lineStart = text.lineRange(for: NSRange(location: caret, length: 0)).location
        let before = text.substring(with: NSRange(location: lineStart, length: caret - lineStart))
        guard let run = before.range(of: #"@?[\p{L}][\p{L}\p{N} _-]*$"#, options: .regularExpression) else { return }
        // Try the longest run first so multi-word names complete, then
        // shorter tails.
        var candidate = String(before[run])
        while !candidate.isEmpty {
            let prefix = candidate.trimmingCharacters(in: .whitespaces)
            if prefix.count >= 2,
               let name = completionNames.first(where: { $0.count > prefix.count && $0.lowercased().hasPrefix(prefix.lowercased()) }) {
                suggestion = (String(name.dropFirst(prefix.count)), caret)
                return
            }
            guard let space = candidate.firstIndex(of: " ") else { break }
            candidate = String(candidate[candidate.index(after: space)...])
        }
    }

    private func drawSuggestion() {
        guard let suggestion, let layoutManager, let textContainer else { return }
        let text = string as NSString
        guard suggestion.location > 0, suggestion.location <= text.length else { return }
        let glyphs = layoutManager.glyphRange(forCharacterRange: NSRange(location: suggestion.location - 1, length: 1), actualCharacterRange: nil)
        let rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer)
        let font = (textStorage?.attribute(.font, at: suggestion.location - 1, effectiveRange: nil) as? NSFont) ?? SheetStyler.bodyFont
        (suggestion.text as NSString).draw(
            at: NSPoint(x: rect.maxX + textContainerOrigin.x, y: rect.minY + textContainerOrigin.y),
            withAttributes: [.font: font, .foregroundColor: SheetStyler.tertiary]
        )
    }

    // MARK: Helpers

    /// Which line a character offset is on.
    static func lineIndex(at location: Int, in text: NSString) -> Int {
        var count = 0
        var cursor = 0
        let end = min(location, text.length)
        while cursor < end {
            let found = text.range(of: "\n", range: NSRange(location: cursor, length: end - cursor))
            guard found.location != NSNotFound else { break }
            count += 1
            cursor = NSMaxRange(found)
        }
        return count
    }
}
