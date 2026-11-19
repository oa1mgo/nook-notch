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

    /// 权限提示通知是延迟发的：手动审批时仍会响（用户需要被叫回来看），
    /// 但不会在 asked 的同一刻就响。
    func testPermissionPromptNotificationIsDelayed() async throws {
        let store = SessionStore.shared
        await store.resetForTesting()
        await store.setPermissionPromptNotificationDelayForTesting(50_000_000)  // 50ms
        let recorder = NotificationRecorder()
        let cancellable = store.completionNotificationsPublisher.sink { recorder.record($0) }
        defer { cancellable.cancel() }

        await startProcessingSession(store, id: "prompt-delay")
        await store.process(.opencodePermissionRequested(
            sessionId: "prompt-delay", cwd: "/tmp/proj", permission: "bash",
            requestId: "per_1", toolUseId: "call-1", input: [:], inputSummary: nil, alwaysPatterns: []))

        XCTAssertTrue(recorder.snapshot().isEmpty, "prompt notification must be held")
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(recorder.snapshot().count, 1)
    }

    /// `opencode run --auto` 会在毫秒级返回 `permission.replied`：此时用户
    /// 根本没机会看到审批条，提示音必须被取消，只保留真正完成时的通知。
    func testPermissionRepliedCancelsPromptNotification() async throws {
        let store = SessionStore.shared
        await store.resetForTesting()
        await store.setPermissionPromptNotificationDelayForTesting(50_000_000)  // 50ms
        let recorder = NotificationRecorder()
        let cancellable = store.completionNotificationsPublisher.sink { recorder.record($0) }
        defer { cancellable.cancel() }

        await startProcessingSession(store, id: "prompt-cancel")
        await store.process(.opencodePermissionRequested(
            sessionId: "prompt-cancel", cwd: "/tmp/proj", permission: "external_directory",
            requestId: "per_1", toolUseId: nil, input: [:], inputSummary: nil, alwaysPatterns: ["/tmp/*"]))
        await store.process(.opencodePermissionReplied(sessionId: "prompt-cancel", requestId: "per_1", reply: "once"))

        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertTrue(recorder.snapshot().isEmpty, "auto-answered prompts must not ring")
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

    /// opencode 自己应答权限（TUI 里点、另一个 client，或 `opencode run --auto`
    /// 自动回 "once"）时，`permission.replied` 是唯一的解除信号：toolUseId 为
    /// nil 的 permission（如 external_directory）没有 tool 完成事件可兜底。
    func testPermissionRepliedClearsWaitingPhase() async {
        let store = SessionStore.shared
        await store.resetForTesting()
        await startProcessingSession(store, id: "replied")
        await store.process(.opencodePermissionRequested(
            sessionId: "replied", cwd: "/tmp/proj", permission: "external_directory",
            requestId: "per_1", toolUseId: nil, input: [:], inputSummary: nil, alwaysPatterns: []))

        var session = await store.session(for: "replied")
        XCTAssertTrue(session?.phase.isWaitingForApproval == true)

        await store.process(.opencodePermissionReplied(sessionId: "replied", requestId: "per_1", reply: "once"))
        session = await store.session(for: "replied")
        XCTAssertEqual(session?.phase, .processing)
    }

    /// requestID 不匹配（Nook 自己的回复路径已推进 phase，或事件迟到）时必须
    /// 幂等忽略，不能误伤仍在等待的审批。
    func testPermissionRepliedWithUnknownRequestIdIsIgnored() async {
        let store = SessionStore.shared
        await store.resetForTesting()
        await startProcessingSession(store, id: "replied-stale")
        await store.process(.opencodePermissionRequested(
            sessionId: "replied-stale", cwd: "/tmp/proj", permission: "bash",
            requestId: "per_1", toolUseId: "call-1", input: [:], inputSummary: nil, alwaysPatterns: []))

        await store.process(.opencodePermissionReplied(sessionId: "replied-stale", requestId: "per_other", reply: "once"))

        let session = await store.session(for: "replied-stale")
        XCTAssertTrue(session?.phase.isWaitingForApproval == true)
    }

    /// `.stop` 之后如果有一个 chat item 抢在第二条 `.stop` 之前把 phase
    /// 拉回 `.processing`，第二条 `.stop` 不得再发通知。闩锁按「轮」重置，
    /// 不依赖 phase。
    func testDuplicateStopAfterLateChatItemNotifiesOnce() async {
        let store = SessionStore.shared
        await store.resetForTesting()
        let recorder = NotificationRecorder()
        let cancellable = store.completionNotificationsPublisher.sink { recorder.record($0) }
        defer { cancellable.cancel() }

        await startProcessingSession(store, id: "late")
        await store.process(.opencodeStopped(sessionId: "late", cwd: "/tmp/proj"))
        await store.process(.realtimeChatItemBatch([
            ChatItemUpdate(
                id: "late-text",
                sessionId: "late",
                block: .assistantText("late chunk"),
                ordering: .timestamp(Date()),
                mutation: .insert,
                provider: .opencode
            )
        ]))
        let reactivated = await store.session(for: "late")
        XCTAssertEqual(reactivated?.phase, .processing, "late assistant text must re-enter processing")
        await store.process(.opencodeStopped(sessionId: "late", cwd: "/tmp/proj"))

        let session = await store.session(for: "late")
        XCTAssertEqual(session?.phase, .idle)
        XCTAssertEqual(recorder.snapshot().count, 1)
        XCTAssertEqual(recorder.snapshot().map(\.sessionId), ["late"])
    }

    /// 新的一轮必须重新武装通知闩锁。
    func testNewTurnAfterCompletionNotifiesAgain() async {
        let store = SessionStore.shared
        await store.resetForTesting()
        let recorder = NotificationRecorder()
        let cancellable = store.completionNotificationsPublisher.sink { recorder.record($0) }
        defer { cancellable.cancel() }

        await startProcessingSession(store, id: "again")
        await store.process(.opencodeStopped(sessionId: "again", cwd: "/tmp/proj"))
        await startProcessingSession(store, id: "again")
        await store.process(.opencodeStopped(sessionId: "again", cwd: "/tmp/proj"))

        XCTAssertEqual(recorder.snapshot().count, 2)
    }

    /// question.rejected 后 .stop 能正常收尾（不再卡在 waitingForInput）。
    func testQuestionRejectedThenStopEndsTurn() async {
        let store = SessionStore.shared
        await store.resetForTesting()
        await startProcessingSession(store, id: "qrej")
        await store.process(.opencodeWaitingForUserInput(
            sessionId: "qrej", cwd: "/tmp/proj", toolUseId: "tool-1", questions: [], requestId: "que_1"))
        await store.process(.opencodeProcessingStarted(sessionId: "qrej", cwd: "/tmp/proj"))
        await store.process(.opencodeStopped(sessionId: "qrej", cwd: "/tmp/proj"))

        let session = await store.session(for: "qrej")
        XCTAssertEqual(session?.phase, .idle)
    }

    /// status=busy（processingStarted）也必须重新武装通知闩锁（TUI 轮次路径）。
    func testProcessingStartedReArmsCompletionNotification() async {
        let store = SessionStore.shared
        await store.resetForTesting()
        let recorder = NotificationRecorder()
        let cancellable = store.completionNotificationsPublisher.sink { recorder.record($0) }
        defer { cancellable.cancel() }

        await startProcessingSession(store, id: "busy")
        await store.process(.opencodeStopped(sessionId: "busy", cwd: "/tmp/proj"))
        await store.process(.opencodeProcessingStarted(sessionId: "busy", cwd: "/tmp/proj"))
        await store.process(.opencodeStopped(sessionId: "busy", cwd: "/tmp/proj"))

        XCTAssertEqual(recorder.snapshot().count, 2)
    }

    func testActiveQuietExpiryMarksOpencodeIdle() async {
        let store = SessionStore.shared
        await store.resetForTesting()
        await startProcessingSession(store, id: "quiet")
        await store.setLastActivityForTesting(sessionId: "quiet", secondsAgo: 120)
        await store.recheckAllSessionsForTesting()

        let session = await store.session(for: "quiet")
        XCTAssertEqual(session?.phase, .idle)
        XCTAssertNil(session?.completionNotificationAt)
        XCTAssertTrue(session?.toolTracker.inProgress.isEmpty == true)
    }

    func testRunningToolGetsLongerQuietWindow() async {
        let store = SessionStore.shared
        await store.resetForTesting()
        await startProcessingSession(store, id: "tool")
        await store.process(.realtimeChatItemBatch([
            ChatItemUpdate(
                id: "call-1",
                sessionId: "tool",
                block: .toolCall(makeToolCall(id: "call-1", status: .running)),
                ordering: .timestamp(Date()),
                mutation: .insert,
                provider: .opencode
            )
        ]))
        await store.setLastActivityForTesting(sessionId: "tool", secondsAgo: 120)
        await store.recheckAllSessionsForTesting()

        let stillRunning = await store.session(for: "tool")
        XCTAssertEqual(stillRunning?.phase, .processing, "running tool must not expire at 90s")

        await store.setLastActivityForTesting(sessionId: "tool", secondsAgo: 700)
        await store.recheckAllSessionsForTesting()
        let expired = await store.session(for: "tool")
        XCTAssertEqual(expired?.phase, .idle)
        let tool = expired?.chatItems.compactMap { item -> ToolCallItem? in
            if case .toolCall(let t) = item.type { return t }
            return nil
        }.first
        XCTAssertEqual(tool?.status, .interrupted)
    }

    /// waitingForInput 是用户可能真的要思考很久的状态：不自动过期。
    func testWaitingForInputIsNotExpired() async {
        let store = SessionStore.shared
        await store.resetForTesting()
        await startProcessingSession(store, id: "wait")
        await store.process(.opencodeWaitingForUserInput(
            sessionId: "wait", cwd: "/tmp/proj", toolUseId: "tool-1", questions: [], requestId: "que_1"))
        await store.setLastActivityForTesting(sessionId: "wait", secondsAgo: 700)
        await store.recheckAllSessionsForTesting()

        let session = await store.session(for: "wait")
        XCTAssertTrue(session?.phase.isWaitingForInput == true)
    }

    /// waitingForApproval 不能永久卡住：120s 不动，700s 回收为 idle。
    func testWaitingForApprovalExpiresAfterLongWindow() async {
        let store = SessionStore.shared
        await store.resetForTesting()
        await startProcessingSession(store, id: "appr-quiet")
        await store.process(.realtimeChatItemBatch([
            ChatItemUpdate(
                id: "call-1",
                sessionId: "appr-quiet",
                block: .toolCall(makeToolCall(id: "call-1", status: .waitingForApproval)),
                ordering: .timestamp(Date()),
                mutation: .insert,
                provider: .opencode
            )
        ]))
        await store.process(.opencodePermissionRequested(
            sessionId: "appr-quiet", cwd: "/tmp/proj", permission: "bash", requestId: "per_1",
            toolUseId: "call-1", input: [:], inputSummary: nil, alwaysPatterns: []))
        await store.setLastActivityForTesting(sessionId: "appr-quiet", secondsAgo: 120)
        await store.recheckAllSessionsForTesting()

        let waiting = await store.session(for: "appr-quiet")
        XCTAssertTrue(waiting?.phase.isWaitingForApproval == true)

        await store.setLastActivityForTesting(sessionId: "appr-quiet", secondsAgo: 700)
        await store.recheckAllSessionsForTesting()
        let expired = await store.session(for: "appr-quiet")
        XCTAssertEqual(expired?.phase, .idle)
        let expiredTool = expired?.chatItems.compactMap { item -> ToolCallItem? in
            if case .toolCall(let t) = item.type { return t }
            return nil
        }.first
        XCTAssertEqual(expiredTool?.status, .interrupted,
                       "approval tool must not stay in waitingForApproval after phase expires")
    }

    /// 阈值是严格大于：89s 不回收，91s 回收。
    func testActiveQuietExpiryBoundaryIsExclusive() async {
        let store = SessionStore.shared
        await store.resetForTesting()
        await startProcessingSession(store, id: "boundary")

        await store.setLastActivityForTesting(sessionId: "boundary", secondsAgo: 89)
        await store.recheckAllSessionsForTesting()
        let notYet = await store.session(for: "boundary")
        XCTAssertEqual(notYet?.phase, .processing)

        await store.setLastActivityForTesting(sessionId: "boundary", secondsAgo: 91)
        await store.recheckAllSessionsForTesting()
        let expired = await store.session(for: "boundary")
        XCTAssertEqual(expired?.phase, .idle)
    }
}
