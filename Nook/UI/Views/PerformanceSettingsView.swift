//
//  PerformanceSettingsView.swift
//  Nook
//
//  Sub-page consolidating performance-related settings.
//

import SwiftUI
import Combine

struct PerformanceSettingsView: View {
    @ObservedObject var viewModel: NotchViewModel
    let primaryTextColor: Color
    let secondaryTextColor: Color
    let separatorColor: Color

    @AppStorage(AppSettings.performanceMonitorEnabledKey) private var performanceMonitorEnabled = true
    @AppStorage(AppSettings.musicAbovePerformanceKey) private var musicAbovePerformance = false
    @AppStorage(AppSettings.performanceVisibleSectionsKey) private var visibleSectionsRaw: String = "cpu,memory,battery,network"

    @State private var didAppear = false

    private var visibleSet: Set<String> {
        Set(visibleSectionsRaw.split(separator: ",").map { String($0) })
    }

    private var visibleCount: Int {
        PerformanceSection.detailAll.filter { visibleSet.contains($0.rawValue) }.count
    }

    private func isSectionVisible(_ section: PerformanceSection) -> Bool {
        visibleSet.contains(section.rawValue)
    }

    /// Minimum 2 sections must remain visible.
    private func canDisable(_ section: PerformanceSection) -> Bool {
        !(isSectionVisible(section) && visibleCount <= 2)
    }

    private func toggleSection(_ section: PerformanceSection) {
        guard canDisable(section) else { return }
        var current = visibleSet
        if current.contains(section.rawValue) {
            current.remove(section.rawValue)
        } else {
            current.insert(section.rawValue)
        }
        let ordered = PerformanceSection.detailAll.filter { current.contains($0.rawValue) }
        visibleSectionsRaw = ordered.map(\.rawValue).joined(separator: ",")
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(spacing: 4) {
                MenuRow(
                    icon: "chevron.left",
                    label: "Back",
                    primaryTextColor: primaryTextColor,
                    isFocused: viewModel.settingsFocusedIndex == 0
                ) {
                    viewModel.navigateBack()
                }

                Divider().background(separatorColor).padding(.vertical, 4)

                MenuToggleRow(
                    icon: "gauge.with.dots.needle.33percent",
                    label: "Performance Monitor",
                    isOn: performanceMonitorEnabled,
                    primaryTextColor: primaryTextColor,
                    secondaryTextColor: secondaryTextColor,
                    isFocused: viewModel.settingsFocusedIndex == 1
                ) {
                    performanceMonitorEnabled.toggle()
                }

                MenuToggleRow(
                    icon: "arrow.up.arrow.down",
                    label: "Show Performance Below Music",
                    isOn: musicAbovePerformance,
                    primaryTextColor: primaryTextColor,
                    secondaryTextColor: secondaryTextColor,
                    isFocused: viewModel.settingsFocusedIndex == 2
                ) {
                    musicAbovePerformance.toggle()
                }

                Divider().background(separatorColor).padding(.vertical, 4)

                ExpandableSettingsRow(
                    icon: "rectangle.grid.1x2",
                    label: "Visible Metrics",
                    trailingText: "\(visibleCount)/4",
                    primaryTextColor: primaryTextColor,
                    secondaryTextColor: secondaryTextColor,
                    isFocused: viewModel.settingsFocusedIndex == 3,
                    isExpanded: $viewModel.performanceSettingsMetricsExpanded
                ) {
                    ForEach(Array(PerformanceSection.detailAll.enumerated()), id: \.element) { index, section in
                        let focusedIndex = 4 + index
                        SettingsSubToggleRow(
                            label: section.title,
                            isOn: isSectionVisible(section),
                            primaryTextColor: primaryTextColor,
                            secondaryTextColor: secondaryTextColor,
                            isFocused: viewModel.settingsFocusedIndex == focusedIndex,
                            locked: !canDisable(section)
                        ) {
                            toggleSection(section)
                        }
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
            .background(
                GeometryReader { g in
                    Color.clear
                        .preference(key: PerformanceSettingsContentHeightKey.self, value: g.size.height)
                }
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onPreferenceChange(PerformanceSettingsContentHeightKey.self) { height in
            viewModel.performanceSettingsContentHeight = height
        }
        .onAppear {
            didAppear = true
            // Match the convention used by SoundPickerRow / ScreenPickerRow /
            // ChatView section toggles / Claude dir picker: every picker
            // defaults to closed and resets when the page is re-entered.
            // The collapsed state still shows useful info ("2/4") so users
            // can scan visibility without expanding.
            viewModel.performanceSettingsMetricsExpanded = false
        }
        .onReceive(viewModel.$keyboardActivateTrigger) { trigger in
            guard trigger != nil, didAppear else { return }
            switch viewModel.settingsFocusedIndex {
            case 0: viewModel.navigateBack()
            case 1: performanceMonitorEnabled.toggle()
            case 2: musicAbovePerformance.toggle()
            case 3:
                withAnimation(.easeInOut(duration: 0.2)) {
                    viewModel.performanceSettingsMetricsExpanded.toggle()
                    if !viewModel.performanceSettingsMetricsExpanded {
                        viewModel.settingsFocusedIndex = 3
                    }
                }
            case 4: toggleSection(.cpu)
            case 5: toggleSection(.memory)
            case 6: toggleSection(.battery)
            case 7: toggleSection(.network)
            default: break
            }
        }
    }
}

private struct PerformanceSettingsContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
