//
//  SessionStore.swift
//  Nook
//
//  Central state manager for all Claude sessions.
//  Single source of truth - all state mutations flow through process().
//

import Combine
import Foundation
import Mixpanel
import os.log

/// Central state manager for all Claude sessions
/// Uses Swift actor for thread-safe state mutations
actor SessionStore {
    static let shared = SessionStore()

    /// Logger for session store (nonisolated static for cross-context access)
    nonisolated static let logger = Logger(subsystem: "com.celestial.Nook", category: "Session")

    // MARK: - State

    /// All sessions keyed by sessionId
    private var sessions: [String: SessionState] = [:]

    /// Pending file syncs (debounced)
    private var pendingSyncs: [String: Task<Void, Never>] = [:]

    /// Pending Codex completion notifications. Codex Stop hooks can continue
    /// the turn, so completion is emitted after a short cancelable window.
    private var pendingCodexCompletionNotifications: [String: Task<Void, Never>] = [:]

    /// In-memory transcript lower bounds after Codex `/clear`. Codex transcript
    /// format is not a stable API, so keep this scoped to live sync only.
    private var codexTranscriptLowerBounds: [String: Date] = [:]

    /// Sync debounce interval (100ms)
    private let syncDebounceNs: UInt64 = 100_000_000

    /// Delay before surfacing a Codex Stop as user-visible completion.
    private let codexCompletionDebounceNs: UInt64 = 750_000_000

    /// Periodic status check task
    private var statusCheckTask: Task<Void, Never>?

    /// Status check interval (3 seconds)
    private let statusCheckIntervalSeconds: UInt64 = 3

    /// Idle Codex sessions do not emit a terminal "ended" event, so reap them
    /// after a short quiet window to avoid stale sessions lingering forever.
    private let codexIdleExpirationSeconds: TimeInterval = 600

    /// Codex hooks can occasionally miss Stop, or finish events can arrive out
    /// of order after Stop. Keep active states bounded so the closed notch does
    /// not keep showing Vibe Glow for a stale turn.
    private let codexActiveQuietExpirationSeconds: TimeInterval = 90
    private let codexRunningToolQuietExpirationSeconds: TimeInterval = 600

    /// BlockOrdering keys for chat items (from unified ChatItemUpdate path).
    /// Maps chatItem.id → BlockOrdering so ChatItemSorter can maintain
    /// correct display order regardless of event arrival timing.
    private var blockOrderings: [String: BlockOrdering] = [:]

    // MARK: - Published State (for UI)

    /// Publisher for session state changes (nonisolated for Combine subscription from any context)
    private nonisolated(unsafe) let sessionsSubject = CurrentValueSubject<[SessionState], Never>([])

    /// Public publisher for UI subscription
    nonisolated var sessionsPublisher: AnyPublisher<[SessionState], Never> {
        sessionsSubject.eraseToAnyPublisher()
    }

    private nonisolated var mixpanel: MixpanelInstance? {
        Mixpanel.safeMainInstance()
    }

    // MARK: - Initialization

    private init() {}

    // MARK: - Event Processing

    /// Process any session event - the ONLY way to mutate state
    func process(_ event: SessionEvent) async {
        Self.logger.debug("Processing: \(String(describing: event), privacy: .public)")

        switch event {
        case .hookReceived(let hookEvent):
            await processHookEvent(hookEvent)

        case .codexSessionStarted(let sessionId, let cwd, let source):
            processCodexSessionStart(sessionId: sessionId, cwd: cwd, source: source)

        case .codexPromptSubmitted(let sessionId, let cwd, let prompt):
            processCodexPromptSubmitted(sessionId: sessionId, cwd: cwd, prompt: prompt)

        case .codexBashStarted(let sessionId, let cwd, let toolName, let toolUseId, let command):
            processCodexBashStarted(sessionId: sessionId, cwd: cwd, toolName: toolName, toolUseId: toolUseId, command: command)

        case .codexBashFinished(let sessionId, let cwd, let toolName, let toolUseId, let command, let output, let isError):
            processCodexBashFinished(sessionId: sessionId, cwd: cwd, toolName: toolName, toolUseId: toolUseId, command: command, output: output, isError: isError)

        case .codexToolStarted(let sessionId, let cwd, let toolName, let toolUseId, let input, let inputSummary):
            processCodexToolStarted(sessionId: sessionId, cwd: cwd, toolName: toolName, toolUseId: toolUseId, input: input, inputSummary: inputSummary)

        case .codexToolFinished(let sessionId, let cwd, let toolName, let toolUseId, let inputSummary, let output, let isError):
            processCodexToolFinished(sessionId: sessionId, cwd: cwd, toolName: toolName, toolUseId: toolUseId, inputSummary: inputSummary, output: output, isError: isError)

        case .codexPermissionRequested(let sessionId, let cwd, let toolName, let toolUseId, let input, let inputSummary):
            processCodexPermissionRequested(sessionId: sessionId, cwd: cwd, toolName: toolName, toolUseId: toolUseId, input: input, inputSummary: inputSummary)

        case .codexCompactingStarted(let sessionId, let cwd):
            processCodexCompactingStarted(sessionId: sessionId, cwd: cwd)

        case .codexCompactingFinished(let sessionId, let cwd):
            processCodexCompactingFinished(sessionId: sessionId, cwd: cwd)

        case .codexSubagentStarted(let sessionId, let cwd):
            processCodexSubagentStarted(sessionId: sessionId, cwd: cwd)

        case .codexSubagentStopped(let sessionId, let cwd):
            processCodexSubagentStopped(sessionId: sessionId, cwd: cwd)

        case .codexStopped(let sessionId, let cwd):
            processCodexStop(sessionId: sessionId, cwd: cwd)

        case .opencodeSessionStarted(let sessionId, let cwd):
            processOpencodeSessionStart(sessionId: sessionId, cwd: cwd)

        case .opencodeProcessingStarted(let sessionId, let cwd):
            processOpencodeProcessingStarted(sessionId: sessionId, cwd: cwd)

        case .opencodeWaitingForUserInput(let sessionId, let cwd):
            processOpencodeWaitingForUserInput(sessionId: sessionId, cwd: cwd)

        case .opencodeStopped(let sessionId, let cwd):
            processOpencodeStop(sessionId: sessionId, cwd: cwd)

        case .cursorSessionStarted(let sessionId, let cwd):
            processCursorSessionStart(sessionId: sessionId, cwd: cwd)

        case .cursorProcessingStarted(let sessionId, let cwd):
            processCursorProcessingStarted(sessionId: sessionId, cwd: cwd)

        case .cursorCompactingStarted(let sessionId, let cwd):
            processCursorCompactingStarted(sessionId: sessionId, cwd: cwd)

        case .cursorStopped(let sessionId, let cwd, let status):
            processCursorStop(sessionId: sessionId, cwd: cwd, status: status)

        case .cursorSessionEnded(let sessionId):
            processCursorSessionEnd(sessionId: sessionId)

        case .chatItemUpdate(let update):
            applyChatItemUpdate(update)

        case .chatItemBatch(let updates):
            for update in updates {
                applyChatItemUpdate(update)
            }

        case .realtimeChatItemBatch(let updates):
            for update in updates {
                applyChatItemUpdate(update, appliesLifecycleEffects: true)
            }

        case .permissionApproved(let sessionId, let toolUseId):
            await processPermissionApproved(sessionId: sessionId, toolUseId: toolUseId)

        case .permissionDenied(let sessionId, let toolUseId, let reason):
            await processPermissionDenied(sessionId: sessionId, toolUseId: toolUseId, reason: reason)

        case .permissionSocketFailed(let sessionId, let toolUseId):
            await processSocketFailure(sessionId: sessionId, toolUseId: toolUseId)

        case .fileUpdated(let payload):
            await processFileUpdate(payload)

        case .interruptDetected(let sessionId):
            await processInterrupt(sessionId: sessionId)

        case .clearDetected(let sessionId):
            await processClearDetected(sessionId: sessionId)

        case .sessionEnded(let sessionId):
            await processSessionEnd(sessionId: sessionId)

        case .loadHistory(let sessionId, let cwd):
            await loadHistoryFromFile(sessionId: sessionId, cwd: cwd)

        case .historyLoaded(let sessionId, let messages, let completedTools, let toolResults, let structuredResults, let conversationInfo):
            await processHistoryLoaded(
                sessionId: sessionId,
                messages: messages,
                completedTools: completedTools,
                toolResults: toolResults,
                structuredResults: structuredResults,
                conversationInfo: conversationInfo
            )

        case .toolCompleted(let sessionId, let toolUseId, let result):
            await processToolCompleted(sessionId: sessionId, toolUseId: toolUseId, result: result)

        // MARK: - Subagent Events

        case .subagentStarted(let sessionId, let taskToolId):
            processSubagentStarted(sessionId: sessionId, taskToolId: taskToolId)

        case .subagentToolExecuted(let sessionId, let tool):
            processSubagentToolExecuted(sessionId: sessionId, tool: tool)

        case .subagentToolCompleted(let sessionId, let toolId, let status):
            processSubagentToolCompleted(sessionId: sessionId, toolId: toolId, status: status)

        case .subagentStopped(let sessionId, let taskToolId):
            processSubagentStopped(sessionId: sessionId, taskToolId: taskToolId)

        case .agentFileUpdated:
            // No longer used - subagent tools are populated from JSONL completion
            break
        }

        publishState()
    }

    // MARK: - Hook Event Processing

    private func processHookEvent(_ event: HookEvent) async {
        let sessionId = event.sessionId
        if let existingSession = sessions[sessionId],
           existingSession.provider != .claude {
            writeDebugLogAsync("[hook-event] ignored provider-mismatch session=\(sessionId) existingProvider=\(existingSession.provider.rawValue) event=\(event.event)")
            return
        }

        let isNewSession = sessions[sessionId] == nil
        var session = sessions[sessionId] ?? createSession(from: event)

        // DIAGNOSTIC (#14): log every hook event to /tmp/nook-debug.log so
        // we can see whether PostToolUse actually fires after the user
        // rejects AskUserQuestion in the terminal. If it doesn't, the chat
        // view's "Waiting for approval" state will never clear.
        DebugLog.shared.write("[hook-event] session=\(sessionId) event=\(event.event) status=\(event.status) tool=\(event.tool ?? "nil") toolUseId=\(event.toolUseId ?? "nil") notificationType=\(event.notificationType ?? "nil")")

        // Track new session in Mixpanel
        if isNewSession {
            mixpanel?.track(event: "Session Started")
        }

        session.pid = event.pid
        if let pid = event.pid {
            let tree = ProcessTreeBuilder.shared.buildTree()
            session.isInTmux = ProcessTreeBuilder.shared.isInTmux(pid: pid, tree: tree)
        }
        if let tty = event.tty {
            session.tty = tty.replacingOccurrences(of: "/dev/", with: "")
        }
        session.lastActivity = Date()

        if event.status == "ended" {
            sessions.removeValue(forKey: sessionId)
            cancelPendingSync(sessionId: sessionId)
            return
        }

        let newPhase = event.determinePhase()

        if session.phase.canTransition(to: newPhase) {
            session.phase = newPhase
        } else {
            Self.logger.debug("Invalid transition: \(String(describing: session.phase), privacy: .public) -> \(String(describing: newPhase), privacy: .public), ignoring")
        }

        if event.event == "PermissionRequest", let toolUseId = event.toolUseId {
            Self.logger.debug("Setting tool \(toolUseId.prefix(12), privacy: .public) status to waitingForApproval")
            DebugLog.shared.write("[hook-tool-status] reason=permissionRequest session=\(sessionId) toolUseId=\(toolUseId) newStatus=waitingForApproval")
            updateToolStatus(in: &session, toolId: toolUseId, status: .waitingForApproval)
        }

        processToolTracking(event: event, session: &session)
        processSubagentTracking(event: event, session: &session)

        if event.event == "Stop" {
            session.subagentState = SubagentState()
        }

        sessions[sessionId] = session
        publishState()

        if event.shouldSyncFile {
            scheduleFileSync(sessionId: sessionId, cwd: event.cwd)
        }
    }

    private func createSession(from event: HookEvent) -> SessionState {
        SessionState(
            sessionId: event.sessionId,
            provider: .claude,
            cwd: event.cwd,
            projectName: URL(fileURLWithPath: event.cwd).lastPathComponent,
            pid: event.pid,
            tty: event.tty?.replacingOccurrences(of: "/dev/", with: ""),
            isInTmux: false,  // Will be updated
            phase: .idle
        )
    }

    private func createCodexSession(sessionId: String, cwd: String) -> SessionState {
        SessionState(
            sessionId: sessionId,
            provider: .codex,
            cwd: cwd,
            projectName: URL(fileURLWithPath: cwd).lastPathComponent,
            phase: .idle
        )
    }

    private func shouldIgnoreCodexSession(_ sessionId: String) -> Bool {
        CodexTranscriptParser.isSubagentSession(sessionId: sessionId)
    }

    private func shouldProcessProviderSession(
        sessionId: String,
        provider: SessionProvider,
        eventName: String
    ) -> Bool {
        guard let existingSession = sessions[sessionId],
              existingSession.provider != provider else {
            return true
        }

        writeDebugLogAsync("[\(provider.rawValue)-lifecycle] ignored provider-mismatch session=\(sessionId) existingProvider=\(existingSession.provider.rawValue) event=\(eventName)")
        return false
    }

    private func processCodexSessionStart(sessionId: String, cwd: String, source: String?) {
        guard shouldProcessProviderSession(sessionId: sessionId, provider: .codex, eventName: "sessionStart") else { return }
        guard !shouldIgnoreCodexSession(sessionId) else { return }
        cancelPendingCodexCompletionNotification(sessionId: sessionId)
        let now = Date()
        let isNewSession = sessions[sessionId] == nil
        var session = sessions[sessionId] ?? createCodexSession(sessionId: sessionId, cwd: cwd)
        if session.cwd.isEmpty, !cwd.isEmpty {
            session = SessionState(
                sessionId: session.sessionId,
                provider: session.provider,
                cwd: cwd,
                pid: session.pid, tty: session.tty, isInTmux: session.isInTmux,
                phase: session.phase,
                chatItems: session.chatItems,
                toolTracker: session.toolTracker,
                subagentState: session.subagentState,
                conversationInfo: session.conversationInfo,
                needsClearReconciliation: session.needsClearReconciliation,
                completionNotificationAt: session.completionNotificationAt,
                lastActivity: session.lastActivity,
                createdAt: session.createdAt
            )
        }
        if source?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "clear" {
            codexTranscriptLowerBounds[sessionId] = now
            resetCodexConversationState(&session)
        }
        enrichCodexRuntimeMetadata(session: &session)
        session.lastActivity = now
        session.completionNotificationAt = nil
        if isNewSession || !session.phase.isActive {
            session.phase = .idle
        }
        sessions[sessionId] = session

        if isNewSession {
            mixpanel?.track(event: "Session Started", properties: ["provider": "codex"])
        }
        scheduleCodexTranscriptSync(sessionId: sessionId)
    }

    private func processCodexPromptSubmitted(sessionId: String, cwd: String, prompt: String?) {
        guard shouldProcessProviderSession(sessionId: sessionId, provider: .codex, eventName: "userPromptSubmit") else { return }
        guard !shouldIgnoreCodexSession(sessionId) else { return }
        cancelPendingCodexCompletionNotification(sessionId: sessionId)
        var session = sessions[sessionId] ?? createCodexSession(sessionId: sessionId, cwd: cwd)
        let now = Date()
        let trimmedPrompt = prompt?.trimmingCharacters(in: .whitespacesAndNewlines)
        let firstUserMessage = session.conversationInfo.firstUserMessage ?? trimmedPrompt

        enrichCodexRuntimeMetadata(session: &session)
        session.lastActivity = now
        session.completionNotificationAt = nil
        session.phase = .processing
        session.conversationInfo = ConversationInfo(
            summary: session.conversationInfo.summary,
            lastMessage: trimmedPrompt,
            lastMessageRole: trimmedPrompt == nil ? session.conversationInfo.lastMessageRole : "user",
            lastToolName: nil,
            firstUserMessage: firstUserMessage,
            lastUserMessageDate: trimmedPrompt == nil ? session.conversationInfo.lastUserMessageDate : now,
            usage: session.conversationInfo.usage
        )

        sessions[sessionId] = session
        scheduleCodexTranscriptSync(sessionId: sessionId)
    }

    private func processCodexBashStarted(sessionId: String, cwd: String, toolName: String, toolUseId: String?, command: String?) {
        let input = command.map { ["command": $0] } ?? [:]
        processCodexToolStarted(
            sessionId: sessionId,
            cwd: cwd,
            toolName: toolName,
            toolUseId: toolUseId,
            input: input,
            inputSummary: command
        )
    }

    private func processCodexToolStarted(
        sessionId: String,
        cwd: String,
        toolName: String,
        toolUseId: String?,
        input: [String: String],
        inputSummary: String?
    ) {
        guard shouldProcessProviderSession(sessionId: sessionId, provider: .codex, eventName: "toolStarted") else { return }
        guard !shouldIgnoreCodexSession(sessionId) else { return }
        cancelPendingCodexCompletionNotification(sessionId: sessionId)
        var session = sessions[sessionId] ?? createCodexSession(sessionId: sessionId, cwd: cwd)
        let now = Date()

        enrichCodexRuntimeMetadata(session: &session)
        session.lastActivity = now
        session.completionNotificationAt = nil
        session.phase = .processing
        if let toolUseId {
            session.toolTracker.startTool(id: toolUseId, name: toolName)
        }

        let inputPreview = inputSummary?.trimmingCharacters(in: .whitespacesAndNewlines)
        session.conversationInfo = ConversationInfo(
            summary: session.conversationInfo.summary,
            lastMessage: inputPreview,
            lastMessageRole: "tool",
            lastToolName: toolName,
            firstUserMessage: session.conversationInfo.firstUserMessage,
            lastUserMessageDate: session.conversationInfo.lastUserMessageDate,
            usage: session.conversationInfo.usage
        )

        sessions[sessionId] = session
        let updates = CodexChatItemAdapter.updates(
            from: .preTool(
                sessionId: sessionId,
                cwd: cwd,
                toolName: toolName,
                toolUseId: toolUseId,
                input: input,
                inputSummary: inputSummary
            ),
            timestamp: now
        )
        for update in updates {
            applyChatItemUpdate(update)
        }
        scheduleCodexTranscriptSync(sessionId: sessionId)
    }

    private func processCodexBashFinished(sessionId: String, cwd: String, toolName: String, toolUseId: String?, command: String?, output: String?, isError: Bool) {
        processCodexToolFinished(
            sessionId: sessionId,
            cwd: cwd,
            toolName: toolName,
            toolUseId: toolUseId,
            inputSummary: command,
            output: output,
            isError: isError
        )
    }

    private func processCodexToolFinished(sessionId: String, cwd: String, toolName: String, toolUseId: String?, inputSummary: String?, output: String?, isError: Bool) {
        guard shouldProcessProviderSession(sessionId: sessionId, provider: .codex, eventName: "toolFinished") else { return }
        guard !shouldIgnoreCodexSession(sessionId) else { return }
        var session = sessions[sessionId] ?? createCodexSession(sessionId: sessionId, cwd: cwd)
        let now = Date()
        let completedTurnAt = session.completionNotificationAt
        let completionPending = pendingCodexCompletionNotifications[sessionId] != nil

        enrichCodexRuntimeMetadata(session: &session)
        session.lastActivity = now

        let completedToolId = latestRunningCodexToolId(in: session, toolName: toolName, toolUseId: toolUseId) ?? toolUseId
        if let toolId = completedToolId {
            session.toolTracker.completeTool(id: toolId, success: !isError)
        }

        session.conversationInfo = ConversationInfo(
            summary: session.conversationInfo.summary,
            lastMessage: inputSummary?.trimmingCharacters(in: .whitespacesAndNewlines) ?? session.conversationInfo.lastMessage,
            lastMessageRole: "tool",
            lastToolName: toolName,
            firstUserMessage: session.conversationInfo.firstUserMessage,
            lastUserMessageDate: session.conversationInfo.lastUserMessageDate,
            usage: session.conversationInfo.usage
        )
        if let completedTurnAt {
            // A late PostToolUse can arrive after Codex has already emitted
            // Stop for the turn. Keep the turn completed while still letting
            // the tool row reconcile above.
            session.phase = .idle
            session.completionNotificationAt = completedTurnAt
        } else if completionPending {
            // Stop has arrived and the completion notification is only being
            // delayed to allow Stop hooks to continue. A late PostToolUse
            // should reconcile the tool row but must not make the turn active.
            session.phase = .idle
            session.completionNotificationAt = nil
        } else {
            // Codex `PostToolUse` is not the end of the turn. The model may keep
            // thinking, produce text, compact, or start another tool before `Stop`.
            // Keep the visible state active until the explicit turn-scope Stop hook.
            if session.phase.canTransition(to: .processing) {
                session.phase = .processing
            }
            session.completionNotificationAt = nil
        }

        sessions[sessionId] = session
        let updates = CodexChatItemAdapter.updates(
            from: .postTool(
                sessionId: sessionId,
                cwd: cwd,
                toolName: toolName,
                toolUseId: completedToolId,
                inputSummary: inputSummary,
                output: output,
                isError: isError
            ),
            timestamp: now
        )
        for update in updates {
            applyChatItemUpdate(update)
        }
        scheduleCodexTranscriptSync(sessionId: sessionId)
    }

    private func processCodexPermissionRequested(
        sessionId: String,
        cwd: String,
        toolName: String?,
        toolUseId: String?,
        input: [String: String],
        inputSummary: String?
    ) {
        guard shouldProcessProviderSession(sessionId: sessionId, provider: .codex, eventName: "permissionRequest") else { return }
        guard !shouldIgnoreCodexSession(sessionId) else { return }
        cancelPendingCodexCompletionNotification(sessionId: sessionId)
        var session = sessions[sessionId] ?? createCodexSession(sessionId: sessionId, cwd: cwd)
        let now = Date()
        enrichCodexRuntimeMetadata(session: &session)
        session.lastActivity = now
        session.completionNotificationAt = nil

        let displayToolName = toolName ?? session.conversationInfo.lastToolName ?? "Tool"
        let resolvedToolUseId = latestRunningCodexToolId(
            in: session,
            toolName: displayToolName,
            toolUseId: toolUseId
        )
        let toolInput = input.mapValues { AnyCodable($0) }
        let context = PermissionContext(
            toolUseId: resolvedToolUseId ?? "",
            toolName: displayToolName,
            toolInput: toolInput.isEmpty ? nil : toolInput,
            receivedAt: now
        )
        let targetPhase = SessionPhase.waitingForTerminalApproval(context)
        if session.phase.canTransition(to: targetPhase) {
            session.phase = targetPhase
        }

        if let resolvedToolUseId {
            updateToolStatus(in: &session, toolId: resolvedToolUseId, status: .waitingForApproval)
            if var inProgress = session.toolTracker.inProgress[resolvedToolUseId] {
                inProgress.phase = .pendingApproval
                session.toolTracker.inProgress[resolvedToolUseId] = inProgress
            }
        }

        let trimmedSummary = inputSummary?.trimmingCharacters(in: .whitespacesAndNewlines)
        var nonEmptySummary: String?
        if let trimmedSummary, !trimmedSummary.isEmpty {
            nonEmptySummary = trimmedSummary
        }
        session.conversationInfo = ConversationInfo(
            summary: session.conversationInfo.summary,
            lastMessage: nonEmptySummary ?? session.conversationInfo.lastMessage,
            lastMessageRole: "tool",
            lastToolName: displayToolName,
            firstUserMessage: session.conversationInfo.firstUserMessage,
            lastUserMessageDate: session.conversationInfo.lastUserMessageDate,
            usage: session.conversationInfo.usage
        )
        sessions[sessionId] = session
        scheduleCodexTranscriptSync(sessionId: sessionId)
    }

    private func processCodexCompactingStarted(sessionId: String, cwd: String) {
        guard shouldProcessProviderSession(sessionId: sessionId, provider: .codex, eventName: "preCompact") else { return }
        guard !shouldIgnoreCodexSession(sessionId) else { return }
        cancelPendingCodexCompletionNotification(sessionId: sessionId)
        var session = sessions[sessionId] ?? createCodexSession(sessionId: sessionId, cwd: cwd)
        enrichCodexRuntimeMetadata(session: &session)
        session.lastActivity = Date()
        session.completionNotificationAt = nil
        if session.phase.canTransition(to: .compacting) {
            session.phase = .compacting
        }
        sessions[sessionId] = session
        scheduleCodexTranscriptSync(sessionId: sessionId)
    }

    private func processCodexCompactingFinished(sessionId: String, cwd: String) {
        guard shouldProcessProviderSession(sessionId: sessionId, provider: .codex, eventName: "postCompact") else { return }
        guard !shouldIgnoreCodexSession(sessionId) else { return }
        var session = sessions[sessionId] ?? createCodexSession(sessionId: sessionId, cwd: cwd)
        enrichCodexRuntimeMetadata(session: &session)
        session.lastActivity = Date()
        if session.completionNotificationAt != nil || pendingCodexCompletionNotifications[sessionId] != nil {
            session.phase = .idle
            sessions[sessionId] = session
            scheduleCodexTranscriptSync(sessionId: sessionId)
            return
        }

        session.completionNotificationAt = nil
        if session.phase.canTransition(to: .processing) {
            session.phase = .processing
        }
        sessions[sessionId] = session
        scheduleCodexTranscriptSync(sessionId: sessionId)
    }

    private func processCodexSubagentStarted(sessionId: String, cwd: String) {
        guard shouldProcessProviderSession(sessionId: sessionId, provider: .codex, eventName: "subagentStart") else { return }
        guard !shouldIgnoreCodexSession(sessionId) else { return }
        cancelPendingCodexCompletionNotification(sessionId: sessionId)
        var session = sessions[sessionId] ?? createCodexSession(sessionId: sessionId, cwd: cwd)
        enrichCodexRuntimeMetadata(session: &session)
        session.lastActivity = Date()
        session.completionNotificationAt = nil
        if session.phase.canTransition(to: .processing) {
            session.phase = .processing
        }
        sessions[sessionId] = session
        scheduleCodexTranscriptSync(sessionId: sessionId)
    }

    private func processCodexSubagentStopped(sessionId: String, cwd: String) {
        guard shouldProcessProviderSession(sessionId: sessionId, provider: .codex, eventName: "subagentStop") else { return }
        guard !shouldIgnoreCodexSession(sessionId) else { return }
        var session = sessions[sessionId] ?? createCodexSession(sessionId: sessionId, cwd: cwd)
        enrichCodexRuntimeMetadata(session: &session)
        session.lastActivity = Date()
        if session.completionNotificationAt != nil || pendingCodexCompletionNotifications[sessionId] != nil {
            session.phase = .idle
            sessions[sessionId] = session
            scheduleCodexTranscriptSync(sessionId: sessionId)
            return
        }

        session.completionNotificationAt = nil
        if session.phase.canTransition(to: .processing) {
            session.phase = .processing
        }
        sessions[sessionId] = session
        scheduleCodexTranscriptSync(sessionId: sessionId)
    }

    private func processCodexStop(sessionId: String, cwd: String) {
        guard shouldProcessProviderSession(sessionId: sessionId, provider: .codex, eventName: "stop") else { return }
        guard !shouldIgnoreCodexSession(sessionId) else { return }
        cancelPendingCodexCompletionNotification(sessionId: sessionId)
        var session = sessions[sessionId] ?? createCodexSession(sessionId: sessionId, cwd: cwd)
        enrichCodexRuntimeMetadata(session: &session)
        session.lastActivity = Date()
        session.phase = .idle
        session.completionNotificationAt = nil
        finishDanglingCodexTools(in: &session)
        session.toolTracker.inProgress.removeAll()
        sessions[sessionId] = session
        scheduleCodexTranscriptSync(sessionId: sessionId)
        scheduleCodexCompletionNotification(sessionId: sessionId)
    }

    // MARK: - OpenCode Session Processing

    private func createOpencodeSession(sessionId: String, cwd: String) -> SessionState {
        SessionState(
            sessionId: sessionId,
            provider: .opencode,
            cwd: cwd,
            projectName: URL(fileURLWithPath: cwd).lastPathComponent,
            phase: .idle
        )
    }

    // No session-id-based ignore hook for opencode: subagent sessions are
    // rewritten to the parent session id by `OpencodeHookAdapter` before
    // their events reach this store (see `subagentToParent` / `remapToParent`
    // in OpencodeHookAdapter.swift), so they never appear in the opencode
    // event stream in the first place. If a future opencode version starts
    // surfacing child session ids we should add the ignore check back here
    // (mirroring `shouldIgnoreCodexSession`'s transcript-based filter).

    private func processOpencodeSessionStart(sessionId: String, cwd: String) {
        let isNewSession = sessions[sessionId] == nil
        var session = sessions[sessionId] ?? createOpencodeSession(sessionId: sessionId, cwd: cwd)
        // When the session was auto-created by applyChatItemUpdate
        // (chat items arrived ~1ms before session.updated), the cwd is
        // a placeholder "". Since cwd/projectName are `let`, we rebuild
        // the session struct with the real values, preserving all
        // mutable state (chatItems, toolTracker, phase, etc.).
        if session.cwd.isEmpty, !cwd.isEmpty {
            session = SessionState(
                sessionId: session.sessionId,
                provider: session.provider,
                cwd: cwd,
                pid: session.pid, tty: session.tty, isInTmux: session.isInTmux,
                phase: session.phase,
                chatItems: session.chatItems,
                toolTracker: session.toolTracker,
                subagentState: session.subagentState,
                conversationInfo: session.conversationInfo,
                needsClearReconciliation: session.needsClearReconciliation,
                completionNotificationAt: session.completionNotificationAt,
                lastActivity: session.lastActivity,
                createdAt: session.createdAt
            )
        }
        enrichOpencodeRuntimeMetadata(session: &session)
        session.lastActivity = Date()
        session.completionNotificationAt = nil
        if isNewSession || !session.phase.isActive {
            session.phase = .idle
        }
        sessions[sessionId] = session

        // Track "Session Started" even for auto-created sessions —
        // applyChatItemUpdate fires the Mixpanel event on first creation
        // but processOpencodeSessionStart may be the first real session
        // start if the chat-item auto-create was for a different session.
        if isNewSession {
            mixpanel?.track(event: "Session Started", properties: ["provider": "opencode"])
        }
        publishState()
    }

    private func processOpencodeProcessingStarted(sessionId: String, cwd: String) {
        var session = sessions[sessionId] ?? createOpencodeSession(sessionId: sessionId, cwd: cwd)
        enrichOpencodeRuntimeMetadata(session: &session)
        session.lastActivity = Date()
        session.completionNotificationAt = nil
        // Idempotent: if already processing, phase.canTransition allows it
        // (processing → processing is a no-op). Covers both thinking and
        // tool-running phases; the first call wins.
        DebugLog.shared.write("[opencode-phase] processingStarted session=\(sessionId.prefix(8)) currentPhase=\(session.phase)")
        if session.phase.canTransition(to: .processing) {
            session.phase = .processing
            DebugLog.shared.write("[opencode-phase] processingStarted → phase set to .processing")
        } else {
            DebugLog.shared.write("[opencode-phase] processingStarted → transition rejected from \(session.phase)")
        }
        sessions[sessionId] = session
        publishState()
    }

    private func processOpencodeWaitingForUserInput(sessionId: String, cwd: String) {
        var session = sessions[sessionId] ?? createOpencodeSession(sessionId: sessionId, cwd: cwd)
        enrichOpencodeRuntimeMetadata(session: &session)
        session.lastActivity = Date()
        // The user is being shown an ask_user_question dialog. Don't surface
        // a completion notification (the user already knows the session is
        // waiting on them). Transition is allowed from .processing by the
        // state machine; from .idle, .waitingForInput is also reachable.
        session.completionNotificationAt = nil
        DebugLog.shared.write("[opencode-phase] waitingForUserInput session=\(sessionId.prefix(8)) currentPhase=\(session.phase)")
        if session.phase.canTransition(to: .waitingForInput) {
            session.phase = .waitingForInput
            DebugLog.shared.write("[opencode-phase] waitingForUserInput → phase set to .waitingForInput")
        } else {
            DebugLog.shared.write("[opencode-phase] waitingForUserInput → transition rejected from \(session.phase)")
        }
        sessions[sessionId] = session
        publishState()
    }

    private func processOpencodeStop(sessionId: String, cwd: String) {
        var session = sessions[sessionId] ?? createOpencodeSession(sessionId: sessionId, cwd: cwd)
        let hadRunningTools = hasRunningTools(in: session)
        enrichOpencodeRuntimeMetadata(session: &session)
        session.lastActivity = Date()
        session.phase = .idle
        session.completionNotificationAt = hadRunningTools ? nil : Date()

        for index in session.chatItems.indices {
            if case .toolCall(var tool) = session.chatItems[index].type, tool.status == .running {
                tool.status = .interrupted
                session.chatItems[index] = ChatHistoryItem(
                    id: session.chatItems[index].id,
                    type: .toolCall(tool),
                    timestamp: session.chatItems[index].timestamp
                )
            }
        }

        session.toolTracker.inProgress.removeAll()
        sessions[sessionId] = session
        publishState()
    }

    // MARK: - Cursor Session Processing

    private func processCursorSessionStart(sessionId: String, cwd: String) {
        applyCursorLifecycle(sessionId: sessionId, event: .sessionStart(cwd: cwd))
    }

    private func processCursorProcessingStarted(sessionId: String, cwd: String) {
        applyCursorLifecycle(sessionId: sessionId, event: .processingStarted(cwd: cwd))
    }

    private func processCursorCompactingStarted(sessionId: String, cwd: String) {
        applyCursorLifecycle(sessionId: sessionId, event: .compactingStarted(cwd: cwd))
    }

    private func processCursorStop(sessionId: String, cwd: String, status: String?) {
        applyCursorLifecycle(sessionId: sessionId, event: .stop(cwd: cwd, status: status))
    }

    private func processCursorSessionEnd(sessionId: String) {
        applyCursorLifecycle(sessionId: sessionId, event: .sessionEnd)
    }

    private func applyCursorLifecycle(
        sessionId: String,
        event: CursorSessionStateReducer.Event
    ) {
        if let existingSession = sessions[sessionId],
           existingSession.provider != .cursor {
            writeDebugLogAsync("[cursor-lifecycle] ignored provider-mismatch session=\(sessionId) existingProvider=\(existingSession.provider.rawValue)")
            return
        }

        let result = CursorSessionStateReducer.reduce(
            existingSession: sessions[sessionId],
            sessionId: sessionId,
            event: event
        )

        if let session = result.session {
            sessions[sessionId] = session
        }

        if let debugMessage = result.debugMessage {
            writeDebugLogAsync(debugMessage)
        }

        if result.didCreateSession {
            mixpanel?.track(event: "Session Started", properties: ["provider": "cursor"])
        }
    }

    private nonisolated func writeDebugLogAsync(_ message: String) {
        Task { @MainActor in
            DebugLog.shared.write(message)
        }
    }

    // MARK: - Unified ChatItem Update Processing

    /// Apply a single ChatItemUpdate to session chat state. The update
    /// itself is provider-normalized content; lifecycle effects are opt-in
    /// for live stream routes and stay out of transcript/history sync.
    ///
    /// After each mutation, chatItems are re-sorted using ChatItemSorter
    /// to maintain correct display order based on BlockOrdering keys.
    ///
    /// Session auto-creation: live event streams can deliver chat updates
    /// before the session-start lifecycle event. Rather than dropping those
    /// items, create a minimal placeholder and let the provider lifecycle
    /// path enrich cwd/pid/tty metadata when it arrives.
    private func applyChatItemUpdate(
        _ update: ChatItemUpdate,
        appliesLifecycleEffects: Bool = false
    ) {
        if let existingSession = sessions[update.sessionId],
           existingSession.provider != update.provider {
            writeDebugLogAsync("[chat-item-update] ignored provider-mismatch session=\(update.sessionId) existingProvider=\(existingSession.provider.rawValue) updateProvider=\(update.provider.rawValue) id=\(update.id)")
            return
        }

        let now = Date()
        var session = sessions[update.sessionId] ?? SessionState(
            sessionId: update.sessionId,
            provider: update.provider,
            cwd: ""  // placeholder — filled by the imminent sessionStart
        )
        let isNewSession = sessions[update.sessionId] == nil
        if isNewSession {
            DebugLog.shared.write("[chat-item-update] auto-created session for \(update.sessionId) (pre-sessionStart chat item)")
            // Fire Mixpanel immediately on auto-create so we never miss
            // the "Session Started" event even if sessionStart passthrough
            // arrives later and finds the session already existing.
            mixpanel?.track(event: "Session Started", properties: ["provider": update.provider.rawValue])
        }

        let didApply = ChatItemUpdateReducer.apply(
            update,
            items: &session.chatItems,
            orderings: &blockOrderings,
            now: now
        )
        guard didApply else { return }

        // ── Optional lifecycle effects ────────────────────────────────
        // ChatItemUpdate itself only represents chat content mutations.
        // Live-stream routes can opt into lifecycle effects at the event
        // boundary; transcript/history sync routes should keep this false.
        if appliesLifecycleEffects {
            applyRealtimeChatItemLifecycle(update, to: &session, now: now)
        }

        sessions[update.sessionId] = session
        DebugLog.shared.write("[chat-item-update] session=\(update.sessionId) id=\(update.id) mutation=\(update.mutation) totalItems=\(session.chatItems.count)")
    }

    private func applyRealtimeChatItemLifecycle(
        _ update: ChatItemUpdate,
        to session: inout SessionState,
        now: Date
    ) {
        guard update.mutation == .insert || update.mutation == .updateStatus else {
            return
        }

        session.lastActivity = now

        switch update.block {
        case .userPrompt(let text):
            session.phase = .processing
            session.completionNotificationAt = nil
            session.conversationInfo = ConversationInfo(
                summary: session.conversationInfo.summary,
                lastMessage: text,
                lastMessageRole: "user",
                lastToolName: nil,
                firstUserMessage: session.conversationInfo.firstUserMessage ?? text,
                lastUserMessageDate: now,
                usage: session.conversationInfo.usage
            )

        case .assistantText(let text):
            session.phase = hasRunningTools(in: session) ? .processing : .idle
            session.completionNotificationAt = now
            session.conversationInfo = ConversationInfo(
                summary: session.conversationInfo.summary,
                lastMessage: text,
                lastMessageRole: "assistant",
                lastToolName: nil,
                firstUserMessage: session.conversationInfo.firstUserMessage,
                lastUserMessageDate: session.conversationInfo.lastUserMessageDate,
                usage: session.conversationInfo.usage
            )

        case .thinking:
            // Thinking is an active-processing signal even before a tool starts.
            session.completionNotificationAt = nil
            if !session.phase.isActive {
                session.phase = .processing
            }

        case .toolCall(let tc):
            if update.mutation == .insert {
                session.toolTracker.startTool(id: update.id, name: tc.name)
                session.completionNotificationAt = nil
                session.phase = .processing
            } else {
                session.toolTracker.completeTool(id: update.id, success: !update.isError)
                session.phase = hasRunningTools(in: session) ? .processing : .idle
            }
            session.conversationInfo = ConversationInfo(
                summary: session.conversationInfo.summary,
                lastMessage: session.conversationInfo.lastMessage,
                lastMessageRole: "tool",
                lastToolName: tc.name,
                firstUserMessage: session.conversationInfo.firstUserMessage,
                lastUserMessageDate: session.conversationInfo.lastUserMessageDate,
                usage: session.conversationInfo.usage
            )

        case .image, .interrupted:
            break
        }
    }

    private func makeOpencodeToolId(for sessionId: String) -> String {
        let millis = Int(Date().timeIntervalSince1970 * 1000)
        return "opencode-bash-\(sessionId)-\(millis)"
    }

    private func enrichOpencodeRuntimeMetadata(session: inout SessionState) {
        let tree = ProcessTreeBuilder.shared.buildTree()
        guard let process = bestMatchingOpencodeProcess(for: session.cwd, tree: tree) else {
            return
        }

        session.pid = process.pid
        session.tty = process.tty
        session.isInTmux = ProcessTreeBuilder.shared.isInTmux(pid: process.pid, tree: tree)
    }

    /// Find the most likely OpenCode parent process for the given working directory.
    private func bestMatchingOpencodeProcess(for cwd: String, tree: [Int: ProcessInfo]) -> ProcessInfo? {
        let candidates = tree.values.filter { info in
            let command = info.command.lowercased()
            return command == "opencode" || command.hasSuffix("/opencode") || command.contains("/opencode/")
        }

        let normalizedCwd = URL(fileURLWithPath: cwd).standardizedFileURL.path
        let exactMatches = candidates.compactMap { info -> ProcessInfo? in
            guard let processCwd = ProcessTreeBuilder.shared.getWorkingDirectory(forPid: info.pid) else {
                return nil
            }
            let normalizedProcessCwd = URL(fileURLWithPath: processCwd).standardizedFileURL.path
            return normalizedProcessCwd == normalizedCwd ? info : nil
        }

        if let tmuxMatch = exactMatches
            .filter({ ProcessTreeBuilder.shared.isInTmux(pid: $0.pid, tree: tree) })
            .max(by: { $0.pid < $1.pid }) {
            return tmuxMatch
        }

        if let exactMatch = exactMatches.max(by: { $0.pid < $1.pid }) {
            return exactMatch
        }

        return candidates
            .filter { ProcessTreeBuilder.shared.isInTmux(pid: $0.pid, tree: tree) }
            .max(by: { $0.pid < $1.pid })
    }

    // MARK: - Codex Helpers

    private func resetCodexConversationState(_ session: inout SessionState) {
        for item in session.chatItems {
            blockOrderings.removeValue(forKey: item.id)
        }

        session.chatItems.removeAll()
        session.toolTracker = ToolTracker()
        session.subagentState = SubagentState()
        session.conversationInfo = ConversationInfo(
            summary: nil,
            lastMessage: nil,
            lastMessageRole: nil,
            lastToolName: nil,
            firstUserMessage: nil,
            lastUserMessageDate: nil
        )
        session.needsClearReconciliation = false
        session.completionNotificationAt = nil
    }

    private func scheduleCodexCompletionNotification(sessionId: String) {
        cancelPendingCodexCompletionNotification(sessionId: sessionId)

        pendingCodexCompletionNotifications[sessionId] = Task { [weak self, codexCompletionDebounceNs] in
            try? await Task.sleep(nanoseconds: codexCompletionDebounceNs)
            guard !Task.isCancelled else { return }
            await self?.emitCodexCompletionNotification(sessionId: sessionId)
        }
    }

    private func cancelPendingCodexCompletionNotification(sessionId: String) {
        pendingCodexCompletionNotifications[sessionId]?.cancel()
        pendingCodexCompletionNotifications.removeValue(forKey: sessionId)
    }

    private func emitCodexCompletionNotification(sessionId: String) {
        pendingCodexCompletionNotifications.removeValue(forKey: sessionId)
        guard var session = sessions[sessionId],
              session.provider == .codex,
              session.phase == .idle,
              session.completionNotificationAt == nil else {
            return
        }

        session.completionNotificationAt = Date()
        sessions[sessionId] = session
        publishState()
    }

    private func latestRunningCodexToolId(in session: SessionState, toolName: String, toolUseId: String?) -> String? {
        if let toolUseId,
           session.chatItems.contains(where: { $0.id == toolUseId }) {
            return toolUseId
        }

        for item in session.chatItems.reversed() {
            guard case .toolCall(let tool) = item.type else { continue }
            guard tool.name == toolName, tool.status == .running else { continue }
            return item.id
        }
        return nil
    }

    private func hasRunningTools(in session: SessionState) -> Bool {
        session.chatItems.contains { item in
            if case .toolCall(let tool) = item.type {
                return tool.status == .running || tool.status == .waitingForApproval
            }
            return false
        }
    }

    private func finishDanglingCodexTools(in session: inout SessionState) {
        for index in session.chatItems.indices {
            guard case .toolCall(var tool) = session.chatItems[index].type,
                  tool.status == .running || tool.status == .waitingForApproval else {
                continue
            }

            tool.status = tool.status == .waitingForApproval ? .interrupted : .success
            session.chatItems[index] = ChatHistoryItem(
                id: session.chatItems[index].id,
                type: .toolCall(tool),
                timestamp: session.chatItems[index].timestamp
            )
        }
    }

    private func enrichCodexRuntimeMetadata(session: inout SessionState) {
        let tree = ProcessTreeBuilder.shared.buildTree()
        guard let process = bestMatchingCodexProcess(for: session.cwd, tree: tree) else {
            session.pid = nil
            session.tty = nil
            session.isInTmux = false
            return
        }

        session.pid = process.pid
        session.tty = process.tty
        session.isInTmux = ProcessTreeBuilder.shared.isInTmux(pid: process.pid, tree: tree)
    }

    private func bestMatchingCodexProcess(for cwd: String, tree: [Int: ProcessInfo]) -> ProcessInfo? {
        let normalizedCwd = URL(fileURLWithPath: cwd).standardizedFileURL.path

        let candidates = tree.values.filter { info in
            let command = info.command.lowercased()
            return command == "codex" || command.hasSuffix("/codex") || command.contains("/codex/")
        }

        let exactMatches = candidates.compactMap { info -> ProcessInfo? in
            guard let processCwd = ProcessTreeBuilder.shared.getWorkingDirectory(forPid: info.pid) else {
                return nil
            }

            let normalizedProcessCwd = URL(fileURLWithPath: processCwd).standardizedFileURL.path
            return normalizedProcessCwd == normalizedCwd ? info : nil
        }

        if let tmuxMatch = exactMatches
            .filter({ ProcessTreeBuilder.shared.isInTmux(pid: $0.pid, tree: tree) })
            .max(by: { $0.pid < $1.pid }) {
            return tmuxMatch
        }

        if let exactMatch = exactMatches.max(by: { $0.pid < $1.pid }) {
            return exactMatch
        }

        return nil
    }

    private func processToolTracking(event: HookEvent, session: inout SessionState) {
        // DIAGNOSTIC (#14): log every event entering processToolTracking
        // so we can confirm whether PostToolUse actually arrives after a
        // user denies AskUserQuestion in the terminal (root cause of the
        // "stuck on Waiting for approval" symptom).
        DebugLog.shared.write("[hook-tool-tracking] session=\(event.sessionId) event=\(event.event) toolUseId=\(event.toolUseId ?? "nil") tool=\(event.tool ?? "nil")")

        // Skip hook placeholder creation for append-order providers.
        // The adapter's JSONL/transcript sync is authoritative — it creates
        // items with correct message.timestamp in source order. Hook
        // PreToolUse creates placeholders with timestamp = Date() (later
        // than the message timestamp), which breaks the append-only ordering
        // guarantee (e.g. a Question placeholder appearing before its
        // thinking bubble). For append-order providers, the adapter handles
        // both tool calls and their status; the hook path only tracks
        // lifecycle in toolTracker.
        if !session.provider.needsHookPlaceholders {
            if let toolUseId = event.toolUseId {
                switch event.event {
                case "PreToolUse":
                    if let toolName = event.tool {
                        session.toolTracker.startTool(id: toolUseId, name: toolName)
                    }
                case "PostToolUse":
                    session.toolTracker.completeTool(id: toolUseId, success: true)
                default:
                    break
                }
            }
            return
        }

        switch event.event {
        case "PreToolUse":
            if let toolUseId = event.toolUseId, let toolName = event.tool {
                session.toolTracker.startTool(id: toolUseId, name: toolName)

                // Skip creating top-level placeholder for subagent tools
                // They'll appear under their parent Task instead
                let isSubagentTool = session.subagentState.hasActiveSubagent && !ToolCallItem.isSubagentContainerName(toolName)
                if isSubagentTool {
                    return
                }

                let toolExists = session.chatItems.contains { $0.id == toolUseId }
                if !toolExists {
                    var input: [String: String] = [:]
                    if let hookInput = event.toolInput {
                        for (key, value) in hookInput {
                            if let str = value.value as? String {
                                input[key] = str
                            } else if let num = value.value as? Int {
                                input[key] = String(num)
                            } else if let bool = value.value as? Bool {
                                input[key] = bool ? "true" : "false"
                            }
                        }
                    }

                    let placeholderItem = ChatHistoryItem(
                        id: toolUseId,
                        type: .toolCall(ToolCallItem(
                            name: toolName,
                            input: input,
                            status: .running,
                            result: nil,
                            structuredResult: nil,
                            subagentTools: []
                        )),
                        timestamp: Date()
                    )
                    session.chatItems.append(placeholderItem)
                    Self.logger.debug("Created placeholder tool entry for \(toolUseId.prefix(16), privacy: .public)")
                }
            }

        case "PostToolUse":
            if let toolUseId = event.toolUseId {
                session.toolTracker.completeTool(id: toolUseId, success: true)
                // Update chatItem status - tool completed (possibly approved via terminal)
                // Only update if still waiting for approval or running
                for i in 0..<session.chatItems.count {
                    if session.chatItems[i].id == toolUseId,
                       case .toolCall(var tool) = session.chatItems[i].type,
                       tool.status == .waitingForApproval || tool.status == .running {
                        let prevStatus = tool.status
                        // DIAGNOSTIC (#14): confirm whether PostToolUse ever
                        // lands and what status transition it forces. The
                        // fact that it always sets .success (regardless of
                        // whether the tool was rejected in the terminal) is
                        // suspected bug A — flagged for the next iteration.
                        DebugLog.shared.write("[hook-tool-tracking] postToolUse session=\(event.sessionId) toolUseId=\(toolUseId) prevStatus=\(prevStatus) newStatus=success")
                        tool.status = .success
                        session.chatItems[i] = ChatHistoryItem(
                            id: toolUseId,
                            type: .toolCall(tool),
                            timestamp: session.chatItems[i].timestamp
                        )
                        break
                    } else if session.chatItems[i].id == toolUseId,
                              case .toolCall = session.chatItems[i].type {
                        // DIAGNOSTIC (#14): tool was found in chatItems but
                        // its status was neither .running nor
                        // .waitingForApproval — i.e. PostToolUse arrived
                        // after JSONL sync already set a terminal status.
                        DebugLog.shared.write("[hook-tool-tracking] postToolUse-skip session=\(event.sessionId) toolUseId=\(toolUseId) reason=existing-status-not-active")
                    }
                }
            }

        default:
            break
        }
    }

    private func processSubagentTracking(event: HookEvent, session: inout SessionState) {
        switch event.event {
        case "PreToolUse":
            if ToolCallItem.isSubagentContainerName(event.tool), let toolUseId = event.toolUseId {
                let description = event.toolInput?["description"]?.value as? String
                session.subagentState.startTask(taskToolId: toolUseId, description: description)
                Self.logger.debug("Started Task/Agent subagent tracking: \(toolUseId.prefix(12), privacy: .public)")
            } else if let toolName = event.tool,
                      let toolUseId = event.toolUseId,
                      session.subagentState.hasActiveSubagent {
                // A subagent's inner tool is starting. Add it to the parent Task/Agent's
                // subagent list and sync to chatItems so the UI updates live (rather
                // than only after the parent Agent completes).
                var input: [String: String] = [:]
                if let hookInput = event.toolInput {
                    for (key, value) in hookInput {
                        if let str = value.value as? String {
                            input[key] = str
                        } else if let num = value.value as? Int {
                            input[key] = String(num)
                        } else if let bool = value.value as? Bool {
                            input[key] = bool ? "true" : "false"
                        }
                    }
                }
                let subagentTool = SubagentToolCall(
                    id: toolUseId,
                    name: toolName,
                    input: input,
                    status: .running,
                    timestamp: Date()
                )
                session.subagentState.addSubagentTool(subagentTool)
                syncSubagentToolsToChatItems(session: &session)
            }

        case "PostToolUse":
            if ToolCallItem.isSubagentContainerName(event.tool), let toolUseId = event.toolUseId {
                // Agent tool returned — the subagent has finished. Stop
                // tracking so subsequent tools in the parent turn don't get
                // attached to this dead task.
                session.subagentState.stopTask(taskToolId: toolUseId)
                Self.logger.debug("Stopped subagent tracking for \(toolUseId.prefix(12), privacy: .public)")
            } else if let toolUseId = event.toolUseId,
                      session.subagentState.hasActiveSubagent {
                // A subagent's inner tool completed. Update its status in the
                // parent's subagent list and sync.
                session.subagentState.updateSubagentToolStatus(toolId: toolUseId, status: .success)
                syncSubagentToolsToChatItems(session: &session)
            }

        case "SubagentStop":
            // SubagentStop fires when a subagent completes - stop tracking
            // Subagent tools are populated from agent file in processFileUpdated
            Self.logger.debug("SubagentStop received")

        default:
            break
        }
    }

    /// Push the current subagent tool lists from subagentState into the
    /// corresponding ChatHistoryItem.subagentTools so the UI renders them live.
    private func syncSubagentToolsToChatItems(session: inout SessionState) {
        for (taskToolId, context) in session.subagentState.activeTasks {
            guard !context.subagentTools.isEmpty else { continue }
            for i in 0..<session.chatItems.count {
                if session.chatItems[i].id == taskToolId,
                   case .toolCall(var tool) = session.chatItems[i].type {
                    tool.subagentTools = context.subagentTools
                    session.chatItems[i] = ChatHistoryItem(
                        id: taskToolId,
                        type: .toolCall(tool),
                        timestamp: session.chatItems[i].timestamp
                    )
                    break
                }
            }
        }
    }

    // MARK: - Subagent Event Handlers

    /// Handle subagent started event.
    ///
    /// Creates the visible `task` chatItem on the parent session if one isn't
    /// already there. The OpenCode adapter emits `subagentStarted` *in addition
    /// to* the normal `preTool(tool=task)` for the parent's task invocation, so
    /// the opencode preTool handler usually creates the chatItem first and this
    /// guard is a no-op — but if the adapter ever emits subagentStarted without
    /// a matching preTool (e.g. because of a race), the chatItem still shows up.
    private func processSubagentStarted(sessionId: String, taskToolId: String) {
        guard var session = sessions[sessionId] else { return }

        // Skip chatItem placeholder for append-order providers — the
        // adapter's JSONL sync creates items with correct timestamps.
        if session.provider.needsHookPlaceholders {
            if !session.chatItems.contains(where: { $0.id == taskToolId }) {
                session.chatItems.append(
                    ChatHistoryItem(
                        id: taskToolId,
                        type: .toolCall(ToolCallItem(
                            name: "task",
                            input: [:],
                            status: .running,
                            result: nil,
                            structuredResult: nil,
                            subagentTools: []
                        )),
                        timestamp: Date()
                    )
                )
            }
        }
        session.subagentState.startTask(taskToolId: taskToolId)
        sessions[sessionId] = session
    }

    /// Handle subagent tool executed event
    private func processSubagentToolExecuted(sessionId: String, tool: SubagentToolCall) {
        guard var session = sessions[sessionId] else { return }
        session.subagentState.addSubagentTool(tool)
        // Sync to chatItems so the UI updates live (rather than only after
        // the parent subagent stops). Mirrors processSubagentTracking
        // (Claude hooks path) at line 1025 — without this, opencode
        // subagent tools sit in subagentState and never make it to the
        // chatItem's subagentTools array, so the UI shows the task row
        // without the expand list. See #74.
        syncSubagentToolsToChatItems(session: &session)
        sessions[sessionId] = session
        // DIAGNOSTIC (#74): confirm subagent tool flowed state → chatItem.
        // stateCount = total subagent tools in the active task context.
        // maxChatItemCount = max subagentTools count across all task chatItems
        // (lets us verify the sync actually wrote to the right chatItem).
        let stateCount = session.subagentState.activeTasks.values
            .flatMap { $0.subagentTools }
            .filter { $0.id == tool.id }
            .count
        let maxChatItemCount = session.chatItems.compactMap { item -> Int? in
            if case .toolCall(let t) = item.type { return t.subagentTools.count }
            return nil
        }.max() ?? -1
        DebugLog.shared.write("[session-store] subagent tool executed session=\(sessionId) toolId=\(tool.id) name=\(tool.name) stateCount=\(stateCount) maxChatItemCount=\(maxChatItemCount)")
    }

    /// Handle subagent tool completed event
    private func processSubagentToolCompleted(sessionId: String, toolId: String, status: ToolStatus) {
        guard var session = sessions[sessionId] else { return }
        session.subagentState.updateSubagentToolStatus(toolId: toolId, status: status)
        // Sync the status update to chatItems. See #74.
        syncSubagentToolsToChatItems(session: &session)
        sessions[sessionId] = session
        // DIAGNOSTIC (#74): confirm subagent tool status flowed state → chatItem
        let stateStatus = session.subagentState.activeTasks.values
            .flatMap { $0.subagentTools }
            .first(where: { $0.id == toolId })?.status.description ?? "?"
        DebugLog.shared.write("[session-store] subagent tool completed session=\(sessionId) toolId=\(toolId) stateStatus=\(stateStatus)")
    }

    /// Handle subagent stopped event
    private func processSubagentStopped(sessionId: String, taskToolId: String) {
        guard var session = sessions[sessionId] else { return }
        session.subagentState.stopTask(taskToolId: taskToolId)
        sessions[sessionId] = session
        // Subagent tools will be populated from agent file in processFileUpdated
    }

    /// Parse ISO8601 timestamp string
    private func parseTimestamp(_ timestampStr: String?) -> Date? {
        guard let str = timestampStr else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: str)
    }

    // MARK: - Permission Processing

    private func processPermissionApproved(sessionId: String, toolUseId: String) async {
        guard var session = sessions[sessionId] else { return }

        // Update tool status in chat history first
        updateToolStatus(in: &session, toolId: toolUseId, status: .running)

        // Check if there are other tools still waiting for approval
        if let nextPending = findNextPendingTool(in: session, excluding: toolUseId) {
            // Another tool is waiting - stay in waitingForApproval with that tool's context
            let newPhase = SessionPhase.waitingForApproval(PermissionContext(
                toolUseId: nextPending.id,
                toolName: nextPending.name,
                toolInput: nil,  // We don't have the input stored in chatItems
                receivedAt: nextPending.timestamp
            ))
            if session.phase.canTransition(to: newPhase) {
                session.phase = newPhase
                Self.logger.debug("Switched to next pending tool: \(nextPending.id.prefix(12), privacy: .public)")
            }
        } else {
            // No more pending tools - transition to processing
            if case .waitingForApproval(let ctx) = session.phase, ctx.toolUseId == toolUseId {
                if session.phase.canTransition(to: .processing) {
                    session.phase = .processing
                }
            } else if case .waitingForApproval = session.phase {
                // The approved tool wasn't the one in phase context, but no others pending
                // This can happen if tools were approved out of order
                if session.phase.canTransition(to: .processing) {
                    session.phase = .processing
                }
            }
        }

        sessions[sessionId] = session
    }

    // MARK: - Tool Completion Processing

    /// Process a tool completion event (from JSONL detection)
    /// This is the authoritative handler for tool completions - ensures consistent state updates
    private func processToolCompleted(sessionId: String, toolUseId: String, result: ToolCompletionResult) async {
        guard var session = sessions[sessionId] else { return }

        // Check if this tool is already completed (avoid duplicate processing)
        if let existingItem = session.chatItems.first(where: { $0.id == toolUseId }),
           case .toolCall(let tool) = existingItem.type,
           tool.status == .success || tool.status == .error || tool.status == .interrupted {
            // Already completed, skip
            return
        }

        // Update the tool status
        for i in 0..<session.chatItems.count {
            if session.chatItems[i].id == toolUseId,
               case .toolCall(var tool) = session.chatItems[i].type {
                tool.status = result.status
                tool.result = result.result
                tool.structuredResult = result.structuredResult
                session.chatItems[i] = ChatHistoryItem(
                    id: toolUseId,
                    type: .toolCall(tool),
                    timestamp: session.chatItems[i].timestamp
                )
                Self.logger.debug("Tool \(toolUseId.prefix(12), privacy: .public) completed with status: \(String(describing: result.status), privacy: .public)")
                break
            }
        }

        // Update session phase if needed
        // If the completed tool was the one in the phase context, switch to next pending or processing
        if case .waitingForApproval(let ctx) = session.phase, ctx.toolUseId == toolUseId {
            if let nextPending = findNextPendingTool(in: session, excluding: toolUseId) {
                let newPhase = SessionPhase.waitingForApproval(PermissionContext(
                    toolUseId: nextPending.id,
                    toolName: nextPending.name,
                    toolInput: nil,
                    receivedAt: nextPending.timestamp
                ))
                session.phase = newPhase
                Self.logger.debug("Switched to next pending tool after completion: \(nextPending.id.prefix(12), privacy: .public)")
            } else {
                if session.phase.canTransition(to: .processing) {
                    session.phase = .processing
                }
            }
        }

        sessions[sessionId] = session
    }

    /// Find the next tool waiting for approval (excluding a specific tool ID)
    private func findNextPendingTool(in session: SessionState, excluding toolId: String) -> (id: String, name: String, timestamp: Date)? {
        for item in session.chatItems {
            if item.id == toolId { continue }
            if case .toolCall(let tool) = item.type, tool.status == .waitingForApproval {
                return (id: item.id, name: tool.name, timestamp: item.timestamp)
            }
        }
        return nil
    }

    private func processPermissionDenied(sessionId: String, toolUseId: String, reason: String?) async {
        guard var session = sessions[sessionId] else { return }

        // Update tool status in chat history first
        updateToolStatus(in: &session, toolId: toolUseId, status: .error)

        // Check if there are other tools still waiting for approval
        if let nextPending = findNextPendingTool(in: session, excluding: toolUseId) {
            // Another tool is waiting - stay in waitingForApproval with that tool's context
            let newPhase = SessionPhase.waitingForApproval(PermissionContext(
                toolUseId: nextPending.id,
                toolName: nextPending.name,
                toolInput: nil,
                receivedAt: nextPending.timestamp
            ))
            if session.phase.canTransition(to: newPhase) {
                session.phase = newPhase
                Self.logger.debug("Switched to next pending tool after denial: \(nextPending.id.prefix(12), privacy: .public)")
            }
        } else {
            // No more pending tools - transition to processing (Claude will handle denial)
            if case .waitingForApproval(let ctx) = session.phase, ctx.toolUseId == toolUseId {
                if session.phase.canTransition(to: .processing) {
                    session.phase = .processing
                }
            } else if case .waitingForApproval = session.phase {
                // The denied tool wasn't the one in phase context, but no others pending
                if session.phase.canTransition(to: .processing) {
                    session.phase = .processing
                }
            }
        }

        sessions[sessionId] = session
    }

    private func processSocketFailure(sessionId: String, toolUseId: String) async {
        guard var session = sessions[sessionId] else { return }

        // Mark the failed tool's status as error
        updateToolStatus(in: &session, toolId: toolUseId, status: .error)

        // Check if there are other tools still waiting for approval
        if let nextPending = findNextPendingTool(in: session, excluding: toolUseId) {
            // Another tool is waiting - switch to that tool's context
            let newPhase = SessionPhase.waitingForApproval(PermissionContext(
                toolUseId: nextPending.id,
                toolName: nextPending.name,
                toolInput: nil,
                receivedAt: nextPending.timestamp
            ))
            if session.phase.canTransition(to: newPhase) {
                session.phase = newPhase
                Self.logger.debug("Switched to next pending tool after socket failure: \(nextPending.id.prefix(12), privacy: .public)")
            }
        } else {
            // No more pending tools - clear permission state
            if case .waitingForApproval(let ctx) = session.phase, ctx.toolUseId == toolUseId {
                session.phase = .idle
            } else if case .waitingForApproval = session.phase {
                // The failed tool wasn't in phase context, but no others pending
                session.phase = .idle
            }
        }

        sessions[sessionId] = session
    }

    // MARK: - File Update Processing

    private func processFileUpdate(_ payload: FileUpdatePayload) async {
        guard var session = sessions[payload.sessionId] else { return }

        DebugLog.shared.write("[claude-file-update] session=\(payload.sessionId) msgs=\(payload.messages.count) incremental=\(payload.isIncremental) completedTools=\(payload.completedToolIds.count)")

        // Update conversationInfo from JSONL (summary, lastMessage, etc.)
        let conversationInfo = await ConversationParser.shared.parse(
            sessionId: payload.sessionId,
            cwd: session.cwd
        )
        session.conversationInfo = conversationInfo

        // Handle /clear reconciliation - remove items that no longer exist in parser state
        if session.needsClearReconciliation {
            // Build set of valid IDs from the payload messages
            var validIds = Set<String>()
            for message in payload.messages {
                for (blockIndex, block) in message.content.enumerated() {
                    switch block {
                    case .toolUse(let tool):
                        validIds.insert(tool.id)
                    case .text, .thinking, .image, .interrupted:
                        let itemId = "\(message.id)-\(block.typePrefix)-\(blockIndex)"
                        validIds.insert(itemId)
                    }
                }
            }

            // Filter chatItems to only keep valid items OR items that are very recent
            // (within last 2 seconds - these are hook-created placeholders for post-clear tools)
            let cutoffTime = Date().addingTimeInterval(-2)
            let previousCount = session.chatItems.count
            session.chatItems = session.chatItems.filter { item in
                validIds.contains(item.id) || item.timestamp > cutoffTime
            }

            // Also reset tool tracker
            session.toolTracker = ToolTracker()
            session.subagentState = SubagentState()

            session.needsClearReconciliation = false
            Self.logger.debug("Clear reconciliation: kept \(session.chatItems.count) of \(previousCount) items")
        }

        // Persist clear reconciliation before applying adapter updates,
        // so applyChatItemUpdate() sees the filtered chatItems.
        sessions[payload.sessionId] = session

        // Use ClaudeChatItemAdapter instead of upsertBlocks.
        // Sorting is handled by ChatItemSorter in applyChatItemUpdate().
        let chatUpdates = ClaudeChatItemAdapter.updates(fromFileUpdate: payload)
        let typeCounts = Dictionary(grouping: chatUpdates, by: { "\($0.block)".prefix(20) }).mapValues(\.count)
        DebugLog.shared.write("[claude-file-update] session=\(payload.sessionId) adapterUpdates=\(chatUpdates.count) types=\(typeCounts)")
        for update in chatUpdates {
            applyChatItemUpdate(update)
        }

        // Re-fetch session — applyChatItemUpdate may have modified it.
        guard var currentSession = sessions[payload.sessionId] else { return }
        currentSession.toolTracker.lastSyncTime = Date()

        await populateSubagentToolsFromAgentFiles(
            sessionId: payload.sessionId,
            session: &currentSession,
            cwd: payload.cwd,
            structuredResults: payload.structuredResults
        )

        sessions[payload.sessionId] = currentSession

        await emitToolCompletionEvents(
            sessionId: payload.sessionId,
            session: currentSession,
            completedToolIds: payload.completedToolIds,
            toolResults: payload.toolResults,
            structuredResults: payload.structuredResults
        )
    }

    /// Populate subagent tools for Task/Agent tools using their agent JSONL files
    private func populateSubagentToolsFromAgentFiles(
        sessionId: String,
        session: inout SessionState,
        cwd: String,
        structuredResults: [String: ToolResultData]
    ) async {
        for i in 0..<session.chatItems.count {
            guard case .toolCall(var tool) = session.chatItems[i].type,
                  tool.isSubagentContainer,
                  let structuredResult = structuredResults[session.chatItems[i].id],
                  case .task(let taskResult) = structuredResult,
                  !taskResult.agentId.isEmpty else { continue }

            let taskToolId = session.chatItems[i].id

            // Store agentId → description mapping for AgentOutputTool display
            if let description = session.subagentState.activeTasks[taskToolId]?.description {
                session.subagentState.agentDescriptions[taskResult.agentId] = description
            } else if let description = tool.input["description"] {
                session.subagentState.agentDescriptions[taskResult.agentId] = description
            }

            let subagentToolInfos = await ConversationParser.shared.parseSubagentTools(
                sessionId: sessionId,
                agentId: taskResult.agentId,
                cwd: cwd
            )

            guard !subagentToolInfos.isEmpty else { continue }

            tool.subagentTools = subagentToolInfos.map { info in
                SubagentToolCall(
                    id: info.id,
                    name: info.name,
                    input: info.input,
                    status: info.isCompleted ? .success : .running,
                    timestamp: parseTimestamp(info.timestamp) ?? Date()
                )
            }

            session.chatItems[i] = ChatHistoryItem(
                id: taskToolId,
                type: .toolCall(tool),
                timestamp: session.chatItems[i].timestamp
            )

            Self.logger.debug("Populated \(subagentToolInfos.count) subagent tools for Task \(taskToolId.prefix(12), privacy: .public) from agent \(taskResult.agentId.prefix(8), privacy: .public)")
        }
    }

    /// Emit toolCompleted events for tools that have results in JSONL but aren't marked complete yet
    private func emitToolCompletionEvents(
        sessionId: String,
        session: SessionState,
        completedToolIds: Set<String>,
        toolResults: [String: ConversationParser.ToolResult],
        structuredResults: [String: ToolResultData]
    ) async {
        for item in session.chatItems {
            guard case .toolCall(let tool) = item.type else { continue }

            // Only emit for tools that are running or waiting but have results in JSONL
            guard tool.status == .running || tool.status == .waitingForApproval else { continue }
            guard completedToolIds.contains(item.id) else { continue }

            let result = ToolCompletionResult.from(
                parserResult: toolResults[item.id],
                structuredResult: structuredResults[item.id]
            )

            // Process the completion event (this will update state and phase consistently)
            await process(.toolCompleted(sessionId: sessionId, toolUseId: item.id, result: result))
        }
    }

    private func updateToolStatus(in session: inout SessionState, toolId: String, status: ToolStatus) {
        var found = false
        for i in 0..<session.chatItems.count {
            if session.chatItems[i].id == toolId,
               case .toolCall(var tool) = session.chatItems[i].type {
                let prevStatus = tool.status
                // DIAGNOSTIC (#14): log every status transition so we can
                // verify whether the .waitingForApproval placeholder for
                // AskUserQuestion ever gets cleared after denial.
                DebugLog.shared.write("[hook-tool-status] update session=\(session.sessionId) toolUseId=\(toolId) prevStatus=\(prevStatus) newStatus=\(status)")
                tool.status = status
                session.chatItems[i] = ChatHistoryItem(
                    id: toolId,
                    type: .toolCall(tool),
                    timestamp: session.chatItems[i].timestamp
                )
                found = true
                break
            }
        }
        if !found {
            let count = session.chatItems.count
            Self.logger.warning("Tool \(toolId.prefix(16), privacy: .public) not found in chatItems (count: \(count))")
            // DIAGNOSTIC (#14): log when updateToolStatus can't find the
            // target tool — likely culprit for "stuck on Waiting for
            // approval" if PermissionRequest updates a toolUseId that
            // PreToolUse never created (mismatch / out-of-order).
            DebugLog.shared.write("[hook-tool-status] update-miss session=\(session.sessionId) toolUseId=\(toolId) requestedStatus=\(status) chatItemsCount=\(count)")
        }
    }

    // MARK: - Interrupt Processing

    private func processInterrupt(sessionId: String) async {
        guard var session = sessions[sessionId] else { return }

        // Clear subagent state
        session.subagentState = SubagentState()

        // Mark running tools as interrupted
        for i in 0..<session.chatItems.count {
            if case .toolCall(var tool) = session.chatItems[i].type,
               tool.status == .running {
                tool.status = .interrupted
                session.chatItems[i] = ChatHistoryItem(
                    id: session.chatItems[i].id,
                    type: .toolCall(tool),
                    timestamp: session.chatItems[i].timestamp
                )
            }
        }

        // Transition to idle
        if session.phase.canTransition(to: .idle) {
            session.phase = .idle
        }

        sessions[sessionId] = session
        publishState()
    }

    // MARK: - Clear Processing

    private func processClearDetected(sessionId: String) async {
        guard var session = sessions[sessionId] else { return }

        Self.logger.info("Processing /clear for session \(sessionId.prefix(8), privacy: .public)")

        // Mark that a clear happened - the next fileUpdated will reconcile
        // by removing items that no longer exist in the parser's state
        session.needsClearReconciliation = true
        sessions[sessionId] = session

        Self.logger.info("/clear processed for session \(sessionId.prefix(8), privacy: .public) - marked for reconciliation")
    }

    // MARK: - Session End Processing

    private func processSessionEnd(sessionId: String) async {
        sessions.removeValue(forKey: sessionId)
        cancelPendingSync(sessionId: sessionId)
        cancelPendingCodexCompletionNotification(sessionId: sessionId)
        codexTranscriptLowerBounds.removeValue(forKey: sessionId)
    }

    // MARK: - History Loading

    private func loadHistoryFromFile(sessionId: String, cwd: String) async {
        if sessions[sessionId]?.provider == .codex {
            await syncCodexTranscript(sessionId: sessionId)
            return
        }
        if sessions[sessionId]?.provider == .cursor {
            return
        }

        // Parse file asynchronously
        let messages = await ConversationParser.shared.parseFullConversation(
            sessionId: sessionId,
            cwd: cwd
        )
        let completedTools = await ConversationParser.shared.completedToolIds(for: sessionId)
        let toolResults = await ConversationParser.shared.toolResults(for: sessionId)
        let structuredResults = await ConversationParser.shared.structuredResults(for: sessionId)

        // Also parse conversationInfo (summary, lastMessage, etc.)
        let conversationInfo = await ConversationParser.shared.parse(
            sessionId: sessionId,
            cwd: cwd
        )

        // Process loaded history
        await process(.historyLoaded(
            sessionId: sessionId,
            messages: messages,
            completedTools: completedTools,
            toolResults: toolResults,
            structuredResults: structuredResults,
            conversationInfo: conversationInfo
        ))
    }

    private func processHistoryLoaded(
        sessionId: String,
        messages: [ChatMessage],
        completedTools: Set<String>,
        toolResults: [String: ConversationParser.ToolResult],
        structuredResults: [String: ToolResultData],
        conversationInfo: ConversationInfo
    ) async {
        guard var session = sessions[sessionId] else { return }

        DebugLog.shared.write("[claude-history-loaded] session=\(sessionId) msgs=\(messages.count) completedTools=\(completedTools.count)")

        // Update conversationInfo (summary, lastMessage, etc.)
        session.conversationInfo = conversationInfo

        // Use ClaudeChatItemAdapter instead of upsertBlocks.
        // Sorting is handled by ChatItemSorter in applyChatItemUpdate().
        sessions[sessionId] = session

        let chatUpdates = ClaudeChatItemAdapter.updates(
            fromHistoryLoad: messages,
            completedTools: completedTools,
            toolResults: toolResults,
            structuredResults: structuredResults,
            sessionId: sessionId
        )
        for update in chatUpdates {
            applyChatItemUpdate(update)
        }
    }

    private func syncCodexTranscript(sessionId: String) async {
        guard !shouldIgnoreCodexSession(sessionId) else { return }

        let updates = await CodexTranscriptParser.loadUpdates(
            sessionId: sessionId,
            after: codexTranscriptLowerBounds[sessionId]
        )
        guard !updates.isEmpty else { return }

        DebugLog.shared.write("[codex-transcript-sync] session=\(sessionId) updates=\(updates.count)")
        for update in updates {
            applyChatItemUpdate(update)
        }
        publishState()
    }

    private func scheduleCodexTranscriptSync(sessionId: String) {
        cancelPendingSync(sessionId: sessionId)

        pendingSyncs[sessionId] = Task { [weak self, syncDebounceNs] in
            try? await Task.sleep(nanoseconds: syncDebounceNs)
            guard !Task.isCancelled else { return }
            await self?.syncCodexTranscript(sessionId: sessionId)
        }
    }

    // MARK: - File Sync Scheduling

    private func scheduleFileSync(sessionId: String, cwd: String) {
        // Cancel existing sync
        cancelPendingSync(sessionId: sessionId)

        // Schedule new debounced sync
        pendingSyncs[sessionId] = Task { [weak self, syncDebounceNs] in
            try? await Task.sleep(nanoseconds: syncDebounceNs)
            guard !Task.isCancelled else { return }

            // Parse incrementally - only get NEW messages since last call
            let result = await ConversationParser.shared.parseIncremental(
                sessionId: sessionId,
                cwd: cwd
            )

            if result.clearDetected {
                await self?.process(.clearDetected(sessionId: sessionId))
            }

            guard !result.newMessages.isEmpty || result.clearDetected else {
                return
            }

            let payload = FileUpdatePayload(
                sessionId: sessionId,
                cwd: cwd,
                messages: result.newMessages,
                isIncremental: !result.clearDetected,
                completedToolIds: result.completedToolIds,
                toolResults: result.toolResults,
                structuredResults: result.structuredResults
            )

            await self?.process(.fileUpdated(payload))
        }
    }

    private func cancelPendingSync(sessionId: String) {
        pendingSyncs[sessionId]?.cancel()
        pendingSyncs.removeValue(forKey: sessionId)
    }

    // MARK: - Periodic Status Check

    /// Start periodic status checking for all sessions
    func startPeriodicStatusCheck() {
        guard statusCheckTask == nil else { return }

        let intervalSeconds = statusCheckIntervalSeconds
        statusCheckTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: intervalSeconds * 1_000_000_000)
                guard !Task.isCancelled else { break }
                await self?.recheckAllSessions()
            }
        }
        Self.logger.info("Started periodic status check (every \(intervalSeconds)s)")
    }

    /// Stop periodic status checking
    func stopPeriodicStatusCheck() {
        statusCheckTask?.cancel()
        statusCheckTask = nil
        Self.logger.info("Stopped periodic status check")
    }

    /// Recheck status of all active sessions
    private func recheckAllSessions() {
        var stateChanged = false
        let now = Date()

        for (sessionId, session) in Array(sessions) {
            if session.phase == .ended {
                sessions.removeValue(forKey: sessionId)
                cancelPendingSync(sessionId: sessionId)
                cancelPendingCodexCompletionNotification(sessionId: sessionId)
                codexTranscriptLowerBounds.removeValue(forKey: sessionId)
                stateChanged = true
                continue
            }

            if session.provider == .codex,
               session.phase == .idle,
               now.timeIntervalSince(session.lastActivity) > codexIdleExpirationSeconds {
                sessions.removeValue(forKey: sessionId)
                cancelPendingCodexCompletionNotification(sessionId: sessionId)
                codexTranscriptLowerBounds.removeValue(forKey: sessionId)
                stateChanged = true
                continue
            }

            if session.provider == .codex,
               session.phase.isActive {
                let quietDuration = now.timeIntervalSince(session.lastActivity)
                let quietLimit = hasRunningTools(in: session)
                    ? codexRunningToolQuietExpirationSeconds
                    : codexActiveQuietExpirationSeconds

                if quietDuration > quietLimit {
                    var updatedSession = session
                    Self.logger.info("Codex session \(sessionId.prefix(8), privacy: .public) active state expired after \(Int(quietDuration), privacy: .public)s quiet; marking idle")
                    updatedSession.phase = .idle
                    updatedSession.completionNotificationAt = nil
                    updatedSession.toolTracker.inProgress.removeAll()
                    sessions[sessionId] = updatedSession
                    stateChanged = true
                    continue
                }
            }

            if let pid = session.pid {
                let isRunning = isProcessRunning(pid: pid)
                if !isRunning {
                    Self.logger.info("Process \(pid) no longer running, ending session \(sessionId.prefix(8))")
                    sessions.removeValue(forKey: sessionId)
                    cancelPendingSync(sessionId: sessionId)
                    cancelPendingCodexCompletionNotification(sessionId: sessionId)
                    codexTranscriptLowerBounds.removeValue(forKey: sessionId)
                    stateChanged = true
                    continue
                }
            }

            let needsSync: Bool
            switch (session.provider, session.phase) {
            case (.claude, .processing), (.claude, .waitingForApproval):
                needsSync = true
            default:
                needsSync = false
            }
            if needsSync {
                scheduleFileSync(sessionId: sessionId, cwd: session.cwd)
            }
        }

        if stateChanged {
            publishState()
        }
    }

    /// Check if a process is still running
    private nonisolated func isProcessRunning(pid: Int) -> Bool {
        return kill(Int32(pid), 0) == 0
    }

    // MARK: - State Publishing

    private func publishState() {
        let sortedSessions = Array(sessions.values).sorted { $0.projectName < $1.projectName }
        sessionsSubject.send(sortedSessions)
    }

    // MARK: - Queries

    /// Get a specific session
    func session(for sessionId: String) -> SessionState? {
        sessions[sessionId]
    }

    /// Check if there's an active permission for a session
    func hasActivePermission(sessionId: String) -> Bool {
        guard let session = sessions[sessionId] else { return false }
        if case .waitingForApproval = session.phase {
            return true
        }
        return false
    }

    /// Get all current sessions
    func allSessions() -> [SessionState] {
        Array(sessions.values)
    }
}
