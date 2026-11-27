//
//  SessionMonitor.swift
//  Nook
//
//  MainActor wrapper around SessionStore for UI binding.
//  Publishes SessionState arrays for SwiftUI observation.
//

import Combine
import Foundation
import os.log

@MainActor
class SessionMonitor: ObservableObject {
    @Published var instances: [SessionState] = []
    @Published var pendingInstances: [SessionState] = []
    @Published var completionNotification: SessionCompletionNotification?
    /// Running OpenCode plugin version (nil until the plugin handshake).
    @Published var opencodePluginVersion: String?

    private static let logger = Logger(subsystem: "com.celestial.Nook", category: "SessionMonitor")

    private var cancellables = Set<AnyCancellable>()

    init() {
        SessionStore.shared.sessionsPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] sessions in
                self?.updateFromSessions(sessions)
            }
            .store(in: &cancellables)

        SessionStore.shared.completionNotificationsPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                self?.completionNotification = notification
            }
            .store(in: &cancellables)

        SessionStore.shared.opencodePluginVersionPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] version in
                self?.opencodePluginVersion = version
            }
            .store(in: &cancellables)
    }

    // MARK: - Permission Handling

    func approvePermission(sessionId: String) {
        Task {
            guard let session = await SessionStore.shared.session(for: sessionId),
                  let permission = session.activePermission else {
                Self.logger.warning("approvePermission: session or permission not found sessionId=\(sessionId.prefix(8), privacy: .public)")
                return
            }

            Self.logger.info("approvePermission: sessionId=\(sessionId.prefix(8), privacy: .public) toolUseId=\(permission.toolUseId.prefix(12), privacy: .public) requestId=\(permission.opencodeRequestId ?? "nil", privacy: .public)")

            // OpenCode permission prompts are replied to via the plugin's
            // command socket (per_xxx id), not the Claude hook socket. When
            // the active permission carries an opencodeRequestId, route the
            // approval there and skip the Claude/Codex hook response.
            if let requestId = permission.opencodeRequestId {
                Self.logger.info("approvePermission: sending permission.reply to opencode requestId=\(requestId, privacy: .public) pid=\(session.pid ?? -1, privacy: .public) cwd=\(session.cwd, privacy: .public)")
                OpencodeCommandSocket.shared.sendCommand([
                    "cmd": "permission.reply",
                    "requestId": requestId,
                    "reply": "once",
                    "directory": session.cwd,
                ], pid: session.pid)
                await SessionStore.shared.process(
                    .permissionApproved(sessionId: sessionId, toolUseId: permission.toolUseId)
                )
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

    /// Approve a permission prompt with the option to remember the decision
    /// for the rest of the session. Only meaningful for OpenCode sessions —
    /// Claude/Codex fall back to the single-shot approvePermission path.
    func approvePermission(sessionId: String, always: Bool) {
        Task {
            guard let session = await SessionStore.shared.session(for: sessionId),
                  let permission = session.activePermission else {
                return
            }

            // OpenCode path: send the reply through the command socket with
            // "once" or "always". If there's no opencodeRequestId (Claude/Codex
            // session), fall back to the standard single-shot path.
            guard let requestId = permission.opencodeRequestId else {
                if !always {
                    approvePermission(sessionId: sessionId)
                }
                return
            }

            OpencodeCommandSocket.shared.sendCommand([
                "cmd": "permission.reply",
                "requestId": requestId,
                "reply": always ? "always" : "once",
                "directory": session.cwd,
            ], pid: session.pid)

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

            // OpenCode deny path — reply "reject" through the command socket.
            if let requestId = permission.opencodeRequestId {
                OpencodeCommandSocket.shared.sendCommand([
                    "cmd": "permission.reply",
                    "requestId": requestId,
                    "reply": "reject",
                    "directory": session.cwd,
                ], pid: session.pid)
                await SessionStore.shared.process(
                    .permissionDenied(sessionId: sessionId, toolUseId: permission.toolUseId, reason: reason)
                )
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
