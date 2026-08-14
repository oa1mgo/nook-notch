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

    /// In-memory transcript lower bounds after Codex `/clear`. Codex transcript
    /// format is not a stable API, so use it only for explicit history loads.
    private var codexTranscriptLowerBounds: [String: Date] = [:]

    /// Codex can deliver trailing PostToolUse/PostCompact-style hooks after Stop.
    /// Keep a short tombstone so those late events cannot reactivate a completed
    /// user-facing session or recreate a hidden internal session.
    private var recentlyStoppedCodexSessions: [String: Date] = [:]

    /// Codex Desktop can run startup/background suggestion prompts in the same
    /// project. They emit hooks but are not user-facing conversations.
    private var pendingCodexStartupSessions: Set<String> = []
    private var ignoredCodexSessions: Set<String> = []

    /// pid → server port, for multi-instance opencode. Sessions bind their
    /// serverPort from the pid that enrichOpencodeRuntimeMetadata resolves.
    private var opencodeServerPorts: [Int: Int] = [:]
    /// Legacy fallback: port from a plugin that reports no pid, or from probe.
    private var opencodeServerPortFallback: Int?

    /// Running OpenCode plugin version, reported by the plugin in the serverPort
    /// handshake. Used to detect when OpenCode is still running a stale plugin
    /// (running version != installed version in the settings UI).
    private var opencodePluginVersion: String?

    /// Sync debounce interval (100ms)
    private let syncDebounceNs: UInt64 = 100_000_000

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
    private let codexLateEventIgnoreSeconds: TimeInterval = 10

    /// BlockOrdering keys for chat items (from unified ChatItemUpdate path).
    /// Maps chatItem.id → BlockOrdering so ChatItemSorter can maintain
    /// correct display order regardless of event arrival timing.
    private var blockOrderings: [String: BlockOrdering] = [:]

    /// Sessions that have been explicitly opened via a `SessionStarted`
    /// event (or via Claude's hook path). The `realtimeChatItemBatch` /
    /// `chatItemBatch` / `chatItemUpdate` entry points filter against this
    /// set: chat-item updates for unknown sessionIds are dropped instead of
    /// being auto-promoted to a top-level `SessionState`. This is the
    /// contract that keeps subagent child sessions (which never emit a
    /// SessionStarted because `OpencodeHookAdapter.adaptSubagentEvent`
    /// short-circuits subagent events) from materializing as standalone
    /// sessions in the UI. See docs/debug/2026-07-23-subagent-cleanup-bug.md.
    private var registeredSessionIds: Set<String> = []

    /// Buffer for chat-item updates that arrive before their session is registered.
    /// Subagent child sessions are intentionally never registered (they don't emit
    /// SessionStarted), so their buffered updates are naturally dropped. Top-level
    /// sessions get registered via processOpencodeSessionStart and flush their buffer.
    private var earlyChatItemBuffer: [String: [ChatItemUpdate]] = [:]

    // MARK: - Published State (for UI)

    /// Publisher for session state changes (nonisolated for Combine subscription from any context)
    private nonisolated(unsafe) let sessionsSubject = CurrentValueSubject<[SessionState], Never>([])

    /// One-shot completion notifications for UI affordances like sound/bounce.
    private nonisolated(unsafe) let completionNotificationsSubject = PassthroughSubject<SessionCompletionNotification, Never>()

    /// Current running OpenCode plugin version (nil until the plugin handshake).
    private nonisolated(unsafe) let opencodePluginVersionSubject = CurrentValueSubject<String?, Never>(nil)

    /// Public publisher for UI subscription
    nonisolated var sessionsPublisher: AnyPublisher<[SessionState], Never> {
        sessionsSubject.eraseToAnyPublisher()
    }

    /// Public completion notification stream for UI-only affordances.
    nonisolated var completionNotificationsPublisher: AnyPublisher<SessionCompletionNotification, Never> {
        completionNotificationsSubject.eraseToAnyPublisher()
    }

    /// Current running OpenCode plugin version stream (nil until known).
    nonisolated var opencodePluginVersionPublisher: AnyPublisher<String?, Never> {
        opencodePluginVersionSubject.eraseToAnyPublisher()
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
            registerSession(sessionId: sessionId)
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
            registerSession(sessionId: sessionId)
            processOpencodeSessionStart(sessionId: sessionId, cwd: cwd)

        case .opencodeProcessingStarted(let sessionId, let cwd):
            processOpencodeProcessingStarted(sessionId: sessionId, cwd: cwd)

        case .opencodeWaitingForUserInput(let sessionId, let cwd):
            processOpencodeWaitingForUserInput(sessionId: sessionId, cwd: cwd)

        case .opencodeStopped(let sessionId, let cwd):
            processOpencodeStop(sessionId: sessionId, cwd: cwd)

        case .opencodePermissionRequested(let sessionId, let cwd, let permission, let requestId, let toolUseId, let input, let inputSummary, let alwaysPatterns):
            processOpencodePermissionRequested(
                sessionId: sessionId, cwd: cwd, permission: permission,
                requestId: requestId, toolUseId: toolUseId,
                input: input, inputSummary: inputSummary,
                alwaysPatterns: alwaysPatterns
            )

        case .opencodePromptSubmitted(let sessionId, let cwd, let prompt):
            processOpencodePromptSubmitted(sessionId: sessionId, cwd: cwd, prompt: prompt)

        case .opencodeServerPortReceived(let sessionId, let port, let version, let pid):
            processOpencodeServerPortReceived(sessionId: sessionId, port: port, version: version, pid: pid)

        case .cursorSessionStarted(let sessionId, let cwd):
            registerSession(sessionId: sessionId)
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
            applyChatItemUpdateIfRegistered(update)
            publishState()

        case .chatItemBatch(let updates):
            for update in updates {
                applyChatItemUpdateIfRegistered(update)
            }
            publishState()

        case .realtimeChatItemBatch(let updates):
            for update in updates {
                applyChatItemUpdateIfRegistered(update, appliesLifecycleEffects: true)
            }
            publishState()

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

    // MARK: - Session Registration

    /// Mark a sessionId as a known top-level session. Called from each
    /// `SessionStarted` branch in `process(_:)` and from `processHookEvent`
    /// (Claude) when it first creates a session. See `registeredSessionIds`.
    private func registerSession(sessionId: String) {
        registeredSessionIds.insert(sessionId)
        // Flush any chat-item updates that arrived before session registration.
        // This handles the race condition where opencode sends chat items
        // (e.g. image) before the sessionStart event.
        if let buffered = earlyChatItemBuffer.removeValue(forKey: sessionId) {
            writeDebugLogAsync("[chat-item-update] flushing \(buffered.count) buffered updates for session=\(sessionId.prefix(12))")
            for update in buffered {
                applyChatItemUpdate(update, appliesLifecycleEffects: true)
            }
        }
    }

    /// Drop `sessionId` from the registered set — typically called when the
    /// session is removed (processSessionEnd, claude `status=ended`, etc.).
    private func unregisterSession(sessionId: String) {
        registeredSessionIds.remove(sessionId)
        earlyChatItemBuffer.removeValue(forKey: sessionId)
    }

    /// Filtered wrapper around `applyChatItemUpdate`: drops updates for
    /// sessionIds that have never been explicitly registered, instead of
    /// letting `applyChatItemUpdate`'s auto-create path materialize a fresh
    /// top-level `SessionState`. Subagent child sessions rely on this to
    /// stay invisible — they leak chat-item events (e.g. reasoning parts)
    /// when `OpencodeHookAdapter`'s `cleanupState` fires prematurely, and
    /// we must not promote those leaks to standalone sessions.
    private func applyChatItemUpdateIfRegistered(
        _ update: ChatItemUpdate,
        appliesLifecycleEffects: Bool = false
    ) {
        if !registeredSessionIds.contains(update.sessionId) {
            // Buffer early chat-item updates instead of dropping them.
            // They will be flushed when the session is registered via processOpencodeSessionStart.
            // Subagent child sessions are never registered, so their buffers
            // are never flushed (and get cleaned up on session end).
            earlyChatItemBuffer[update.sessionId, default: []].append(update)
            writeDebugLogAsync("[chat-item-update] buffered for unregistered session=\(update.sessionId.prefix(12)) id=\(update.id.prefix(16)) bufferCount=\(earlyChatItemBuffer[update.sessionId]?.count ?? 0)")
            return
        }
        applyChatItemUpdate(update, appliesLifecycleEffects: appliesLifecycleEffects)
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
            registerSession(sessionId: sessionId)
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
            unregisterSession(sessionId: sessionId)
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
        registerSession(sessionId: event.sessionId)
        return SessionState(
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
        registerSession(sessionId: sessionId)
        return SessionState(
            sessionId: sessionId,
            provider: .codex,
            cwd: cwd,
            projectName: URL(fileURLWithPath: cwd).lastPathComponent,
            phase: .idle
        )
    }

    private func shouldIgnoreCodexSession(_ sessionId: String) -> Bool {
        if ignoredCodexSessions.contains(sessionId) {
            return true
        }

        if CodexTranscriptParser.isSubagentSession(sessionId: sessionId) {
            ignoredCodexSessions.insert(sessionId)
            return true
        }

        return false
    }

    private func normalizedCodexSource(_ source: String?) -> String? {
        let normalized = source?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return normalized?.isEmpty == false ? normalized : nil
    }

    private func isCodexInternalStartupPrompt(_ prompt: String?) -> Bool {
        guard let prompt else { return false }
        let normalized = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.contains("Generate 0 to 3 hyperpersonalized suggestions")
            && normalized.contains("Return 0 to 3 fresh suggestions")
            && normalized.contains("Recent Codex threads in this project")
    }

    private func shouldDeferPendingCodexStartupEvent(sessionId: String, eventName: String) -> Bool {
        guard pendingCodexStartupSessions.contains(sessionId) else { return false }
        writeDebugLogAsync("[codex-lifecycle] deferred pending startup event session=\(sessionId) event=\(eventName)")
        return true
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

    private func markCodexSessionStopped(sessionId: String, at date: Date = Date()) {
        recentlyStoppedCodexSessions[sessionId] = date
    }

    private func clearCodexStoppedMarker(sessionId: String) {
        recentlyStoppedCodexSessions.removeValue(forKey: sessionId)
    }

    private func shouldDropLateCodexEvent(sessionId: String, eventName: String, now: Date = Date()) -> Bool {
        guard let stoppedAt = recentlyStoppedCodexSessions[sessionId] else { return false }

        if now.timeIntervalSince(stoppedAt) <= codexLateEventIgnoreSeconds {
            writeDebugLogAsync("[codex-lifecycle] ignored late event session=\(sessionId) event=\(eventName)")
            return true
        }

        recentlyStoppedCodexSessions.removeValue(forKey: sessionId)
        return false
    }

    private func processCodexSessionStart(sessionId: String, cwd: String, source: String?) {
        guard shouldProcessProviderSession(sessionId: sessionId, provider: .codex, eventName: "sessionStart") else { return }
        let normalizedSource = normalizedCodexSource(source)
        if normalizedSource == "startup", sessions[sessionId] == nil {
            pendingCodexStartupSessions.insert(sessionId)
            writeDebugLogAsync("[codex-lifecycle] startup pending session=\(sessionId) cwd=\(cwd)")
            return
        }

        guard !shouldIgnoreCodexSession(sessionId) else { return }
        clearCodexStoppedMarker(sessionId: sessionId)
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
        if normalizedSource == "clear" {
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
        writeDebugLogAsync("[codex-lifecycle] sessionStart session=\(sessionId) source=\(source ?? "nil") phase=\(String(describing: session.phase)) cwd=\(session.cwd)")
    }

    private func processCodexPromptSubmitted(sessionId: String, cwd: String, prompt: String?) {
        guard shouldProcessProviderSession(sessionId: sessionId, provider: .codex, eventName: "userPromptSubmit") else { return }
        if pendingCodexStartupSessions.remove(sessionId) != nil,
           isCodexInternalStartupPrompt(prompt) {
            ignoredCodexSessions.insert(sessionId)
            sessions.removeValue(forKey: sessionId)
            cancelPendingSync(sessionId: sessionId)
            unregisterSession(sessionId: sessionId)
            writeDebugLogAsync("[codex-lifecycle] ignored internal startup session=\(sessionId)")
            return
        }

        guard !shouldIgnoreCodexSession(sessionId) else { return }
        clearCodexStoppedMarker(sessionId: sessionId)
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
        writeDebugLogAsync("[codex-lifecycle] userPromptSubmit session=\(sessionId) phase=\(String(describing: session.phase)) promptChars=\(trimmedPrompt?.count ?? 0)")
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
        guard !shouldDeferPendingCodexStartupEvent(sessionId: sessionId, eventName: "toolStarted") else { return }
        guard !shouldIgnoreCodexSession(sessionId) else { return }
        guard !shouldDropLateCodexEvent(sessionId: sessionId, eventName: "toolStarted") else { return }
        clearCodexStoppedMarker(sessionId: sessionId)
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
        writeDebugLogAsync("[codex-lifecycle] toolStarted session=\(sessionId) tool=\(toolName) toolUseId=\(toolUseId ?? "nil") phase=\(String(describing: session.phase))")
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
        guard !shouldDeferPendingCodexStartupEvent(sessionId: sessionId, eventName: "toolFinished") else { return }
        guard !shouldIgnoreCodexSession(sessionId) else { return }
        guard !shouldDropLateCodexEvent(sessionId: sessionId, eventName: "toolFinished") else { return }
        guard var session = sessions[sessionId] else {
            writeDebugLogAsync("[codex-lifecycle] ignored toolFinished missing-session session=\(sessionId) tool=\(toolName)")
            return
        }
        let now = Date()

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

        // Codex `PostToolUse` is not the end of the turn. The model may keep
        // thinking, produce text, compact, or start another tool before `Stop`.
        // Keep the visible state active until the explicit turn-scope Stop hook.
        if session.phase.canTransition(to: .processing) {
            session.phase = .processing
        }
        session.completionNotificationAt = nil

        sessions[sessionId] = session
        writeDebugLogAsync("[codex-lifecycle] toolFinished session=\(sessionId) tool=\(toolName) toolUseId=\(completedToolId ?? "nil") isError=\(isError) phase=\(String(describing: session.phase))")
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
        guard !shouldDeferPendingCodexStartupEvent(sessionId: sessionId, eventName: "permissionRequest") else { return }
        guard !shouldIgnoreCodexSession(sessionId) else { return }
        guard !shouldDropLateCodexEvent(sessionId: sessionId, eventName: "permissionRequest") else { return }
        clearCodexStoppedMarker(sessionId: sessionId)
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
        writeDebugLogAsync("[codex-lifecycle] permissionRequest session=\(sessionId) tool=\(displayToolName) toolUseId=\(resolvedToolUseId ?? "nil") phase=\(String(describing: session.phase))")
    }

    private func processCodexCompactingStarted(sessionId: String, cwd: String) {
        guard shouldProcessProviderSession(sessionId: sessionId, provider: .codex, eventName: "preCompact") else { return }
        guard !shouldDeferPendingCodexStartupEvent(sessionId: sessionId, eventName: "preCompact") else { return }
        guard !shouldIgnoreCodexSession(sessionId) else { return }
        guard !shouldDropLateCodexEvent(sessionId: sessionId, eventName: "preCompact") else { return }
        clearCodexStoppedMarker(sessionId: sessionId)
        var session = sessions[sessionId] ?? createCodexSession(sessionId: sessionId, cwd: cwd)
        enrichCodexRuntimeMetadata(session: &session)
        session.lastActivity = Date()
        session.completionNotificationAt = nil
        if session.phase.canTransition(to: .compacting) {
            session.phase = .compacting
        }
        sessions[sessionId] = session
    }

    private func processCodexCompactingFinished(sessionId: String, cwd: String) {
        guard shouldProcessProviderSession(sessionId: sessionId, provider: .codex, eventName: "postCompact") else { return }
        guard !shouldDeferPendingCodexStartupEvent(sessionId: sessionId, eventName: "postCompact") else { return }
        guard !shouldIgnoreCodexSession(sessionId) else { return }
        guard !shouldDropLateCodexEvent(sessionId: sessionId, eventName: "postCompact") else { return }
        guard var session = sessions[sessionId] else {
            writeDebugLogAsync("[codex-lifecycle] ignored postCompact missing-session session=\(sessionId)")
            return
        }
        enrichCodexRuntimeMetadata(session: &session)
        session.lastActivity = Date()
        session.completionNotificationAt = nil
        if session.phase.canTransition(to: .processing) {
            session.phase = .processing
        }
        sessions[sessionId] = session
    }

    private func processCodexSubagentStarted(sessionId: String, cwd: String) {
        guard shouldProcessProviderSession(sessionId: sessionId, provider: .codex, eventName: "subagentStart") else { return }
        guard !shouldDeferPendingCodexStartupEvent(sessionId: sessionId, eventName: "subagentStart") else { return }
        guard !shouldIgnoreCodexSession(sessionId) else { return }
        guard !shouldDropLateCodexEvent(sessionId: sessionId, eventName: "subagentStart") else { return }
        clearCodexStoppedMarker(sessionId: sessionId)
        var session = sessions[sessionId] ?? createCodexSession(sessionId: sessionId, cwd: cwd)
        enrichCodexRuntimeMetadata(session: &session)
        session.lastActivity = Date()
        session.completionNotificationAt = nil
        if session.phase.canTransition(to: .processing) {
            session.phase = .processing
        }
        sessions[sessionId] = session
    }

    private func processCodexSubagentStopped(sessionId: String, cwd: String) {
        guard shouldProcessProviderSession(sessionId: sessionId, provider: .codex, eventName: "subagentStop") else { return }
        guard !shouldDeferPendingCodexStartupEvent(sessionId: sessionId, eventName: "subagentStop") else { return }
        guard !shouldIgnoreCodexSession(sessionId) else { return }
        guard !shouldDropLateCodexEvent(sessionId: sessionId, eventName: "subagentStop") else { return }
        guard var session = sessions[sessionId] else {
            writeDebugLogAsync("[codex-lifecycle] ignored subagentStop missing-session session=\(sessionId)")
            return
        }
        enrichCodexRuntimeMetadata(session: &session)
        session.lastActivity = Date()
        session.completionNotificationAt = nil
        if session.phase.canTransition(to: .processing) {
            session.phase = .processing
        }
        sessions[sessionId] = session
    }

    private func processCodexStop(sessionId: String, cwd: String) {
        guard shouldProcessProviderSession(sessionId: sessionId, provider: .codex, eventName: "stop") else { return }
        pendingCodexStartupSessions.remove(sessionId)
        if ignoredCodexSessions.contains(sessionId) {
            writeDebugLogAsync("[codex-lifecycle] ignored stop for hidden session=\(sessionId)")
            return
        }
        guard !shouldIgnoreCodexSession(sessionId) else { return }
        markCodexSessionStopped(sessionId: sessionId)
        guard var session = sessions[sessionId] else {
            writeDebugLogAsync("[codex-lifecycle] stop ignored missing-session session=\(sessionId)")
            return
        }
        enrichCodexRuntimeMetadata(session: &session)
        session.lastActivity = Date()
        session.phase = .idle
        session.completionNotificationAt = nil
        finishDanglingCodexTools(in: &session)
        session.toolTracker.inProgress.removeAll()
        writeDebugLogAsync("[codex-lifecycle] stop session=\(sessionId) phase=\(String(describing: session.phase)) chatItems=\(session.chatItems.count)")
        sessions[sessionId] = session
        publishCompletionNotification(for: session)
        pendingCodexStartupSessions.remove(sessionId)
    }

    // MARK: - OpenCode Session Processing

    private func createOpencodeSession(sessionId: String, cwd: String) -> SessionState {
        registerSession(sessionId: sessionId)
        return SessionState(
            sessionId: sessionId,
            provider: .opencode,
            cwd: cwd,
            projectName: URL(fileURLWithPath: cwd).lastPathComponent,
            serverPort: nil,
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

        // Probe OpenCode server port if not yet known (plugin's serverPort
        // event may have been lost due to race with socket connection).
        if session.serverPort == nil && opencodeServerPortFallback == nil && opencodeServerPorts.isEmpty {
            Task { await probeOpencodeServerPort() }
        }

        publishState()
    }

    private func processOpencodeProcessingStarted(sessionId: String, cwd: String) {
        if sessions[sessionId] == nil, !registeredSessionIds.contains(sessionId) {
            writeDebugLogAsync("[opencode-lifecycle] ignored pre-registration processingStarted session=\(sessionId.prefix(12)) cwd=\(cwd)")
            return
        }
        var session = sessions[sessionId] ?? createOpencodeSession(sessionId: sessionId, cwd: cwd)

        // Retry probe if server port still unknown (plugin event may arrive late).
        if session.serverPort == nil && opencodeServerPortFallback == nil && opencodeServerPorts.isEmpty {
            Task { await probeOpencodeServerPort() }
        }
        enrichOpencodeRuntimeMetadata(session: &session)
        session.lastActivity = Date()
        session.completionNotificationAt = nil
        // Idempotent: if already processing, phase.canTransition allows it
        // (processing → processing is a no-op). Covers both thinking and
        // tool-running phases; the first call wins.
        //
        // opencode fires `message.part.updated(running)` immediately after
        // `permission.asked`, which surfaces here as a processingStarted.
        // Without this guard, the processingStarted would overwrite the
        // .waitingForApproval phase that permissionAsked just set, hiding the
        // approval buttons before the user can click them.
        DebugLog.shared.write("[opencode-phase] processingStarted session=\(sessionId.prefix(8)) currentPhase=\(session.phase)")
        if case .waitingForApproval = session.phase {
            // keep waitingForApproval — tool is awaiting user permission
            DebugLog.shared.write("[opencode-phase] processingStarted → suppressed (waitingForApproval)")
        } else if case .waitingForTerminalApproval = session.phase {
            // keep waitingForTerminalApproval — terminal permission pending
            DebugLog.shared.write("[opencode-phase] processingStarted → suppressed (waitingForTerminalApproval)")
        } else if session.phase.canTransition(to: .processing) {
            session.phase = .processing
            DebugLog.shared.write("[opencode-phase] processingStarted → phase set to .processing")
        } else {
            DebugLog.shared.write("[opencode-phase] processingStarted → transition rejected from \(session.phase)")
        }
        sessions[sessionId] = session
        publishState()
    }

    private func processOpencodeWaitingForUserInput(sessionId: String, cwd: String) {
        if sessions[sessionId] == nil, !registeredSessionIds.contains(sessionId) {
            writeDebugLogAsync("[opencode-lifecycle] ignored pre-registration waitingForUserInput session=\(sessionId.prefix(12)) cwd=\(cwd)")
            return
        }
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
        if sessions[sessionId] == nil, !registeredSessionIds.contains(sessionId) {
            writeDebugLogAsync("[opencode-lifecycle] ignored pre-registration stop session=\(sessionId.prefix(12)) cwd=\(cwd)")
            return
        }
        var session = sessions[sessionId] ?? createOpencodeSession(sessionId: sessionId, cwd: cwd)
        let hadRunningTools = hasRunningTools(in: session)
        enrichOpencodeRuntimeMetadata(session: &session)
        session.lastActivity = Date()
        session.phase = .idle
        // Don't set completionNotificationAt here — we use publishCompletionNotification
        // below for direct notification, avoiding double-trigger with
        // handleWaitingForInputChange's completionMarker detection.

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

        // Publish completion notification when the session ends without
        // running tools (normal turn completion). This triggers the
        // notification sound and bounce in NotchView.
        // NOTE: We use publishCompletionNotification (direct) instead of
        // completionNotificationAt (detected via handleWaitingForInputChange)
        // to avoid double-triggering the sound.
        if !hadRunningTools {
            publishCompletionNotification(for: session)
        }
    }

    private func processOpencodePromptSubmitted(sessionId: String, cwd: String, prompt: String) {
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty else { return }
        registerSession(sessionId: sessionId)
        var session = sessions[sessionId] ?? createOpencodeSession(sessionId: sessionId, cwd: cwd)
        enrichOpencodeRuntimeMetadata(session: &session)
        session.lastActivity = Date()
        session.completionNotificationAt = nil
        session.phase = .processing
        let now = Date()
        let firstUserMessage = session.conversationInfo.firstUserMessage ?? trimmedPrompt
        session.conversationInfo = ConversationInfo(
            summary: session.conversationInfo.summary,
            lastMessage: trimmedPrompt,
            lastMessageRole: "user",
            lastToolName: nil,
            firstUserMessage: firstUserMessage,
            lastUserMessageDate: now,
            usage: session.conversationInfo.usage
        )
        sessions[sessionId] = session
        let millis = Int(now.timeIntervalSince1970 * 1000)
        let id = "opencode-prompt-\(sessionId)-\(millis)"
        let update = ChatItemUpdate(
            id: id, sessionId: sessionId,
            block: .userPrompt(trimmedPrompt),
            ordering: .appendOrder,
            mutation: .insert, provider: .opencode
        )
        applyChatItemUpdate(update, appliesLifecycleEffects: true)
        publishState()
    }

    /// Probe common OpenCode server ports to discover a running server.
    /// Note: OpenCode in TUI mode (tmux) has no HTTP server — this only works
    /// for `opencode serve` mode. TUI sessions should use tmux send-keys.
    private func probeOpencodeServerPort() async {
        guard opencodeServerPortFallback == nil && opencodeServerPorts.isEmpty else { return }
        let ports = [4096, 4097, 4098]
        for port in ports {
            guard let url = URL(string: "http://127.0.0.1:\(port)/global/health") else { continue }
            var request = URLRequest(url: url)
            request.timeoutInterval = 1
            if let (_, response) = try? await URLSession.shared.data(for: request),
               let http = response as? HTTPURLResponse, http.statusCode == 200 {
                writeDebugLogAsync("[opencode-server] probe OK port=\(port)")
                applyOpencodeFallbackPort(port)
                return
            }
        }
        writeDebugLogAsync("[opencode-server] probe FAILED (TUI mode or no server)")
    }

    /// Legacy plugin / probe path: write global fallback and backfill all
    /// opencode sessions that don't have a port yet.
    private func applyOpencodeFallbackPort(_ port: Int) {
        opencodeServerPortFallback = port
        for (id, var session) in sessions where session.provider == .opencode && session.serverPort == nil {
            session.serverPort = port
            sessions[id] = session
        }
        publishState()
    }

    private func processOpencodeServerPortReceived(sessionId: String, port: Int, version: String?, pid: Int?) {
        // port 0/negative signals "no HTTP server" (TUI mode without --port).
        // Ignore so sessions never bind to a fake port.
        guard port > 0 else {
            writeDebugLogAsync("[opencode-server] serverPort ignored (no server, port=\(port)) pid=\(pid ?? -1)")
            return
        }
        if let version, !version.isEmpty {
            opencodePluginVersion = version
            opencodePluginVersionSubject.send(version)
        }
        guard let pid else {
            // Legacy plugin (no pid) or "?" broadcast: global fallback
            applyOpencodeFallbackPort(port)
            return
        }
        // Precise instance binding: override whatever fallback/probe assigned,
        // so each session's serverPort tracks its own pid authoritatively.
        opencodeServerPorts[pid] = port
        for (id, var session) in sessions where session.provider == .opencode {
            if session.pid == pid {
                session.serverPort = port
            } else if let sessionPid = session.pid, let known = opencodeServerPorts[sessionPid] {
                session.serverPort = known
            }
            sessions[id] = session
        }
        publishState()
    }

    private func processOpencodePermissionRequested(
        sessionId: String,
        cwd: String,
        permission: String,
        requestId: String,
        toolUseId: String?,
        input: [String: String],
        inputSummary: String?,
        alwaysPatterns: [String] = []
    ) {
        if sessions[sessionId] == nil, !registeredSessionIds.contains(sessionId) {
            writeDebugLogAsync("[opencode-lifecycle] ignored pre-registration permissionAsked session=\(sessionId.prefix(12)) cwd=\(cwd)")
            return
        }
        var session = sessions[sessionId] ?? createOpencodeSession(sessionId: sessionId, cwd: cwd)
        enrichOpencodeRuntimeMetadata(session: &session)
        session.lastActivity = Date()
        session.completionNotificationAt = nil

        let toolInput = input.mapValues { AnyCodable($0) }
        let context = PermissionContext(
            toolUseId: toolUseId ?? "",
            toolName: permission,
            toolInput: toolInput.isEmpty ? nil : toolInput,
            receivedAt: Date(),
            opencodeRequestId: requestId,
            alwaysPatterns: alwaysPatterns
        )
        // opencode permission prompts use the in-process approval path
        // (Nook → plugin socket → client.permissionReply). The phase must be
        // .waitingForApproval (not .waitingForTerminalApproval) so the UI
        // renders the Allow/Deny/Always buttons that can reply to it.
        let targetPhase = SessionPhase.waitingForApproval(context)
        if session.phase.canTransition(to: targetPhase) {
            session.phase = targetPhase
        }

        if let toolUseId, !toolUseId.isEmpty {
            updateToolStatus(in: &session, toolId: toolUseId, status: .waitingForApproval)
        }

        let trimmedSummary = inputSummary?.trimmingCharacters(in: .whitespacesAndNewlines)
        let nonEmptySummary: String? = {
            guard let trimmedSummary, !trimmedSummary.isEmpty else { return nil }
            return trimmedSummary
        }()
        session.conversationInfo = ConversationInfo(
            summary: session.conversationInfo.summary,
            lastMessage: nonEmptySummary ?? session.conversationInfo.lastMessage,
            lastMessageRole: "tool",
            lastToolName: permission,
            firstUserMessage: session.conversationInfo.firstUserMessage,
            lastUserMessageDate: session.conversationInfo.lastUserMessageDate,
            usage: session.conversationInfo.usage
        )
        sessions[sessionId] = session
        // Publish a completion notification so the notch plays the alert
        // sound and bounces — permission prompts are actionable events
        // that need the user's attention just like a finished response.
        publishCompletionNotification(for: session)
        writeDebugLogAsync("[opencode-permission] permissionAsked session=\(sessionId.prefix(8)) tool=\(permission) requestId=\(requestId.prefix(12)) toolUseId=\(toolUseId ?? "nil") phase=\(String(describing: session.phase))")
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
        appliesLifecycleEffects: Bool = false,
        allowSessionCreation: Bool = true
    ) {
        if let existingSession = sessions[update.sessionId],
           existingSession.provider != update.provider {
            writeDebugLogAsync("[chat-item-update] ignored provider-mismatch session=\(update.sessionId) existingProvider=\(existingSession.provider.rawValue) updateProvider=\(update.provider.rawValue) id=\(update.id)")
            return
        }

        if sessions[update.sessionId] == nil, !allowSessionCreation {
            writeDebugLogAsync("[chat-item-update] ignored missing-session session=\(update.sessionId) updateProvider=\(update.provider.rawValue) id=\(update.id)")
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
            // Don't overwrite waitingForApproval: user shouldn't be submitting
            // prompts while a permission is pending, but guard defensively.
            if !session.phase.isWaitingForApproval && !session.phase.isWaitingForTerminalApproval {
                session.phase = .processing
            }
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
            // OpenCode sessions should stay .processing between ops — the
            // only valid transition to .idle is via the explicit `.stop`
            // event (from opencode's `session.idle` bus event). Setting
            // phase=.idle here when no tools are running causes the notch
            // icon animation to flash off between tool/think boundaries
            // (because opencode fires session.status=busy 1-3ms after the
            // tool-end idle gap). For all other providers, the existing
            // hasRunningTools heuristic is fine.
            if session.provider == .opencode {
                if !session.phase.isWaitingForApproval && !session.phase.isWaitingForTerminalApproval {
                    session.phase = .processing
                }
            } else {
                session.phase = hasRunningTools(in: session) ? .processing : .idle
            }
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
                // Don't overwrite waitingForApproval/waitingForTerminalApproval:
                // opencode fires message.part.updated(running) immediately after
                // permission.asked, which surfaces here as a toolCall insert.
                // Without this guard the phase would flip back to .processing
                // and the user would never see the approval buttons.
                //
                // Also don't overwrite waitingForInput for askUserQuestion tools:
                // question.asked sets .waitingForInput before the preTool arrives,
                // and the preTool would incorrectly flip it back to .processing.
                let isAskQuestion = ToolCallItem.kind(of: tc.name) == .askUserQuestion
                if !session.phase.isWaitingForApproval && !session.phase.isWaitingForTerminalApproval && !isAskQuestion {
                    session.phase = .processing
                }
            } else {
                session.toolTracker.completeTool(id: update.id, success: !update.isError)
                // Same opencode carve-out as assistantText above: between
                // tool calls the session is still alive, so keep .processing
                // until the explicit .stop event.
                if session.provider == .opencode {
                    if !session.phase.isWaitingForApproval && !session.phase.isWaitingForTerminalApproval {
                        session.phase = .processing
                    }
                } else {
                    session.phase = hasRunningTools(in: session) ? .processing : .idle
                }
            }
            // Extract tool input summary for the session list display.
            // Without this, lastMessage keeps the previous value (e.g. user's
            // prompt), causing the session list to show [tool name] + [user prompt].
            let toolInputSummary = Self.extractToolInputSummary(tc)
            session.conversationInfo = ConversationInfo(
                summary: session.conversationInfo.summary,
                lastMessage: toolInputSummary.isEmpty ? session.conversationInfo.lastMessage : toolInputSummary,
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

    /// Extract a short human-readable summary from a tool call's input dictionary.
    /// Mirrors Claude's ConversationParser.formatToolInput and OpenCode's
    /// buildInputSummary logic — show the most meaningful field for each tool type.
    private static func extractToolInputSummary(_ tc: ChatItemToolCall) -> String {
        let lower = tc.name.lowercased()
        if lower == "bash", let cmd = tc.input["command"] { return cmd }
        if let filePath = tc.input["file_path"] ?? tc.input["filePath"] { return filePath }
        if let name = tc.input["name"] { return name }
        if let pattern = tc.input["pattern"] { return pattern }
        if let description = tc.input["description"] { return String(description.prefix(60)) }
        if let query = tc.input["query"] { return String(query.prefix(60)) }
        if let url = tc.input["url"] { return url }
        if let prompt = tc.input["prompt"] { return String(prompt.prefix(60)) }
        if let content = tc.input["content"] { return String(content.prefix(60)) }
        return tc.name
    }

    private func enrichOpencodeRuntimeMetadata(session: inout SessionState) {
        let tree = ProcessTreeBuilder.shared.buildTree()
        guard let process = bestMatchingOpencodeProcess(for: session.cwd, tree: tree) else {
            return
        }

        session.pid = process.pid
        session.tty = process.tty
        session.isInTmux = ProcessTreeBuilder.shared.isInTmux(pid: process.pid, tree: tree)
        if let port = opencodeServerPorts[process.pid] {
            session.serverPort = port
        }
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
        guard var session = sessions[sessionId] else {
            Self.logger.warning("permissionApproved: session not found sessionId=\(sessionId.prefix(8), privacy: .public)")
            return
        }

        Self.logger.info("permissionApproved: processing toolUseId=\(toolUseId.prefix(12), privacy: .public) currentPhase=\(String(describing: session.phase), privacy: .public)")

        // Update tool status in chat history first
        updateToolStatus(in: &session, toolId: toolUseId, status: .running)

        // Check if there are other tools still waiting for approval
        if let nextPending = findNextPendingTool(in: session, excluding: toolUseId) {
            // Another tool is waiting - stay in waitingForApproval with that tool's context
            Self.logger.info("permissionApproved: found next pending tool=\(nextPending.id.prefix(12), privacy: .public) name=\(nextPending.name, privacy: .public)")
            let newPhase = SessionPhase.waitingForApproval(PermissionContext(
                toolUseId: nextPending.id,
                toolName: nextPending.name,
                toolInput: nil,  // We don't have the input stored in chatItems
                receivedAt: nextPending.timestamp
            ))
            if session.phase.canTransition(to: newPhase) {
                session.phase = newPhase
                Self.logger.debug("Switched to next pending tool: \(nextPending.id.prefix(12), privacy: .public)")
            } else {
                Self.logger.warning("permissionApproved: cannot transition to next pending tool phase current=\(String(describing: session.phase), privacy: .public) target=\(String(describing: newPhase), privacy: .public)")
            }
        } else {
            // No more pending tools - transition to processing
            if case .waitingForApproval(let ctx) = session.phase, ctx.toolUseId == toolUseId {
                if session.phase.canTransition(to: .processing) {
                    session.phase = .processing
                    Self.logger.info("permissionApproved: transitioned to processing")
                } else {
                    Self.logger.warning("permissionApproved: cannot transition to processing current=\(String(describing: session.phase), privacy: .public)")
                }
            } else if case .waitingForApproval(let ctx) = session.phase {
                // The approved tool wasn't the one in phase context, but no others pending
                // This can happen if tools were approved out of order
                Self.logger.warning("permissionApproved: tool mismatch phaseTool=\(ctx.toolUseId.prefix(12), privacy: .public) approvedTool=\(toolUseId.prefix(12), privacy: .public)")
                if session.phase.canTransition(to: .processing) {
                    session.phase = .processing
                    Self.logger.info("permissionApproved: transitioned to processing (out of order)")
                }
            } else {
                Self.logger.warning("permissionApproved: unexpected phase=\(String(describing: session.phase), privacy: .public)")
            }
        }

        Self.logger.info("permissionApproved: final phase=\(String(describing: session.phase), privacy: .public)")
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

        // Idempotent guard: if the session already settled to .idle
        // (e.g. Stop hook event was processed first, then the
        // status-file watcher also fired on busy→idle transition),
        // don't re-run the cleanup. Without this, both paths would
        // each clear subagentState and re-publishState().
        guard session.phase != .idle else { return }

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
        codexTranscriptLowerBounds.removeValue(forKey: sessionId)
        recentlyStoppedCodexSessions.removeValue(forKey: sessionId)
        pendingCodexStartupSessions.remove(sessionId)
        ignoredCodexSessions.remove(sessionId)
        unregisterSession(sessionId: sessionId)
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
        guard let session = sessions[sessionId], session.provider == .codex else {
            writeDebugLogAsync("[codex-transcript-sync] skipped missing-session session=\(sessionId)")
            return
        }

        let lowerBound = codexTranscriptLowerBounds[sessionId]
        let startOffset = lowerBound == nil ? session.toolTracker.lastSyncOffset : 0
        let result = await CodexTranscriptParser.loadUpdateResult(
            sessionId: sessionId,
            after: lowerBound,
            fromOffset: startOffset
        )
        guard var currentSession = sessions[sessionId], currentSession.provider == .codex else {
            writeDebugLogAsync("[codex-transcript-sync] dropped result missing-session session=\(sessionId)")
            return
        }

        currentSession.toolTracker.lastSyncOffset = result.endOffset
        currentSession.toolTracker.lastSyncTime = Date()
        sessions[sessionId] = currentSession

        guard !result.updates.isEmpty else { return }

        DebugLog.shared.write("[codex-transcript-sync] session=\(sessionId) updates=\(result.updates.count) offset=\(startOffset)->\(result.endOffset)")
        for update in result.updates {
            applyChatItemUpdate(update, allowSessionCreation: false)
        }
        publishState()
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

        for (sessionId, stoppedAt) in recentlyStoppedCodexSessions {
            if now.timeIntervalSince(stoppedAt) > codexLateEventIgnoreSeconds {
                recentlyStoppedCodexSessions.removeValue(forKey: sessionId)
            }
        }

        for (sessionId, session) in Array(sessions) {
            if session.phase == .ended {
                sessions.removeValue(forKey: sessionId)
                cancelPendingSync(sessionId: sessionId)
                codexTranscriptLowerBounds.removeValue(forKey: sessionId)
                recentlyStoppedCodexSessions.removeValue(forKey: sessionId)
                pendingCodexStartupSessions.remove(sessionId)
                ignoredCodexSessions.remove(sessionId)
                unregisterSession(sessionId: sessionId)
                stateChanged = true
                continue
            }

            if session.provider == .codex,
               session.phase == .idle,
               now.timeIntervalSince(session.lastActivity) > codexIdleExpirationSeconds {
                sessions.removeValue(forKey: sessionId)
                codexTranscriptLowerBounds.removeValue(forKey: sessionId)
                recentlyStoppedCodexSessions.removeValue(forKey: sessionId)
                pendingCodexStartupSessions.remove(sessionId)
                ignoredCodexSessions.remove(sessionId)
                unregisterSession(sessionId: sessionId)
                stateChanged = true
                continue
            }

            if session.provider == .codex,
               session.phase.isActive {
                let quietDuration = now.timeIntervalSince(session.lastActivity)
                let quietLimit = hasRunningTools(in: session)
                    ? codexRunningToolQuietExpirationSeconds
                    : codexActiveQuietExpirationSeconds

                // Check transcript for terminal error (e.g. 429 Too Many Requests)
                // before falling through to quiet expiration. Codex Desktop does not
                // fire a Stop hook when the API retry limit is exceeded, so the
                // session would otherwise remain stuck in .processing for 90+ seconds.
                if let errorMessage = CodexTranscriptParser.detectTerminalError(sessionId: sessionId) {
                    Self.logger.info("Codex session \(sessionId.prefix(8), privacy: .public) terminated with error: \(errorMessage, privacy: .public)")
                    writeDebugLogAsync("[codex-lifecycle] terminalErrorDetected session=\(sessionId) error=\(errorMessage) phase=\(String(describing: session.phase))")
                    markCodexSessionStopped(sessionId: sessionId)
                    var updatedSession = session
                    updatedSession.phase = .idle
                    updatedSession.completionNotificationAt = nil
                    finishDanglingCodexTools(in: &updatedSession)
                    updatedSession.toolTracker.inProgress.removeAll()
                    sessions[sessionId] = updatedSession
                    stateChanged = true
                    continue
                }

                if quietDuration > quietLimit {
                    var updatedSession = session
                    Self.logger.info("Codex session \(sessionId.prefix(8), privacy: .public) active state expired after \(Int(quietDuration), privacy: .public)s quiet; marking idle")
                    writeDebugLogAsync("[codex-lifecycle] activeQuietExpired session=\(sessionId) quietSeconds=\(Int(quietDuration)) limitSeconds=\(Int(quietLimit)) phase=\(String(describing: session.phase))")
                    updatedSession.phase = .idle
                    updatedSession.completionNotificationAt = nil
                    updatedSession.toolTracker.inProgress.removeAll()
                    sessions[sessionId] = updatedSession
                    stateChanged = true
                    continue
                }
            }

            if let pid = session.pid,
               shouldRemoveWhenProcessExits(session) {
                let isRunning = isProcessRunning(pid: pid)
                if !isRunning {
                    Self.logger.info("Process \(pid) no longer running, ending session \(sessionId.prefix(8))")
                    sessions.removeValue(forKey: sessionId)
                    cancelPendingSync(sessionId: sessionId)
                    codexTranscriptLowerBounds.removeValue(forKey: sessionId)
                    recentlyStoppedCodexSessions.removeValue(forKey: sessionId)
                    pendingCodexStartupSessions.remove(sessionId)
                    ignoredCodexSessions.remove(sessionId)
                    unregisterSession(sessionId: sessionId)
                    stateChanged = true
                    continue
                }
            }

            // Claude: when the Stop hook is missed (e.g. nook-state.py
            // fails to connect, or the socket is temporarily unavailable),
            // the session can get stuck in .processing even though Claude
            // CLI has already gone idle. Check the per-pid status file as
            // a fallback — if it reports "idle" while our phase is still
            // active, transition the session out of the stuck state.
            if session.provider == .claude,
               session.phase.isActive,
               let pid = session.pid {
                if let status = readClaudeStatusFile(pid: pid), status == "idle" {
                    var updatedSession = session
                    Self.logger.info("Claude session \(sessionId.prefix(8), privacy: .public) stuck in \(String(describing: session.phase)) but status file is idle; transitioning to idle")
                    writeDebugLogAsync("[claude-lifecycle] statusFileIdleFallback session=\(sessionId) pid=\(pid) phase=\(String(describing: session.phase))")
                    updatedSession.phase = .idle
                    updatedSession.completionNotificationAt = nil
                    updatedSession.toolTracker.inProgress.removeAll()
                    sessions[sessionId] = updatedSession
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

    private func shouldRemoveWhenProcessExits(_ session: SessionState) -> Bool {
        switch session.provider {
        case .codex:
            // Codex runtime pids are best-effort hints for focusing a live turn.
            // The stable identity is the Codex session id, so a completed Codex
            // turn must remain visible after the worker process exits.
            return false
        case .claude, .opencode, .cursor:
            return true
        }
    }

    /// Check if a process is still running
    private nonisolated func isProcessRunning(pid: Int) -> Bool {
        return kill(Int32(pid), 0) == 0
    }

    /// Read the `status` field from Claude's per-pid session file
    /// (`~/.claude/sessions/{pid}.json`). Returns nil if the file
    /// doesn't exist or can't be parsed.
    private nonisolated func readClaudeStatusFile(pid: Int) -> String? {
        let path = NSHomeDirectory() + "/.claude/sessions/\(pid).json"
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json["status"] as? String
    }

    // MARK: - State Publishing

    private func publishState() {
        let sortedSessions = Array(sessions.values).sorted { $0.projectName < $1.projectName }
        sessionsSubject.send(sortedSessions)
    }

    private func publishCompletionNotification(for session: SessionState) {
        completionNotificationsSubject.send(
            SessionCompletionNotification(session: session)
        )
        writeDebugLogAsync("[completion-notification] published provider=\(session.provider.rawValue) session=\(session.sessionId)")
    }

    #if DEBUG
    func resetForTesting() {
        for task in pendingSyncs.values {
            task.cancel()
        }
        sessions.removeAll()
        pendingSyncs.removeAll()
        codexTranscriptLowerBounds.removeAll()
        recentlyStoppedCodexSessions.removeAll()
        pendingCodexStartupSessions.removeAll()
        ignoredCodexSessions.removeAll()
        blockOrderings.removeAll()
        publishState()
    }

    func setSessionPidForTesting(sessionId: String, pid: Int?) {
        guard var session = sessions[sessionId] else { return }
        session.pid = pid
        sessions[sessionId] = session
        publishState()
    }

    func recheckAllSessionsForTesting() {
        recheckAllSessions()
    }
    #endif

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
