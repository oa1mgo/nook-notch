import Foundation

/// Owns process-wide session ingestion. Window-scoped SessionMonitor instances
/// only observe the store; rebuilding a window never replaces watcher delegates.
@MainActor
final class SessionRuntime {
    /// The lifecycle boundary is injectable so tests never bind the production
    /// socket or start file watchers. Provider event mapping stays in this type.
    struct Lifecycle {
        var startIngress: (SessionRuntime) -> Void
        var stopIngress: () -> Void
        var setStatusChecksRunning: @Sendable (Bool) async -> Void

        static var live: Self {
            Self(
                startIngress: { runtime in
                    InterruptWatcherManager.shared.delegate = runtime
                    runtime.startHookServer()
                },
                stopIngress: {
                    HookSocketServer.shared.stop()
                    InterruptWatcherManager.shared.stopAll()
                    InterruptWatcherManager.shared.delegate = nil
                },
                setStatusChecksRunning: { running in
                    if running {
                        await SessionStore.shared.startPeriodicStatusCheck()
                    } else {
                        await SessionStore.shared.stopPeriodicStatusCheck()
                    }
                }
            )
        }
    }

    private nonisolated static let codexHookEventQueue = AsyncHookEventQueue()
    private let lifecycle: Lifecycle
    private var statusCheckTransition: Task<Void, Never>?
    private var monitoringGeneration: UUID?
    private(set) var isRunning = false

    convenience init() {
        self.init(lifecycle: .live)
    }

    init(lifecycle: Lifecycle) {
        self.lifecycle = lifecycle
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        monitoringGeneration = UUID()
        enqueueStatusCheckTransition(running: true)
        lifecycle.startIngress(self)
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        monitoringGeneration = nil
        lifecycle.stopIngress()
        enqueueStatusCheckTransition(running: false)
    }

    /// Actor hops must preserve the order of start/stop calls, including a stop
    /// before the first start task has executed and an immediate restart.
    private func enqueueStatusCheckTransition(running: Bool) {
        let previous = statusCheckTransition
        let setRunning = lifecycle.setStatusChecksRunning
        statusCheckTransition = Task {
            await previous?.value
            await setRunning(running)
        }
    }

    func waitForStatusCheckTransition() async {
        await statusCheckTransition?.value
    }

    private func startHookServer() {
        let generation = monitoringGeneration
        HookSocketServer.shared.start(
            onEvent: { [weak self] event in
                Task {
                    await SessionStore.shared.process(.hookReceived(event))
                }

                if event.sessionPhase == .processing {
                    Task { @MainActor [weak self] in
                        guard self?.monitoringGeneration == generation else { return }
                        InterruptWatcherManager.shared.startWatching(
                            sessionId: event.sessionId,
                            cwd: event.cwd,
                            pid: event.pid
                        )
                    }
                }

                if event.status == "ended" {
                    Task { @MainActor [weak self] in
                        guard self?.monitoringGeneration == generation else { return }
                        InterruptWatcherManager.shared.stopWatching(sessionId: event.sessionId)
                    }
                }

                if event.event == "Stop" {
                    HookSocketServer.shared.cancelPendingPermissions(sessionId: event.sessionId)
                }

                if event.event == "PostToolUse", let toolUseId = event.toolUseId {
                    HookSocketServer.shared.cancelPendingPermission(toolUseId: toolUseId)
                }
            },
            onPermissionFailure: { sessionId, toolUseId in
                Task {
                    await SessionStore.shared.process(
                        .permissionSocketFailed(sessionId: sessionId, toolUseId: toolUseId)
                    )
                }
            },
            onCodexEvent: { event in
                SessionRuntime.codexHookEventQueue.enqueue {
                    await SessionRuntime.processCodexHookEvent(event)
                }
            },
            onOpencodeEvent: { event in
                // Passthrough events only — session lifecycle + subagent.
                // Chat-item events are handled via onOpencodeChatItems below.
                Task {
                    switch event {
                    case .sessionStart(let sessionId, let cwd, let provisional, let pid):
                        await SessionStore.shared.process(.opencodeSessionStarted(sessionId: sessionId, cwd: cwd, provisional: provisional, pid: pid))
                    case .processingStarted(let sessionId, let cwd):
                        await SessionStore.shared.process(.opencodeProcessingStarted(sessionId: sessionId, cwd: cwd))
                    case .waitingForUserInput(let sessionId, let cwd, let toolUseId, let questions, let requestId):
                        await SessionStore.shared.process(.opencodeWaitingForUserInput(sessionId: sessionId, cwd: cwd, toolUseId: toolUseId, questions: questions, requestId: requestId))
                    case .stop(let sessionId, let cwd):
                        await OpencodeChatItemAdapter.shared.clearSession(sessionId)
                        await SessionStore.shared.process(.opencodeStopped(sessionId: sessionId, cwd: cwd))
                    case .permissionAsked(let sessionId, let cwd, let requestId, let toolName, let toolUseId, let input, let inputSummary, let alwaysPatterns):
                        await SessionStore.shared.process(.opencodePermissionRequested(sessionId: sessionId, cwd: cwd, permission: toolName, requestId: requestId, toolUseId: toolUseId, input: input, inputSummary: inputSummary, alwaysPatterns: alwaysPatterns))
                    case .serverPortReceived(let sessionId, let port, let version, let pid):
                        await SessionStore.shared.process(.opencodeServerPortReceived(sessionId: sessionId, port: port, version: version, pid: pid))
                    case .subagentStarted(let sessionId, let taskToolId):
                        // sessionId is already the parent's — the adapter
                        // rewrites child session ids before emitting.
                        await SessionStore.shared.process(.subagentStarted(sessionId: sessionId, taskToolId: taskToolId))
                    case .subagentToolExecuted(let sessionId, let tool):
                        await SessionStore.shared.process(.subagentToolExecuted(sessionId: sessionId, tool: tool))
                    case .subagentToolCompleted(let sessionId, let toolId, let status):
                        await SessionStore.shared.process(.subagentToolCompleted(sessionId: sessionId, toolId: toolId, status: status))
                    case .subagentStopped(let sessionId, let taskToolId):
                        await SessionStore.shared.process(.subagentStopped(sessionId: sessionId, taskToolId: taskToolId))
                    case .userPromptSubmitted, .assistantThinking, .assistantThinkingStreaming,
                         .assistantText, .assistantTextStreaming, .assistantStreamingCancelled,
                         .preTool, .postTool, .image:
                        // These are now routed through OpencodeChatItemAdapter
                        // → onOpencodeChatItems → realtimeChatItemBatch.
                        // Should not
                        // reach here in normal operation.
                        break
                    }
                }
            },
            onOpencodeChatItems: { chatItems in
                Task {
                    await SessionStore.shared.process(.realtimeChatItemBatch(chatItems))
                }
            },
            onCursorEvent: { event in
                Task {
                    switch event {
                    case .sessionStart(let sessionId, let cwd):
                        await SessionStore.shared.process(.cursorSessionStarted(sessionId: sessionId, cwd: cwd))
                    case .processingStarted(let sessionId, let cwd):
                        await SessionStore.shared.process(.cursorProcessingStarted(sessionId: sessionId, cwd: cwd))
                    case .compactingStarted(let sessionId, let cwd):
                        await SessionStore.shared.process(.cursorCompactingStarted(sessionId: sessionId, cwd: cwd))
                    case .stop(let sessionId, let cwd, let status):
                        CursorChatItemAdapter.shared.clearSession(sessionId)
                        await SessionStore.shared.process(.cursorStopped(sessionId: sessionId, cwd: cwd, status: status))
                    case .sessionEnd(let sessionId):
                        CursorChatItemAdapter.shared.clearSession(sessionId)
                        await SessionStore.shared.process(.cursorSessionEnded(sessionId: sessionId))
                    }
                }
            },
            onCursorChatItems: { chatItems in
                Task {
                    await SessionStore.shared.process(.realtimeChatItemBatch(chatItems))
                }
            }
        )
    }

    private nonisolated static func processCodexHookEvent(_ event: CodexSessionEvent) async {
        switch event {
        case .sessionStart(let sessionId, let cwd, let source):
            await SessionStore.shared.process(.codexSessionStarted(sessionId: sessionId, cwd: cwd, source: source))
        case .sessionEnd(let sessionId, _, _):
            await SessionStore.shared.process(.sessionEnded(sessionId: sessionId))
        case .userPromptSubmit(let sessionId, let cwd, let prompt):
            await SessionStore.shared.process(.codexPromptSubmitted(sessionId: sessionId, cwd: cwd, prompt: prompt))
        case .preTool(let sessionId, let cwd, let toolName, let toolUseId, let input, let inputSummary):
            await SessionStore.shared.process(.codexToolStarted(sessionId: sessionId, cwd: cwd, toolName: toolName, toolUseId: toolUseId, input: input, inputSummary: inputSummary))
        case .postTool(let sessionId, let cwd, let toolName, let toolUseId, let inputSummary, let output, let isError):
            await SessionStore.shared.process(.codexToolFinished(sessionId: sessionId, cwd: cwd, toolName: toolName, toolUseId: toolUseId, inputSummary: inputSummary, output: output, isError: isError))
        case .permissionRequest(let sessionId, let cwd, let toolName, let toolUseId, let input, let inputSummary):
            await SessionStore.shared.process(.codexPermissionRequested(sessionId: sessionId, cwd: cwd, toolName: toolName, toolUseId: toolUseId, input: input, inputSummary: inputSummary))
        case .compactingStarted(let sessionId, let cwd):
            await SessionStore.shared.process(.codexCompactingStarted(sessionId: sessionId, cwd: cwd))
        case .compactingFinished(let sessionId, let cwd):
            await SessionStore.shared.process(.codexCompactingFinished(sessionId: sessionId, cwd: cwd))
        case .subagentStarted(let sessionId, let cwd):
            await SessionStore.shared.process(.codexSubagentStarted(sessionId: sessionId, cwd: cwd))
        case .subagentStopped(let sessionId, let cwd):
            await SessionStore.shared.process(.codexSubagentStopped(sessionId: sessionId, cwd: cwd))
        case .stop(let sessionId, let cwd):
            await SessionStore.shared.process(.codexStopped(sessionId: sessionId, cwd: cwd))
        }
    }

}

private nonisolated final class AsyncHookEventQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var tail: Task<Void, Never>?

    nonisolated init() {}

    nonisolated func enqueue(_ operation: @escaping @Sendable () async -> Void) {
        lock.lock()
        let previous = tail
        let task = Task {
            await previous?.value
            await operation()
        }
        tail = task
        lock.unlock()
    }
}

// MARK: - Interrupt Watcher Delegate

extension SessionRuntime: JSONLInterruptWatcherDelegate, ClaudeStatusFileWatcherDelegate {
    nonisolated func didDetectInterrupt(sessionId: String) {
        Task { @MainActor [weak self] in
            guard let self, let generation = self.monitoringGeneration else { return }
            await SessionStore.shared.process(.interruptDetected(sessionId: sessionId))
            guard self.monitoringGeneration == generation else { return }
            InterruptWatcherManager.shared.stopWatching(sessionId: sessionId)
        }
    }
}
