//
//  ChatItemUpdate.swift
//  Nook
//
//  Provider-agnostic intermediate format for chat item operations.
//  All providers (Claude, OpenCode, Codex) translate their native events
//  into ChatItemUpdate before passing to SessionStore.applyChatItemUpdate().
//
//  Design spec: docs/specs/2026-06-11-unified-chatitem-middle-layer-design.md
//

import Foundation

// MARK: - ChatItemUpdate

/// A single chat item operation — insert, update, updateStatus, or remove.
/// Carries ordering information so SessionStore can maintain correct display
/// order regardless of event arrival timing (fixes the opencode thinking
/// ordering bug where reasoning blocks appeared after tool blocks).
struct ChatItemUpdate: Sendable, Identifiable {
    let id: String                    // Stable unique identifier
    let sessionId: String
    let block: ChatItemBlock          // Content payload
    let ordering: BlockOrdering       // Sort key (provider-specific)
    let mutation: BlockMutation       // Operation type
    let provider: SessionProvider     // Source provider
    /// Provider-computed error flag for tool completions. Includes
    /// provider-specific error signals (e.g. opencode's `<bash_metadata>`
    /// footer for bash timeout/non-zero-exit) that can't be derived from
    /// the `error` string alone. Ignored for non-tool updates.
    let isError: Bool

    init(
        id: String, sessionId: String, block: ChatItemBlock,
        ordering: BlockOrdering, mutation: BlockMutation,
        provider: SessionProvider, isError: Bool = false
    ) {
        self.id = id
        self.sessionId = sessionId
        self.block = block
        self.ordering = ordering
        self.mutation = mutation
        self.provider = provider
        self.isError = isError
    }
}

// MARK: - ChatItemBlock

/// Content payload for a chat item. Mirrors ChatHistoryItemType but is
/// provider-agnostic and Sendable. Conversion methods bridge to the
/// existing ChatHistoryItemType used by the UI layer.
enum ChatItemBlock: Sendable, Equatable {
    case userPrompt(String)
    case assistantText(String)
    case thinking(String)
    case toolCall(ChatItemToolCall)
    case image(ImageBlock)
    case interrupted
}

/// Tool call data within a ChatItemBlock.
struct ChatItemToolCall: Sendable, Equatable {
    let toolId: String
    let name: String
    let input: [String: String]
    var status: ToolStatus
    var result: String?
    var structuredResult: ToolResultData?
    var subagentTools: [SubagentToolCall]
}

// MARK: - BlockOrdering

/// Sort key for chat items. Each provider uses the variant that matches
/// its data source:
/// - Claude/Codex JSONL → filePosition (messageIndex + blockIndex from file)
/// - OpenCode events → messageRelative (messageId + per-message blockIndex)
/// - Fallback → timestamp
enum BlockOrdering: Sendable, Equatable {
    /// Position within a JSONL file (Claude / Codex transcript).
    case filePosition(messageIndex: Int, blockIndex: Int)
    /// Position relative to a message in an event stream (OpenCode).
    /// messageId encodes chronological order (opencode message IDs are
    /// monotonic); typePriority ensures logical ordering within a message
    /// (thinking=0 < tool=1 < text=2) regardless of event arrival order;
    /// blockIndex preserves insertion order within the same type.
    case messageRelative(messageId: String, typePriority: Int, blockIndex: Int)
    /// Fallback: raw timestamp ordering (Codex live events).
    case timestamp(Date)
}

// MARK: - BlockMutation

/// The type of operation a ChatItemUpdate represents.
enum BlockMutation: Sendable, Equatable {
    /// Insert a new item (or replace if ID already exists).
    case insert
    /// Full content replacement.
    case update
    /// Only update tool status / result fields.
    case updateStatus
    /// Remove the item by ID.
    case remove
}

// MARK: - ChatItemBlock ↔ ChatHistoryItemType Conversion

extension ChatItemBlock {
    /// Convert to the UI-layer ChatHistoryItemType.
    func toChatHistoryItemType() -> ChatHistoryItemType {
        switch self {
        case .userPrompt(let text):
            return .user(text)
        case .assistantText(let text):
            return .assistant(text)
        case .thinking(let text):
            return .thinking(text)
        case .toolCall(let tc):
            return .toolCall(ToolCallItem(
                name: tc.name,
                input: tc.input,
                status: tc.status,
                result: tc.result,
                structuredResult: tc.structuredResult,
                subagentTools: tc.subagentTools
            ))
        case .image(let block):
            return .image(block)
        case .interrupted:
            return .interrupted
        }
    }

    /// Create from the UI-layer ChatHistoryItemType.
    static func from(_ type: ChatHistoryItemType, toolId: String? = nil) -> ChatItemBlock {
        switch type {
        case .user(let text):
            return .userPrompt(text)
        case .assistant(let text):
            return .assistantText(text)
        case .thinking(let text):
            return .thinking(text)
        case .toolCall(let item):
            return .toolCall(ChatItemToolCall(
                toolId: toolId ?? "",
                name: item.name,
                input: item.input,
                status: item.status,
                result: item.result,
                structuredResult: item.structuredResult,
                subagentTools: item.subagentTools
            ))
        case .image(let block):
            return .image(block)
        case .interrupted:
            return .interrupted
        }
    }
}
