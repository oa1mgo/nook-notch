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
    let sessionMonitor: SessionMonitor
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
        sessionMonitor: SessionMonitor,
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
        } else if initialSession.provider == .cursor {
            cachedHistory = initialSession.chatItems
            alreadyLoaded = true
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
                    // Track new messages when autoscroll is paused
                    if isAutoscrollPaused && newHistory.count > previousHistoryCount {
                        let addedCount = newHistory.count - previousHistoryCount
                        newMessageCount += addedCount
                        previousHistoryCount = newHistory.count
                    }

                    history = newHistory
                    let lastAssistantLen: Int = {
                        for item in newHistory.reversed() {
                            if case .assistant(let text) = item.type { return text.count }
                        }
                        return 0
                    }()
                    print("[ChatView] history updated sessionId=\(sessionId) count=\(newHistory.count) lastAssistantLen=\(lastAssistantLen)")

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
        .onReceive(viewModel.$keyboardReplyTrigger) { trigger in
            guard trigger != nil,
                  viewModel.contentType == .chat(session),
                  session.phase == .waitingForInput,
                  session.provider == .opencode else { return }
            viewModel.notchOpen(reason: .notification)
            viewModel.pushTo(.question(session))
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
            switch session.provider {
            case .opencode:
                if session.serverPort != nil {
                    return "Message to \(name) via server... (⏎ send · ⌃F/⌃B scroll · ⌃G bottom)"
                } else {
                    return "Message to \(name) via tmux... (⏎ send · ⌃F/⌃B scroll · ⌃G bottom)"
                }
            case .claude, .codex, .cursor:
                return "Message to \(name)... (⏎ send · ⌃F/⌃B scroll · ⌃G bottom)"
            }
        } else {
            switch session.provider {
            case .opencode:
                // OpenCode has two ways to enable messaging: tmux (legacy)
                // or the server API (started with --port). Surface both so
                // users who don't tmux their agent know they have an option.
                return "Run \(name) inside tmux or with --port to enable messaging"
            case .claude, .codex, .cursor:
                return "Open \(name) in tmux to enable messaging"
            }
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
        case .cursor:
            return "Cursor needs your input"
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
                    // Defer scroll to next runloop tick so LazyVStack has a
                    // chance to lay out newly inserted items. Without this
                    // delay, scrollTo("bottom") executes before the new
                    // content has a measured height, causing the last item
                    // to be partially or fully off-screen.
                    DispatchQueue.main.async {
                        withAnimation(.easeOut(duration: 0.3)) {
                            proxy.scrollTo("bottom", anchor: .bottom)
                        }
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

    /// Can send messages via tmux or server API (OpenCode only)
    private var canSendMessages: Bool {
        switch session.provider {
        case .opencode:
            // OpenCode: tmux or server API
            return (session.isInTmux && session.tty != nil) || session.serverPort != nil
        case .claude, .codex, .cursor:
            // Other providers: tmux only
            return session.isInTmux && session.tty != nil
        }
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
            onDeny: { denyPermission() },
            onApproveAlways: session.provider == .opencode ? { approvePermissionAlways() } : nil,
            alwaysPatterns: session.activePermission?.alwaysPatterns ?? []
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
            // For opencode, the question is answered inside Nook's notch UI,
            // not the terminal. If the user collapsed the notch, this lets
            // them re-open it from the chat view rather than losing the
            // question prompt entirely.
            onOpenQuestionInNotch: session.provider == .opencode
                ? {
                    viewModel.notchOpen(reason: .notification)
                    viewModel.pushTo(.question(session))
                }
                : nil,
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
                //
                // NOTE: `notchClose()` defaults to `restorePreviousApp: false`,
                // so focus stays on the terminal we just focused — which is
                // exactly what we want here.
                DebugLog.shared.write("[focus] success, closing notch (terminal keeps focus)")
                viewModel.notchClose()
            } else {
                // All focus methods failed. Keep the notch open so the
                // user can still see the question and try again (or use
                // the fallback hint to start a tmux session). Set a
                // visible error message that gets cleared on next click.
                DebugLog.shared.write("[focus] all methods failed, keeping notch open")
                focusErrorMessage = "Couldn't focus terminal. Switch to it manually (session.pid missing or terminal app not in the known list)."
            }
        }
    }

    /// Try every terminal focus method in order; return true on first success.
    /// Order: tmux (yabai) → non-tmux process tree → last-resort bundle ID.
    /// Logic lives in TerminalFocusHelper so the question panel can reuse it.
    private func tryFocusTerminal() async -> Bool {
        return await TerminalFocusHelper.tryFocusTerminal(for: session)
    }

    private func approvePermission() {
        sessionMonitor.approvePermission(sessionId: sessionId)
    }

    private func approvePermissionAlways() {
        sessionMonitor.approvePermission(sessionId: sessionId, always: true)
    }

    private func denyPermission() {
        sessionMonitor.denyPermission(sessionId: sessionId, reason: nil)
    }

    private func performKeyboardScroll(_ direction: ChatScrollDirection) {
        guard let sv = findScrollView(in: NSApp.keyWindow?.contentView) else {
            // Fallback: synthesize a scroll-wheel event when the scroll view
            // isn't available. Page up/down fall back to a larger line count.
            let lines: Int32 = {
                switch direction {
                case .up:       return 3
                case .down:     return -3
                case .pageUp:   return 30
                case .pageDown: return -30
                case .bottom:   return Int32.max / 2
                }
            }()
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
        case .pageUp, .pageDown:
            // Vim-style page scroll: full viewport height with ~10% overlap
            // so the user keeps some context across pages.
            let viewportHeight = sv.contentView.bounds.height
            let overlap: CGFloat = viewportHeight * 0.1
            let pageSize = max(viewportHeight - overlap, 60)
            let newY = direction == .pageUp
                ? sv.contentView.bounds.origin.y + pageSize
                : sv.contentView.bounds.origin.y - pageSize
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

        // Emit a local fallback event immediately so the user's
        // prompt appears in the chat even if opencode's
        // message.part.updated(type=text) never reaches Nook.
        Task {
            await sendToSession(text)
            await SessionStore.shared.process(.opencodePromptSubmitted(
                sessionId: sessionId, cwd: session.cwd, prompt: text
            ))
        }
    }

    private func sendToSession(_ text: String) async {
        switch session.provider {
        case .opencode:
            await sendToOpenCode(text)
        case .claude, .codex, .cursor:
            await sendToTmux(text)
        }
    }

    private func sendToOpenCode(_ text: String) async {
        // 优先 tmux（OpenCode TUI 模式下唯一可靠的通道）
        if session.isInTmux, let tty = session.tty,
           let target = await findTmuxTarget(tty: tty) {
            DebugLog.shared.write("[ChatView] send via tmux target=\(target) session=\(session.sessionId.prefix(12))")
            _ = await ToolApprovalHandler.shared.sendMessage(text, to: target)
            return
        }

        // fallback: server HTTP API（仅 opencode serve 模式）
        guard let port = session.serverPort else {
            DebugLog.shared.write("[ChatView] send FAILED: no tmux and no serverPort session=\(session.sessionId.prefix(12))")
            return
        }
        DebugLog.shared.write("[ChatView] send via server API port=\(port) session=\(session.sessionId.prefix(12))")
        await sendViaServerAPI(text: text, port: port)
    }

    private func sendViaServerAPI(text: String, port: Int) async {
        let url = URL(string: "http://127.0.0.1:\(port)/session/\(session.sessionId)/message")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "parts": [["type": "text", "text": text]]
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        _ = try? await URLSession.shared.data(for: request)
    }

    private func sendToTmux(_ text: String) async {
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
    ///   TaskUpdate (`.todoWrite` with `taskId` input) is excluded —
    ///   its result is a plain status-confirmation string with no
    ///   structured content worth expanding.
    /// Uses provider-agnostic kind — opencode emits "edit" lowercase while
    /// Claude emits "Edit" PascalCase.
    private var canExpand: Bool {
        if tool.isSubagentContainer { return !tool.subagentTools.isEmpty }
        // TaskUpdate: single-task status change — no expandable content.
        if tool.kind == .todoWrite && tool.input["taskId"] != nil { return false }
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
                } else if tool.kind == .todoWrite {
                    // Two sub-shapes share `.todoWrite`:
                    //   • TaskUpdate  → input has `taskId` + `status`
                    //     (single-task status delta, e.g. "#1 → completed")
                    //   • TodoWrite   → input has `todos` array
                    //     (full list replacement, e.g. "Todo (7 tasks)")
                    if let taskId = tool.input["taskId"],
                       let status = tool.input["status"] {
                        Text("#\(taskId) → \(status)")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(textColor.opacity(0.7))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    } else if let todosJson = tool.input["todos"],
                              let data = todosJson.data(using: .utf8),
                              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                        Text("Todo (\(array.count) tasks)")
                            .font(.system(size: 11))
                            .foregroundColor(textColor.opacity(0.7))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    } else if tool.input["todos"] != nil {
                        Text("Todo")
                            .font(.system(size: 11))
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
                } else {
                    // Defensive fallback for any tool that doesn't have an
                    // explicit branch above (glob, webFetch, webSearch,
                    // write, edit, askUserQuestion, plan-mode,
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
                // so always allow expanding regardless of status.
                // Subagent containers also keep the chevron visible while
                // running — otherwise the user has no affordance to collapse
                // a long-running task, and the list's visibility no longer
                // reflects the chevron's rotation (see `showsSubagentToolsList`).
                // Other tools hide the chevron while running/waitingForApproval
                // because their result content isn't available yet.
                let isAskQuestion = tool.kind == .askUserQuestion
                if canExpand && (isAskQuestion || tool.isSubagentContainer || (tool.status != .running && tool.status != .waitingForApproval)) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(secondaryTextColor.opacity(0.8))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: isExpanded)
                }
            }

            // Subagent tools list (for Task/Agent tools). Visibility is a
            // pure function of the user's `isExpanded` toggle — see
            // `ToolCallItem.showsSubagentToolsList(isExpanded:)` for the
            // rationale (previously force-shown while running, which made
            // the fold action invisible and the row appear "stuck" expanded).
            if tool.showsSubagentToolsList(isExpanded: isExpanded) {
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
    /// For opencode, the question is answered inside Nook's notch UI rather
    /// than the terminal. When non-nil, the button label becomes "Answer in
    /// Nook" and the click re-opens the notch with the question panel —
    /// useful when the user collapsed the notch and lost access to the
    /// question prompt.
    let onOpenQuestionInNotch: (() -> Void)?
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
                if onOpenQuestionInNotch == nil && !canFocusTerminal {
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

            // Action button on right. For opencode the question is answered
            // inside Nook's notch, so the button re-opens the notch with
            // the question panel. For other providers it falls back to the
            // existing "focus the terminal app" flow.
            if let openNotch = onOpenQuestionInNotch {
                Button {
                    openNotch()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "questionmark.bubble.fill")
                            .font(.system(size: 11, weight: .medium))
                        Text("Answer in Nook")
                            .font(.system(size: 13, weight: .medium))
                    }
                    .foregroundColor(.black)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Color.orange)
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("Open the question panel in Nook's notch (⌃R)")
                .opacity(showButton ? 1 : 0)
                .scaleEffect(showButton ? 1 : 0.8)
            } else {
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
        case .cursor: return "Cursor needs your input"
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
        case .cursor: return "Cursor"
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

/// Approval bar for the chat view with animated buttons.
/// Supports an inline "Always allow" confirmation: when the user taps
/// "Always", the bar swaps to a Confirm / Cancel layout with the
/// allowed patterns displayed, matching opencode TUI's two-step flow.
struct ChatApprovalBar: View {
    let tool: String
    let toolInput: String?
    let primaryTextColor: Color
    let secondaryTextColor: Color
    let onApprove: () -> Void
    let onDeny: () -> Void
    /// When non-nil, an additional "Always" button is rendered with a warning
    /// red palette. Only OpenCode sessions wire this up — Claude/Codex leave
    /// it nil and get the original two-button layout.
    let onApproveAlways: (() -> Void)?
    /// Patterns that will be allowed if the user confirms "Always".
    /// Displayed inline during the confirmation step.
    let alwaysPatterns: [String]

    @State private var showContent = false
    @State private var showAllowButton = false
    @State private var showDenyButton = false
    @State private var showAlwaysButton = false
    @State private var isConfirmingAlways = false
    @State private var localMonitor: Any?

    init(
        tool: String,
        toolInput: String?,
        primaryTextColor: Color,
        secondaryTextColor: Color,
        onApprove: @escaping () -> Void,
        onDeny: @escaping () -> Void,
        onApproveAlways: (() -> Void)? = nil,
        alwaysPatterns: [String] = []
    ) {
        self.tool = tool
        self.toolInput = toolInput
        self.primaryTextColor = primaryTextColor
        self.secondaryTextColor = secondaryTextColor
        self.onApprove = onApprove
        self.onDeny = onDeny
        self.onApproveAlways = onApproveAlways
        self.alwaysPatterns = alwaysPatterns
    }

    var body: some View {
        VStack(spacing: 6) {
            if isConfirmingAlways {
                // Patterns info line
                if alwaysPatterns.count == 1 && alwaysPatterns[0] == "*" {
                    Text("This will allow \(MCPToolFormatter.formatToolName(tool)) until OpenCode is restarted.")
                        .font(.system(size: 11))
                        .foregroundColor(secondaryTextColor)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("This will allow the following patterns until OpenCode is restarted:")
                            .font(.system(size: 11))
                            .foregroundColor(secondaryTextColor)
                        ForEach(alwaysPatterns, id: \.self) { pattern in
                            Text("  - \(pattern)")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(secondaryTextColor)
                                .lineLimit(1)
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }

                // Confirm / Cancel buttons
                HStack(spacing: 12) {
                    // Tool info (same as normal mode)
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

                    Spacer()

                    Button {
                        isConfirmingAlways = false
                    } label: {
                        Text("Cancel (Esc)")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.white.opacity(0.6))
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(Color.white.opacity(0.1))
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .fixedSize(horizontal: true, vertical: false)
                    .help("Cancel (Esc)")

                    Button {
                        isConfirmingAlways = false
                        onApproveAlways?()
                    } label: {
                        Text("Confirm (C)")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(Color(red: 0.92, green: 0.30, blue: 0.25))
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(Color.white.opacity(0.92))
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .fixedSize(horizontal: true, vertical: false)
                    .help("Confirm (C)")
                }
            } else {
                // Normal three-button layout
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
                        Text("Deny (N)")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.white.opacity(0.6))
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(Color.white.opacity(0.1))
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .fixedSize(horizontal: true, vertical: false)
                    .opacity(showDenyButton ? 1 : 0)
                    .scaleEffect(showDenyButton ? 1 : 0.8)
                    .help("Deny (N)")

                    // Allow button
                    Button {
                        onApprove()
                    } label: {
                        Text("Allow (Y)")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(Color.black.opacity(0.88))
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(Color.white.opacity(0.92))
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .fixedSize(horizontal: true, vertical: false)
                    .opacity(showAllowButton ? 1 : 0)
                    .scaleEffect(showAllowButton ? 1 : 0.8)
                    .help("Approve (Y)")

                    // Always button — only when onApproveAlways is provided.
                    if onApproveAlways != nil {
                        Button {
                            isConfirmingAlways = true
                        } label: {
                            Text("Always (A)")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(Color(red: 0.92, green: 0.30, blue: 0.25))
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                                .background(Color.white.opacity(0.92))
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .fixedSize(horizontal: true, vertical: false)
                        .opacity(showAlwaysButton ? 1 : 0)
                        .scaleEffect(showAlwaysButton ? 1 : 0.8)
                        .help("Always allow (A)")
                    }
                }
            }
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
            if onApproveAlways != nil {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.7).delay(0.2)) {
                    showAlwaysButton = true
                }
            }
            installKeyboardMonitor()
        }
        .onDisappear {
            removeKeyboardMonitor()
        }
    }

    // MARK: - Keyboard (AppKit local monitor — Y/N/A in permission bar)

    private func installKeyboardMonitor() {
        guard localMonitor == nil else { return }
        // Make the notch key so the local monitor fires. Permission
        // requires an explicit response (Y/N/A), so stealing focus here
        // is the right call — unlike question/notification auto-expand
        // which can wait. Restoring previous-app focus when the bar
        // disappears is the user's responsibility (close the notch).
        NSApp.activate(ignoringOtherApps: false)
        NSApp.windows.first { $0 is NotchPanel }?.makeKey()
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            self.handleKeyDown(event)
        }
    }

    private func removeKeyboardMonitor() {
        if let monitor = localMonitor {
            NSEvent.removeMonitor(monitor)
            localMonitor = nil
        }
    }

    private func handleKeyDown(_ event: NSEvent) -> NSEvent? {
        // Skip when an editable text field is focused (let it handle typing)
        if let responder = NSApp.keyWindow?.firstResponder,
           (responder.isKind(of: NSTextView.self) || responder.isKind(of: NSTextField.self)) {
            return event
        }

        let mods = event.modifierFlags
        let hasCtrl = mods.contains(.control)
        let hasCmd = mods.contains(.command)
        guard !hasCmd, !hasCtrl else { return event }

        let chars = event.charactersIgnoringModifiers?.lowercased() ?? ""

        if isConfirmingAlways {
            // Confirm step: C confirms, Esc cancels
            if chars == "c" {
                isConfirmingAlways = false
                onApproveAlways?()
                return nil
            }
            if event.keyCode == 53 { // Esc
                isConfirmingAlways = false
                return nil
            }
            return event
        }

        // Main buttons
        switch chars {
        case "y":
            onApprove()
            return nil
        case "n":
            onDeny()
            return nil
        case "a" where onApproveAlways != nil:
            isConfirmingAlways = true
            return nil
        default:
            return event
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
