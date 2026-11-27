import XCTest
@testable import Nook

@MainActor
final class PendingChatItemBufferTests: XCTestCase {
    private func entry(
        _ id: String, session: String = "session", provider: SessionProvider = .cursor,
        live: Bool = false
    ) -> PendingChatItemBuffer.Entry {
        .init(
            update: ChatItemUpdate(
                id: id, sessionId: session, block: .assistantText(id),
                ordering: .appendOrder, mutation: .insert, provider: provider
            ),
            appliesLifecycleEffects: live
        )
    }

    func testRegistrationDrainsOnlyTheOwnerInOrderAndPreservesLifecyclePolicy() {
        var buffer = PendingChatItemBuffer()
        _ = buffer.enqueue(entry("foreign", provider: .opencode), now: 0)
        _ = buffer.enqueue(entry("history"), now: 1)
        _ = buffer.enqueue(entry("live", live: true), now: 2)

        let result = buffer.drain(provider: .cursor, sessionId: "session", now: 3)
        XCTAssertEqual(result.entries.map(\.update.id), ["history", "live"])
        XCTAssertEqual(result.entries.map(\.appliesLifecycleEffects), [false, true])
        XCTAssertEqual(result.discards.map(\.reason), [.providerMismatch])
        XCTAssertEqual(result.discards.map(\.count), [1])
        XCTAssertEqual(buffer.identityCount, 0)
        XCTAssertEqual(buffer.updateCount, 0)
        XCTAssertTrue(buffer.drain(provider: .cursor, sessionId: "session", now: 4).entries.isEmpty)
    }

    func testTTLStartsAtFirstArrivalAndExpiresAtExactBoundaryWithoutRenewal() {
        var buffer = PendingChatItemBuffer()
        _ = buffer.enqueue(entry("first"), now: 100)
        _ = buffer.enqueue(entry("later"), now: 129)
        XCTAssertTrue(buffer.prune(now: 129.999).isEmpty)

        let discards = buffer.prune(now: 130)
        XCTAssertEqual(discards.map(\.reason), [.expired])
        XCTAssertEqual(discards.map(\.count), [2])
        XCTAssertEqual(buffer.identityCount, 0)
        XCTAssertEqual(buffer.updateCount, 0)
    }

    func testEnqueueAndDrainBothPruneExpiredContent() {
        var buffer = PendingChatItemBuffer()
        _ = buffer.enqueue(entry("old", session: "A"), now: 0)
        let enqueueDiscards = buffer.enqueue(entry("new", session: "B"), now: 30)
        XCTAssertEqual(enqueueDiscards.map(\.reason), [.expired])
        XCTAssertEqual(buffer.sessionIds, ["B"])

        let result = buffer.drain(provider: .cursor, sessionId: "B", now: 60)
        XCTAssertTrue(result.entries.isEmpty)
        XCTAssertEqual(result.discards.map(\.reason), [.expired])
        XCTAssertEqual(buffer.updateCount, 0)
    }

    func testIdentityOverflowDropsWholeBucketAndSuppressesItsTailUntilExpiry() {
        var buffer = PendingChatItemBuffer(policy: .init(maximumUpdatesPerIdentity: 2))
        _ = buffer.enqueue(entry("one"), now: 0)
        _ = buffer.enqueue(entry("two"), now: 1)
        let overflow = buffer.enqueue(entry("three"), now: 2)
        XCTAssertEqual(overflow.map(\.reason), [.identityOverflow])
        XCTAssertEqual(overflow.map(\.count), [3])
        XCTAssertEqual(buffer.updateCount, 0)
        XCTAssertEqual(buffer.identityCount, 1, "Suppression must occupy a bounded identity record")
        XCTAssertEqual(buffer.enqueue(entry("tail"), now: 29).map(\.reason), [.suppressed])

        _ = buffer.enqueue(entry("fresh"), now: 30)
        let result = buffer.drain(provider: .cursor, sessionId: "session", now: 30)
        XCTAssertEqual(result.entries.map(\.update.id), ["fresh"])
    }

    func testRegistrationClearsSuppressionWithoutReplayingAnIncompletePrefix() {
        var buffer = PendingChatItemBuffer(policy: .init(maximumUpdatesPerIdentity: 1))
        _ = buffer.enqueue(entry("one"), now: 0)
        _ = buffer.enqueue(entry("overflow"), now: 1)
        XCTAssertTrue(buffer.drain(provider: .cursor, sessionId: "session", now: 2).entries.isEmpty)
        XCTAssertEqual(buffer.identityCount, 0)
        _ = buffer.enqueue(entry("recreated"), now: 3)
        XCTAssertEqual(buffer.drain(provider: .cursor, sessionId: "session", now: 4).entries.map(\.update.id), ["recreated"])
    }

    func testGlobalBudgetDiscardsOldestWholeContentBucketAndSuppressesItsTail() {
        var buffer = PendingChatItemBuffer(policy: .init(maximumUpdates: 3))
        _ = buffer.enqueue(entry("A1", session: "A"), now: 0)
        _ = buffer.enqueue(entry("A2", session: "A"), now: 1)
        _ = buffer.enqueue(entry("B1", session: "B"), now: 2)
        let discards = buffer.enqueue(entry("B2", session: "B"), now: 3)
        XCTAssertEqual(discards.map(\.reason), [.updateLimit])
        XCTAssertEqual(discards.map(\.identity.sessionId), ["A"])
        XCTAssertEqual(discards.map(\.count), [2])
        XCTAssertEqual(buffer.updateCount, 2)
        XCTAssertEqual(buffer.enqueue(entry("A-tail", session: "A"), now: 4).map(\.reason), [.suppressed])
        XCTAssertTrue(buffer.drain(provider: .cursor, sessionId: "A", now: 5).entries.isEmpty)
        XCTAssertEqual(buffer.drain(provider: .cursor, sessionId: "B", now: 5).entries.map(\.update.id), ["B1", "B2"])
    }

    func testGlobalBudgetCanSuppressTheIncomingIdentityWithoutKeepingADetachedTail() {
        var buffer = PendingChatItemBuffer(policy: .init(maximumUpdates: 1))
        _ = buffer.enqueue(entry("first"), now: 0)
        let discards = buffer.enqueue(entry("tail"), now: 1)
        XCTAssertEqual(discards.map(\.reason), [.updateLimit, .suppressed])
        XCTAssertEqual(buffer.updateCount, 0)
        XCTAssertTrue(buffer.drain(provider: .cursor, sessionId: "session", now: 2).entries.isEmpty)
    }

    func testIdentityEvictionIsDeterministicAndForgetsSuppression() {
        var buffer = PendingChatItemBuffer(policy: .init(maximumIdentities: 2, maximumUpdatesPerIdentity: 1))
        _ = buffer.enqueue(entry("A1", session: "A"), now: 0)
        _ = buffer.enqueue(entry("A-overflow", session: "A"), now: 0)
        _ = buffer.enqueue(entry("B1", session: "B"), now: 0)
        let evicted = buffer.enqueue(entry("C1", session: "C"), now: 0)
        XCTAssertEqual(evicted.map(\.reason), [.identityLimit])
        XCTAssertEqual(evicted.map(\.identity.sessionId), ["A"])
        XCTAssertEqual(buffer.sessionIds, ["B", "C"])

        // Suppression is guaranteed only while the bounded identity survives.
        let recreated = buffer.enqueue(entry("A-fresh", session: "A"), now: 1)
        XCTAssertEqual(recreated.map(\.identity.sessionId), ["B"])
        XCTAssertEqual(buffer.identityCount, 2)
        XCTAssertEqual(buffer.updateCount, 2)
        XCTAssertEqual(buffer.drain(provider: .cursor, sessionId: "A", now: 2).entries.map(\.update.id), ["A-fresh"])
    }

    func testRemovalClearsAllProviderBucketsAndResetClearsSuppressedRecords() {
        var buffer = PendingChatItemBuffer(policy: .init(maximumUpdatesPerIdentity: 1))
        _ = buffer.enqueue(entry("cursor"), now: 0)
        _ = buffer.enqueue(entry("opencode", provider: .opencode), now: 0)
        _ = buffer.enqueue(entry("keep", session: "other"), now: 0)
        buffer.remove(sessionId: "session")
        XCTAssertEqual(buffer.sessionIds, ["other"])
        XCTAssertEqual(buffer.updateCount, 1)
        _ = buffer.enqueue(entry("overflow", session: "other"), now: 1)
        buffer.removeAll()
        XCTAssertEqual(buffer.identityCount, 0)
        XCTAssertEqual(buffer.updateCount, 0)
        _ = buffer.enqueue(entry("fresh", session: "other"), now: 2)
        XCTAssertEqual(buffer.drain(provider: .cursor, sessionId: "other", now: 3).entries.map(\.update.id), ["fresh"])
    }
}
