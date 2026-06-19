//
//  CursorHookAdapter.swift
//  Nook
//
//  Maps Cursor hook envelopes to the small event set used by Nook.
//

import Foundation

enum CursorHookAdapter {
    static func adapt(_ envelope: CursorHookEnvelope) -> CursorSessionEvent? {
        guard envelope.isCursorPayload else { return nil }

        switch envelope.normalizedEventName {
        case "sessionstart":
            return .sessionStart(sessionId: envelope.sessionId, cwd: envelope.cwd)

        case "beforesubmitprompt", "pretooluse", "posttooluse", "posttoolusefailure",
             "afteragentresponse", "afteragentthought", "subagentstart", "subagentstop":
            return .processingStarted(sessionId: envelope.sessionId, cwd: envelope.cwd)

        case "precompact":
            return .compactingStarted(sessionId: envelope.sessionId, cwd: envelope.cwd)

        case "stop":
            return .stop(
                sessionId: envelope.sessionId,
                cwd: envelope.cwd,
                status: envelope.status
            )

        case "sessionend":
            return .sessionEnd(sessionId: envelope.sessionId)

        default:
            return nil
        }
    }
}
