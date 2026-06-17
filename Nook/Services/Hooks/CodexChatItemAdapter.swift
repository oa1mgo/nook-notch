//
//  CodexChatItemAdapter.swift
//  Nook
//
//  Converts Codex transcript rows and live hook events into ChatItemUpdate.
//

import Foundation

enum CodexChatItemAdapter {
    nonisolated static func messageUpdate(
        sessionId: String,
        lineIndex: Int,
        role: String,
        text: String,
        timestamp: Date
    ) -> ChatItemUpdate? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let block: ChatItemBlock = role == "user"
            ? .userPrompt(trimmed)
            : .assistantText(trimmed)

        return ChatItemUpdate(
            id: ChatItemIdFactory.codexBlockId(sessionId: sessionId, lineIndex: lineIndex),
            sessionId: sessionId,
            block: block,
            ordering: .appendOrder,
            mutation: .insert,
            provider: .codex,
            messageTimestamp: timestamp
        )
    }

    nonisolated static func toolCallUpdate(
        sessionId: String,
        lineIndex: Int,
        callId: String?,
        name: String,
        input: [String: String],
        timestamp: Date
    ) -> ChatItemUpdate {
        let toolId = callId ?? "codex-tool-\(sessionId)-\(lineIndex)"
        return ChatItemUpdate(
            id: toolId,
            sessionId: sessionId,
            block: .toolCall(ChatItemToolCall(
                toolId: toolId,
                name: name,
                input: input,
                status: .running,
                result: nil,
                structuredResult: nil,
                subagentTools: []
            )),
            ordering: .appendOrder,
            mutation: .insert,
            provider: .codex,
            messageTimestamp: timestamp
        )
    }

    nonisolated static func toolOutputUpdate(
        sessionId: String,
        callId: String,
        result: String?,
        timestamp: Date
    ) -> ChatItemUpdate {
        ChatItemUpdate(
            id: callId,
            sessionId: sessionId,
            block: .toolCall(ChatItemToolCall(
                toolId: callId,
                name: "Tool",
                input: [:],
                status: .success,
                result: result,
                structuredResult: nil,
                subagentTools: []
            )),
            ordering: .appendOrder,
            mutation: .updateStatus,
            provider: .codex,
            messageTimestamp: timestamp
        )
    }

    nonisolated static func updates(from event: CodexSessionEvent, timestamp: Date = Date()) -> [ChatItemUpdate] {
        switch event {
        case .preTool(let sessionId, _, let toolName, let toolUseId, let input, let inputSummary):
            guard let toolUseId else { return [] }
            let displayInput = displayInput(input: input, inputSummary: inputSummary)
            return [ChatItemUpdate(
                id: toolUseId,
                sessionId: sessionId,
                block: .toolCall(ChatItemToolCall(
                    toolId: toolUseId,
                    name: toolName,
                    input: displayInput,
                    status: .running,
                    result: nil,
                    structuredResult: nil,
                    subagentTools: []
                )),
                ordering: .timestamp(timestamp),
                mutation: .insert,
                provider: .codex,
                messageTimestamp: timestamp
            )]

        case .postTool(let sessionId, _, let toolName, let toolUseId, let inputSummary, let output, let isError):
            guard let toolUseId else { return [] }
            return [ChatItemUpdate(
                id: toolUseId,
                sessionId: sessionId,
                block: .toolCall(ChatItemToolCall(
                    toolId: toolUseId,
                    name: toolName,
                    input: displayInput(input: [:], inputSummary: inputSummary),
                    status: isError ? .error : .success,
                    result: output,
                    structuredResult: nil,
                    subagentTools: []
                )),
                ordering: .timestamp(timestamp),
                mutation: .updateStatus,
                provider: .codex,
                isError: isError,
                messageTimestamp: timestamp
            )]

        case .sessionStart, .userPromptSubmit, .permissionRequest,
             .compactingStarted, .compactingFinished, .subagentStarted,
             .subagentStopped, .stop:
            return []
        }
    }

    private nonisolated static func displayInput(input: [String: String], inputSummary: String?) -> [String: String] {
        if !input.isEmpty {
            return input
        }

        if let summary = inputSummary?.trimmingCharacters(in: .whitespacesAndNewlines),
           !summary.isEmpty {
            return ["summary": summary]
        }

        return [:]
    }
}
