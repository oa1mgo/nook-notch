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

    @State private var didAppear = false

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
        }
        .onReceive(viewModel.$keyboardActivateTrigger) { trigger in
            guard trigger != nil, didAppear else { return }
            switch viewModel.settingsFocusedIndex {
            case 0: viewModel.navigateBack()
            case 1: performanceMonitorEnabled.toggle()
            case 2: musicAbovePerformance.toggle()
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
