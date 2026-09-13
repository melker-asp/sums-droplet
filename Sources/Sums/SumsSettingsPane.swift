//
//  SumsSettingsPane.swift
//  Sums
//

import DroppyKit
import SwiftUI

/// Sums' page in Droppy's Settings.
struct SumsSettingsPane: View {
    @ObservedObject var droplet: SumsDroplet
    @ObservedObject var store: SheetStore

    var body: some View {
        VStack(alignment: .leading, spacing: DroppySpacing.lg) {
            section("Numbers") {
                DropletSettingsCard {
                    DropletControlRow(
                        title: "Number format",
                        icon: "number",
                        infoTip: "How Sums reads and writes numbers. Sheets are read in this format too: with 1 234,56 a space groups thousands and a comma marks decimals."
                    ) {
                        Picker("Number format", selection: droplet.binding(\.numberFormat)) {
                            ForEach(NumberFormat.allCases) { format in
                                Text(format.title).tag(format)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .fixedSize()
                    }
                    DropletSettingsDivider()
                    DropletSliderRow(
                        title: "Decimal places",
                        value: "\(droplet.settings.decimals)",
                        binding: decimals,
                        range: 0...8,
                        step: 1
                    )
                    DropletSettingsDivider()
                    DropletToggleRow(
                        title: "Live currency rates",
                        icon: "dollarsign.arrow.circlepath",
                        subtitle: "Daily rates from the European Central Bank, including SEK. Off uses built-in rates.",
                        isOn: droplet.binding(\.usesLiveRates)
                    )
                }
            }
            section("Shelf") {
                DropletSettingsCard {
                    DropletToggleRow(
                        title: "Open the last sheet",
                        icon: "clock.arrow.circlepath",
                        subtitle: "Show the sheet you used last instead of the list.",
                        isOn: droplet.binding(\.opensLastSheet)
                    )
                    DropletSettingsDivider()
                    DropletControlRow(
                        title: "Pinned sheet",
                        icon: "pin",
                        infoTip: "The sheet whose answer the compact card and the lock screen show."
                    ) {
                        Picker("Pinned sheet", selection: droplet.binding(\.pinnedSheetID)) {
                            Text("Last opened").tag(UUID?.none)
                            ForEach(store.active) { sheet in
                                Text(store.displayTitle(sheet.id)).tag(UUID?.some(sheet.id))
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .fixedSize()
                    }
                    DropletSettingsDivider()
                    DropletToggleRow(
                        title: "Show on the lock screen",
                        icon: "lock",
                        subtitle: "The pinned sheet's answer, on Droppy's lock screen.",
                        isOn: droplet.binding(\.showsOnLockScreen)
                    )
                }
            }
            section("Sheets") {
                DropletSettingsCard {
                    DropletControlRow(
                        title: "Sheets folder",
                        icon: "folder",
                        infoTip: "Every sheet is a Markdown file you can open anywhere."
                    ) {
                        Button("Show in Finder") { droplet.revealSheetsFolder() }
                            .buttonStyle(DroppyQuietButtonStyle(size: .small))
                    }
                    DropletSettingsDivider()
                    DropletControlRow(
                        title: "Quick guide",
                        icon: "questionmark.circle",
                        infoTip: "Adds the welcome sheet to your list again."
                    ) {
                        Button("Add") { droplet.createSheet(from: Templates.quickGuide, opening: false) }
                            .buttonStyle(DroppyQuietButtonStyle(size: .small))
                    }
                    DropletSettingsDivider()
                    DropletControlRow(
                        title: "Keyboard shortcuts",
                        icon: "keyboard",
                        infoTip: "Open Sums (⌃⌥S) and New quick calc (⌃⌥N) can be changed in Droppy's Shortcuts settings."
                    ) {
                        EmptyView()
                    }
                }
            }
        }
    }

    private var decimals: Binding<Double> {
        Binding(
            get: { Double(droplet.settings.decimals) },
            set: { value in droplet.updateSettings { $0.decimals = Int(value.rounded()) } }
        )
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: DroppySpacing.xsm) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, DroppySpacing.xs)
            content()
        }
    }
}
