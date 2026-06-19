//
//  ChatItemUpdate.swift
//  Nook
//
//  Provider-agnostic intermediate format for chat item operations.
//  All providers (Claude, OpenCode, Codex, Cursor) translate their native events
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
    /// Timestamp of the source message, so all blocks from the same
    /// message share one timestamp. This keeps blocks grouped together
    /// when ChatItemSorter falls back to timestamp comparison (e.g.
    /// hook-created items have nil ordering).
    let messageTimestamp: Date?

    init(
        id: String, sessionId: String, block: ChatItemBlock,
        ordering: BlockOrdering, mutation: BlockMutation,
        provider: SessionProvider, isError: Bool = false,
        messageTimestamp: Date? = nil
    ) {
        self.id = id
        self.sessionId = sessionId
        self.block = block
        self.ordering = ordering
        self.mutation = mutation
        self.provider = provider
        self.isError = isError
        self.messageTimestamp = messageTimestamp
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

/// Sort key for chat items. Each provider picks the variant that matches
/// its data source's ordering guarantees:
///
/// | Provider data shape | Recommended case |
/// | --- | --- |
/// | append-only, monotonic source (Claude JSONL, hook events) | `.appendOrder` |
/// | event stream with out-of-order arrival (OpenCode) | `.messageRelative` |
/// | full-file parse with globally-stable index | `.filePosition` |
/// | nothing else applies | `.timestamp` |
///
/// **Adding a new provider?** Default to `.appendOrder` unless you can
/// prove your source produces items out of display order.
enum BlockOrdering: Sendable, Equatable {
    /// Position within a JSONL file (full-file parse only).
    ///
    /// ⚠ Do NOT use on incremental sync paths — the (messageIndex,
    /// blockIndex) tuple is only stable when `messages` is the complete
    /// file. On an incremental parse that returns only newly-appended
    /// messages, messageIndex resets to 0 and the new items get sorted
    /// to the top of the chat. Use `.appendOrder` instead in that case.
    case filePosition(messageIndex: Int, blockIndex: Int)
    /// Position relative to a message in an event stream (OpenCode).
    /// messageId encodes chronological order (opencode message IDs are
    /// monotonic); typePriority ensures logical ordering within a message
    /// (thinking=0 < tool=1 < text=2) regardless of event arrival order;
    /// blockIndex preserves insertion order within the same type.
    case messageRelative(messageId: String, typePriority: BlockTypePriority, blockIndex: Int)
    /// Fallback: raw timestamp ordering (Codex live events).
    case timestamp(Date)
    /// Provider declares: append order IS display order — `ChatItemSorter`
    /// must not reposition these items.
    ///
    /// Use for append-only + monotonic data sources where the order items
    /// are appended to `session.chatItems` already matches the order they
    /// should render in. Examples:
    /// - Claude JSONL transcript (lines are written in turn order)
    /// - Hook event stream (events fire in the order Claude writes them)
    ///
    /// `ChatItemSorter.sorted()` has a fast path that returns the input
    /// array verbatim when every item declares `.appendOrder` (or has no
    /// ordering entry at all — see the sorter doc for why missing is
    /// treated the same way).
    case appendOrder
}

// MARK: - BlockTypePriority

/// Causal ordering of block types within a single message turn.
///
/// LLM generation follows a strict causal chain:
///   reasoning (think) → tool use (act) → text response (respond)
///
/// OpenCode's event bus emits `message.part.updated` events in stream-
/// processing order, NOT in causal order — tool parts may arrive before
/// the reasoning final-text event. This is an inherent property of the
/// event-driven architecture, not a bug:
///
///   - opencode stores message parts in arrival order (see
///     `toModelMessagesEffect` in `message-v2.ts` which iterates
///     `msg.parts` without reordering)
///   - The Anthropic provider adapter reorders reasoning before tool_use
///     at API call time (commit e8d6d1c, PR #10474)
///   - Multiple issues confirm: #9364 ("assistant message content order
///     causes API error"), #3077 ("Expected thinking, but found tool_use")
///
/// Nook mirrors this two-phase approach: events are stored in arrival
/// order (blockIndex via `nextBlockIndex`), and the correct display
/// order is reconstructed at sort time using this enum as a tiebreaker
/// within the same message — exactly what opencode's provider adapter
/// does for the API layer.
enum BlockTypePriority: Int, Sendable {
    case reasoning = 0
    case action    = 1
    case response  = 2
    case terminal  = 99

    /// Derive the causal priority from a block type.
    static func forBlock(_ block: ChatItemBlock) -> BlockTypePriority {
        switch block {
        case .thinking:      return .reasoning
        case .toolCall:      return .action
        case .assistantText: return .response
        case .userPrompt:    return .reasoning  // only block in its message
        case .image:         return .action
        case .interrupted:   return .terminal
        }
    }
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
