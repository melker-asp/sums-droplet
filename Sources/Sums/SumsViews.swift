//
//  SumsViews.swift
//  Sums
//

import AppKit
import DroppyKit
import SwiftUI

private let primaryText = AdaptiveColors.notchSurfacePrimaryText
private let secondaryText = AdaptiveColors.notchSurfaceSecondaryText
private let tertiaryText = AdaptiveColors.notchSurfaceTertiaryText

/// The shelf card. Solo it navigates between the sheet list, a sheet, the
/// template picker and Recently deleted; in a shared row it shows the pinned
/// sheet's answer.
struct SumsWidget: View {
    @ObservedObject var droplet: SumsDroplet
    @ObservedObject var store: SheetStore
    @ObservedObject var document: SheetDocument
    let context: ShelfWidgetContext

    var body: some View {
        content
            .padding(context.contentInsets)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private var content: some View {
        if context.isCompact {
            CompactSummaryView(droplet: droplet, store: store)
        } else {
            switch droplet.route {
            case .list:
                SheetListView(droplet: droplet, store: store, isPreview: context.isPreview)
            case .sheet:
                SheetEditorView(droplet: droplet, store: store, document: document, isPreview: context.isPreview)
            case .newSheet:
                NewSheetView(droplet: droplet)
            case .trash:
                TrashView(droplet: droplet, store: store)
            }
        }
    }
}

// MARK: - Shared pieces

/// The header row every page shares: a back button or the symbol, a title,
/// and the page's controls at the trailing end.
private struct CardHeader<Title: View, Trailing: View>: View {
    var onBack: (@MainActor () -> Void)?
    @ViewBuilder var title: Title
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: DroppySpacing.xsm) {
            if let onBack {
                Button(action: onBack) {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(DroppyCircleButtonStyle(size: 20))
                .help("Back to sheets")
                .accessibilityLabel("Back to sheets")
            } else {
                Image(systemName: "sum")
                    .font(.system(size: 12, weight: .medium))
            }
            title
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
            Spacer(minLength: DroppySpacing.xs)
            trailing
        }
        .foregroundStyle(secondaryText)
        .frame(height: 20)
    }
}

private struct IconButton: View {
    let systemImage: String
    let label: String
    var destructive = false
    let action: @MainActor () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
        }
        .buttonStyle(
            destructive
                ? DroppyCircleButtonStyle(size: 20, destructive: true, solidFill: nil, foregroundColorOverride: nil)
                : DroppyCircleButtonStyle(size: 20)
        )
        .help(label)
        .accessibilityLabel(label)
    }
}

private struct ToastView: View {
    let toast: SumsDroplet.Toast
    let droplet: SumsDroplet

    var body: some View {
        HStack(spacing: DroppySpacing.sm) {
            Text(toast.message)
                .font(.system(size: 11.5))
                .foregroundStyle(secondaryText)
                .lineLimit(1)
            Spacer(minLength: 0)
            if toast.undoSheetID != nil {
                Button("Undo") { droplet.undoToast() }
                    .buttonStyle(DroppyQuietButtonStyle(size: .small))
            }
        }
        .padding(.horizontal, DroppySpacing.sm)
        .padding(.vertical, DroppySpacing.xs)
        .background(Capsule(style: .continuous).fill(AdaptiveColors.notchSurfaceCardFill))
    }
}

// MARK: - Sheet list

private struct SheetListView: View {
    @ObservedObject var droplet: SumsDroplet
    @ObservedObject var store: SheetStore
    let isPreview: Bool

    @State private var query = ""
    @State private var isSearching = false
    @State private var selection: UUID?
    @FocusState private var focus: Field?

    private enum Field { case list, search }

    private var sheets: [SheetInfo] {
        store.search(isSearching ? query : "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DroppySpacing.sm) {
            CardHeader(title: { Text("Sums") }) {
                IconButton(systemImage: "magnifyingglass", label: "Search sheets") { toggleSearch() }
                IconButton(systemImage: "plus", label: "New sheet") { droplet.showNewSheet() }
            }
            if isSearching {
                TextField("Search sheets", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(primaryText)
                    .padding(.horizontal, DroppySpacing.sm)
                    .padding(.vertical, DroppySpacing.xs)
                    .background(
                        RoundedRectangle(cornerRadius: DroppyRadius.small, style: .continuous)
                            .fill(AdaptiveColors.notchSurfaceCardFill)
                    )
                    .focused($focus, equals: .search)
                    .onSubmit {
                        if let first = sheets.first { droplet.open(first.id) }
                    }
            }
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(sheets) { sheet in
                            SheetRow(droplet: droplet, store: store, sheet: sheet, isSelected: selection == sheet.id)
                                .id(sheet.id)
                        }
                        if sheets.isEmpty {
                            Text(isSearching ? "No sheets match." : "No sheets yet. Press + to start one.")
                                .font(.system(size: 12))
                                .foregroundStyle(tertiaryText)
                                .padding(DroppySpacing.sm)
                        }
                        if !isSearching, !store.recentlyDeleted.isEmpty {
                            Button {
                                droplet.showTrash()
                            } label: {
                                Label("Recently deleted (\(store.recentlyDeleted.count))", systemImage: "trash")
                                    .font(.system(size: 11))
                                    .foregroundStyle(tertiaryText)
                                    .padding(.horizontal, DroppySpacing.sm)
                                    .padding(.vertical, DroppySpacing.xs)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .onChange(of: selection) { _, id in
                    if let id { proxy.scrollTo(id) }
                }
            }
            if let toast = droplet.toast {
                ToastView(toast: toast, droplet: droplet)
            }
        }
        .focusable()
        .focused($focus, equals: .list)
        .focusEffectDisabled()
        .onKeyPress(phases: .down, action: handleKey)
        .onAppear {
            if !isPreview { focus = .list }
        }
    }

    private func toggleSearch() {
        isSearching.toggle()
        if isSearching {
            focus = .search
        } else {
            query = ""
            focus = .list
        }
    }

    /// Arrow keys and Return move through and open sheets; ⌘N starts one,
    /// ⌘⌫ deletes the selected one, ⌘F searches.
    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        let ids = sheets.map(\.id)
        let command = press.modifiers.contains(.command)
        switch press.key {
        case .downArrow, .upArrow:
            let step = press.key == .downArrow ? 1 : -1
            let current = selection.flatMap { ids.firstIndex(of: $0) } ?? (step > 0 ? -1 : ids.count)
            let next = min(max(current + step, 0), ids.count - 1)
            if ids.indices.contains(next) { selection = ids[next] }
            return .handled
        case .return:
            guard let id = selection ?? ids.first else { return .ignored }
            droplet.open(id)
            return .handled
        case .delete where command && focus != .search:
            if let id = selection { droplet.delete(id) }
            return .handled
        default:
            break
        }
        if command, press.characters.lowercased() == "n" {
            droplet.showNewSheet()
            return .handled
        }
        if command, press.characters.lowercased() == "f" {
            if !isSearching { toggleSearch() } else { focus = .search }
            return .handled
        }
        return .ignored
    }
}

private struct SheetRow: View {
    @ObservedObject var droplet: SumsDroplet
    let store: SheetStore
    let sheet: SheetInfo
    let isSelected: Bool

    @State private var isHovering = false

    private var isPinned: Bool { droplet.settings.pinnedSheetID == sheet.id }

    var body: some View {
        HStack(spacing: DroppySpacing.sm) {
            Image(systemName: isPinned ? "pin.fill" : "doc.text")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(tertiaryText)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 1) {
                Text(store.displayTitle(sheet.id))
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(primaryText)
                    .lineLimit(1)
                Text(sheet.modified, format: .relative(presentation: .named))
                    .font(.system(size: 10.5))
                    .foregroundStyle(tertiaryText)
            }
            Spacer(minLength: DroppySpacing.sm)
            if let summary = droplet.summary(for: sheet.id) {
                Text(summary.formatted)
                    .font(.system(size: 12, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(secondaryText)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, DroppySpacing.sm)
        .padding(.vertical, DroppySpacing.xs)
        .background(
            RoundedRectangle(cornerRadius: DroppyRadius.small, style: .continuous)
                .fill(isHovering || isSelected ? AdaptiveColors.notchSurfaceCardFill : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture { droplet.open(sheet.id) }
        .onHover { isHovering = $0 }
        .contextMenu {
            Button("Open") { droplet.open(sheet.id) }
            Button("Rename") { droplet.beginRename(sheet.id) }
            Button("Duplicate") { droplet.duplicate(sheet.id) }
            Button(isPinned ? "Unpin from card" : "Pin to card") { droplet.togglePin(sheet.id) }
            Divider()
            Button("Delete", role: .destructive) { droplet.delete(sheet.id) }
        }
    }
}

// MARK: - Sheet editor

private struct SheetEditorView: View {
    @ObservedObject var droplet: SumsDroplet
    @ObservedObject var store: SheetStore
    @ObservedObject var document: SheetDocument
    let isPreview: Bool

    @State private var titleDraft = ""
    @State private var showsInputs = false
    @FocusState private var titleFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: DroppySpacing.xsm) {
            CardHeader(onBack: { commitTitle(); droplet.showList() }, title: { titleField }) {
                IconButton(
                    systemImage: showsInputs ? "text.alignleft" : "slider.horizontal.3",
                    label: showsInputs ? "Show the sheet" : "Show inputs"
                ) {
                    showsInputs.toggle()
                }
                IconButton(systemImage: "doc.on.doc", label: "Copy sheet with answers") { droplet.copySheet() }
                moreMenu
            }
            if showsInputs {
                InputsView(droplet: droplet, document: document)
            } else {
                CalculatorEditor(
                    document: document,
                    focusRequest: isPreview ? 0 : droplet.focusRequest,
                    restoreSelection: document.sheetID.flatMap { store.sheet($0)?.selection },
                    actions: EditorActions(
                        textChanged: { droplet.editorChanged($0) },
                        selectionChanged: { droplet.selectionChanged(location: $0, lines: $1) },
                        copyAnswer: { droplet.copy($0) },
                        focusChanged: { droplet.editorFocusChanged($0) },
                        back: { commitTitle(); droplet.showList() },
                        newSheet: { droplet.showNewSheet() }
                    )
                )
            }
            if let stats = document.stats {
                StatsStrip(stats: stats)
            } else if let toast = droplet.toast {
                ToastView(toast: toast, droplet: droplet)
            }
        }
        .onAppear(perform: loadTitle)
        .onChange(of: document.sheetID) { loadTitle() }
        .onChange(of: droplet.titleFocusRequest) { titleFocused = true }
        .onChange(of: titleFocused) { _, focused in
            if !focused { commitTitle() }
            droplet.editorFocusChanged(focused)
        }
    }

    private var titleField: some View {
        TextField(placeholderTitle, text: $titleDraft)
            .textFieldStyle(.plain)
            .foregroundStyle(primaryText)
            .focused($titleFocused)
            .onSubmit {
                commitTitle()
                droplet.focusEditor()
            }
    }

    private var moreMenu: some View {
        Menu {
            Button("Rename") { titleFocused = true }
            if let id = document.sheetID {
                Button("Duplicate") { droplet.duplicate(id) }
                Button(droplet.settings.pinnedSheetID == id ? "Unpin from card" : "Pin to card") { droplet.togglePin(id) }
            }
            Menu("Export") {
                ForEach(SheetExporter.Format.allCases) { format in
                    Button(format.title) { droplet.export(format) }
                }
            }
            Divider()
            if let id = document.sheetID {
                Button("Delete", role: .destructive) { droplet.delete(id) }
            }
        } label: {
            Image(systemName: "ellipsis")
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(DroppyCircleButtonStyle(size: 20))
        .fixedSize()
        .help("More")
        .accessibilityLabel("More")
    }

    /// With no title of its own a sheet is named by its first line, which
    /// the field shows as its placeholder.
    private var placeholderTitle: String {
        document.sheetID.map { store.displayTitle($0) } ?? "Untitled"
    }

    private func loadTitle() {
        titleDraft = document.sheetID.flatMap { store.sheet($0)?.title } ?? ""
    }

    private func commitTitle() {
        guard let id = document.sheetID, store.sheet(id)?.title != titleDraft else { return }
        droplet.rename(id, to: titleDraft)
    }
}

/// Sum, average, median and standard deviation of the selected lines.
private struct StatsStrip: View {
    let stats: QuickStats

    var body: some View {
        HStack(spacing: DroppySpacing.md) {
            item("Sum", stats.total)
            item("Avg", stats.average)
            item("Median", stats.median)
            item("Std dev", stats.standardDeviation)
            Spacer(minLength: 0)
            Text("\(stats.count) lines")
                .foregroundStyle(tertiaryText)
        }
        .font(.system(size: 10.5))
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .frame(height: 16)
    }

    private func item(_ label: String, _ value: String) -> some View {
        HStack(spacing: 3) {
            Text(label).foregroundStyle(tertiaryText)
            Text(value).monospacedDigit().foregroundStyle(secondaryText)
        }
    }
}

// MARK: - Inputs

/// A sheet as a small form: each variable with a plain value is a field, and
/// the answers that follow from them are listed below.
private struct InputsView: View {
    @ObservedObject var droplet: SumsDroplet
    @ObservedObject var document: SheetDocument

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: DroppySpacing.xs) {
                if document.inputs.isEmpty {
                    Text("No inputs yet. A line like price = 1 000 kr becomes a field here.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(tertiaryText)
                }
                ForEach(document.inputs) { input in
                    HStack(spacing: DroppySpacing.sm) {
                        Text(input.name)
                            .font(.system(size: 12))
                            .foregroundStyle(secondaryText)
                            .lineLimit(1)
                        Spacer(minLength: DroppySpacing.sm)
                        InputField(value: input.value) { value in
                            droplet.setInput(line: input.lineIndex, to: value)
                        } onFocusChange: { focused in
                            droplet.editorFocusChanged(focused)
                        }
                    }
                }
                if !document.outputs.isEmpty {
                    Spacer().frame(height: DroppySpacing.xs)
                    ForEach(document.outputs) { output in
                        HStack(spacing: DroppySpacing.sm) {
                            Text(output.label)
                                .font(.system(size: 12))
                                .foregroundStyle(tertiaryText)
                                .lineLimit(1)
                            Spacer(minLength: DroppySpacing.sm)
                            Text(output.value)
                                .font(.system(size: 13, weight: .semibold))
                                .monospacedDigit()
                                .foregroundStyle(primaryText)
                                .lineLimit(1)
                        }
                    }
                }
            }
        }
    }
}

private struct InputField: View {
    let value: String
    let onChange: @MainActor (String) -> Void
    let onFocusChange: @MainActor (Bool) -> Void

    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("", text: $draft)
            .textFieldStyle(.plain)
            .multilineTextAlignment(.trailing)
            .font(.system(size: 12.5, weight: .semibold))
            .monospacedDigit()
            .foregroundStyle(primaryText)
            .padding(.horizontal, DroppySpacing.sm)
            .padding(.vertical, 3)
            .frame(width: 150)
            .background(
                RoundedRectangle(cornerRadius: DroppyRadius.small, style: .continuous)
                    .fill(AdaptiveColors.notchSurfaceCardFill)
            )
            .focused($focused)
            .onAppear { draft = value }
            .onChange(of: value) { _, newValue in
                if !focused { draft = newValue }
            }
            .onChange(of: draft) { _, newValue in
                if newValue != value { onChange(newValue) }
            }
            .onChange(of: focused) { _, isFocused in
                onFocusChange(isFocused)
            }
    }
}

// MARK: - New sheet

private struct NewSheetView: View {
    @ObservedObject var droplet: SumsDroplet

    private let columns = [
        GridItem(.flexible(), spacing: DroppySpacing.xs),
        GridItem(.flexible(), spacing: DroppySpacing.xs)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: DroppySpacing.sm) {
            CardHeader(onBack: { droplet.showList() }, title: { Text("New sheet") }) {
                EmptyView()
            }
            ScrollView(.vertical, showsIndicators: false) {
                LazyVGrid(columns: columns, spacing: DroppySpacing.xs) {
                    TemplateTile(title: "Blank worksheet", systemImage: "square.and.pencil") {
                        droplet.createSheet(from: nil)
                    }
                    ForEach(Templates.all) { template in
                        TemplateTile(title: template.title, systemImage: template.systemImage) {
                            droplet.createSheet(from: template)
                        }
                    }
                }
            }
        }
    }
}

private struct TemplateTile: View {
    let title: String
    let systemImage: String
    let action: @MainActor () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: DroppySpacing.xsm) {
                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .medium))
                    .frame(width: 14)
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .foregroundStyle(primaryText)
            .padding(.horizontal, DroppySpacing.sm)
            .padding(.vertical, DroppySpacing.xsm)
            .contentShape(Rectangle())
        }
        .buttonStyle(DroppyGlassButtonStyle(
            shape: AnyShape(RoundedRectangle(cornerRadius: DroppyRadius.small, style: .continuous))
        ))
    }
}

// MARK: - Recently deleted

private struct TrashView: View {
    @ObservedObject var droplet: SumsDroplet
    @ObservedObject var store: SheetStore

    var body: some View {
        VStack(alignment: .leading, spacing: DroppySpacing.sm) {
            CardHeader(onBack: { droplet.showList() }, title: { Text("Recently deleted") }) {
                if !store.recentlyDeleted.isEmpty {
                    Button("Empty") { droplet.emptyTrash() }
                        .buttonStyle(DroppyQuietButtonStyle(size: .small, destructive: true))
                }
            }
            if store.recentlyDeleted.isEmpty {
                Text("Nothing here. Deleted sheets stay for 30 days.")
                    .font(.system(size: 12))
                    .foregroundStyle(tertiaryText)
            }
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: DroppySpacing.xs) {
                    ForEach(store.recentlyDeleted) { sheet in
                        HStack(spacing: DroppySpacing.sm) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(store.displayTitle(sheet.id))
                                    .font(.system(size: 12.5, weight: .medium))
                                    .foregroundStyle(primaryText)
                                    .lineLimit(1)
                                if let deleted = sheet.deleted {
                                    Text("Deleted \(deleted.formatted(.relative(presentation: .named)))")
                                        .font(.system(size: 10.5))
                                        .foregroundStyle(tertiaryText)
                                }
                            }
                            Spacer(minLength: DroppySpacing.sm)
                            IconButton(systemImage: "arrow.uturn.backward", label: "Restore") { droplet.restore(sheet.id) }
                            IconButton(systemImage: "trash", label: "Delete now", destructive: true) {
                                droplet.deletePermanently(sheet.id)
                            }
                        }
                        .padding(.horizontal, DroppySpacing.sm)
                    }
                }
            }
        }
    }
}

// MARK: - Compact

/// In a shared row: the pinned sheet's name and answer. Click to copy it.
private struct CompactSummaryView: View {
    @ObservedObject var droplet: SumsDroplet
    @ObservedObject var store: SheetStore

    var body: some View {
        let id = droplet.pinnedSheetID
        VStack(alignment: .leading, spacing: DroppySpacing.xs) {
            CardHeader(title: { Text(id.map { store.displayTitle($0) } ?? "Sums") }) {
                EmptyView()
            }
            Text(id.flatMap { droplet.summary(for: $0)?.formatted } ?? "–")
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .foregroundStyle(primaryText)
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .onTapGesture { droplet.copyPinnedSummary() }
        .help("Click to copy")
    }
}
