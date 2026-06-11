//
//  ClaudeSessionMonitor.swift
//  Nook
//
//  MainActor wrapper around SessionStore for UI binding.
//  Publishes SessionState arrays for SwiftUI observation.
//

import AppKit
import Combine
import Foundation

@MainActor
class ClaudeSessionMonitor: ObservableObject {
    @Published var instances: [SessionState] = []
    @Published var pendingInstances: [SessionState] = []

    private var cancellables = Set<AnyCancellable>()

    init() {
        SessionStore.shared.sessionsPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] sessions in
                self?.updateFromSessions(sessions)
            }
            .store(in: &cancellables)

        InterruptWatcherManager.shared.delegate = self
    }

    // MARK: - Monitoring Lifecycle

    func startMonitoring() {
        // Start periodic status rechecking
        Task {
            await SessionStore.shared.startPeriodicStatusCheck()
        }

        HookSocketServer.shared.start(
            onEvent: { event in
                Task {
                    await SessionStore.shared.process(.hookReceived(event))
                }

                if event.sessionPhase == .processing {
                    Task { @MainActor in
                        InterruptWatcherManager.shared.startWatching(
                            sessionId: event.sessionId,
                            cwd: event.cwd
                        )
                    }
                }

                if event.status == "ended" {
                    Task { @MainActor in
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
                Task {
                    switch event {
                    case .sessionStart(let sessionId, let cwd):
                        await SessionStore.shared.process(.codexSessionStarted(sessionId: sessionId, cwd: cwd))
                    case .userPromptSubmit(let sessionId, let cwd, let prompt):
                        await SessionStore.shared.process(.codexPromptSubmitted(sessionId: sessionId, cwd: cwd, prompt: prompt))
                    case .preTool(let sessionId, let cwd, let toolName, let toolUseId, let input, let inputSummary):
                        await SessionStore.shared.process(.codexToolStarted(sessionId: sessionId, cwd: cwd, toolName: toolName, toolUseId: toolUseId, input: input, inputSummary: inputSummary))
                    case .postTool(let sessionId, let cwd, let toolName, let toolUseId, let inputSummary):
                        await SessionStore.shared.process(.codexToolFinished(sessionId: sessionId, cwd: cwd, toolName: toolName, toolUseId: toolUseId, inputSummary: inputSummary))
                    case .waitingForUserInput(let sessionId, let cwd):
                        await SessionStore.shared.process(.codexWaitingForUserInput(sessionId: sessionId, cwd: cwd))
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
            },
            onOpencodeEvent: { event in
                // Passthrough events only — session lifecycle + subagent.
                // Chat-item events are handled via onOpencodeChatItems below.
                Task {
                    switch event {
                    case .sessionStart(let sessionId, let cwd):
                        await SessionStore.shared.process(.opencodeSessionStarted(sessionId: sessionId, cwd: cwd))
                    case .processingStarted(let sessionId, let cwd):
                        await SessionStore.shared.process(.opencodeProcessingStarted(sessionId: sessionId, cwd: cwd))
                    case .waitingForUserInput(let sessionId, let cwd):
                        await SessionStore.shared.process(.opencodeWaitingForUserInput(sessionId: sessionId, cwd: cwd))
                    case .stop(let sessionId, let cwd):
                        OpencodeChatItemAdapter.shared.clearSession(sessionId)
                        await SessionStore.shared.process(.opencodeStopped(sessionId: sessionId, cwd: cwd))
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
                    case .userPromptSubmitted, .assistantThinking, .assistantText,
                         .preTool, .postTool:
                        // These are now routed through OpencodeChatItemAdapter
                        // → onOpencodeChatItems → chatItemBatch. Should not
                        // reach here in normal operation.
                        break
                    }
                }
            },
            onOpencodeChatItems: { chatItems in
                Task {
                    await SessionStore.shared.process(.chatItemBatch(chatItems))
                }
            }
        )
    }

    func stopMonitoring() {
        HookSocketServer.shared.stop()
        Task {
            await SessionStore.shared.stopPeriodicStatusCheck()
        }
    }

    // MARK: - Permission Handling

    func approvePermission(sessionId: String) {
        Task {
            guard let session = await SessionStore.shared.session(for: sessionId),
                  let permission = session.activePermission else {
                return
            }

            HookSocketServer.shared.respondToPermission(
                toolUseId: permission.toolUseId,
                decision: "allow"
            )

            await SessionStore.shared.process(
                .permissionApproved(sessionId: sessionId, toolUseId: permission.toolUseId)
            )
        }
    }

    func denyPermission(sessionId: String, reason: String?) {
        Task {
            guard let session = await SessionStore.shared.session(for: sessionId),
                  let permission = session.activePermission else {
                return
            }

            HookSocketServer.shared.respondToPermission(
                toolUseId: permission.toolUseId,
                decision: "deny",
                reason: reason
            )

            await SessionStore.shared.process(
                .permissionDenied(sessionId: sessionId, toolUseId: permission.toolUseId, reason: reason)
            )
        }
    }

    /// Archive (remove) a session from the instances list
    func archiveSession(sessionId: String) {
        Task {
            await SessionStore.shared.process(.sessionEnded(sessionId: sessionId))
        }
    }

    // MARK: - State Update

    private func updateFromSessions(_ sessions: [SessionState]) {
        instances = sessions
        pendingInstances = sessions.filter { $0.needsAttention }
    }

    // MARK: - History Loading (for UI)

    /// Request history load for a session
    func loadHistory(sessionId: String, cwd: String) {
        Task {
            await SessionStore.shared.process(.loadHistory(sessionId: sessionId, cwd: cwd))
        }
    }
}

// MARK: - Interrupt Watcher Delegate

extension ClaudeSessionMonitor: JSONLInterruptWatcherDelegate {
    nonisolated func didDetectInterrupt(sessionId: String) {
        Task {
            await SessionStore.shared.process(.interruptDetected(sessionId: sessionId))
        }

        Task { @MainActor in
            InterruptWatcherManager.shared.stopWatching(sessionId: sessionId)
        }
    }
}
