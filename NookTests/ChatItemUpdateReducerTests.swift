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
