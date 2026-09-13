//
//  SheetStore.swift
//  Sums
//

import Foundation

/// A saved sheet's metadata. Its text lives beside the index as `<id>.md`.
struct SheetInfo: Codable, Identifiable, Equatable {
    let id: UUID
    /// The name the user gave it. Empty means "use the first line".
    var title: String
    var created: Date
    var modified: Date
    /// When it was moved to Recently deleted, or `nil` while it is live.
    var deleted: Date?
    /// Caret location to restore when the sheet reopens (UTF-16 offset).
    var selection: Int?
}

/// Every sheet, on disk in the droplet's container.
///
/// Sheets are plain Markdown files so they stay readable outside Sums; the
/// index holds titles, dates and the trash. Writes are debounced while the
/// user types and flushed when the droplet deactivates.
@MainActor
final class SheetStore: ObservableObject {
    /// How long a deleted sheet stays in Recently deleted.
    static let trashRetention: TimeInterval = 30 * 24 * 60 * 60

    @Published private(set) var sheets: [SheetInfo] = []
    /// Bumped on every text change, so views showing answers refresh.
    @Published private(set) var revision = 0

    private struct Index: Codable {
        var sheets: [SheetInfo]
        var didSeedGuide: Bool
    }

    /// The folder the sheets live in, set by ``load(directory:now:)``.
    private(set) var folder = FileManager.default.temporaryDirectory.appendingPathComponent("Sums", isDirectory: true)
    private var texts: [UUID: String] = [:]
    private var didSeedGuide = false
    private var dirtyTexts: Set<UUID> = []
    private var indexIsDirty = false
    private var saveTask: Task<Void, Never>?

    private var indexURL: URL { folder.appendingPathComponent("index.json") }

    private func textURL(_ id: UUID) -> URL {
        folder.appendingPathComponent("\(id.uuidString).md")
    }

    // MARK: Loading and saving

    /// Reads the index and every sheet, empties the trash of anything past
    /// its retention, and reports whether this is the first run.
    @discardableResult
    func load(directory: URL, now: Date = Date()) -> Bool {
        folder = directory
        sheets = []
        texts = [:]
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: indexURL),
           let index = try? JSONDecoder.sums.decode(Index.self, from: data) {
            sheets = index.sheets
            didSeedGuide = index.didSeedGuide
        }
        for sheet in sheets {
            texts[sheet.id] = (try? String(contentsOf: textURL(sheet.id), encoding: .utf8)) ?? ""
        }
        for sheet in sheets where sheet.deleted.map({ now.timeIntervalSince($0) > Self.trashRetention }) == true {
            deletePermanently(sheet.id)
        }
        let isFirstRun = !didSeedGuide
        if isFirstRun {
            didSeedGuide = true
            indexIsDirty = true
            scheduleSave()
        }
        return isFirstRun
    }

    /// Writes everything pending now. Called on deactivation.
    func flush() {
        saveTask?.cancel()
        saveTask = nil
        writePending()
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            self?.writePending()
        }
    }

    private func writePending() {
        for id in dirtyTexts {
            try? (texts[id] ?? "").write(to: textURL(id), atomically: true, encoding: .utf8)
        }
        dirtyTexts.removeAll()
        if indexIsDirty,
           let data = try? JSONEncoder.sums.encode(Index(sheets: sheets, didSeedGuide: didSeedGuide)) {
            try? data.write(to: indexURL, options: .atomic)
            indexIsDirty = false
        }
    }

    // MARK: Reading

    /// Live sheets, most recently edited first.
    var active: [SheetInfo] {
        sheets.filter { $0.deleted == nil }.sorted { $0.modified > $1.modified }
    }

    /// Sheets in Recently deleted, most recently deleted first.
    var recentlyDeleted: [SheetInfo] {
        sheets.filter { $0.deleted != nil }.sorted { ($0.deleted ?? .distantPast) > ($1.deleted ?? .distantPast) }
    }

    func sheet(_ id: UUID) -> SheetInfo? {
        sheets.first { $0.id == id }
    }

    func text(_ id: UUID) -> String {
        texts[id] ?? ""
    }

    /// The name shown for a sheet: its title, or else its first line without
    /// Markdown heading marks.
    func displayTitle(_ id: UUID) -> String {
        if let title = sheet(id)?.title, !title.isEmpty { return title }
        let firstLine = text(id)
            .components(separatedBy: "\n")
            .lazy
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
        let stripped = firstLine?.replacingOccurrences(of: #"^#+\s*"#, with: "", options: .regularExpression)
        return stripped.flatMap { $0.isEmpty ? nil : $0 } ?? "Untitled"
    }

    /// Case-insensitive search over titles and text.
    func search(_ query: String) -> [SheetInfo] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return active }
        return active.filter {
            displayTitle($0.id).localizedCaseInsensitiveContains(needle)
                || text($0.id).localizedCaseInsensitiveContains(needle)
        }
    }

    // MARK: Changing

    @discardableResult
    func create(title: String = "", text: String = "", now: Date = Date()) -> SheetInfo {
        let sheet = SheetInfo(id: UUID(), title: title, created: now, modified: now, deleted: nil, selection: nil)
        sheets.append(sheet)
        texts[sheet.id] = text
        dirtyTexts.insert(sheet.id)
        indexIsDirty = true
        revision += 1
        scheduleSave()
        return sheet
    }

    func updateText(_ id: UUID, _ text: String, now: Date = Date()) {
        guard texts[id] != text else { return }
        texts[id] = text
        dirtyTexts.insert(id)
        modify(id) { $0.modified = now }
        revision += 1
    }

    func rename(_ id: UUID, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        modify(id) { $0.title = trimmed }
    }

    @discardableResult
    func duplicate(_ id: UUID) -> SheetInfo? {
        guard sheet(id) != nil else { return nil }
        return create(title: "\(displayTitle(id)) copy", text: text(id))
    }

    func moveToTrash(_ id: UUID, now: Date = Date()) {
        modify(id) { $0.deleted = now }
    }

    func restore(_ id: UUID) {
        modify(id) { $0.deleted = nil }
    }

    func deletePermanently(_ id: UUID) {
        sheets.removeAll { $0.id == id }
        texts[id] = nil
        dirtyTexts.remove(id)
        try? FileManager.default.removeItem(at: textURL(id))
        indexIsDirty = true
        scheduleSave()
    }

    func rememberSelection(_ id: UUID, _ location: Int) {
        guard sheet(id)?.selection != location else { return }
        modify(id) { $0.selection = location }
    }

    private func modify(_ id: UUID, _ change: (inout SheetInfo) -> Void) {
        guard let index = sheets.firstIndex(where: { $0.id == id }) else { return }
        change(&sheets[index])
        indexIsDirty = true
        scheduleSave()
    }
}

private extension JSONEncoder {
    static var sums: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

private extension JSONDecoder {
    static var sums: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
