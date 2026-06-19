//
//  CursorSessionStateReducer.swift
//  Nook
//
//  Cursor-specific lifecycle state transitions.
//

import Foundation

struct CursorSessionStateReducer {
    enum Event: Sendable {
        case sessionStart(cwd: String)
        case processingStarted(cwd: String)
        case compactingStarted(cwd: String)
        case stop(cwd: String, status: String?)
        case sessionEnd
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
        if let existingSession, existingSession.provider != .cursor {
            return Result(
                session: nil,
                didCreateSession: false,
                debugMessage: "[cursor-lifecycle] ignored provider-mismatch session=\(sessionId) existingProvider=\(existingSession.provider.rawValue)"
            )
        }

        switch event {
        case .sessionStart(let cwd):
            return processSessionStart(existingSession: existingSession, sessionId: sessionId, cwd: cwd)

        case .processingStarted(let cwd):
            return processProcessingStarted(existingSession: existingSession, sessionId: sessionId, cwd: cwd)

        case .compactingStarted(let cwd):
            return processCompactingStarted(existingSession: existingSession, sessionId: sessionId, cwd: cwd)

        case .stop(let cwd, let status):
            return processStop(existingSession: existingSession, sessionId: sessionId, cwd: cwd, status: status)

        case .sessionEnd:
            return processSessionEnd(existingSession: existingSession, sessionId: sessionId)
        }
    }

    private nonisolated static func processSessionStart(
        existingSession: SessionState?,
        sessionId: String,
        cwd: String
    ) -> Result {
        let isNewSession = existingSession == nil
        var session = resolvedCursorSession(
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
            debugMessage: "[cursor-lifecycle] sessionStart session=\(sessionId) cwd=\(session.cwd) phase=\(session.phase)"
        )
    }

    private nonisolated static func processProcessingStarted(
        existingSession: SessionState?,
        sessionId: String,
        cwd: String
    ) -> Result {
        let isNewSession = existingSession == nil
        var session = resolvedCursorSession(
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
            debugMessage: "[cursor-lifecycle] processingStarted session=\(sessionId) cwd=\(session.cwd) phase=\(session.phase)"
        )
    }

    private nonisolated static func processCompactingStarted(
        existingSession: SessionState?,
        sessionId: String,
        cwd: String
    ) -> Result {
        let isNewSession = existingSession == nil
        var session = resolvedCursorSession(
            existingSession ?? createSession(sessionId: sessionId, cwd: cwd),
            cwd: cwd
        )

        session.lastActivity = Date()
        session.completionNotificationAt = nil
        if session.phase.canTransition(to: .compacting) {
            session.phase = .compacting
        }

        return Result(
            session: session,
            didCreateSession: isNewSession,
            debugMessage: "[cursor-lifecycle] compactingStarted session=\(sessionId) cwd=\(session.cwd) phase=\(session.phase)"
        )
    }

    private nonisolated static func processStop(
        existingSession: SessionState?,
        sessionId: String,
        cwd: String,
        status: String?
    ) -> Result {
        let isNewSession = existingSession == nil
        var session = resolvedCursorSession(
            existingSession ?? createSession(sessionId: sessionId, cwd: cwd),
            cwd: cwd
        )
        let now = Date()
        let normalizedStatus = status?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        session.lastActivity = now
        session.phase = .idle
        session.completionNotificationAt = normalizedStatus == nil || normalizedStatus == "completed" ? now : nil
        finishDanglingTools(in: &session, status: normalizedStatus)
        session.toolTracker.inProgress.removeAll()

        return Result(
            session: session,
            didCreateSession: isNewSession,
            debugMessage: "[cursor-lifecycle] stop session=\(sessionId) cwd=\(session.cwd) status=\(normalizedStatus ?? "nil") phase=\(session.phase) items=\(session.chatItems.count)"
        )
    }

    private nonisolated static func processSessionEnd(
        existingSession: SessionState?,
        sessionId: String
    ) -> Result {
        guard var session = existingSession else {
            return Result(
                session: nil,
                didCreateSession: false,
                debugMessage: "[cursor-lifecycle] sessionEnd ignored missing session=\(sessionId)"
            )
        }

        session = resolvedCursorSession(session)
        session.lastActivity = Date()
        if session.phase.canTransition(to: .idle) {
            session.phase = .idle
        }
        finishDanglingTools(in: &session, status: "aborted")
        session.toolTracker.inProgress.removeAll()

        return Result(
            session: session,
            didCreateSession: false,
            debugMessage: "[cursor-lifecycle] sessionEnd preserved session=\(sessionId) phase=\(session.phase) items=\(session.chatItems.count)"
        )
    }

    private nonisolated static func createSession(sessionId: String, cwd: String) -> SessionState {
        SessionState(
            sessionId: sessionId,
            provider: .cursor,
            cwd: cwd,
            projectName: URL(fileURLWithPath: cwd).lastPathComponent,
            phase: .idle
        )
    }

    private nonisolated static func resolvedCursorSession(_ session: SessionState, cwd: String? = nil) -> SessionState {
        let incomingCwd: String? = {
            let trimmed = cwd?.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed?.isEmpty == false ? trimmed : nil
        }()
        let resolvedCwd = session.cwd.isEmpty ? (incomingCwd ?? session.cwd) : session.cwd

        guard session.provider != .cursor || session.cwd != resolvedCwd else {
            return session
        }

        return SessionState(
            sessionId: session.sessionId,
            provider: .cursor,
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

    private nonisolated static func finishDanglingTools(in session: inout SessionState, status: String?) {
        let terminalStatus: ToolStatus
        switch status {
        case "error":
            terminalStatus = .error
        case "aborted":
            terminalStatus = .interrupted
        default:
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
