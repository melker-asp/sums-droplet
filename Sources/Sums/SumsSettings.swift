//
//  SumsSettings.swift
//  Sums
//

import DroppyKit
import Foundation

/// How numbers are read and written.
///
/// This is more than display: the engine reads `8 500` as eight thousand
/// five hundred only when a space groups thousands, so the format decides
/// how a sheet is understood.
enum NumberFormat: String, CaseIterable, Identifiable {
    /// Follow the Mac's region.
    case automatic
    /// `1 234,56`
    case spaceComma
    /// `1,234.56`
    case commaPoint

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: "System"
        case .spaceComma: "1 234,56"
        case .commaPoint: "1,234.56"
        }
    }

    var locale: Locale {
        switch self {
        case .automatic: .current
        case .spaceComma: Locale(identifier: "sv_SE")
        case .commaPoint: Locale(identifier: "en_US")
        }
    }

    var decimalSeparator: String {
        locale.decimalSeparator ?? "."
    }
}

/// Everything the settings pane changes, persisted through the host's
/// droplet-scoped preferences.
struct SumsSettings: Equatable {
    var numberFormat: NumberFormat = .automatic
    /// Decimal places in answers.
    var decimals: Int = 2
    /// Open the last sheet rather than the list when the shelf shows Sums.
    var opensLastSheet = true
    /// The sheet the compact card and the lock screen show. `nil` means the
    /// last sheet opened.
    var pinnedSheetID: UUID?
    var showsOnLockScreen = false
    /// Daily rates from the European Central Bank instead of SoulverCore's
    /// built-in table.
    var usesLiveRates = true

    private enum Key {
        static let usesLiveRates = "usesLiveRates"
        static let numberFormat = "numberFormat"
        static let decimals = "decimals"
        static let opensLastSheet = "opensLastSheet"
        static let pinnedSheetID = "pinnedSheetID"
        static let showsOnLockScreen = "showsOnLockScreen"
    }

    @MainActor
    static func load(from preferences: any DropletPreferencesService) -> SumsSettings {
        var settings = SumsSettings()
        if let raw = preferences.value(forKey: Key.numberFormat, as: String.self),
           let format = NumberFormat(rawValue: raw) {
            settings.numberFormat = format
        }
        if let decimals = preferences.value(forKey: Key.decimals, as: Int.self) {
            settings.decimals = min(max(decimals, 0), 8)
        }
        if let opens = preferences.value(forKey: Key.opensLastSheet, as: Bool.self) {
            settings.opensLastSheet = opens
        }
        settings.pinnedSheetID = preferences.value(forKey: Key.pinnedSheetID, as: String.self).flatMap(UUID.init(uuidString:))
        if let shows = preferences.value(forKey: Key.showsOnLockScreen, as: Bool.self) {
            settings.showsOnLockScreen = shows
        }
        if let live = preferences.value(forKey: Key.usesLiveRates, as: Bool.self) {
            settings.usesLiveRates = live
        }
        return settings
    }

    @MainActor
    func save(to preferences: any DropletPreferencesService) {
        preferences.setValue(numberFormat.rawValue, forKey: Key.numberFormat)
        preferences.setValue(decimals, forKey: Key.decimals)
        preferences.setValue(opensLastSheet, forKey: Key.opensLastSheet)
        preferences.setValue(pinnedSheetID?.uuidString, forKey: Key.pinnedSheetID)
        preferences.setValue(showsOnLockScreen, forKey: Key.showsOnLockScreen)
        preferences.setValue(usesLiveRates, forKey: Key.usesLiveRates)
    }
}
