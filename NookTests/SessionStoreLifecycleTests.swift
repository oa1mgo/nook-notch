import Combine
import XCTest
@testable import Nook

@MainActor
final class SessionStoreLifecycleTests: XCTestCase {
    private func makeStore() -> SessionStore {
        let store = SessionStore()
        addTeardownBlock { await store.resetForTesting() }
        return store
    }

    private func update(
        sessionId: String,
        id: String,
        position: Int = 0,
        block: ChatItemBlock? = nil,
        provider: SessionProvider = .cursor,
        mutation: BlockMutation = .insert
    ) -> ChatItemUpdate {
        ChatItemUpdate(
            id: id, sessionId: sessionId, block: block ?? .assistantText(id),
            ordering: .filePosition(messageIndex: 0, blockIndex: position),
            mutation: mutation, provider: provider
        )
    }

    func testIdenticalItemIDsHaveIndependentOrderingAcrossSessions() async {
        let store = makeStore()
        await store.process(.cursorSessionStarted(sessionId: "A", cwd: "/tmp/a"))
        await store.process(.cursorSessionStarted(sessionId: "B", cwd: "/tmp/b"))
        await store.process(.chatItemBatch([
            update(sessionId: "A", id: "shared", position: 0),
            update(sessionId: "A", id: "a-tail", position: 2),
            update(sessionId: "B", id: "b-first", position: 0),
            update(sessionId: "B", id: "shared", position: 3),
            update(sessionId: "A", id: "a-middle", position: 1),
        ]))

        let a = await store.session(for: "A")
        let b = await store.session(for: "B")
        XCTAssertEqual(a?.chatItems.map(\.id), ["shared", "a-middle", "a-tail"])
        XCTAssertEqual(b?.chatItems.map(\.id), ["b-first", "shared"])

        await store.process(.sessionEnded(sessionId: "A"))
        await store.process(.chatItemUpdate(update(sessionId: "B", id: "b-middle", position: 1)))
        let remaining = await store.session(for: "B")
        let resourceIDs = await store.sessionResourceIDsForTesting()
        XCTAssertEqual(remaining?.chatItems.map(\.id), ["b-first", "b-middle", "shared"])
        XCTAssertEqual(resourceIDs, ["B"], "Removal releases only the target session's resources")
    }

    func testEndingUnregisteredSessionDiscardsItsBufferedHistory() async {
        let store = makeStore()
        await store.process(.chatItemUpdate(update(sessionId: "early", id: "old")))
        await store.process(.sessionEnded(sessionId: "early"))

        let resourceIDs = await store.sessionResourceIDsForTesting()
        XCTAssertTrue(resourceIDs.isEmpty)
        await store.process(.cursorSessionStarted(sessionId: "early", cwd: "/tmp/early"))
        let session = await store.session(for: "early")
        XCTAssertEqual(session?.chatItems, [])
    }

    func testBufferedHistoryPreservesContentOnlySemantics() async {
        let store = makeStore()
        await store.process(.chatItemBatch([
            update(sessionId: "history", id: "prompt", block: .userPrompt("old prompt")),
            update(sessionId: "history", id: "tool", position: 1,
                   block: .toolCall(makeToolCall(id: "tool"))),
        ]))
        await store.process(.cursorSessionStarted(sessionId: "history", cwd: "/tmp/history"))

        let session = await store.session(for: "history")
        XCTAssertEqual(session?.chatItems.map(\.id), ["prompt", "tool"])
        XCTAssertEqual(session?.phase, .idle)
        XCTAssertTrue(session?.toolTracker.inProgress.isEmpty == true)
        XCTAssertNil(session?.conversationInfo.lastMessage)
    }

    func testBufferedRealtimeContentRetainsLifecycleEffects() async {
        let store = makeStore()
        await store.process(.realtimeChatItemBatch([
            update(sessionId: "live", id: "prompt", block: .userPrompt("new prompt")),
            update(sessionId: "live", id: "tool", position: 1,
                   block: .toolCall(makeToolCall(id: "tool"))),
        ]))
        await store.process(.cursorSessionStarted(sessionId: "live", cwd: "/tmp/live"))

        let session = await store.session(for: "live")
        XCTAssertEqual(session?.chatItems.map(\.id), ["prompt", "tool"])
        XCTAssertEqual(session?.phase, .processing)
        XCTAssertNotNil(session?.toolTracker.inProgress["tool"])
        XCTAssertEqual(session?.conversationInfo.firstUserMessage, "new prompt")
    }

    func testProcessExitReleasesOrderingAndRegistration() async {
        let store = makeStore()
        await store.process(.cursorSessionStarted(sessionId: "exited", cwd: "/tmp/exited"))
        await store.process(.chatItemUpdate(update(sessionId: "exited", id: "item")))
        await store.setSessionPidForTesting(sessionId: "exited", pid: Int(Int32.max))
        await store.recheckAllSessionsForTesting()

        let resourceIDs = await store.sessionResourceIDsForTesting()
        XCTAssertTrue(resourceIDs.isEmpty)
        await store.process(.chatItemUpdate(update(sessionId: "exited", id: "late")))
        let session = await store.session(for: "exited")
        XCTAssertNil(session, "Late content cannot recreate an ended session without registration")
    }

    func testProvisionalReplacementReleasesEmptyConversationResources() async {
        let store = makeStore()
        await store.process(.opencodeServerPortReceived(sessionId: "?", port: 4444, version: nil, pid: 100))
        await store.process(.opencodeSessionStarted(sessionId: "guess", cwd: "/tmp/guess", provisional: true, pid: 100))
        await store.process(.chatItemUpdate(update(sessionId: "guess", id: "temporary", provider: .opencode)))
        await store.process(.chatItemUpdate(update(sessionId: "guess", id: "temporary", provider: .opencode, mutation: .remove)))
        await store.process(.opencodeSessionStarted(sessionId: "real", cwd: "/tmp/real", provisional: false, pid: 100))

        let resourceIDs = await store.sessionResourceIDsForTesting()
        XCTAssertEqual(resourceIDs, ["real"])
    }

    func testRemovingSessionPreservesOpenCodeInstancePorts() async {
        let store = makeStore()
        await store.process(.opencodeServerPortReceived(sessionId: "?", port: 4444, version: nil, pid: 100))
        await store.process(.opencodeSessionStarted(sessionId: "A", cwd: "/tmp/a"))
        await store.process(.opencodeSessionStarted(sessionId: "B", cwd: "/tmp/b"))
        await store.setSessionPidForTesting(sessionId: "A", pid: 100)
        await store.setSessionPidForTesting(sessionId: "B", pid: 100)
        await store.process(.sessionEnded(sessionId: "A"))
        // An unrelated instance handshake rebinds B from the retained pid map.
        await store.process(.opencodeServerPortReceived(sessionId: "?", port: 5555, version: nil, pid: 200))

        let b = await store.session(for: "B")
        XCTAssertEqual(b?.serverPort, 4444)
    }

    func testHiddenCodexStartupKeepsSuppressionUntilExplicitEnd() async throws {
        let store = makeStore()
        await store.setCodexTranscriptRootForTesting(try makeCodexTestDirectory())
        await store.process(.codexSessionStarted(sessionId: "hidden", cwd: "/tmp/hidden", source: "startup"))
        await store.process(.codexPromptSubmitted(
            sessionId: "hidden", cwd: "/tmp/hidden",
            prompt: "Generate 0 to 3 hyperpersonalized suggestions. Recent Codex threads in this project. Return 0 to 3 fresh suggestions."
        ))
        await store.process(.codexToolStarted(sessionId: "hidden", cwd: "/tmp/hidden", toolName: "Bash", toolUseId: "late", input: [:], inputSummary: nil))
        let hidden = await store.session(for: "hidden")
        XCTAssertNil(hidden)

        await store.process(.sessionEnded(sessionId: "hidden"))
        let resourceIDs = await store.sessionResourceIDsForTesting()
        XCTAssertTrue(resourceIDs.isEmpty)
        await store.process(.codexPromptSubmitted(sessionId: "hidden", cwd: "/tmp/hidden", prompt: "a real prompt"))
        let restarted = await store.session(for: "hidden")
        XCTAssertEqual(restarted?.phase, .processing)
    }

    func testResetClearsRegistrationBuffersInstanceMetadataAndTasks() async {
        let store = makeStore()
        let versions = PluginVersionRecorder()
        let subscription = store.opencodePluginVersionPublisher.sink { versions.record($0) }
        defer { subscription.cancel() }
        await store.process(.cursorSessionStarted(sessionId: "old", cwd: "/tmp/old"))
        await store.process(.chatItemUpdate(update(sessionId: "old", id: "item")))
        await store.process(.chatItemUpdate(update(sessionId: "early", id: "stale")))
        await store.process(.opencodeServerPortReceived(sessionId: "?", port: 4444, version: "old-version", pid: 100))
        await store.startPeriodicStatusCheck()
        await store.resetForTesting()

        let resourceIDs = await store.sessionResourceIDsForTesting()
        let hasTasks = await store.hasBackgroundTasksForTesting()
        XCTAssertTrue(resourceIDs.isEmpty)
        XCTAssertFalse(hasTasks)
        XCTAssertEqual(versions.snapshot(), [nil, "old-version", nil])

        await store.process(.chatItemUpdate(update(sessionId: "old", id: "late")))
        let old = await store.session(for: "old")
        XCTAssertNil(old, "Reset must invalidate the old registration")
        await store.process(.cursorSessionStarted(sessionId: "early", cwd: "/tmp/early"))
        let early = await store.session(for: "early")
        XCTAssertEqual(early?.chatItems, [], "Reset must discard buffered content")

        // Seed another instance to avoid initiating a port probe in this test.
        await store.process(.opencodeServerPortReceived(sessionId: "?", port: 5555, version: nil, pid: 200))
        await store.process(.opencodeSessionStarted(sessionId: "new", cwd: "/tmp/new"))
        await store.setSessionPidForTesting(sessionId: "new", pid: 100)
        await store.process(.opencodeServerPortReceived(sessionId: "?", port: 5555, version: nil, pid: 200))
        let newSession = await store.session(for: "new")
        XCTAssertNil(newSession?.serverPort, "Reset must forget the old instance's port")
    }
}

private final class PluginVersionRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var versions: [String?] = []

    func record(_ version: String?) {
        lock.lock()
        versions.append(version)
        lock.unlock()
    }

    func snapshot() -> [String?] {
        lock.lock()
        defer { lock.unlock() }
        return versions
    }
}
