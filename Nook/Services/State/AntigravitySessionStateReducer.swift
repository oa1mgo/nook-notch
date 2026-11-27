//
//  AntigravitySessionStateReducer.swift
//  Nook
//
//  Antigravity-specific lifecycle state transitions.
//

import Foundation

struct AntigravitySessionStateReducer {
    enum Event: Sendable {
        case sessionStart(cwd: String)
        case processingStarted(cwd: String)
        case waitingForInput(cwd: String)
        case stop(cwd: String, terminationReason: String?, error: String?)
    }

    struct Result: Sendable {
        var session: SessionState?
        var didCreateSession: Bool
        var debugMessage: String?
    }

    nonisolated static func reduce(
        existingSession: SessionState?,
        sessionId: String,
        event: Event
    ) -> Result {
        if let existingSession, existingSession.provider != .antigravity {
            return Result(
                session: nil,
                didCreateSession: false,
                debugMessage: "[antigravity-lifecycle] ignored provider-mismatch session=\(sessionId) existingProvider=\(existingSession.provider.rawValue)"
            )
        }

        switch event {
        case .sessionStart(let cwd):
            return processSessionStart(existingSession: existingSession, sessionId: sessionId, cwd: cwd)

        case .processingStarted(let cwd):
            return processProcessingStarted(existingSession: existingSession, sessionId: sessionId, cwd: cwd)

        case .waitingForInput(let cwd):
            return processWaitingForInput(existingSession: existingSession, sessionId: sessionId, cwd: cwd)

        case .stop(let cwd, let terminationReason, let error):
            return processStop(
                existingSession: existingSession,
                sessionId: sessionId,
                cwd: cwd,
                terminationReason: terminationReason,
                error: error
            )
        }
    }

    private nonisolated static func processSessionStart(
        existingSession: SessionState?,
        sessionId: String,
        cwd: String
    ) -> Result {
        let isNewSession = existingSession == nil
        var session = resolvedAntigravitySession(
            existingSession ?? createSession(sessionId: sessionId, cwd: cwd),
            cwd: cwd
        )

        session.lastActivity = Date()
        session.completionNotificationAt = nil
        if isNewSession || !session.phase.isActive {
            session.phase = .idle
        }

        return Result(
            session: session,
            didCreateSession: isNewSession,
            debugMessage: "[antigravity-lifecycle] sessionStart session=\(sessionId) cwd=\(session.cwd) phase=\(session.phase)"
        )
    }

    private nonisolated static func processProcessingStarted(
        existingSession: SessionState?,
        sessionId: String,
        cwd: String
    ) -> Result {
        let isNewSession = existingSession == nil
        var session = resolvedAntigravitySession(
            existingSession ?? createSession(sessionId: sessionId, cwd: cwd),
            cwd: cwd
        )

        session.lastActivity = Date()
        session.completionNotificationAt = nil
        if session.phase.canTransition(to: .processing) {
            session.phase = .processing
        }

        return Result(
            session: session,
            didCreateSession: isNewSession,
            debugMessage: "[antigravity-lifecycle] processingStarted session=\(sessionId) cwd=\(session.cwd) phase=\(session.phase)"
        )
    }

    private nonisolated static func processWaitingForInput(
        existingSession: SessionState?,
        sessionId: String,
        cwd: String
    ) -> Result {
        let isNewSession = existingSession == nil
        var session = resolvedAntigravitySession(
            existingSession ?? createSession(sessionId: sessionId, cwd: cwd),
            cwd: cwd
        )

        session.lastActivity = Date()
        session.completionNotificationAt = nil
        if session.phase.canTransition(to: .waitingForInput) {
            session.phase = .waitingForInput
        }

        return Result(
            session: session,
            didCreateSession: isNewSession,
            debugMessage: "[antigravity-lifecycle] waitingForInput session=\(sessionId) cwd=\(session.cwd) phase=\(session.phase)"
        )
    }

    private nonisolated static func processStop(
        existingSession: SessionState?,
        sessionId: String,
        cwd: String,
        terminationReason: String?,
        error: String?
    ) -> Result {
        let isNewSession = existingSession == nil
        var session = resolvedAntigravitySession(
            existingSession ?? createSession(sessionId: sessionId, cwd: cwd),
            cwd: cwd
        )
        let now = Date()
        let normalizedReason = terminationReason?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let hasError = normalizedReason == "ERROR" || !(error?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        let wasCanceled = normalizedReason == "USER_CANCELED"

        session.lastActivity = now
        session.phase = .idle
        session.completionNotificationAt = (!hasError && !wasCanceled) ? now : nil
        finishDanglingTools(in: &session, hasError: hasError, wasCanceled: wasCanceled)
        session.toolTracker.inProgress.removeAll()

        return Result(
            session: session,
            didCreateSession: isNewSession,
            debugMessage: "[antigravity-lifecycle] stop session=\(sessionId) cwd=\(session.cwd) reason=\(normalizedReason ?? "nil") phase=\(session.phase) items=\(session.chatItems.count)"
        )
    }

    private nonisolated static func createSession(sessionId: String, cwd: String) -> SessionState {
        SessionState(
            sessionId: sessionId,
            provider: .antigravity,
            cwd: cwd,
            projectName: URL(fileURLWithPath: cwd).lastPathComponent,
            phase: .idle
        )
    }

    private nonisolated static func resolvedAntigravitySession(_ session: SessionState, cwd: String? = nil) -> SessionState {
        let incomingCwd: String? = {
            let trimmed = cwd?.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed?.isEmpty == false ? trimmed : nil
        }()
        let resolvedCwd = session.cwd.isEmpty ? (incomingCwd ?? session.cwd) : session.cwd

        guard session.provider != .antigravity || session.cwd != resolvedCwd else {
            return session
        }

        return SessionState(
            sessionId: session.sessionId,
            provider: .antigravity,
            cwd: resolvedCwd,
            projectName: resolvedCwd.isEmpty ? session.projectName : URL(fileURLWithPath: resolvedCwd).lastPathComponent,
            pid: session.pid,
            tty: session.tty,
            isInTmux: session.isInTmux,
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

    private nonisolated static func finishDanglingTools(
        in session: inout SessionState,
        hasError: Bool,
        wasCanceled: Bool
    ) {
        let terminalStatus: ToolStatus
        if hasError {
            terminalStatus = .error
        } else if wasCanceled {
            terminalStatus = .interrupted
        } else {
            terminalStatus = .success
        }

        for index in session.chatItems.indices {
            guard case .toolCall(var tool) = session.chatItems[index].type,
                  tool.status == .running || tool.status == .waitingForApproval else {
                continue
            }

            tool.status = terminalStatus
            session.chatItems[index] = ChatHistoryItem(
                id: session.chatItems[index].id,
                type: .toolCall(tool),
                timestamp: session.chatItems[index].timestamp
            )
        }
    }
}
