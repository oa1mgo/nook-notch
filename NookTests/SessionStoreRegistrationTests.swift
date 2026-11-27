import Combine
import XCTest
@testable import Nook

@MainActor
final class SessionStoreRegistrationTests: XCTestCase {
    private func makeStore(
        policy: PendingChatItemBuffer.Policy = .init(),
        clock: RegistrationTestClock = RegistrationTestClock()
    ) -> SessionStore {
        let store = SessionStore(pendingChatItemPolicy: policy, pendingChatItemClock: { clock.now() })
        addTeardownBlock { await store.resetForTesting() }
        return store
    }

    private func update(
        _ id: String, session: String = "session", provider: SessionProvider = .cursor,
        block: ChatItemBlock? = nil
    ) -> ChatItemUpdate {
        ChatItemUpdate(
            id: id, sessionId: session, block: block ?? .assistantText(id),
            ordering: .appendOrder, mutation: .insert, provider: provider
        )
    }

    private func seedOpenCodePort(_ store: SessionStore) async {
        await store.process(.opencodeServerPortReceived(sessionId: "?", port: 4444, version: nil, pid: 100))
    }

    func testEarlyForeignContentCannotChooseTheProviderOrOverwriteLegitimateContent() async throws {
        let store = makeStore()
        await store.setCodexTranscriptRootForTesting(try makeCodexTestDirectory())
        await seedOpenCodePort(store)
        let starts: [(SessionProvider, SessionEvent)] = [
            (.cursor, .cursorSessionStarted(sessionId: "cursor", cwd: "/tmp/project")),
            (.codex, .codexSessionStarted(sessionId: "codex", cwd: "/tmp/project", source: nil)),
            (.opencode, .opencodeSessionStarted(sessionId: "opencode", cwd: "/tmp/project")),
            (.claude, .hookReceived(HookEvent(
                sessionId: "claude", cwd: "/tmp/project", event: "SessionStart", status: "idle",
                pid: nil, tty: nil, tool: nil, toolInput: nil, toolUseId: nil,
                notificationType: nil, message: nil
            ))),
        ]
        for (provider, start) in starts {
            let sessionId = provider.rawValue
            let foreign: SessionProvider = provider == .cursor ? .opencode : .cursor
            await store.process(.realtimeChatItemBatch([
                update("foreign", session: sessionId, provider: foreign),
                update("owned", session: sessionId, provider: provider),
            ]))
            await store.process(start)
            let session = await store.session(for: sessionId)
            XCTAssertEqual(session?.provider, provider)
            XCTAssertEqual(session?.cwd, "/tmp/project")
            XCTAssertEqual(session?.chatItems.map(\.id), ["owned"], "Creation must return the state after replay")
            await store.process(start)
            let afterRepeatedStart = await store.session(for: sessionId)
            XCTAssertEqual(afterRepeatedStart?.chatItems.map(\.id), ["owned"], "Registration replays only once")
        }
    }

    func testCursorFallbackProcessingRegistersAndReplaysBeforeCurrentLifecycle() async {
        let store = makeStore()
        await store.process(.chatItemUpdate(update("before")))
        await store.process(.cursorProcessingStarted(sessionId: "session", cwd: "/tmp/project"))
        await store.process(.chatItemUpdate(update("after")))

        let session = await store.session(for: "session")
        XCTAssertEqual(session?.provider, .cursor)
        XCTAssertEqual(session?.phase, .processing)
        XCTAssertEqual(session?.chatItems.map(\.id), ["before", "after"])
    }

    func testFirstCursorStopFinalizesBufferedToolsWithoutAReplayReactivatingTheSession() async {
        let store = makeStore()
        await store.process(.realtimeChatItemBatch([
            update("tool", block: .toolCall(makeToolCall(id: "tool"))),
        ]))
        await store.process(.cursorStopped(sessionId: "session", cwd: "/tmp/project", status: "completed"))

        let session = await store.session(for: "session")
        XCTAssertEqual(session?.phase, .idle)
        XCTAssertTrue(session?.toolTracker.inProgress.isEmpty == true)
        guard let item = session?.chatItems.first, case .toolCall(let tool) = item.type else {
            return XCTFail("Buffered tool must survive registration")
        }
        XCTAssertEqual(tool.status, .success)
        XCTAssertNotNil(session?.completionNotificationAt)
        await store.process(.chatItemUpdate(update("after")))
        let registered = await store.session(for: "session")
        XCTAssertEqual(registered?.chatItems.map(\.id), ["tool", "after"])
    }

    func testMissingCursorSessionEndDoesNotRegisterOrPromoteBufferedContent() async {
        let store = makeStore()
        await store.process(.chatItemUpdate(update("early")))
        await store.process(.cursorSessionEnded(sessionId: "session"))
        let missing = await store.session(for: "session")
        XCTAssertNil(missing)
    }

    func testCurrentPromptWinsOverBufferedAssistantLifecycleForCodexAndOpenCode() async throws {
        let store = makeStore()
        await store.setCodexTranscriptRootForTesting(try makeCodexTestDirectory())
        await seedOpenCodePort(store)
        for provider in [SessionProvider.codex, .opencode] {
            let id = provider.rawValue
            await store.process(.realtimeChatItemBatch([
                update("earlier", session: id, provider: provider, block: .assistantText("old answer")),
            ]))
            if provider == .codex {
                await store.process(.codexPromptSubmitted(sessionId: id, cwd: "/tmp/project", prompt: "current prompt"))
            } else {
                await store.process(.opencodePromptSubmitted(sessionId: id, cwd: "/tmp/project", prompt: "current prompt"))
            }
            let session = await store.session(for: id)
            XCTAssertEqual(session?.provider, provider)
            XCTAssertEqual(session?.phase, .processing)
            XCTAssertEqual(session?.conversationInfo.lastMessage, "current prompt")
            XCTAssertEqual(session?.conversationInfo.lastMessageRole, "user")
            XCTAssertTrue(session?.chatItems.contains(where: { $0.id == "earlier" }) == true)
        }
    }

    func testCodexStartupDoesNotAuthorizeReplayUntilARealPrompt() async throws {
        let store = makeStore()
        await store.setCodexTranscriptRootForTesting(try makeCodexTestDirectory())
        await store.process(.realtimeChatItemBatch([update("early", provider: .codex)]))
        await store.process(.codexSessionStarted(sessionId: "session", cwd: "/tmp/project", source: "startup"))
        let pending = await store.session(for: "session")
        XCTAssertNil(pending)
        await store.process(.codexPromptSubmitted(sessionId: "session", cwd: "/tmp/project", prompt: "real prompt"))
        let session = await store.session(for: "session")
        XCTAssertEqual(session?.chatItems.map(\.id), ["early"])
        XCTAssertEqual(session?.conversationInfo.lastMessage, "real prompt")
    }

    func testSuppressedCodexStartupDiscardsEarlyContentBeforeTheIDIsReused() async throws {
        let store = makeStore()
        await store.setCodexTranscriptRootForTesting(try makeCodexTestDirectory())
        await store.process(.realtimeChatItemBatch([update("hidden", provider: .codex)]))
        await store.process(.codexSessionStarted(sessionId: "session", cwd: "/tmp/project", source: "startup"))
        await store.process(.codexPromptSubmitted(
            sessionId: "session", cwd: "/tmp/project",
            prompt: "Generate 0 to 3 hyperpersonalized suggestions. Recent Codex threads in this project. Return 0 to 3 fresh suggestions."
        ))
        let hidden = await store.session(for: "session")
        XCTAssertNil(hidden)
        await store.process(.sessionEnded(sessionId: "session"))
        await store.process(.codexPromptSubmitted(sessionId: "session", cwd: "/tmp/project", prompt: "real prompt"))
        let recreated = await store.session(for: "session")
        XCTAssertEqual(recreated?.chatItems, [])
    }

    func testUnknownOpenCodeChildStaysInvisibleAndExpiresDuringPeriodicRecheck() async {
        let clock = RegistrationTestClock()
        let store = makeStore(clock: clock)
        let notifications = RegistrationNotificationCounter()
        let subscription = store.completionNotificationsPublisher.sink { _ in notifications.record() }
        defer { subscription.cancel() }
        await store.process(.realtimeChatItemBatch([update("child", provider: .opencode)]))
        await store.process(.opencodeProcessingStarted(sessionId: "session", cwd: "/tmp/project"))
        await store.process(.opencodeWaitingForUserInput(sessionId: "session", cwd: "/tmp/project", toolUseId: "q", questions: [], requestId: nil))
        await store.process(.opencodePermissionRequested(
            sessionId: "session", cwd: "/tmp/project", permission: "Bash", requestId: "p",
            toolUseId: "tool", input: [:], inputSummary: "permission", alwaysPatterns: []
        ))
        await store.process(.opencodeStopped(sessionId: "session", cwd: "/tmp/project"))
        let child = await store.session(for: "session")
        XCTAssertNil(child)
        XCTAssertEqual(notifications.count(), 0)

        clock.set(30)
        await store.recheckAllSessionsForTesting()
        let resources = await store.sessionResourceIDsForTesting()
        XCTAssertTrue(resources.isEmpty, "An unknown child needs no new input or explicit removal to expire")
    }

    func testOpenCodeLifecycleCannotMutateAnotherProviderOrPublishPermissionNotifications() async {
        let store = makeStore()
        await store.process(.cursorSessionStarted(sessionId: "session", cwd: "/tmp/project"))
        await store.process(.realtimeChatItemBatch([
            update("tool", block: .toolCall(makeToolCall(id: "tool"))),
        ]))
        let before = await store.session(for: "session")
        let notifications = RegistrationNotificationCounter()
        let subscription = store.completionNotificationsPublisher.sink { _ in notifications.record() }
        defer { subscription.cancel() }
        let foreignEvents: [SessionEvent] = [
            .opencodeSessionStarted(sessionId: "session", cwd: "/tmp/foreign"),
            .opencodeProcessingStarted(sessionId: "session", cwd: "/tmp/foreign"),
            .opencodeWaitingForUserInput(sessionId: "session", cwd: "/tmp/foreign", toolUseId: "tool", questions: [], requestId: nil),
            .opencodePermissionRequested(
                sessionId: "session", cwd: "/tmp/foreign", permission: "Bash", requestId: "p",
                toolUseId: "tool", input: [:], inputSummary: "foreign permission", alwaysPatterns: []
            ),
            .opencodePromptSubmitted(sessionId: "session", cwd: "/tmp/foreign", prompt: "foreign prompt"),
            .opencodeStopped(sessionId: "session", cwd: "/tmp/foreign"),
        ]
        for event in foreignEvents {
            await store.process(event)
            let after = await store.session(for: "session")
            XCTAssertEqual(after, before)
        }
        XCTAssertEqual(notifications.count(), 0)
    }

    func testRegisteredSessionsBypassAllPendingBufferBudgets() async {
        let store = makeStore(policy: .init(maximumIdentities: 1, maximumUpdatesPerIdentity: 1, maximumUpdates: 1))
        await store.process(.chatItemBatch([
            update("one"), update("overflow"),
        ]))
        await store.process(.cursorSessionStarted(sessionId: "session", cwd: "/tmp/project"))
        let empty = await store.session(for: "session")
        XCTAssertEqual(empty?.chatItems, [], "Registration must not replay the retained prefix of an overflowing bucket")

        await store.process(.chatItemBatch([update("live-one"), update("live-two"), update("live-three")]))
        let registered = await store.session(for: "session")
        XCTAssertEqual(registered?.chatItems.map(\.id), ["live-one", "live-two", "live-three"])
    }
}

private nonisolated final class RegistrationTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval = 0

    func now() -> TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set(_ value: TimeInterval) {
        lock.lock()
        self.value = value
        lock.unlock()
    }
}

private nonisolated final class RegistrationNotificationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func record() {
        lock.lock()
        value += 1
        lock.unlock()
    }

    func count() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}
