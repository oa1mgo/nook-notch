//
//  AntigravityChatItemAdapter.swift
//  Nook
//
//  Converts Antigravity hook payloads into ChatItemUpdate operations.
//

import Foundation

final class AntigravityChatItemAdapter: @unchecked Sendable {
    nonisolated static let shared = AntigravityChatItemAdapter()

    struct Result: Sendable {
        var chatItemUpdates: [ChatItemUpdate]
        var passthroughEvents: [AntigravitySessionEvent]
    }

    private init() {}

    func adaptAndConvert(_ envelope: AntigravityHookEnvelope) -> Result {
        guard envelope.isAntigravityPayload else {
            return Result(chatItemUpdates: [], passthroughEvents: [])
        }

        let updates = updates(from: envelope)
        var events: [AntigravitySessionEvent] = []
        if let event = AntigravityHookAdapter.adapt(envelope) {
            events.append(event)
        }

        return Result(chatItemUpdates: updates, passthroughEvents: events)
    }

    nonisolated func clearSession(_: String) {}

    private func updates(from envelope: AntigravityHookEnvelope) -> [ChatItemUpdate] {
        let timestamp = Date()

        switch envelope.normalizedEventName {
        case "preinvocation":
            guard let prompt = envelope.lastUserInput?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !prompt.isEmpty else {
                return []
            }
            let id = "antigravity-\(envelope.sessionId)-prompt-\(Self.stableHash(prompt))"
            return [ChatItemUpdate(
                id: id,
                sessionId: envelope.sessionId,
                block: .userPrompt(prompt),
                ordering: .timestamp(timestamp),
                mutation: .insert,
                provider: .antigravity,
                messageTimestamp: timestamp
            )]

        case "pretooluse":
            guard let toolName = envelope.toolName else { return [] }
            let toolId = ChatItemIdFactory.toolId(provider: .antigravity, rawId: envelope.toolUseId)
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
                provider: .antigravity,
                messageTimestamp: timestamp
            )]

        case "posttooluse":
            guard let toolName = envelope.toolName else { return [] }
            let toolId = ChatItemIdFactory.toolId(provider: .antigravity, rawId: envelope.toolUseId)
            let errorMessage = envelope.errorSummary
            let isError = errorMessage != nil
            let toolBlock = ChatItemBlock.toolCall(ChatItemToolCall(
                toolId: toolId,
                name: toolName,
                input: displayInput(envelope),
                status: isError ? .error : .success,
                result: errorMessage,
                structuredResult: nil,
                subagentTools: []
            ))
            // Emit `.insert` followed by `.updateStatus` so standalone PostToolUse
            // (when PreToolUse is not registered) creates the completed tool item,
            // while a PreToolUse -> PostToolUse pair still updates status cleanly.
            return [
                ChatItemUpdate(
                    id: toolId,
                    sessionId: envelope.sessionId,
                    block: toolBlock,
                    ordering: .timestamp(timestamp),
                    mutation: .insert,
                    provider: .antigravity,
                    isError: isError,
                    messageTimestamp: timestamp
                ),
                ChatItemUpdate(
                    id: toolId,
                    sessionId: envelope.sessionId,
                    block: toolBlock,
                    ordering: .timestamp(timestamp),
                    mutation: .updateStatus,
                    provider: .antigravity,
                    isError: isError,
                    messageTimestamp: timestamp
                )
            ]

        default:
            return []
        }
    }

    private func displayInput(_ envelope: AntigravityHookEnvelope) -> [String: String] {
        let input = envelope.displayInput
        if !input.isEmpty { return input }
        if let summary = envelope.inputSummary?.trimmingCharacters(in: .whitespacesAndNewlines),
           !summary.isEmpty {
            return ["summary": summary]
        }
        return [:]
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
