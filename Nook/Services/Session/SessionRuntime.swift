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

    private let ingress: SessionEventIngress
    private let lifecycle: Lifecycle
    private var statusCheckTransition: Task<Void, Never>?
    private var monitoringGeneration: UUID?
    private(set) var isRunning = false
    private(set) var hookCallbacks: HookSocketCallbacks?

    convenience init() {
        self.init(lifecycle: .live)
    }

    init(lifecycle: Lifecycle, eventSink: SessionEventIngress.Sink? = nil) {
        self.lifecycle = lifecycle
        self.ingress = SessionEventIngress(sink: eventSink ?? {
            await SessionStore.shared.process($0)
        })
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        let generation = ingress.beginGeneration()
        monitoringGeneration = generation
        hookCallbacks = makeHookCallbacks(generation: generation)
        enqueueStatusCheckTransition(running: true)
        lifecycle.startIngress(self)
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        monitoringGeneration = nil
        ingress.close()
        hookCallbacks = nil
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

    func waitForIngress() async {
        await ingress.waitUntilDrained()
    }

    private func startHookServer() {
        guard let hookCallbacks else { return }
        HookSocketServer.shared.start(callbacks: hookCallbacks)
    }

    private func makeHookCallbacks(generation: UUID) -> HookSocketCallbacks {
        let ingress = self.ingress
        return HookSocketCallbacks(
            onEvent: { [weak self] event in
                guard ingress.enqueue([.hookReceived(event)], generation: generation) else { return }

                Task { @MainActor [weak self] in
                    guard self?.monitoringGeneration == generation else { return }
                    if event.sessionPhase == .processing {
                        InterruptWatcherManager.shared.startWatching(
                            sessionId: event.sessionId,
                            cwd: event.cwd,
                            pid: event.pid
                        )
                    }
                    if event.status == "ended" {
                        InterruptWatcherManager.shared.stopWatching(sessionId: event.sessionId)
                    }
                    if event.event == "Stop" {
                        HookSocketServer.shared.cancelPendingPermissions(sessionId: event.sessionId)
                    }
                    if event.event == "PostToolUse", let toolUseId = event.toolUseId {
                        HookSocketServer.shared.cancelPendingPermission(toolUseId: toolUseId)
                    }
                }
            },
            onPermissionFailure: { sessionId, toolUseId in
                ingress.enqueue(
                    [.permissionSocketFailed(sessionId: sessionId, toolUseId: toolUseId)],
                    generation: generation
                )
            },
            onCodexEvent: { event in
                ingress.enqueue([Self.sessionEvent(from: event)], generation: generation)
            },
            onOpencodeBatch: { batch in
                var events: [SessionEvent] = batch.chatItemUpdates.isEmpty
                    ? [] : [.realtimeChatItemBatch(batch.chatItemUpdates)]
                events.append(contentsOf: batch.passthroughEvents.compactMap(Self.sessionEvent(from:)))
                ingress.enqueue(events, generation: generation)
            },
            onCursorBatch: { batch in
                var events: [SessionEvent] = batch.chatItemUpdates.isEmpty
                    ? [] : [.realtimeChatItemBatch(batch.chatItemUpdates)]
                events.append(contentsOf: batch.passthroughEvents.map(Self.sessionEvent(from:)))
                ingress.enqueue(events, generation: generation)
            },
            onAntigravityBatch: { batch in
                var events: [SessionEvent] = batch.chatItemUpdates.isEmpty
                    ? [] : [.realtimeChatItemBatch(batch.chatItemUpdates)]
                events.append(contentsOf: batch.passthroughEvents.map(Self.sessionEvent(from:)))
                ingress.enqueue(events, generation: generation)
            }
        )
    }

    private nonisolated static func sessionEvent(from event: OpencodeSessionEvent) -> SessionEvent? {
        switch event {
        case .sessionStart(let sessionId, let cwd, let provisional, let pid):
            return .opencodeSessionStarted(sessionId: sessionId, cwd: cwd, provisional: provisional, pid: pid)
        case .processingStarted(let sessionId, let cwd):
            return .opencodeProcessingStarted(sessionId: sessionId, cwd: cwd)
        case .waitingForUserInput(let sessionId, let cwd, let toolUseId, let questions, let requestId):
            return .opencodeWaitingForUserInput(sessionId: sessionId, cwd: cwd, toolUseId: toolUseId, questions: questions, requestId: requestId)
        case .stop(let sessionId, let cwd):
            return .opencodeStopped(sessionId: sessionId, cwd: cwd)
        case .permissionAsked(let sessionId, let cwd, let requestId, let toolName, let toolUseId, let input, let inputSummary, let alwaysPatterns):
            return .opencodePermissionRequested(sessionId: sessionId, cwd: cwd, permission: toolName, requestId: requestId, toolUseId: toolUseId, input: input, inputSummary: inputSummary, alwaysPatterns: alwaysPatterns)
        case .permissionReplied(let sessionId, let requestId, let reply):
            return .opencodePermissionReplied(sessionId: sessionId, requestId: requestId, reply: reply)
        case .serverPortReceived(let sessionId, let port, let version, let pid):
            return .opencodeServerPortReceived(sessionId: sessionId, port: port, version: version, pid: pid)
        case .subagentStarted(let sessionId, let taskToolId):
            // The adapter has already rewritten a child ID to its parent.
            return .subagentStarted(sessionId: sessionId, taskToolId: taskToolId)
        case .subagentToolExecuted(let sessionId, let tool):
            return .subagentToolExecuted(sessionId: sessionId, tool: tool)
        case .subagentToolCompleted(let sessionId, let toolId, let status):
            return .subagentToolCompleted(sessionId: sessionId, toolId: toolId, status: status)
        case .subagentStopped(let sessionId, let taskToolId):
            return .subagentStopped(sessionId: sessionId, taskToolId: taskToolId)
        case .userPromptSubmitted, .assistantThinking, .assistantThinkingStreaming,
             .assistantText, .assistantTextStreaming, .assistantStreamingCancelled,
             .preTool, .postTool, .image:
            // Content has already been converted in the same adapter batch.
            return nil
        }
    }

    private nonisolated static func sessionEvent(from event: CursorSessionEvent) -> SessionEvent {
        switch event {
        case .sessionStart(let sessionId, let cwd):
            return .cursorSessionStarted(sessionId: sessionId, cwd: cwd)
        case .processingStarted(let sessionId, let cwd):
            return .cursorProcessingStarted(sessionId: sessionId, cwd: cwd)
        case .compactingStarted(let sessionId, let cwd):
            return .cursorCompactingStarted(sessionId: sessionId, cwd: cwd)
        case .stop(let sessionId, let cwd, let status):
            return .cursorStopped(sessionId: sessionId, cwd: cwd, status: status)
        case .sessionEnd(let sessionId):
            return .cursorSessionEnded(sessionId: sessionId)
        }
    }

    private nonisolated static func sessionEvent(from event: AntigravitySessionEvent) -> SessionEvent {
        switch event {
        case .sessionStart(let sessionId, let cwd):
            return .antigravitySessionStarted(sessionId: sessionId, cwd: cwd)
        case .processingStarted(let sessionId, let cwd):
            return .antigravityProcessingStarted(sessionId: sessionId, cwd: cwd)
        case .waitingForInput(let sessionId, let cwd):
            return .antigravityWaitingForInput(sessionId: sessionId, cwd: cwd)
        case .stop(let sessionId, let cwd, let terminationReason, let error):
            return .antigravityStopped(sessionId: sessionId, cwd: cwd, terminationReason: terminationReason, error: error)
        }
    }

    private nonisolated static func sessionEvent(from event: CodexSessionEvent) -> SessionEvent {
        switch event {
        case .sessionStart(let sessionId, let cwd, let source):
            return .codexSessionStarted(sessionId: sessionId, cwd: cwd, source: source)
        case .sessionEnd(let sessionId, _, _):
            return .sessionEnded(sessionId: sessionId)
        case .userPromptSubmit(let sessionId, let cwd, let prompt):
            return .codexPromptSubmitted(sessionId: sessionId, cwd: cwd, prompt: prompt)
        case .preTool(let sessionId, let cwd, let toolName, let toolUseId, let input, let inputSummary):
            return .codexToolStarted(sessionId: sessionId, cwd: cwd, toolName: toolName, toolUseId: toolUseId, input: input, inputSummary: inputSummary)
        case .postTool(let sessionId, let cwd, let toolName, let toolUseId, let inputSummary, let output, let isError):
            return .codexToolFinished(sessionId: sessionId, cwd: cwd, toolName: toolName, toolUseId: toolUseId, inputSummary: inputSummary, output: output, isError: isError)
        case .permissionRequest(let sessionId, let cwd, let toolName, let toolUseId, let input, let inputSummary):
            return .codexPermissionRequested(sessionId: sessionId, cwd: cwd, toolName: toolName, toolUseId: toolUseId, input: input, inputSummary: inputSummary)
        case .compactingStarted(let sessionId, let cwd):
            return .codexCompactingStarted(sessionId: sessionId, cwd: cwd)
        case .compactingFinished(let sessionId, let cwd):
            return .codexCompactingFinished(sessionId: sessionId, cwd: cwd)
        case .subagentStarted(let sessionId, let cwd):
            return .codexSubagentStarted(sessionId: sessionId, cwd: cwd)
        case .subagentStopped(let sessionId, let cwd):
            return .codexSubagentStopped(sessionId: sessionId, cwd: cwd)
        case .stop(let sessionId, let cwd):
            return .codexStopped(sessionId: sessionId, cwd: cwd)
        }
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
