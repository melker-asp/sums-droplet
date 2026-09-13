//
//  FullSheetView.swift
//  Sums
//

import DroppyKit
import SwiftUI

/// Full-sheet mode: the notch area taken over by the sheet list and the
/// editor side by side, for longer work.
struct FullSheetView: View {
    @ObservedObject var droplet: SumsDroplet
    @ObservedObject var store: SheetStore
    @ObservedObject var document: SheetDocument
    let isPreview: Bool

    var body: some View {
        HStack(alignment: .top, spacing: DroppySpacing.lg) {
            sidebar
                .frame(width: 200)
            Group {
                if document.sheetID != nil {
                    SheetEditorView(droplet: droplet, store: store, document: document, isPreview: isPreview, isExpanded: true)
                } else {
                    VStack(spacing: DroppySpacing.sm) {
                        Text("No sheet is open.")
                            .font(.system(size: 12))
                            .foregroundStyle(AdaptiveColors.notchSurfaceTertiaryText)
                        Button("New sheet") { droplet.createSheet(from: nil) }
                            .buttonStyle(DroppyAccentButtonStyle(size: .small))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: DroppySpacing.xs) {
            HStack(spacing: DroppySpacing.xsm) {
                Image(systemName: "sum")
                    .font(.system(size: 12, weight: .medium))
                Text("Sheets")
                    .font(.system(size: 12, weight: .semibold))
                Spacer(minLength: 0)
                Button {
                    droplet.createSheet(from: nil)
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(DroppyCircleButtonStyle(size: 20))
                .help("New sheet")
                .accessibilityLabel("New sheet")
            }
            .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
            .frame(height: 20)

            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(store.active) { sheet in
                        SidebarRow(
                            title: store.displayTitle(sheet.id),
                            summary: droplet.summary(for: sheet.id)?.formatted,
                            isShared: sheet.isShared == true,
                            isSelected: document.sheetID == sheet.id
                        ) {
                            droplet.open(sheet.id)
                        }
                    }
                }
            }
        }
    }
}

private struct SidebarRow: View {
    let title: String
    let summary: String?
    let isShared: Bool
    let isSelected: Bool
    let onTap: @MainActor () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: DroppySpacing.xsm) {
            if isShared {
                Image(systemName: "globe")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(AdaptiveColors.notchSurfaceTertiaryText)
            }
            Text(title)
                .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
                .lineLimit(1)
            Spacer(minLength: DroppySpacing.xs)
            if let summary {
                Text(summary)
                    .font(.system(size: 11, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(AdaptiveColors.notchSurfaceTertiaryText)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, DroppySpacing.sm)
        .padding(.vertical, DroppySpacing.xsm)
        .background(
            RoundedRectangle(cornerRadius: DroppyRadius.small, style: .continuous)
                .fill(isSelected || isHovering ? AdaptiveColors.notchSurfaceCardFill : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
        .onHover { isHovering = $0 }
    }
}
