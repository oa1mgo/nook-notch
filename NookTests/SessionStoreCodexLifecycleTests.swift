import Combine
import XCTest
@testable import Nook

@MainActor
final class SessionStoreCodexLifecycleTests: XCTestCase {
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
