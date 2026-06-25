//
//  NotchView.swift
//  Nook
//
//  The main dynamic island SwiftUI view with accurate notch shape
//

import AppKit
import Combine
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
    @StateObject private var sessionMonitor = SessionMonitor()
    @StateObject private var activityCoordinator = NotchActivityCoordinator.shared
    @StateObject private var musicManager = MusicManager()
    @StateObject private var performanceMonitor = PerformanceMonitor()
    @ObservedObject private var updateManager = UpdateManager.shared
    @State private var previousPendingIds: Set<String> = []
    @State private var previousWaitingForInputIds: Set<String> = []
    @State private var previousCompletionNotificationMarkers: [String: Date] = [:]
    @State private var waitingForInputTimestamps: [String: Date] = [:]  // sessionId -> when it entered waitingForInput
    @State private var isVisible: Bool = false
    @State private var isHovering: Bool = false
    @State private var isBouncing: Bool = false
    // Provider currently at the FRONT of the multi-agent icon stack.
    // Other working agents are stacked behind in priority order. A
    // 2s timer rotates this cursor so each agent gets a turn at the
    // front (with the spinner color tracking along).
    @State private var carouselFront: SessionProvider?
    // IMPORTANT: Timer.publish must be a stable instance — recreating
    // it on every body evaluation (which fires often via @ObservedObject
    // updates) resets the 2-second countdown, so the timer NEVER fires.
    // deepseek-v4-flash review caught this: body re-runs ~every state
    // change, each one starts a fresh publisher → no rotation.
    private let carouselTimer = Timer.publish(every: 2.0, on: .main, in: .common).autoconnect()
    @AppStorage(AppSettings.artworkAdaptiveBackgroundEnabledKey) private var artworkAdaptiveBackgroundEnabled = true
    @AppStorage(AppSettings.musicEdgeGlowEnabledKey) private var musicEdgeGlowEnabled = true
    @AppStorage(AppSettings.vibeGlowEnabledKey) private var vibeGlowEnabled = false
    @AppStorage(AppSettings.performanceMonitorEnabledKey) private var performanceMonitorEnabled = true

    @Namespace private var activityNamespace

    /// Whether any tracked session is currently processing or compacting
    private var isAnyProcessing: Bool {
        sessionMonitor.instances.contains { $0.phase == .processing || $0.phase == .compacting }
    }

    private var activeProcessingActivityType: NotchActivityType? {
        activeProcessingProviders.first.map { provider in
            switch provider {
            case .claude: return .claude
            case .codex: return .codex
            case .opencode: return .opencode
            case .cursor: return .cursor
            }
        }
    }

    /// All currently processing providers, in priority order
    /// (claude > codex > opencode > cursor). Empty if no agent is
    /// processing. Used by the closed-state header to render a
    /// stacked "peek" of icons — see `headerRow` below.
    private var activeProcessingProviders: [SessionProvider] {
        var providers: [SessionProvider] = []
        if sessionMonitor.instances.contains(where: { $0.provider == .claude && ($0.phase == .processing || $0.phase == .compacting) }) {
            providers.append(.claude)
        }
        if sessionMonitor.instances.contains(where: { $0.provider == .codex && ($0.phase == .processing || $0.phase == .compacting) }) {
            providers.append(.codex)
        }
        if sessionMonitor.instances.contains(where: { $0.provider == .opencode && ($0.phase == .processing || $0.phase == .compacting) }) {
            providers.append(.opencode)
        }
        if sessionMonitor.instances.contains(where: { $0.provider == .cursor && ($0.phase == .processing || $0.phase == .compacting) }) {
            providers.append(.cursor)
        }
        return providers
    }

    /// Display order for the icon stack. Always at most 2 elements:
    /// the current `carouselFront` and the front's "next" provider in
    /// the priority-ordered active list. When the providers list
    /// changes, the current front (if still active) is preserved so
    /// the carousel doesn't jump. With 0 active providers the stack
    /// is empty; with 1 active the stack is just that one icon (no
    /// peek). With 2+ active the second icon is the front's successor
    /// in the rotation, so it changes as the front cycles.
    private var displayOrder: [SessionProvider] {
        let active = activeProcessingProviders
        guard !active.isEmpty else { return [] }
        if let front = carouselFront, let frontIndex = active.firstIndex(of: front) {
            // N=1: no peek — avoid rendering a faded ghost of the same icon.
            guard active.count > 1 else { return [front] }
            let nextIndex = (frontIndex + 1) % active.count
            return [front, active[nextIndex]]
        }
        return Array(active.prefix(2))
    }
    private var activePendingPermissionActivityType: NotchActivityType? {
        if sessionMonitor.instances.contains(where: { $0.provider == .claude && ($0.phase.isWaitingForApproval || $0.phase.isWaitingForTerminalApproval) }) {
            return .claude
        }
        if sessionMonitor.instances.contains(where: { $0.provider == .codex && ($0.phase.isWaitingForApproval || $0.phase.isWaitingForTerminalApproval) }) {
            return .codex
        }
        if sessionMonitor.instances.contains(where: { $0.provider == .opencode && ($0.phase.isWaitingForApproval || $0.phase.isWaitingForTerminalApproval) }) {
            return .opencode
        }
        if sessionMonitor.instances.contains(where: { $0.provider == .cursor && ($0.phase.isWaitingForApproval || $0.phase.isWaitingForTerminalApproval) }) {
            return .cursor
        }
        return nil
    }

    /// Whether any tracked session has a pending permission request
    private var hasPendingPermission: Bool {
        sessionMonitor.instances.contains { $0.phase.isWaitingForApproval || $0.phase.isWaitingForTerminalApproval }
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
        let baseExpansion = 2 * max(0, closedNotchSize.height - 12) + 20

        if showMusicActivity {
            return baseExpansion
        }

        guard !suppressesHeaderAgentActivity else {
            return 0
        }

        let permissionIndicatorWidth: CGFloat = hasPendingPermission ? 18 : 0

        if activityCoordinator.expandingActivity.show {
            switch activityCoordinator.expandingActivity.type {
            case .claude, .codex, .opencode, .cursor:
                return baseExpansion + permissionIndicatorWidth
            case .none:
                break
            }
        }

        if hasPendingPermission {
            return baseExpansion + permissionIndicatorWidth
        }

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
                    .overlay(edgeGlowOverlay)
                    .shadow(
                        color: (viewModel.status == .opened || isHovering) ? .black.opacity(0.7) : .clear,
                        radius: 6
                    )
                    .frame(
                        maxWidth: viewModel.status == .opened ? notchSize.width : nil,
                        maxHeight: viewModel.status == .opened ? notchSize.height : nil,
                        alignment: .top
                    )
                    // Match the panel's height animation to the picker's
                    // 0.2s easeInOut curve (same as `ExpandableContent`'s
                    // own frame animation). They MUST use the same curve,
                    // otherwise the panel leads/lags the VStack's ideal
                    // height during expand, briefly clipping the ScrollView
                    // and flashing the scrollbar.
                    //
                    // Note: `openAnimation` (spring 0.42/0.8) was tried
                    // here previously and caused agents-page flicker
                    // because spring's curve doesn't track the 0.2s
                    // easeInOut picker curve — VStack actual < VStack ideal
                    // during the mismatch window. `.settingsExpand`
                    // matches the picker curve exactly, so VStack actual
                    // stays = VStack ideal throughout the animation.
                    .animation(.settingsExpand, value: notchSize)
                    .animation(viewModel.status == .opened ? openAnimation : closeAnimation, value: viewModel.status)
                    .animation(.smooth, value: activityCoordinator.expandingActivity)
                    .animation(.smooth, value: hasPendingPermission)
                    .animation(.smooth, value: hasWaitingForInput)
                    .animation(.smooth, value: showMusicActivity)
                    .animation(.smooth, value: vibeGlowEnabled)
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
                            handleNotchTap()
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
            performanceMonitor.setActive(performanceMonitorEnabled)
            syncInstancesPageLayoutState()
            handleProcessingChange()
            syncVisibilityForVibeGlow()
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
        .onChange(of: sessionMonitor.completionNotification) { _, notification in
            guard let notification else { return }
            handleCompletionNotification(notification)
        }
        .onChange(of: musicManager.playbackState) { _, _ in
            syncInstancesPageLayoutState()
            handleProcessingChange()
        }
        .onChange(of: performanceMonitorEnabled) { _, isEnabled in
            performanceMonitor.setActive(isEnabled)
            syncInstancesPageLayoutState()
        }
        .onChange(of: vibeGlowEnabled) { _, _ in
            syncVisibilityForVibeGlow()
        }
        .onChange(of: expansionWidth) { _, newValue in
            viewModel.closedNotchExpansionWidth = newValue
        }
    }

    // MARK: - Notch Layout

    private var isProcessing: Bool {
        guard activityCoordinator.expandingActivity.show else { return false }

        switch activityCoordinator.expandingActivity.type {
        case .claude, .codex, .opencode, .cursor:
            return true
        case .none:
            return false
        }
    }

    private var activeWaitingForInputActivityType: NotchActivityType? {
        let activeIds = Set(waitingForInputTimestamps.keys)
        guard let session = sessionMonitor.instances.first(where: { activeIds.contains($0.stableId) }) else {
            return nil
        }
        return activityType(for: session.provider)
    }

    private var closedActivityType: NotchActivityType {
        if isProcessing || hasPendingPermission {
            return activityCoordinator.expandingActivity.type
        }
        if hasWaitingForInput {
            return activeWaitingForInputActivityType ?? activityCoordinator.expandingActivity.type
        }
        return activityCoordinator.expandingActivity.type
    }

    private var closedActivityProvider: SessionProvider {
        switch closedActivityType {
        case .codex:
            return .codex
        case .opencode:
            return .opencode
        case .cursor:
            return .cursor
        case .claude, .none:
            return .claude
        }
    }

    private var closedActivityTint: Color {
        SessionLoadingStyle.tint(for: closedActivityProvider)
    }

    private func activityType(for provider: SessionProvider) -> NotchActivityType {
        switch provider {
        case .claude:
            return .claude
        case .codex:
            return .codex
        case .opencode:
            return .opencode
        case .cursor:
            return .cursor
        }
    }

    private var showMusicActivity: Bool {
        musicManager.isVisible && (usesClosedVibeMode || (!hasPendingPermission && !isAnyProcessing))
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

    private var showHeaderAgentActivity: Bool {
        !suppressesHeaderAgentActivity && (isProcessing || hasPendingPermission || hasWaitingForInput)
    }

    private var usesClosedVibeMode: Bool {
        vibeGlowEnabled && viewModel.status != .opened && isAnyProcessing
    }

    private var suppressesHeaderAgentActivity: Bool {
        vibeGlowEnabled
    }

    private var vibeGlowVisible: Bool {
        vibeGlowEnabled && viewModel.status == .closed && isAnyProcessing
    }

    /// Whether to show the music progress edge glow
    private var musicEdgeGlowVisible: Bool {
        musicManager.playbackState.isPlaying
            && viewModel.status == .closed
            && musicEdgeGlowEnabled
            && !vibeGlowVisible
    }

    @State private var breathingOpacity: CGFloat = 0.9

    @ViewBuilder
    private var edgeGlowOverlay: some View {
        if vibeGlowVisible {
            VibeSurroundGlow(
                topCornerRadius: viewModel.animatedTopCornerRadius,
                bottomCornerRadius: viewModel.animatedBottomCornerRadius
            )
        } else if musicEdgeGlowVisible {
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
                if showHeaderAgentActivity {
                    HStack(spacing: 4) {
                        // Stacked "peek" of working-agent icons. When
                        // multiple agents are processing simultaneously,
                        // the `displayOrder` starts at `carouselFront`
                        // and rotates every 2s. The leftmost icon (front)
                        // is fully visible; the others peek out 8pt to
                        // the right, sorted by priority from the front.
                        // Each icon's own pulse/movement animation is
                        // independent (Claude legs, Codex glow,
                        // OpenCode squish, Cursor highlight pulse), so
                        // the stack reads as alive on its own.
                        if !activeProcessingProviders.isEmpty {
                            ZStack(alignment: .leading) {
                                ForEach(Array(displayOrder.enumerated()), id: \.element) { index, provider in
                                    let isFront = index == 0
                                    AgentIcon(
                                        provider: provider,
                                        size: 14,
                                        color: SessionLoadingStyle.tint(for: provider),
                                        animate: true
                                    )
                                    .padding(1)
                                    .scaleEffect(isFront ? 1.0 : 0.85, anchor: .center)
                                    .opacity(isFront ? 1.0 : 0.55)
                                    .offset(x: CGFloat(index) * 11)
                                    .zIndex(Double(displayOrder.count - index))
                                    .animation(.smooth(duration: 0.5), value: isFront)
                                }
                            }
                            .matchedGeometryEffect(id: "agent-icons", in: activityNamespace, isSource: showHeaderAgentActivity)
                            .animation(.smooth(duration: 0.5), value: displayOrder)
                            // Rotate the carousel front every 2s so each
                            // working agent gets a turn. No-op when ≤1
                            // provider (the stack is just one icon).
                            .onReceive(carouselTimer) { _ in
                                // TODO(progress): carousel front/back
                                // animation tuning still in progress.
                                // Debug logs kept until rotation is
                                // confirmed working as intended across
                                // all multi-agent scenarios. See PROGRESS.md.
                                let active = activeProcessingProviders
                                let activeDesc = active.map { $0.rawValue }.joined(separator: ",")
                                DebugLog.shared.write("[carousel] tick active=[\(activeDesc)] count=\(active.count) currentFront=\(carouselFront?.rawValue ?? "nil")")
                                guard active.count > 1 else { return }
                                // If the cached front is no longer in the
                                // active set (provider stopped since last
                                // tick), reset to the current first active
                                // provider. Without this, the carousel
                                // gets stuck because firstIndex(of:) returns
                                // nil forever and we never advance.
                                let resolvedFront: SessionProvider = {
                                    if let f = carouselFront, active.contains(f) {
                                        return f
                                    }
                                    let reset = active.first!
                                    DebugLog.shared.write("[carousel] stale front reset → \(reset.rawValue)")
                                    carouselFront = reset
                                    return reset
                                }()
                                guard let i = active.firstIndex(of: resolvedFront) else {
                                    DebugLog.shared.write("[carousel] resolvedFront missing post-reset, skip")
                                    return
                                }
                                let next = active[(i + 1) % active.count]
                                DebugLog.shared.write("[carousel] rotating front \(resolvedFront.rawValue) → \(next.rawValue)")
                                withAnimation(.easeInOut(duration: 0.5)) {
                                    carouselFront = next
                                }
                            }
                        }

                        if hasPendingPermission {
                            PermissionIndicatorIcon(size: 14, color: Color(red: 0.85, green: 0.47, blue: 0.34))
                                .padding(1)
                                .matchedGeometryEffect(id: "status-indicator", in: activityNamespace, isSource: showHeaderAgentActivity)
                        }
                    }
                }

                if viewModel.status == .opened {
                    openedHeaderContent
                } else if !showHeaderAgentActivity {
                    Spacer()
                } else {
                    Spacer()
                        .background(Color.black)
                }

                if showHeaderAgentActivity {
                    if isProcessing || hasPendingPermission {
                        // Spinner follows the carousel front. When the
                        // front rotates, the spinner color animates to
                        // the next provider's tint (via .animation(value:)
                        // on the color binding).
                        //
                        // Ignore carouselFront if it points to a provider
                        // that's no longer processing (e.g. OpenCode
                        // stopped but carouselFront still cached .opencode) —
                        // fall through to activeProcessingProviders.first
                        // so the spinner switches to Claude immediately.
                        let active = activeProcessingProviders
                        let spinnerProvider: SessionProvider = {
                            if let f = carouselFront, active.contains(f) { return f }
                            return active.first ?? closedActivityProvider
                        }()
                        let spinnerColor = SessionLoadingStyle.tint(for: spinnerProvider)
                        ProcessingSpinner(color: spinnerColor)
                            .animation(.easeInOut(duration: 0.5), value: spinnerProvider)
                            .matchedGeometryEffect(id: "spinner", in: activityNamespace, isSource: showHeaderAgentActivity)
                    } else if hasWaitingForInput {
                        ReadyForInputIndicatorIcon(size: 14, color: TerminalColors.green)
                            .padding(1)
                            .matchedGeometryEffect(id: "spinner", in: activityNamespace, isSource: showHeaderAgentActivity)
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
                SessionListView(
                    sessionMonitor: sessionMonitor,
                    viewModel: viewModel,
                    musicManager: musicManager,
                    performanceMonitor: performanceMonitor,
                    isPerformanceMonitorEnabled: performanceMonitorEnabled
                )
            case .menu:
                NotchMenuView(
                    viewModel: viewModel,
                    primaryTextColor: expandedPrimaryTextColor,
                    secondaryTextColor: expandedSecondaryTextColor,
                    separatorColor: expandedSeparatorColor
                )
            case .shortcuts:
                ShortcutSettingsView(
                    viewModel: viewModel,
                    primaryTextColor: expandedPrimaryTextColor,
                    secondaryTextColor: expandedSecondaryTextColor,
                    separatorColor: expandedSeparatorColor
                )
            case .agents:
                AgentSettingsView(
                    viewModel: viewModel,
                    primaryTextColor: expandedPrimaryTextColor,
                    secondaryTextColor: expandedSecondaryTextColor,
                    separatorColor: expandedSeparatorColor
                )
            case .performanceSettings:
                PerformanceSettingsView(
                    viewModel: viewModel,
                    primaryTextColor: expandedPrimaryTextColor,
                    secondaryTextColor: expandedSecondaryTextColor,
                    separatorColor: expandedSeparatorColor
                )
            case .performance(let section):
                PerformanceDetailView(
                    viewModel: viewModel,
                    monitor: performanceMonitor,
                    section: section,
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
        viewModel.instancesPageShowsPerformance = performanceMonitorEnabled
        viewModel.instancesPageShowsMusic = showsMusic
    }

    // MARK: - Event Handlers

    private func handleProcessingChange() {
        if isAnyProcessing || hasPendingPermission {
            let activityType = activePendingPermissionActivityType ?? activeProcessingActivityType ?? .claude
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
            if viewModel.status == .closed && viewModel.hasPhysicalNotch && !vibeGlowVisible {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    if !vibeGlowVisible && !isAnyProcessing && !hasPendingPermission && !hasWaitingForInput && viewModel.status == .closed {
                        isVisible = false
                    }
                }
            }
        }
    }

    private func handleNotchTap() {
        viewModel.handleNotchTap()
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
                if viewModel.status == .closed && !vibeGlowVisible && !isAnyProcessing && !hasPendingPermission && !hasWaitingForInput && !showMusicActivity && !activityCoordinator.expandingActivity.show {
                    isVisible = false
                }
            }
        }
    }

    private func syncVisibilityForVibeGlow() {
        if vibeGlowVisible {
            isVisible = true
        } else if viewModel.status == .closed &&
                    viewModel.hasPhysicalNotch &&
                    !isAnyProcessing &&
                    !hasPendingPermission &&
                    !hasWaitingForInput &&
                    !showMusicActivity &&
                    !activityCoordinator.expandingActivity.show {
            isVisible = false
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

        // Get sessions that are now waiting for user action.
        let waitingForInputSessions = instances.filter {
            $0.phase == .waitingForInput || $0.phase.isWaitingForTerminalApproval
        }
        let currentIds = Set(waitingForInputSessions.map { $0.stableId })
        let newWaitingIds = currentIds.subtracting(previousWaitingForInputIds)

        // Track timestamps for newly waiting sessions
        for session in waitingForInputSessions where newWaitingIds.contains(session.stableId) {
            waitingForInputTimestamps[session.stableId] = now
        }

        // Track synthetic completion notifications for providers that keep a
        // short completed marker in the active session list.
        let completionMarkerSessions = instances.filter {
            $0.provider == .cursor && $0.completionNotificationAt != nil
        }
        var currentCompletionMarkers: [String: Date] = [:]
        var newCompletionSessions: [SessionState] = []

        for session in completionMarkerSessions {
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

        // Bounce the notch when a session newly enters waiting-for-input or emits a completion marker.
        if !newlyCompletedSessions.isEmpty {
            let debugContext = newlyCompletedSessions
                .map { "provider=\($0.provider.rawValue) session=\($0.sessionId)" }
                .joined(separator: ",")
            playNotificationSoundIfNeeded(forPids: newlyCompletedSessions.map(\.pid), debugContext: debugContext)
            triggerNotificationBounce()

            // Schedule hiding the checkmark after 30 seconds
            DispatchQueue.main.asyncAfter(deadline: .now() + displayDuration) { [self] in
                // Trigger a UI update to re-evaluate hasWaitingForInput
                handleProcessingChange()
            }
        }

        previousWaitingForInputIds = currentIds
        previousCompletionNotificationMarkers = currentCompletionMarkers
    }

    private func handleCompletionNotification(_ notification: SessionCompletionNotification) {
        let debugContext = "provider=\(notification.provider.rawValue) session=\(notification.sessionId)"
        DebugLog.shared.write("[notch-notification] completionReceived \(debugContext)")
        playNotificationSoundIfNeeded(forPids: [notification.pid], debugContext: debugContext)
        triggerNotificationBounce()
    }

    private func playNotificationSoundIfNeeded(forPids pids: [Int?], debugContext: String) {
        guard AppSettings.notificationSound.soundName != nil else { return }

        Task {
            let shouldPlaySound = await shouldPlayNotificationSound(forPids: pids)
            if shouldPlaySound {
                await MainActor.run {
                    NotificationSoundPlayer.play(AppSettings.notificationSound)
                }
                DebugLog.shared.write("[notch-notification] soundPlayed \(debugContext)")
            } else {
                DebugLog.shared.write("[notch-notification] soundSkippedFocused \(debugContext)")
            }
        }
    }

    private func triggerNotificationBounce() {
        DispatchQueue.main.async {
            isBouncing = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                isBouncing = false
            }
        }
    }

    /// Returns true if ANY notifying session is not actively focused.
    private func shouldPlayNotificationSound(forPids pids: [Int?]) async -> Bool {
        for pid in pids {
            guard let pid else {
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

private struct VibeSurroundGlow: View {
    let topCornerRadius: CGFloat
    let bottomCornerRadius: CGFloat

    private let cycleDuration: TimeInterval = 7.2
    private let innerGlowOffset: CGFloat = 3
    private let outerGlowOffset: CGFloat = 10
    private let colors: [Color] = [
        Color(red: 0.24, green: 0.82, blue: 1.00),
        Color(red: 0.76, green: 0.42, blue: 1.00),
        Color(red: 1.00, green: 0.42, blue: 0.68),
        Color(red: 0.34, green: 0.92, blue: 0.74),
        Color(red: 0.24, green: 0.82, blue: 1.00),
    ]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24.0)) { timeline in
            let phase = timeline.date.timeIntervalSinceReferenceDate
                .truncatingRemainder(dividingBy: cycleDuration) / cycleDuration
            let startAngle = Angle.degrees(-phase * 360)
            let gradient = AngularGradient(
                colors: colors,
                center: .center,
                startAngle: startAngle,
                endAngle: startAngle + .degrees(360)
            )
            let outerGlowEdge = VibeSurroundEdge(
                topCornerRadius: topCornerRadius,
                bottomCornerRadius: bottomCornerRadius,
                outwardOffset: outerGlowOffset
            )
            let innerGlowEdge = VibeSurroundEdge(
                topCornerRadius: topCornerRadius,
                bottomCornerRadius: bottomCornerRadius,
                outwardOffset: innerGlowOffset
            )

            ZStack {
                outerGlowEdge
                    .stroke(
                        gradient,
                        style: StrokeStyle(lineWidth: 18, lineCap: .round, lineJoin: .round)
                    )
                    .blur(radius: 16)
                    .opacity(0.34)

                innerGlowEdge
                    .stroke(
                        gradient,
                        style: StrokeStyle(lineWidth: 7, lineCap: .round, lineJoin: .round)
                    )
                    .blur(radius: 4)
                    .opacity(0.56)
            }
        }
        .allowsHitTesting(false)
    }
}

private struct VibeSurroundEdge: Shape {
    var topCornerRadius: CGFloat
    var bottomCornerRadius: CGFloat
    var outwardOffset: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { .init(topCornerRadius, bottomCornerRadius) }
        set {
            topCornerRadius = newValue.first
            bottomCornerRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let topY = rect.minY
        let bottomY = rect.maxY + outwardOffset
        let leftX = rect.minX + topCornerRadius - outwardOffset
        let rightX = rect.maxX - topCornerRadius + outwardOffset

        path.move(to: CGPoint(x: rect.maxX + outwardOffset, y: topY))
        path.addQuadCurve(
            to: CGPoint(x: rightX, y: topY + topCornerRadius),
            control: CGPoint(x: rightX, y: topY)
        )
        path.addLine(to: CGPoint(x: rightX, y: bottomY - bottomCornerRadius))
        path.addQuadCurve(
            to: CGPoint(x: rightX - bottomCornerRadius, y: bottomY),
            control: CGPoint(x: rightX, y: bottomY)
        )
        path.addLine(to: CGPoint(x: leftX + bottomCornerRadius, y: bottomY))
        path.addQuadCurve(
            to: CGPoint(x: leftX, y: bottomY - bottomCornerRadius),
            control: CGPoint(x: leftX, y: bottomY)
        )
        path.addLine(to: CGPoint(x: leftX, y: topY + topCornerRadius))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX - outwardOffset, y: topY),
            control: CGPoint(x: leftX, y: topY)
        )

        return path
    }
}
