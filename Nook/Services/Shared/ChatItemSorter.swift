//
//  ChatItemSorter.swift
//  Nook
//
//  Sorts chat items using provider-specific BlockOrdering keys.
//  Replaces naive append-order with logical ordering based on the
//  provider's data model (file position, message-relative, or timestamp).
//
//  Design spec: docs/specs/2026-06-11-unified-chatitem-middle-layer-design.md
//

import Foundation

// MARK: - ChatItemSorter

enum ChatItemSorter {
    /// Sort chat items using the stored ordering keys. Items without a
    /// stored ordering fall back to timestamp comparison.
    ///
    /// **Fast path**: when every item declares `.appendOrder` (or has no
    /// entry in `orderings` at all), the call returns `items` verbatim —
    /// no sort is performed and the original array identity is preserved
    /// (a small SwiftUI diffing win). Providers whose data source is
    /// append-only and monotonic (Claude JSONL, hook events) emit
    /// `.appendOrder`; the hook path also appends items without ever
    /// writing to `orderings`, and a missing entry is treated the same
    /// way — both signals say "the order I appended is the order to
    /// display".
    nonisolated static func sorted(
        _ items: [ChatHistoryItem],
        orderings: [String: BlockOrdering]
    ) -> [ChatHistoryItem] {
        // Fast path: nothing needs reordering. Avoids an unstable sort
        // that could shuffle equal-ordering items, and keeps the array
        // identity stable for SwiftUI.
        let everyItemIsAppendOrder = items.allSatisfy { item in
            guard let ordering = orderings[item.id] else { return true }
            if case .appendOrder = ordering { return true }
            return false
        }
        if everyItemIsAppendOrder { return items }

        return items.sorted { a, b in
            compare(
                orderings[a.id], orderings[b.id],
                fallbackA: a, fallbackB: b
            )
        }
    }

    private nonisolated static func compare(
        _ a: BlockOrdering?, _ b: BlockOrdering?,
        fallbackA: ChatHistoryItem, fallbackB: ChatHistoryItem
    ) -> Bool {
        switch (a, b) {
        case (.filePosition(let mi1, let bi1), .filePosition(let mi2, let bi2)):
            return (mi1, bi1) < (mi2, bi2)
        case (.messageRelative(let m1, let p1, let b1), .messageRelative(let m2, let p2, let b2)):
            // opencode messageIDs have a monotonic creation-time prefix,
            // so lexicographic order is chronological.
            //
            // Within the same message we enforce two rules:
            //
            //   1. **Reasoning always comes first.** The model computes
            //      reasoning before anything else, but opencode's event
            //      bus may emit the final reasoning text AFTER the tool
            //      pending event (the original "reasoning appears after
            //      tool" bug). The `.reasoning` priority forces the block
            //      to the top regardless of arrival order — mirroring
            //      opencode's own provider-adapter fix at API-call time
            //      (anomalyco/opencode PR #10474, commit e8d6d1c, issues
            //      #9364, #3077).
            //
            //   2. **All other blocks follow insertion order.** Within an
            //      assistant message the model emits text (preamble)
            //      BEFORE tool_use (Anthropic API convention), so the
            //      event arrival order already encodes the correct
            //      display order. `blockIndex` is set by `nextBlockIndex`
            //      for non-streaming blocks; streaming blocks use fixed
            //      `blockIndex = 0` to upsert into a single item, so
            //      they tie with each other — Swift's stable sort then
            //      preserves the original `items.append` order.
            //
            // We deliberately do NOT use `typePriority` to rank
            // `action` vs `response`: the original design assumed
            // "reasoning → tool → text" causality, but real models put
            // text before tool (preamble). Enforcing action < response
            // inverts the preamble so the tool card appears above the
            // text that introduced it. See `BlockTypePriority` in
            // `Nook/Models/ChatItemUpdate.swift` for the rationale.
            if m1 == m2 {
                if p1 == .reasoning && p2 != .reasoning { return true }
                if p1 != .reasoning && p2 == .reasoning { return false }
                return b1 < b2
            }
            return m1 < m2
        case (.timestamp(let t1), .timestamp(let t2)):
            return t1 < t2
        case (.appendOrder, .appendOrder):
            // Backstop for the fast path: if both items are .appendOrder
            // and the caller bypassed the all-appendOrder shortcut for
            // some reason, returning false keeps their relative order
            // intact (no swap). Array.sorted is unstable in general, but
            // the fast path covers the 100%-appendOrder case so this
            // arm is just defense in depth.
            return false
        default:
            // Mixed ordering types or nil → fall back to timestamp
            return fallbackA.timestamp < fallbackB.timestamp
        }
    }
}

// MARK: - ChatItemIdFactory

/// Generates stable, provider-scoped IDs for chat items.
enum ChatItemIdFactory {
    /// Claude: based on JSONL message ID + block position (unchanged from existing scheme).
    nonisolated static func claudeBlockId(messageId: String, typePrefix: String, blockIndex: Int) -> String {
        "\(messageId)-\(typePrefix)-\(blockIndex)"
    }

    /// OpenCode: based on message ID + logical block index (replaces timestamp-based IDs).
    nonisolated static func opencodeBlockId(messageId: String, typePrefix: String, blockIndex: Int) -> String {
        "opencode-\(messageId)-\(typePrefix)-\(blockIndex)"
    }

    /// Codex: based on transcript line index or call_id (unchanged).
    nonisolated static func codexBlockId(sessionId: String, lineIndex: Int) -> String {
        "codex-message-\(sessionId)-\(lineIndex)"
    }

    /// Fallback tool ID when no provider-specific ID is available.
    nonisolated static func toolId(provider: SessionProvider, rawId: String?) -> String {
        rawId ?? "\(provider.rawValue)-tool-\(Int(Date().timeIntervalSince1970 * 1000))"
    }
}
