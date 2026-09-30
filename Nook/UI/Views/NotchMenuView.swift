//
//  NotchMenuView.swift
//  Nook
//
//  Minimal menu matching Dynamic Island aesthetic
//

import AppKit
import ApplicationServices
import Combine
import SwiftUI
import ServiceManagement

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
    @State private var isAppearancePickerExpanded = false
    @AppStorage(AppSettings.notchAppearanceStyleKey) private var notchAppearanceStyleRaw = NotchAppearanceStyle.adaptiveArtwork.rawValue
    @AppStorage(AppSettings.musicEdgeGlowEnabledKey) private var musicEdgeGlowEnabled = false
    @AppStorage(AppSettings.vibeGlowEnabledKey) private var vibeGlowEnabled = false

    /// Compile-time layout for the menu page. 14 visible rows + 5
    /// dividers (Back, divider, Screen, Sound, Agents..., Performance...,
    /// Keyboard..., divider, Appearance, Music Edge, Vibe, divider,
    /// Launch, Accessibility, Beta Features..., divider, Star, divider, Quit).
    static var pageLayout: PageLayout {
        PageLayout(rowCount: 14, dividerCount: 5)
    }

    /// Total height the menu VStack should report, given which pickers
    /// are currently expanded. Drives `viewModel.menuContentHeight`
    /// through `onChange` — no GeometryReader feedback.
    ///
    /// The "base" height (no picker expanded) is `PageLayout.staticHeight`,
    /// derived from `menuRowHeight` (font-metric from 13pt medium label
    /// + 20pt vertical padding = 35.31pt) — bit-for-bit identical to
    /// what SwiftUI allocates per row, so the formula matches
    /// `ScrollView.contentSize` at every frame.
    private var menuContentHeight: CGFloat {
        let base = Self.pageLayout.staticHeight
        let expandedHeights: [CGFloat] = [
            screenSelector.isPickerExpanded ? ScreenPickerRow.pickerLayout.expandedHeight : 0,
            soundSelector.isPickerExpanded ? SoundPickerRow.pickerLayout.expandedHeight : 0,
            isAppearancePickerExpanded ? AppearanceStylePickerRow.pickerLayout.expandedHeight : 0
        ]
        let total = base + expandedHeights.reduce(0, +)
        return total
    }

    var body: some View {
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
                    isFocused: viewModel.settingsFocusedIndex == 1,
                    onToggle: { _, _ in
                        // ScreenSelector.isPickerExpanded already mutated
                        // by the binding setter inside `withAnimation` —
                        // recompute menu height in the same transaction.
                        // `markExplicitSet` is REQUIRED — see
                        // `handleMeasuredContentHeight` for why.
                        markExplicitSet()
                        viewModel.menuContentHeight = menuContentHeight
                    }
                )
                SoundPickerRow(
                    soundSelector: soundSelector,
                    primaryTextColor: primaryTextColor,
                    secondaryTextColor: secondaryTextColor,
                    isFocused: viewModel.settingsFocusedIndex == 2,
                    onToggle: { _, _ in
                        markExplicitSet()
                        viewModel.menuContentHeight = menuContentHeight
                    }
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
                    icon: "gauge.with.dots.needle.33percent",
                    label: "Performance...",
                    trailingIcon: "chevron.right",
                    primaryTextColor: primaryTextColor,
                    isFocused: viewModel.settingsFocusedIndex == 4
                ) {
                    viewModel.pushTo(.performanceSettings)
                }

                MenuRow(
                    icon: "keyboard",
                    label: "Keyboard Shortcuts...",
                    trailingIcon: "chevron.right",
                    primaryTextColor: primaryTextColor,
                    isFocused: viewModel.settingsFocusedIndex == 5
                ) {
                    viewModel.pushTo(.shortcuts)
                }

                Divider()
                    .background(separatorColor)
                    .padding(.vertical, 4)

                // Music settings
                AppearanceStylePickerRow(
                    selectedStyle: selectedAppearanceStyle,
                    primaryTextColor: primaryTextColor,
                    secondaryTextColor: secondaryTextColor,
                    isFocused: viewModel.settingsFocusedIndex == 6,
                    isExpanded: $isAppearancePickerExpanded,
                    onToggle: { _, _ in
                        markExplicitSet()
                        viewModel.menuContentHeight = menuContentHeight
                    }
                ) { style in
                    setAppearanceStyle(style)
                }

                MenuToggleRow(
                    icon: "music.note",
                    label: "Music Edge Glow",
                    isOn: musicEdgeGlowEnabled,
                    primaryTextColor: primaryTextColor,
                    secondaryTextColor: secondaryTextColor,
                    isFocused: viewModel.settingsFocusedIndex == 7
                ) {
                    musicEdgeGlowEnabled.toggle()
                }

                MenuToggleRow(
                    icon: "sparkles",
                    label: "Vibe Glow",
                    isOn: vibeGlowEnabled,
                    primaryTextColor: primaryTextColor,
                    secondaryTextColor: secondaryTextColor,
                    isFocused: viewModel.settingsFocusedIndex == 8
                ) {
                    vibeGlowEnabled.toggle()
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

                MenuRow(
                    icon: "testtube.2",
                    label: "Beta Features...",
                    trailingIcon: "chevron.right",
                    primaryTextColor: primaryTextColor,
                    isFocused: viewModel.settingsFocusedIndex == 11
                ) {
                    viewModel.pushTo(.betaFeatures)
                }

                Divider()
                    .background(separatorColor)
                    .padding(.vertical, 4)

                MenuRow(
                    icon: "star",
                    label: "Star on GitHub",
                    trailingLabel: appVersion,
                    primaryTextColor: primaryTextColor,
                    isFocused: viewModel.settingsFocusedIndex == 12
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
                    isFocused: viewModel.settingsFocusedIndex == 13
                ) {
                    NSApplication.shared.terminate(nil)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear {
            didAppear = true
            refreshStates()
            // Menu page is transient — collapsed pickers should not
            // survive a navigation round-trip. (`isAppearancePickerExpanded`
            // is `@State` so it resets automatically when this View is
            // destroyed; the two singletons need an explicit reset.)
            screenSelector.isPickerExpanded = false
            soundSelector.isPickerExpanded = false
            isAppearancePickerExpanded = false
            // Re-arm the content-height calibration on every menu re-open.
            // The notification-based measurement will re-converge and
            // write the actual VStack height into menuContentHeight.
            markExplicitSet()
            // Initial push of the compile-time-derived height so the
            // panel opens at the right size without waiting for a
            // picker toggle.
            viewModel.menuContentHeight = menuContentHeight
            DispatchQueue.main.async {
                ScrollViewOverlayHelper.installIfNeeded()
            }
        }
        .onChange(of: viewModel.contentType) { oldValue, newValue in
            if oldValue == .menu && newValue != .menu {
                // User navigating AWAY from menu — reset the singleton
                // pickers. Doing this on EXIT (not just on the next
                // ENTRY's onAppear) avoids a race where the new View's
                // first GeometryReader / layout pass reads the still-
                // expanded picker state and snapshots a stale height.
                screenSelector.isPickerExpanded = false
                soundSelector.isPickerExpanded = false
            }
            if newValue == .menu {
                didAppear = true
                refreshStates()
                screenSelector.isPickerExpanded = false
                soundSelector.isPickerExpanded = false
                isAppearancePickerExpanded = false
                // Re-arm the content-height calibration. The notification
                // subscriber will re-converge and rewrite menuContentHeight
                // on the next stable measurement.
                markExplicitSet()
                viewModel.menuContentHeight = menuContentHeight
            }
        }
        // Picker toggles are handled in their onToggle closures above
        // (synchronously inside the picker's `withAnimation` block).
        .onReceive(viewModel.$keyboardActivateTrigger) { trigger in
            guard trigger != nil, didAppear else { return }
            performFocusedAction()
        }
        // Listen for content-height broadcasts from ScrollViewOverlayHelper.
        // The installer reads `documentView.frame.size.height` after every
        // NSScrollView layout pass, so this is the most accurate height
        // available — better than SwiftUI's own GeometryReader, which
        // can return transient values during the first layout pass.
        .onReceive(NotificationCenter.default.publisher(for: .scrollViewDidMeasureContent)) { note in
            guard let height = note.userInfo?["height"] as? CGFloat else { return }
            handleMeasuredContentHeight(height)
        }
    }

    private func performFocusedAction() {
        let i = viewModel.settingsFocusedIndex
        switch i {
        case 0: viewModel.toggleMenu()
        case 1:
            toggleScreenPickerFromKeyboard()
        case 2:
            toggleSoundPickerFromKeyboard()
        case 3: viewModel.pushTo(.agents)
        case 4: viewModel.pushTo(.performanceSettings)
        case 5: viewModel.pushTo(.shortcuts)
        case 6:
            toggleAppearancePickerFromKeyboard()
        case 7: musicEdgeGlowEnabled.toggle()
        case 8: vibeGlowEnabled.toggle()
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
            viewModel.pushTo(.betaFeatures)
        case 12:
            if let url = URL(string: "https://github.com/oa1mgo/nook") {
                NSWorkspace.shared.open(url)
            }
        case 13: NSApplication.shared.terminate(nil)
        default: break
        }
    }

    /// Keyboard-driven picker toggle. Same transaction as a mouse click
    /// on the row header — both `withAnimation` and the compile-time
    /// layout arithmetic apply here.
    private func toggleScreenPickerFromKeyboard() {
        withAnimation(.easeInOut(duration: 0.2)) {
            screenSelector.isPickerExpanded.toggle()
            markExplicitSet()
            viewModel.menuContentHeight = menuContentHeight
        }
    }

    private func toggleSoundPickerFromKeyboard() {
        withAnimation(.easeInOut(duration: 0.2)) {
            soundSelector.isPickerExpanded.toggle()
            markExplicitSet()
            viewModel.menuContentHeight = menuContentHeight
        }
    }

    private func toggleAppearancePickerFromKeyboard() {
        withAnimation(.easeInOut(duration: 0.2)) {
            isAppearancePickerExpanded.toggle()
            markExplicitSet()
            viewModel.menuContentHeight = menuContentHeight
        }
    }

    /// Stamp "an explicit setter just wrote `menuContentHeight`" so the
    /// broadcast handler can ignore in-flight measurements for the
    /// picker animation window.
    ///
    /// SwiftUI's layout is incremental: the picker's `frame(height:)`
    /// animation drives the layout through intermediate values
    /// (771 → 770 → 659 → 597 over 0.2s). The first post-toggle
    /// broadcast (≈ 100ms after the click) reads an in-flight frame
    /// still very close to the pre-toggle height. Without gating,
    /// that broadcast passes the `< 1.5pt` convergence check against
    /// the pre-toggle `prev` and overwrites the compile-time value we
    /// just wrote — causing the panel to snap back to the expanded
    /// size and "stay there".
    ///
    /// Single source of truth for the gate: every setter call
    /// (onAppear, onChange(contentType), every picker onToggle, every
    /// keyboard toggle) just stamps `now`. The handler does the rest.
    /// Future devs adding a new picker only need to call this once
    /// in their onToggle — they cannot forget the broadcast-gate
    /// plumbing because it lives entirely inside the handler.
    private func markExplicitSet() {
        lastExplicitSetAt = Date()
    }

    /// Receive content-height broadcasts from `ScrollViewOverlayHelper`.
    /// The installer reads the documentView's actual frame after every
    /// NSScrollView layout pass, so this is the most accurate height
    /// available — better than SwiftUI's own GeometryReader which can
    /// return transient under-estimates during the first layout pass.
    ///
    /// Gating: for `pickerAnimationGuard` seconds after any explicit
    /// setter call, broadcasts are ignored (in-flight animation values
    /// are unreliable). After the window expires, broadcasts are
    /// accepted and converge-tracked — this is the defense-in-depth
    /// that catches drift if SwiftUI ever changes its Text rendering
    /// box. With the font-metric-driven `PageLayout.staticHeight`, the
    /// broadcast value should match the theoretical value within
    /// subpixel, so this safety net rarely fires.
    @State private var lastExplicitSetAt: Date? = nil
    @State private var lastBroadcastHeight: CGFloat? = nil
    @State private var stableContentHeight: CGFloat? = nil
    /// Picker `frame(height:)` animation is 0.2s; we gate for 0.3s
    /// (animation + one 10Hz timer tick of safety) so the first
    /// post-toggle broadcast never lands inside the gated window.
    private let pickerAnimationGuard: TimeInterval = 0.3

    private func handleMeasuredContentHeight(_ height: CGFloat) {
        defer { lastBroadcastHeight = height }

        // Suppress broadcasts that arrive during the picker animation
        // window. See `markExplicitSet` for the full rationale.
        if let lastSet = lastExplicitSetAt,
           Date().timeIntervalSince(lastSet) < pickerAnimationGuard {
            return
        }

        guard let prev = lastBroadcastHeight else {
            // First broadcast after the gate — wait for the next pass to
            // confirm this isn't a transient value.
            return
        }
        let converged = abs(height - prev) < 1.5
        let isMeaningful = height >= Self.pageLayout.staticHeight - 1
        guard converged && isMeaningful else { return }
        guard stableContentHeight != height else { return }
        viewModel.menuContentHeight = height
        stableContentHeight = height
    }

    private func refreshStates() {
        launchAtLogin = SMAppService.mainApp.status == .enabled
        screenSelector.refreshScreens()
        notchAppearanceStyleRaw = AppSettings.notchAppearanceStyle.rawValue
    }

    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        return "v\(version)"
    }

    private var selectedAppearanceStyle: NotchAppearanceStyle {
        (NotchAppearanceStyle(rawValue: notchAppearanceStyleRaw) ?? AppSettings.notchAppearanceStyle)
            .resolvedForCurrentSystem
    }

    private func setAppearanceStyle(_ style: NotchAppearanceStyle) {
        let resolvedStyle = style.resolvedForCurrentSystem
        withAnimation(.easeInOut(duration: 0.2)) {
            AppSettings.notchAppearanceStyle = resolvedStyle
            notchAppearanceStyleRaw = resolvedStyle.rawValue
        }
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
        // Mirror MenuToggleRow's right-hand indicator (green/grey dot + On/Off
        // label) so the row's height is byte-for-byte identical to a standard
        // MenuRow. Previously we used a filled "Enable" Button in the
        // disabled state — that Button added ~4-6pt of vertical height and
        // broke PageLayout's row-height arithmetic (theory 36pt, actual ~40pt,
        // 1pt drift → permanent NSScroller thumb).
        //
        // Tapping the row opens System Settings → Accessibility (the only
        // meaningful action — the user can't toggle accessibility from inside
        // a sandboxed app, only the OS prompt can grant it).
        Button(action: openAccessibilitySettings) {
            HStack(spacing: 10) {
                Image(systemName: "hand.raised")
                    .font(.system(size: 12))
                    .foregroundColor(textColor)
                    .frame(width: 16)

                Text("Accessibility")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(textColor)

                Spacer()

                Circle()
                    .fill(currentlyEnabled ? TerminalColors.green : Color.white.opacity(0.3))
                    .frame(width: 6, height: 6)

                Text(currentlyEnabled ? "Enabled" : "Disabled")
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
        .buttonStyle(NoPressButtonStyle())
        .contentShape(Rectangle())
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

struct MenuRow<Icon: View>: View {
    let icon: String
    /// Optional override for the leading icon. When provided, replaces
    /// the SF Symbol `icon`. Use this when a row needs a brand logo
    /// (e.g. Codex / Cursor / OpenCode marks) instead of an SF Symbol.
    ///
    /// `MenuRow` is generic over `Icon` so the brand logo's concrete
    /// type is preserved end-to-end — no `AnyView` heap allocation, no
    /// SwiftUI view-diffing penalty. The most common call sites don't
    /// pass `customIcon` and use the convenience init in the
    /// `Icon == EmptyView` extension below; they pay nothing for the
    /// extra type parameter.
    var customIcon: Icon? = nil
    let label: String
    var trailingLabel: String? = nil
    /// Design for the trailing label. Defaults to `.default`; pass
    /// `.monospaced` for things like file paths where fixed-width
    /// alignment matters.
    var trailingLabelDesign: Font.Design = .default
    /// When true, trailing label is rendered dimmer than the default
    /// (0.35 vs 0.55 of the text color). Use for secondary status text
    /// like "Not installed" that should recede visually.
    var trailingLabelDimmed: Bool = false
    var trailingIcon: String? = nil
    var isDestructive: Bool = false
    var primaryTextColor: Color = .white
    var isFocused: Bool = false
    let action: () -> Void

    @State private var isHovered = false

    init(
        icon: String,
        customIcon: Icon? = nil,
        label: String,
        trailingLabel: String? = nil,
        trailingLabelDesign: Font.Design = .default,
        trailingLabelDimmed: Bool = false,
        trailingIcon: String? = nil,
        isDestructive: Bool = false,
        primaryTextColor: Color = .white,
        isFocused: Bool = false,
        action: @escaping () -> Void
    ) {
        self.icon = icon
        self.customIcon = customIcon
        self.label = label
        self.trailingLabel = trailingLabel
        self.trailingLabelDesign = trailingLabelDesign
        self.trailingLabelDimmed = trailingLabelDimmed
        self.trailingIcon = trailingIcon
        self.isDestructive = isDestructive
        self.primaryTextColor = primaryTextColor
        self.isFocused = isFocused
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                iconView

                Text(label)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(textColor)

                Spacer()

                if let trailingLabel {
                    Text(trailingLabel)
                        .font(.system(size: 11, design: trailingLabelDesign))
                        .foregroundColor(textColor.opacity(trailingLabelDimmed ? 0.35 : 0.55))
                        .lineLimit(1)
                        .truncationMode(.middle)
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
        .buttonStyle(NoPressButtonStyle())
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
    }

    @ViewBuilder
    private var iconView: some View {
        if let customIcon {
            customIcon.frame(width: 16)
        } else {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundColor(textColor)
                .frame(width: 16)
        }
    }

    private var textColor: Color {
        if isDestructive {
            return Color(red: 1.0, green: 0.4, blue: 0.4)
        }
        return primaryTextColor.opacity(isHovered ? 1.0 : 0.82)
    }
}

/// Convenience init for the common case (no `customIcon`). Pins
/// `Icon` to `EmptyView` so existing call sites don't need to
/// specify the generic parameter — they keep their old argument
/// shape and just get a slightly more efficient `MenuRow` under
/// the hood.
extension MenuRow where Icon == EmptyView {
    init(
        icon: String,
        label: String,
        trailingLabel: String? = nil,
        trailingLabelDesign: Font.Design = .default,
        trailingLabelDimmed: Bool = false,
        trailingIcon: String? = nil,
        isDestructive: Bool = false,
        primaryTextColor: Color = .white,
        isFocused: Bool = false,
        action: @escaping () -> Void
    ) {
        self.init(
            icon: icon,
            customIcon: nil,
            label: label,
            trailingLabel: trailingLabel,
            trailingLabelDesign: trailingLabelDesign,
            trailingLabelDimmed: trailingLabelDimmed,
            trailingIcon: trailingIcon,
            isDestructive: isDestructive,
            primaryTextColor: primaryTextColor,
            isFocused: isFocused,
            action: action
        )
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
        .buttonStyle(NoPressButtonStyle())
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
    }

    private var textColor: Color {
        primaryTextColor.opacity(isHovered ? 1.0 : 0.82)
    }
}

struct AppearanceStylePickerRow: View {
    let selectedStyle: NotchAppearanceStyle
    var primaryTextColor: Color = .white
    var secondaryTextColor: Color = .white.opacity(0.4)
    var isFocused: Bool = false
    @Binding var isExpanded: Bool
    var onToggle: ((Bool, CGFloat) -> Void)? = nil
    let action: (NotchAppearanceStyle) -> Void

    /// Compile-time layout for this picker's expanded content.
    /// One row per available appearance style; subRows use
    /// `verticalSublabel: true` so `rowHeight` is 46.91pt
    /// (font-metric-derived).
    static var pickerLayout: PickerLayout {
        PickerLayout(
            rowCount: NotchAppearanceStyle.availableCases.count,
            rowHeight: settingsSubPickerRowVerticalSublabelHeight
        )
    }

    var body: some View {
        ExpandableSettingsRow(
            icon: "circle.lefthalf.filled",
            label: "Appearance Style",
            trailingText: selectedStyle.displayName,
            primaryTextColor: primaryTextColor,
            secondaryTextColor: secondaryTextColor,
            isFocused: isFocused,
            isExpanded: $isExpanded,
            targetHeight: Self.pickerLayout.expandedHeight,
            onToggle: onToggle
        ) {
            VStack(spacing: 2) {
                ForEach(NotchAppearanceStyle.availableCases) { style in
                    SettingsSubPickerRow(
                        label: style.displayName,
                        sublabel: sublabel(for: style),
                        verticalSublabel: true,
                        isSelected: selectedStyle == style,
                        primaryTextColor: primaryTextColor,
                        secondaryTextColor: secondaryTextColor
                    ) {
                        action(style)
                    }
                }
            }
        }
    }

    private func sublabel(for style: NotchAppearanceStyle) -> String {
        switch style {
        case .liquidGlass:
            return "macOS 26+ glass"
        case .adaptiveArtwork:
            return "Dynamic music colors"
        case .pureBlack:
            return "Solid black"
        }
    }
}

// (MenuContentHeightKey PreferenceKey removed 2026-07-02 — GeometryReader
//  feedback loop eliminated by switching to font-metric row heights in
//  SettingsPageLayout.swift. Panel height = PageLayout.staticHeight +
//  PickerLayout.expandedHeight, all compile-time, no measurement.)
