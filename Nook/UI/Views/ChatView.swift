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
    @State private var codexTranscriptHistory: [ChatHistoryItem] = []
    @State private var isRefreshingCodexHistory: Bool = false

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

        // Codex sessions currently source their visible history from SessionStore
        // rather than the Claude JSONL-backed ChatHistoryManager path.
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
                if isLoading {
                    loadingState
                } else if history.isEmpty {
                    emptyState
                } else {
                    messageList
                }

                // Approval bar, interactive prompt, or Input bar
                if let tool = approvalTool {
                    if tool == "AskUserQuestion" {
                        // Interactive tools - show prompt to answer in terminal
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
        .animation(nil, value: viewModel.status)
        .task {
            // Skip if already loaded (prevents redundant work on view recreation)
            guard !hasLoadedOnce else { return }
            hasLoadedOnce = true

            if session.provider == .codex {
                await refreshCodexHistory(using: session)
                return
            }

            // Check if already loaded (from previous visit)
            if ChatHistoryManager.shared.isLoaded(sessionId: sessionId) {
                history = ChatHistoryManager.shared.history(for: sessionId)
                isLoading = false
                return
            }

            // Load in background, show loading state
            await ChatHistoryManager.shared.loadFromFile(sessionId: sessionId, cwd: session.cwd)
            history = ChatHistoryManager.shared.history(for: sessionId)

            withAnimation(.easeOut(duration: 0.2)) {
                isLoading = false
            }
        }
        .onReceive(ChatHistoryManager.shared.$histories) { histories in
            guard session.provider == .claude else { return }
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

                if updated.provider == .codex {
                    let previousCount = history.count
                    history = mergedCodexHistory(
                        transcriptItems: codexTranscriptHistory,
                        liveItems: updated.chatItems
                    )
                    if isLoading {
                        isLoading = false
                    }
                    if !isAutoscrollPaused && history.count > previousCount {
                        shouldScrollToBottom = true
                    }

                    Task {
                        await refreshCodexHistory(using: updated)
                    }
                }

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

    private func mergedCodexHistory(
        transcriptItems: [ChatHistoryItem],
        liveItems: [ChatHistoryItem]
    ) -> [ChatHistoryItem] {
        guard !transcriptItems.isEmpty else { return liveItems }

        var merged = transcriptItems

        for item in liveItems {
            guard case .toolCall(let liveTool) = item.type else { continue }

            let isDuplicate = merged.contains { existing in
                guard case .toolCall(let existingTool) = existing.type else { return false }
                return existingTool.name == liveTool.name &&
                    existingTool.input == liveTool.input &&
                    abs(existing.timestamp.timeIntervalSince(item.timestamp)) < 2
            }

            guard !isDuplicate else { continue }
            merged.append(item)
        }

        return merged.sorted {
            if $0.timestamp == $1.timestamp {
                return $0.id < $1.id
            }
            return $0.timestamp < $1.timestamp
        }
    }

    @MainActor
    private func applyCodexHistoryRefresh(
        transcriptItems: [ChatHistoryItem],
        liveItems: [ChatHistoryItem]
    ) {
        let previousCount = history.count
        codexTranscriptHistory = transcriptItems
        history = mergedCodexHistory(transcriptItems: transcriptItems, liveItems: liveItems)

        if isLoading {
            withAnimation(.easeOut(duration: 0.2)) {
                isLoading = false
            }
        }

        if !isAutoscrollPaused && history.count > previousCount {
            shouldScrollToBottom = true
        }
    }

    private func refreshCodexHistory(using liveSession: SessionState) async {
        guard liveSession.provider == .codex else { return }

        let shouldStart = await MainActor.run { () -> Bool in
            if isRefreshingCodexHistory {
                return false
            }
            isRefreshingCodexHistory = true
            return true
        }
        guard shouldStart else { return }

        let transcriptItems = await CodexTranscriptParser.loadHistory(sessionId: sessionId)

        await MainActor.run {
            applyCodexHistoryRefresh(transcriptItems: transcriptItems, liveItems: liveSession.chatItems)
            isRefreshingCodexHistory = false
        }
    }

    private var chatInputPlaceholder: String {
        switch session.provider {
        case .claude:
            return canSendMessages ? "Message Claude..." : "Open Claude Code in tmux to enable messaging"
        case .codex:
            return canSendMessages ? "Message Codex..." : "Open Codex in tmux to enable messaging"
        }
    }

    private var interactivePromptSubtitle: String {
        switch session.provider {
        case .claude:
            return "Claude Code needs your input"
        case .codex:
            return "Codex needs your input"
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
                LazyVStack(spacing: 16) {
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
            primaryTextColor: primaryTextColor,
            secondaryTextColor: secondaryTextColor,
            onGoToTerminal: { focusTerminal() }
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
        Task {
            if let pid = session.pid {
                _ = await YabaiController.shared.focusWindow(forClaudePid: pid)
            } else {
                _ = await YabaiController.shared.focusWindow(forWorkingDirectory: session.cwd)
            }
        }
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
        let lineHeight: CGFloat = 120
        let newY = switch direction {
        case .up: sv.contentView.bounds.origin.y + lineHeight
        case .down: sv.contentView.bounds.origin.y - lineHeight
        }
        let maxY = max(0, (sv.documentView?.bounds.height ?? 0) - sv.contentView.bounds.height)
        sv.contentView.animator().setBoundsOrigin(NSPoint(x: 0, y: min(max(0, newY), maxY)))
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
        tool.result != nil || tool.structuredResult != nil
    }

    /// Whether the tool can be expanded (has result, NOT a subagent container, NOT Edit).
    private var canExpand: Bool {
        !tool.isSubagentContainer && tool.name != "Edit" && hasResult
    }

    private var showContent: Bool {
        tool.name == "Edit" || isExpanded
    }

    private var agentDescription: String? {
        guard tool.name == "AgentOutputTool",
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

                if tool.isSubagentContainer && !tool.subagentTools.isEmpty {
                    let taskDesc = tool.input["description"] ?? "Running agent..."
                    Text("\(taskDesc) (\(tool.subagentTools.count) tools)")
                        .font(.system(size: 11))
                        .foregroundColor(textColor.opacity(0.7))
                        .lineLimit(1)
                        .truncationMode(.tail)
                } else if tool.name == "AgentOutputTool", let desc = agentDescription {
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
                } else {
                    Text(tool.statusDisplay.text)
                        .font(.system(size: 11))
                        .foregroundColor(textColor.opacity(0.7))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                Spacer()

                // Expand indicator (only for expandable tools)
                if canExpand && tool.status != .running && tool.status != .waitingForApproval {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(secondaryTextColor.opacity(0.8))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: isExpanded)
                }
            }

            // Subagent tools list (for Task/Agent tools)
            if tool.isSubagentContainer && !tool.subagentTools.isEmpty {
                SubagentToolsList(tools: tool.subagentTools, primaryTextColor: primaryTextColor, secondaryTextColor: secondaryTextColor)
                    .padding(.leading, 12)
                    .padding(.top, 2)
            }

            // Result content (Edit always shows, others when expanded)
            // Edit tools bypass hasResult check - fallback in ToolResultContent renders from input params
            if showContent && tool.status != .running && !tool.isSubagentContainer && (hasResult || tool.name == "Edit") {
                ToolResultContent(tool: tool)
                    .padding(.leading, 12)
                    .padding(.top, 4)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            // Edit tools show diff from input even while running
            if tool.name == "Edit" && tool.status == .running {
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

    /// Number of hidden tools (all except last 2)
    private var hiddenCount: Int {
        max(0, tools.count - 2)
    }

    /// Recent tools to show (last 2, regardless of status)
    private var recentTools: [SubagentToolCall] {
        Array(tools.suffix(2))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            // Show count of older hidden tools at top
            if hiddenCount > 0 {
                Text("+\(hiddenCount) more tool uses")
                    .font(.system(size: 10))
                    .foregroundColor(secondaryTextColor)
            }

            // Show last 2 tools (most recent activity)
            ForEach(recentTools) { tool in
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

                Text(isExpanded ? text : String(text.prefix(80)) + (canExpand ? "..." : ""))
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
            .padding(.vertical, 2)
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
    let primaryTextColor: Color
    let secondaryTextColor: Color
    let onGoToTerminal: () -> Void

    @State private var showContent = false
    @State private var showButton = false

    var body: some View {
        HStack(spacing: 12) {
            // Tool info - same style as approval bar
            VStack(alignment: .leading, spacing: 2) {
                Text(MCPToolFormatter.formatToolName("AskUserQuestion"))
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundColor(TerminalColors.amber)
                Text(provider == .codex ? "Codex needs your input" : "Claude Code needs your input")
                    .font(.system(size: 11))
                    .foregroundColor(secondaryTextColor)
                    .lineLimit(1)
            }
            .opacity(showContent ? 1 : 0)
            .offset(x: showContent ? 0 : -10)

            Spacer()

            // Terminal button on right (similar to Allow button)
            Button {
                if isInTmux {
                    onGoToTerminal()
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "terminal")
                        .font(.system(size: 11, weight: .medium))
                    Text("Terminal")
                        .font(.system(size: 13, weight: .medium))
                }
                .foregroundColor(isInTmux ? Color.black.opacity(0.88) : secondaryTextColor)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(isInTmux ? primaryTextColor.opacity(0.92) : secondaryTextColor.opacity(0.16))
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
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
