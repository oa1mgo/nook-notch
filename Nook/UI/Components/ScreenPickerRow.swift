//
//  ScreenPickerRow.swift
//  Nook
//
//  Screen selection picker for settings menu
//

import SwiftUI

struct ScreenPickerRow: View {
    @ObservedObject var screenSelector: ScreenSelector
    var primaryTextColor: Color = .white
    var secondaryTextColor: Color = .white.opacity(0.4)
    var isFocused: Bool = false
    var onToggle: ((Bool, CGFloat) -> Void)? = nil

    private var isExpandedBinding: Binding<Bool> {
        Binding(
            get: { screenSelector.isPickerExpanded },
            set: { screenSelector.isPickerExpanded = $0 }
        )
    }

    /// Compile-time layout for this picker's expanded content. Row
    /// heights are computed PER-ROW because each screen's sublabel
    /// presence varies — "Automatic" always has a sublabel, individual
    /// screens only have one when they're built-in or main. Rows
    /// without a sublabel render at `settingsSubPickerRowHeight`
    /// (~27pt) with the title centered; rows with a sublabel render at
    /// `settingsSubPickerRowVerticalSublabelHeight` (~41pt) stacked.
    /// `SettingsSubPickerRow` picks the matching variant automatically
    /// based on `sublabel != nil`.
    static var pickerLayout: PickerLayout {
        let autoHeight = settingsSubPickerRowVerticalSublabelHeight
        let screenHeights = ScreenSelector.shared.availableScreens.map { screen in
            Self.screenSublabel(for: screen) != nil
                ? settingsSubPickerRowVerticalSublabelHeight
                : settingsSubPickerRowHeight
        }
        return PickerLayout(rowHeights: [autoHeight] + screenHeights)
    }

    var body: some View {
        ExpandableSettingsRow(
            icon: "display",
            label: "Screen",
            trailingText: currentSelectionLabel,
            primaryTextColor: primaryTextColor,
            secondaryTextColor: secondaryTextColor,
            isFocused: isFocused,
            isExpanded: isExpandedBinding,
            targetHeight: Self.pickerLayout.expandedHeight,
            onToggle: onToggle
        ) {
            VStack(spacing: 2) {
                SettingsSubPickerRow(
                    label: "Automatic",
                    sublabel: "Built-in or Main",
                    verticalSublabel: true,
                    isSelected: screenSelector.selectionMode == .automatic,
                    primaryTextColor: primaryTextColor,
                    secondaryTextColor: secondaryTextColor
                ) {
                    screenSelector.selectAutomatic()
                    triggerWindowRecreation()
                    collapseAfterDelay()
                }

                ForEach(screenSelector.availableScreens, id: \.self) { screen in
                    SettingsSubPickerRow(
                        label: screen.localizedName,
                        sublabel: Self.screenSublabel(for: screen),
                        verticalSublabel: true,
                        isSelected: screenSelector.selectionMode == .specificScreen &&
                                    screenSelector.isSelected(screen),
                        primaryTextColor: primaryTextColor,
                        secondaryTextColor: secondaryTextColor
                    ) {
                        screenSelector.selectScreen(screen)
                        triggerWindowRecreation()
                        collapseAfterDelay()
                    }
                }
            }
        }
    }

    private var currentSelectionLabel: String {
        switch screenSelector.selectionMode {
        case .automatic:
            return "Auto"
        case .specificScreen:
            if let screen = screenSelector.selectedScreen {
                return screen.localizedName
            }
            return "Auto"
        }
    }

    /// Marking as `static` lets `pickerLayout` reuse the same
    /// sublabel-presence logic to pick the per-row height — keeps the
    /// font-metric height and the rendered string in lock-step.
    private static func screenSublabel(for screen: NSScreen) -> String? {
        var parts: [String] = []
        if screen.isBuiltinDisplay {
            parts.append("Built-in")
        }
        if screen == NSScreen.main {
            parts.append("Main")
        }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    private func triggerWindowRecreation() {
        NotificationCenter.default.post(
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    private func collapseAfterDelay() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            // Collapse with the same animation curve used by the row's
            // own toggle so the panel height and picker frame stay in
            // lock-step. Target height comes from `Self.pickerLayout` —
            // no measurement feedback.
            withAnimation(.easeInOut(duration: 0.2)) {
                screenSelector.isPickerExpanded = false
                onToggle?(false, Self.pickerLayout.expandedHeight)
            }
        }
    }
}
