import XCTest
@testable import Nook

final class ChatItemUpdateReducerTests: XCTestCase {
    func testAppendOrderPreservesInsertionOrderDespiteTimestamps() {
        var items: [ChatHistoryItem] = []
        var orderings: [String: BlockOrdering] = [:]

        apply(
            id: "user",
            block: .userPrompt("first"),
            ordering: .appendOrder,
            messageTimestamp: fixedDate(200),
            items: &items,
            orderings: &orderings
        )
        apply(
            id: "assistant",
            block: .assistantText("second"),
            ordering: .appendOrder,
            messageTimestamp: fixedDate(100),
            items: &items,
            orderings: &orderings
        )

        XCTAssertEqual(items.map(\.id), ["user", "assistant"])
    }

    func testMessageRelativeOrderingRestoresReasoningToolResponseOrder() {
        var items: [ChatHistoryItem] = []
        var orderings: [String: BlockOrdering] = [:]

        apply(
            id: "tool",
            block: .toolCall(makeToolCall(id: "tool")),
            ordering: .messageRelative(messageId: "msg-1", typePriority: .action, blockIndex: 0),
            messageTimestamp: fixedDate(1),
            items: &items,
            orderings: &orderings
        )
        apply(
            id: "response",
            block: .assistantText("done"),
            ordering: .messageRelative(messageId: "msg-1", typePriority: .response, blockIndex: 0),
            messageTimestamp: fixedDate(1),
            items: &items,
            orderings: &orderings
        )
        apply(
            id: "reasoning",
            block: .thinking("thinking"),
            ordering: .messageRelative(messageId: "msg-1", typePriority: .reasoning, blockIndex: 0),
            messageTimestamp: fixedDate(1),
            items: &items,
            orderings: &orderings
        )

        XCTAssertEqual(items.map(\.id), ["reasoning", "tool", "response"])
    }

    func testToolStatusUpdateMutatesExistingToolOnly() {
        var items: [ChatHistoryItem] = []
        var orderings: [String: BlockOrdering] = [:]

        apply(
            id: "tool",
            block: .toolCall(makeToolCall(id: "tool", status: .running)),
            ordering: .appendOrder,
            items: &items,
            orderings: &orderings
        )
        apply(
            id: "tool",
            block: .toolCall(makeToolCall(id: "tool", status: .success, result: "done")),
            ordering: .appendOrder,
            mutation: .updateStatus,
            items: &items,
            orderings: &orderings
        )
        apply(
            id: "missing-tool",
            block: .toolCall(makeToolCall(id: "missing-tool", status: .success, result: "ignored")),
            ordering: .appendOrder,
            mutation: .updateStatus,
            items: &items,
            orderings: &orderings
        )

        XCTAssertEqual(items.count, 1)
        guard case .toolCall(let tool) = items[0].type else {
            return XCTFail("Expected tool call")
        }
        XCTAssertEqual(tool.status, .success)
        XCTAssertEqual(tool.result, "done")
    }

    func testDuplicateUserPromptInsertDoesNotReplaceOriginalPrompt() {
        var items: [ChatHistoryItem] = []
        var orderings: [String: BlockOrdering] = [:]

        apply(
            id: "prompt",
            block: .userPrompt("original"),
            ordering: .appendOrder,
            items: &items,
            orderings: &orderings
        )
        apply(
            id: "prompt",
            block: .userPrompt("replacement"),
            ordering: .appendOrder,
            items: &items,
            orderings: &orderings
        )

        XCTAssertEqual(items.count, 1)
        guard case .user(let prompt) = items[0].type else {
            return XCTFail("Expected user prompt")
        }
        XCTAssertEqual(prompt, "original")
    }

    /// Regression test: inserting a userPrompt with identical text to an existing
    /// item (different ID) should be deduplicated to prevent double-display.
    func testSameContentUserPromptDifferentIdIsDeduplicated() {
        var items: [ChatHistoryItem] = []
        var orderings: [String: BlockOrdering] = [:]

        // Simulate local creation (SessionStore path) — local prompt uses appendOrder
        apply(
            id: "opencode-prompt-session-1234567890",
            block: .userPrompt("Hello world"),
            ordering: .appendOrder,
            items: &items,
            orderings: &orderings
        )

        // Simulate hook echo (OpencodeChatItemAdapter path) — real id keeps messageRelative
        apply(
            id: "opencode-msg-abc-prompt-0",
            block: .userPrompt("Hello world"),
            ordering: .messageRelative(messageId: "msg-abc", typePriority: .reasoning, blockIndex: 0),
            items: &items,
            orderings: &orderings
        )

        // Should only have one item, not two
        XCTAssertEqual(items.count, 1, "Duplicate user prompt with same text should be deduplicated")
        guard case .user(let prompt) = items[0].type else {
            return XCTFail("Expected user prompt")
        }
        XCTAssertEqual(prompt, "Hello world")
        // Original ID should be preserved
        XCTAssertEqual(items[0].id, "opencode-prompt-session-1234567890")
    }

    func testHookEchoUpgradesLocalPromptOrderingFromAppendToMessageRelative() {
        var items: [ChatHistoryItem] = []
        var orderings: [String: BlockOrdering] = [:]

        // 1. Hook echo arrives first (adapter path) with real messageId
        apply(
            id: "opencode-msg-abc-prompt-0",
            block: .userPrompt("Hello world"),
            ordering: .messageRelative(messageId: "msg-abc", typePriority: .reasoning, blockIndex: 0),
            items: &items, orderings: &orderings
        )
        // 2. Local fallback arrives later (SessionStore path) — must not override
        apply(
            id: "opencode-prompt-session-1234567890",
            block: .userPrompt("Hello world"),
            ordering: .appendOrder,
            items: &items, orderings: &orderings
        )

        XCTAssertEqual(items.count, 1)
        guard case .messageRelative(let messageId, _, _) = orderings[items[0].id] else {
            return XCTFail("Expected messageRelative ordering to be preserved")
        }
        XCTAssertEqual(messageId, "msg-abc")
    }

    func testLocalPromptFirstThenHookEchoUsesRealMessageId() {
        var items: [ChatHistoryItem] = []
        var orderings: [String: BlockOrdering] = [:]

        apply(
            id: "opencode-prompt-session-1234567890",
            block: .userPrompt("Hello world"),
            ordering: .appendOrder,
            items: &items, orderings: &orderings
        )
        apply(
            id: "opencode-msg-abc-prompt-0",
            block: .userPrompt("Hello world"),
            ordering: .messageRelative(messageId: "msg-abc", typePriority: .reasoning, blockIndex: 0),
            items: &items, orderings: &orderings
        )

        XCTAssertEqual(items.count, 1)
        guard case .messageRelative(let messageId, _, _) = orderings[items[0].id] else {
            return XCTFail("Expected messageRelative ordering")
        }
        XCTAssertEqual(messageId, "msg-abc")
    }

    private func apply(
        id: String,
        block: ChatItemBlock,
        ordering: BlockOrdering,
        mutation: BlockMutation = .insert,
        provider: SessionProvider = .opencode,
        messageTimestamp: Date? = nil,
        items: inout [ChatHistoryItem],
        orderings: inout [String: BlockOrdering]
    ) {
        ChatItemUpdateReducer.apply(
            ChatItemUpdate(
                id: id,
                sessionId: "session",
                block: block,
                ordering: ordering,
                mutation: mutation,
                provider: provider,
                messageTimestamp: messageTimestamp
            ),
            items: &items,
            orderings: &orderings,
            now: fixedDate(0)
        )
    }
}
