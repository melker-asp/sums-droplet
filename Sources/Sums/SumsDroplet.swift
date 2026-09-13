//
//  SumsDroplet.swift
//  Sums
//

import AppKit
import Combine
import DroppyKit
import SwiftUI

/// The class Droppy's loader instantiates, named in the bundle's
/// `NSPrincipalClass`. Keep it empty: it runs before the host is ready.
@objc(SumsPrincipal)
public final class SumsPrincipal: NSObject, DropletPrincipal {
    public override init() { super.init() }

    @MainActor public func makeDroplet() -> AnyObject { SumsDroplet() }
}

/// Sums: a notepad calculator on the shelf.
@MainActor
public final class SumsDroplet: NSObject, ObservableObject, Droplet {
    /// Must equal `DroppyDropletID` in the bundle's Info.plist and `id` in
    /// droplet.json. The loader refuses the bundle if the three disagree.
    public nonisolated static let id: DropletID = "sums"
    static let widgetID: ShelfWidgetID = "sums"

    /// The sheet on the shelf. One for now; named sheets come later.
    let sheet = SheetModel()

    /// Bumped to ask the editor to take keyboard focus.
    @Published private(set) var focusRequest = 0

    /// What the editor saw the last time focus moved. Spike diagnostics,
    /// shown in the header until keyboard focus is settled.
    @Published var focusStatus = "not focused yet"

    private var host: DropletHost?

    public func activate(host: DropletHost) throws {
        self.host = host
        sheet.update(text: SheetModel.sample)

        host.shortcuts.register(
            id: "open",
            title: "Open Sums",
            defaultShortcut: DropletKeyboardShortcut(
                keyCode: 1, // S
                modifiers: NSEvent.ModifierFlags([.control, .option]).rawValue
            )
        ) { [weak self] in
            self?.summon()
        }
    }

    public func deactivate() {
        // Everything activate() started is torn down here. The shortcut is
        // unregistered by the host; the hold is ours to release.
        _ = host?.shelf.setHoldsOpen(false)
        host = nil
    }

    /// Opens the shelf on Sums and puts the cursor in the sheet.
    func summon() {
        guard let host else { return }
        let opened = host.shelf.open(revealing: Self.widgetID)
        host.log.info("summon: shelf.open returned \(opened)")
        focusRequest += 1
    }

    /// Copies an answer and says so in the notch.
    func copy(_ result: LineResult) {
        guard let host, host.workspace.copyToPasteboard(result.raw) else { return }
        let shown = result.formatted
        let presented = host.hud.present(
            DropletHUDRequest(id: "sums.copied", duration: 1.5, accessibilityLabel: "Copied \(shown)") {
                HStack(spacing: 0) {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: DroppyLiveActivityMetrics.iconSize, weight: .semibold))
                    Spacer(minLength: 0)
                    Text(verbatim: shown)
                        .font(.system(size: DroppyLiveActivityMetrics.labelFontSize, weight: .semibold))
                        .monospacedDigit()
                }
                .frame(maxWidth: .infinity)
                .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
            }
        )
        host.log.info("copy: hud presented \(presented)")
    }

    /// Keeps the shelf open while the user is typing in the sheet.
    func editorFocusChanged(_ focused: Bool) {
        _ = host?.shelf.setHoldsOpen(focused)
    }
}

// MARK: - Shelf widget

extension SumsDroplet: ShelfWidgetProviding {
    public var widgetDescriptors: [ShelfWidgetDescriptor] {
        [
            ShelfWidgetDescriptor(
                id: Self.widgetID,
                title: "Sums",
                systemImage: "sum",
                layoutTraits: ShelfWidgetLayoutTraits(
                    preferredSoloWidth: 420,
                    preferredPairedWidth: 210,
                    contentHeight: .fixed(170)
                ),
                focusPolicy: .keyboardFocusable,
                searchKeywords: ["calculator", "notepad", "soulver", "math", "vat"]
            )
        ]
    }

    public func makeWidgetView(_ id: ShelfWidgetID, context: ShelfWidgetContext) -> AnyView {
        AnyView(SumsWidget(droplet: self, sheet: sheet, context: context))
    }

    public func makeWidgetSettingsPopover(_ id: ShelfWidgetID) -> AnyView? { nil }
}

// MARK: - HUD

extension SumsDroplet: HUDPresenting {}

/// The widget. Solo is the editor; paired shows the bottom-most answer.
private struct SumsWidget: View {
    @ObservedObject var droplet: SumsDroplet
    @ObservedObject var sheet: SheetModel
    let context: ShelfWidgetContext

    var body: some View {
        VStack(alignment: .leading, spacing: DroppySpacing.sm) {
            header
            if context.isCompact {
                compact
            } else {
                editor
            }
        }
        .padding(context.contentInsets)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var header: some View {
        HStack(spacing: DroppySpacing.xsm) {
            Image(systemName: "sum")
                .font(.system(size: 12, weight: .medium))
            Text("Sums")
                .font(.system(size: 12, weight: .semibold))
            Spacer(minLength: 0)
            if !context.isCompact {
                Text(verbatim: droplet.focusStatus)
                    .font(.system(size: 10))
                    .lineLimit(1)
            }
        }
        .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
    }

    private var editor: some View {
        CalculatorEditor(
            sheet: sheet,
            focusRequest: context.isPreview ? 0 : droplet.focusRequest,
            onCopy: { droplet.copy($0) },
            onFocusChange: { droplet.editorFocusChanged($0) },
            onFocusReport: { droplet.focusStatus = $0 }
        )
    }

    private var compact: some View {
        VStack(alignment: .leading, spacing: DroppySpacing.xs) {
            Text(verbatim: sheet.lastResult?.formatted ?? "–")
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
            Text(verbatim: sheet.lastExpression ?? "Empty sheet")
                .font(.system(size: 11))
                .lineLimit(1)
                .foregroundStyle(AdaptiveColors.notchSurfaceTertiaryText)
        }
    }
}
