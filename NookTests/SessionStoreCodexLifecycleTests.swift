import Combine
import XCTest
@testable import Nook

@MainActor
final class SessionStoreCodexLifecycleTests: XCTestCase {
    func testCodexStopPublishesCompletionAndRemovesActiveSession() async throws {
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
        XCTAssertTrue(sessionsAfterStop.isEmpty)

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
        XCTAssertTrue(sessionsAfterLateEvent.isEmpty)
        XCTAssertEqual(recorder.snapshot().count, 1)

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
