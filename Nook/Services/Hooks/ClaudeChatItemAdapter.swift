//
//  ClaudeChatItemAdapter.swift
//  Nook
//
//  Stateless adapter that converts Claude's JSONL-based data formats
//  (FileUpdatePayload, [ChatMessage]) into provider-agnostic ChatItemUpdate.
//
//  This is the Task 4 adapter from the unified ChatItem middle layer design:
//  docs/specs/2026-06-16-clause-chatitem-adapter-design.md
//
//  Unlike OpencodeChatItemAdapter, this adapter is stateless because:
//  - Claude's JSONL messages carry stable IDs (message.id)
//  - Block positions come from enumeration (blockIndex)
//  - Tool IDs are globally unique from JSONL
//  - No per-message block counter needed
//
//  Only the JSONL sync path is routed through this adapter. The hook event
//  path (processToolTracking) remains direct because applyChatItemUpdate's
//  lifecycle side effects (phase, conversationInfo, toolTracker) are designed
//  for OpenCode's real-time event stream and would cause phase flickering
//  and conversationInfo overrides for Claude's batch JSONL updates.
//

import Foundation

/// Stateless adapter: Claude JSONL → [ChatItemUpdate].
///
/// All mutations are `.insert` — the adapter has no knowledge of existing
/// session state. Upsert semantics (tool state preservation, text/thinking
/// dedup) are handled by `SessionStore.applyChatItemUpdate()`.
enum ClaudeChatItemAdapter {

    // MARK: - File Update Path

    /// Convert a FileUpdatePayload into ChatItemUpdates.
    /// Replaces `SessionStore.upsertBlocks()` for the JSONL sync path.
    static func updates(fromFileUpdate payload: FileUpdatePayload) -> [ChatItemUpdate] {
        return convertMessages(
            payload.messages,
            sessionId: payload.sessionId,
            completedToolIds: payload.completedToolIds,
            toolResults: payload.toolResults,
            structuredResults: payload.structuredResults
        )
    }

    // MARK: - History Load Path

    /// Convert history load data into ChatItemUpdates.
    /// Same logic as `updates(fromFileUpdate:)` — delegates to the same
    /// conversion by constructing a synthetic payload.
    static func updates(
        fromHistoryLoad messages: [ChatMessage],
        completedTools: Set<String>,
        toolResults: [String: ConversationParser.ToolResult],
        structuredResults: [String: ToolResultData],
        sessionId: String
    ) -> [ChatItemUpdate] {
        let payload = FileUpdatePayload(
            sessionId: sessionId,
            cwd: "",
            messages: messages,
            isIncremental: false,
            completedToolIds: completedTools,
            toolResults: toolResults,
            structuredResults: structuredResults
        )
        return updates(fromFileUpdate: payload)
    }

    // MARK: - Core Conversion

    /// Iterate every message (with messageIndex) and every block (with
    /// blockIndex), producing one ChatItemUpdate per block.
    private static func convertMessages(
        _ messages: [ChatMessage],
        sessionId: String,
        completedToolIds: Set<String>,
        toolResults: [String: ConversationParser.ToolResult],
        structuredResults: [String: ToolResultData]
    ) -> [ChatItemUpdate] {
        var updates: [ChatItemUpdate] = []

        for (_, message) in messages.enumerated() {
            for (blockIndex, block) in message.content.enumerated() {
                // Claude JSONL is append-only + monotonic — the order items
                // appear in `messages` is the order they should render in.
                // `ChatItemSorter.sorted()` short-circuits to a no-op when
                // every item declares `.appendOrder` (or has no ordering
                // entry at all, which is the case for hook-inserted
                // placeholders). We still need `blockIndex` below for ID
                // generation via `ChatItemIdFactory.claudeBlockId(...)`.
                let ordering = BlockOrdering.appendOrder

                switch block {
                case .text(let text):
                    let itemId = ChatItemIdFactory.claudeBlockId(
                        messageId: message.id, typePrefix: "text", blockIndex: blockIndex
                    )
                    let chatBlock: ChatItemBlock = (message.role == .user)
                        ? .userPrompt(text)
                        : .assistantText(text)
                    updates.append(ChatItemUpdate(
                        id: itemId, sessionId: sessionId,
                        block: chatBlock,
                        ordering: ordering,
                        mutation: .insert, provider: .claude,
                        messageTimestamp: message.timestamp
                    ))

                case .thinking(let text):
                    // Skip empty thinking — applyChatItemUpdate also guards
                    // this (line ~703), but filtering here avoids generating
                    // unnecessary updates.
                    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        continue
                    }
                    let itemId = ChatItemIdFactory.claudeBlockId(
                        messageId: message.id, typePrefix: "thinking", blockIndex: blockIndex
                    )
                    updates.append(ChatItemUpdate(
                        id: itemId, sessionId: sessionId,
                        block: .thinking(text),
                        ordering: ordering,
                        mutation: .insert, provider: .claude,
                        messageTimestamp: message.timestamp
                    ))

                case .toolUse(let tool):
                    // Propagate error/interrupted status from toolResults.
                    // completedToolIds alone cannot distinguish success from
                    // rejection — toolResults carries isError + isInterrupted.
                    let toolResult = toolResults[tool.id]
                    let status: ToolStatus = {
                        if toolResult?.isInterrupted == true { return .interrupted }
                        if toolResult?.isError == true { return .error }
                        return completedToolIds.contains(tool.id) ? .success : .running
                    }()
                    let resultText = extractToolResult(tool.id, from: toolResults)

                    // AskUserQuestion fallback: when the tool is rejected,
                    // toolUseResult is a plain string (not a dict), so
                    // parseStructuredResult is never called and
                    // structuredResults[tool.id] is nil. Rebuild the question
                    // content from the tool input so the UI can display it.
                    var structured = structuredResults[tool.id]
                    if tool.name == "AskUserQuestion" {
                        let hadStructured = structured != nil
                        let inputQJson = tool.input["questions"]
                        if structured == nil, let questionsJson = inputQJson {
                            structured = buildAskUserResult(from: questionsJson)
                        }
                        let optCount: Int = {
                            if case .askUserQuestion(let r) = structured {
                                return r.questions.first?.options.count ?? 0
                            }
                            return -1
                        }()
                        DebugLog.shared.write("[claude-adapter] AskUserQuestion id=\(tool.id) hadStructured=\(hadStructured) inputQJsonLen=\(inputQJson?.count ?? 0) structuredOpts=\(optCount)")
                    }

                    updates.append(ChatItemUpdate(
                        id: tool.id, sessionId: sessionId,
                        block: .toolCall(ChatItemToolCall(
                            toolId: tool.id,
                            name: tool.name,
                            input: tool.input,
                            status: status,
                            result: resultText,
                            structuredResult: structured,
                            subagentTools: []
                        )),
                        ordering: ordering,
                        mutation: .insert, provider: .claude,
                        messageTimestamp: message.timestamp
                    ))

                case .image(let imageBlock):
                    let itemId = ChatItemIdFactory.claudeBlockId(
                        messageId: message.id, typePrefix: "image", blockIndex: blockIndex
                    )
                    DebugLog.shared.write("[claude-adapter] IMAGE id=\(itemId) mediaType=\(imageBlock.mediaType) base64Len=\(imageBlock.base64Data.count) msgRole=\(message.role)")
                    updates.append(ChatItemUpdate(
                        id: itemId, sessionId: sessionId,
                        block: .image(imageBlock),
                        ordering: ordering,
                        mutation: .insert, provider: .claude,
                        messageTimestamp: message.timestamp
                    ))

                case .interrupted:
                    let itemId = ChatItemIdFactory.claudeBlockId(
                        messageId: message.id, typePrefix: "interrupted", blockIndex: blockIndex
                    )
                    updates.append(ChatItemUpdate(
                        id: itemId, sessionId: sessionId,
                        block: .interrupted,
                        ordering: ordering,
                        mutation: .insert, provider: .claude,
                        messageTimestamp: message.timestamp
                    ))
                }
            }
        }

        return updates
    }

    // MARK: - Helpers

    /// Extract tool result text from parser results.
    /// Mirrors `upsertBlocks()` lines 1608-1616: stdout > stderr > content.
    private static func extractToolResult(
        _ toolId: String,
        from toolResults: [String: ConversationParser.ToolResult]
    ) -> String? {
        guard let parserResult = toolResults[toolId] else { return nil }
        if let stdout = parserResult.stdout, !stdout.isEmpty { return stdout }
        if let stderr = parserResult.stderr, !stderr.isEmpty { return stderr }
        if let content = parserResult.content, !content.isEmpty { return content }
        return nil
    }

    /// Rebuild AskUserQuestionResult from the JSON-serialized questions
    /// array in tool input. Used when the tool was rejected (toolUseResult
    /// is a plain string, so parseStructuredResult was never called).
    private static func buildAskUserResult(from questionsJson: String) -> ToolResultData? {
        guard let data = questionsJson.data(using: .utf8),
              let questionsArray = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return nil }

        let questions: [QuestionItem] = questionsArray.compactMap { q in
            guard let question = q["question"] as? String else { return nil }
            var options: [QuestionOption] = []
            if let optionsArray = q["options"] as? [[String: Any]] {
                options = optionsArray.compactMap { opt in
                    guard let label = opt["label"] as? String else { return nil }
                    return QuestionOption(
                        label: label,
                        description: opt["description"] as? String
                    )
                }
            }
            return QuestionItem(
                question: question,
                header: q["header"] as? String,
                options: options
            )
        }

        guard !questions.isEmpty else { return nil }
        return .askUserQuestion(AskUserQuestionResult(questions: questions, answers: [:]))
    }
}
