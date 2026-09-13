//
//  SumsDroplet.swift
//  Sums
//

import AppKit
import Combine
import DroppyKit
import SoulverCore
import SwiftUI

/// The class Droppy's loader instantiates, named in the bundle's
/// `NSPrincipalClass`. Keep it empty: it runs before the host is ready.
@objc(SumsPrincipal)
public final class SumsPrincipal: NSObject, DropletPrincipal {
    public override init() { super.init() }

    @MainActor public func makeDroplet() -> AnyObject { SumsDroplet() }
}

/// Sums: worksheets that calculate as you type, on the shelf.
@MainActor
public final class SumsDroplet: NSObject, ObservableObject, Droplet {
    /// Must equal `DroppyDropletID` in the bundle's Info.plist and `id` in
    /// droplet.json. The loader refuses the bundle if the three disagree.
    public nonisolated static let id: DropletID = "sums"
    static let widgetID: ShelfWidgetID = "sums"

    enum Route: Equatable {
        case list
        case sheet(UUID)
        case newSheet
        case trash
    }

    /// A short message at the bottom of the card, optionally undoable.
    struct Toast: Equatable {
        let id = UUID()
        let message: String
        var undoSheetID: UUID?
    }

    @Published var route: Route = .list
    @Published private(set) var settings = SumsSettings()
    /// Bumped to put the cursor in the sheet editor.
    @Published private(set) var focusRequest = 0
    /// Bumped to put the cursor in the sheet's title.
    @Published private(set) var titleFocusRequest = 0
    @Published private(set) var toast: Toast?

    let store = SheetStore()
    let document = SheetDocument()

    private var host: DropletHost?
    private var lastOpenedID: UUID?
    private let summaryEngine = SheetEngine()
    private var summaries: [UUID: (text: String, summary: LineResult?)] = [:]
    private var toastTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()
    private let lockScreenSubject = CurrentValueSubject<LockScreenStatusEntry?, Never>(nil)
    /// Live rates from the European Central Bank, refreshed while Sums runs.
    private let currencyRates = ECBCurrencyRateProvider()
    private var hasLiveRates = false
    private var ratesTask: Task<Void, Never>?
    /// Set when a shared sheet changed, so the next navigation recomputes
    /// the variables every sheet sees.
    private var globalsAreStale = false
    /// The one-line calculator a shortcut opens in the notch.
    let quickCalc = QuickCalc()
    private var quickCalcPresentation: ExpandedSurfacePresentation?
    private var fullSheetPresentation: ExpandedSurfacePresentation?

    private static let lastOpenedKey = "lastOpenedSheetID"
    private static let quickCalcHistoryKey = "quickCalcHistory"

    // MARK: Lifecycle

    public func activate(host: DropletHost) throws {
        self.host = host
        settings = SumsSettings.load(from: host.preferences)
        lastOpenedID = host.preferences.value(forKey: Self.lastOpenedKey, as: String.self).flatMap(UUID.init(uuidString:))

        let folder = host.environment.containerDirectory.appendingPathComponent("Sheets", isDirectory: true)
        if store.load(directory: folder) {
            let guide = createSheet(from: Templates.quickGuide, opening: false)
            lastOpenedID = guide.id
        }
        applyEngineConfiguration()
        startRatesUpdates()
        quickCalc.restore(history: host.preferences.value(forKey: Self.quickCalcHistoryKey, as: [String].self) ?? [])
        if settings.opensLastSheet, let id = liveSheet(lastOpenedID) {
            open(id, focus: false)
        } else {
            route = .list
        }

        let modifiers = NSEvent.ModifierFlags([.control, .option]).rawValue
        host.shortcuts.register(
            id: "open",
            title: "Open Sums",
            defaultShortcut: DropletKeyboardShortcut(keyCode: 1, modifiers: modifiers) // S
        ) { [weak self] in
            self?.summon()
        }
        host.shortcuts.register(
            id: "new-quick-calc",
            title: "New quick calc",
            defaultShortcut: DropletKeyboardShortcut(keyCode: 45, modifiers: modifiers) // N
        ) { [weak self] in
            self?.newQuickCalc()
        }
        host.shortcuts.register(
            id: "quick-calc",
            title: "Quick calc in the notch",
            defaultShortcut: DropletKeyboardShortcut(keyCode: 49, modifiers: modifiers) // Space
        ) { [weak self] in
            self?.presentQuickCalc()
        }

        store.$revision
            .sink { [weak self] _ in self?.publishLockScreen() }
            .store(in: &cancellables)
        publishLockScreen()
    }

    public func deactivate() {
        // Everything activate() started is torn down here. The shortcuts are
        // unregistered by the host; the rest is ours.
        store.flush()
        toastTask?.cancel()
        toastTask = nil
        ratesTask?.cancel()
        ratesTask = nil
        // The host takes presented surfaces down with the droplet.
        quickCalcPresentation = nil
        fullSheetPresentation = nil
        cancellables.removeAll()
        lockScreenSubject.send(nil)
        _ = host?.shelf.setHoldsOpen(false)
        host = nil
    }

    // MARK: Navigation

    func open(_ id: UUID, focus: Bool = true) {
        guard liveSheet(id) != nil else { return }
        refreshGlobalsIfStale()
        document.open(id, text: store.text(id))
        route = .sheet(id)
        lastOpenedID = id
        host?.preferences.setValue(id.uuidString, forKey: Self.lastOpenedKey)
        if focus { focusRequest += 1 }
        publishLockScreen()
    }

    func showList() {
        document.close()
        refreshGlobalsIfStale()
        route = .list
        _ = host?.shelf.setHoldsOpen(false)
    }

    func showNewSheet() {
        route = .newSheet
    }

    func showTrash() {
        route = .trash
    }

    func focusEditor() {
        focusRequest += 1
    }

    /// Opens the sheet and puts the cursor in its title.
    func beginRename(_ id: UUID) {
        open(id, focus: false)
        titleFocusRequest += 1
    }

    /// The global shortcut: the shelf opens on Sums, ready to type.
    func summon() {
        guard let host else { return }
        if case .sheet = route {
            // Stay on the sheet that is open.
        } else if settings.opensLastSheet, let id = liveSheet(lastOpenedID) {
            open(id, focus: false)
        }
        _ = host.shelf.open(revealing: Self.widgetID)
        focusRequest += 1
    }

    /// A blank sheet, open and ready to type in, from anywhere.
    func newQuickCalc() {
        createSheet(from: nil)
        _ = host?.shelf.open(revealing: Self.widgetID)
    }

    // MARK: Sheets

    @discardableResult
    func createSheet(from template: SheetTemplate?, opening: Bool = true) -> SheetInfo {
        let text = template?.text(decimalSeparator: settings.numberFormat.decimalSeparator) ?? ""
        let sheet = store.create(title: template?.title ?? "", text: text)
        if opening { open(sheet.id) }
        return sheet
    }

    func editorChanged(_ text: String) {
        guard let id = document.sheetID else { return }
        document.update(text)
        store.updateText(id, text)
        if store.sheet(id)?.isShared == true { globalsAreStale = true }
    }

    /// Shares a sheet's variables with every other sheet, or stops.
    func toggleShared(_ id: UUID) {
        let wasShared = store.sheet(id)?.isShared == true
        store.setShared(id, !wasShared)
        applyEngineConfiguration()
        showToast(wasShared ? "This sheet's variables are its own again" : "Every sheet can now use these variables")
    }

    /// Writes a new value into the line an input field belongs to.
    func setInput(line lineIndex: Int, to value: String) {
        guard let id = document.sheetID,
              let input = document.inputs.first(where: { $0.lineIndex == lineIndex })
        else { return }
        var lines = document.lines
        guard lines.indices.contains(lineIndex) else { return }
        let line = lines[lineIndex] as NSString
        guard NSMaxRange(input.valueRange) <= line.length else { return }
        lines[lineIndex] = line.replacingCharacters(in: input.valueRange, with: value)
        let text = lines.joined(separator: "\n")
        document.update(text)
        store.updateText(id, text)
    }

    func selectionChanged(location: Int, lines: IndexSet) {
        if let id = document.sheetID { store.rememberSelection(id, location) }
        document.select(lines: lines)
    }

    func rename(_ id: UUID, to title: String) {
        store.rename(id, to: title)
    }

    func duplicate(_ id: UUID) {
        if let copy = store.duplicate(id) { open(copy.id) }
    }

    func togglePin(_ id: UUID) {
        updateSettings { $0.pinnedSheetID = $0.pinnedSheetID == id ? nil : id }
    }

    func delete(_ id: UUID) {
        let title = store.displayTitle(id)
        store.moveToTrash(id)
        if document.sheetID == id { showList() }
        if settings.pinnedSheetID == id { updateSettings { $0.pinnedSheetID = nil } }
        showToast("Deleted “\(title)”", undo: id)
        publishLockScreen()
    }

    func restore(_ id: UUID) {
        store.restore(id)
        if store.recentlyDeleted.isEmpty, route == .trash { route = .list }
    }

    func deletePermanently(_ id: UUID) {
        store.deletePermanently(id)
        if store.recentlyDeleted.isEmpty, route == .trash { route = .list }
    }

    func emptyTrash() {
        for sheet in store.recentlyDeleted { store.deletePermanently(sheet.id) }
        route = .list
    }

    // MARK: Answers

    /// A sheet's bottom-most answer, cached until its text changes.
    func summary(for id: UUID) -> LineResult? {
        let text = store.text(id)
        if let cached = summaries[id], cached.text == text { return cached.summary }
        summaryEngine.evaluate(text)
        let summary = summaryEngine.summary
        summaries[id] = (text, summary)
        return summary
    }

    /// The sheet the compact card and the lock screen show: the pinned one,
    /// else the last one opened, else the newest.
    var pinnedSheetID: UUID? {
        liveSheet(settings.pinnedSheetID) ?? liveSheet(lastOpenedID) ?? store.active.first?.id
    }

    /// Copies an answer. Raw, so it pastes into a spreadsheet as a number.
    func copy(_ result: LineResult) {
        guard let host, host.workspace.copyToPasteboard(result.raw) else { return }
        showToast("Copied \(result.formatted)")
    }

    /// Copies text exactly as shown, such as an answer with its unit.
    func copyText(_ text: String, message: String) {
        guard let host, host.workspace.copyToPasteboard(text) else { return }
        showToast(message)
    }

    func copySheet() {
        guard let host else { return }
        let text = SheetExporter.plainText(lines: document.lines, results: document.results)
        guard host.workspace.copyToPasteboard(text) else { return }
        showToast("Copied the sheet with its answers")
    }

    /// The compact card's click: copy its answer and say so in the notch.
    func copyPinnedSummary() {
        guard let host, let id = pinnedSheetID, let summary = summary(for: id),
              host.workspace.copyToPasteboard(summary.raw)
        else { return }
        presentCopiedHUD(summary.formatted)
    }

    /// "Copied" in the notch: the glyph at one edge, the value at the other.
    private func presentCopiedHUD(_ shown: String) {
        _ = host?.hud.present(
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
    }

    /// Writes the open sheet to a file in the droplet's Exports folder and
    /// shows it in Finder.
    func export(_ format: SheetExporter.Format) {
        guard let host, let id = document.sheetID else { return }
        let title = store.displayTitle(id)
        let contents = SheetExporter.export(
            format,
            title: title,
            lines: document.lines,
            results: document.results,
            decimalSeparator: settings.numberFormat.decimalSeparator
        )
        let folder = host.environment.containerDirectory.appendingPathComponent("Exports", isDirectory: true)
        let url = folder.appendingPathComponent(SheetExporter.fileName(for: title, format: format))
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try contents.write(to: url, atomically: true, encoding: .utf8)
            host.workspace.revealInFinder(url)
            showToast("Exported \(url.lastPathComponent)")
        } catch {
            host.log.info("export failed: \(error.localizedDescription)")
            showToast("Could not export the sheet")
        }
    }

    func revealSheetsFolder() {
        host?.workspace.revealInFinder(store.folder)
    }

    /// Keeps the shelf open while the user is typing in Sums.
    func editorFocusChanged(_ focused: Bool) {
        _ = host?.shelf.setHoldsOpen(focused)
    }

    // MARK: Toasts

    func showToast(_ message: String, undo sheetID: UUID? = nil) {
        toast = Toast(message: message, undoSheetID: sheetID)
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }

    func undoToast() {
        if let id = toast?.undoSheetID { store.restore(id) }
        toast = nil
        publishLockScreen()
    }

    // MARK: Settings

    func binding<Value>(_ keyPath: WritableKeyPath<SumsSettings, Value>) -> Binding<Value> {
        Binding(
            get: { self.settings[keyPath: keyPath] },
            set: { value in self.updateSettings { $0[keyPath: keyPath] = value } }
        )
    }

    func updateSettings(_ change: (inout SumsSettings) -> Void) {
        var updated = settings
        change(&updated)
        guard updated != settings else { return }
        let ratesChanged = updated.usesLiveRates != settings.usesLiveRates
        settings = updated
        if let host { updated.save(to: host.preferences) }
        if ratesChanged { startRatesUpdates() }
        applyEngineConfiguration()
    }

    // MARK: Engine configuration

    /// Pushes settings, live rates and shared variables into every engine.
    private func applyEngineConfiguration() {
        let rates: (any CurrencyRateProvider)? = settings.usesLiveRates && hasLiveRates ? currencyRates : nil
        let globals = sharedVariables()
        document.configure(settings, currencyRates: rates, globals: globals)
        summaryEngine.configure(settings, currencyRates: rates)
        summaryEngine.setGlobals(globals)
        quickCalc.configure(settings, currencyRates: rates, globals: globals)
        summaries.removeAll()
        globalsAreStale = false
        publishLockScreen()
    }

    private func refreshGlobalsIfStale() {
        if globalsAreStale { applyEngineConfiguration() }
    }

    /// The variables declared in shared sheets, with their answers.
    private func sharedVariables() -> [(name: String, value: String)] {
        let engine = SheetEngine(settings: settings)
        var variables: [(name: String, value: String)] = []
        for sheet in store.shared {
            engine.evaluate(store.text(sheet.id))
            variables += engine.declarations
        }
        return variables
    }

    /// Fetches rates now and every six hours while live rates are on.
    private func startRatesUpdates() {
        ratesTask?.cancel()
        ratesTask = nil
        guard settings.usesLiveRates else {
            hasLiveRates = false
            return
        }
        ratesTask = Task { [weak self, currencyRates] in
            while !Task.isCancelled {
                let updated = await currencyRates.updateRates()
                guard !Task.isCancelled, let self else { return }
                if updated {
                    self.hasLiveRates = true
                    self.applyEngineConfiguration()
                }
                try? await Task.sleep(for: .seconds(6 * 60 * 60))
            }
        }
    }

    // MARK: Lock screen

    private func publishLockScreen() {
        guard settings.showsOnLockScreen, let id = pinnedSheetID, let summary = summary(for: id) else {
            lockScreenSubject.send(nil)
            return
        }
        lockScreenSubject.send(
            LockScreenStatusEntry(id: "sums.pinned", systemImage: "sum", text: summary.formatted, detail: store.displayTitle(id))
        )
    }

    private func liveSheet(_ id: UUID?) -> UUID? {
        guard let id, let sheet = store.sheet(id), sheet.deleted == nil else { return nil }
        return id
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
                    preferredSoloWidth: 440,
                    preferredPairedWidth: 210,
                    contentHeight: .fixed(230)
                ),
                focusPolicy: .keyboardFocusable,
                searchKeywords: ["calculator", "notepad", "soulver", "math", "vat", "worksheet"]
            )
        ]
    }

    public func makeWidgetView(_ id: ShelfWidgetID, context: ShelfWidgetContext) -> AnyView {
        AnyView(SumsWidget(droplet: self, store: store, document: document, context: context))
    }

    public func makeWidgetSettingsPopover(_ id: ShelfWidgetID) -> AnyView? { nil }
}

// MARK: - Other surfaces

extension SumsDroplet: HUDPresenting {}

extension SumsDroplet: SettingsPaneProviding {
    public func makeSettingsPane(context: SettingsPaneContext) -> AnyView {
        AnyView(SumsSettingsPane(droplet: self, store: store))
    }

    public var settingsSearchEntries: [SettingsSearchEntry] {
        [
            SettingsSearchEntry(title: "Number format", keywords: ["decimal", "comma", "thousands", "locale"]),
            SettingsSearchEntry(title: "Decimal places", keywords: ["rounding", "decimals"]),
            SettingsSearchEntry(title: "Pinned sheet", keywords: ["compact", "card"]),
            SettingsSearchEntry(title: "Show on the lock screen", keywords: ["lock screen", "total"])
        ]
    }
}

extension SumsDroplet: LockScreenStatusProviding {
    public var lockScreenStatus: AnyPublisher<LockScreenStatusEntry?, Never> {
        lockScreenSubject.eraseToAnyPublisher()
    }
}

// MARK: - Notch surfaces

extension SumsDroplet: ExpandedSurfaceHosting {
    public var expandedSurfaceProvider: (any ExpandedSurfaceProviding)? { self }
}

extension SumsDroplet: ExpandedSurfaceProviding {
    static let quickCalcSurface: ExpandedSurfaceID = "quick-calc"
    static let fullSheetSurface: ExpandedSurfaceID = "full-sheet"

    public var expandedSurfaces: [ExpandedSurfaceDescriptor] {
        [
            ExpandedSurfaceDescriptor(
                id: Self.quickCalcSurface,
                title: "Quick calc",
                systemImage: "sum",
                suppresses: [.shelfWidgets, .notificationBanners]
            ),
            ExpandedSurfaceDescriptor(
                id: Self.fullSheetSurface,
                title: "Sums",
                systemImage: "sum",
                // Longer work: nothing else on the shelf, and it stays put
                // when the pointer wanders. A click outside still closes it.
                suppresses: [.shelfWidgets, .favoritesBar, .floatingNavLane, .notificationBanners, .autoCollapse]
            )
        ]
    }

    public func makeExpandedSurfaceView(_ id: ExpandedSurfaceID, context: ExpandedSurfaceContext) -> AnyView {
        switch id {
        case Self.quickCalcSurface:
            return AnyView(QuickCalcView(
                model: quickCalc,
                isPreview: context.isPreview,
                onCopy: { [weak self] in self?.quickCalcCopy() },
                onAddToSheet: { [weak self] in self?.quickCalcAddToSheet() },
                onClose: { [weak self] in self?.closeQuickCalc() }
            ))
        case Self.fullSheetSurface:
            return AnyView(FullSheetView(droplet: self, store: store, document: document, isPreview: context.isPreview))
        default:
            return AnyView(EmptyView())
        }
    }

    public func expandedSurfaceSize(_ id: ExpandedSurfaceID, fitting proposal: ExpandedSurfaceSizeProposal) -> CGSize? {
        switch id {
        case Self.quickCalcSurface:
            return CGSize(width: max(proposal.standardSize.width, 480), height: 58)
        case Self.fullSheetSurface:
            return CGSize(width: min(proposal.maximumSize.width, 880), height: min(proposal.maximumSize.height, 520))
        default:
            return nil
        }
    }

    public func expandedSurfaceDidDismiss(
        _ id: ExpandedSurfaceID,
        presentation: ExpandedSurfacePresentation,
        reason: ExpandedSurfaceDismissalReason
    ) {
        // Compared by presentation, not surface: a late teardown must not
        // clear a surface the user has already summoned again.
        if presentation.id == quickCalcPresentation?.id {
            quickCalcPresentation = nil
            quickCalc.reset()
        }
        if presentation.id == fullSheetPresentation?.id {
            fullSheetPresentation = nil
            _ = host?.shelf.setHoldsOpen(false)
        }
    }

    // MARK: Quick calc

    /// The shortcut: a one-line calculator in the notch, ready to type in.
    func presentQuickCalc() {
        guard let host else { return }
        quickCalc.reset()
        quickCalcPresentation = host.notchSurface.presentExpandedSurface(
            ExpandedSurfacePresentationRequest(surfaceID: Self.quickCalcSurface, opensShelf: true)
        )
        if quickCalcPresentation == nil { host.log.info("quick calc: the host refused the surface") }
    }

    /// ⏎: copies the answer as a plain number and closes.
    func quickCalcCopy() {
        guard let host, let result = quickCalc.result, host.workspace.copyToPasteboard(result.raw) else { return }
        rememberQuickCalc()
        closeQuickCalc()
        presentCopiedHUD(result.formatted)
    }

    /// ⇥: adds the calculation to the last sheet and closes.
    func quickCalcAddToSheet() {
        let calculation = quickCalc.input.trimmingCharacters(in: .whitespaces)
        guard !calculation.isEmpty else { return }
        let id = liveSheet(lastOpenedID) ?? createSheet(from: nil, opening: false).id
        var text = store.text(id)
        if !text.isEmpty, !text.hasSuffix("\n") { text += "\n" }
        text += calculation
        store.updateText(id, text)
        if document.sheetID == id { document.update(text) }
        rememberQuickCalc()
        closeQuickCalc()
        showToast("Added to “\(store.displayTitle(id))”")
    }

    func closeQuickCalc() {
        host?.notchSurface.dismissExpandedSurface(Self.quickCalcSurface)
    }

    private func rememberQuickCalc() {
        quickCalc.remember()
        host?.preferences.setValue(quickCalc.history, forKey: Self.quickCalcHistoryKey)
    }

    // MARK: Full-sheet mode

    var isFullSheetPresented: Bool { fullSheetPresentation != nil }

    /// Takes the notch over with the sheet list and the editor side by side.
    func presentFullSheet() {
        guard let host else { return }
        if document.sheetID == nil, let id = pinnedSheetID { open(id, focus: false) }
        fullSheetPresentation = host.notchSurface.presentExpandedSurface(
            ExpandedSurfacePresentationRequest(surfaceID: Self.fullSheetSurface, opensShelf: true)
        )
        if fullSheetPresentation != nil {
            focusEditor()
        } else {
            host.log.info("full-sheet mode: the host refused the surface")
        }
    }

    func dismissFullSheet() {
        host?.notchSurface.dismissExpandedSurface(Self.fullSheetSurface)
    }
}
