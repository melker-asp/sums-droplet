//
//  SheetExporter.swift
//  Sums
//

import Foundation

/// Turns a sheet and its answers into text for the pasteboard or a file.
enum SheetExporter {
    enum Format: String, CaseIterable, Identifiable {
        case markdown
        case csv
        case html

        var id: String { rawValue }
        var title: String {
            switch self {
            case .markdown: "Markdown"
            case .csv: "CSV"
            case .html: "HTML"
            }
        }
        var fileExtension: String {
            switch self {
            case .markdown: "md"
            case .csv: "csv"
            case .html: "html"
            }
        }
    }

    /// Each line followed by its answer, for pasting into mail or a report.
    static func plainText(lines: [String], results: [LineResult]) -> String {
        zip(lines, padded(results, to: lines.count))
            .map { line, result in
                result.isEmpty ? line : "\(line) = \(result.formatted)"
            }
            .joined(separator: "\n")
    }

    static func export(
        _ format: Format,
        title: String,
        lines: [String],
        results: [LineResult],
        decimalSeparator: String
    ) -> String {
        let results = padded(results, to: lines.count)
        switch format {
        case .markdown:
            return plainText(lines: lines, results: results)
        case .csv:
            // Spreadsheets in comma-decimal regions expect semicolons.
            let separator = decimalSeparator == "," ? ";" : ","
            let rows = zip(lines, results).map { line, result in
                [csvField(line), csvField(result.formatted)].joined(separator: separator)
            }
            return ([["Line", "Answer"].joined(separator: separator)] + rows).joined(separator: "\n") + "\n"
        case .html:
            let rows = zip(lines, results).map { line, result in
                "<tr><td>\(escape(line))</td><td class=\"answer\">\(escape(result.formatted))</td></tr>"
            }
            return """
            <!doctype html>
            <html><head><meta charset="utf-8"><title>\(escape(title))</title>
            <style>
            body { font: 14px -apple-system, sans-serif; margin: 2em; }
            table { border-collapse: collapse; min-width: 24em; }
            td { padding: 4px 12px; border-bottom: 1px solid #eee; }
            td.answer { text-align: right; font-variant-numeric: tabular-nums; font-weight: 600; }
            </style></head><body>
            <h1>\(escape(title))</h1>
            <table>
            \(rows.joined(separator: "\n"))
            </table>
            </body></html>
            """
        }
    }

    /// A file name that is safe on disk and still recognisable.
    static func fileName(for title: String, format: Format) -> String {
        let cleaned = title
            .components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>"))
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespaces)
        return "\(cleaned.isEmpty ? "Sheet" : cleaned).\(format.fileExtension)"
    }

    private static func padded(_ results: [LineResult], to count: Int) -> [LineResult] {
        results.count >= count ? results : results + Array(repeating: LineResult(formatted: "", raw: ""), count: count - results.count)
    }

    private static func csvField(_ value: String) -> String {
        guard value.contains(where: { ",;\"\n".contains($0) }) else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    private static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
