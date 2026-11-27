import XCTest
@testable import Nook

@MainActor
final class OpencodeIngressAdapterTests: XCTestCase {
    func testStopClearsOldContextBeforeTheNextEnvelope() throws {
        let sessionId = "ingress-adapter-\(UUID().uuidString)"
        let adapter = OpencodeChatItemAdapter.shared
        defer { finishFixture(sessionId, callIds: ["old", "without-message"]) }
        let first = adapter.adaptAndConvert(toolEnvelope(sessionId, callId: "old", messageId: "old-message"))
        assertOrdering(try XCTUnwrap(first.chatItemUpdates.first), messageId: "old-message", index: 0)
        let stopped = adapter.adaptAndConvert(envelope("session.idle", sessionId: sessionId))
        guard case .stop = stopped.passthroughEvents.first else { return XCTFail("Expected stop") }

        let next = adapter.adaptAndConvert(toolEnvelope(sessionId, callId: "without-message", messageId: nil))
        assertOrdering(try XCTUnwrap(next.chatItemUpdates.first), messageId: "unknown-\(sessionId)", index: 0)
    }

    func testDelayedStoreStopCannotClearTheNextTurnsMessageOrBlockContext() async throws {
        let sessionId = "ingress-adapter-\(UUID().uuidString)"
        let adapter = OpencodeChatItemAdapter.shared
        defer { finishFixture(sessionId, callIds: ["old", "fresh", "next"]) }
        let entered = expectation(description: "earlier submission suspended")
        let gate = AdapterIngressGate(entered: entered)
        addTeardownBlock { await gate.open() }
        let runtime = SessionRuntime(lifecycle: .init(
            startIngress: { _ in }, stopIngress: {}, setStatusChecksRunning: { _ in }
        ), eventSink: { await gate.consume($0) })
        runtime.start()
        let callbacks = try XCTUnwrap(runtime.hookCallbacks)
        callbacks.onCodexEvent?(.sessionStart(sessionId: "earlier", cwd: "/tmp", source: nil))
        await fulfillment(of: [entered], timeout: 2)

        _ = adapter.adaptAndConvert(toolEnvelope(sessionId, callId: "old", messageId: "old-message"))
        let stop = adapter.adaptAndConvert(envelope("session.idle", sessionId: sessionId))
        callbacks.onOpencodeBatch?(stop)
        // Transport may adapt the next turn while the Store is still draining
        // older work. Its context must survive completion of the older stop.
        let fresh = adapter.adaptAndConvert(toolEnvelope(sessionId, callId: "fresh", messageId: "new-message"))
        assertOrdering(try XCTUnwrap(fresh.chatItemUpdates.first), messageId: "new-message", index: 0)
        callbacks.onOpencodeBatch?(fresh)
        await gate.open()
        let drained = expectation(description: "queued stop committed")
        Task { await runtime.waitForIngress(); drained.fulfill() }
        await fulfillment(of: [drained], timeout: 2)

        let next = adapter.adaptAndConvert(toolEnvelope(sessionId, callId: "next", messageId: nil))
        assertOrdering(try XCTUnwrap(next.chatItemUpdates.first), messageId: "new-message", index: 1)
        runtime.stop()
        await runtime.waitForStatusCheckTransition()
    }

    private func toolEnvelope(_ sessionId: String, callId: String, messageId: String?, status: String = "running") -> OpencodeHookEnvelope {
        var part: [String: Any] = [
            "type": "tool", "tool": "bash", "callID": "\(sessionId)-\(callId)",
            "state": ["status": status, "input": ["command": "echo fixture"]]
        ]
        if let messageId { part["messageID"] = messageId }
        return envelope("message.part.updated", sessionId: sessionId, properties: ["part": part])
    }

    private func finishFixture(_ sessionId: String, callIds: [String]) {
        let adapter = OpencodeChatItemAdapter.shared
        for callId in callIds {
            _ = adapter.adaptAndConvert(toolEnvelope(sessionId, callId: callId, messageId: nil, status: "completed"))
        }
        _ = adapter.adaptAndConvert(envelope("session.idle", sessionId: sessionId))
    }

    private func envelope(_ type: String, sessionId: String, properties: [String: Any] = [:]) -> OpencodeHookEnvelope {
        var props = properties
        props["sessionID"] = sessionId
        props["cwd"] = "/tmp/ingress-fixture"
        return OpencodeHookEnvelope(origin: "opencode", type: type, properties: props.mapValues { AnyCodable($0) })
    }

    private func assertOrdering(_ update: ChatItemUpdate, messageId: String, index: Int,
                                file: StaticString = #filePath, line: UInt = #line) {
        guard case .messageRelative(let actualMessage, _, let actualIndex) = update.ordering else {
            return XCTFail("Expected message-relative ordering", file: file, line: line)
        }
        XCTAssertEqual(actualMessage, messageId, file: file, line: line)
        XCTAssertEqual(actualIndex, index, file: file, line: line)
    }
}

private actor AdapterIngressGate {
    private let entered: XCTestExpectation
    private var continuation: CheckedContinuation<Void, Never>?
    private var isOpen = false
    private var first = true

    init(entered: XCTestExpectation) { self.entered = entered }

    func consume(_ event: SessionEvent) async {
        guard first else { return }
        first = false
        entered.fulfill()
        if !isOpen { await withCheckedContinuation { continuation = $0 } }
    }

    func open() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}
