//
//  AnswerActionsBar.swift
//  Sums
//

import AppKit
import DroppyKit
import SwiftUI

/// The small bar that appears beside an answer under the pointer.
struct AnswerActionsBar: View {
    let onCopy: @MainActor () -> Void
    let onCopyWithUnit: @MainActor () -> Void
    let onReference: @MainActor () -> Void
    let onName: @MainActor () -> Void

    var body: some View {
        HStack(spacing: 2) {
            action("doc.on.doc", "Copy the number", onCopy)
            action("textformat.123", "Copy with its unit", onCopyWithUnit)
            action("at", "Refer to this line at the cursor", onReference)
            action("tag", "Name this line", onName)
        }
        .padding(3)
        .background(
            Capsule(style: .continuous)
                .fill(Color.black)
                .overlay(Capsule(style: .continuous).fill(AdaptiveColors.notchSurfaceCardFill))
        )
        .droppyFlatGlassControls()
        .fixedSize()
    }

    private func action(_ systemImage: String, _ label: String, _ perform: @escaping @MainActor () -> Void) -> some View {
        Button(action: perform) {
            Image(systemName: systemImage)
        }
        .buttonStyle(DroppyCircleButtonStyle(size: 20))
        .help(label)
        .accessibilityLabel(label)
    }
}

/// Provides the pasteboard copy operation for an answer dragged out of a
/// sheet. Separate from the text view, whose own drags move text.
@MainActor
final class AnswerDragSource: NSObject, NSDraggingSource {
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }
}
