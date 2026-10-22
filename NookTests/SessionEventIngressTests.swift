import XCTest
@testable import Nook

@MainActor
final class SessionEventIngressTests: XCTestCase {
    func testAcceptedBatchesFinishInOrderAcrossGenerationChanges() async {
        let firstStarted = expectation(description: "first event suspended")
        let recorder = IngressEventRecorder(firstStarted: firstStarted)
        addTeardownBlock { await recorder.open() }
        let ingress = SessionEventIngress(sink: { await recorder.consume($0) })
        let firstGeneration = ingress.beginGeneration()
        XCTAssertTrue(ingress.enqueue([
            .cursorSessionStarted(sessionId: "first", cwd: "/tmp")
        ], generation: firstGeneration))
        await fulfillment(of: [firstStarted], timeout: 2)
        XCTAssertTrue(ingress.enqueue([
            .cursorProcessingStarted(sessionId: "second", cwd: "/tmp"),
            .cursorStopped(sessionId: "third", cwd: "/tmp", status: nil)
        ], generation: firstGeneration))

        ingress.close()
        XCTAssertFalse(ingress.enqueue([
            .cursorSessionEnded(sessionId: "rejected-closed")
        ], generation: firstGeneration))
        let nextGeneration = ingress.beginGeneration()
        XCTAssertFalse(ingress.enqueue([
            .cursorSessionEnded(sessionId: "rejected-old")
        ], generation: firstGeneration))
        XCTAssertTrue(ingress.enqueue([
            .cursorSessionEnded(sessionId: "fourth")
        ], generation: nextGeneration))
        await recorder.open()
        await boundedDrain { await ingress.waitUntilDrained() }

        let timeline = await recorder.timeline
        XCTAssertEqual(timeline, paired([
            "cursor.start:first", "cursor.processing:second", "cursor.stop:third", "cursor.end:fourth"
        ]))
    }

    func testRuntimePreservesWholeBatchesAndCrossProviderOrder() async throws {
        let firstStarted = expectation(description: "first content suspended")
        let recorder = IngressEventRecorder(firstStarted: firstStarted)
        addTeardownBlock { await recorder.open() }
        let runtime = makeRuntime(sink: { await recorder.consume($0) })
        runtime.start()
        let callbacks = try XCTUnwrap(runtime.hookCallbacks)
        callbacks.onOpencodeBatch?(.init(
            chatItemUpdates: [update("open", id: "open-text", provider: .opencode)],
            passthroughEvents: [.processingStarted(sessionId: "open", cwd: "/tmp"), .stop(sessionId: "open", cwd: "/tmp")]
        ))
        await fulfillment(of: [firstStarted], timeout: 2)
        callbacks.onCodexEvent?(.sessionStart(sessionId: "codex", cwd: "/tmp", source: nil))
        callbacks.onEvent(hook("claude"))
        callbacks.onPermissionFailure?("claude", "tool")
        callbacks.onCursorBatch?(.init(
            chatItemUpdates: [update("cursor", id: "cursor-text")],
            passthroughEvents: [.stop(sessionId: "cursor", cwd: "/tmp", status: "completed")]
        ))
        await recorder.open()
        await boundedDrain { await runtime.waitForIngress() }
        runtime.stop()
        await runtime.waitForStatusCheckTransition()

        let timeline = await recorder.timeline
        XCTAssertEqual(timeline, paired([
            "content:open-text", "open.processing:open", "open.stop:open",
            "codex.start:codex", "claude:claude", "permission:claude:tool",
            "content:cursor-text", "cursor.stop:cursor"
        ]))
    }

    func testStopPreservesAcceptedWorkAndRejectsEveryOldCallbackAfterRestart() async throws {
        let firstStarted = expectation(description: "accepted event suspended")
        let recorder = IngressEventRecorder(firstStarted: firstStarted)
        addTeardownBlock { await recorder.open() }
        let runtime = makeRuntime(sink: { await recorder.consume($0) })
        runtime.start()
        let old = try XCTUnwrap(runtime.hookCallbacks)
        old.onCursorBatch?(.init(chatItemUpdates: [], passthroughEvents: [
            .sessionStart(sessionId: "accepted-first", cwd: "/tmp")
        ]))
        await fulfillment(of: [firstStarted], timeout: 2)
        old.onOpencodeBatch?(.init(chatItemUpdates: [], passthroughEvents: [
            .stop(sessionId: "accepted-stop", cwd: "/tmp")
        ]))
        runtime.stop()
        XCTAssertFalse(runtime.isRunning, "stop closes admission without waiting for the gated sink")
        XCTAssertNil(runtime.hookCallbacks)
        old.onEvent(hook("closed"))
        runtime.start()
        let fresh = try XCTUnwrap(runtime.hookCallbacks)
        old.onEvent(hook("old-claude"))
        old.onPermissionFailure?("old-permission", "tool")
        old.onCodexEvent?(.stop(sessionId: "old-codex", cwd: "/tmp"))
        old.onOpencodeBatch?(.init(chatItemUpdates: [], passthroughEvents: [
            .stop(sessionId: "old-open", cwd: "/tmp")
        ]))
        old.onCursorBatch?(.init(chatItemUpdates: [], passthroughEvents: [
            .sessionEnd(sessionId: "old-cursor")
        ]))
        fresh.onCursorBatch?(.init(chatItemUpdates: [], passthroughEvents: [
            .sessionStart(sessionId: "fresh", cwd: "/tmp")
        ]))
        await recorder.open()
        await boundedDrain { await runtime.waitForIngress() }
        runtime.stop()
        await runtime.waitForStatusCheckTransition()

        let timeline = await recorder.timeline
        XCTAssertEqual(timeline, paired([
            "cursor.start:accepted-first", "open.stop:accepted-stop", "cursor.start:fresh"
        ]))
    }

    func testOpenCodeContentThenStopLeavesStoreIdleWithFinishedTools() async throws {
        let store = makeStore()
        let runtime = makeRuntime(sink: { await store.process($0) })
        runtime.start()
        let callbacks = try XCTUnwrap(runtime.hookCallbacks)
        callbacks.onOpencodeBatch?(.init(chatItemUpdates: [], passthroughEvents: [
            .serverPortReceived(sessionId: "open", port: 9191, version: nil, pid: nil),
            .sessionStart(sessionId: "open", cwd: "/tmp", provisional: false, pid: nil)
        ]))
        callbacks.onOpencodeBatch?(.init(
            chatItemUpdates: [toolUpdate("open", provider: .opencode)],
            passthroughEvents: [.processingStarted(sessionId: "open", cwd: "/tmp")]
        ))
        callbacks.onOpencodeBatch?(.init(
            chatItemUpdates: [update("open", id: "answer", provider: .opencode)],
            passthroughEvents: [.stop(sessionId: "open", cwd: "/tmp")]
        ))
        await boundedDrain { await runtime.waitForIngress() }
        runtime.stop()
        await runtime.waitForStatusCheckTransition()

        let storedSession = await store.session(for: "open")
        let session = try XCTUnwrap(storedSession)
        XCTAssertEqual(session.phase, .idle)
        XCTAssertEqual(session.chatItems.map(\.id), ["tool", "answer"])
        XCTAssertTrue(session.toolTracker.inProgress.isEmpty)
        guard case .toolCall(let tool) = session.chatItems[0].type else { return XCTFail("Missing tool") }
        XCTAssertEqual(tool.status, .interrupted)
    }

    func testCursorStopAndEndKeepChatAndFinishRunningTools() async throws {
        let store = makeStore()
        let runtime = makeRuntime(sink: { await store.process($0) })
        runtime.start()
        let callbacks = try XCTUnwrap(runtime.hookCallbacks)
        callbacks.onCursorBatch?(.init(chatItemUpdates: [], passthroughEvents: [
            .sessionStart(sessionId: "cursor", cwd: "/tmp")
        ]))
        callbacks.onCursorBatch?(.init(
            chatItemUpdates: [toolUpdate("cursor", provider: .cursor)],
            passthroughEvents: [.processingStarted(sessionId: "cursor", cwd: "/tmp")]
        ))
        callbacks.onCursorBatch?(.init(
            chatItemUpdates: [update("cursor", id: "answer")],
            passthroughEvents: [.stop(sessionId: "cursor", cwd: "/tmp", status: "aborted"), .sessionEnd(sessionId: "cursor")]
        ))
        await boundedDrain { await runtime.waitForIngress() }
        runtime.stop()
        await runtime.waitForStatusCheckTransition()

        let storedSession = await store.session(for: "cursor")
        let session = try XCTUnwrap(storedSession)
        XCTAssertEqual(session.phase, .idle)
        XCTAssertEqual(session.chatItems.map(\.id), ["tool", "answer"])
        XCTAssertTrue(session.toolTracker.inProgress.isEmpty)
        guard case .toolCall(let tool) = session.chatItems[0].type else { return XCTFail("Missing tool") }
        XCTAssertEqual(tool.status, .interrupted)
    }

    private func makeRuntime(sink: @escaping SessionEventIngress.Sink) -> SessionRuntime {
        SessionRuntime(lifecycle: .init(
            startIngress: { _ in }, stopIngress: {}, setStatusChecksRunning: { _ in }
        ), eventSink: sink)
    }

    private func makeStore() -> SessionStore {
        let store = SessionStore()
        addTeardownBlock { await store.resetForTesting() }
        return store
    }

    private func boundedDrain(_ action: @escaping @MainActor () async -> Void) async {
        let drained = expectation(description: "accepted ingress drained")
        Task { await action(); drained.fulfill() }
        await fulfillment(of: [drained], timeout: 2)
    }

    private func paired(_ labels: [String]) -> [String] {
        labels.flatMap { ["begin:\($0)", "end:\($0)"] }
    }

    private func update(_ sessionId: String, id: String, provider: SessionProvider = .cursor) -> ChatItemUpdate {
        ChatItemUpdate(id: id, sessionId: sessionId, block: .assistantText(id),
                       ordering: .filePosition(messageIndex: 0, blockIndex: 1), mutation: .insert, provider: provider)
    }

    private func toolUpdate(_ sessionId: String, provider: SessionProvider) -> ChatItemUpdate {
        ChatItemUpdate(id: "tool", sessionId: sessionId,
                       block: .toolCall(ChatItemToolCall(toolId: "tool", name: "Bash", input: [:], status: .running,
                                                        result: nil, structuredResult: nil, subagentTools: [])),
                       ordering: .filePosition(messageIndex: 0, blockIndex: 0), mutation: .insert, provider: provider)
    }

    private func hook(_ sessionId: String) -> HookEvent {
        HookEvent(sessionId: sessionId, cwd: "/tmp", event: "Notification", status: "idle",
                  pid: nil, tty: nil, tool: nil, toolInput: nil, toolUseId: nil,
                  notificationType: nil, message: nil)
    }
}

private actor IngressEventRecorder {
    private let firstStarted: XCTestExpectation
    private var gate: CheckedContinuation<Void, Never>?
    private var isOpen = false
    private var count = 0
    private(set) var timeline: [String] = []

    init(firstStarted: XCTestExpectation) {
        self.firstStarted = firstStarted
    }

    func consume(_ event: SessionEvent) async {
        let label = Self.label(event)
        timeline.append("begin:\(label)")
        count += 1
        if count == 1 {
            firstStarted.fulfill()
            if !isOpen {
                await withCheckedContinuation { gate = $0 }
            }
        }
        timeline.append("end:\(label)")
    }

    func open() {
        isOpen = true
        gate?.resume()
        gate = nil
    }

    private static func label(_ event: SessionEvent) -> String {
        switch event {
        case .cursorSessionStarted(let id, _): return "cursor.start:\(id)"
        case .cursorProcessingStarted(let id, _): return "cursor.processing:\(id)"
        case .cursorStopped(let id, _, _): return "cursor.stop:\(id)"
        case .cursorSessionEnded(let id): return "cursor.end:\(id)"
        case .opencodeProcessingStarted(let id, _): return "open.processing:\(id)"
        case .opencodeStopped(let id, _): return "open.stop:\(id)"
        case .codexSessionStarted(let id, _, _): return "codex.start:\(id)"
        case .hookReceived(let hook): return "claude:\(hook.sessionId)"
        case .permissionSocketFailed(let id, let tool): return "permission:\(id):\(tool)"
        case .realtimeChatItemBatch(let updates): return "content:\(updates.map(\.id).joined(separator: ","))"
        default: return "unexpected"
        }
    }
}
