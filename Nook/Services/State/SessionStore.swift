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

    /// Sync debounce interval (100ms)
    private let syncDebounceNs: UInt64 = 100_000_000

    /// Periodic status check task
    private var statusCheckTask: Task<Void, Never>?

    /// Status check interval (3 seconds)
    private let statusCheckIntervalSeconds: UInt64 = 3

    /// Idle Codex sessions do not emit a terminal "ended" event, so reap them
    /// after a short quiet window to avoid stale sessions lingering forever.
    private let codexIdleExpirationSeconds: TimeInterval = 600

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

        case .codexSessionStarted(let sessionId, let cwd):
            processCodexSessionStart(sessionId: sessionId, cwd: cwd)

        case .codexPromptSubmitted(let sessionId, let cwd, let prompt):
            processCodexPromptSubmitted(sessionId: sessionId, cwd: cwd, prompt: prompt)

        case .codexBashStarted(let sessionId, let cwd, let toolName, let toolUseId, let command):
            processCodexBashStarted(sessionId: sessionId, cwd: cwd, toolName: toolName, toolUseId: toolUseId, command: command)

        case .codexBashFinished(let sessionId, let cwd, let toolName, let toolUseId, let command):
            processCodexBashFinished(sessionId: sessionId, cwd: cwd, toolName: toolName, toolUseId: toolUseId, command: command)

        case .codexToolStarted(let sessionId, let cwd, let toolName, let toolUseId, let input, let inputSummary):
            processCodexToolStarted(sessionId: sessionId, cwd: cwd, toolName: toolName, toolUseId: toolUseId, input: input, inputSummary: inputSummary)

        case .codexToolFinished(let sessionId, let cwd, let toolName, let toolUseId, let inputSummary):
            processCodexToolFinished(sessionId: sessionId, cwd: cwd, toolName: toolName, toolUseId: toolUseId, inputSummary: inputSummary)

        case .codexWaitingForUserInput(let sessionId, let cwd):
            processCodexWaitingForUserInput(sessionId: sessionId, cwd: cwd)

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

        case .opencodePromptSubmitted(let sessionId, let cwd, let prompt):
            processOpencodePromptSubmitted(sessionId: sessionId, cwd: cwd, prompt: prompt)

        case .opencodeProcessingStarted(let sessionId, let cwd):
            processOpencodeProcessingStarted(sessionId: sessionId, cwd: cwd)

        case .opencodeWaitingForUserInput(let sessionId, let cwd):
            processOpencodeWaitingForUserInput(sessionId: sessionId, cwd: cwd)

        case .opencodeAssistantThinking(let sessionId, let cwd, let text):
            processOpencodeAssistantThinking(sessionId: sessionId, cwd: cwd, text: text)

        case .opencodeAssistantText(let sessionId, let cwd, let text):
            processOpencodeAssistantText(sessionId: sessionId, cwd: cwd, text: text)

        case .opencodeToolStarted(let sessionId, let cwd, let toolName, let toolUseId, let inputSummary):
            processOpencodeToolStarted(sessionId: sessionId, cwd: cwd, toolName: toolName, toolUseId: toolUseId, inputSummary: inputSummary)

        case .opencodeToolFinished(let sessionId, let cwd, let toolName, let toolUseId, let inputSummary, let output, let error):
            processOpencodeToolFinished(sessionId: sessionId, cwd: cwd, toolName: toolName, toolUseId: toolUseId, inputSummary: inputSummary, output: output, error: error)

        case .opencodeStopped(let sessionId, let cwd):
            processOpencodeStop(sessionId: sessionId, cwd: cwd)

        case .chatItemUpdate(let update):
            applyChatItemUpdate(update)

        case .chatItemBatch(let updates):
            for update in updates {
                applyChatItemUpdate(update)
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
        let isNewSession = sessions[sessionId] == nil
        var session = sessions[sessionId] ?? createSession(from: event)

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

    private func processCodexSessionStart(sessionId: String, cwd: String) {
        guard !shouldIgnoreCodexSession(sessionId) else { return }
        let isNewSession = sessions[sessionId] == nil
        var session = sessions[sessionId] ?? createCodexSession(sessionId: sessionId, cwd: cwd)
        enrichCodexRuntimeMetadata(session: &session)
        session.lastActivity = Date()
        session.completionNotificationAt = nil
        if isNewSession || !session.phase.isActive {
            session.phase = .idle
        }
        sessions[sessionId] = session

        if isNewSession {
            mixpanel?.track(event: "Session Started", properties: ["provider": "codex"])
        }
    }

    private func processCodexPromptSubmitted(sessionId: String, cwd: String, prompt: String?) {
        guard !shouldIgnoreCodexSession(sessionId) else { return }
        var session = sessions[sessionId] ?? createCodexSession(sessionId: sessionId, cwd: cwd)
        let now = Date()
        let trimmedPrompt = prompt?.trimmingCharacters(in: .whitespacesAndNewlines)
        let firstUserMessage = session.conversationInfo.firstUserMessage ?? trimmedPrompt

        enrichCodexRuntimeMetadata(session: &session)
        session.lastActivity = now
        session.completionNotificationAt = nil
        session.phase = .processing
        if let trimmedPrompt, !trimmedPrompt.isEmpty {
            session.chatItems.append(
                ChatHistoryItem(
                    id: "codex-user-\(sessionId)-\(Int(now.timeIntervalSince1970 * 1000))",
                    type: .user(trimmedPrompt),
                    timestamp: now
                )
            )
        }
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
        guard !shouldIgnoreCodexSession(sessionId) else { return }
        var session = sessions[sessionId] ?? createCodexSession(sessionId: sessionId, cwd: cwd)
        let now = Date()
        let toolId = toolUseId ?? makeCodexToolId(for: sessionId)

        enrichCodexRuntimeMetadata(session: &session)
        session.lastActivity = now
        session.completionNotificationAt = nil
        session.phase = .processing
        session.toolTracker.startTool(id: toolId, name: toolName)

        let inputPreview = inputSummary?.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayInput: [String: String]
        if !input.isEmpty {
            displayInput = input
        } else if let inputPreview, !inputPreview.isEmpty {
            displayInput = ["summary": inputPreview]
        } else {
            displayInput = [:]
        }
        // Dedup: if a tool item with this ID already exists, update it
        // instead of appending. Codex can re-emit `codexBashStarted` for
        // the same callID if the underlying hook fires more than once
        // (e.g. tmux event redelivery or duplicate socket frames). The
        // previous version always appended, which would stack a fresh
        // chatItem on every duplicate start and produce ~3 row-sized
        // blank gaps in the chat. Mirror the dedup shape used by
        // `processOpencodeToolStarted` and `processToolTracking` (Claude).
        if let idx = session.chatItems.firstIndex(where: { $0.id == toolId }),
           case .toolCall(let existing) = session.chatItems[idx].type {
            let updated = ToolCallItem(
                name: existing.name,
                input: displayInput,
                status: existing.status == .success || existing.status == .error ? existing.status : .running,
                result: existing.result,
                structuredResult: existing.structuredResult,
                subagentTools: existing.subagentTools
            )
            session.chatItems[idx] = ChatHistoryItem(
                id: toolId,
                type: .toolCall(updated),
                timestamp: session.chatItems[idx].timestamp
            )
        } else {
            session.chatItems.append(
                ChatHistoryItem(
                    id: toolId,
                    type: .toolCall(ToolCallItem(
                        name: toolName,
                        input: displayInput,
                        status: .running,
                        result: nil,
                        structuredResult: nil,
                        subagentTools: []
                    )),
                    timestamp: now
                )
            )
        }
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
    }

    private func processCodexBashFinished(sessionId: String, cwd: String, toolName: String, toolUseId: String?, command: String?) {
        processCodexToolFinished(
            sessionId: sessionId,
            cwd: cwd,
            toolName: toolName,
            toolUseId: toolUseId,
            inputSummary: command
        )
    }

    private func processCodexToolFinished(sessionId: String, cwd: String, toolName: String, toolUseId: String?, inputSummary: String?) {
        guard !shouldIgnoreCodexSession(sessionId) else { return }
        var session = sessions[sessionId] ?? createCodexSession(sessionId: sessionId, cwd: cwd)
        let now = Date()
        let fallbackToolId = toolUseId ?? makeCodexToolId(for: sessionId)
        let completedTurnAt = session.completionNotificationAt

        enrichCodexRuntimeMetadata(session: &session)
        session.lastActivity = now

        if let toolId = latestRunningCodexToolId(in: session, toolName: toolName, toolUseId: toolUseId) {
            session.toolTracker.completeTool(id: toolId, success: true)
            updateToolStatus(in: &session, toolId: toolId, status: .success)
        } else if let toolUseId, !session.chatItems.contains(where: { $0.id == toolUseId }) {
            session.chatItems.append(
                ChatHistoryItem(
                    id: fallbackToolId,
                    type: .toolCall(ToolCallItem(
                        name: toolName,
                        input: inputSummary.map { ["summary": $0] } ?? [:],
                        status: .success,
                        result: nil,
                        structuredResult: nil,
                        subagentTools: []
                    )),
                    timestamp: now
                )
            )
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
    }

    private func processCodexWaitingForUserInput(sessionId: String, cwd: String) {
        guard !shouldIgnoreCodexSession(sessionId) else { return }
        var session = sessions[sessionId] ?? createCodexSession(sessionId: sessionId, cwd: cwd)
        enrichCodexRuntimeMetadata(session: &session)
        session.lastActivity = Date()
        session.completionNotificationAt = nil
        if session.phase.canTransition(to: .waitingForInput) {
            session.phase = .waitingForInput
        }
        sessions[sessionId] = session
    }

    private func processCodexCompactingStarted(sessionId: String, cwd: String) {
        guard !shouldIgnoreCodexSession(sessionId) else { return }
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
        guard !shouldIgnoreCodexSession(sessionId) else { return }
        var session = sessions[sessionId] ?? createCodexSession(sessionId: sessionId, cwd: cwd)
        enrichCodexRuntimeMetadata(session: &session)
        session.lastActivity = Date()
        session.completionNotificationAt = nil
        if session.phase.canTransition(to: .processing) {
            session.phase = .processing
        }
        sessions[sessionId] = session
    }

    private func processCodexSubagentStarted(sessionId: String, cwd: String) {
        guard !shouldIgnoreCodexSession(sessionId) else { return }
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
        guard !shouldIgnoreCodexSession(sessionId) else { return }
        var session = sessions[sessionId] ?? createCodexSession(sessionId: sessionId, cwd: cwd)
        enrichCodexRuntimeMetadata(session: &session)
        session.lastActivity = Date()
        session.completionNotificationAt = nil
        if session.phase.canTransition(to: .processing) {
            session.phase = .processing
        }
        sessions[sessionId] = session
    }

    private func processCodexStop(sessionId: String, cwd: String) {
        guard !shouldIgnoreCodexSession(sessionId) else { return }
        var session = sessions[sessionId] ?? createCodexSession(sessionId: sessionId, cwd: cwd)
        enrichCodexRuntimeMetadata(session: &session)
        session.lastActivity = Date()
        session.phase = .idle
        session.completionNotificationAt = Date()
        finishDanglingCodexTools(in: &session)
        session.toolTracker.inProgress.removeAll()
        sessions[sessionId] = session
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
    }

    private func processOpencodePromptSubmitted(sessionId: String, cwd: String, prompt: String?) {
        var session = sessions[sessionId] ?? createOpencodeSession(sessionId: sessionId, cwd: cwd)
        let now = Date()
        let trimmedPrompt = prompt?.trimmingCharacters(in: .whitespacesAndNewlines)

        // Update phase / activity / completion-notification BEFORE the
        // empty-prompt guard. An opencode session that receives an empty
        // user prompt (defensive case — adapter usually filters these)
        // should still register as `.processing` so the UI doesn't stay
        // stuck on a stale phase. Mirrors `processCodexPromptSubmitted`.
        enrichOpencodeRuntimeMetadata(session: &session)
        session.lastActivity = now
        session.phase = .processing
        session.completionNotificationAt = nil

        if let prompt = trimmedPrompt, !prompt.isEmpty {
            session.chatItems.append(
                ChatHistoryItem(
                    id: "opencode-prompt-\(sessionId)-\(Int(now.timeIntervalSince1970 * 1000))",
                    type: .user(prompt),
                    timestamp: now
                )
            )
            session.conversationInfo = ConversationInfo(
                summary: session.conversationInfo.summary,
                lastMessage: prompt,
                lastMessageRole: "user",
                lastToolName: nil,
                firstUserMessage: session.conversationInfo.firstUserMessage ?? prompt,
                lastUserMessageDate: now,
                usage: session.conversationInfo.usage
            )
        }

        sessions[sessionId] = session
    }

    private func processOpencodeProcessingStarted(sessionId: String, cwd: String) {
        var session = sessions[sessionId] ?? createOpencodeSession(sessionId: sessionId, cwd: cwd)
        enrichOpencodeRuntimeMetadata(session: &session)
        session.lastActivity = Date()
        session.completionNotificationAt = nil
        // Idempotent: if already processing, phase.canTransition allows it
        // (processing → processing is a no-op). Covers both thinking and
        // tool-running phases; the first call wins.
        if session.phase.canTransition(to: .processing) {
            session.phase = .processing
        }
        sessions[sessionId] = session
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
        if session.phase.canTransition(to: .waitingForInput) {
            session.phase = .waitingForInput
        }
        sessions[sessionId] = session
    }

    private func processOpencodeAssistantThinking(sessionId: String, cwd: String, text: String) {
        var session = sessions[sessionId] ?? createOpencodeSession(sessionId: sessionId, cwd: cwd)
        let now = Date()
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return }

        enrichOpencodeRuntimeMetadata(session: &session)
        session.lastActivity = now
        // Mirror processOpencodeAssistantText: tools still in flight → .processing,
        // pure reasoning with no tool activity → .idle. The previous form
        // (?: .processing) was a copy-paste typo from the opencode event-stream
        // commit (6c56af0) that forced .processing even during idle reasoning,
        // which made the notch keep showing the orange spinner on opencode
        // sessions that only emitted a thinking block before stopping.
        session.phase = hasRunningTools(in: session) ? .processing : .idle
        session.completionNotificationAt = nil
        // Thinking always goes BEFORE the matching assistant text. The adapter
        // emits .assistantThinking before .assistantText for the same message
        // (reasoning flush precedes text flush in handleMessageUpdated), and we
        // append in arrival order, so the thinking item lands at a lower index
        // than its companion text. Chat view renders in array order, which is
        // what we want.
        let itemId = "opencode-thinking-\(sessionId)-\(Int(now.timeIntervalSince1970 * 1000))"
        session.chatItems.append(
            ChatHistoryItem(
                id: itemId,
                type: .thinking(trimmedText),
                timestamp: now
            )
        )
        // DIAGNOSTIC (#70): dump chatItems state to find where second thinking is lost
        let thinkingCount = session.chatItems.filter { if case .thinking = $0.type { return true } else { return false } }.count
        let last3 = session.chatItems.suffix(3).map { "\($0.id)=\(self.typeName($0.type))" }.joined(separator: ", ")
        DebugLog.shared.write("[session-store] thinking appended session=\(sessionId) itemId=\(itemId) textChars=\(trimmedText.count) totalItems=\(session.chatItems.count) thinkingCount=\(thinkingCount) last3=\(last3)")

        sessions[sessionId] = session
    }

    /// DIAGNOSTIC (#70): helper to label a chatItem type for debug logging
    private func typeName(_ t: ChatHistoryItemType) -> String {
        switch t {
        case .user: return "user"
        case .assistant: return "assistant"
        case .toolCall(let tool): return "tool(\(tool.name))"
        case .thinking: return "thinking"
        case .image: return "image"
        case .interrupted: return "interrupted"
        }
    }

    /// Check whether the bash output ends with the opencode `<bash_metadata>`
    /// footer (appended for timeout / abort / non-zero with metadata,
    /// opencode/src/tool/bash.ts:393-398). We only inspect the tail of the
    /// output because the literal string `<bash_metadata>` can appear in the
    /// middle of benign output (e.g. `git diff` of code that references it)
    /// — see #72 in the task list.
    private nonisolated func tailContainsBashMetadata(_ output: String?) -> Bool? {
        guard let output, !output.isEmpty else { return false }
        // 1KB is generous — the footer is ~200 chars in practice. Cheap O(1)
        // check that avoids scanning megabytes of `cat`-style output.
        let tail = output.suffix(1024)
        return tail.contains("<bash_metadata>")
    }

    private func processOpencodeAssistantText(sessionId: String, cwd: String, text: String) {
        var session = sessions[sessionId] ?? createOpencodeSession(sessionId: sessionId, cwd: cwd)
        let now = Date()
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return }

        enrichOpencodeRuntimeMetadata(session: &session)
        session.lastActivity = now
        session.phase = hasRunningTools(in: session) ? .processing : .idle
        session.completionNotificationAt = Date()
        session.chatItems.append(
            ChatHistoryItem(
                id: "opencode-assistant-\(sessionId)-\(Int(now.timeIntervalSince1970 * 1000))",
                type: .assistant(trimmedText),
                timestamp: now
            )
        )
        session.conversationInfo = ConversationInfo(
            summary: session.conversationInfo.summary,
            lastMessage: trimmedText,
            lastMessageRole: "assistant",
            lastToolName: nil,
            firstUserMessage: session.conversationInfo.firstUserMessage,
            lastUserMessageDate: session.conversationInfo.lastUserMessageDate,
            usage: session.conversationInfo.usage
        )

        sessions[sessionId] = session
    }

    private func processOpencodeToolStarted(sessionId: String, cwd: String, toolName: String, toolUseId: String?, inputSummary: String?) {
        var session = sessions[sessionId] ?? createOpencodeSession(sessionId: sessionId, cwd: cwd)
        let now = Date()
        let toolId = toolUseId ?? makeOpencodeToolId(for: sessionId)

        enrichOpencodeRuntimeMetadata(session: &session)
        session.lastActivity = now
        session.completionNotificationAt = nil
        // NOTE: this unconditionally overwrites .waitingForInput to .processing.
        // If a `question.asked` event from the opencode plugin arrived BEFORE
        // this `preTool` (ordering between session.status, question.asked, and
        // preTool is not formally guaranteed across opencode versions), the
        // .waitingForInput phase set by processOpencodeWaitingForUserInput
        // gets clobbered here and the user sees the orange processing spinner
        // instead of the "Answer the question" banner. In practice opencode
        // v1.15.13+ fires preTool first, so this race has not been observed,
        // but if a user reports "stuck on processing while question dialog
        // is open", inspect /tmp/nook-debug.log for the order of
        //   → processingStarted (session.status=busy)
        //   → waitingForUserInput (question.asked)
        //   → toolStarted (preTool ...)
        // and consider gating this assignment with a canTransition check that
        // refuses to clobber .waitingForInput. See SessionPhase.swift for the
        // state machine.
        session.phase = .processing
        session.toolTracker.startTool(id: toolId, name: toolName)

        let inputPreview = inputSummary?.trimmingCharacters(in: .whitespacesAndNewlines)
        let input: [String: String] = {
            // Opencode's subagent tool is named "task" (lowercase). Use the
            // provider-agnostic kind so the description is preserved under
            // the "description" key (matching the Claude subagent
            // container) instead of the generic "command" key.
            if ToolCallItem.kind(of: toolName) == .task, let desc = inputPreview {
                return ["description": String(desc.prefix(80))]
            }
            return inputPreview.map { ["command": $0] } ?? [:]
        }()
        // If a tool item with this ID already exists, update its input
        // instead of appending. Important: do NOT skip the update when
        // input is already set — opencode can re-emit `preTool` for the
        // same callID multiple times (e.g. message.part.updated state
        // cycles pending→running→pending→running within a few ms, and
        // the adapter forwards each `preTool` it sees). The previous
        // version gated the update on `input["command"] == nil`, which
        // meant every duplicate preTool fell through to `else` and
        // appended a fresh chatItem. Three duplicate preTools → three
        // bash rows in the chat, visible as a ~60pt blank gap.
        if let idx = session.chatItems.firstIndex(where: { $0.id == toolId }),
           case .toolCall(let existing) = session.chatItems[idx].type {
            let updated = ToolCallItem(
                name: existing.name,
                input: input,
                status: existing.status,
                result: existing.result,
                structuredResult: existing.structuredResult,
                subagentTools: existing.subagentTools
            )
            session.chatItems[idx] = ChatHistoryItem(
                id: toolId,
                type: .toolCall(updated),
                timestamp: session.chatItems[idx].timestamp
            )
        } else {
            session.chatItems.append(
                ChatHistoryItem(
                    id: toolId,
                    type: .toolCall(ToolCallItem(
                        name: toolName,
                        input: input,
                        status: .running,
                        result: nil,
                        structuredResult: nil,
                        subagentTools: []
                    )),
                    timestamp: now
                )
            )
        }
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
    }

    private func processOpencodeToolFinished(sessionId: String, cwd: String, toolName: String, toolUseId: String?, inputSummary: String?, output: String? = nil, error: String? = nil) {
        var session = sessions[sessionId] ?? createOpencodeSession(sessionId: sessionId, cwd: cwd)
        let now = Date()

        enrichOpencodeRuntimeMetadata(session: &session)
        session.lastActivity = now

        let toolKind = ToolKind.classify(toolName)
        let isBash = toolKind == .bash
        // Bash error detection — two signals:
        //   1. state.error is non-nil → opencode's ToolStateError path
        //      (opencode/src/session/message-v2.ts:319-333), e.g. spawn() threw.
        //   2. state.output ends with "<bash_metadata>…" footer → opencode's
        //      bash.ts:393-398 appends this footer for timeout / abort / non-zero
        //      with metadata. The footer is appended at the END of the output,
        //      so we only check the tail (last 1KB). Checking the entire output
        //      causes false positives when the bash output happens to contain
        //      the literal string `<bash_metadata>` (e.g. `git diff` of code
        //      that references it).
        // Route A: don't parse the XML; the rendered preview already conveys why.
        let outputIsError = (error?.isEmpty == false)
            || (isBash && (tailContainsBashMetadata(output) ?? false))
        // Prefer output over error when both exist — output is usually the
        // longer body (stdout/stderr); error is just the exception message.
        let resultBody: String? = {
            if let output, !output.isEmpty { return output }
            if let error, !error.isEmpty { return error }
            return nil
        }()
        let finalStatus: ToolStatus = outputIsError ? .error : .success

        if let toolId = latestRunningCodexToolId(in: session, toolName: toolName, toolUseId: toolUseId) {
            session.toolTracker.completeTool(id: toolId, success: !outputIsError)
            updateToolStatus(in: &session, toolId: toolId, status: finalStatus)
        }

        // Stamp `result` on the toolCall, except on the parent's task container.
        // canExpand already excludes .task, and subagentTools is what drives the
        // container's own expansion — leaving `tool.result = nil` there is the
        // right model. structuredResult intentionally untouched (route A).
        if let toolUseId, toolKind != .task, let body = resultBody {
            for i in 0..<session.chatItems.count where session.chatItems[i].id == toolUseId {
                if case .toolCall(var tool) = session.chatItems[i].type {
                    tool.status = finalStatus
                    tool.result = body
                    session.chatItems[i] = ChatHistoryItem(
                        id: session.chatItems[i].id,
                        type: .toolCall(tool),
                        timestamp: session.chatItems[i].timestamp
                    )
                }
                break
            }
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
        session.phase = hasRunningTools(in: session) ? .processing : .idle

        sessions[sessionId] = session
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
    }

    // MARK: - Unified ChatItem Update Processing

    /// Apply a single ChatItemUpdate to session state. This is the unified
    /// entry point for all provider chat item mutations, replacing the
    /// provider-specific processOpencode* / processCodex* methods.
    ///
    /// After each mutation, chatItems are re-sorted using ChatItemSorter
    /// to maintain correct display order based on BlockOrdering keys.
    ///
    /// Session auto-creation: OpenCode's bus can deliver message events
    /// ~1ms before the session.updated event that triggers sessionStart.
    /// Rather than dropping chat items for unknown sessions (the original
    /// guard-early-return bug), we create a minimal session placeholder
    /// here. The imminent sessionStart passthrough will then enrich it
    /// with cwd, pid, and other metadata via the explicit cwd-override
    /// in processOpencodeSessionStart.
    private func applyChatItemUpdate(_ update: ChatItemUpdate) {
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
            mixpanel?.track(event: "Session Started", properties: ["provider": "opencode"])
        }

        // ── Early guards ──────────────────────────────────────────────

        // Skip empty thinking blocks — they render as orphan grey dots.
        if case .thinking(let text) = update.block,
           text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return
        }

        // ── Mutation ──────────────────────────────────────────────────

        switch update.mutation {
        case .insert:
            let item = ChatHistoryItem(
                id: update.id,
                type: update.block.toChatHistoryItemType(),
                timestamp: now
            )
            if let idx = session.chatItems.firstIndex(where: { $0.id == update.id }) {
                // Upsert: replace existing item (preserves original timestamp)
                let originalTimestamp = session.chatItems[idx].timestamp
                session.chatItems[idx] = ChatHistoryItem(
                    id: update.id,
                    type: update.block.toChatHistoryItemType(),
                    timestamp: originalTimestamp
                )
            } else {
                session.chatItems.append(item)
            }
            blockOrderings[update.id] = update.ordering

        case .update:
            if let idx = session.chatItems.firstIndex(where: { $0.id == update.id }) {
                let originalTimestamp = session.chatItems[idx].timestamp
                session.chatItems[idx] = ChatHistoryItem(
                    id: update.id,
                    type: update.block.toChatHistoryItemType(),
                    timestamp: originalTimestamp
                )
            }

        case .updateStatus:
            if case .toolCall(let block) = update.block,
               let idx = session.chatItems.firstIndex(where: { $0.id == update.id }),
               case .toolCall(var existing) = session.chatItems[idx].type {
                existing.status = block.status
                if let result = block.result {
                    existing.result = result
                }
                if let structured = block.structuredResult {
                    existing.structuredResult = structured
                }
                session.chatItems[idx] = ChatHistoryItem(
                    id: update.id,
                    type: .toolCall(existing),
                    timestamp: session.chatItems[idx].timestamp
                )
            }

        case .remove:
            session.chatItems.removeAll { $0.id == update.id }
            blockOrderings.removeValue(forKey: update.id)
        }

        // ── Lifecycle side effects ────────────────────────────────────
        // Mirror the side effects that the old processOpencode* methods
        // applied (lastActivity, phase, completionNotificationAt,
        // conversationInfo, toolTracker). Only the .insert / .updateStatus
        // mutations carry meaningful lifecycle signals; .update / .remove
        // are structural and don't change the session's activity state.

        if update.mutation == .insert || update.mutation == .updateStatus {
            enrichOpencodeRuntimeMetadata(session: &session)
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
                // Thinking is a signal of active processing. Clear any
                // stale completionNotificationAt (prevents premature
                // notification if thinking starts after a tool completes
                // but before the next assistantText), and ensure phase
                // reflects active work even if no tool is running yet.
                session.completionNotificationAt = nil
                if !session.phase.isActive {
                    session.phase = .processing
                }

            case .toolCall(let tc):
                if update.mutation == .insert {
                    // Tool started — track in toolTracker so that
                    // hasRunningTools() / progress indicators work.
                    session.toolTracker.startTool(id: update.id, name: tc.name)
                    session.completionNotificationAt = nil
                    session.phase = .processing
                } else {
                    // Tool finished (updateStatus) — use the adapter's
                    // isError flag (which includes bash metadata detection)
                    // for accurate success/failure tracking.
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

        // ── Re-sort & persist ─────────────────────────────────────────

        session.chatItems = ChatItemSorter.sorted(
            session.chatItems,
            orderings: blockOrderings
        )

        sessions[update.sessionId] = session
        DebugLog.shared.write("[chat-item-update] session=\(update.sessionId) id=\(update.id) mutation=\(update.mutation) totalItems=\(session.chatItems.count)")
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

    private func makeCodexToolId(for sessionId: String) -> String {
        let millis = Int(Date().timeIntervalSince1970 * 1000)
        return "codex-bash-\(sessionId)-\(millis)"
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

        return candidates
            .filter { ProcessTreeBuilder.shared.isInTmux(pid: $0.pid, tree: tree) }
            .max(by: { $0.pid < $1.pid })
    }

    private func processToolTracking(event: HookEvent, session: inout SessionState) {
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
                        tool.status = .success
                        session.chatItems[i] = ChatHistoryItem(
                            id: toolUseId,
                            type: .toolCall(tool),
                            timestamp: session.chatItems[i].timestamp
                        )
                        break
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
    /// `processOpencodeToolStarted` usually creates the chatItem first and this
    /// guard is a no-op — but if the adapter ever emits subagentStarted without
    /// a matching preTool (e.g. because of a race), the chatItem still shows up.
    private func processSubagentStarted(sessionId: String, taskToolId: String) {
        guard var session = sessions[sessionId] else { return }
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

            let blocksInThisBatch = Self.upsertBlocks(
                messages: payload.messages,
                completedToolIds: payload.completedToolIds,
                toolResults: payload.toolResults,
                structuredResults: payload.structuredResults,
                session: &session
            )

        if !payload.isIncremental {
            session.chatItems.sort { $0.timestamp < $1.timestamp }
        }

        session.toolTracker.lastSyncTime = Date()

        await populateSubagentToolsFromAgentFiles(
            sessionId: payload.sessionId,
            session: &session,
            cwd: payload.cwd,
            structuredResults: payload.structuredResults
        )

        sessions[payload.sessionId] = session

        await emitToolCompletionEvents(
            sessionId: payload.sessionId,
            session: session,
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

    /// Upsert blocks into `chatItems`.
    ///
    /// For every block we either UPDATE the existing item with the same id (preserving
    /// runtime state like tool status / result / subagent children) or APPEND a new
    /// item if the id isn't present yet. Empty text / thinking blocks are allowed in
    /// the array — `AssistantMessageView` / `ThinkingView` render them as `EmptyView`
    /// so we never get orphan dots, but the placeholder is present so a later
    /// non-empty content update replaces it in place rather than disappearing.
    ///
    /// The earlier behaviour returned `nil` for empty text and skipped re-processing
    /// of the same id; in long turns with multiple tool calls that combination made
    /// the final assistant text vanish from the chat view until the next turn's
    /// re-sync happened to re-introduce it.
    ///
    /// Takes `inout SessionState` rather than separate inout arrays because passing
    /// `&session.chatItems` and `&session.toolTracker` to the same call triggers a
    /// Swift exclusivity violation (the runtime flags both as simultaneous modify
    /// accesses to the same struct storage). Inside this function the two fields
    /// are accessed sequentially under a single inout scope, which is allowed.
    static func upsertBlocks(
        messages: [ChatMessage],
        completedToolIds: Set<String>,
        toolResults: [String: ConversationParser.ToolResult],
        structuredResults: [String: ToolResultData],
        session: inout SessionState
    ) {
        for message in messages {
            for (blockIndex, block) in message.content.enumerated() {
                switch block {
                case .toolUse(let tool):
                    if let idx = session.chatItems.firstIndex(where: { $0.id == tool.id }),
                       case .toolCall(let existingTool) = session.chatItems[idx].type {
                        session.chatItems[idx] = ChatHistoryItem(
                            id: tool.id,
                            type: .toolCall(ToolCallItem(
                                name: tool.name,
                                input: tool.input,
                                status: existingTool.status,
                                result: existingTool.result,
                                structuredResult: existingTool.structuredResult,
                                subagentTools: existingTool.subagentTools
                            )),
                            timestamp: message.timestamp
                        )
                        continue
                    }
                    if session.toolTracker.markSeen(tool.id) {
                        let status: ToolStatus = completedToolIds.contains(tool.id) ? .success : .running
                        var resultText: String? = nil
                        if let parserResult = toolResults[tool.id] {
                            if let stdout = parserResult.stdout, !stdout.isEmpty {
                                resultText = stdout
                            } else if let stderr = parserResult.stderr, !stderr.isEmpty {
                                resultText = stderr
                            } else if let content = parserResult.content, !content.isEmpty {
                                resultText = content
                            }
                        }
                        session.chatItems.append(ChatHistoryItem(
                            id: tool.id,
                            type: .toolCall(ToolCallItem(
                                name: tool.name,
                                input: tool.input,
                                status: status,
                                result: resultText,
                                structuredResult: structuredResults[tool.id],
                                subagentTools: []
                            )),
                            timestamp: message.timestamp
                        ))
                    }

                case .text(let text):
                    let itemId = "\(message.id)-text-\(blockIndex)"
                    let newType: ChatHistoryItemType = (message.role == .user) ? .user(text) : .assistant(text)
                    if let idx = session.chatItems.firstIndex(where: { $0.id == itemId }) {
                        // Preserve user prompts once they exist — the JSONL shouldn't
                        // rewrite user text, and overwriting an empty placeholder with
                        // another empty placeholder just churns the view.
                        if case .user = session.chatItems[idx].type { continue }
                        // For assistant text, allow empty → empty (no churn) and
                        // non-empty → replace the placeholder. Never overwrite a
                        // non-empty assistant message with empty content.
                        if case .assistant(let existing) = session.chatItems[idx].type,
                           existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                           text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            continue
                        }
                        session.chatItems[idx] = ChatHistoryItem(
                            id: itemId,
                            type: newType,
                            timestamp: message.timestamp
                        )
                    } else {
                        session.chatItems.append(ChatHistoryItem(
                            id: itemId,
                            type: newType,
                            timestamp: message.timestamp
                        ))
                    }

                case .thinking(let text):
                    let itemId = "\(message.id)-thinking-\(blockIndex)"
                    if let idx = session.chatItems.firstIndex(where: { $0.id == itemId }) {
                        if case .thinking(let existing) = session.chatItems[idx].type,
                           existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                           text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            continue
                        }
                        session.chatItems[idx] = ChatHistoryItem(
                            id: itemId,
                            type: .thinking(text),
                            timestamp: message.timestamp
                        )
                    } else {
                        // Skip inserting thinking blocks with empty text
                        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                            continue
                        }
                        session.chatItems.append(ChatHistoryItem(
                            id: itemId,
                            type: .thinking(text),
                            timestamp: message.timestamp
                        ))
                    }

                case .image(let imageBlock):
                    let itemId = "\(message.id)-image-\(blockIndex)"
                    if let idx = session.chatItems.firstIndex(where: { $0.id == itemId }) {
                        session.chatItems[idx] = ChatHistoryItem(
                            id: itemId,
                            type: .image(imageBlock),
                            timestamp: message.timestamp
                        )
                    } else {
                        session.chatItems.append(ChatHistoryItem(
                            id: itemId,
                            type: .image(imageBlock),
                            timestamp: message.timestamp
                        ))
                    }

                case .interrupted:
                    let itemId = "\(message.id)-interrupted-\(blockIndex)"
                    if !session.chatItems.contains(where: { $0.id == itemId }) {
                        session.chatItems.append(ChatHistoryItem(
                            id: itemId,
                            type: .interrupted,
                            timestamp: message.timestamp
                        ))
                    }
                }
            }
        }
    }

    private func updateToolStatus(in session: inout SessionState, toolId: String, status: ToolStatus) {
        var found = false
        for i in 0..<session.chatItems.count {
            if session.chatItems[i].id == toolId,
               case .toolCall(var tool) = session.chatItems[i].type {
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
    }

    // MARK: - History Loading

    private func loadHistoryFromFile(sessionId: String, cwd: String) async {
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

        // Update conversationInfo (summary, lastMessage, etc.)
        session.conversationInfo = conversationInfo

        Self.upsertBlocks(
            messages: messages,
            completedToolIds: completedTools,
            toolResults: toolResults,
            structuredResults: structuredResults,
            session: &session
        )

        // Sort by timestamp
        session.chatItems.sort { $0.timestamp < $1.timestamp }

        sessions[sessionId] = session
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
        var removedSession = false

        for (sessionId, session) in Array(sessions) {
            if session.phase == .ended {
                sessions.removeValue(forKey: sessionId)
                cancelPendingSync(sessionId: sessionId)
                removedSession = true
                continue
            }

            if session.provider == .codex,
               session.phase == .idle,
               Date().timeIntervalSince(session.lastActivity) > codexIdleExpirationSeconds {
                sessions.removeValue(forKey: sessionId)
                removedSession = true
                continue
            }

            if let pid = session.pid {
                let isRunning = isProcessRunning(pid: pid)
                if !isRunning {
                    Self.logger.info("Process \(pid) no longer running, ending session \(sessionId.prefix(8))")
                    sessions.removeValue(forKey: sessionId)
                    cancelPendingSync(sessionId: sessionId)
                    removedSession = true
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

        if removedSession {
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
