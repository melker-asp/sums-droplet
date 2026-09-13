//
//  SheetStyler.swift
//  Sums
//

import AppKit
import DroppyKit
import SwiftUI

/// What a stretch of a calculating line means, for colouring.
enum SyntaxKind: Equatable {
    case number
    case operatorSymbol
    case unit
    case variable
    case function
    case date
    /// Words Sums itself understands: `total`, `average`, `prev`.
    case keyword
}

/// A coloured stretch of one line.
struct SyntaxToken: Equatable {
    /// UTF-16 range within the line.
    let range: NSRange
    let kind: SyntaxKind
}

/// Paints a worksheet: Markdown styling for the whole text, then syntax
/// colours on the lines that calculate. Markdown marks stay visible but dim,
/// so what you see is exactly what is saved.
@MainActor
enum SheetStyler {
    static let bodyFont = NSFont.systemFont(ofSize: 13)
    static let codeFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

    static let primary = NSColor(AdaptiveColors.notchSurfacePrimaryText)
    static let secondary = NSColor(AdaptiveColors.notchSurfaceSecondaryText)
    static let tertiary = NSColor(AdaptiveColors.notchSurfaceTertiaryText)
    static let codeFill = NSColor(AdaptiveColors.notchSurfaceCardFill)
    static let highlightFill = NSColor.systemYellow.withAlphaComponent(0.32)

    static func color(for kind: SyntaxKind) -> NSColor {
        switch kind {
        case .number: NSColor(srgbRed: 0.56, green: 0.79, blue: 1.00, alpha: 1)
        case .operatorSymbol: NSColor.white.withAlphaComponent(0.55)
        case .unit: NSColor(srgbRed: 0.47, green: 0.86, blue: 0.76, alpha: 1)
        case .variable: NSColor(srgbRed: 1.00, green: 0.76, blue: 0.47, alpha: 1)
        case .function: NSColor(srgbRed: 0.80, green: 0.67, blue: 1.00, alpha: 1)
        case .date: NSColor(srgbRed: 0.62, green: 0.90, blue: 0.57, alpha: 1)
        case .keyword: NSColor(srgbRed: 1.00, green: 0.60, blue: 0.70, alpha: 1)
        }
    }

    /// Attributes for text the user is about to type.
    static var typingAttributes: [NSAttributedString.Key: Any] {
        [.font: bodyFont, .foregroundColor: primary, .paragraphStyle: paragraphStyle]
    }

    private static let paragraphStyle: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 2
        return style
    }()

    private static let heading = try! NSRegularExpression(pattern: #"^(#{1,6})\s"#)
    private static let listMarker = try! NSRegularExpression(pattern: #"^\s*(?:[-*+]|\d+[.)])\s+"#)
    private static let checkbox = try! NSRegularExpression(pattern: #"^\s*[-*+]\s+(\[( |x|X)\])"#)
    private static let rule = try! NSRegularExpression(pattern: #"^\s*([-*_])(\s*\1){2,}\s*$"#)
    private static let inlineCode = try! NSRegularExpression(pattern: #"`([^`]+)`"#)
    private static let bold = try! NSRegularExpression(pattern: #"(\*\*|__)(?=\S)(.+?)(?<=\S)\1"#)
    private static let italic = try! NSRegularExpression(
        pattern: #"(?<![\w*])\*(?![\s*])(.+?)(?<![\s*])\*(?![\w*])|(?<![\w_])_(?![\s_])(.+?)(?<![\s_])_(?![\w_])"#
    )
    private static let strike = try! NSRegularExpression(pattern: #"~~(?=\S)(.+?)(?<=\S)~~"#)
    private static let highlight = try! NSRegularExpression(pattern: #"==(?=\S)(.+?)(?<=\S)=="#)

    /// Restyles the whole text. `tokens[i]` colours line `i`.
    static func apply(to storage: NSTextStorage, tokens: [[SyntaxToken]]) {
        // Work on a native copy. The storage's string is bridged from
        // Objective-C, and every Swift string operation on a bridged string
        // takes a slow path; styling a sheet that way froze the shelf.
        var text = storage.string
        text.makeContiguousUTF8()
        let length = storage.length

        storage.beginEditing()
        storage.setAttributes(typingAttributes, range: NSRange(location: 0, length: length))

        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var offset = 0
        var inCodeFence = false
        for (lineIndex, line) in lines.enumerated() {
            let content = NSRange(location: offset, length: line.utf16.count)
            offset = NSMaxRange(content) + 1
            guard NSMaxRange(content) <= length else { break }
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                inCodeFence.toggle()
                storage.addAttributes([.font: codeFont, .foregroundColor: tertiary], range: content)
            } else if inCodeFence {
                storage.addAttributes([.font: codeFont, .foregroundColor: secondary], range: content)
            } else if SheetSyntax.isTableLine(line) {
                let isHeader = lineIndex + 1 < lines.count && SheetSyntax.isTableSeparator(lines[lineIndex + 1])
                styleTableRow(line, at: content.location, isHeader: isHeader, in: storage)
                styleInline(line, at: content.location, in: storage)
            } else {
                styleLine(line, at: content.location, in: storage)
                if lineIndex < tokens.count {
                    for token in tokens[lineIndex] where NSMaxRange(token.range) <= content.length {
                        let range = NSRange(location: content.location + token.range.location, length: token.range.length)
                        storage.addAttribute(.foregroundColor, value: color(for: token.kind), range: range)
                    }
                }
                styleInline(line, at: content.location, in: storage)
                styleSheetSyntax(line, at: content.location, in: storage)
            }
        }
        storage.endEditing()
    }

    /// How tall a chart line is, leaving room for the chart beside its words.
    static let chartLineHeight: CGFloat = 76

    // MARK: Sums syntax

    /// Anchors fade into the margin; references read as chips; a chart line
    /// makes room for its chart.
    private static func styleSheetSyntax(_ line: String, at offset: Int, in storage: NSTextStorage) {
        func global(_ range: NSRange) -> NSRange { NSRange(location: offset + range.location, length: range.length) }
        if let anchor = SheetSyntax.anchor(in: line) {
            storage.addAttributes([.foregroundColor: tertiary, .font: NSFont.systemFont(ofSize: 11)], range: global(anchor.range))
        }
        let keyword = color(for: .keyword)
        for reference in SheetSyntax.references(in: line) {
            storage.addAttributes([
                .foregroundColor: keyword,
                .backgroundColor: keyword.withAlphaComponent(0.16)
            ], range: global(reference.range))
        }
        if SheetSyntax.chartKind(of: line) != nil {
            let style = NSMutableParagraphStyle()
            style.lineSpacing = 2
            style.minimumLineHeight = chartLineHeight
            storage.addAttributes([
                .paragraphStyle: style,
                .foregroundColor: keyword
            ], range: global(NSRange(location: 0, length: (line as NSString).length)))
        }
    }

    /// Pipes fade, the header row is bold, and a statistic row's keyword is
    /// coloured like `total` elsewhere.
    private static func styleTableRow(_ line: String, at offset: Int, isHeader: Bool, in storage: NSTextStorage) {
        let text = line as NSString
        let whole = NSRange(location: offset, length: text.length)
        if SheetSyntax.isTableSeparator(line) {
            storage.addAttribute(.foregroundColor, value: tertiary, range: whole)
            return
        }
        if isHeader {
            storage.addAttribute(.font, value: NSFont.systemFont(ofSize: 13, weight: .semibold), range: whole)
        }
        var search = NSRange(location: 0, length: text.length)
        while true {
            let pipe = text.range(of: "|", range: search)
            guard pipe.location != NSNotFound else { break }
            storage.addAttribute(.foregroundColor, value: tertiary, range: NSRange(location: offset + pipe.location, length: 1))
            search = NSRange(location: NSMaxRange(pipe), length: text.length - NSMaxRange(pipe))
        }
        if let first = SheetSyntax.cells(of: line).first, Aggregate.statistic(named: first) != nil {
            let word = text.range(of: first)
            if word.location != NSNotFound {
                storage.addAttribute(.foregroundColor, value: color(for: .keyword), range: NSRange(location: offset + word.location, length: word.length))
            }
        }
    }

    // MARK: Block styles

    private static func styleLine(_ line: String, at offset: Int, in storage: NSTextStorage) {
        let whole = NSRange(location: 0, length: (line as NSString).length)
        func global(_ range: NSRange) -> NSRange { NSRange(location: offset + range.location, length: range.length) }

        if let match = heading.firstMatch(in: line, range: whole) {
            let level = match.range(at: 1).length
            let size: CGFloat = level == 1 ? 16 : level == 2 ? 14.5 : 13
            storage.addAttribute(.font, value: NSFont.systemFont(ofSize: size, weight: .semibold), range: global(whole))
            storage.addAttribute(.foregroundColor, value: tertiary, range: global(match.range(at: 1)))
            return
        }
        if rule.firstMatch(in: line, range: whole) != nil {
            storage.addAttribute(.foregroundColor, value: tertiary, range: global(whole))
            return
        }
        if line.trimmingCharacters(in: .whitespaces).hasPrefix(">") {
            storage.addAttribute(.foregroundColor, value: secondary, range: global(whole))
            storage.addAttribute(.font, value: NSFontManager.shared.convert(bodyFont, toHaveTrait: .italicFontMask), range: global(whole))
            return
        }
        if let marker = listMarker.firstMatch(in: line, range: whole) {
            storage.addAttribute(.foregroundColor, value: tertiary, range: global(marker.range))
        }
        if let box = checkbox.firstMatch(in: line, range: whole) {
            storage.addAttribute(.foregroundColor, value: tertiary, range: global(box.range(at: 1)))
            if box.range(at: 2).length == 1, (line as NSString).substring(with: box.range(at: 2)) != " " {
                let rest = NSRange(location: NSMaxRange(box.range), length: whole.length - NSMaxRange(box.range))
                storage.addAttributes([
                    .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                    .foregroundColor: tertiary
                ], range: global(rest))
            }
        }
    }

    // MARK: Inline styles

    private static func styleInline(_ line: String, at offset: Int, in storage: NSTextStorage) {
        let whole = NSRange(location: 0, length: (line as NSString).length)
        func global(_ range: NSRange) -> NSRange { NSRange(location: offset + range.location, length: range.length) }
        func dimMarks(_ match: NSTextCheckingResult, markLength: Int) {
            let range = match.range
            storage.addAttribute(.foregroundColor, value: tertiary, range: global(NSRange(location: range.location, length: markLength)))
            storage.addAttribute(.foregroundColor, value: tertiary, range: global(NSRange(location: NSMaxRange(range) - markLength, length: markLength)))
        }
        func addTrait(_ trait: NSFontTraitMask, to range: NSRange) {
            let target = global(range)
            storage.enumerateAttribute(.font, in: target) { value, subrange, _ in
                let font = (value as? NSFont) ?? bodyFont
                storage.addAttribute(.font, value: NSFontManager.shared.convert(font, toHaveTrait: trait), range: subrange)
            }
        }

        for match in bold.matches(in: line, range: whole) {
            addTrait(.boldFontMask, to: match.range)
            dimMarks(match, markLength: 2)
        }
        for match in italic.matches(in: line, range: whole) {
            addTrait(.italicFontMask, to: match.range)
            dimMarks(match, markLength: 1)
        }
        for match in strike.matches(in: line, range: whole) {
            storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: global(match.range))
            dimMarks(match, markLength: 2)
        }
        for match in highlight.matches(in: line, range: whole) {
            storage.addAttribute(.backgroundColor, value: highlightFill, range: global(match.range(at: 1)))
            dimMarks(match, markLength: 2)
        }
        for match in inlineCode.matches(in: line, range: whole) {
            storage.addAttributes([
                .font: codeFont,
                .foregroundColor: secondary,
                .backgroundColor: codeFill
            ], range: global(match.range))
        }
    }

    /// The range of a line's task checkbox, `[ ]` or `[x]`, in line-local
    /// UTF-16 offsets.
    static func checkboxRange(in line: String) -> NSRange? {
        checkbox.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length))?.range(at: 1)
    }
}
