//
//  CodexHookAdapter.swift
//  Nook
//
//  Maps Codex hook envelopes to the small event set used by V1.
//

import Foundation

enum CodexHookAdapter {
    static func adapt(_ envelope: CodexHookEnvelope) -> CodexSessionEvent? {
        switch envelope.normalizedEventName {
        case "sessionstart":
            return .sessionStart(sessionId: envelope.sessionId, cwd: envelope.cwd)

        case "userpromptsubmit":
            return .userPromptSubmit(
                sessionId: envelope.sessionId,
                cwd: envelope.cwd,
                prompt: envelope.prompt
            )

        case "pretooluse", "prebashtool":
            guard let toolName = envelope.toolName else { return nil }
            return .preTool(
                sessionId: envelope.sessionId,
                cwd: envelope.cwd,
                toolName: toolName,
                toolUseId: envelope.toolUseId,
                input: envelope.displayInput,
                inputSummary: envelope.inputSummary
            )

        case "posttooluse", "postbashtool":
            guard let toolName = envelope.toolName else { return nil }
            return .postTool(
                sessionId: envelope.sessionId,
                cwd: envelope.cwd,
                toolName: toolName,
                toolUseId: envelope.toolUseId,
                inputSummary: envelope.inputSummary
            )

        case "permissionrequest":
            return .waitingForUserInput(sessionId: envelope.sessionId, cwd: envelope.cwd)

        case "precompact":
            return .compactingStarted(sessionId: envelope.sessionId, cwd: envelope.cwd)

        case "postcompact":
            return .compactingFinished(sessionId: envelope.sessionId, cwd: envelope.cwd)

        case "subagentstart":
            return .subagentStarted(sessionId: envelope.sessionId, cwd: envelope.cwd)

        case "subagentstop":
            return .subagentStopped(sessionId: envelope.sessionId, cwd: envelope.cwd)

        case "stop":
            return .stop(sessionId: envelope.sessionId, cwd: envelope.cwd)

        default:
            return nil
        }
    }
}
