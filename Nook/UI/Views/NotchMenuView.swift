//
//  NotchMenuView.swift
//  Nook
//
//  Minimal menu matching Dynamic Island aesthetic
//

import ApplicationServices
import Combine
import SwiftUI
import ServiceManagement

// MARK: - Content Height Measurement

private struct MenuContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

// MARK: - NotchMenuView

struct NotchMenuView: View {
    @ObservedObject var viewModel: NotchViewModel
    let primaryTextColor: Color
    let secondaryTextColor: Color
    let separatorColor: Color
    @ObservedObject private var updateManager = UpdateManager.shared
    @ObservedObject private var screenSelector = ScreenSelector.shared
    @ObservedObject private var soundSelector = SoundSelector.shared
    @State private var launchAtLogin: Bool = false
    @State private var didAppear = false
    @AppStorage(AppSettings.artworkAdaptiveBackgroundEnabledKey) private var artworkAdaptiveBackgroundEnabled = true
    @AppStorage(AppSettings.musicEdgeGlowEnabledKey) private var musicEdgeGlowEnabled = true
    @AppStorage(AppSettings.vibeGlowEnabledKey) private var vibeGlowEnabled = false
    @AppStorage(AppSettings.performanceMonitorEnabledKey) private var performanceMonitorEnabled = true

    var body: some View {
        // ScrollView so the menu gracefully scrolls when content exceeds the
        // panel height (e.g. both picker rows expanded on a small panel).
        ScrollView(.vertical, showsIndicators: true) {
            VStack(spacing: 4) {
                // Back button
                MenuRow(
                    icon: "chevron.left",
                    label: "Back",
                    primaryTextColor: primaryTextColor,
                    isFocused: viewModel.settingsFocusedIndex == 0
                ) {
                    viewModel.toggleMenu()
                }

                Divider()
                    .background(separatorColor)
                    .padding(.vertical, 4)

                // Appearance settings
                ScreenPickerRow(
                    screenSelector: screenSelector,
                    primaryTextColor: primaryTextColor,
                    secondaryTextColor: secondaryTextColor,
                    isFocused: viewModel.settingsFocusedIndex == 1
                )
                SoundPickerRow(
                    soundSelector: soundSelector,
                    primaryTextColor: primaryTextColor,
                    secondaryTextColor: secondaryTextColor,
                    isFocused: viewModel.settingsFocusedIndex == 2
                )

                MenuRow(
                    icon: "terminal",
                    label: "Agents...",
                    trailingIcon: "chevron.right",
                    primaryTextColor: primaryTextColor,
                    isFocused: viewModel.settingsFocusedIndex == 3
                ) {
                    viewModel.pushTo(.agents)
                }

                MenuRow(
                    icon: "keyboard",
                    label: "Keyboard Shortcuts...",
                    trailingIcon: "chevron.right",
                    primaryTextColor: primaryTextColor,
                    isFocused: viewModel.settingsFocusedIndex == 4
                ) {
                    viewModel.pushTo(.shortcuts)
                }

                Divider()
                    .background(separatorColor)
                    .padding(.vertical, 4)

                // Music settings
                MenuToggleRow(
                    icon: "photo",
                    label: "Artwork Adaptive Background",
                    isOn: artworkAdaptiveBackgroundEnabled,
                    primaryTextColor: primaryTextColor,
                    secondaryTextColor: secondaryTextColor,
                    isFocused: viewModel.settingsFocusedIndex == 5
                ) {
                    artworkAdaptiveBackgroundEnabled.toggle()
                }

                MenuToggleRow(
                    icon: "music.note",
                    label: "Music Edge Glow",
                    isOn: musicEdgeGlowEnabled,
                    primaryTextColor: primaryTextColor,
                    secondaryTextColor: secondaryTextColor,
                    isFocused: viewModel.settingsFocusedIndex == 6
                ) {
                    musicEdgeGlowEnabled.toggle()
                }

                MenuToggleRow(
                    icon: "sparkles",
                    label: "Vibe Glow",
                    isOn: vibeGlowEnabled,
                    primaryTextColor: primaryTextColor,
                    secondaryTextColor: secondaryTextColor,
                    isFocused: viewModel.settingsFocusedIndex == 7
                ) {
                    vibeGlowEnabled.toggle()
                }

                MenuToggleRow(
                    icon: "gauge.with.dots.needle.33percent",
                    label: "Performance Monitor",
                    isOn: performanceMonitorEnabled,
                    primaryTextColor: primaryTextColor,
                    secondaryTextColor: secondaryTextColor,
                    isFocused: viewModel.settingsFocusedIndex == 8
                ) {
                    performanceMonitorEnabled.toggle()
                }

                Divider()
                    .background(separatorColor)
                    .padding(.vertical, 4)

                // System settings
                MenuToggleRow(
                    icon: "power",
                    label: "Launch at Login",
                    isOn: launchAtLogin,
                    primaryTextColor: primaryTextColor,
                    secondaryTextColor: secondaryTextColor,
                    isFocused: viewModel.settingsFocusedIndex == 9
                ) {
                    do {
                        if launchAtLogin {
                            try SMAppService.mainApp.unregister()
                            launchAtLogin = false
                        } else {
                            try SMAppService.mainApp.register()
                            launchAtLogin = true
                        }
                    } catch {
                        print("Failed to toggle launch at login: \(error)")
                    }
                }

                AccessibilityRow(isEnabled: AXIsProcessTrusted(), primaryTextColor: primaryTextColor, secondaryTextColor: secondaryTextColor, isFocused: viewModel.settingsFocusedIndex == 10)

                Divider()
                    .background(separatorColor)
                    .padding(.vertical, 4)

                MenuRow(
                    icon: "star",
                    label: "Star on GitHub",
                    trailingLabel: appVersion,
                    primaryTextColor: primaryTextColor,
                    isFocused: viewModel.settingsFocusedIndex == 11
                ) {
                    if let url = URL(string: "https://github.com/oa1mgo/nook") {
                        NSWorkspace.shared.open(url)
                    }
                }

                Divider()
                    .background(separatorColor)
                    .padding(.vertical, 4)

                MenuRow(
                    icon: "xmark.circle",
                    label: "Quit",
                    trailingLabel: "⌘Q",
                    isDestructive: true,
                    primaryTextColor: primaryTextColor,
                    isFocused: viewModel.settingsFocusedIndex == 12
                ) {
                    NSApplication.shared.terminate(nil)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
            .background(
                GeometryReader { g in
                    Color.clear
                        .preference(key: MenuContentHeightKey.self, value: g.size.height)
                }
            )
        }
        .onPreferenceChange(MenuContentHeightKey.self) { height in
            viewModel.menuContentHeight = height
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear {
            didAppear = true
            refreshStates()
        }
        .onChange(of: viewModel.contentType) { _, newValue in
            if newValue == .menu {
                didAppear = true
                refreshStates()
            }
        }
        .onReceive(viewModel.$keyboardActivateTrigger) { trigger in
            guard trigger != nil, didAppear else { return }
            performFocusedAction()
        }
    }

    private func performFocusedAction() {
        let i = viewModel.settingsFocusedIndex
        switch i {
        case 0: viewModel.toggleMenu()
        case 1: withAnimation(.easeInOut(duration: 0.2)) { screenSelector.isPickerExpanded.toggle() }
        case 2: withAnimation(.easeInOut(duration: 0.2)) { soundSelector.isPickerExpanded.toggle() }
        case 3: viewModel.pushTo(.agents)
        case 4: viewModel.pushTo(.shortcuts)
        case 5: artworkAdaptiveBackgroundEnabled.toggle()
        case 6: musicEdgeGlowEnabled.toggle()
        case 7: vibeGlowEnabled.toggle()
        case 8: performanceMonitorEnabled.toggle()
        case 9:
            do {
                if launchAtLogin {
                    try SMAppService.mainApp.unregister()
                    launchAtLogin = false
                } else {
                    try SMAppService.mainApp.register()
                    launchAtLogin = true
                }
            } catch {
                print("Failed to toggle launch at login: \(error)")
            }
        case 10:
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
            }
        case 11:
            if let url = URL(string: "https://github.com/oa1mgo/nook") {
                NSWorkspace.shared.open(url)
            }
        case 12: NSApplication.shared.terminate(nil)
        default: break
        }
    }

    private func refreshStates() {
        launchAtLogin = SMAppService.mainApp.status == .enabled
        screenSelector.refreshScreens()
    }

    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        return "v\(version)"
    }
}

// MARK: - Update Row

struct UpdateRow: View {
    @ObservedObject var updateManager: UpdateManager
    @State private var isHovered = false
    @State private var isSpinning = false

    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        return "v\(version)"
    }

    var body: some View {
        Button {
            handleTap()
        } label: {
            HStack(spacing: 10) {
                // Icon
                ZStack {
                    if case .installing = updateManager.state {
                        Image(systemName: "gear")
                            .font(.system(size: 12))
                            .foregroundColor(TerminalColors.blue)
                            .rotationEffect(.degrees(isSpinning ? 360 : 0))
                            .animation(.linear(duration: 1).repeatForever(autoreverses: false), value: isSpinning)
                            .onAppear { isSpinning = true }
                    } else {
                        Image(systemName: icon)
                            .font(.system(size: 12))
                            .foregroundColor(iconColor)
                    }
                }
                .frame(width: 16)

                // Label
                Text(label)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(labelColor)

                Spacer()

                // Right side: progress or status
                rightContent
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isHovered && isInteractive ? Color.white.opacity(0.08) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .disabled(!isInteractive)
        .onHover { isHovered = $0 }
        .animation(.easeInOut(duration: 0.2), value: updateManager.state)
    }

    // MARK: - Right Content

    @ViewBuilder
    private var rightContent: some View {
        switch updateManager.state {
        case .idle:
            Text(appVersion)
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.4))

        case .upToDate:
            HStack(spacing: 6) {
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(TerminalColors.green)
                Text("Up to date")
                    .font(.system(size: 11))
                    .foregroundColor(TerminalColors.green)
            }

        case .checking, .installing:
            ProgressView()
                .scaleEffect(0.5)
                .frame(width: 12, height: 12)

        case .found(let version, _):
            HStack(spacing: 6) {
                Circle()
                    .fill(TerminalColors.green)
                    .frame(width: 6, height: 6)
                Text("v\(version)")
                    .font(.system(size: 11))
                    .foregroundColor(TerminalColors.green)
            }

        case .downloading(let progress):
            HStack(spacing: 8) {
                ProgressView(value: progress)
                    .frame(width: 60)
                    .tint(TerminalColors.blue)
                Text("\(Int(progress * 100))%")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(TerminalColors.blue)
                    .frame(width: 32, alignment: .trailing)
            }

        case .extracting(let progress):
            HStack(spacing: 8) {
                ProgressView(value: progress)
                    .frame(width: 60)
                    .tint(TerminalColors.amber)
                Text("\(Int(progress * 100))%")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(TerminalColors.amber)
                    .frame(width: 32, alignment: .trailing)
            }

        case .readyToInstall(let version):
            HStack(spacing: 6) {
                Circle()
                    .fill(TerminalColors.green)
                    .frame(width: 6, height: 6)
                Text("v\(version)")
                    .font(.system(size: 11))
                    .foregroundColor(TerminalColors.green)
            }

        case .error:
            Text("Retry")
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.5))
        }
    }

    // MARK: - Computed Properties

    private var icon: String {
        switch updateManager.state {
        case .idle:
            return "arrow.down.circle"
        case .checking:
            return "arrow.down.circle"
        case .upToDate:
            return "checkmark.circle.fill"
        case .found:
            return "arrow.down.circle.fill"
        case .downloading:
            return "arrow.down.circle"
        case .extracting:
            return "doc.zipper"
        case .readyToInstall:
            return "checkmark.circle.fill"
        case .installing:
            return "gear"
        case .error:
            return "exclamationmark.circle"
        }
    }

    private var iconColor: Color {
        switch updateManager.state {
        case .idle:
            return .white.opacity(isHovered ? 1.0 : 0.7)
        case .checking:
            return .white.opacity(0.7)
        case .upToDate:
            return TerminalColors.green
        case .found, .readyToInstall:
            return TerminalColors.green
        case .downloading:
            return TerminalColors.blue
        case .extracting:
            return TerminalColors.amber
        case .installing:
            return TerminalColors.blue
        case .error:
            return Color(red: 1.0, green: 0.4, blue: 0.4)
        }
    }

    private var label: String {
        switch updateManager.state {
        case .idle:
            return "Check for Updates"
        case .checking:
            return "Checking..."
        case .upToDate:
            return "Check for Updates"
        case .found:
            return "Download Update"
        case .downloading:
            return "Downloading..."
        case .extracting:
            return "Extracting..."
        case .readyToInstall:
            return "Install & Relaunch"
        case .installing:
            return "Installing..."
        case .error:
            return "Update failed"
        }
    }

    private var labelColor: Color {
        switch updateManager.state {
        case .idle, .upToDate:
            return .white.opacity(isHovered ? 1.0 : 0.7)
        case .checking, .downloading, .extracting, .installing:
            return .white.opacity(0.9)
        case .found, .readyToInstall:
            return TerminalColors.green
        case .error:
            return Color(red: 1.0, green: 0.4, blue: 0.4)
        }
    }

    private var isInteractive: Bool {
        switch updateManager.state {
        case .idle, .upToDate, .found, .readyToInstall, .error:
            return true
        case .checking, .downloading, .extracting, .installing:
            return false
        }
    }

    // MARK: - Actions

    private func handleTap() {
        switch updateManager.state {
        case .idle, .upToDate, .error:
            updateManager.checkForUpdates()
        case .found:
            updateManager.downloadAndInstall()
        case .readyToInstall:
            updateManager.installAndRelaunch()
        default:
            break
        }
    }
}

// MARK: - Accessibility Permission Row

struct AccessibilityRow: View {
    let isEnabled: Bool
    let primaryTextColor: Color
    let secondaryTextColor: Color
    var isFocused: Bool = false

    @State private var isHovered = false
    @State private var refreshTrigger = false

    private var currentlyEnabled: Bool {
        // Re-check on each render when refreshTrigger changes
        _ = refreshTrigger
        return isEnabled
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "hand.raised")
                .font(.system(size: 12))
                .foregroundColor(textColor)
                .frame(width: 16)

            Text("Accessibility")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(textColor)

            Spacer()

            if isEnabled {
                Circle()
                    .fill(TerminalColors.green)
                    .frame(width: 6, height: 6)

                Text("On")
                    .font(.system(size: 11))
                    .foregroundColor(secondaryTextColor)
            } else {
                Button(action: openAccessibilitySettings) {
                    Text("Enable")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.black)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 5)
                                .fill(Color.white)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isFocused ? Color.white.opacity(0.12) : (isHovered ? Color.white.opacity(0.08) : Color.clear))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isFocused ? Color.white.opacity(0.25) : Color.clear, lineWidth: 1)
        )
        .onHover { isHovered = $0 }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshTrigger.toggle()
        }
    }

    private var textColor: Color {
        primaryTextColor.opacity(isHovered ? 1.0 : 0.82)
    }

    private func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}

struct MenuRow: View {
    let icon: String
    let label: String
    var trailingLabel: String? = nil
    var trailingIcon: String? = nil
    var isDestructive: Bool = false
    var primaryTextColor: Color = .white
    var isFocused: Bool = false
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .foregroundColor(textColor)
                    .frame(width: 16)

                Text(label)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(textColor)

                Spacer()

                if let trailingLabel {
                    Text(trailingLabel)
                        .font(.system(size: 11))
                        .foregroundColor(textColor.opacity(0.55))
                }

                if let trailingIcon {
                    Image(systemName: trailingIcon)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(textColor.opacity(0.4))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isFocused ? Color.white.opacity(0.12) : (isHovered ? Color.white.opacity(0.08) : Color.clear))
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

    private var textColor: Color {
        if isDestructive {
            return Color(red: 1.0, green: 0.4, blue: 0.4)
        }
        return primaryTextColor.opacity(isHovered ? 1.0 : 0.82)
    }
}

struct MenuToggleRow: View {
    let icon: String
    let label: String
    let isOn: Bool
    var primaryTextColor: Color = .white
    var secondaryTextColor: Color = .white.opacity(0.4)
    var isFocused: Bool = false
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .foregroundColor(textColor)
                    .frame(width: 16)

                Text(label)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(textColor)

                Spacer()

                Circle()
                    .fill(isOn ? TerminalColors.green : Color.white.opacity(0.3))
                    .frame(width: 6, height: 6)

                Text(isOn ? "On" : "Off")
                    .font(.system(size: 11))
                    .foregroundColor(secondaryTextColor)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isFocused ? Color.white.opacity(0.12) : (isHovered ? Color.white.opacity(0.08) : Color.clear))
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

    private var textColor: Color {
        primaryTextColor.opacity(isHovered ? 1.0 : 0.82)
    }
}
