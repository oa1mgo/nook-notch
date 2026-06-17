//
//  ChatView.swift
//  Nook
//
//  Redesigned chat interface with clean visual hierarchy
//

import AppKit
import Combine
import SwiftUI

struct ChatView: View {
    let sessionId: String
    let initialSession: SessionState
    let sessionMonitor: ClaudeSessionMonitor
    @ObservedObject var viewModel: NotchViewModel
    let primaryTextColor: Color
    let secondaryTextColor: Color

    @State private var inputText: String = ""
    @State private var history: [ChatHistoryItem] = []
    @State private var session: SessionState
    @State private var isLoading: Bool = true
    @State private var hasLoadedOnce: Bool = false
    @State private var shouldScrollToBottom: Bool = false
    @State private var isAutoscrollPaused: Bool = false
    @State private var newMessageCount: Int = 0
    @State private var previousHistoryCount: Int = 0
    @State private var isBottomVisible: Bool = true
    @State private var focusErrorMessage: String? = nil

    @FocusState private var isInputFocused: Bool

    init(
        sessionId: String,
        initialSession: SessionState,
        sessionMonitor: ClaudeSessionMonitor,
        viewModel: NotchViewModel,
        primaryTextColor: Color = .white,
        secondaryTextColor: Color = .white.opacity(0.4)
    ) {
        self.sessionId = sessionId
        self.initialSession = initialSession
        self.sessionMonitor = sessionMonitor
        self._viewModel = ObservedObject(wrappedValue: viewModel)
        self.primaryTextColor = primaryTextColor
        self.secondaryTextColor = secondaryTextColor
        self._session = State(initialValue: initialSession)

        // Codex sessions force an initial transcript sync below, but the
        // visible history still flows through ChatHistoryManager like other
        // providers.
        let cachedHistory: [ChatHistoryItem]
        let alreadyLoaded: Bool
        if initialSession.provider == .codex {
            cachedHistory = initialSession.chatItems
            alreadyLoaded = false
        } else {
            cachedHistory = ChatHistoryManager.shared.history(for: sessionId)
            alreadyLoaded = !cachedHistory.isEmpty
        }
        self._history = State(initialValue: cachedHistory)
        self._isLoading = State(initialValue: !alreadyLoaded)
        self._hasLoadedOnce = State(initialValue: alreadyLoaded)
    }

    /// Whether we're waiting for approval
    private var isWaitingForApproval: Bool {
        session.phase.isWaitingForApproval
    }

    /// Extract the tool name if waiting for approval
    private var approvalTool: String? {
        session.phase.approvalToolName
    }

    
    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                // Header
                chatHeader

                // Messages
                if isLoading && !isProcessing {
                    loadingState
                } else if history.isEmpty && !isProcessing {
                    emptyState
                } else {
                    messageList
                }

                // Bottom bar — provider-agnostic precedence:
                //   1. .waitingForInput  → opencode ask_user_question
                //   2. .waitingForApproval with AskUserQuestion → Claude's
                //      interactive tool prompt
                //   3. .waitingForApproval with any other tool → permission
                //      approve/deny bar
                //   4. else → regular input bar
                // Unifying cases 1 and 2 onto the same `interactivePromptBar`
                // so the user sees one consistent "click to focus the
                // terminal" UX across providers. The top banner that used
                // to live above the message list for opencode case 1 is
                // removed in favour of the bottom bar (which sits right
                // next to the input and is harder to miss).
                if session.phase == .waitingForInput || session.phase.isWaitingForTerminalApproval {
                    interactivePromptBar
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .move(edge: .bottom)),
                            removal: .opacity
                        ))
                } else if let tool = approvalTool {
                    if ToolCallItem.kind(of: tool) == .askUserQuestion {
                        interactivePromptBar
                            .transition(.asymmetric(
                                insertion: .opacity.combined(with: .move(edge: .bottom)),
                                removal: .opacity
                            ))
                    } else {
                        approvalBar(tool: tool)
                            .transition(.asymmetric(
                                insertion: .opacity.combined(with: .move(edge: .bottom)),
                                removal: .opacity
                            ))
                    }
                } else {
                    inputBar
                        .transition(.opacity)
                }
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: isWaitingForApproval)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: session.phase)
        .animation(nil, value: viewModel.status)
        .task {
            // Skip if already loaded (prevents redundant work on view recreation)
            guard !hasLoadedOnce else { return }
            hasLoadedOnce = true

            // Check if already loaded (from previous visit)
            let shouldForceReload = session.provider == .codex
            if !shouldForceReload && ChatHistoryManager.shared.isLoaded(sessionId: sessionId) {
                history = ChatHistoryManager.shared.history(for: sessionId)
                isLoading = false
                return
            }

            // Load in background, show loading state
            await ChatHistoryManager.shared.loadFromFile(
                sessionId: sessionId,
                cwd: session.cwd,
                force: shouldForceReload
            )
            history = ChatHistoryManager.shared.history(for: sessionId)

            withAnimation(.easeOut(duration: 0.2)) {
                isLoading = false
            }
        }
        .onReceive(ChatHistoryManager.shared.$histories) { histories in
            // Update when count changes, last item differs, or content changes (e.g., tool status)
            if let newHistory = histories[sessionId] {
                let countChanged = newHistory.count != history.count
                let lastItemChanged = newHistory.last?.id != history.last?.id
                // Always update - the @Published ensures we only get notified on real changes
                // This allows tool status updates (waitingForApproval -> running) to reflect
                if countChanged || lastItemChanged || newHistory != history {
                    // DIAGNOSTIC (#70): dump incoming history to find where second thinking is lost
                    let newThinkingCount = newHistory.filter { if case .thinking = $0.type { return true } else { return false } }.count
                    let newThinkingIds = newHistory.compactMap { item -> String? in
                        if case .thinking = item.type { return item.id } else { return nil }
                    }
                    DebugLog.shared.write("[chat-view] history update session=\(sessionId) total=\(newHistory.count) thinkingCount=\(newThinkingCount) thinkingIds=\(newThinkingIds.joined(separator: ","))")
                    // Track new messages when autoscroll is paused
                    if isAutoscrollPaused && newHistory.count > previousHistoryCount {
                        let addedCount = newHistory.count - previousHistoryCount
                        newMessageCount += addedCount
                        previousHistoryCount = newHistory.count
                    }

                    history = newHistory

                    // Auto-scroll to bottom only if autoscroll is NOT paused
                    if !isAutoscrollPaused && countChanged {
                        shouldScrollToBottom = true
                    }

                    // If we have data, skip loading state (handles view recreation)
                    if isLoading && !newHistory.isEmpty {
                        isLoading = false
                    }
                }
            } else if hasLoadedOnce {
                // Session was loaded but is now gone (removed via /clear) - navigate back
                viewModel.exitChat()
            }
        }
        .onReceive(sessionMonitor.$instances) { sessions in
            if let updated = sessions.first(where: { $0.sessionId == sessionId }),
               updated != session {
                // Check if permission was just accepted (transition from waitingForApproval to processing)
                let wasWaiting = isWaitingForApproval
                session = updated
                let isNowProcessing = updated.phase == .processing

                if wasWaiting && isNowProcessing {
                    // Scroll to bottom after permission accepted (with slight delay)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        shouldScrollToBottom = true
                    }
                }
            }
        }
        .onChange(of: canSendMessages) { _, canSend in
            // Auto-focus input when tmux messaging becomes available
            if canSend && !isInputFocused {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    isInputFocused = true
                }
            }
        }
        .onAppear {
            // Auto-focus input when chat opens and tmux messaging is available
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                if canSendMessages {
                    isInputFocused = true
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .chatScrollAction)) { notification in
            guard let direction = notification.object as? ChatScrollDirection else { return }
            performKeyboardScroll(direction)
        }
    }

    // MARK: - Header

    @State private var isHeaderHovered = false

    private var chatHeader: some View {
        Button {
            viewModel.exitChat()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(primaryTextColor.opacity(isHeaderHovered ? 1.0 : 0.72))
                    .frame(width: 24, height: 24)

                Text(session.displayTitle)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(primaryTextColor.opacity(isHeaderHovered ? 1.0 : 0.9))
                    .lineLimit(1)

                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isHeaderHovered ? Color.white.opacity(0.08) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHeaderHovered = $0 }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .zIndex(1) // Render above message list
    }

    /// Whether the session is currently processing
    private var isProcessing: Bool {
        session.phase == .processing || session.phase == .compacting
    }

    /// Get the last user message ID for stable text selection per turn
    private var lastUserMessageId: String {
        for item in history.reversed() {
            if case .user = item.type {
                return item.id
            }
        }
        return ""
    }

    private var chatInputPlaceholder: String {
        let name = session.provider.displayName
        if canSendMessages {
            return "Message to \(name)... (⏎ send · ⌃P/⌃N scroll · ⌃G bottom)"
        } else {
            return "Open \(name) in tmux to enable messaging"
        }
    }

    private var interactivePromptSubtitle: String {
        switch session.provider {
        case .claude:
            return "Claude Code needs your input"
        case .codex:
            return "Codex needs your input"
        case .opencode:
            return "OpenCode needs your input"
        }
    }

    // MARK: - Loading State

    private var loadingState: some View {
        VStack(spacing: 8) {
            ProgressView()
                .progressViewStyle(CircularProgressViewStyle(tint: secondaryTextColor))
                .scaleEffect(0.8)
            Text("Loading messages...")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(secondaryTextColor)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 24))
                .foregroundColor(secondaryTextColor.opacity(0.6))
            Text("No messages yet")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(secondaryTextColor)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Message List

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                // Spacing: 10pt between adjacent items. Previous 8pt was OK
                // for short tool lists but felt cramped once the opencode
                // sessions started interleaving thinking blocks and 3-5
                // tool calls in a row — runs of similar-looking tool rows
                // fused into a single dense block. 12-16pt felt too airy
                // (subagent tool lists developed visible "empty rows"
                // between every line). 10pt is a middle ground that gives
                // each tool row a clear top/bottom edge without breaking
                // runs apart.
                LazyVStack(spacing: 10) {
                    // Invisible anchor at bottom (first due to flip)
                    Color.clear
                        .frame(height: 1)
                        .id("bottom")

                    // Processing indicator at bottom (first due to flip)
                    if isProcessing {
                        SessionLoadingRow(provider: session.provider, turnId: lastUserMessageId)
                            .padding(.horizontal, 16)
                            .scaleEffect(x: 1, y: -1)
                            .transition(.asymmetric(
                                insertion: .opacity.combined(with: .scale(scale: 0.95)).combined(with: .offset(y: -4)),
                                removal: .opacity
                            ))
                    }

                    ForEach(history.reversed()) { item in
                        MessageItemView(
                            item: item,
                            sessionId: sessionId,
                            primaryTextColor: primaryTextColor,
                            secondaryTextColor: secondaryTextColor
                        )
                            .padding(.horizontal, 16)
                            .scaleEffect(x: 1, y: -1)
                            .transition(.asymmetric(
                                insertion: .opacity.combined(with: .scale(scale: 0.98)),
                                removal: .opacity
                            ))
                    }
                }
                .padding(.top, 20)
                .padding(.bottom, 20)
                .animation(.spring(response: 0.3, dampingFraction: 0.8), value: isProcessing)
                .animation(.spring(response: 0.3, dampingFraction: 0.8), value: history.count)
            }
            .scaleEffect(x: 1, y: -1)
            .onScrollGeometryChange(for: Bool.self) { geometry in
                // Check if we're near the top of the content (which is bottom in inverted view)
                // contentOffset.y near 0 means at bottom, larger means scrolled up
                geometry.contentOffset.y < 50
            } action: { wasAtBottom, isNowAtBottom in
                if wasAtBottom && !isNowAtBottom {
                    // User scrolled away from bottom
                    pauseAutoscroll()
                } else if !wasAtBottom && isNowAtBottom && isAutoscrollPaused {
                    // User scrolled back to bottom
                    resumeAutoscroll()
                }
            }
            .onChange(of: shouldScrollToBottom) { _, shouldScroll in
                if shouldScroll {
                    withAnimation(.easeOut(duration: 0.3)) {
                        // In inverted scroll, use .bottom anchor to scroll to the visual bottom
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                    shouldScrollToBottom = false
                    resumeAutoscroll()
                }
            }
            // New messages indicator overlay
            .overlay(alignment: .bottom) {
                if isAutoscrollPaused && newMessageCount > 0 {
                    NewMessagesIndicator(count: newMessageCount) {
                        withAnimation(.easeOut(duration: 0.3)) {
                            // In inverted scroll, use .bottom anchor to scroll to the visual bottom
                            proxy.scrollTo("bottom", anchor: .bottom)
                        }
                        resumeAutoscroll()
                    }
                    .padding(.bottom, 16)
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .move(edge: .bottom)),
                        removal: .opacity
                    ))
                }
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: isAutoscrollPaused && newMessageCount > 0)
        }
    }

    // MARK: - Input Bar

    /// Can send messages only if session is in tmux
    private var canSendMessages: Bool {
        session.isInTmux && session.tty != nil
    }

    private var inputBar: some View {
        HStack(spacing: 10) {
            TextField(chatInputPlaceholder, text: $inputText)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundColor(canSendMessages ? primaryTextColor : secondaryTextColor)
                .focused($isInputFocused)
                .disabled(!canSendMessages)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 20)
                        .fill(Color.white.opacity(canSendMessages ? 0.08 : 0.04))
                        .overlay(
                            RoundedRectangle(cornerRadius: 20)
                                .strokeBorder(Color.white.opacity(0.1), lineWidth: 1)
                        )
                )
                .onSubmit {
                    sendMessage()
                }

            Button {
                sendMessage()
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 28))
                    .foregroundColor(!canSendMessages || inputText.isEmpty ? secondaryTextColor.opacity(0.55) : primaryTextColor.opacity(0.94))
            }
            .buttonStyle(.plain)
            .disabled(!canSendMessages || inputText.isEmpty)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .zIndex(1) // Render above message list
    }

    // MARK: - Approval Bar

    private func approvalBar(tool: String) -> some View {
        ChatApprovalBar(
            tool: tool,
            toolInput: session.pendingToolInput,
            primaryTextColor: primaryTextColor,
            secondaryTextColor: secondaryTextColor,
            onApprove: { approvePermission() },
            onDeny: { denyPermission() }
        )
    }

    // MARK: - Interactive Prompt Bar

    /// Bar for interactive tools like AskUserQuestion that need terminal input
    private var interactivePromptBar: some View {
        ChatInteractivePromptBar(
            provider: session.provider,
            isInTmux: session.isInTmux,
            canFocusTerminal: session.isInTmux || session.pid != nil,
            primaryTextColor: primaryTextColor,
            secondaryTextColor: secondaryTextColor,
            onGoToTerminal: { focusTerminal() },
            focusErrorMessage: focusErrorMessage
        )
    }

    // MARK: - Autoscroll Management

    /// Pause autoscroll (user scrolled away from bottom)
    private func pauseAutoscroll() {
        isAutoscrollPaused = true
        previousHistoryCount = history.count
    }

    /// Resume autoscroll and reset new message count
    private func resumeAutoscroll() {
        isAutoscrollPaused = false
        newMessageCount = 0
        previousHistoryCount = history.count
    }

    // MARK: - Actions

    private func focusTerminal() {
        // Clear any previous error message before retrying
        focusErrorMessage = nil

        Task {
            DebugLog.shared.write("[focus] called session.isInTmux=\(session.isInTmux) session.pid=\(session.pid ?? -1) provider=\(session.provider)")

            // Try each focus method in order; stop at the first success.
            // Order: tmux (yabai) → non-tmux process tree → last-resort bundle ID.
            let focusSucceeded = await tryFocusTerminal()

            if focusSucceeded {
                // Only close the notch AFTER we know the terminal has
                // accepted focus. Closing on a failed focus leaves the
                // user looking at nothing — they can't see the question
                // prompt and they don't know why.
                DebugLog.shared.write("[focus] success, closing notch and restoring focus")
                viewModel.notchClose()
            } else {
                // All focus methods failed. Keep the notch open so the
                // user can still see the question and try again (or use
                // the fallback hint to start a tmux session). Set a
                // visible error message that gets cleared on next click.
                DebugLog.shared.write("[focus] all methods failed, keeping notch open")
                focusErrorMessage = "无法聚焦终端。请手动切换窗口（session.pid 缺失或终端 app 不在已知列表）"
            }
        }
    }

    /// Try every terminal focus method in order; return true on first success.
    /// Order: tmux (yabai) → non-tmux process tree → last-resort bundle ID.
    private func tryFocusTerminal() async -> Bool {
        // tmux path (Claude's default): the Yabai controller walks
        // `client_pid → terminal` via tmux's own `list-clients` and
        // focuses the right pane. Skipped silently if yabai isn't
        // installed.
        if session.isInTmux, let pid = session.pid {
            if await YabaiController.shared.focusWindow(forClaudePid: pid) {
                DebugLog.shared.write("[focus] tmux focusWindow(forClaudePid) succeeded")
                return true
            }
            DebugLog.shared.write("[focus] tmux focusWindow(forClaudePid) failed, trying forWorkingDirectory")
            if await YabaiController.shared.focusWindow(forWorkingDirectory: session.cwd) {
                DebugLog.shared.write("[focus] tmux focusWindow(forWorkingDirectory) succeeded")
                return true
            }
            DebugLog.shared.write("[focus] tmux path failed, falling through to non-tmux fallback")
            // Fall through to non-tmux fallback — yabai may not be
            // installed or the tmux lookup may have failed.
        }
        // Non-tmux fallback (e.g. opencode running directly in Ghostty).
        // Yabai focuses whole windows by PID; for a non-tmux shell we
        // don't have a window handle, only the shell's PID. Walk the
        // process tree up to the terminal app's PID and activate it
        // via NSWorkspace — `activate(ignoringOtherApps:)` brings the
        // terminal to the front so the user can interact with the
        // opencode question popup.
        if let pid = session.pid {
            if await focusTerminalApp(forChildPid: Int(pid)) {
                DebugLog.shared.write("[focus] non-tmux focusTerminalApp succeeded")
                return true
            }
            DebugLog.shared.write("[focus] non-tmux focusTerminalApp failed: could not find terminal app for pid=\(pid)")
            // Last resort: try activating any known terminal app
            // by bundle ID. Works when the process tree walk fails
            // (e.g. Ghostty launched via launchd, PID namespace quirks).
            let terminalBundleIds = ["com.mitchellh.ghostty", "com.googlecode.iterm2", "com.apple.Terminal"]
            for bundleId in terminalBundleIds {
                if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first {
                    let ok = app.activate()
                    DebugLog.shared.write("[focus] last-resort activate bundleId=\(bundleId) success=\(ok)")
                    if ok { return true }
                }
            }
            DebugLog.shared.write("[focus] all focus methods failed")
        } else {
            DebugLog.shared.write("[focus] session.pid is nil, cannot focus terminal")
        }
        return false
    }

    /// Walk up the process tree from `childPid` until we hit a known
    /// terminal app process, then activate that app. Returns true if a
    /// terminal app was found and activated.
    private func focusTerminalApp(forChildPid childPid: Int) async -> Bool {
        let tree = ProcessTreeBuilder.shared.buildTree()
        guard let terminalPid = ProcessTreeBuilder.shared.findTerminalPid(
            forProcess: childPid, tree: tree
        ) else {
            return false
        }
        // NSRunningApplication is the only API that gives us `activate`
        // and survives app-sandbox quirks for already-running processes.
        // `processIdentifier` matches the PID we just looked up. Note:
        // `.activateIgnoringOtherApps` is deprecated in macOS 14 (no-op),
        // so we call `activate()` plain — on macOS 14+ that's enough to
        // surface the terminal window.
        guard let app = NSRunningApplication(processIdentifier: pid_t(terminalPid)),
              let bundleId = app.bundleIdentifier,
              TerminalAppRegistry.isTerminalBundle(bundleId) else {
            // Process found but isn't a known terminal app (e.g. parent
            // is `login` or some other intermediary). Fall through.
            return false
        }
        let activated = app.activate()
        DebugLog.shared.write("[focus] activated terminal app pid=\(terminalPid) bundleId=\(bundleId) success=\(activated)")
        return activated
    }

    private func approvePermission() {
        sessionMonitor.approvePermission(sessionId: sessionId)
    }

    private func denyPermission() {
        sessionMonitor.denyPermission(sessionId: sessionId, reason: nil)
    }

    private func performKeyboardScroll(_ direction: ChatScrollDirection) {
        guard let sv = findScrollView(in: NSApp.keyWindow?.contentView) else {
            let lines: Int32 = direction == .up ? 3 : -3
            if let event = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: lines, wheel2: 0, wheel3: 0) {
                event.post(tap: .cghidEventTap)
            }
            return
        }
        switch direction {
        case .bottom:
            let targetY: CGFloat = 0
            if abs(sv.contentView.bounds.origin.y - targetY) > 1 {
                sv.contentView.animator().setBoundsOrigin(NSPoint(x: 0, y: targetY))
            }
            resumeAutoscroll()
        case .up, .down:
            let lineHeight: CGFloat = 120
            let newY = direction == .up
                ? sv.contentView.bounds.origin.y + lineHeight
                : sv.contentView.bounds.origin.y - lineHeight
            let maxY = max(0, (sv.documentView?.bounds.height ?? 0) - sv.contentView.bounds.height)
            sv.contentView.animator().setBoundsOrigin(NSPoint(x: 0, y: min(max(0, newY), maxY)))
        }
    }

    /// Recursively find the first NSScrollView in a view hierarchy.
    private func findScrollView(in view: NSView?) -> NSScrollView? {
        guard let view = view else { return nil }
        if let sv = view as? NSScrollView { return sv }
        for subview in view.subviews {
            if let found = findScrollView(in: subview) { return found }
        }
        return nil
    }

    private func sendMessage() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        inputText = ""

        // Resume autoscroll when user sends a message
        resumeAutoscroll()
        shouldScrollToBottom = true

        // Don't add to history here - it will be synced from JSONL when UserPromptSubmit event fires
        Task {
            await sendToSession(text)
        }
    }

    private func sendToSession(_ text: String) async {
        guard session.isInTmux else { return }
        guard let tty = session.tty else { return }

        if let target = await findTmuxTarget(tty: tty) {
            _ = await ToolApprovalHandler.shared.sendMessage(text, to: target)
        }
    }

    private func findTmuxTarget(tty: String) async -> TmuxTarget? {
        guard let tmuxPath = await TmuxPathFinder.shared.getTmuxPath() else {
            return nil
        }

        do {
            let output = try await ProcessExecutor.shared.run(
                tmuxPath,
                arguments: ["list-panes", "-a", "-F", "#{session_name}:#{window_index}.#{pane_index} #{pane_tty}"]
            )

            let lines = output.components(separatedBy: "\n")
            for line in lines {
                let parts = line.components(separatedBy: " ")
                guard parts.count >= 2 else { continue }

                let target = parts[0]
                let paneTty = parts[1].replacingOccurrences(of: "/dev/", with: "")

                if paneTty == tty {
                    return TmuxTarget(from: target)
                }
            }
        } catch {
            return nil
        }

        return nil
    }
}

// MARK: - Message Item View

struct MessageItemView: View {
    let item: ChatHistoryItem
    let sessionId: String
    let primaryTextColor: Color
    let secondaryTextColor: Color

    var body: some View {
        switch item.type {
        case .user(let text):
            UserMessageView(text: text, primaryTextColor: primaryTextColor, secondaryTextColor: secondaryTextColor)
        case .assistant(let text):
            AssistantMessageView(text: text, primaryTextColor: primaryTextColor, secondaryTextColor: secondaryTextColor)
        case .toolCall(let tool):
            ToolCallView(tool: tool, sessionId: sessionId, primaryTextColor: primaryTextColor, secondaryTextColor: secondaryTextColor)
        case .thinking(let text):
            ThinkingView(text: text, secondaryTextColor: secondaryTextColor)
        case .image(let block):
            ImageMessageView(image: block, secondaryTextColor: secondaryTextColor)
        case .interrupted:
            InterruptedMessageView()
        }
    }
}

// MARK: - Image Message

struct ImageMessageView: View {
    let image: ImageBlock
    let secondaryTextColor: Color

    /// Decoded image cached so base64 isn't re-decoded on every render.
    /// Large inline images (tens of KB) would otherwise thrash during
    /// scrolling or parent re-renders.
    @State private var decoded: NSImage?

    var body: some View {
        HStack {
            Spacer(minLength: 60)

            if let decoded {
                Image(nsImage: decoded)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: 280, maxHeight: 280)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.white.opacity(0.1), lineWidth: 1)
                    )
            } else {
                // Decode failed — show a labelled placeholder rather than silently dropping
                HStack(spacing: 6) {
                    Image(systemName: "photo")
                        .font(.system(size: 12))
                    Text("Image (\(image.mediaType))")
                        .font(.system(size: 12))
                }
                .foregroundColor(secondaryTextColor)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(secondaryTextColor.opacity(0.12))
                )
            }
        }
        .task(id: image.id) {
            // Decode off the main thread so large images don't hitch scrolling.
            let b64 = image.base64Data
            let decoded = await Task.detached(priority: .userInitiated) {
                guard let data = Data(base64Encoded: b64) else { return nil as NSImage? }
                return NSImage(data: data)
            }.value
            self.decoded = decoded
        }
    }
}

// MARK: - User Message

struct UserMessageView: View {
    let text: String
    let primaryTextColor: Color
    let secondaryTextColor: Color

    var body: some View {
        HStack {
            Spacer(minLength: 60)

            MarkdownText(text, color: primaryTextColor, fontSize: 13)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 18)
                        .fill(secondaryTextColor.opacity(0.22))
                )
        }
    }
}

// MARK: - Assistant Message

struct AssistantMessageView: View {
    let text: String
    let primaryTextColor: Color
    let secondaryTextColor: Color

    var body: some View {
        // Skip rendering when text is empty — otherwise the dot indicator
        // shows up alone (orphan dot) for tool-only assistant turns.
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            EmptyView()
        } else {
            HStack(alignment: .top, spacing: 6) {
                Circle()
                    .fill(secondaryTextColor.opacity(0.9))
                    .frame(width: 6, height: 6)
                    .padding(.top, 5)

                MarkdownText(text, color: primaryTextColor.opacity(0.94), fontSize: 13)

                Spacer(minLength: 60)
            }
        }
    }
}

// MARK: - Tool Call View

struct ToolCallView: View {
    let tool: ToolCallItem
    let sessionId: String
    let primaryTextColor: Color
    let secondaryTextColor: Color

    @State private var pulseOpacity: Double = 0.6
    @State private var isExpanded: Bool = false
    @State private var isHovering: Bool = false

    private var statusColor: Color {
        switch tool.status {
        case .running:
            return primaryTextColor
        case .waitingForApproval:
            return Color.orange
        case .success:
            return Color.green
        case .error, .interrupted:
            return Color.red
        }
    }

    private var textColor: Color {
        switch tool.status {
        case .running:
            return secondaryTextColor
        case .waitingForApproval:
            return Color.orange.opacity(0.9)
        case .success:
            return primaryTextColor.opacity(0.78)
        case .error, .interrupted:
            return Color.red.opacity(0.8)
        }
    }

    private var hasResult: Bool {
        // AskUserQuestion: options are static content (parsed from tool
        // input), so the item always has renderable content regardless of
        // whether structuredResult is populated. This matters for OpenCode's
        // hook path which doesn't set structuredResult until the tool
        // completes — the user should still see options while waiting.
        if tool.kind == .askUserQuestion { return true }

        let hasNonEmptyResult = tool.result.map { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? false
        return hasNonEmptyResult || tool.structuredResult != nil
    }

    /// Whether the tool can be expanded. Two cases:
    ///   1. Subagent container with at least one subagent tool → chevron
    ///      toggles the SubagentToolsList (visibility is also auto-shown
    ///      while running so the user sees live activity).
    ///   2. Anything else with a result AND not Edit → chevron toggles
    ///      ToolResultContent (Edit always shows its diff via showContent).
    /// Uses provider-agnostic kind — opencode emits "edit" lowercase while
    /// Claude emits "Edit" PascalCase.
    private var canExpand: Bool {
        if tool.isSubagentContainer { return !tool.subagentTools.isEmpty }
        return tool.kind != .edit && hasResult
    }

    private var showContent: Bool {
        tool.kind == .edit || isExpanded
    }

    private var agentDescription: String? {
        guard tool.kind == .agentOutputTool,
              let agentId = tool.input["agentId"],
              let sessionDescriptions = ChatHistoryManager.shared.agentDescriptions[sessionId] else {
            return nil
        }
        return sessionDescriptions[agentId]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle()
                    .fill(statusColor.opacity(tool.status == .running || tool.status == .waitingForApproval ? pulseOpacity : 0.6))
                    .frame(width: 6, height: 6)
                    .id(tool.status)  // Forces view recreation, cancelling repeatForever animation
                    .onAppear {
                        if tool.status == .running || tool.status == .waitingForApproval {
                            startPulsing()
                        }
                    }

                // Tool name (formatted for MCP tools)
                Text(MCPToolFormatter.formatToolName(tool.name))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(textColor)
                    .fixedSize()

                if tool.isSubagentContainer {
                    if !tool.subagentTools.isEmpty {
                        let taskDesc = tool.input["description"] ?? "Running agent..."
                        Text("\(taskDesc) (\(tool.subagentTools.count) tools)")
                            .font(.system(size: 11))
                            .foregroundColor(textColor.opacity(0.7))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    } else if let desc = tool.input["description"] {
                        Text(desc)
                            .font(.system(size: 11))
                            .foregroundColor(textColor.opacity(0.7))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                } else if tool.kind == .agentOutputTool, let desc = agentDescription {
                    let blocking = tool.input["block"] == "true"
                    Text(blocking ? "Waiting: \(desc)" : desc)
                        .font(.system(size: 11))
                        .foregroundColor(textColor.opacity(0.7))
                        .lineLimit(1)
                        .truncationMode(.tail)
                } else if MCPToolFormatter.isMCPTool(tool.name) && !tool.input.isEmpty {
                    Text(MCPToolFormatter.formatArgs(tool.input))
                        .font(.system(size: 11))
                        .foregroundColor(textColor.opacity(0.7))
                        .lineLimit(1)
                        .truncationMode(.tail)
                } else if tool.kind == .bash {
                    // Bash tools surface the actual command (or summary, for
                    // subagent-emitted ones) on the same row as the status.
                    // Without this the row is just "bash Completed" / "bash
                    // Interrupted" — visually a blank line, and the user
                    // can't tell which command each row refers to. The
                    // status (running / success / interrupted) is already
                    // encoded by the dot color, so we always show the cmd.
                    //
                    // Routes via provider-agnostic `kind` — opencode emits
                    // toolName "bash" (lowercase) while Claude emits
                    // "Bash" (PascalCase); see `ToolCallItem.kind`.
                    let rawCommand = tool.input["command"]
                        ?? tool.input["summary"]
                        ?? tool.input["description"]
                    if let cmd = rawCommand?.trimmingCharacters(in: .whitespacesAndNewlines),
                       !cmd.isEmpty {
                        let firstLine = cmd.components(separatedBy: "\n").first ?? cmd
                        Text(String(firstLine.prefix(120)))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(textColor.opacity(0.7))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    } else {
                        Text(tool.statusDisplay.text)
                            .font(.system(size: 11))
                            .foregroundColor(textColor.opacity(0.7))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                } else if tool.kind == .read {
                    // Read tools: opencode's postTool does not carry the
                    // structured result back (see OpencodeChatItemAdapter
                    // .postTool handling), so
                    // `statusDisplay.text` falls back to a literal
                    // "Completed" with no filename and no line count.
                    // The result collapses to a one-line row that is much
                    // shorter than the surrounding bash rows, which made
                    // the area after a long bash sequence look like a
                    // blank/inconsistent-height block. Render the input
                    // file path the same way bash renders its command so
                    // heights align.
                    //
                    // Path lookup order: `file_path` (Claude) → `path`
                    // (some adapters) → `command` (opencode: the
                    // OpencodeHookAdapter's `buildInputSummary` returns
                    // the file path for read tools, and SessionStore
                    // stores it under the "command" key for all
                    // non-task tools).
                    let rawPath = tool.input["file_path"]
                        ?? tool.input["path"]
                        ?? tool.input["command"]
                    if let path = rawPath?.trimmingCharacters(in: .whitespacesAndNewlines),
                       !path.isEmpty {
                        Text(URL(fileURLWithPath: path).lastPathComponent)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(textColor.opacity(0.7))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    } else {
                        Text(tool.statusDisplay.text)
                            .font(.system(size: 11))
                            .foregroundColor(textColor.opacity(0.7))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                } else if tool.kind == .grep {
                    // Grep tools: like read, opencode's postTool doesn't
                    // carry a structured result, so statusDisplay.text
                    // would render as a bare "Completed" — visually a
                    // blank-ish row that breaks the rhythm of the
                    // surrounding bash/read lines. Surface the pattern
                    // (or command fallback for opencode) so the user
                    // can tell which search the row refers to.
                    //
                    // Lookup order: `pattern` (Claude) → `path` (the
                    // search root, secondary signal) → `command`
                    // (opencode: buildInputSummary returns the pattern
                    // for grep tools, and SessionStore stores it under
                    // the "command" key for all non-task tools).
                    let rawPattern = tool.input["pattern"]
                        ?? tool.input["command"]
                    if let pattern = rawPattern?.trimmingCharacters(in: .whitespacesAndNewlines),
                       !pattern.isEmpty {
                        Text("grep: \(String(pattern.prefix(80)))")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(textColor.opacity(0.7))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    } else if let path = tool.input["path"]?.trimmingCharacters(in: .whitespacesAndNewlines),
                              !path.isEmpty {
                        Text(URL(fileURLWithPath: path).lastPathComponent)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(textColor.opacity(0.7))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    } else {
                        Text(tool.statusDisplay.text)
                            .font(.system(size: 11))
                            .foregroundColor(textColor.opacity(0.7))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                } else {
                    // Defensive fallback for any tool that doesn't have an
                    // explicit branch above (glob, webFetch, webSearch,
                    // write, edit, askUserQuestion, plan-mode, todoWrite,
                    // killShell, bashOutput, agentOutputTool without a
                    // description, unknown MCP tools, etc.). Without this
                    // those tools would render as a bare "Completed" /
                    // "Interrupted" — visually a blank one-line row that
                    // breaks the height rhythm of the surrounding
                    // messages and creates the "large blank area"
                    // impression users reported.
                    //
                    // `inputPreview` already does a provider-agnostic
                    // best-effort extraction (file_path → command →
                    // pattern → query → url → first value), so even
                    // unrecognised tools get a useful label here. Only
                    // fall through to statusDisplay when preview is
                    // empty (e.g. a task with no description and no
                    // other input).
                    let preview = tool.inputPreview
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !preview.isEmpty {
                        Text(preview)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(textColor.opacity(0.7))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    } else {
                        Text(tool.statusDisplay.text)
                            .font(.system(size: 11))
                            .foregroundColor(textColor.opacity(0.7))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }

                Spacer()

                // Expand indicator (only for expandable tools).
                // AskUserQuestion options are static (parsed from input),
                // so always allow expanding regardless of status. Other
                // tools hide the chevron while running/waitingForApproval
                // because their result content isn't available yet.
                let isAskQuestion = tool.kind == .askUserQuestion
                if canExpand && (isAskQuestion || (tool.status != .running && tool.status != .waitingForApproval)) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(secondaryTextColor.opacity(0.8))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: isExpanded)
                }
            }

            // Subagent tools list (for Task/Agent tools).
            // Shows during execution regardless of expansion; after completion,
            // visibility follows isExpanded so the user can collapse to save space.
            if tool.isSubagentContainer && !tool.subagentTools.isEmpty && (isExpanded || tool.status == .running) {
                SubagentToolsList(tools: tool.subagentTools, primaryTextColor: primaryTextColor, secondaryTextColor: secondaryTextColor)
                    .padding(.leading, 12)
                    .padding(.top, 2)
            }

            // Result content (Edit always shows, others when expanded)
            // Edit tools bypass hasResult check - fallback in ToolResultContent renders from input params
            // Subagent containers (task/Agent) are allowed to show their
            // TaskResultContent when expanded, but should NOT show raw
            // text output (which is the agent's final message — already
            // visible in the subagent tools list).
            let isSubagentWithResult = tool.isSubagentContainer && tool.structuredResult != nil
            // AskUserQuestion content (options) is static — allow showing
            // even while the tool is still running/waiting for answer.
            let isAskQuestion = tool.kind == .askUserQuestion
            if showContent && (isAskQuestion || tool.status != .running) && (!tool.isSubagentContainer || isSubagentWithResult) && (hasResult || tool.kind == .edit) {
                ToolResultContent(tool: tool)
                    .padding(.leading, 12)
                    .padding(.top, 4)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            // Edit tools show diff from input even while running
            if tool.kind == .edit && tool.status == .running {
                EditInputDiffView(input: tool.input)
                    .padding(.leading, 12)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(canExpand && isHovering ? secondaryTextColor.opacity(0.12) : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovering = hovering
        }
        .onTapGesture {
            if canExpand {
                withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                    isExpanded.toggle()
                }
            }
        }
        .animation(.easeOut(duration: 0.15), value: isHovering)
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: isExpanded)
    }

    private func startPulsing() {
        withAnimation(
            .easeInOut(duration: 0.6)
            .repeatForever(autoreverses: true)
        ) {
            pulseOpacity = 0.15
        }
    }
}

// MARK: - Subagent Views

/// List of subagent tools (shown during Task execution)
struct SubagentToolsList: View {
    let tools: [SubagentToolCall]
    let primaryTextColor: Color
    let secondaryTextColor: Color

    /// Collapse threshold — show all tools if count is at or below this,
    /// otherwise show only the most recent and offer a tap-to-expand.
    /// Previously the list always showed only the last 2 with a
    /// "+N more tool uses" hint and no way to actually see the rest, which
    /// left the user with a "can't expand" impression (see #74). Showing
    /// all tools up to the threshold avoids the implicit two-tier cut and
    /// makes the "task ran 8 grep calls" outcome actually visible.
    private let collapseThreshold = 6

    /// Whether the list is currently expanded (only meaningful when
    /// tools.count > collapseThreshold).
    @State private var isExpanded: Bool = false

    private var visibleTools: [SubagentToolCall] {
        if isExpanded || tools.count <= collapseThreshold {
            return tools
        }
        return Array(tools.suffix(2))
    }

    private var hiddenCount: Int {
        max(0, tools.count - visibleTools.count)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            // Show count of hidden tools at top with a tap-to-expand affordance.
            // When nothing is hidden this branch is skipped entirely.
            if hiddenCount > 0 {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 8, weight: .medium))
                        Text(isExpanded
                             ? "Hide \(hiddenCount) older tool uses"
                             : "Show all \(tools.count) tool uses")
                            .font(.system(size: 10))
                    }
                    .foregroundColor(secondaryTextColor)
                }
                .buttonStyle(.plain)
            }

            ForEach(visibleTools) { tool in
                SubagentToolRow(tool: tool, primaryTextColor: primaryTextColor, secondaryTextColor: secondaryTextColor)
            }
        }
    }
}

/// Single subagent tool row
struct SubagentToolRow: View {
    let tool: SubagentToolCall
    let primaryTextColor: Color
    let secondaryTextColor: Color

    @State private var dotOpacity: Double = 0.5

    private var statusColor: Color {
        switch tool.status {
        case .running, .waitingForApproval: return .orange
        case .success: return .green
        case .error, .interrupted: return .red
        }
    }

    /// Get status text using the same logic as regular tools
    private var statusText: String {
        if tool.status == .interrupted {
            return "Interrupted"
        } else if tool.status == .running {
            return ToolStatusDisplay.running(for: tool.name, input: tool.input).text
        } else {
            // For completed subagent tools, we don't have the result data
            // so use a simple display based on tool name and input
            return ToolStatusDisplay.running(for: tool.name, input: tool.input).text
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            // Status dot
            Circle()
                .fill(statusColor.opacity(tool.status == .running ? dotOpacity : 0.6))
                .frame(width: 4, height: 4)
                .id(tool.status)  // Forces view recreation, cancelling repeatForever animation
                .onAppear {
                    if tool.status == .running {
                        withAnimation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true)) {
                            dotOpacity = 0.2
                        }
                    }
                }

            // Tool name
            Text(tool.name)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(primaryTextColor.opacity(0.7))

            // Status text (same format as regular tools)
            Text(statusText)
                .font(.system(size: 10))
                .foregroundColor(secondaryTextColor)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}

/// Summary of subagent tools (shown when Task is expanded after completion)
struct SubagentToolsSummary: View {
    let tools: [SubagentToolCall]
    let primaryTextColor: Color
    let secondaryTextColor: Color

    private var toolCounts: [(String, Int)] {
        var counts: [String: Int] = [:]
        for tool in tools {
            counts[tool.name, default: 0] += 1
        }
        return counts.sorted { $0.value > $1.value }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Subagent used \(tools.count) tools:")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(secondaryTextColor)

            HStack(spacing: 8) {
                ForEach(toolCounts.prefix(5), id: \.0) { name, count in
                    HStack(spacing: 2) {
                        Text(name)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(primaryTextColor.opacity(0.68))
                        Text("×\(count)")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundColor(secondaryTextColor.opacity(0.85))
                    }
                }
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(secondaryTextColor.opacity(0.08))
        )
    }
}

// MARK: - Thinking View

struct ThinkingView: View {
    let text: String
    let secondaryTextColor: Color

    @State private var isExpanded = false

    private var canExpand: Bool {
        text.count > 80
    }

    var body: some View {
        // Skip rendering when text is empty — streaming thinking blocks can
        // briefly arrive empty, which otherwise leaves an orphan grey dot.
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            EmptyView()
        } else {
            HStack(alignment: .top, spacing: 6) {
                Circle()
                    .fill(Color.gray.opacity(0.5))
                    .frame(width: 6, height: 6)
                    .padding(.top, 4)

                let displayText = isExpanded
                    ? text
                    : text.trimmingCharacters(in: .whitespacesAndNewlines)
                Text(isExpanded
                     ? displayText
                     : String(displayText.prefix(80)) + (canExpand ? "..." : ""))
                    .font(.system(size: 11))
                    .foregroundColor(secondaryTextColor)
                    .italic()
                    .lineLimit(isExpanded ? nil : 1)
                    .multilineTextAlignment(.leading)

                Spacer()

                if canExpand {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(secondaryTextColor.opacity(0.8))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .padding(.top, 3)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                if canExpand {
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                        isExpanded.toggle()
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // No extra vertical padding: when collapsed the HStack is a
            // single short line, and the 10pt LazyVStack spacing already
            // gives the row enough breathing room. Adding 2pt here made
            // the gap between a collapsed thinking and the next tool row
            // feel larger than the gap between two tool rows.
        }
    }
}

// MARK: - Interrupted Message

struct InterruptedMessageView: View {
    var body: some View {
        HStack {
            Text("Interrupted")
                .font(.system(size: 13))
                .foregroundColor(.red)
            Spacer()
        }
    }
}

// MARK: - Chat Interactive Prompt Bar

/// Bar for interactive tools like AskUserQuestion that need terminal input
struct ChatInteractivePromptBar: View {
    let provider: SessionProvider
    let isInTmux: Bool
    /// True when the Terminal button click can do something useful.
    /// Tighter than `isInTmux` alone — also true for non-tmux sessions
    /// where we have a `session.pid` we can walk up to a terminal app
    /// (opencode running directly in Ghostty, etc.). Drives both the
    /// button action and the visual style — we don't want the button
    /// to look clickable but do nothing, or unclickable but do something.
    let canFocusTerminal: Bool
    let primaryTextColor: Color
    let secondaryTextColor: Color
    let onGoToTerminal: () -> Void
    /// Error message shown when Terminal focus failed on the last click.
    /// Cleared on next click. nil = no error.
    let focusErrorMessage: String?

    @State private var showContent = false
    @State private var showButton = false

    var body: some View {
        HStack(spacing: 12) {
            // Tool info - same style as approval bar
            VStack(alignment: .leading, spacing: 2) {
                Text(MCPToolFormatter.formatToolName("AskUserQuestion"))
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundColor(TerminalColors.amber)
                Text(providerSubtitle)
                    .font(.system(size: 11))
                    .foregroundColor(secondaryTextColor)
                    .lineLimit(1)
                if !canFocusTerminal {
                    Text(hintSubtitle)
                        .font(.system(size: 10))
                        .foregroundColor(secondaryTextColor.opacity(0.7))
                        .lineLimit(1)
                }
                if let error = focusErrorMessage {
                    // Show the most recent focus failure in red. Cleared
                    // on next click (parent sets focusErrorMessage = nil
                    // at the start of focusTerminal). Shown ABOVE the
                    // button so the user can see why the click did nothing.
                    Text(error)
                        .font(.system(size: 10))
                        .foregroundColor(.red.opacity(0.9))
                        .lineLimit(2)
                }
            }
            .opacity(showContent ? 1 : 0)
            .offset(x: showContent ? 0 : -10)

            Spacer()

            // Terminal button on right (similar to Allow button).
            //
            // Visual style and click both follow `canFocusTerminal` rather
            // than `isInTmux` alone — non-tmux sessions can still have the
            // click do something useful (focus the terminal app via
            // NSWorkspace) and we don't want the button to look broken when
            // the user IS in a session we can focus.
            //
            // When `canFocusTerminal` is false, the button is still rendered
            // (for layout consistency with the in-tmux path) but clicking
            // is a no-op and a `.help()` tooltip explains the workaround
            // (start the agent inside tmux). The `interactivePromptSubtitle`
            // on the left also gains a hint line in that case so the user
            // sees the explanation without having to hover.
            Button {
                if canFocusTerminal {
                    onGoToTerminal()
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "terminal")
                        .font(.system(size: 11, weight: .medium))
                    Text("Terminal")
                        .font(.system(size: 13, weight: .medium))
                }
                .foregroundColor(canFocusTerminal ? Color.white : secondaryTextColor)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                // Use a fixed dark background regardless of theme — adaptive
                // background mode sets `primaryTextColor` to a dark color
                // (e.g. black on light theme), which would make the button
                // invisible with the previous black-on-primaryTextColor scheme.
                .background(canFocusTerminal ? Color.black.opacity(0.85) : secondaryTextColor.opacity(0.16))
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .help(canFocusTerminal
                  ? "Focus the terminal window running \(providerName)"
                  : "Start \(providerName) inside tmux to focus the terminal from here")
            .opacity(showButton ? 1 : 0)
            .scaleEffect(showButton ? 1 : 0.8)
        }
        .frame(minHeight: 44)  // Consistent height with other bars
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .onAppear {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7).delay(0.05)) {
                showContent = true
            }
            withAnimation(.spring(response: 0.35, dampingFraction: 0.7).delay(0.1)) {
                showButton = true
            }
        }
    }

    /// Provider-aware subtitle. Mirrors `ChatView.interactivePromptSubtitle`
    /// (lines 397-406) — kept in sync by a comment; consider extracting to a
    /// shared helper if a third caller appears.
    private var providerSubtitle: String {
        switch provider {
        case .claude: return "Claude Code needs your input"
        case .codex: return "Codex needs your input"
        case .opencode: return "OpenCode needs your input"
        }
    }

    /// Short agent name used in tooltips ("Focus the terminal window
    /// running <X>"). Distinct from `providerSubtitle` so the hint copy
    /// stays terse and free of marketing words like "Code".
    private var providerName: String {
        switch provider {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        case .opencode: return "OpenCode"
        }
    }

    /// Shown under the provider subtitle when the Terminal button can't
    /// focus. Tells the user exactly how to unblock the click — start the
    /// agent in tmux. We don't try to explain WHY here (the visual story
    /// is that this pill is dimmed and the tooltip repeats the same
    /// message); this is the "what to do" half of the hint.
    private var hintSubtitle: String {
        "Start \(providerName) in tmux to focus terminal"
    }
}

// MARK: - Chat Approval Bar

/// Approval bar for the chat view with animated buttons
struct ChatApprovalBar: View {
    let tool: String
    let toolInput: String?
    let primaryTextColor: Color
    let secondaryTextColor: Color
    let onApprove: () -> Void
    let onDeny: () -> Void

    @State private var showContent = false
    @State private var showAllowButton = false
    @State private var showDenyButton = false

    var body: some View {
        HStack(spacing: 12) {
            // Tool info
            VStack(alignment: .leading, spacing: 2) {
                Text(MCPToolFormatter.formatToolName(tool))
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundColor(TerminalColors.amber)
                if let input = toolInput {
                    Text(input)
                        .font(.system(size: 11))
                        .foregroundColor(secondaryTextColor)
                        .lineLimit(1)
                }
            }
            .opacity(showContent ? 1 : 0)
            .offset(x: showContent ? 0 : -10)

            Spacer()

            // Deny button
            Button {
                onDeny()
            } label: {
                Text("Deny")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(primaryTextColor.opacity(0.78))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(secondaryTextColor.opacity(0.16))
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .opacity(showDenyButton ? 1 : 0)
            .scaleEffect(showDenyButton ? 1 : 0.8)

            // Allow button
            Button {
                onApprove()
            } label: {
                Text("Allow")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(Color.black.opacity(0.88))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(primaryTextColor.opacity(0.92))
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .opacity(showAllowButton ? 1 : 0)
            .scaleEffect(showAllowButton ? 1 : 0.8)
        }
        .frame(minHeight: 44)  // Consistent height with other bars
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .onAppear {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7).delay(0.05)) {
                showContent = true
            }
            withAnimation(.spring(response: 0.35, dampingFraction: 0.7).delay(0.1)) {
                showDenyButton = true
            }
            withAnimation(.spring(response: 0.35, dampingFraction: 0.7).delay(0.15)) {
                showAllowButton = true
            }
        }
    }
}

// MARK: - New Messages Indicator

/// Floating indicator showing count of new messages when user has scrolled up
struct NewMessagesIndicator: View {
    let count: Int
    let onTap: () -> Void

    @State private var isHovering: Bool = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .bold))

                Text(count == 1 ? "1 new message" : "\(count) new messages")
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundColor(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                Capsule()
                    .fill(Color(red: 0.85, green: 0.47, blue: 0.34)) // Claude orange
                    .shadow(color: .black.opacity(0.3), radius: 8, x: 0, y: 4)
            )
            .scaleEffect(isHovering ? 1.05 : 1.0)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.spring(response: 0.2, dampingFraction: 0.7)) {
                isHovering = hovering
            }
        }
    }
}
