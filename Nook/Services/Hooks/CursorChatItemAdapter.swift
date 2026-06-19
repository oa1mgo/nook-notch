//
//  CursorChatItemAdapter.swift
//  Nook
//
//  Converts Cursor hook payloads into ChatItemUpdate operations.
//

import Foundation

final class CursorChatItemAdapter: @unchecked Sendable {
    nonisolated static let shared = CursorChatItemAdapter()

    struct Result: Sendable {
        var chatItemUpdates: [ChatItemUpdate]
        var passthroughEvents: [CursorSessionEvent]
    }

    private init() {}

    func adaptAndConvert(_ envelope: CursorHookEnvelope) -> Result {
        guard envelope.isCursorPayload else {
            return Result(chatItemUpdates: [], passthroughEvents: [])
        }

        var updates = updates(from: envelope)
        var events: [CursorSessionEvent] = []
        if let event = CursorHookAdapter.adapt(envelope) {
            events.append(event)
        }

        if case .sessionEnd(let sessionId) = events.last {
            clearSession(sessionId)
            updates.removeAll()
        }

        return Result(chatItemUpdates: updates, passthroughEvents: events)
    }

    nonisolated func clearSession(_: String) {}

    private func updates(from envelope: CursorHookEnvelope) -> [ChatItemUpdate] {
        let timestamp = Date()

        switch envelope.normalizedEventName {
        case "beforesubmitprompt":
            guard let prompt = envelope.prompt?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !prompt.isEmpty else {
                return []
            }
            return [textUpdate(
                envelope: envelope,
                typePrefix: "prompt",
                block: .userPrompt(prompt),
                timestamp: timestamp
            )]

        case "afteragentresponse":
            guard let text = envelope.text?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty else {
                return []
            }
            return [textUpdate(
                envelope: envelope,
                typePrefix: "text",
                block: .assistantText(text),
                timestamp: timestamp
            )]

        case "afteragentthought":
            guard let text = envelope.text?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty else {
                return []
            }
            return [textUpdate(
                envelope: envelope,
                typePrefix: "thinking",
                block: .thinking(text),
                timestamp: timestamp
            )]

        case "pretooluse":
            guard let toolName = envelope.toolName else { return [] }
            let toolId = ChatItemIdFactory.toolId(provider: .cursor, rawId: envelope.toolUseId)
            return [ChatItemUpdate(
                id: toolId,
                sessionId: envelope.sessionId,
                block: .toolCall(ChatItemToolCall(
                    toolId: toolId,
                    name: toolName,
                    input: displayInput(envelope),
                    status: .running,
                    result: nil,
                    structuredResult: nil,
                    subagentTools: []
                )),
                ordering: .timestamp(timestamp),
                mutation: .insert,
                provider: .cursor,
                messageTimestamp: timestamp
            )]

        case "posttooluse":
            guard let toolName = envelope.toolName else { return [] }
            let toolId = ChatItemIdFactory.toolId(provider: .cursor, rawId: envelope.toolUseId)
            return [ChatItemUpdate(
                id: toolId,
                sessionId: envelope.sessionId,
                block: .toolCall(ChatItemToolCall(
                    toolId: toolId,
                    name: toolName,
                    input: displayInput(envelope),
                    status: .success,
                    result: envelope.toolOutputSummary,
                    structuredResult: nil,
                    subagentTools: []
                )),
                ordering: .timestamp(timestamp),
                mutation: .updateStatus,
                provider: .cursor,
                messageTimestamp: timestamp
            )]

        case "posttoolusefailure":
            let toolName = envelope.toolName ?? "Tool"
            let toolId = ChatItemIdFactory.toolId(provider: .cursor, rawId: envelope.toolUseId)
            return [ChatItemUpdate(
                id: toolId,
                sessionId: envelope.sessionId,
                block: .toolCall(ChatItemToolCall(
                    toolId: toolId,
                    name: toolName,
                    input: displayInput(envelope),
                    status: .error,
                    result: envelope.errorSummary,
                    structuredResult: nil,
                    subagentTools: []
                )),
                ordering: .timestamp(timestamp),
                mutation: .updateStatus,
                provider: .cursor,
                isError: true,
                messageTimestamp: timestamp
            )]

        default:
            return []
        }
    }

    private func textUpdate(
        envelope: CursorHookEnvelope,
        typePrefix: String,
        block: ChatItemBlock,
        timestamp: Date
    ) -> ChatItemUpdate {
        let id = cursorBlockId(
            sessionId: envelope.sessionId,
            generationId: envelope.generationId,
            typePrefix: typePrefix,
            text: block.stableTextForId
        )

        return ChatItemUpdate(
            id: id,
            sessionId: envelope.sessionId,
            block: block,
            ordering: .timestamp(timestamp),
            mutation: .insert,
            provider: .cursor,
            messageTimestamp: timestamp
        )
    }

    private func displayInput(_ envelope: CursorHookEnvelope) -> [String: String] {
        let input = envelope.displayInput
        if !input.isEmpty { return input }
        if let summary = envelope.inputSummary?.trimmingCharacters(in: .whitespacesAndNewlines),
           !summary.isEmpty {
            return ["summary": summary]
        }
        return [:]
    }

    private func cursorBlockId(
        sessionId: String,
        generationId: String?,
        typePrefix: String,
        text: String?
    ) -> String {
        let generation = generationId ?? "session"
        let textHash = text.map(Self.stableHash) ?? "empty"
        return "cursor-\(sessionId)-\(generation)-\(typePrefix)-\(textHash)"
    }

    private nonisolated static func stableHash(_ text: String) -> String {
        var hash: UInt64 = 1469598103934665603
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1099511628211
        }
        return String(hash, radix: 16)
    }
}

private extension ChatItemBlock {
    var stableTextForId: String? {
        switch self {
        case .userPrompt(let text), .assistantText(let text), .thinking(let text):
            return text
        case .toolCall, .image, .interrupted:
            return nil
        }
    }
}
