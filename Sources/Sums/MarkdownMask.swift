//
//  MarkdownMask.swift
//  Sums
//

import Foundation

/// Hides Markdown syntax that SoulverCore would otherwise read as math.
///
/// A sheet is Markdown and a calculator at once, so `- 500` is a list item
/// holding 500, not minus 500. Masked syntax is replaced with spaces rather
/// than removed, so every line keeps its length and its line number.
enum MarkdownMask {
    /// A list marker, numbered or not, and an optional task checkbox.
    private static let listMarker = #"^\s*(?:[-*+]|\d+[.)])\s+(?:\[[ xX]\]\s+)?"#

    /// The text SoulverCore evaluates for a sheet.
    static func calculable(_ text: String) -> String {
        var inCodeFence = false
        return text
            .components(separatedBy: "\n")
            .map { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                    inCodeFence.toggle()
                    return blank(line)
                }
                // Code and tables are never calculated.
                if inCodeFence || trimmed.hasPrefix("|") {
                    return blank(line)
                }
                if let marker = line.range(of: listMarker, options: .regularExpression) {
                    return blank(line[marker]) + line[marker.upperBound...]
                }
                return line
            }
            .joined(separator: "\n")
    }

    private static func blank<S: StringProtocol>(_ text: S) -> String {
        String(repeating: " ", count: text.count)
    }
}
