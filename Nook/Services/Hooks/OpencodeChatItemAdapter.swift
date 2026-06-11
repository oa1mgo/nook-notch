//
//  OpencodeChatItemAdapter.swift
//  Nook
//
//  Wraps OpencodeHookAdapter to produce [ChatItemUpdate] with proper
//  BlockOrdering, fixing the thinking-ordering bug where reasoning blocks
//  from a later message could appear after tool blocks from an earlier one.
//
//  This is the Task 2 adapter from the unified ChatItem middle layer design:
//  docs/specs/2026-06-11-unified-chatitem-middle-layer-design.md
//

import Foundation

/// Stateful adapter that converts OpencodeSessionEvent into ChatItemUpdate
/// with proper per-message block indexing. Maintains the messageId context
/// that the stateless OpencodeHookAdapter cannot carry.
///
/// Thread safety: all mutable state is guarded by `lock`.
final class OpencodeChatItemAdapter: @unchecked Sendable {
    static let shared = OpencodeChatItemAdapter()

    private let lock = NSLock()

    /// sessionID → most recently seen messageId (set by message.updated events)
    private var currentMessageIdBySession: [String: String] = [:]

    /// sessionID → [messageId: blockIndex] — per-message monotonic counter
    /// for generating BlockOrdering.messageRelative keys.
    private var blockIndexByMessage: [String: [String: Int]] = [:]

    private init() {}

    // MARK: - Result Type

    /// Result of adapting an opencode envelope: chat item updates (for the
    /// unified ChatItemUpdate path) and passthrough events (session lifecycle,
    /// subagent events that still need the old SessionStore dispatch).
    struct AdaptResult {
        let chatItemUpdates: [ChatItemUpdate]
        let passthroughEvents: [OpencodeSessionEvent]
    }

    // MARK: - Public API

    /// Convert a raw envelope into ChatItemUpdates + passthrough events.
    /// Internally delegates to OpencodeHookAdapter.adapt() for event parsing,
    /// then separates chat-item events (converted with BlockOrdering) from
    /// lifecycle/subagent events (passed through unchanged).
    func adaptAndConvert(_ envelope: OpencodeHookEnvelope) -> AdaptResult {
        let events = OpencodeHookAdapter.adapt(envelope)
        guard !events.isEmpty else {
            return AdaptResult(chatItemUpdates: [], passthroughEvents: [])
        }

        // Extract messageId from the envelope for context tracking
        let props = envelope.properties ?? [:]
        let sessionId = (props["sessionID"]?.value as? String) ?? "?"

        // For message.updated events, update the current messageId context
        if envelope.type == "message.updated",
           let info = props["info"]?.value as? [String: Any],
           let messageId = info["id"] as? String, !messageId.isEmpty {
            lock.lock()
            currentMessageIdBySession[sessionId] = messageId
            lock.unlock()
        }

        // For message.part.updated with tool type, also update context
        // (tool parts carry messageID in the part payload)
        if envelope.type == "message.part.updated",
           let part = props["part"]?.value as? [String: Any],
           let messageId = part["messageID"] as? String, !messageId.isEmpty {
            lock.lock()
            currentMessageIdBySession[sessionId] = messageId
            lock.unlock()
        }

        // Separate chat-item events from passthrough events
        var chatItemUpdates: [ChatItemUpdate] = []
        var passthroughEvents: [OpencodeSessionEvent] = []

        for event in events {
            if isChatItemEvent(event) {
                chatItemUpdates.append(contentsOf: convertEvent(event, sessionId: sessionId))
            } else {
                passthroughEvents.append(event)
            }
        }

        return AdaptResult(
            chatItemUpdates: chatItemUpdates,
            passthroughEvents: passthroughEvents
        )
    }

    /// Clear all state for a session (call on session end / cleanup).
    func clearSession(_ sessionId: String) {
        lock.lock()
        currentMessageIdBySession.removeValue(forKey: sessionId)
        blockIndexByMessage.removeValue(forKey: sessionId)
        lock.unlock()
    }

    // MARK: - Event Classification

    private func isChatItemEvent(_ event: OpencodeSessionEvent) -> Bool {
        switch event {
        case .userPromptSubmitted, .assistantThinking, .assistantText,
             .preTool, .postTool:
            return true
        case .sessionStart, .processingStarted, .waitingForUserInput, .stop,
             .subagentStarted, .subagentToolExecuted, .subagentToolCompleted, .subagentStopped:
            return false
        }
    }

    // MARK: - Event Conversion

    private func convertEvent(_ event: OpencodeSessionEvent, sessionId: String) -> [ChatItemUpdate] {
        switch event {
        case .userPromptSubmitted(let sid, _, let prompt, let messageId):
            guard let text = prompt, !text.isEmpty else { return [] }
            let msgId = messageId ?? lookupMessageId(for: sid)
            let idx = nextBlockIndex(sessionId: sid, messageId: msgId)
            let id = ChatItemIdFactory.opencodeBlockId(messageId: msgId, typePrefix: "prompt", blockIndex: idx)
            return [ChatItemUpdate(
                id: id, sessionId: sid,
                block: .userPrompt(text),
                ordering: .messageRelative(messageId: msgId, typePriority: Self.typePriority(for: .userPrompt(text)), blockIndex: idx),
                mutation: .insert, provider: .opencode
            )]

        case .assistantThinking(let sid, _, let text, let messageId):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return [] }
            let msgId = messageId ?? lookupMessageId(for: sid)
            let idx = nextBlockIndex(sessionId: sid, messageId: msgId)
            let id = ChatItemIdFactory.opencodeBlockId(messageId: msgId, typePrefix: "thinking", blockIndex: idx)
            return [ChatItemUpdate(
                id: id, sessionId: sid,
                block: .thinking(trimmed),
                ordering: .messageRelative(messageId: msgId, typePriority: Self.typePriority(for: .thinking(trimmed)), blockIndex: idx),
                mutation: .insert, provider: .opencode
            )]

        case .assistantText(let sid, _, let text, let messageId):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return [] }
            let msgId = messageId ?? lookupMessageId(for: sid)
            let idx = nextBlockIndex(sessionId: sid, messageId: msgId)
            let id = ChatItemIdFactory.opencodeBlockId(messageId: msgId, typePrefix: "text", blockIndex: idx)
            return [ChatItemUpdate(
                id: id, sessionId: sid,
                block: .assistantText(trimmed),
                ordering: .messageRelative(messageId: msgId, typePriority: Self.typePriority(for: .assistantText(trimmed)), blockIndex: idx),
                mutation: .insert, provider: .opencode
            )]

        case .preTool(let sid, _, let toolName, let toolUseId, let inputSummary, let messageId):
            let toolId = toolUseId ?? makeFallbackToolId(sessionId: sid)
            let msgId = messageId ?? lookupMessageId(for: sid)
            let idx = nextBlockIndex(sessionId: sid, messageId: msgId)
            let input: [String: String] = {
                if ToolCallItem.kind(of: toolName) == .task, let desc = inputSummary?.trimmingCharacters(in: .whitespacesAndNewlines) {
                    return ["description": String(desc.prefix(80))]
                }
                return inputSummary.map { ["command": $0] } ?? [:]
            }()
            return [ChatItemUpdate(
                id: toolId, sessionId: sid,
                block: .toolCall(ChatItemToolCall(
                    toolId: toolId, name: toolName,
                    input: input, status: .running,
                    result: nil, structuredResult: nil,
                    subagentTools: []
                )),
                ordering: .messageRelative(messageId: msgId, typePriority: Self.typePriority(for: .toolCall(ChatItemToolCall(toolId: toolId, name: toolName, input: input, status: .running, result: nil, structuredResult: nil, subagentTools: []))), blockIndex: idx),
                mutation: .insert, provider: .opencode
            )]

        case .postTool(let sid, _, let toolName, let toolUseId, _, let output, let error, let messageId):
            let toolId = toolUseId ?? makeFallbackToolId(sessionId: sid)
            let msgId = messageId ?? lookupMessageId(for: sid)
            // Bash error detection — mirror the two-signal check from
            // SessionStore.tailContainsBashMetadata: opencode appends a
            // <bash_metadata> footer for timeout/abort/non-zero-exit on
            // bash tools. Without this, a bash timeout with no `error`
            // field would incorrectly show as success (green).
            let isBash = ToolKind.classify(toolName) == .bash
            let outputIsError = (error?.isEmpty == false)
                || (isBash && Self.tailContainsBashMetadata(output))
            let finalStatus: ToolStatus = outputIsError ? .error : .success
            let resultBody: String? = {
                if let output, !output.isEmpty { return output }
                if let error, !error.isEmpty { return error }
                return nil
            }()
            return [ChatItemUpdate(
                id: toolId, sessionId: sid,
                block: .toolCall(ChatItemToolCall(
                    toolId: toolId, name: toolName,
                    input: [:], status: finalStatus,
                    result: resultBody, structuredResult: nil,
                    subagentTools: []
                )),
                ordering: .messageRelative(messageId: msgId, typePriority: 1, blockIndex: 0),
                mutation: .updateStatus, provider: .opencode,
                isError: outputIsError
            )]

        case .sessionStart, .processingStarted, .waitingForUserInput, .stop,
             .subagentStarted, .subagentToolExecuted, .subagentToolCompleted, .subagentStopped:
            return []
        }
    }

    // MARK: - State Management

    private func lookupMessageId(for sessionId: String) -> String {
        lock.lock()
        defer { lock.unlock() }
        return currentMessageIdBySession[sessionId] ?? "unknown-\(sessionId)"
    }

    private func nextBlockIndex(sessionId: String, messageId: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        let current = blockIndexByMessage[sessionId]?[messageId] ?? 0
        if blockIndexByMessage[sessionId] == nil {
            blockIndexByMessage[sessionId] = [:]
        }
        blockIndexByMessage[sessionId]?[messageId] = current + 1
        return current
    }

    private func makeFallbackToolId(sessionId: String) -> String {
        let millis = Int(Date().timeIntervalSince1970 * 1000)
        return "opencode-bash-\(sessionId)-\(millis)"
    }

    /// Check whether the tail of a bash tool's output contains the
    /// `<bash_metadata>` footer that opencode appends for timeout, abort,
    /// or non-zero-exit. Only the last 1KB is checked to avoid scanning
    /// large outputs (e.g. `cat` of a big file).
    private static func tailContainsBashMetadata(_ output: String?) -> Bool {
        guard let output, !output.isEmpty else { return false }
        let tail = output.suffix(1024)
        return tail.contains("<bash_metadata>")
    }

    // MARK: - Type Priority

    /// Logical ordering within a message: thinking before tools before text.
    /// This ensures correct display order even when opencode streams events
    /// out of logical sequence (e.g. tool events arriving before thinking).
    private static func typePriority(for block: ChatItemBlock) -> Int {
        switch block {
        case .thinking:    return 0
        case .toolCall:    return 1
        case .assistantText: return 2
        case .userPrompt:  return 0  // only block in its message
        case .image:       return 1
        case .interrupted: return 99
        }
    }

}
