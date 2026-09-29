//
//  SessionListView.swift
//  Nook
//
//  Minimal instances list matching Dynamic Island aesthetic
//

import Combine
import SwiftUI

extension SessionState {
    /// SOI: row renders InlineApprovalButtons — keyboard Y/N/A target.
    /// Mirrors InstanceRow action-area branch (SessionListView.swift
    /// `isWaitingForTerminalApproval || (... && isInteractiveTool)` first,
    /// then approval buttons). Keep both in sync when either changes.
    ///
    /// Premise: `phase.isWaitingForApproval` matches ONLY
    /// `.waitingForApproval` (SessionPhase.swift L266-269) — terminal-side
    /// `.waitingForTerminalApproval` is a different case and is NOT
    /// included. Targets do not pass through InstanceRow's else-if chain,
    /// so this exclusivity is what keeps terminal-approval rows out of the
    /// keyboard target set. Do not "merge" the two phase helpers.
    var showsInlineApprovalButtons: Bool {
        guard phase.isWaitingForApproval else { return false }
        if let tool = pendingToolName, ToolCallItem.kind(of: tool) == .askUserQuestion {
            return false // branch 1: Go to Terminal, not Y/N/A
        }
        return true
    }

    /// Always button exists only for OpenCode (mirrors onApproveAlways wiring at call site L195).
    var canApproveAlways: Bool { showsInlineApprovalButtons && provider == .opencode }
}

struct SessionListView: View {
    @ObservedObject var sessionMonitor: SessionMonitor
    @ObservedObject var viewModel: NotchViewModel
    @ObservedObject var musicManager: MusicManager
    @ObservedObject var performanceMonitor: PerformanceMonitor
    let isPerformanceMonitorEnabled: Bool
    @AppStorage(AppSettings.musicAbovePerformanceKey) private var musicAbovePerformance: Bool = false

    @State private var instanceRowHeight: CGFloat = 0
    @State private var performanceRowHeight: CGFloat = 0
    @State private var musicCardHeight: CGFloat = 0
    /// The session currently in Always-confirm mode (Patterns + Cancel/Confirm).
    /// Parent-scoped so only one row can be in confirm mode at a time and the
    /// keyboard path can drive it (spec §5).
    @State private var confirmingSessionId: String?
    /// Local keyDown monitor for Y/N/A/C/Esc (installed on appear — spec §4).
    @State private var keyMonitor: Any?

    private var showsPerformanceRow: Bool { isPerformanceMonitorEnabled }
    private var showsMusicCard: Bool { musicManager.isVisible }

    /// Open the music source app (Apple Music / Spotify / etc.) and dismiss
    /// the notch so the user actually sees the app they just asked for.
    /// `restorePreviousApp` defaults to `false` because activating the music
    /// app is the user's intent — we must not yank focus back to wherever
    /// Nook stole it from.
    private func handleOpenMusicSource() {
        musicManager.openSourceApp()
        viewModel.notchClose()
    }

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
            if musicAbovePerformance {
                if showsMusicCard {
                    MusicCardView(
                        musicManager: musicManager,
                        onOpenSourceApp: handleOpenMusicSource
                    )
                    .measureHeight(using: MusicCardHeightKey.self) { musicCardHeight = $0 }
                }

                if showsPerformanceRow {
                    PerformanceSummaryRow(monitor: performanceMonitor) {
                        viewModel.pushTo(.performance(.overview))
                    }
                    .measureHeight(using: PerformanceRowHeightKey.self) { performanceRowHeight = $0 }
                }
            } else {
                if showsPerformanceRow {
                    PerformanceSummaryRow(monitor: performanceMonitor) {
                        viewModel.pushTo(.performance(.overview))
                    }
                    .measureHeight(using: PerformanceRowHeightKey.self) { performanceRowHeight = $0 }
                }

                if showsMusicCard {
                    MusicCardView(
                        musicManager: musicManager,
                        onOpenSourceApp: handleOpenMusicSource
                    )
                    .measureHeight(using: MusicCardHeightKey.self) { musicCardHeight = $0 }
                }
            }

            if sessionMonitor.instances.isEmpty {
                emptyState
            } else {
                instancesList
            }
        }
        .onAppear {
            syncLayoutMetrics()
            installKeyboardMonitor()
        }
        .onChange(of: musicManager.isVisible) { _, _ in
            syncLayoutMetrics()
        }
        .onChange(of: isPerformanceMonitorEnabled) { _, _ in
            syncLayoutMetrics()
        }
        .onChange(of: musicAbovePerformance) { _, _ in
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
        .onChange(of: approvalTargets) { _, newTargets in
            if let id = confirmingSessionId,
               !newTargets.contains(where: { $0.sessionId == id }) {
                confirmingSessionId = nil
            }
        }
        .onDisappear {
            removeKeyboardMonitor()
            confirmingSessionId = nil
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

    /// Rows that render InlineApprovalButtons — keyboard Y/N/A targets (spec §1).
    private var approvalTargets: [SessionState] {
        sortedInstances.filter(\.showsInlineApprovalButtons)
    }

    /// Lower number = higher priority
    /// Approval requests share priority with processing to maintain stable ordering
    private func phasePriority(_ phase: SessionPhase) -> Int {
        switch phase {
        case .waitingForApproval, .waitingForTerminalApproval, .processing, .compacting: return 0
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
                            onReply: session.phase == .waitingForInput ? { replyToQuestion(session) } : nil,
                            onApprove: { approveSession(session) },
                            onReject: { rejectSession(session) },
                            onApproveAlways: session.provider == .opencode ? { approveAlwaysSession(session) } : nil,
                            isKeyboardSelected: index == viewModel.keyboardSelectedIndex,
                            isConfirmingAlways: Binding(
                                get: { confirmingSessionId == session.sessionId },
                                set: { confirmingSessionId = $0 ? session.sessionId : nil }
                            )
                        )
                        .measureHeight(using: InstanceRowHeightKey.self) {
                            if index == 0 {
                                instanceRowHeight = $0
                            }
                        }
                        .id(session.stableId)
                    }
                }
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
                guard trigger != nil else { return }
                // Consume immediately: @Published replays the current value to
                // every new subscription, and this view re-subscribes every time
                // it re-mounts (chat → back). A leftover UUID would re-fire.
                viewModel.keyboardActivateTrigger = nil
                guard viewModel.keyboardSelectedIndex >= 0,
                      viewModel.keyboardSelectedIndex < sortedInstances.count else { return }
                openChat(sortedInstances[viewModel.keyboardSelectedIndex])
            }
            .onReceive(viewModel.$keyboardReplyTrigger) { trigger in
                guard trigger != nil else { return }
                viewModel.keyboardReplyTrigger = nil // consume (see above)
                guard viewModel.contentType == .instances else { return }
                // Target set + 0/1/2+ rule: reply-shortcut spec §3.2 (shared
                // resolver with permission Y/N/A below).
                // Single snapshot: `sortedInstances` re-sorts on every access, and
                // `highlighted` (by index) + `targets` (by filter) must come from the
                // same array, else index and membership can disagree.
                let rows = sortedInstances
                let idx = viewModel.keyboardSelectedIndex
                let highlighted = (idx >= 0 && idx < rows.count) ? rows[idx] : nil
                let targets = rows.filter { $0.phase == .waitingForInput }
                guard let target = KeyboardTargetResolver.resolve(from: targets, highlighted: highlighted) else { return }
                replyToQuestion(target)
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

    private func approveAlwaysSession(_ session: SessionState) {
        DebugLog.shared.write("[notch] approveAlwaysSession sessionId=\(session.sessionId) provider=\(session.provider) activePermission=\(session.activePermission != nil)")
        sessionMonitor.approvePermission(sessionId: session.sessionId, always: true)
    }

    private func rejectSession(_ session: SessionState) {
        sessionMonitor.denyPermission(sessionId: session.sessionId, reason: nil)
    }

    // MARK: - Keyboard (AppKit local monitor — Y/N/A on instances page)

    private func installKeyboardMonitor() {
        guard keyMonitor == nil else { return }
        // Deliberately NO NSApp.activate / makeKey here: NotchWindowController
        // L75-77 skips activate only for .notification opens (task-finished
        // notifications mount THIS page while the user types elsewhere —
        // activating would route subsequent keystrokes into Nook and a stray
        // `y` could approve a permission). User-initiated opens (click/hover/
        // hotkey) are already key via the window controller.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            self.handleKeyDown(event)
        }
    }

    private func removeKeyboardMonitor() {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
    }

    private func handleKeyDown(_ event: NSEvent) -> NSEvent? {
        // Skip when an editable text field is focused (mirrors ChatApprovalBar)
        if let responder = NSApp.keyWindow?.firstResponder,
           (responder.isKind(of: NSTextView.self) || responder.isKind(of: NSTextField.self)) {
            return event
        }

        // Ignore auto-repeat: holding y/n/a must not cascade-approve as
        // targets leave the list and count drops 2+ → 1 (spec: multi-pending
        // requires explicit highlight). First physical press is not a repeat.
        if event.isARepeat {
            return event
        }

        let mods = event.modifierFlags
        guard !mods.contains(.command), !mods.contains(.control) else { return event }

        let chars = event.charactersIgnoringModifiers?.lowercased() ?? ""

        // Confirm step: scoped to confirmingSessionId's row (may differ from highlight)
        if confirmingSessionId != nil {
            if chars == "c" {
                if let id = confirmingSessionId,
                   let session = sortedInstances.first(where: { $0.sessionId == id }) {
                    approveAlwaysSession(session)
                }
                confirmingSessionId = nil
                return nil
            }
            if event.keyCode == 53 { // Esc — cancel confirm only; NOT closeNotch
                                     // (list monitor is LIFO-later ⇒ receives first)
                confirmingSessionId = nil
                return nil
            }
            return event
        }

        guard chars == "y" || chars == "n" || chars == "a" else { return event }

        // Resolve target (permission-shortcuts spec §2 — shared with question
        // ⌃R via KeyboardTargetResolver): 0 → none; 1 → ignore highlight;
        // 2+ → highlight must be a target. Single snapshot for idx + membership.
        let rows = sortedInstances
        let idx = viewModel.keyboardSelectedIndex // -1 = no highlight (NotchViewModel L118)
        let highlighted = (idx >= 0 && idx < rows.count) ? rows[idx] : nil
        let target: SessionState? = KeyboardTargetResolver.resolve(
            from: rows.filter(\.showsInlineApprovalButtons), highlighted: highlighted
        )
        guard let target else { return event }

        switch chars {
        case "y":
            approveSession(target)
            return nil
        case "n":
            rejectSession(target)
            return nil
        case "a":
            guard target.canApproveAlways else { return event } // non-OpenCode: pass through
            confirmingSessionId = target.sessionId
            return nil
        default:
            return event
        }
    }

    private func archiveSession(_ session: SessionState) {
        sessionMonitor.archiveSession(sessionId: session.sessionId)
    }

    /// Skip chat and go straight to the question panel. Previously this
    /// went through chat first (instances → chat → question) which
    /// produced a visible "expand then shrink" animation as the panel
    /// size resolved three times. Going direct (instances → question)
    /// gives a single, smooth size transition matching the panel's
    /// intended final dimensions.
    private func replyToQuestion(_ session: SessionState) {
        viewModel.notchOpen(reason: .notification)
        viewModel.pushTo(.question(session))
    }
}

private enum InstancesListLayout {
    static let targetVisibleRows: CGFloat = 3.2
    static let contentSpacing: CGFloat = 6
    static let listRowSpacing: CGFloat = 2
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
        return visibleRowsHeight + spacingHeight
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

private extension SessionListView {
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
    /// Optional "Reply to question" affordance. When non-nil, a reply icon
    /// renders next to the archive button and the click opens the chat view
    /// with the question panel pushed (so the user doesn't need to enter the
    /// chat view first then re-open the question UI after collapsing the notch).
    let onReply: (() -> Void)?
    let onApprove: () -> Void
    let onReject: () -> Void
    /// Optional "Always allow" affordance. When non-nil, the inline approval
    /// buttons render a third red-tinted button that grants a session-wide
    /// allowance. Only wired up for OpenCode sessions.
    let onApproveAlways: (() -> Void)?
    let isKeyboardSelected: Bool
    /// Parent-owned Always-confirm mode (was per-row @State — allowed two rows
    /// to confirm simultaneously; hoisted per spec §5).
    @Binding var isConfirmingAlways: Bool

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
        case .cursor:
            return Color(red: 0.86, green: 0.86, blue: 0.84)
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
        case .cursor:
            return Color(red: 0.12, green: 0.12, blue: 0.12).opacity(0.42)
        }
    }

    /// Whether we're showing the approval UI
    private var isWaitingForApproval: Bool {
        session.phase.isWaitingForApproval
    }

    private var isWaitingForTerminalApproval: Bool {
        session.phase.isWaitingForTerminalApproval
    }

    /// Whether the session is waiting for user input (AskUserQuestion).
    /// Unified across providers: Claude sends status: "waiting_for_input",
    /// OpenCode sends PermissionRequest — both resolve to .waitingForInput.
    private var isWaitingForUserInput: Bool {
        session.phase.isWaitingForInput && isInteractiveTool
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
        case .waitingForTerminalApproval:
            return "Approval needed in terminal"
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
                if isConfirmingAlways {
                    // Confirm mode: show "Patterns" label + allowed patterns
                    Text("Patterns")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white)
                        .lineLimit(1)
                    let patterns = session.activePermission?.alwaysPatterns ?? []
                    let text = patterns.count == 1 && patterns[0] == "*"
                        ? "Allow all until restart"
                        : patterns.joined(separator: ", ")
                    MarqueeText(text: text, font: .system(size: 10), color: .white.opacity(0.5))
                        .frame(maxWidth: 200, alignment: .leading)
                } else {
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

                        if session.usage.totalTokens > 0 {
                            Text(session.usage.formattedTotal)
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                                .foregroundColor(.white.opacity(0.3))
                        }
                    }

                    if (isWaitingForApproval || isWaitingForTerminalApproval || isWaitingForUserInput),
                       let toolName = session.pendingToolName {
                        HStack(spacing: 6) {
                            Text(MCPToolFormatter.formatToolName(toolName))
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(TerminalColors.amber.opacity(0.9))
                                .fixedSize(horizontal: true, vertical: false)
                            if isInteractiveTool {
                                Text("Needs your input")
                                    .font(.system(size: 11))
                                    .foregroundColor(.white.opacity(0.5))
                                    .lineLimit(1)
                            } else if let input = session.pendingToolInput {
                                MarqueeText(
                                    text: input,
                                    font: .system(size: 11),
                                    color: .white.opacity(0.5)
                                )
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    } else if let role = session.lastMessageRole {
                        switch role {
                        case "tool":
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
                        Text(phaseStatusText)
                            .font(.system(size: 11))
                            .foregroundColor(.white.opacity(0.4))
                            .lineLimit(1)
                    }
                }
            }
            // layoutPriority(1) so the title + status column claims its
            // natural width first when reply/archive/focus buttons appear
            // on the right; without this the action icons eat into the
            // title's available space (especially with 2-3 buttons in
            // waitingForInput + tmux+yabai rows).
            .layoutPriority(1)

            Spacer(minLength: 0)

            // Action icons or approval buttons
            if isWaitingForTerminalApproval || ((isWaitingForApproval || isWaitingForUserInput) && isInteractiveTool) {
                // Interactive tools and terminal-side approval prompts need terminal focus.
                HStack(spacing: 8) {
                    // Go to Terminal button (only if yabai available)
                    if isYabaiAvailable {
                        TerminalButton(
                            isEnabled: session.isInTmux,
                            onTap: { onFocus() }
                        )
                    }
                }
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
            } else if session.showsInlineApprovalButtons {
                InlineApprovalButtons(
                    onApprove: onApprove,
                    onReject: onReject,
                    onApproveAlways: onApproveAlways,
                    isConfirmingAlways: $isConfirmingAlways
                )
                .layoutPriority(1)
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
            } else {
                HStack(spacing: 8) {
                    // Left: Focus (eye) when available — only for tmux+yabai.
                    if session.isInTmux && isYabaiAvailable {
                        IconButton(icon: "eye") {
                            onFocus()
                        }
                    }

                    // Push everything else right.
                    Spacer(minLength: 0)

                    // Right cluster: Reply (bubble, when waitingForInput)
                    // sits immediately to the LEFT of Archive so the two
                    // primary row actions group together. Archive always
                    // stays at the far-right edge.
                    if let onReply, session.phase == .waitingForInput {
                        IconButton(icon: "questionmark.bubble.fill") {
                            onReply()
                        }
                        .help("Reply to question (⌃R)")
                    }
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
        .onTapGesture(count: 1) {
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
        case .waitingForApproval, .waitingForTerminalApproval:
            ProcessingSpinner(color: TerminalColors.amber)
        case .waitingForInput:
            // Same pixel-art icon as the question close-state / panel
            // header, tinted amber so the session row matches the
            // question view. 12pt mirrors the original speech bubble size.
            PermissionIndicatorIcon(size: 12, color: TerminalColors.amber)
        case .idle, .ended:
            Circle()
                .fill(Color.white.opacity(0.2))
                .frame(width: 6, height: 6)
        }
    }

}

// MARK: - Inline Approval Buttons

/// Compact inline approval buttons with staggered animation.
/// When the user taps "Always", the buttons swap to Confirm / Cancel
/// (inline, no extra text — notch space is too tight for patterns).
struct InlineApprovalButtons: View {
    let onApprove: () -> Void
    let onReject: () -> Void
    let onApproveAlways: (() -> Void)?
    @Binding var isConfirmingAlways: Bool

    @State private var showDenyButton = false
    @State private var showAllowButton = false
    @State private var showAlwaysButton = false

    init(
        onApprove: @escaping () -> Void,
        onReject: @escaping () -> Void,
        onApproveAlways: (() -> Void)? = nil,
        isConfirmingAlways: Binding<Bool> = .constant(false)
    ) {
        self.onApprove = onApprove
        self.onReject = onReject
        self.onApproveAlways = onApproveAlways
        self._isConfirmingAlways = isConfirmingAlways
    }

    var body: some View {
        // Button row only — patterns info is displayed by the parent (InstanceRow)
        HStack(spacing: 6) {
            if isConfirmingAlways {
                Button {
                    isConfirmingAlways = false
                } label: {
                    Text("Cancel (Esc)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white.opacity(0.6))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color.white.opacity(0.1))
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .fixedSize(horizontal: true, vertical: false)

                Button {
                    DebugLog.shared.write("[notch] Confirm tapped")
                    isConfirmingAlways = false
                    onApproveAlways?()
                } label: {
                    Text("Confirm (C)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(Color(red: 0.92, green: 0.30, blue: 0.25))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color.white.opacity(0.9))
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .fixedSize(horizontal: true, vertical: false)
            } else {
                Button {
                    onReject()
                } label: {
                    Text("Deny (N)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white.opacity(0.6))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color.white.opacity(0.1))
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .fixedSize(horizontal: true, vertical: false)
                .opacity(showDenyButton ? 1 : 0)
                .scaleEffect(showDenyButton ? 1 : 0.8)

                Button {
                    onApprove()
                } label: {
                    Text("Allow (Y)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.black)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color.white.opacity(0.9))
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .fixedSize(horizontal: true, vertical: false)
                .opacity(showAllowButton ? 1 : 0)
                .scaleEffect(showAllowButton ? 1 : 0.8)

                if onApproveAlways != nil {
                    Button {
                        DebugLog.shared.write("[notch] Always tapped")
                        isConfirmingAlways = true
                    } label: {
                        Text("Always (A)")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(Color(red: 0.92, green: 0.30, blue: 0.25))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Color.white.opacity(0.9))
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .fixedSize(horizontal: true, vertical: false)
                    .opacity(showAlwaysButton ? 1 : 0)
                    .scaleEffect(showAlwaysButton ? 1 : 0.8)
                }
            }
        }
        .onAppear {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7).delay(0.0)) {
                showDenyButton = true
            }
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7).delay(0.05)) {
                showAllowButton = true
            }
            if onApproveAlways != nil {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.7).delay(0.1)) {
                    showAlwaysButton = true
                }
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
