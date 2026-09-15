import Combine
import XCTest
@testable import Nook

@MainActor
final class SessionStoreCodexLifecycleTests: XCTestCase {
    override func tearDown() async throws {
        await SessionStore.shared.resetForTesting()
        try await super.tearDown()
    }

    private func prepareTranscriptStore(rows: [String]) async throws -> (SessionStore, URL) {
        let root = try makeCodexTestDirectory()
        let url = try writeCodexFragment(in: root, rows: rows)
        let store = SessionStore.shared
        await store.resetForTesting()
        await store.setCodexTranscriptRootForTesting(root)
        return (store, url)
    }

    func testPromptHookLoadsDirectMessageWithoutOpeningChat() async throws {
        let (store, _) = try await prepareTranscriptStore(rows: [codexUserRow(id: "user", text: "真实输入")])
        await store.process(.codexPromptSubmitted(sessionId: "session", cwd: "/tmp/project", prompt: "真实输入"))
        await store.waitForCodexSyncForTesting(sessionId: "session")
        let session = await store.session(for: "session")
        XCTAssertEqual(session?.chatItems.map(\.type), [.user("真实输入")])
        XCTAssertEqual(session?.phase, .processing)
    }

    func testPeriodicSyncFindsTextWithoutAnyToolHooks() async throws {
        let (store, url) = try await prepareTranscriptStore(rows: [codexUserRow(id: "user", text: "question")])
        await store.process(.codexPromptSubmitted(sessionId: "session", cwd: "/tmp/project", prompt: "question"))
        await store.waitForCodexSyncForTesting(sessionId: "session")
        let before = await store.session(for: "session")
        try appendCodexRows(codexAssistantRow(text: "live commentary", second: 2), to: url)
        await store.recheckAllSessionsForTesting()
        await store.waitForCodexSyncForTesting(sessionId: "session")
        let after = await store.session(for: "session")
        XCTAssertEqual(after?.chatItems.map(\.type), [.user("question"), .assistant("live commentary")])
        XCTAssertEqual(after?.phase, .processing)
        XCTAssertEqual(after?.lastActivity, before?.lastActivity)
        XCTAssertNil(after?.completionNotificationAt)
    }

    func testLateFinalResponseAfterStopSyncsWithoutAnotherCompletion() async throws {
        let (store, url) = try await prepareTranscriptStore(rows: [codexUserRow(id: "user", text: "question")])
        let recorder = NotificationRecorder()
        let cancellable = store.completionNotificationsPublisher.sink { recorder.record($0) }
        defer { cancellable.cancel() }
        await store.process(.codexPromptSubmitted(sessionId: "session", cwd: "/tmp/project", prompt: "question"))
        await store.waitForCodexSyncForTesting(sessionId: "session")
        await store.process(.codexStopped(sessionId: "session", cwd: "/tmp/project"))
        await store.waitForCodexSyncForTesting(sessionId: "session")
        try appendCodexRows(codexAssistantRow(text: "final answer", second: 3), to: url)
        await store.recheckAllSessionsForTesting()
        await store.waitForCodexSyncForTesting(sessionId: "session")
        let session = await store.session(for: "session")
        XCTAssertEqual(session?.chatItems.last?.type, .assistant("final answer"))
        XCTAssertEqual(session?.phase, .idle)
        XCTAssertNil(session?.completionNotificationAt)
        XCTAssertEqual(recorder.snapshot().count, 1)
    }

    func testLiveToolMergesWithTranscriptInSourceOrder() async throws {
        let (store, _) = try await prepareTranscriptStore(rows: [
            codexUserRow(id: "user", text: "question"),
            #"{"timestamp":"2026-09-15T00:00:02Z","type":"response_item","payload":{"type":"function_call","call_id":"call","name":"Bash","arguments":"{\"command\":\"pwd\"}"}}"#,
            #"{"timestamp":"2026-09-15T00:00:03Z","type":"response_item","payload":{"type":"function_call_output","call_id":"call","output":"/tmp/project"}}"#,
            codexAssistantRow(text: "answer", second: 4)
        ])
        await store.process(.codexPromptSubmitted(sessionId: "session", cwd: "/tmp/project", prompt: "question"))
        await store.process(.codexToolStarted(sessionId: "session", cwd: "/tmp/project", toolName: "Bash", toolUseId: "call", input: ["command": "pwd"], inputSummary: "pwd"))
        await store.process(.codexToolFinished(sessionId: "session", cwd: "/tmp/project", toolName: "Bash", toolUseId: "call", inputSummary: "pwd", output: "/tmp/project", isError: false))
        await store.waitForCodexSyncForTesting(sessionId: "session")
        let session = await store.session(for: "session")
        let items = try XCTUnwrap(session?.chatItems)
        XCTAssertEqual(items.count, 3)
        XCTAssertEqual(items[0].type, .user("question"))
        XCTAssertEqual(items[1].id, "call")
        XCTAssertEqual(items[2].type, .assistant("answer"))
        guard case .toolCall(let tool) = items[1].type else { return XCTFail("Expected tool") }
        XCTAssertEqual(tool.status, .success)
        XCTAssertEqual(tool.result, "/tmp/project")
    }

    func testClearCancelsPendingHistoryAndKeepsOnlyNewMessages() async throws {
        let (store, url) = try await prepareTranscriptStore(rows: [codexUserRow(id: "old", text: "old", timestamp: "2000-01-01T00:00:00Z")])
        await store.process(.codexPromptSubmitted(sessionId: "session", cwd: "/tmp/project", prompt: "old"))
        await store.process(.codexSessionStarted(sessionId: "session", cwd: "/tmp/project", source: "clear"))
        let timestamp = ISO8601DateFormatter().string(from: Date().addingTimeInterval(2))
        try appendCodexRows(codexUserRow(id: "new", text: "after clear", timestamp: timestamp), to: url)
        await store.process(.codexPromptSubmitted(sessionId: "session", cwd: "/tmp/project", prompt: "after clear"))
        await store.waitForCodexSyncForTesting(sessionId: "session")
        let session = await store.session(for: "session")
        XCTAssertEqual(session?.chatItems.map(\.type), [.user("after clear")])
        await store.process(.loadHistory(sessionId: "session", cwd: "/tmp/project"))
        let reloaded = await store.session(for: "session")
        XCTAssertEqual(reloaded?.chatItems.map(\.type), [.user("after clear")])
    }

    func testEndedSessionCannotBeRecreatedByPendingSync() async throws {
        let (store, _) = try await prepareTranscriptStore(rows: [codexUserRow(id: "old", text: "old")])
        await store.process(.codexPromptSubmitted(sessionId: "session", cwd: "/tmp/project", prompt: "old"))
        await store.process(.sessionEnded(sessionId: "session"))
        try await Task.sleep(nanoseconds: 200_000_000)
        let sessions = await store.allSessions()
        XCTAssertTrue(sessions.isEmpty)
    }

    func testConcurrentExplicitLoadsAreIdempotent() async throws {
        let (store, _) = try await prepareTranscriptStore(rows: [codexUserRow(id: "user", text: "question"), codexAssistantRow(text: "answer", second: 2)])
        await store.process(.codexPromptSubmitted(sessionId: "session", cwd: "/tmp/project", prompt: "question"))
        async let first: Void = store.process(.loadHistory(sessionId: "session", cwd: "/tmp/project"))
        async let second: Void = store.process(.loadHistory(sessionId: "session", cwd: "/tmp/project"))
        _ = await (first, second)
        let session = await store.session(for: "session")
        XCTAssertEqual(session?.chatItems.map(\.type), [.user("question"), .assistant("answer")])
    }

    func testCodexStopPublishesCompletionAndKeepsIdleSession() async throws {
        let store = SessionStore.shared
        await store.resetForTesting()

        let receivedCompletion = expectation(description: "Codex completion notification")
        let recorder = NotificationRecorder()
        let cancellable = store.completionNotificationsPublisher.sink { notification in
            recorder.record(notification)
            receivedCompletion.fulfill()
        }
        defer { cancellable.cancel() }

        await store.process(.codexSessionStarted(
            sessionId: "codex-session",
            cwd: "/tmp/project",
            source: "selftest"
        ))
        await store.process(.codexPromptSubmitted(
            sessionId: "codex-session",
            cwd: "/tmp/project",
            prompt: "你好"
        ))

        let activeSessions = await store.allSessions()
        XCTAssertEqual(activeSessions.count, 1)
        XCTAssertEqual(activeSessions.first?.provider, .codex)
        XCTAssertEqual(activeSessions.first?.phase, .processing)

        await store.process(.codexStopped(sessionId: "codex-session", cwd: "/tmp/project"))
        await fulfillment(of: [receivedCompletion], timeout: 2.0)

        let notifications = recorder.snapshot()
        XCTAssertEqual(notifications.count, 1)
        XCTAssertEqual(notifications[0].sessionId, "codex-session")
        XCTAssertEqual(notifications[0].provider, .codex)

        let sessionsAfterStop = await store.allSessions()
        XCTAssertEqual(sessionsAfterStop.count, 1)
        XCTAssertEqual(sessionsAfterStop.first?.sessionId, "codex-session")
        XCTAssertEqual(sessionsAfterStop.first?.phase, .idle)

        await store.setSessionPidForTesting(sessionId: "codex-session", pid: 999_999)
        await store.recheckAllSessionsForTesting()

        let sessionsAfterExitedProcessCheck = await store.allSessions()
        XCTAssertEqual(sessionsAfterExitedProcessCheck.count, 1)
        XCTAssertEqual(sessionsAfterExitedProcessCheck.first?.sessionId, "codex-session")
        XCTAssertEqual(sessionsAfterExitedProcessCheck.first?.phase, .idle)

        await store.process(.codexToolFinished(
            sessionId: "codex-session",
            cwd: "/tmp/project",
            toolName: "Bash",
            toolUseId: "late-tool",
            inputSummary: "echo late",
            output: "late",
            isError: false
        ))

        let sessionsAfterLateEvent = await store.allSessions()
        XCTAssertEqual(sessionsAfterLateEvent.count, 1)
        XCTAssertEqual(sessionsAfterLateEvent.first?.phase, .idle)
        XCTAssertTrue(sessionsAfterLateEvent.first?.toolTracker.inProgress.isEmpty ?? false)
        XCTAssertEqual(recorder.snapshot().count, 1)

        await store.process(.codexToolStarted(
            sessionId: "codex-session",
            cwd: "/tmp/project",
            toolName: "Bash",
            toolUseId: "late-tool-start",
            input: ["command": "echo late"],
            inputSummary: "echo late"
        ))

        let sessionsAfterLateStart = await store.allSessions()
        XCTAssertEqual(sessionsAfterLateStart.count, 1)
        XCTAssertEqual(sessionsAfterLateStart.first?.phase, .idle)
        XCTAssertTrue(sessionsAfterLateStart.first?.toolTracker.inProgress.isEmpty ?? false)
        XCTAssertEqual(recorder.snapshot().count, 1)

        await store.resetForTesting()
    }

    func testCodexStartupSuggestionSessionIsHidden() async throws {
        let store = SessionStore.shared
        await store.resetForTesting()

        await store.process(.codexSessionStarted(
            sessionId: "internal-startup",
            cwd: "/tmp/project",
            source: "startup"
        ))
        let sessionsAfterStart = await store.allSessions()
        XCTAssertTrue(sessionsAfterStart.isEmpty)

        await store.process(.codexToolStarted(
            sessionId: "internal-startup",
            cwd: "/tmp/project",
            toolName: "Bash",
            toolUseId: "tool-before-prompt",
            input: ["command": "pwd"],
            inputSummary: "pwd"
        ))
        let sessionsAfterEarlyTool = await store.allSessions()
        XCTAssertTrue(sessionsAfterEarlyTool.isEmpty)

        await store.process(.codexPromptSubmitted(
            sessionId: "internal-startup",
            cwd: "/tmp/project",
            prompt: """
            # Overview

            Generate 0 to 3 hyperpersonalized suggestions for what this user can do with Codex in this local project.
            Recent Codex threads in this project:
            []
            Return 0 to 3 fresh suggestions.
            """
        ))
        let sessionsAfterInternalPrompt = await store.allSessions()
        XCTAssertTrue(sessionsAfterInternalPrompt.isEmpty)

        await store.process(.codexToolStarted(
            sessionId: "internal-startup",
            cwd: "/tmp/project",
            toolName: "Bash",
            toolUseId: "tool-1",
            input: ["command": "git status"],
            inputSummary: "git status"
        ))
        let sessionsAfterIgnoredTool = await store.allSessions()
        XCTAssertTrue(sessionsAfterIgnoredTool.isEmpty)

        await store.resetForTesting()
    }

    func testCodexStartupUserPromptStillCreatesSession() async throws {
        let store = SessionStore.shared
        await store.resetForTesting()

        await store.process(.codexSessionStarted(
            sessionId: "user-startup",
            cwd: "/tmp/project",
            source: "startup"
        ))
        let sessionsAfterStart = await store.allSessions()
        XCTAssertTrue(sessionsAfterStart.isEmpty)

        await store.process(.codexPromptSubmitted(
            sessionId: "user-startup",
            cwd: "/tmp/project",
            prompt: "你好"
        ))

        let sessions = await store.allSessions()
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions.first?.sessionId, "user-startup")
        XCTAssertEqual(sessions.first?.phase, .processing)

        await store.resetForTesting()
    }
}

private final class NotificationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var notifications: [SessionCompletionNotification] = []

    func record(_ notification: SessionCompletionNotification) {
        lock.lock()
        notifications.append(notification)
        lock.unlock()
    }

    func snapshot() -> [SessionCompletionNotification] {
        lock.lock()
        defer { lock.unlock() }
        return notifications
    }
}
