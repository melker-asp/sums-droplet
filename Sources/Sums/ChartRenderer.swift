//
//  ChartRenderer.swift
//  Sums
//

import AppKit

/// Draws a chart line's small chart, in the flipped coordinates of the
/// sheet editor.
@MainActor
enum ChartRenderer {
    static func draw(_ spec: ChartSpec, in rect: NSRect) {
        guard spec.points.count >= 2, rect.width > 48, rect.height > 28 else { return }
        let labelHeight: CGFloat = 12
        let plot = NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height - labelHeight - 3)
        let values = spec.points.map(\.value)
        let top = max(values.max() ?? 0, 0)
        let bottom = min(values.min() ?? 0, 0)
        let span = max(top - bottom, .leastNonzeroMagnitude)
        func y(_ value: Double) -> CGFloat {
            plot.minY + CGFloat((top - value) / span) * plot.height
        }
        let slot = plot.width / CGFloat(spec.points.count)
        let positive = SheetStyler.color(for: .number)
        let negative = NSColor(srgbRed: 1.0, green: 0.52, blue: 0.48, alpha: 1)

        switch spec.kind {
        case .bars:
            let width = min(slot * 0.62, 26)
            for (index, point) in spec.points.enumerated() {
                let x = plot.minX + slot * CGFloat(index) + (slot - width) / 2
                let from = y(max(point.value, 0))
                let to = y(min(point.value, 0))
                (point.value < 0 ? negative : positive).setFill()
                NSBezierPath(
                    roundedRect: NSRect(x: x, y: from, width: width, height: max(to - from, 1)),
                    xRadius: 2.5,
                    yRadius: 2.5
                ).fill()
            }
        case .line:
            let path = NSBezierPath()
            path.lineWidth = 1.5
            path.lineJoinStyle = .round
            let centers = spec.points.enumerated().map { index, point in
                NSPoint(x: plot.minX + slot * (CGFloat(index) + 0.5), y: y(point.value))
            }
            for (index, center) in centers.enumerated() {
                index == 0 ? path.move(to: center) : path.line(to: center)
            }
            positive.setStroke()
            path.stroke()
            positive.setFill()
            for center in centers {
                NSBezierPath(ovalIn: NSRect(x: center.x - 2, y: center.y - 2, width: 4, height: 4)).fill()
            }
        }

        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9.5),
            .foregroundColor: SheetStyler.tertiary,
            .paragraphStyle: style
        ]
        for (index, point) in spec.points.enumerated() where !point.label.isEmpty {
            let labelRect = NSRect(x: plot.minX + slot * CGFloat(index), y: plot.maxY + 3, width: slot, height: labelHeight)
            (point.label as NSString).draw(in: labelRect, withAttributes: attributes)
        }
    }
}
