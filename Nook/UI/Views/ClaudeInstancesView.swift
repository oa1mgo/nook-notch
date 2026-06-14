//
//  ClaudeInstancesView.swift
//  Nook
//
//  Minimal instances list matching Dynamic Island aesthetic
//

import Combine
import SwiftUI

struct ClaudeInstancesView: View {
    @ObservedObject var sessionMonitor: ClaudeSessionMonitor
    @ObservedObject var viewModel: NotchViewModel
    @ObservedObject var musicManager: MusicManager
    @ObservedObject var performanceMonitor: PerformanceMonitor
    let isPerformanceMonitorEnabled: Bool

    @State private var instanceRowHeight: CGFloat = 0
    @State private var performanceRowHeight: CGFloat = 0
    @State private var musicCardHeight: CGFloat = 0

    private var showsPerformanceRow: Bool { isPerformanceMonitorEnabled }
    private var showsMusicCard: Bool { musicManager.isVisible }

    private var maxInstancesListHeight: CGFloat {
        InstancesListLayout.maxListHeight(
            rowHeight: instanceRowHeight
        )
    }

    private var resolvedInstancesListMaxHeight: CGFloat? {
        instanceRowHeight > 0 ? maxInstancesListHeight : nil
    }

    private var measuredListHeight: CGFloat? {
        guard instanceRowHeight > 0 else { return nil }

        return InstancesListLayout.listHeight(
            rowHeight: instanceRowHeight,
            sessionCount: sortedInstances.count
        )
    }

    private var appliedInstancesListHeight: CGFloat? {
        guard let measuredListHeight else { return nil }
        return InstancesListLayout.appliedListHeight(
            contentHeight: measuredListHeight,
            maxHeight: maxInstancesListHeight
        )
    }

    var body: some View {
        VStack(spacing: 8) {
            if showsPerformanceRow {
                PerformanceSummaryRow(monitor: performanceMonitor) {
                    viewModel.pushTo(.performance(.overview))
                }
                .padding(.top, InstancesListLayout.performanceTopInset)
                .measureHeight(using: PerformanceRowHeightKey.self) { performanceRowHeight = $0 }
            }

            if showsMusicCard {
                MusicCardView(musicManager: musicManager)
                    .measureHeight(using: MusicCardHeightKey.self) { musicCardHeight = $0 }
            }

            if sessionMonitor.instances.isEmpty {
                emptyState
            } else {
                instancesList
            }
        }
        .onAppear {
            syncLayoutMetrics()
        }
        .onChange(of: musicManager.isVisible) { _, _ in
            syncLayoutMetrics()
        }
        .onChange(of: isPerformanceMonitorEnabled) { _, _ in
            syncLayoutMetrics()
        }
        .onChange(of: performanceRowHeight) { _, _ in
            syncLayoutMetrics()
        }
        .onChange(of: musicCardHeight) { _, _ in
            syncLayoutMetrics()
        }
        .onChange(of: instanceRowHeight) { _, _ in
            syncLayoutMetrics()
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 0) {
            Text("No sessions")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(.white.opacity(0.58))

            Text("Run claude in terminal or start a codex session")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.white.opacity(0.26))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 220)
                .padding(.top, 10)
        }
        .multilineTextAlignment(.center)
        .frame(
            maxWidth: .infinity,
            minHeight: InstancesListLayout.emptyStateHeight,
            maxHeight: InstancesListLayout.emptyStateHeight,
            alignment: .center
        )
    }

    // MARK: - Instances List

    /// Priority: active (approval/processing/compacting) > waitingForInput > idle
    /// Secondary sort: by last user message date (stable - doesn't change when agent responds)
    /// Note: approval requests stay in their date-based position to avoid layout shift
    private var sortedInstances: [SessionState] {
        sessionMonitor.instances.sorted { a, b in
            let priorityA = phasePriority(a.phase)
            let priorityB = phasePriority(b.phase)
            if priorityA != priorityB {
                return priorityA < priorityB
            }
            // Sort by last user message date (more recent first)
            // Fall back to lastActivity if no user messages yet
            let dateA = a.lastUserMessageDate ?? a.lastActivity
            let dateB = b.lastUserMessageDate ?? b.lastActivity
            return dateA > dateB
        }
    }

    /// Lower number = higher priority
    /// Approval requests share priority with processing to maintain stable ordering
    private func phasePriority(_ phase: SessionPhase) -> Int {
        switch phase {
        case .waitingForApproval, .processing, .compacting: return 0
        case .waitingForInput: return 1
        case .idle, .ended: return 2
        }
    }

    private var instancesList: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 2) {
                    ForEach(Array(sortedInstances.enumerated()), id: \.element.stableId) { index, session in
                        InstanceRow(
                            session: session,
                            onFocus: { focusSession(session) },
                            onChat: { openChat(session) },
                            onArchive: { archiveSession(session) },
                            onApprove: { approveSession(session) },
                            onReject: { rejectSession(session) },
                            isKeyboardSelected: index == viewModel.keyboardSelectedIndex
                        )
                        .measureHeight(using: InstanceRowHeightKey.self) {
                            if index == 0 {
                                instanceRowHeight = $0
                            }
                        }
                        .id(session.stableId)
                    }
                }
                .padding(.vertical, 4)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: resolvedInstancesListMaxHeight)
            .onChange(of: viewModel.keyboardSelectedIndex) { _, idx in
                guard idx < sortedInstances.count else { return }
                withAnimation(.smooth(duration: 0.2)) {
                    proxy.scrollTo(sortedInstances[idx].stableId, anchor: .center)
                }
            }
            .onReceive(viewModel.$keyboardActivateTrigger) { trigger in
                guard trigger != nil,
                      viewModel.keyboardSelectedIndex >= 0,
                      viewModel.keyboardSelectedIndex < sortedInstances.count else { return }
                openChat(sortedInstances[viewModel.keyboardSelectedIndex])
            }
        }
    }

    // MARK: - Actions

    private func focusSession(_ session: SessionState) {
        guard session.isInTmux else { return }

        Task {
            if let pid = session.pid {
                _ = await YabaiController.shared.focusWindow(forClaudePid: pid)
            } else {
                _ = await YabaiController.shared.focusWindow(forWorkingDirectory: session.cwd)
            }
        }
    }

    private func openChat(_ session: SessionState) {
        viewModel.showChat(for: session)
    }

    private func approveSession(_ session: SessionState) {
        sessionMonitor.approvePermission(sessionId: session.sessionId)
    }

    private func rejectSession(_ session: SessionState) {
        sessionMonitor.denyPermission(sessionId: session.sessionId, reason: nil)
    }

    private func archiveSession(_ session: SessionState) {
        sessionMonitor.archiveSession(sessionId: session.sessionId)
    }
}

private enum InstancesListLayout {
    static let targetVisibleRows: CGFloat = 3.2
    static let contentSpacing: CGFloat = 8
    static let performanceTopInset: CGFloat = 8
    static let listRowSpacing: CGFloat = 2
    static let listVerticalPadding: CGFloat = 4
    static let emptyStateHeight: CGFloat = 84

    static func maxListHeight(rowHeight: CGFloat) -> CGFloat {
        listHeight(rowHeight: rowHeight, visibleRows: targetVisibleRows)
    }

    static func listHeight(rowHeight: CGFloat, sessionCount: Int) -> CGFloat {
        listHeight(
            rowHeight: rowHeight,
            visibleRows: min(CGFloat(max(0, sessionCount)), targetVisibleRows)
        )
    }

    static func appliedListHeight(
        contentHeight: CGFloat,
        maxHeight: CGFloat
    ) -> CGFloat {
        min(max(0, contentHeight), max(0, maxHeight))
    }

    private static func listHeight(rowHeight: CGFloat, visibleRows: CGFloat) -> CGFloat {
        let clampedVisibleRows = max(0, visibleRows)
        let visibleRowsHeight = max(0, rowHeight) * clampedVisibleRows
        let visibleSpacingCount = max(0, ceil(clampedVisibleRows) - 1)
        let spacingHeight = listRowSpacing * visibleSpacingCount
        let verticalPaddingHeight = listVerticalPadding * 2
        return visibleRowsHeight + spacingHeight + verticalPaddingHeight
    }
}

private struct InstanceRowHeightKey: PreferenceKey {
    static var defaultValue: CGFloat { 0 }

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct MusicCardHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct PerformanceRowHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct MeasuredHeightReader<Key: PreferenceKey>: ViewModifier where Key.Value == CGFloat {
    let onChange: (CGFloat) -> Void

    func body(content: Content) -> some View {
        content
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(key: Key.self, value: proxy.size.height)
                }
            )
            .onPreferenceChange(Key.self, perform: onChange)
    }
}

private extension View {
    func measureHeight<Key: PreferenceKey>(
        using _: Key.Type,
        _ onChange: @escaping (CGFloat) -> Void
    ) -> some View where Key.Value == CGFloat {
        modifier(MeasuredHeightReader<Key>(onChange: onChange))
    }
}

private extension ClaudeInstancesView {
    func syncLayoutMetrics() {
        guard viewModel.contentType == .instances else { return }

        if abs(viewModel.instancesPageRowHeight - instanceRowHeight) > 0.5 {
            viewModel.instancesPageRowHeight = instanceRowHeight
        }

        if abs(viewModel.instancesPagePerformanceRowHeight - performanceRowHeight) > 0.5 {
            viewModel.instancesPagePerformanceRowHeight = performanceRowHeight
        }

        if abs(viewModel.instancesPageMusicCardHeight - musicCardHeight) > 0.5 {
            viewModel.instancesPageMusicCardHeight = musicCardHeight
        }
    }
}

// MARK: - Instance Row

struct InstanceRow: View {
    let session: SessionState
    let onFocus: () -> Void
    let onChat: () -> Void
    let onArchive: () -> Void
    let onApprove: () -> Void
    let onReject: () -> Void
    let isKeyboardSelected: Bool

    @State private var isHovered = false
    @State private var isYabaiAvailable = false

    private var providerTint: Color {
        SessionLoadingStyle.tint(for: session.provider)
    }

    private var providerLabelForeground: Color {
        switch session.provider {
        case .claude:
            return Color(red: 0.98, green: 0.82, blue: 0.62)
        case .codex:
            return Color(red: 0.80, green: 0.90, blue: 0.98)
        case .opencode:
            return Color(red: 0.72, green: 0.95, blue: 0.72)
        }
    }

    private var providerLabelBackground: Color {
        switch session.provider {
        case .claude:
            return Color(red: 0.85, green: 0.47, blue: 0.34).opacity(0.28)
        case .codex:
            return Color(red: 0.50, green: 0.60, blue: 0.66).opacity(0.40)
        case .opencode:
            return Color(red: 0.40, green: 0.80, blue: 0.40).opacity(0.28)
        }
    }

    /// Whether we're showing the approval UI
    private var isWaitingForApproval: Bool {
        session.phase.isWaitingForApproval
    }

    /// Whether the pending tool requires interactive input (not just approve/deny)
    private var isInteractiveTool: Bool {
        guard let toolName = session.pendingToolName else { return false }
        return ToolCallItem.kind(of: toolName) == .askUserQuestion
    }

    /// Status text based on session phase (fallback when no other content)
    private var phaseStatusText: String {
        switch session.phase {
        case .processing:
            return "Processing..."
        case .compacting:
            return "Compacting..."
        case .waitingForInput:
            return "Ready"
        case .waitingForApproval:
            return "Waiting for approval"
        case .idle:
            return "Idle"
        case .ended:
            return "Ended"
        }
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            // State indicator on left
            stateIndicator
                .frame(width: 14)

            // Text content
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(session.displayTitle)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white)
                        .lineLimit(1)

                    Text(session.provider.displayName)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(providerLabelForeground)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(providerLabelBackground)
                        .clipShape(Capsule())

                    // Token usage indicator
                    if session.usage.totalTokens > 0 {
                        Text(session.usage.formattedTotal)
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundColor(.white.opacity(0.3))
                    }
                }

                // Show tool call when waiting for approval, otherwise last activity
                if isWaitingForApproval, let toolName = session.pendingToolName {
                    // Show tool name in amber + input on same line
                    HStack(spacing: 4) {
                        Text(MCPToolFormatter.formatToolName(toolName))
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundColor(TerminalColors.amber.opacity(0.9))
                        if isInteractiveTool {
                            Text("Needs your input")
                                .font(.system(size: 11))
                                .foregroundColor(.white.opacity(0.5))
                                .lineLimit(1)
                        } else if let input = session.pendingToolInput {
                            Text(input)
                                .font(.system(size: 11))
                                .foregroundColor(.white.opacity(0.5))
                                .lineLimit(1)
                        }
                    }
                } else if let role = session.lastMessageRole {
                    switch role {
                    case "tool":
                        // Tool call - show tool name + input
                        HStack(spacing: 4) {
                            if let toolName = session.lastToolName {
                                Text(MCPToolFormatter.formatToolName(toolName))
                                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                                    .foregroundColor(.white.opacity(0.5))
                            }
                            if let input = session.lastMessage {
                                Text(input)
                                    .font(.system(size: 11))
                                    .foregroundColor(.white.opacity(0.4))
                                    .lineLimit(1)
                            }
                        }
                    case "user":
                        // User message - prefix with "You:"
                        HStack(spacing: 4) {
                            Text("You:")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(.white.opacity(0.5))
                            if let msg = session.lastMessage {
                                Text(msg)
                                    .font(.system(size: 11))
                                    .foregroundColor(.white.opacity(0.4))
                                    .lineLimit(1)
                            }
                        }
                    default:
                        // Assistant message - just show text
                        if let msg = session.lastMessage {
                            Text(msg)
                                .font(.system(size: 11))
                                .foregroundColor(.white.opacity(0.4))
                                .lineLimit(1)
                        }
                    }
                } else if let lastMsg = session.lastMessage {
                    Text(lastMsg)
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.4))
                        .lineLimit(1)
                } else {
                    // Fallback: show phase-based status when no other content
                    Text(phaseStatusText)
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.4))
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)

            // Action icons or approval buttons
            if isWaitingForApproval && isInteractiveTool {
                // Interactive tools like AskUserQuestion - show chat + terminal buttons
                HStack(spacing: 8) {
                    IconButton(icon: "bubble.left") {
                        onChat()
                    }

                    // Go to Terminal button (only if yabai available)
                    if isYabaiAvailable {
                        TerminalButton(
                            isEnabled: session.isInTmux,
                            onTap: { onFocus() }
                        )
                    }
                }
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
            } else if isWaitingForApproval {
                InlineApprovalButtons(
                    onChat: onChat,
                    onApprove: onApprove,
                    onReject: onReject
                )
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
            } else {
                HStack(spacing: 8) {
                    // Chat icon - always show
                    IconButton(icon: "bubble.left") {
                        onChat()
                    }

                    // Focus icon (only for tmux instances with yabai)
                    if session.isInTmux && isYabaiAvailable {
                        IconButton(icon: "eye") {
                            onFocus()
                        }
                    }

                    // Archive button - only for idle or completed sessions
                    if session.phase == .idle || session.phase == .waitingForInput {
                        IconButton(icon: "archivebox") {
                            onArchive()
                        }
                    }
                }
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, 14)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            onChat()
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: isWaitingForApproval)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(isKeyboardSelected ? Color.white.opacity(0.08) : (isHovered ? Color.white.opacity(0.06) : Color.clear))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(isKeyboardSelected ? Color.white.opacity(0.2) : Color.clear, lineWidth: 1)
        )
        .onHover { isHovered = $0 }
        .task {
            isYabaiAvailable = await WindowFinder.shared.isYabaiAvailable()
        }
    }

    @ViewBuilder
    private var stateIndicator: some View {
        switch session.phase {
        case .processing, .compacting:
            ProcessingSpinner(provider: session.provider)
        case .waitingForApproval:
            ProcessingSpinner(color: TerminalColors.amber)
        case .waitingForInput:
            // Pixel speech bubble (12×12) — visually distinct from the
            // 6×6 idle dot, matches the opencode ask_user_question /
            // Claude Code "Ready for input" state semantically.
            WaitingForInputIcon(size: 12)
        case .idle, .ended:
            Circle()
                .fill(Color.white.opacity(0.2))
                .frame(width: 6, height: 6)
        }
    }

}

// MARK: - Inline Approval Buttons

/// Compact inline approval buttons with staggered animation
struct InlineApprovalButtons: View {
    let onChat: () -> Void
    let onApprove: () -> Void
    let onReject: () -> Void

    @State private var showChatButton = false
    @State private var showDenyButton = false
    @State private var showAllowButton = false

    var body: some View {
        HStack(spacing: 6) {
            // Chat button
            IconButton(icon: "bubble.left") {
                onChat()
            }
            .opacity(showChatButton ? 1 : 0)
            .scaleEffect(showChatButton ? 1 : 0.8)

            Button {
                onReject()
            } label: {
                Text("Deny")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.6))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.white.opacity(0.1))
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .opacity(showDenyButton ? 1 : 0)
            .scaleEffect(showDenyButton ? 1 : 0.8)

            Button {
                onApprove()
            } label: {
                Text("Allow")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.black)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.white.opacity(0.9))
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .opacity(showAllowButton ? 1 : 0)
            .scaleEffect(showAllowButton ? 1 : 0.8)
        }
        .onAppear {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7).delay(0.0)) {
                showChatButton = true
            }
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7).delay(0.05)) {
                showDenyButton = true
            }
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7).delay(0.1)) {
                showAllowButton = true
            }
        }
    }
}

// MARK: - Icon Button

struct IconButton: View {
    let icon: String
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button {
            action()
        } label: {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(isHovered ? .white.opacity(0.8) : .white.opacity(0.4))
                .frame(width: 24, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isHovered ? Color.white.opacity(0.1) : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

// MARK: - Compact Terminal Button (inline in description)

struct CompactTerminalButton: View {
    let isEnabled: Bool
    let onTap: () -> Void

    var body: some View {
        Button {
            if isEnabled {
                onTap()
            }
        } label: {
            HStack(spacing: 2) {
                Image(systemName: "terminal")
                    .font(.system(size: 8, weight: .medium))
                Text("Go to Terminal")
                    .font(.system(size: 10, weight: .medium))
            }
            .foregroundColor(isEnabled ? .white.opacity(0.9) : .white.opacity(0.3))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(isEnabled ? Color.white.opacity(0.15) : Color.white.opacity(0.05))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Terminal Button

struct TerminalButton: View {
    let isEnabled: Bool
    let onTap: () -> Void

    var body: some View {
        Button {
            if isEnabled {
                onTap()
            }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "terminal")
                    .font(.system(size: 9, weight: .medium))
                Text("Terminal")
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundColor(isEnabled ? .black : .white.opacity(0.4))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(isEnabled ? Color.white.opacity(0.95) : Color.white.opacity(0.1))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}
