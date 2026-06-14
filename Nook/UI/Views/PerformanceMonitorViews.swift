//
//  PerformanceMonitorViews.swift
//  Nook
//
//  Compact and detailed performance monitor UI.
//

import AppKit
import Foundation
import SwiftUI

private struct PerformanceContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct PerformanceSummaryRow: View {
    @ObservedObject var monitor: PerformanceMonitor
    let action: () -> Void

    @State private var isHovered = false

    private var snapshot: PerformanceSnapshot {
        monitor.snapshot
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                PerformanceHomeMetric(
                    label: "CPU",
                    detail: PerformanceFormat.percent(snapshot.cpuUsage),
                    icon: "cpu",
                    tint: PerformancePalette.cpu(snapshot.cpuUsage)
                )

                PerformanceHomeMetric(
                    label: "Memory",
                    detail: PerformanceFormat.memoryPair(snapshot.memory),
                    icon: "memorychip",
                    tint: PerformancePalette.memory(snapshot.memory.usage)
                )

                PerformanceHomeMetric(
                    label: "Battery",
                    detail: batteryText,
                    icon: batteryIcon,
                    tint: PerformancePalette.battery(snapshot.battery)
                )

                PerformanceHomeMetric(
                    label: "Network",
                    detail: PerformanceFormat.compactNetwork(snapshot.network),
                    icon: "antenna.radiowaves.left.and.right",
                    tint: TerminalColors.cyan
                )
            }
            .padding(.horizontal, 8)
            .frame(height: 44)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isHovered ? Color.white.opacity(0.08) : Color.white.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.white.opacity(isHovered ? 0.14 : 0.06), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
    }

    private var batteryIcon: String {
        PerformanceFormat.batteryIcon(snapshot.battery)
    }

    private var batteryText: String {
        guard let level = snapshot.battery.level else {
            return "AC"
        }
        return PerformanceFormat.percent(level)
    }
}

struct PerformanceDetailView: View {
    @ObservedObject var viewModel: NotchViewModel
    @ObservedObject var monitor: PerformanceMonitor
    let section: PerformanceSection
    let primaryTextColor: Color
    let secondaryTextColor: Color
    let separatorColor: Color

    @State private var didAppear = false

    private let detailSections: [PerformanceSection] = [.cpu, .memory, .battery, .network]

    private var snapshot: PerformanceSnapshot {
        monitor.snapshot
    }

    private var history: [PerformanceHistorySample] {
        monitor.history
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(spacing: 8) {
                MenuRow(
                    icon: "chevron.left",
                    label: section == .overview ? "Back" : "Performance",
                    primaryTextColor: primaryTextColor,
                    isFocused: viewModel.settingsFocusedIndex == 0
                ) {
                    viewModel.navigateBack()
                }

                Divider()
                    .background(separatorColor)
                    .padding(.vertical, 2)

                pageContent
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
            .background(
                GeometryReader { proxy in
                    Color.clear
                        .preference(key: PerformanceContentHeightKey.self, value: proxy.size.height)
                }
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onPreferenceChange(PerformanceContentHeightKey.self) { height in
            viewModel.updatePerformanceContentHeight(height, for: section)
        }
        .onAppear {
            didAppear = true
            syncProcessDetailsSampling()
            monitor.refresh()
        }
        .onDisappear {
            monitor.setProcessDetailsActive(false)
        }
        .onChange(of: section) { _, _ in
            syncProcessDetailsSampling()
            monitor.refresh()
        }
        .onReceive(viewModel.$keyboardActivateTrigger) { trigger in
            guard trigger != nil, didAppear else {
                return
            }
            performFocusedAction()
        }
    }

    @ViewBuilder
    private var pageContent: some View {
        switch section {
        case .overview:
            overviewContent
        case .cpu:
            cpuContent
        case .memory:
            memoryContent
        case .battery:
            batteryContent
        case .network:
            networkContent
        }
    }

    private var overviewContent: some View {
        VStack(spacing: 8) {
            ForEach(Array(detailSections.enumerated()), id: \.element) { index, section in
                PerformanceOverviewCard(
                    section: section,
                    snapshot: snapshot,
                    primaryTextColor: primaryTextColor,
                    secondaryTextColor: secondaryTextColor,
                    isFocused: viewModel.settingsFocusedIndex == index + 1
                ) {
                    viewModel.pushTo(.performance(section))
                }
            }
        }
    }

    private var cpuContent: some View {
        VStack(spacing: 8) {
            PerformanceHeroPanel(
                icon: "cpu",
                title: "CPU",
                value: PerformanceFormat.percent(snapshot.cpuUsage),
                subtitle: "Total processor activity",
                progress: snapshot.cpuUsage,
                tint: PerformancePalette.cpu(snapshot.cpuUsage),
                primaryTextColor: primaryTextColor,
                secondaryTextColor: secondaryTextColor
            )

            PerformanceTrendPanel(
                title: "Usage Trend",
                subtitle: historyWindowText,
                series: [
                    PerformanceChartSeries(
                        id: "cpu",
                        label: "CPU",
                        value: PerformanceFormat.percent(snapshot.cpuUsage),
                        tint: PerformancePalette.cpu(snapshot.cpuUsage),
                        points: history.map { $0.cpuUsage }
                    )
                ],
                fixedRange: 0...1,
                yAxisLabel: PerformanceFormat.percent,
                xAxisStartLabel: historyStartAxisText,
                primaryTextColor: primaryTextColor,
                secondaryTextColor: secondaryTextColor
            )

            PerformanceStatGrid(items: [
                PerformanceStatItem(label: "Cores", value: "\(Foundation.ProcessInfo.processInfo.processorCount)"),
                PerformanceStatItem(label: "Active", value: "\(Foundation.ProcessInfo.processInfo.activeProcessorCount)"),
            ], primaryTextColor: primaryTextColor, secondaryTextColor: secondaryTextColor)

            PerformanceCoreUsagePanel(
                usages: snapshot.cpuCoreUsages,
                primaryTextColor: primaryTextColor,
                secondaryTextColor: secondaryTextColor
            )
        }
    }

    private var memoryContent: some View {
        VStack(spacing: 8) {
            PerformanceHeroPanel(
                icon: "memorychip",
                title: "Memory",
                value: "\(PerformanceFormat.bytes(snapshot.memory.usedBytes)) / \(PerformanceFormat.bytes(snapshot.memory.totalBytes))",
                subtitle: "\(PerformanceFormat.percent(snapshot.memory.usage)) used",
                progress: snapshot.memory.usage,
                tint: PerformancePalette.memory(snapshot.memory.usage),
                primaryTextColor: primaryTextColor,
                secondaryTextColor: secondaryTextColor
            )

            PerformanceMemoryBreakdownPanel(
                memory: snapshot.memory,
                history: history,
                xAxisStartLabel: historyStartAxisText,
                primaryTextColor: primaryTextColor,
                secondaryTextColor: secondaryTextColor
            )

            PerformanceProcessList(
                processes: snapshot.memory.processes,
                primaryTextColor: primaryTextColor,
                secondaryTextColor: secondaryTextColor
            )
        }
    }

    private var batteryContent: some View {
        VStack(spacing: 8) {
            PerformanceHeroPanel(
                icon: PerformanceFormat.batteryIcon(snapshot.battery),
                title: "Battery",
                value: batteryValue,
                subtitle: batteryDetail,
                progress: snapshot.battery.level,
                tint: PerformancePalette.battery(snapshot.battery),
                primaryTextColor: primaryTextColor,
                secondaryTextColor: secondaryTextColor
            )

            PerformanceTrendPanel(
                title: "Charge Trend",
                subtitle: historyWindowText,
                series: [
                    PerformanceChartSeries(
                        id: "battery",
                        label: "Battery",
                        value: batteryValue,
                        tint: PerformancePalette.battery(snapshot.battery),
                        points: history.map { $0.batteryLevel }
                    )
                ],
                fixedRange: 0...1,
                yAxisLabel: PerformanceFormat.percent,
                xAxisStartLabel: historyStartAxisText,
                primaryTextColor: primaryTextColor,
                secondaryTextColor: secondaryTextColor
            )

            PerformanceStatGrid(items: [
                PerformanceStatItem(label: "Source", value: batterySourceText),
                PerformanceStatItem(label: "Charging", value: snapshot.battery.level == nil ? "-" : (snapshot.battery.isCharging ? "Yes" : "No")),
                PerformanceStatItem(label: "Remaining", value: batteryTimeText),
                PerformanceStatItem(label: "Updated", value: PerformanceFormat.sampleAge(snapshot.sampledAt)),
            ], primaryTextColor: primaryTextColor, secondaryTextColor: secondaryTextColor)

            PerformanceInfoPanel(
                title: "Power State",
                rows: [
                    ("Level", batteryValue),
                    ("Status", batteryDetail),
                    ("Adapter", snapshot.battery.isPluggedIn ? "Connected" : "Disconnected"),
                ],
                primaryTextColor: primaryTextColor,
                secondaryTextColor: secondaryTextColor
            )
        }
    }

    private var networkContent: some View {
        VStack(spacing: 8) {
            PerformanceHeroPanel(
                icon: "antenna.radiowaves.left.and.right",
                title: "Network",
                value: PerformanceFormat.compactNetwork(snapshot.network),
                subtitle: "Current total throughput",
                progress: nil,
                tint: TerminalColors.cyan,
                primaryTextColor: primaryTextColor,
                secondaryTextColor: secondaryTextColor
            )

            PerformanceTrendPanel(
                title: "Throughput Trend",
                subtitle: historyWindowText,
                series: [
                    PerformanceChartSeries(
                        id: "download",
                        label: "Down",
                        value: "↓ \(PerformanceFormat.speed(snapshot.network.downloadBytesPerSecond))",
                        tint: TerminalColors.cyan,
                        points: history.map { Double($0.downloadBytesPerSecond) }
                    ),
                    PerformanceChartSeries(
                        id: "upload",
                        label: "Up",
                        value: "↑ \(PerformanceFormat.speed(snapshot.network.uploadBytesPerSecond))",
                        tint: TerminalColors.green,
                        points: history.map { Double($0.uploadBytesPerSecond) }
                    ),
                ],
                fixedRange: nil,
                yAxisLabel: PerformanceFormat.axisSpeed,
                xAxisStartLabel: historyStartAxisText,
                primaryTextColor: primaryTextColor,
                secondaryTextColor: secondaryTextColor
            )

            PerformanceStatGrid(items: [
                PerformanceStatItem(label: "Received", value: PerformanceFormat.bytes(snapshot.network.receivedBytes)),
                PerformanceStatItem(label: "Sent", value: PerformanceFormat.bytes(snapshot.network.sentBytes)),
            ], primaryTextColor: primaryTextColor, secondaryTextColor: secondaryTextColor)

            PerformanceInterfaceList(
                interfaces: snapshot.network.interfaces,
                primaryTextColor: primaryTextColor,
                secondaryTextColor: secondaryTextColor
            )
        }
    }

    private var batteryValue: String {
        guard let level = snapshot.battery.level else {
            return "No battery"
        }
        return PerformanceFormat.percent(level)
    }

    private var batterySourceText: String {
        guard snapshot.battery.level != nil else {
            return "-"
        }
        return snapshot.battery.isPluggedIn ? "Power" : "Battery"
    }

    private var batteryTimeText: String {
        guard let minutes = snapshot.battery.timeRemainingMinutes else {
            return "-"
        }
        return PerformanceFormat.duration(minutes)
    }

    private var batteryDetail: String {
        let battery = snapshot.battery

        guard battery.level != nil else {
            return "No battery reported"
        }

        if battery.isCharging {
            if let minutes = battery.timeRemainingMinutes {
                return "Charging, full in \(PerformanceFormat.duration(minutes))"
            }
            return "Charging"
        }

        if battery.isPluggedIn {
            return "Connected to power"
        }

        if let minutes = battery.timeRemainingMinutes {
            return "\(PerformanceFormat.duration(minutes)) remaining"
        }

        return "On battery"
    }

    private var historyWindowText: String {
        PerformanceFormat.historyWindow(history)
    }

    private var historyStartAxisText: String {
        PerformanceFormat.historyStartAxis(history)
    }

    private func performFocusedAction() {
        if viewModel.settingsFocusedIndex == 0 {
            viewModel.navigateBack()
            return
        }

        guard section == .overview else {
            return
        }

        let sectionIndex = viewModel.settingsFocusedIndex - 1
        guard detailSections.indices.contains(sectionIndex) else {
            return
        }

        viewModel.pushTo(.performance(detailSections[sectionIndex]))
    }

    private func syncProcessDetailsSampling() {
        monitor.setProcessDetailsActive(section == .memory)
    }
}

private struct PerformanceHomeMetric: View {
    let label: String
    let detail: String
    let icon: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(tint)
                    .frame(width: 11)

                Text(label)
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(.white.opacity(0.46))
                    .lineLimit(1)
                    .minimumScaleFactor(0.62)
            }

            Text(detail)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundColor(.white.opacity(0.88))
                .lineLimit(1)
                .minimumScaleFactor(0.48)
                .layoutPriority(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.white.opacity(0.035))
        )
    }
}

private struct PerformanceOverviewCard: View {
    let section: PerformanceSection
    let snapshot: PerformanceSnapshot
    let primaryTextColor: Color
    let secondaryTextColor: Color
    let isFocused: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(tint)
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(section.title)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(primaryTextColor.opacity(0.9))

                        Text(detail)
                            .font(.system(size: 10))
                            .foregroundColor(secondaryTextColor)
                            .lineLimit(1)
                    }

                    PerformanceProgressBar(value: progress, tint: tint)
                }

                Spacer(minLength: 8)

                Text(value)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundColor(primaryTextColor.opacity(0.92))
                    .lineLimit(1)
                    .minimumScaleFactor(0.74)

                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(secondaryTextColor.opacity(0.85))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isFocused ? Color.white.opacity(0.12) : (isHovered ? Color.white.opacity(0.08) : Color.white.opacity(0.05)))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isFocused ? Color.white.opacity(0.25) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
    }

    private var icon: String {
        switch section {
        case .overview: return "gauge.with.dots.needle.33percent"
        case .cpu: return "cpu"
        case .memory: return "memorychip"
        case .battery: return PerformanceFormat.batteryIcon(snapshot.battery)
        case .network: return "antenna.radiowaves.left.and.right"
        }
    }

    private var value: String {
        switch section {
        case .overview:
            return PerformanceFormat.sampleAge(snapshot.sampledAt)
        case .cpu:
            return PerformanceFormat.percent(snapshot.cpuUsage)
        case .memory:
            return PerformanceFormat.memoryPair(snapshot.memory)
        case .battery:
            guard let level = snapshot.battery.level else { return "AC" }
            return PerformanceFormat.percent(level)
        case .network:
            return PerformanceFormat.compactNetwork(snapshot.network)
        }
    }

    private var detail: String {
        switch section {
        case .overview:
            return "Updated \(PerformanceFormat.sampleAge(snapshot.sampledAt))"
        case .cpu:
            return "Active \(Foundation.ProcessInfo.processInfo.activeProcessorCount)/\(Foundation.ProcessInfo.processInfo.processorCount) cores"
        case .memory:
            return "\(PerformanceFormat.percent(snapshot.memory.usage)) used"
        case .battery:
            if snapshot.battery.isCharging { return "Charging" }
            return snapshot.battery.isPluggedIn ? "Power" : "Battery"
        case .network:
            return "\(snapshot.network.interfaces.count) interfaces"
        }
    }

    private var progress: Double {
        switch section {
        case .overview:
            return min(max((snapshot.cpuUsage + snapshot.memory.usage) / 2, 0), 1)
        case .cpu:
            return snapshot.cpuUsage
        case .memory:
            return snapshot.memory.usage
        case .battery:
            return snapshot.battery.level ?? 0
        case .network:
            let bytes = Double(snapshot.network.downloadBytesPerSecond + snapshot.network.uploadBytesPerSecond)
            return min(bytes / 2_000_000, 1)
        }
    }

    private var tint: Color {
        switch section {
        case .overview:
            return TerminalColors.green
        case .cpu:
            return PerformancePalette.cpu(snapshot.cpuUsage)
        case .memory:
            return PerformancePalette.memory(snapshot.memory.usage)
        case .battery:
            return PerformancePalette.battery(snapshot.battery)
        case .network:
            return TerminalColors.cyan
        }
    }
}

private struct PerformanceHeroPanel: View {
    let icon: String
    let title: String
    let value: String
    let subtitle: String
    let progress: Double?
    let tint: Color
    let primaryTextColor: Color
    let secondaryTextColor: Color

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(tint)
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(primaryTextColor.opacity(0.92))

                    Text(subtitle)
                        .font(.system(size: 10))
                        .foregroundColor(secondaryTextColor)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                Text(value)
                    .font(.system(size: 17, weight: .bold, design: .monospaced))
                    .foregroundColor(primaryTextColor.opacity(0.95))
                    .lineLimit(1)
                    .minimumScaleFactor(0.62)
            }

            if let progress {
                PerformanceProgressBar(value: progress, tint: tint)
                    .frame(height: 6)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.white.opacity(0.06))
        )
    }
}

private struct PerformanceStatItem: Identifiable {
    let label: String
    let value: String

    var id: String { label }
}

private struct PerformanceStatGrid: View {
    let items: [PerformanceStatItem]
    let primaryTextColor: Color
    let secondaryTextColor: Color

    private let columns = [
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8),
    ]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 8) {
            ForEach(items) { item in
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.label)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(secondaryTextColor)
                        .lineLimit(1)

                    Text(item.value)
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundColor(primaryTextColor.opacity(0.9))
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.white.opacity(0.05))
                )
            }
        }
    }
}

private struct PerformanceMemoryBreakdownPanel: View {
    let memory: PerformanceMemorySnapshot
    let history: [PerformanceHistorySample]
    let xAxisStartLabel: String
    let primaryTextColor: Color
    let secondaryTextColor: Color

    private var pressureSeries: [PerformanceChartSeries] {
        [
            PerformanceChartSeries(
                id: "used",
                label: "Used",
                value: PerformanceFormat.percent(memory.usage),
                tint: PerformancePalette.memory(memory.usage),
                points: historyPoints(\.memoryUsage, fallback: memory.usage)
            ),
            PerformanceChartSeries(
                id: "app",
                label: "App",
                value: PerformanceFormat.percent(memory.appMemoryUsage),
                tint: TerminalColors.blue,
                points: historyPoints(\.appMemoryUsage, fallback: memory.appMemoryUsage)
            ),
            PerformanceChartSeries(
                id: "wired",
                label: "Wired",
                value: PerformanceFormat.percent(memory.wiredMemoryUsage),
                tint: TerminalColors.amber,
                points: historyPoints(\.wiredMemoryUsage, fallback: memory.wiredMemoryUsage)
            ),
            PerformanceChartSeries(
                id: "compressed",
                label: "Compressed",
                value: PerformanceFormat.percent(memory.compressedUsage),
                tint: TerminalColors.magenta,
                points: historyPoints(\.compressedMemoryUsage, fallback: memory.compressedUsage)
            ),
            PerformanceChartSeries(
                id: "cached",
                label: "Cached",
                value: PerformanceFormat.percent(memory.cachedFilesUsage),
                tint: TerminalColors.cyan,
                points: historyPoints(\.cachedFilesUsage, fallback: memory.cachedFilesUsage)
            ),
        ]
    }

    private var hasEnoughPressureData: Bool {
        pressureSeries.contains { item in
            item.points.compactMap { $0 }.count > 1
        }
    }

    private var leftItems: [PerformanceStatItem] {
        [
            PerformanceStatItem(label: "Physical Memory", value: PerformanceFormat.bytes(memory.totalBytes)),
            PerformanceStatItem(label: "Memory Used", value: PerformanceFormat.bytes(memory.usedBytes)),
            PerformanceStatItem(label: "Cached Files", value: PerformanceFormat.bytes(memory.cachedFilesBytes)),
            PerformanceStatItem(label: "Swap Used", value: PerformanceFormat.bytes(memory.swapUsedBytes)),
        ]
    }

    private var rightItems: [PerformanceStatItem] {
        [
            PerformanceStatItem(label: "App Memory", value: PerformanceFormat.bytes(memory.appMemoryBytes)),
            PerformanceStatItem(label: "Wired Memory", value: PerformanceFormat.bytes(memory.wiredMemoryBytes)),
            PerformanceStatItem(label: "Compressed", value: PerformanceFormat.bytes(memory.compressedBytes)),
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("MEMORY PRESSURE")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(secondaryTextColor.opacity(0.92))
                    .lineLimit(1)

                Spacer(minLength: 8)

                Text(PerformanceFormat.percent(memory.usage))
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundColor(primaryTextColor.opacity(0.86))
            }

            if hasEnoughPressureData {
                PerformanceLineChart(
                    series: pressureSeries,
                    fixedRange: 0...1,
                    yAxisLabel: PerformanceFormat.percent,
                    xAxisStartLabel: xAxisStartLabel,
                    axisColor: secondaryTextColor.opacity(0.68),
                    gridColor: secondaryTextColor.opacity(0.12)
                )
                .frame(height: 102)
            } else {
                Text("Collecting memory samples")
                    .font(.system(size: 10))
                    .foregroundColor(secondaryTextColor)
                    .frame(maxWidth: .infinity, minHeight: 102, alignment: .center)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.white.opacity(0.035))
                    )
            }

            PerformanceMemorySeriesLegend(
                series: pressureSeries,
                primaryTextColor: primaryTextColor,
                secondaryTextColor: secondaryTextColor
            )

            HStack(alignment: .top, spacing: 10) {
                PerformanceMemoryMetricColumn(
                    items: leftItems,
                    primaryTextColor: primaryTextColor,
                    secondaryTextColor: secondaryTextColor
                )

                Divider()
                    .background(secondaryTextColor.opacity(0.22))

                PerformanceMemoryMetricColumn(
                    items: rightItems,
                    primaryTextColor: primaryTextColor,
                    secondaryTextColor: secondaryTextColor
                )
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.white.opacity(0.05))
        )
    }

    private func historyPoints(_ keyPath: KeyPath<PerformanceHistorySample, Double>, fallback: Double) -> [Double] {
        let points = history.map { $0[keyPath: keyPath] }
        return points.isEmpty ? [fallback] : points
    }
}

private struct PerformanceMemorySeriesLegend: View {
    let series: [PerformanceChartSeries]
    let primaryTextColor: Color
    let secondaryTextColor: Color

    private let columns = [
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8),
    ]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 5) {
            ForEach(series) { item in
                HStack(spacing: 5) {
                    Circle()
                        .fill(item.tint)
                        .frame(width: 6, height: 6)

                    Text(item.label)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(secondaryTextColor)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)

                    Spacer(minLength: 4)

                    Text(item.value)
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundColor(primaryTextColor.opacity(0.86))
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                }
            }
        }
        .padding(.horizontal, 2)
    }
}

private struct PerformanceMemoryMetricColumn: View {
    let items: [PerformanceStatItem]
    let primaryTextColor: Color
    let secondaryTextColor: Color

    var body: some View {
        VStack(spacing: 7) {
            ForEach(items) { item in
                HStack(spacing: 6) {
                    Text(item.label)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(secondaryTextColor)
                        .lineLimit(1)
                        .minimumScaleFactor(0.68)

                    Spacer(minLength: 4)

                    Text(item.value)
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundColor(primaryTextColor.opacity(0.88))
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
    }
}

private struct PerformanceChartSeries: Identifiable {
    let id: String
    let label: String
    let value: String
    let tint: Color
    let points: [Double?]

    init(id: String, label: String, value: String, tint: Color, points: [Double]) {
        self.id = id
        self.label = label
        self.value = value
        self.tint = tint
        self.points = points.map(Optional.some)
    }

    init(id: String, label: String, value: String, tint: Color, points: [Double?]) {
        self.id = id
        self.label = label
        self.value = value
        self.tint = tint
        self.points = points
    }
}

private struct PerformanceHoverValue: Identifiable {
    let id: String
    let label: String
    let value: String
    let tint: Color
}

private struct PerformanceTrendPanel: View {
    let title: String
    let subtitle: String
    let series: [PerformanceChartSeries]
    let fixedRange: ClosedRange<Double>?
    let yAxisLabel: (Double) -> String
    let xAxisStartLabel: String
    let primaryTextColor: Color
    let secondaryTextColor: Color

    private var hasEnoughData: Bool {
        series.contains { chartSeries in
            chartSeries.points.compactMap { $0 }.count > 1
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(primaryTextColor.opacity(0.84))
                    .lineLimit(1)

                Spacer(minLength: 8)

                Text(subtitle)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(secondaryTextColor)
                    .lineLimit(1)
            }

            if hasEnoughData {
                PerformanceLineChart(
                    series: series,
                    fixedRange: fixedRange,
                    yAxisLabel: yAxisLabel,
                    xAxisStartLabel: xAxisStartLabel,
                    axisColor: secondaryTextColor.opacity(0.68),
                    gridColor: secondaryTextColor.opacity(0.12)
                )
                .frame(height: 102)
            } else {
                Text("Collecting trend samples")
                    .font(.system(size: 10))
                    .foregroundColor(secondaryTextColor)
                    .frame(maxWidth: .infinity, minHeight: 102, alignment: .center)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.white.opacity(0.035))
                    )
            }

            HStack(spacing: 10) {
                ForEach(series) { item in
                    HStack(spacing: 5) {
                        Circle()
                            .fill(item.tint)
                            .frame(width: 6, height: 6)

                        Text(item.label)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(secondaryTextColor)
                            .lineLimit(1)

                        Text(item.value)
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundColor(primaryTextColor.opacity(0.86))
                            .lineLimit(1)
                            .minimumScaleFactor(0.72)
                    }
                }

                Spacer(minLength: 0)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.white.opacity(0.05))
        )
    }
}

private struct PerformanceLineChart: View {
    @State private var hoverLocation: CGPoint?

    let series: [PerformanceChartSeries]
    let fixedRange: ClosedRange<Double>?
    let yAxisLabel: (Double) -> String
    let xAxisStartLabel: String
    let axisColor: Color
    let gridColor: Color

    private let plotInsets = EdgeInsets(top: 6, leading: 36, bottom: 17, trailing: 7)

    private var chartRange: ClosedRange<Double> {
        if let fixedRange {
            return fixedRange
        }

        let maxValue = series
            .flatMap { $0.points.compactMap { $0 } }
            .max() ?? 1
        return 0...max(maxValue, 1)
    }

    private var sampleCount: Int {
        series.map(\.points.count).max() ?? 0
    }

    var body: some View {
        GeometryReader { proxy in
            let range = chartRange
            let plotRect = plotRect(in: proxy.size)
            let hoverIndex = hoverLocation.flatMap { nearestIndex(for: $0.x, in: plotRect) }

            ZStack {
                gridPath(in: plotRect)
                    .stroke(gridColor, lineWidth: 1)

                ForEach(Array(series.enumerated()), id: \.element.id) { index, chartSeries in
                    if index == 0 {
                        areaPath(for: chartSeries, in: plotRect, range: range)
                            .fill(
                                LinearGradient(
                                    colors: [
                                        chartSeries.tint.opacity(0.24),
                                        chartSeries.tint.opacity(0.02),
                                    ],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                    }

                    linePath(for: chartSeries, in: plotRect, range: range)
                        .stroke(
                            chartSeries.tint.opacity(0.95),
                            style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)
                        )
                }

                if let hoverIndex {
                    hoverOverlay(index: hoverIndex, in: plotRect, range: range)
                }

                axisLabels(in: proxy.size, range: range)
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    hoverLocation = location
                case .ended:
                    hoverLocation = nil
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.white.opacity(0.035))
        )
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    @ViewBuilder
    private func hoverOverlay(index: Int, in plotRect: CGRect, range: ClosedRange<Double>) -> some View {
        let x = chartX(index: index, count: sampleCount, plotRect: plotRect)
        let values = hoverValues(at: index)

        ZStack(alignment: .topLeading) {
            hoverLinePath(x: x, in: plotRect)
                .stroke(
                    axisColor.opacity(0.72),
                    style: StrokeStyle(lineWidth: 1, lineCap: .round, dash: [3, 3])
                )

            ForEach(series) { chartSeries in
                if index < chartSeries.points.count,
                   let value = chartSeries.points[index] {
                    Circle()
                        .fill(chartSeries.tint)
                        .frame(width: 6, height: 6)
                        .overlay(
                            Circle()
                                .stroke(Color.black.opacity(0.55), lineWidth: 1)
                        )
                        .position(
                            chartPoint(
                                value: value,
                                index: index,
                                count: chartSeries.points.count,
                                plotRect: plotRect,
                                range: range
                            )
                        )
                }
            }

            if !values.isEmpty {
                hoverTooltip(values: values, x: x, plotRect: plotRect)
            }
        }
    }

    private func hoverTooltip(values: [PerformanceHoverValue], x: CGFloat, plotRect: CGRect) -> some View {
        let width: CGFloat = 114
        let rowHeight: CGFloat = 15
        let height = CGFloat(values.count) * rowHeight + 12

        return VStack(alignment: .leading, spacing: 4) {
            ForEach(values) { item in
                HStack(spacing: 5) {
                    Circle()
                        .fill(item.tint)
                        .frame(width: 5, height: 5)

                    Text(item.label)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(.white.opacity(0.62))
                        .lineLimit(1)

                    Spacer(minLength: 4)

                    Text(item.value)
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundColor(.white.opacity(0.9))
                        .lineLimit(1)
                        .minimumScaleFactor(0.68)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(width: width, height: height, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.black.opacity(0.78))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
        .position(
            x: tooltipX(for: x, width: width, in: plotRect),
            y: plotRect.minY + height / 2 + 6
        )
    }

    private func axisLabels(in size: CGSize, range: ClosedRange<Double>) -> some View {
        let plotRect = plotRect(in: size)
        let middleValue = range.lowerBound + (range.upperBound - range.lowerBound) / 2

        return ZStack(alignment: .topLeading) {
            VStack(alignment: .trailing, spacing: 0) {
                Text(yAxisLabel(range.upperBound))
                    .frame(height: 12, alignment: .topTrailing)

                Spacer(minLength: 0)

                Text(yAxisLabel(middleValue))
                    .frame(height: 12, alignment: .trailing)

                Spacer(minLength: 0)

                Text(yAxisLabel(range.lowerBound))
                    .frame(height: 12, alignment: .bottomTrailing)
            }
            .font(.system(size: 8, weight: .medium, design: .monospaced))
            .foregroundColor(axisColor)
            .lineLimit(1)
            .minimumScaleFactor(0.65)
            .frame(width: plotInsets.leading - 7, height: plotRect.height)
            .position(
                x: (plotInsets.leading - 7) / 2,
                y: plotRect.midY
            )

            HStack {
                Text(xAxisStartLabel)

                Spacer(minLength: 0)

                Text("now")
            }
            .font(.system(size: 8, weight: .medium, design: .monospaced))
            .foregroundColor(axisColor)
            .lineLimit(1)
            .minimumScaleFactor(0.72)
            .frame(width: plotRect.width)
            .position(x: plotRect.midX, y: plotRect.maxY + 9)
        }
    }

    private func hoverValues(at index: Int) -> [PerformanceHoverValue] {
        series.compactMap { chartSeries in
            guard index < chartSeries.points.count,
                  let value = chartSeries.points[index] else {
                return nil
            }

            return PerformanceHoverValue(
                id: chartSeries.id,
                label: chartSeries.label,
                value: yAxisLabel(value),
                tint: chartSeries.tint
            )
        }
    }

    private func nearestIndex(for x: CGFloat, in plotRect: CGRect) -> Int? {
        guard sampleCount > 1, plotRect.width > 0 else { return nil }

        let normalized = min(max((x - plotRect.minX) / plotRect.width, 0), 1)
        let rawIndex = Int((normalized * CGFloat(sampleCount - 1)).rounded())
        return min(max(rawIndex, 0), sampleCount - 1)
    }

    private func chartX(index: Int, count: Int, plotRect: CGRect) -> CGFloat {
        let divisor = max(count - 1, 1)
        return plotRect.minX + plotRect.width * CGFloat(index) / CGFloat(divisor)
    }

    private func tooltipX(for x: CGFloat, width: CGFloat, in plotRect: CGRect) -> CGFloat {
        min(max(x, plotRect.minX + width / 2), plotRect.maxX - width / 2)
    }

    private func hoverLinePath(x: CGFloat, in plotRect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: x, y: plotRect.minY))
            path.addLine(to: CGPoint(x: x, y: plotRect.maxY))
        }
    }

    private func plotRect(in size: CGSize) -> CGRect {
        let width = max(1, size.width - plotInsets.leading - plotInsets.trailing)
        let height = max(1, size.height - plotInsets.top - plotInsets.bottom)
        return CGRect(x: plotInsets.leading, y: plotInsets.top, width: width, height: height)
    }

    private func gridPath(in plotRect: CGRect) -> Path {
        Path { path in
            guard plotRect.width > 0, plotRect.height > 0 else { return }

            for step in 1...3 {
                let y = plotRect.minY + plotRect.height * CGFloat(step) / 4
                path.move(to: CGPoint(x: plotRect.minX, y: y))
                path.addLine(to: CGPoint(x: plotRect.maxX, y: y))
            }

            for step in 1...3 {
                let x = plotRect.minX + plotRect.width * CGFloat(step) / 4
                path.move(to: CGPoint(x: x, y: plotRect.minY))
                path.addLine(to: CGPoint(x: x, y: plotRect.maxY))
            }
        }
    }

    private func linePath(for series: PerformanceChartSeries, in plotRect: CGRect, range: ClosedRange<Double>) -> Path {
        Path { path in
            var hasStarted = false

            for (index, value) in series.points.enumerated() {
                guard let value else {
                    hasStarted = false
                    continue
                }

                let point = chartPoint(
                    value: value,
                    index: index,
                    count: series.points.count,
                    plotRect: plotRect,
                    range: range
                )

                if hasStarted {
                    path.addLine(to: point)
                } else {
                    path.move(to: point)
                    hasStarted = true
                }
            }
        }
    }

    private func areaPath(for series: PerformanceChartSeries, in plotRect: CGRect, range: ClosedRange<Double>) -> Path {
        let points = series.points.enumerated().compactMap { index, value -> CGPoint? in
            guard let value else { return nil }
            return chartPoint(
                value: value,
                index: index,
                count: series.points.count,
                plotRect: plotRect,
                range: range
            )
        }

        return Path { path in
            guard points.count > 1, let first = points.first, let last = points.last else { return }

            path.move(to: CGPoint(x: first.x, y: plotRect.maxY))
            path.addLine(to: first)

            for point in points.dropFirst() {
                path.addLine(to: point)
            }

            path.addLine(to: CGPoint(x: last.x, y: plotRect.maxY))
            path.closeSubpath()
        }
    }

    private func chartPoint(
        value: Double,
        index: Int,
        count: Int,
        plotRect: CGRect,
        range: ClosedRange<Double>
    ) -> CGPoint {
        let x = chartX(index: index, count: count, plotRect: plotRect)
        let span = max(range.upperBound - range.lowerBound, 0.0001)
        let clampedValue = min(max(value, range.lowerBound), range.upperBound)
        let normalized = (clampedValue - range.lowerBound) / span
        let y = plotRect.minY + plotRect.height * CGFloat(1 - normalized)
        return CGPoint(x: x, y: y)
    }
}

private struct PerformanceCoreUsagePanel: View {
    let usages: [Double]
    let primaryTextColor: Color
    let secondaryTextColor: Color

    private let columns = [
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Per Core")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(primaryTextColor.opacity(0.82))

            if usages.isEmpty {
                Text("Waiting for the next CPU sample")
                    .font(.system(size: 10))
                    .foregroundColor(secondaryTextColor)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                LazyVGrid(columns: columns, spacing: 7) {
                    ForEach(Array(usages.enumerated()), id: \.offset) { index, usage in
                        HStack(spacing: 7) {
                            Text("#\(index + 1)")
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                                .foregroundColor(secondaryTextColor)
                                .frame(width: 26, alignment: .leading)

                            PerformanceProgressBar(value: usage, tint: PerformancePalette.cpu(usage))

                            Text(PerformanceFormat.percent(usage))
                                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                .foregroundColor(primaryTextColor.opacity(0.82))
                                .frame(width: 34, alignment: .trailing)
                        }
                    }
                }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.white.opacity(0.05))
        )
    }
}

private struct PerformanceProcessList: View {
    let processes: [PerformanceProcessSnapshot]
    let primaryTextColor: Color
    let secondaryTextColor: Color

    @State private var expandedGroupIds: Set<String> = []
    @State private var didApplyDefaultExpansion = false

    private var groups: [PerformanceProcessGroup] {
        PerformanceProcessGrouper.groups(from: processes)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("Processes")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(primaryTextColor.opacity(0.82))

                Spacer()

                Text("Grouped by app")
                    .font(.system(size: 10))
                    .foregroundColor(secondaryTextColor)
            }

            if processes.isEmpty {
                Text("No process memory data available")
                    .font(.system(size: 10))
                    .foregroundColor(secondaryTextColor)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
            } else {
                LazyVStack(spacing: 4) {
                    ForEach(groups) { group in
                        PerformanceProcessGroupView(
                            group: group,
                            isExpanded: expandedGroupIds.contains(group.id),
                            toggleExpansion: {
                                toggleGroup(group)
                            },
                            primaryTextColor: primaryTextColor,
                            secondaryTextColor: secondaryTextColor
                        )
                    }
                }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.white.opacity(0.05))
        )
        .onAppear {
            syncDefaultExpandedGroups()
        }
        .onChange(of: processes) { _, _ in
            syncDefaultExpandedGroups()
        }
    }

    private func toggleGroup(_ group: PerformanceProcessGroup) {
        guard group.canExpand else { return }

        if expandedGroupIds.contains(group.id) {
            expandedGroupIds.remove(group.id)
        } else {
            expandedGroupIds.insert(group.id)
        }
    }

    private func syncDefaultExpandedGroups() {
        let currentGroupIds = Set(groups.map(\.id))
        expandedGroupIds = expandedGroupIds.intersection(currentGroupIds)

        guard !didApplyDefaultExpansion else { return }

        expandedGroupIds.formUnion(
            groups
                .filter(\.canExpand)
                .prefix(4)
                .map(\.id)
        )
        didApplyDefaultExpansion = true
    }
}

private struct PerformanceProcessGroup: Identifiable {
    let id: String
    let name: String
    let appPath: String?
    let processes: [PerformanceProcessSnapshot]

    var representativeProcess: PerformanceProcessSnapshot? {
        processes.first
    }

    var canExpand: Bool {
        processes.count > 1
    }

    var totalResidentMemoryBytes: UInt64 {
        processes.reduce(UInt64(0)) { $0 + $1.residentMemoryBytes }
    }

    var totalMemoryUsage: Double {
        processes.reduce(0) { $0 + $1.memoryUsage }
    }
}

@MainActor
private enum PerformanceProcessGrouper {
    static func groups(from processes: [PerformanceProcessSnapshot]) -> [PerformanceProcessGroup] {
        let grouped = Dictionary(grouping: processes) { process in
            if let appPath = PerformanceProcessApplicationResolver.appPath(for: process) {
                return "app:\(appPath)"
            }

            return "process:\(process.pid)"
        }

        return grouped.map { key, processes in
            let sortedProcesses = processes.sorted {
                if $0.residentMemoryBytes == $1.residentMemoryBytes {
                    return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                }
                return $0.residentMemoryBytes > $1.residentMemoryBytes
            }

            let appPath = sortedProcesses
                .compactMap(PerformanceProcessApplicationResolver.appPath(for:))
                .first

            return PerformanceProcessGroup(
                id: key,
                name: appPath.map(PerformanceProcessApplicationResolver.displayName(forAppPath:)) ?? (sortedProcesses.first?.name ?? "Process"),
                appPath: appPath,
                processes: sortedProcesses
            )
        }
        .sorted {
            if $0.totalResidentMemoryBytes == $1.totalResidentMemoryBytes {
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
            return $0.totalResidentMemoryBytes > $1.totalResidentMemoryBytes
        }
    }
}

private enum PerformanceProcessApplicationResolver {
    static func appPath(for process: PerformanceProcessSnapshot) -> String? {
        guard let executablePath = process.executablePath else {
            return nil
        }

        return containingAppPath(for: executablePath)
    }

    static func displayName(forAppPath appPath: String) -> String {
        if let bundleName = Bundle(path: appPath)?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String,
           !bundleName.isEmpty {
            return bundleName
        }

        if let bundleName = Bundle(path: appPath)?.object(forInfoDictionaryKey: "CFBundleName") as? String,
           !bundleName.isEmpty {
            return bundleName
        }

        let fileName = URL(fileURLWithPath: appPath).deletingPathExtension().lastPathComponent
        return fileName.isEmpty ? "Application" : fileName
    }

    static func containingAppPath(for executablePath: String) -> String? {
        var path = executablePath
        var appPath: String?

        while !path.isEmpty, path != "/" {
            if path.hasSuffix(".app") {
                appPath = path
            }

            path = (path as NSString).deletingLastPathComponent
        }

        return appPath
    }
}

private struct PerformanceProcessGroupView: View {
    let group: PerformanceProcessGroup
    let isExpanded: Bool
    let toggleExpansion: () -> Void
    let primaryTextColor: Color
    let secondaryTextColor: Color

    var body: some View {
        VStack(spacing: 3) {
            Button(action: toggleExpansion) {
                HStack(spacing: 8) {
                    Image(systemName: group.canExpand ? "chevron.right" : "circle.fill")
                        .font(.system(size: group.canExpand ? 9 : 4, weight: .semibold))
                        .foregroundColor(secondaryTextColor.opacity(group.canExpand ? 0.78 : 0.35))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .frame(width: 10)

                    PerformanceProcessGroupIcon(
                        group: group,
                        fallbackColor: secondaryTextColor
                    )

                    VStack(alignment: .leading, spacing: 2) {
                        Text(group.name)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(primaryTextColor.opacity(0.9))
                            .lineLimit(1)

                        Text(groupSubtitle)
                            .font(.system(size: 9, weight: .medium))
                            .foregroundColor(secondaryTextColor)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 8)

                    Text(PerformanceFormat.percent(group.totalMemoryUsage))
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundColor(secondaryTextColor)
                        .frame(width: 42, alignment: .trailing)

                    Text(PerformanceFormat.bytes(group.totalResidentMemoryBytes))
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundColor(primaryTextColor.opacity(0.9))
                        .frame(width: 72, alignment: .trailing)
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.white.opacity(0.055))
                )
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())

            if isExpanded {
                VStack(spacing: 3) {
                    ForEach(group.processes) { process in
                        PerformanceProcessRow(
                            process: process,
                            primaryTextColor: primaryTextColor,
                            secondaryTextColor: secondaryTextColor,
                            isChild: true
                        )
                    }
                }
                .padding(.leading, 18)
            }
        }
    }

    private var groupSubtitle: String {
        if group.processes.count == 1,
           let process = group.representativeProcess {
            return "pid \(process.pid)"
        }

        return "\(group.processes.count) processes"
    }
}

private struct PerformanceProcessGroupIcon: View {
    let group: PerformanceProcessGroup
    let fallbackColor: Color

    var body: some View {
        Group {
            if let appPath = group.appPath,
               let icon = PerformanceProcessIconProvider.icon(forAppPath: appPath) {
                Image(nsImage: icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            } else if let process = group.representativeProcess,
                      let icon = PerformanceProcessIconProvider.icon(for: process) {
                Image(nsImage: icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.white.opacity(0.06))

                    Image(systemName: "app.dashed")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(fallbackColor.opacity(0.85))
                }
            }
        }
        .frame(width: 20, height: 20)
        .accessibilityHidden(true)
    }
}

private struct PerformanceProcessRow: View {
    let process: PerformanceProcessSnapshot
    let primaryTextColor: Color
    let secondaryTextColor: Color
    var isChild = false

    var body: some View {
        HStack(spacing: 8) {
            PerformanceProcessIcon(
                process: process,
                fallbackColor: secondaryTextColor
            )

            VStack(alignment: .leading, spacing: 2) {
                Text(process.name)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(primaryTextColor.opacity(0.86))
                    .lineLimit(1)

                Text("pid \(process.pid)")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundColor(secondaryTextColor)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Text(PerformanceFormat.percent(process.memoryUsage))
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundColor(secondaryTextColor)
                .frame(width: 42, alignment: .trailing)

            Text(PerformanceFormat.bytes(process.residentMemoryBytes))
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundColor(primaryTextColor.opacity(0.88))
                .frame(width: 72, alignment: .trailing)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, isChild ? 5 : 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.white.opacity(isChild ? 0.026 : 0.035))
        )
    }
}

private struct PerformanceProcessIcon: View {
    let process: PerformanceProcessSnapshot
    let fallbackColor: Color

    var body: some View {
        Group {
            if let icon = PerformanceProcessIconProvider.icon(for: process) {
                Image(nsImage: icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.white.opacity(0.06))

                    Image(systemName: "terminal")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(fallbackColor.opacity(0.85))
                }
            }
        }
        .frame(width: 20, height: 20)
        .accessibilityHidden(true)
    }
}

@MainActor
private enum PerformanceProcessIconProvider {
    private static let iconSize = NSSize(width: 20, height: 20)
    private static let iconCacheCost = 20 * 20 * 4
    private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 160
        cache.totalCostLimit = 1_000_000
        return cache
    }()

    static func icon(for process: PerformanceProcessSnapshot) -> NSImage? {
        let cacheKey = processIconCacheKey(for: process) as NSString
        if let cachedIcon = cache.object(forKey: cacheKey) {
            return cachedIcon
        }

        guard let resolvedIcon = resolveIcon(for: process) else {
            return nil
        }

        let cachedIcon = thumbnail(from: resolvedIcon)
        cache.setObject(cachedIcon, forKey: cacheKey, cost: iconCacheCost)
        return cachedIcon
    }

    static func icon(forAppPath appPath: String) -> NSImage? {
        let cacheKey = appPath as NSString
        if let cachedIcon = cache.object(forKey: cacheKey) {
            return cachedIcon
        }

        let cachedIcon = thumbnail(from: NSWorkspace.shared.icon(forFile: appPath))
        cache.setObject(cachedIcon, forKey: cacheKey, cost: iconCacheCost)
        return cachedIcon
    }

    private static func resolveIcon(for process: PerformanceProcessSnapshot) -> NSImage? {
        if let runningIcon = NSRunningApplication(processIdentifier: process.pid)?.icon {
            return runningIcon
        }

        guard let executablePath = process.executablePath else {
            return nil
        }

        let iconPath = PerformanceProcessApplicationResolver.containingAppPath(for: executablePath) ?? executablePath
        return NSWorkspace.shared.icon(forFile: iconPath)
    }

    private static func processIconCacheKey(for process: PerformanceProcessSnapshot) -> String {
        if let executablePath = process.executablePath {
            return executablePath
        }

        return "\(process.pid):\(process.name)"
    }

    private static func thumbnail(from icon: NSImage) -> NSImage {
        let image = NSImage(size: iconSize)
        image.lockFocus()
        icon.draw(
            in: NSRect(origin: .zero, size: iconSize),
            from: .zero,
            operation: .sourceOver,
            fraction: 1
        )
        image.unlockFocus()
        return image
    }
}

private struct PerformanceInterfaceList: View {
    let interfaces: [PerformanceNetworkInterfaceSnapshot]
    let primaryTextColor: Color
    let secondaryTextColor: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("Interfaces")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(primaryTextColor.opacity(0.82))

                Spacer()

                Text("\(interfaces.count) active")
                    .font(.system(size: 10))
                    .foregroundColor(secondaryTextColor)
            }

            if interfaces.isEmpty {
                Text("No active network interfaces")
                    .font(.system(size: 10))
                    .foregroundColor(secondaryTextColor)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
            } else {
                LazyVStack(spacing: 5) {
                    ForEach(interfaces) { interface in
                        PerformanceInterfaceRow(
                            interface: interface,
                            primaryTextColor: primaryTextColor,
                            secondaryTextColor: secondaryTextColor
                        )
                    }
                }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.white.opacity(0.05))
        )
    }
}

private struct PerformanceInterfaceRow: View {
    let interface: PerformanceNetworkInterfaceSnapshot
    let primaryTextColor: Color
    let secondaryTextColor: Color

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Text(interface.name)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(primaryTextColor.opacity(0.88))

                Spacer()

                Text("↓ \(PerformanceFormat.speed(interface.downloadBytesPerSecond))")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundColor(TerminalColors.cyan.opacity(0.9))

                Text("↑ \(PerformanceFormat.speed(interface.uploadBytesPerSecond))")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundColor(TerminalColors.green.opacity(0.9))
            }

            Text("\(PerformanceFormat.bytes(interface.receivedBytes)) received / \(PerformanceFormat.bytes(interface.sentBytes)) sent")
                .font(.system(size: 10))
                .foregroundColor(secondaryTextColor)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.white.opacity(0.035))
        )
    }
}

private struct PerformanceInfoPanel: View {
    let title: String
    let rows: [(String, String)]
    let primaryTextColor: Color
    let secondaryTextColor: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(primaryTextColor.opacity(0.82))

            ForEach(rows, id: \.0) { row in
                HStack {
                    Text(row.0)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(secondaryTextColor)

                    Spacer()

                    Text(row.1)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(primaryTextColor.opacity(0.88))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.white.opacity(0.05))
        )
    }
}

private struct PerformanceProgressBar: View {
    let value: Double
    let tint: Color

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.white.opacity(0.12))

                RoundedRectangle(cornerRadius: 2)
                    .fill(tint.opacity(0.86))
                    .frame(width: max(0, min(proxy.size.width, proxy.size.width * min(max(value, 0), 1))))
            }
        }
        .frame(height: 4)
    }
}

private enum PerformancePalette {
    static func cpu(_ usage: Double) -> Color {
        if usage >= 0.85 { return TerminalColors.red }
        if usage >= 0.65 { return TerminalColors.amber }
        return TerminalColors.green
    }

    static func memory(_ usage: Double) -> Color {
        if usage >= 0.85 { return TerminalColors.red }
        if usage >= 0.72 { return TerminalColors.amber }
        return TerminalColors.blue
    }

    static func battery(_ battery: PerformanceBatterySnapshot) -> Color {
        guard let level = battery.level else {
            return .white.opacity(0.36)
        }
        if battery.isCharging || battery.isPluggedIn {
            return TerminalColors.green
        }
        if level <= 0.15 { return TerminalColors.red }
        if level <= 0.30 { return TerminalColors.amber }
        return TerminalColors.green
    }
}

private enum PerformanceFormat {
    nonisolated static func percent(_ value: Double) -> String {
        "\(Int((min(max(value, 0), 1) * 100).rounded()))%"
    }

    nonisolated static func memoryPair(_ memory: PerformanceMemorySnapshot) -> String {
        "\(compactBytes(memory.usedBytes))/\(compactBytes(memory.totalBytes))"
    }

    nonisolated static func compactBytes(_ bytes: UInt64) -> String {
        scaledBytes(bytes, units: ["B", "K", "M", "G", "T"], precisionLimit: 10, separator: "")
    }

    nonisolated static func bytes(_ bytes: UInt64) -> String {
        scaledBytes(bytes, units: ["B", "KB", "MB", "GB", "TB"], precisionLimit: 10, separator: " ")
    }

    nonisolated static func speed(_ bytesPerSecond: UInt64) -> String {
        "\(bytes(bytesPerSecond))/s"
    }

    nonisolated static func compactNetwork(_ network: PerformanceNetworkSnapshot) -> String {
        "↓\(compactSpeed(network.downloadBytesPerSecond)) ↑\(compactSpeed(network.uploadBytesPerSecond))"
    }

    nonisolated static func compactSpeed(_ bytesPerSecond: UInt64) -> String {
        "\(compactBytes(bytesPerSecond))/s"
    }

    nonisolated static func duration(_ minutes: Int) -> String {
        guard minutes >= 60 else {
            return "\(minutes)m"
        }
        let hours = minutes / 60
        let remainingMinutes = minutes % 60
        return remainingMinutes == 0 ? "\(hours)h" : "\(hours)h \(remainingMinutes)m"
    }

    nonisolated static func sampleAge(_ date: Date) -> String {
        let seconds = max(0, Int(Date().timeIntervalSince(date).rounded()))
        if seconds < 2 {
            return "now"
        }
        return "\(seconds)s ago"
    }

    nonisolated static func historyWindow(_ history: [PerformanceHistorySample]) -> String {
        guard let first = history.first,
              let last = history.last,
              history.count > 1 else {
            return "Collecting"
        }

        let seconds = max(1, Int(last.sampledAt.timeIntervalSince(first.sampledAt).rounded()))
        return "Last \(compactDuration(seconds))"
    }

    nonisolated static func historyStartAxis(_ history: [PerformanceHistorySample]) -> String {
        guard let first = history.first,
              let last = history.last,
              history.count > 1 else {
            return "start"
        }

        let seconds = max(1, Int(last.sampledAt.timeIntervalSince(first.sampledAt).rounded()))
        return "-\(compactDuration(seconds))"
    }

    nonisolated static func axisSpeed(_ bytesPerSecond: Double) -> String {
        speed(UInt64(max(0, bytesPerSecond.rounded())))
    }

    nonisolated static func batteryIcon(_ battery: PerformanceBatterySnapshot) -> String {
        guard let level = battery.level else {
            return "powerplug"
        }
        if battery.isCharging || battery.isPluggedIn {
            return "battery.100.bolt"
        }
        switch level {
        case ..<0.20:
            return "battery.25"
        case ..<0.55:
            return "battery.50"
        case ..<0.85:
            return "battery.75"
        default:
            return "battery.100"
        }
    }

    nonisolated private static func scaledBytes(_ bytes: UInt64, units: [String], precisionLimit: Double, separator: String) -> String {
        var value = Double(bytes)
        var unitIndex = 0

        while value >= 1024, unitIndex < units.count - 1 {
            value /= 1024
            unitIndex += 1
        }

        if unitIndex == 0 {
            return "\(Int(value))\(separator)\(units[unitIndex])"
        }

        if value >= precisionLimit {
            return "\(Int(value.rounded()))\(separator)\(units[unitIndex])"
        }

        return String(format: "%.1f%@%@", value, separator, units[unitIndex])
    }

    nonisolated private static func compactDuration(_ seconds: Int) -> String {
        guard seconds >= 60 else {
            return "\(seconds)s"
        }

        let minutes = seconds / 60
        let remainingSeconds = seconds % 60
        if remainingSeconds == 0 {
            return "\(minutes)m"
        }

        return "\(minutes)m \(remainingSeconds)s"
    }
}

private extension PerformanceMemorySnapshot {
    var freeBytes: UInt64 {
        totalBytes > usedBytes ? totalBytes - usedBytes : 0
    }
}
