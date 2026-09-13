//
//  CalculatorEditor.swift
//  Sums
//

import AppKit
import DroppyKit
import SwiftUI

/// What the editor asks of the droplet.
struct EditorActions {
    var textChanged: @MainActor (String) -> Void
    /// The caret location and the lines the selection covers.
    var selectionChanged: @MainActor (Int, IndexSet) -> Void
    var copyAnswer: @MainActor (LineResult) -> Void
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
    let actions: EditorActions

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> NSScrollView {
        let coordinator = context.coordinator
        let textView = SumsTextView(usingTextLayoutManager: false)
        textView.configureForSums()
        textView.delegate = coordinator
        textView.onCopy = { [weak coordinator] in coordinator?.parent.actions.copyAnswer($0) }
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
            // A different sheet: new text, the caret where it was left, and
            // no undo history from the previous sheet.
            coordinator.sheetID = document.sheetID
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
        if textView.results != document.results {
            textView.results = document.results
        }
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
                let first = Self.lineIndex(at: range.location, in: text)
                let last = Self.lineIndex(at: NSMaxRange(range) - 1, in: text)
                lines = IndexSet(integersIn: first...last)
            }
            parent.actions.selectionChanged(range.location, lines)
        }

        private static func lineIndex(at location: Int, in text: NSString) -> Int {
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
}

/// A plain-text view that styles its Markdown, reserves a right-hand column,
/// and draws each line's answer in it, level with the line.
final class SumsTextView: NSTextView {
    var results: [LineResult] = [] {
        didSet {
            resizeAnswerColumn()
            window?.invalidateCursorRects(for: self)
        }
    }
    var onCopy: (@MainActor (LineResult) -> Void)?
    var onFocusChange: (@MainActor (Bool) -> Void)?
    var onBack: (@MainActor () -> Void)?
    var onNewSheet: (@MainActor () -> Void)?

    private let answerFont = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
    private var answerColumnWidth: CGFloat = 64
    private let placeholder = "Type a note or a calculation…"

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

    private var styledText: String?
    private var styledTokens: [[SyntaxToken]] = []

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
        if resigned { onFocusChange?(false) }
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

    private func answer(at point: NSPoint) -> LineResult? {
        var hit: LineResult?
        enumerateAnswers { rect, result in
            if hit == nil, rect.contains(point) { hit = result }
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
        let attributes: [NSAttributedString.Key: Any] = [
            .font: answerFont,
            .foregroundColor: SheetStyler.primary,
            .paragraphStyle: style
        ]
        enumerateAnswers { rect, result in
            guard rect.intersects(dirtyRect) else { return }
            (result.formatted as NSString).draw(in: rect, withAttributes: attributes)
        }
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        enumerateAnswers { rect, _ in
            addCursorRect(rect, cursor: .pointingHand)
        }
    }

    // MARK: Clicks

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let hit = answer(at: point) {
            if event.modifierFlags.contains(.option) {
                // ⌥-click puts the answer where the cursor is.
                insertText(hit.formatted, replacementRange: selectedRange())
            } else {
                onCopy?(hit)
            }
            return
        }
        if toggleCheckbox(at: point) { return }
        super.mouseDown(with: event)
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
        guard shouldChangeText(in: mark, replacementString: replacement) else { return false }
        textStorage?.replaceCharacters(in: mark, with: replacement)
        didChangeText()
        return true
    }
}
