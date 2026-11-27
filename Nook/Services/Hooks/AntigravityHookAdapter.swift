//
//  AntigravityHookAdapter.swift
//  Nook
//
//  Maps Antigravity hook envelopes to the lifecycle event set used by Nook.
//

import Foundation

enum AntigravityHookAdapter {
    static func adapt(_ envelope: AntigravityHookEnvelope) -> AntigravitySessionEvent? {
        guard envelope.isAntigravityPayload else { return nil }

        switch envelope.normalizedEventName {
        case "sessionstart":
            return .sessionStart(sessionId: envelope.sessionId, cwd: envelope.cwd)

        case "pretooluse":
            if ToolKind.classify(envelope.toolName) == .askUserQuestion {
                return .waitingForInput(sessionId: envelope.sessionId, cwd: envelope.cwd)
            }
            return .processingStarted(sessionId: envelope.sessionId, cwd: envelope.cwd)

        case "preinvocation", "postinvocation", "posttooluse":
            return .processingStarted(sessionId: envelope.sessionId, cwd: envelope.cwd)

        case "stop":
            return .stop(
                sessionId: envelope.sessionId,
                cwd: envelope.cwd,
                terminationReason: envelope.terminationReason,
                error: envelope.errorSummary
            )

        default:
            return nil
        }
    }
}
