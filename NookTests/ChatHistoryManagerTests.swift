import Combine
import XCTest
@testable import Nook

@MainActor
final class ChatHistoryManagerTests: XCTestCase {
    func testRemovingSessionReleasesEveryProjectionAndKeepsOtherSession() async {
        let store = SessionStore()
        let manager = ChatHistoryManager(store: store)
        await expectSnapshot(manager, items: ["first": ["first-item"], "second": ["second-item"]]) {
            await store.process(.cursorSessionStarted(sessionId: "first", cwd: "/tmp/first"))
            await store.process(.cursorSessionStarted(sessionId: "second", cwd: "/tmp/second"))
            await store.process(.chatItemBatch([
                update(session: "first", id: "first-item", block: .userPrompt("first")),
                update(session: "second", id: "second-item", block: .userPrompt("second"))
            ]))
        }
        XCTAssertTrue(manager.isLoaded(sessionId: "first"))
        XCTAssertTrue(manager.isLoaded(sessionId: "second"))

        await expectSnapshot(manager, items: ["second": ["second-item"]]) {
            await store.process(.sessionEnded(sessionId: "first"))
        }
        XCTAssertFalse(manager.isLoaded(sessionId: "first"))
        XCTAssertTrue(manager.isLoaded(sessionId: "second"))
        XCTAssertNil(manager.agentDescriptions["first"])
        XCTAssertEqual(manager.history(for: "second").first?.type, .user("second"))
    }

    func testEmptySnapshotClearsCachesAndReusedSessionStartsFresh() async {
        let store = SessionStore()
        let manager = ChatHistoryManager(store: store)
        await expectSnapshot(manager, items: ["session": ["old"]]) {
            await store.process(.cursorSessionStarted(sessionId: "session", cwd: "/tmp/project"))
            await store.process(.chatItemBatch([update(session: "session", id: "old", block: .assistantText("old"))]))
        }
        await expectSnapshot(manager, items: [:]) {
            await store.process(.sessionEnded(sessionId: "session"))
        }
        XCTAssertTrue(manager.histories.isEmpty)
        XCTAssertTrue(manager.agentDescriptions.isEmpty)
        XCTAssertFalse(manager.isLoaded(sessionId: "session"))

        await expectSnapshot(manager, items: ["session": []]) {
            await store.process(.cursorSessionStarted(sessionId: "session", cwd: "/tmp/project"))
        }
        XCTAssertTrue(manager.history(for: "session").isEmpty)
        XCTAssertTrue(manager.isLoaded(sessionId: "session"))
    }

    func testProjectionStillFiltersToolsAlreadyNestedUnderSubagent() async {
        let store = SessionStore()
        let manager = ChatHistoryManager(store: store)
        let child = SubagentToolCall(id: "child", name: "Read", input: [:], status: .success, timestamp: fixedDate(1))
        await expectSnapshot(manager, items: ["session": ["parent", "ordinary"]]) {
            await store.process(.cursorSessionStarted(sessionId: "session", cwd: "/tmp/project"))
            await store.process(.chatItemBatch([
                update(session: "session", id: "parent", block: .toolCall(makeToolCall(id: "parent", name: "Task", subagentTools: [child]))),
                update(session: "session", id: "child", block: .toolCall(makeToolCall(id: "child", name: "Read"))),
                update(session: "session", id: "ordinary", block: .assistantText("answer"))
            ]))
        }
        let source = await store.session(for: "session")
        XCTAssertEqual(source?.chatItems.count, 3, "Projection must not mutate the source snapshot")
        XCTAssertEqual(manager.history(for: "session").map(\.id), ["parent", "ordinary"])
    }

    private func update(session: String, id: String, block: ChatItemBlock) -> ChatItemUpdate {
        ChatItemUpdate(id: id, sessionId: session, block: block, ordering: .appendOrder, mutation: .insert, provider: .cursor)
    }

    private func expectSnapshot(
        _ manager: ChatHistoryManager,
        items: [String: [String]],
        action: () async -> Void
    ) async {
        let received = expectation(description: "Complete history snapshot \(items.keys.sorted())")
        let subscription = manager.$agentDescriptions
            .filter { descriptions in
                Set(descriptions.keys) == Set(items.keys)
                    && manager.histories.mapValues { $0.map(\.id) } == items
            }
            .prefix(1)
            .sink { _ in received.fulfill() }
        defer { subscription.cancel() }
        await action()
        await fulfillment(of: [received], timeout: 2)
    }
}
