import Combine
import XCTest
@testable import Nook

@MainActor
final class SessionStoreOpencodeLifecycleTests: XCTestCase {
    override func tearDown() async throws {
        await SessionStore.shared.resetForTesting()
        try await super.tearDown()
    }

    private func startProcessingSession(_ store: SessionStore, id: String) async {
        await store.process(.opencodePromptSubmitted(sessionId: id, cwd: "/tmp/proj", prompt: "hello"))
    }

    /// `status=idle` 与 `session.idle` 双发会产生两条 `.stop`。第二条不得再发完成通知。
    func testDuplicateStopNotifiesExactlyOnce() async {
        let store = SessionStore.shared
        await store.resetForTesting()
        let recorder = NotificationRecorder()
        let cancellable = store.completionNotificationsPublisher.sink { recorder.record($0) }
        defer { cancellable.cancel() }

        await startProcessingSession(store, id: "dup")
        await store.process(.opencodeStopped(sessionId: "dup", cwd: "/tmp/proj"))
        await store.process(.opencodeStopped(sessionId: "dup", cwd: "/tmp/proj"))

        let session = await store.session(for: "dup")
        XCTAssertEqual(session?.phase, .idle)
        XCTAssertEqual(recorder.snapshot().count, 1)
    }

    /// 等待用户输入时收到 `.stop` 不能把会话打成 idle（否则问题面板被关掉）。
    func testStopWhileWaitingForInputKeepsWaitingPhase() async {
        let store = SessionStore.shared
        await store.resetForTesting()
        let recorder = NotificationRecorder()
        let cancellable = store.completionNotificationsPublisher.sink { recorder.record($0) }
        defer { cancellable.cancel() }

        await startProcessingSession(store, id: "waiting")
        await store.process(.opencodeWaitingForUserInput(
            sessionId: "waiting",
            cwd: "/tmp/proj",
            toolUseId: "tool-1",
            questions: [],
            requestId: "que_1"
        ))
        await store.process(.opencodeStopped(sessionId: "waiting", cwd: "/tmp/proj"))

        let session = await store.session(for: "waiting")
        XCTAssertTrue(session?.phase.isWaitingForInput == true)
        XCTAssertTrue(recorder.snapshot().isEmpty)
    }

    /// 审批条挂起时同理：`.stop` 不得清掉 waitingForApproval。
    /// 它的回收出口是后续 task 的 600s quiet-expiry。
    func testStopWhileWaitingForApprovalKeepsPhase() async {
        let store = SessionStore.shared
        await store.resetForTesting()
        let recorder = NotificationRecorder()
        let cancellable = store.completionNotificationsPublisher.sink { recorder.record($0) }
        defer { cancellable.cancel() }

        await startProcessingSession(store, id: "approval")
        await store.process(.opencodePermissionRequested(
            sessionId: "approval",
            cwd: "/tmp/proj",
            permission: "bash",
            requestId: "per_1",
            toolUseId: "call-1",
            input: [:],
            inputSummary: nil,
            alwaysPatterns: []
        ))
        let notificationsBeforeStop = recorder.snapshot().count
        await store.process(.opencodeStopped(sessionId: "approval", cwd: "/tmp/proj"))

        let session = await store.session(for: "approval")
        XCTAssertTrue(session?.phase.isWaitingForApproval == true)
        XCTAssertEqual(recorder.snapshot().count, notificationsBeforeStop)
    }
}
