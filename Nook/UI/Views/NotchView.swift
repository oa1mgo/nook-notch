//
//  NotchView.swift
//  Nook
//
//  The main dynamic island SwiftUI view with accurate notch shape
//

import AppKit
import CoreGraphics
import SwiftUI

// Corner radius constants
private let cornerRadiusInsets = (
    opened: (top: CGFloat(12), bottom: CGFloat(24)),
    closed: (top: CGFloat(6), bottom: CGFloat(12))
)

struct NotchView: View {
    private struct ExpandedNotchTheme {
        let backgroundGradient: LinearGradient
        let overlayColor: Color
        let primaryText: Color
        let secondaryText: Color
        let separator: Color
        let headerIcon: Color
    }

    @ObservedObject var viewModel: NotchViewModel
    @StateObject private var sessionMonitor = ClaudeSessionMonitor()
    @StateObject private var activityCoordinator = NotchActivityCoordinator.shared
    @StateObject private var musicManager = MusicManager()
    @ObservedObject private var updateManager = UpdateManager.shared
    @State private var previousPendingIds: Set<String> = []
    @State private var previousWaitingForInputIds: Set<String> = []
    @State private var previousCompletionNotificationMarkers: [String: Date] = [:]
    @State private var waitingForInputTimestamps: [String: Date] = [:]  // sessionId -> when it entered waitingForInput
    @State private var isVisible: Bool = false
    @State private var isHovering: Bool = false
    @State private var isBouncing: Bool = false
    @AppStorage(AppSettings.artworkAdaptiveBackgroundEnabledKey) private var artworkAdaptiveBackgroundEnabled = true

    @Namespace private var activityNamespace

    /// Whether any tracked session is currently processing or compacting
    private var isAnyProcessing: Bool {
        sessionMonitor.instances.contains { $0.phase == .processing || $0.phase == .compacting }
    }

    private var activeProcessingActivityType: NotchActivityType? {
        if sessionMonitor.instances.contains(where: { $0.provider == .claude && ($0.phase == .processing || $0.phase == .compacting) }) {
            return .claude
        }
        if sessionMonitor.instances.contains(where: { $0.provider == .codex && $0.phase == .processing }) {
            return .codex
        }
        return nil
    }

    /// Whether any tracked session has a pending permission request
    private var hasPendingPermission: Bool {
        sessionMonitor.instances.contains { $0.phase.isWaitingForApproval }
    }

    /// Whether any tracked session is waiting for user input (done/ready state) within the display window
    private var hasWaitingForInput: Bool {
        let now = Date()
        let displayDuration: TimeInterval = 30  // Show checkmark for 30 seconds

        return waitingForInputTimestamps.values.contains { enteredAt in
            now.timeIntervalSince(enteredAt) < displayDuration
        }
    }

    // MARK: - Sizing

    private var closedNotchSize: CGSize {
        CGSize(
            width: viewModel.deviceNotchRect.width,
            height: viewModel.deviceNotchRect.height
        )
    }

    /// Extra width for expanding activities (like Dynamic Island)
    private var expansionWidth: CGFloat {
        // Base expansion: two side icon areas (each = sideWidth)
        let baseExpansion = 2 * max(0, closedNotchSize.height - 12) + 20

        if showMusicActivity {
            return baseExpansion
        }

        // Permission indicator adds width on left side only
        let permissionIndicatorWidth: CGFloat = hasPendingPermission ? 18 : 0

        // Expand for processing activity
        if activityCoordinator.expandingActivity.show {
            switch activityCoordinator.expandingActivity.type {
            case .claude, .codex:
                return baseExpansion + permissionIndicatorWidth
            case .none:
                break
            }
        }

        // Expand for pending permissions (left indicator) or waiting for input (checkmark on right)
        if hasPendingPermission {
            return baseExpansion + permissionIndicatorWidth
        }

        // Waiting for input just shows checkmark on right, no extra left indicator
        if hasWaitingForInput {
            return baseExpansion
        }

        return 0
    }

    private var notchSize: CGSize {
        switch viewModel.status {
        case .closed, .popping:
            return closedNotchSize
        case .opened:
            return viewModel.openedSize
        }
    }

    /// Width of the closed content (notch + any expansion)
    private var closedContentWidth: CGFloat {
        closedNotchSize.width + expansionWidth
    }

    // MARK: - Corner Radii

    private var topCornerRadius: CGFloat {
        viewModel.animatedTopCornerRadius
    }

    private var bottomCornerRadius: CGFloat {
        viewModel.animatedBottomCornerRadius
    }

    // Animation springs
    private let openAnimation = Animation.spring(response: 0.42, dampingFraction: 0.8, blendDuration: 0)
    private let closeAnimation = Animation.spring(response: 0.45, dampingFraction: 1.0, blendDuration: 0)

    // MARK: - Body

    var body: some View {
        ZStack(alignment: .top) {
            // Outer container does NOT receive hits - only the notch content does
            VStack(spacing: 0) {
                notchLayout
                    .frame(
                        maxWidth: viewModel.status == .opened ? notchSize.width : nil,
                        alignment: .top
                    )
                    .padding(
                        .horizontal,
                        viewModel.status == .opened
                            ? cornerRadiusInsets.opened.top
                            : cornerRadiusInsets.closed.bottom
                    )
                    .padding([.horizontal, .bottom], viewModel.status == .opened ? 12 : 0)
                    .background {
                        if isAdaptiveBackgroundEnabled {
                            NotchShape(
                                topCornerRadius: viewModel.animatedTopCornerRadius,
                                bottomCornerRadius: viewModel.animatedBottomCornerRadius
                            )
                            .fill(expandedNotchTheme.backgroundGradient)
                            .overlay(
                                RadialGradient(
                                    colors: [
                                        expandedNotchTheme.primaryText.opacity(0.08),
                                        .clear
                                    ],
                                    center: .topLeading,
                                    startRadius: 12,
                                    endRadius: notchSize.width * 0.9
                                )
                            )
                            .overlay(expandedNotchTheme.overlayColor)
                            .clipShape(NotchShape(
                                topCornerRadius: viewModel.animatedTopCornerRadius,
                                bottomCornerRadius: viewModel.animatedBottomCornerRadius
                            ))
                        } else {
                            NotchShape(
                                topCornerRadius: viewModel.animatedTopCornerRadius,
                                bottomCornerRadius: viewModel.animatedBottomCornerRadius
                            )
                            .fill(Color.black)
                        }
                    }
                    .clipShape(NotchShape(
                        topCornerRadius: viewModel.animatedTopCornerRadius,
                        bottomCornerRadius: viewModel.animatedBottomCornerRadius
                    ))
                    .overlay(musicEdgeGlow)
                    .shadow(
                        color: (viewModel.status == .opened || isHovering) ? .black.opacity(0.7) : .clear,
                        radius: 6
                    )
                    .frame(
                        maxWidth: viewModel.status == .opened ? notchSize.width : nil,
                        maxHeight: viewModel.status == .opened ? notchSize.height : nil,
                        alignment: .top
                    )
                    .animation(openAnimation, value: notchSize) // Animate container size changes between content types
                    .animation(viewModel.status == .opened ? openAnimation : closeAnimation, value: viewModel.status)
                    .animation(.smooth, value: activityCoordinator.expandingActivity)
                    .animation(.smooth, value: hasPendingPermission)
                    .animation(.smooth, value: hasWaitingForInput)
                    .animation(.smooth, value: showMusicActivity)
                    .animation(.smooth(duration: 0.45), value: musicManager.playbackState.artworkData)
                    .animation(.spring(response: 0.3, dampingFraction: 0.5), value: isBouncing)
                    .contentShape(Rectangle())
                    .onHover { hovering in
                        withAnimation(.spring(response: 0.38, dampingFraction: 0.8)) {
                            isHovering = hovering
                        }
                    }
                    .onTapGesture {
                        if viewModel.status != .opened {
                            // Don't re-open if we just closed due to clicking the notch area.
                            // The NSEvent monitor fires first and already handled the close;
                            // without this guard the SwiftUI gesture would immediately re-open.
                            if let closedAt = viewModel.closedByTapAt,
                               Date().timeIntervalSince(closedAt) < 0.2 {
                                return
                            }
                            viewModel.notchOpen(reason: .click)
                        }
                    }
            }
        }
        .opacity(isVisible ? 1 : 0)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .preferredColorScheme(.dark)
        .onAppear {
            viewModel.closedNotchExpansionWidth = expansionWidth
            sessionMonitor.startMonitoring()
            syncInstancesPageLayoutState()
            handleProcessingChange()
            // On non-notched devices, keep visible so users have a target to interact with
            if !viewModel.hasPhysicalNotch {
                isVisible = true
            }
        }
        .onChange(of: viewModel.status) { oldStatus, newStatus in
            handleStatusChange(from: oldStatus, to: newStatus)
        }
        .onChange(of: sessionMonitor.pendingInstances) { _, sessions in
            handlePendingSessionsChange(sessions)
        }
        .onChange(of: sessionMonitor.instances) { _, instances in
            syncInstancesPageLayoutState()
            handleProcessingChange()
            handleWaitingForInputChange(instances)
        }
        .onChange(of: musicManager.playbackState) { _, _ in
            syncInstancesPageLayoutState()
            handleProcessingChange()
        }
        .onChange(of: expansionWidth) { _, newValue in
            viewModel.closedNotchExpansionWidth = newValue
        }
    }

    // MARK: - Notch Layout

    private var isProcessing: Bool {
        activityCoordinator.expandingActivity.show &&
            (activityCoordinator.expandingActivity.type == .claude || activityCoordinator.expandingActivity.type == .codex)
    }

    private var isCodexProcessing: Bool {
        activityCoordinator.expandingActivity.show && activityCoordinator.expandingActivity.type == .codex
    }

    private var activeLoadingProvider: SessionProvider {
        switch activityCoordinator.expandingActivity.type {
        case .codex:
            return .codex
        case .claude, .none:
            return .claude
        }
    }

    private var activityTint: Color {
        SessionLoadingStyle.tint(for: activeLoadingProvider)
    }

    private var showMusicActivity: Bool {
        musicManager.isVisible && !hasPendingPermission && !isAnyProcessing
    }

    private var showCompactMusicActivity: Bool {
        viewModel.status != .opened && showMusicActivity
    }

    private var hasArtworkThemeSource: Bool {
        musicManager.albumArt != nil && musicManager.hasArtworkGradient
    }

    private var isAdaptiveBackgroundEnabled: Bool {
        viewModel.status == .opened && musicManager.isVisible && artworkAdaptiveBackgroundEnabled && hasArtworkThemeSource
    }

    private var expandedNotchTheme: ExpandedNotchTheme {
        let colors = musicManager.artworkGradient.map(Color.init(nsColor:))
        let useDarkForeground = perceivedBrightness(for: musicManager.artworkGradient) > 0.72

        return ExpandedNotchTheme(
            backgroundGradient: LinearGradient(
                colors: colors + [colors.last ?? .black],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            overlayColor: useDarkForeground ? Color.black.opacity(0.18) : Color.black.opacity(0.36),
            primaryText: useDarkForeground ? Color.black.opacity(0.82) : Color.white.opacity(0.96),
            secondaryText: useDarkForeground ? Color.black.opacity(0.58) : Color.white.opacity(0.62),
            separator: useDarkForeground ? Color.black.opacity(0.12) : Color.white.opacity(0.10),
            headerIcon: useDarkForeground ? Color.black.opacity(0.56) : Color.white.opacity(0.5)
        )
    }

    private var expandedPrimaryTextColor: Color {
        isAdaptiveBackgroundEnabled ? expandedNotchTheme.primaryText : .white
    }

    private var expandedSecondaryTextColor: Color {
        isAdaptiveBackgroundEnabled ? expandedNotchTheme.secondaryText : .white.opacity(0.4)
    }

    private var expandedSeparatorColor: Color {
        isAdaptiveBackgroundEnabled ? expandedNotchTheme.separator : .white.opacity(0.08)
    }

    private var expandedHeaderIconColor: Color {
        isAdaptiveBackgroundEnabled ? expandedNotchTheme.headerIcon : .white.opacity(0.4)
    }

    /// Whether to show the expanded closed state (processing, pending permission, or waiting for input)
    private var showClosedActivity: Bool {
        showCompactMusicActivity || isProcessing || hasPendingPermission || hasWaitingForInput
    }

    /// Whether to show the music progress edge glow
    private var musicEdgeGlowVisible: Bool {
        musicManager.playbackState.isPlaying
            && viewModel.status == .closed
    }

    @State private var breathingOpacity: CGFloat = 0.9

    @ViewBuilder
    private var musicEdgeGlow: some View {
        if musicEdgeGlowVisible {
            let glowColors = musicManager.edgeGlowGradient.map(Color.init(nsColor:))
            let glowGradient = LinearGradient(colors: glowColors, startPoint: .leading, endPoint: .trailing)

            let edgeShape = NotchBottomEdge(
                topCornerRadius: viewModel.animatedTopCornerRadius,
                bottomCornerRadius: viewModel.animatedBottomCornerRadius
            )

            edgeShape
                .trim(from: 0, to: 1)
                .stroke(glowGradient, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                .blur(radius: 6)
                .opacity(breathingOpacity * 0.75)
                .task {
                    while !Task.isCancelled {
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        withAnimation(.easeInOut(duration: 1.5)) {
                            breathingOpacity = 0.15
                        }
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        withAnimation(.easeInOut(duration: 1.5)) {
                            breathingOpacity = 1.0
                        }
                    }
                }
        }
    }

    @ViewBuilder
    private var notchLayout: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header row - always present, contains crab and spinner that persist across states
            headerRow
                .frame(height: max(24, closedNotchSize.height))

            // Main content only when opened
            if viewModel.status == .opened {
                contentView
                    .frame(width: notchSize.width - 24) // Fixed width to prevent reflow
                    .compositingGroup() // Flatten content before transition effects to prevent layer interleaving artifacts
                    .transition(
                        .asymmetric(
                            insertion: .scale(scale: 0.8, anchor: .top)
                                .combined(with: .opacity)
                                .animation(.smooth(duration: 0.35)),
                            removal: .opacity.animation(.easeOut(duration: 0.15))
                        )
                    )
            }
        }
    }

    // MARK: - Header Row (persists across states)

    @ViewBuilder
    private var headerRow: some View {
        if showCompactMusicActivity {
            CompactMusicActivityView(musicManager: musicManager)
                .frame(width: closedContentWidth, height: closedNotchSize.height, alignment: .leading)
                .frame(height: closedNotchSize.height)
        } else {
        HStack(spacing: 0) {
            // Left side - icons at natural size
            if showClosedActivity {
                HStack(spacing: 4) {
                    if isCodexProcessing {
                        CodexPulseIcon(size: 14, color: activityTint, isAnimating: true)
                            .padding(1)
                            .matchedGeometryEffect(id: "crab", in: activityNamespace, isSource: showClosedActivity)
                    } else {
                        ClaudeCrabIcon(size: 14, color: activityTint, animateLegs: isProcessing)
                            .padding(1)
                            .matchedGeometryEffect(id: "crab", in: activityNamespace, isSource: showClosedActivity)
                    }

                    if hasPendingPermission {
                        PermissionIndicatorIcon(size: 14, color: Color(red: 0.85, green: 0.47, blue: 0.34))
                            .padding(1)
                            .matchedGeometryEffect(id: "status-indicator", in: activityNamespace, isSource: showClosedActivity)
                    }
                }
            }

            // Center spacer
            if viewModel.status == .opened {
                openedHeaderContent
            } else if !showClosedActivity {
                Spacer()
            } else {
                Spacer()
                    .background(Color.black)
            }

            // Right side - icons at natural size
            if showClosedActivity {
                if isProcessing || hasPendingPermission {
                    ProcessingSpinner(provider: activeLoadingProvider)
                        .matchedGeometryEffect(id: "spinner", in: activityNamespace, isSource: showClosedActivity)
                } else if hasWaitingForInput {
                    ReadyForInputIndicatorIcon(size: 14, color: TerminalColors.green)
                        .padding(1)
                        .matchedGeometryEffect(id: "spinner", in: activityNamespace, isSource: showClosedActivity)
                }
            }
        }
        .padding(.horizontal, 7)
        .frame(width: viewModel.status == .opened ? nil : closedContentWidth + (isBouncing ? 16 : 0))
        .frame(height: closedNotchSize.height)
        }
    }

    // MARK: - Opened Header Content

    @ViewBuilder
    private var openedHeaderContent: some View {
        HStack(spacing: 12) {
            // Show static crab only if not showing activity in headerRow
            // (headerRow handles crab + indicator when showClosedActivity is true)
            if !showClosedActivity {
                if activityCoordinator.expandingActivity.type == .codex {
                    CodexPulseIcon(size: 14, color: Color(red: 0.34, green: 0.64, blue: 0.98))
                        .matchedGeometryEffect(id: "crab", in: activityNamespace, isSource: !showClosedActivity)
                        .padding(.leading, 8)
                } else {
                    ClaudeCrabIcon(size: 14)
                        .matchedGeometryEffect(id: "crab", in: activityNamespace, isSource: !showClosedActivity)
                        .padding(.leading, 8)
                }
            }

            Spacer()

            // Menu toggle
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    viewModel.toggleMenu()
                    if viewModel.contentType == .menu {
                        updateManager.markUpdateSeen()
                    }
                }
            } label: {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: viewModel.contentType == .menu ? "xmark" : "line.3.horizontal")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(expandedHeaderIconColor)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())

                    // Green dot for unseen update
                    if updateManager.hasUnseenUpdate && viewModel.contentType != .menu {
                        Circle()
                            .fill(TerminalColors.green)
                            .frame(width: 6, height: 6)
                            .offset(x: -2, y: 2)
                    }
                }
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Content View (Opened State)

    @ViewBuilder
    private var contentView: some View {
        Group {
            switch viewModel.contentType {
            case .instances:
                ClaudeInstancesView(
                    sessionMonitor: sessionMonitor,
                    viewModel: viewModel,
                    musicManager: musicManager
                )
            case .menu:
                NotchMenuView(
                    viewModel: viewModel,
                    primaryTextColor: expandedPrimaryTextColor,
                    secondaryTextColor: expandedSecondaryTextColor,
                    separatorColor: expandedSeparatorColor
                )
            case .chat(let session):
                ChatView(
                    sessionId: session.sessionId,
                    initialSession: session,
                    sessionMonitor: sessionMonitor,
                    viewModel: viewModel,
                    primaryTextColor: expandedPrimaryTextColor,
                    secondaryTextColor: expandedSecondaryTextColor
                )
            }
        }
        .frame(width: notchSize.width - 24) // Fixed width to prevent text reflow
        // Removed .id() - was causing view recreation and performance issues
    }

    private func perceivedBrightness(for colors: [NSColor]) -> CGFloat {
        let samples = colors.compactMap { $0.usingColorSpace(.deviceRGB) }
        guard !samples.isEmpty else { return 0 }

        let total = samples.reduce(CGFloat.zero) { partialResult, color in
            partialResult + ((color.redComponent * 0.299) + (color.greenComponent * 0.587) + (color.blueComponent * 0.114))
        }

        return total / CGFloat(samples.count)
    }

    private func syncInstancesPageLayoutState() {
        let sessionCount = sessionMonitor.instances.count
        let hasSessions = sessionCount > 0
        let showsMusic = musicManager.isVisible

        viewModel.instancesPageHasSessions = hasSessions
        viewModel.instancesPageSessionCount = sessionCount
        viewModel.instancesPageShowsMusic = showsMusic
    }

    // MARK: - Event Handlers

    private func handleProcessingChange() {
        if isAnyProcessing || hasPendingPermission {
            // Claude approval remains Claude-styled; otherwise follow the active provider.
            let activityType: NotchActivityType = hasPendingPermission ? .claude : (activeProcessingActivityType ?? .claude)
            activityCoordinator.showActivity(type: activityType)
            isVisible = true
        } else if showMusicActivity {
            activityCoordinator.hideActivity()
            isVisible = true
        } else if hasWaitingForInput {
            // Keep visible for waiting-for-input but hide the processing spinner
            activityCoordinator.hideActivity()
            isVisible = true
        } else {
            // Hide activity when done
            activityCoordinator.hideActivity()

            // Delay hiding the notch until animation completes
            // Don't hide on non-notched devices - users need a visible target
            if viewModel.status == .closed && viewModel.hasPhysicalNotch {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    if !isAnyProcessing && !hasPendingPermission && !hasWaitingForInput && viewModel.status == .closed {
                        isVisible = false
                    }
                }
            }
        }
    }

    private func handleStatusChange(from oldStatus: NotchStatus, to newStatus: NotchStatus) {
        switch newStatus {
        case .opened, .popping:
            isVisible = true
            // Clear waiting-for-input timestamps only when manually opened (user acknowledged)
            if viewModel.openReason == .click || viewModel.openReason == .hover {
                waitingForInputTimestamps.removeAll()
            }
        case .closed:
            // Don't hide on non-notched devices - users need a visible target
            guard viewModel.hasPhysicalNotch else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                if viewModel.status == .closed && !isAnyProcessing && !hasPendingPermission && !hasWaitingForInput && !showMusicActivity && !activityCoordinator.expandingActivity.show {
                    isVisible = false
                }
            }
        }
    }

    private func handlePendingSessionsChange(_ sessions: [SessionState]) {
        let currentIds = Set(sessions.map { $0.stableId })
        let newPendingIds = currentIds.subtracting(previousPendingIds)

        if !newPendingIds.isEmpty &&
           viewModel.status == .closed &&
           !TerminalVisibilityDetector.isTerminalVisibleOnCurrentSpace() {
            viewModel.notchOpen(reason: .notification)
        }

        previousPendingIds = currentIds
    }

    private func handleWaitingForInputChange(_ instances: [SessionState]) {
        let displayDuration: TimeInterval = 30
        let now = Date()

        // Get Claude sessions that are now waiting for input
        let waitingForInputSessions = instances.filter { $0.phase == .waitingForInput }
        let currentIds = Set(waitingForInputSessions.map { $0.stableId })
        let newWaitingIds = currentIds.subtracting(previousWaitingForInputIds)

        // Track timestamps for newly waiting sessions
        for session in waitingForInputSessions where newWaitingIds.contains(session.stableId) {
            waitingForInputTimestamps[session.stableId] = now
        }

        // Track synthetic Codex completion notifications emitted on Stop.
        let codexCompletionSessions = instances.filter {
            $0.provider == .codex && $0.completionNotificationAt != nil
        }
        var currentCompletionMarkers: [String: Date] = [:]
        var newCompletionSessions: [SessionState] = []

        for session in codexCompletionSessions {
            guard let completionAt = session.completionNotificationAt else { continue }
            currentCompletionMarkers[session.stableId] = completionAt

            if previousCompletionNotificationMarkers[session.stableId] != completionAt {
                waitingForInputTimestamps[session.stableId] = completionAt
                newCompletionSessions.append(session)
            }
        }

        let activeTimestampIds = currentIds.union(currentCompletionMarkers.keys)

        // Clean up timestamps for sessions that no longer qualify or have expired.
        for (stableId, enteredAt) in waitingForInputTimestamps {
            let isStillActive = activeTimestampIds.contains(stableId)
            let isStillVisible = now.timeIntervalSince(enteredAt) < displayDuration
            if !isStillActive || !isStillVisible {
                waitingForInputTimestamps.removeValue(forKey: stableId)
            }
        }

        let newlyWaitingSessions = waitingForInputSessions.filter { newWaitingIds.contains($0.stableId) }
        let newlyCompletedSessions = newlyWaitingSessions + newCompletionSessions

        // Bounce the notch when a session newly enters waiting-for-input or Codex emits a stop completion.
        if !newlyCompletedSessions.isEmpty {

            // Play notification sound if the session is not actively focused
            if let soundName = AppSettings.notificationSound.soundName {
                // Check if we should play sound (async check for tmux pane focus)
                Task {
                    let shouldPlaySound = await shouldPlayNotificationSound(for: newlyCompletedSessions)
                    if shouldPlaySound {
                        _ = await MainActor.run {
                            NSSound(named: soundName)?.play()
                        }
                    }
                }
            }

            // Trigger bounce animation to get user's attention
            DispatchQueue.main.async {
                isBouncing = true
                // Bounce back after a short delay
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    isBouncing = false
                }
            }

            // Schedule hiding the checkmark after 30 seconds
            DispatchQueue.main.asyncAfter(deadline: .now() + displayDuration) { [self] in
                // Trigger a UI update to re-evaluate hasWaitingForInput
                handleProcessingChange()
            }
        }

        previousWaitingForInputIds = currentIds
        previousCompletionNotificationMarkers = currentCompletionMarkers
    }

    /// Determine if notification sound should play for the given sessions
    /// Returns true if ANY session is not actively focused
    private func shouldPlayNotificationSound(for sessions: [SessionState]) async -> Bool {
        for session in sessions {
            guard let pid = session.pid else {
                // No PID means we can't check focus, assume not focused
                return true
            }

            let isFocused = await TerminalVisibilityDetector.isSessionFocused(sessionPid: pid)
            if !isFocused {
                return true
            }
        }

        return false
    }
}
