# opencode 会话结束信号恢复 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让 opencode 会话在「结束事件丢失」或「结束事件全部缺失」时都能正确退出 `.processing`，且不产生重复完成通知、不覆盖等待态。

**Architecture:** 两层互补。协议层把 `session.status=idle`（源码中与 `session.idle` 同点双发，且 `session.idle` 已 deprecated）也映射成 `.stop`，并把 `session.status=retry` 映射成 `.processingStarted`（provider 退避期间刷新 `lastActivity`，否则静默兜底会把重试中的会话误判为空闲）；状态层把 phase 转移与完成通知收口到 `SessionStore.processOpencodeStop` 的 `wasActive` guard，保证幂等。状态层再加 opencode 专属静默过期兜底（正常 90s；运行中工具 / `.compacting` / `.waitingForApproval` 600s；`.waitingForInput` 不自动过期）。

**Tech Stack:** Swift 6 / SwiftUI（macOS）、XCTest、opencode plugin 事件流（Unix socket）。

**依据：**
- `docs/specs/2026-06-17-opencode-v1.17-compatibility-matrix.md` 陷阱 4
- `docs/debug/2026-10-23-opencode-lost-idle-stuck-processing.md`
- 本地 opencode 源码（CLI 1.19.3）：
  - `packages/schema/src/session-status-event.ts` — `idle` 标注 deprecated；`retry` 携带 `attempt` / `message` / `next`
  - `packages/opencode/src/session/status.ts` — `SessionStatus.set()` 先 `publish(Status)`，`status.type === "idle"` 时紧接着 `publish(Idle)`（同一次调用 1:1 双发）
  - `packages/opencode/src/session/retry.ts` — `policy()` 在**进入退避等待之前**调用 `set({type:"retry", next: now + wait})`，即每次 attempt 刷新一次；默认 `wait` 上限 30s
  - `packages/opencode/src/session/processor.ts` — `Effect.catch(halt)` 只在 retry 策略耗尽后触发，说明 `status=idle` 不会在 retry 中途发出

---

## 决策摘要（已定，实施时不要改）

1. `.stop` 的驱动源是 `session.status=idle`，不是 `finish=stop`。`finish` 跟着 step 走，会被 `message.updated` 重复携带。
2. adapter 不持有 phase → `handleSessionStatus` 的 `idle` 分支**无条件**产 `.stop`。
3. phase guard 落在 `SessionStore.processOpencodeStop`：只把「phase → `.idle`」+ 完成通知放进 `wasActive` 条件；running-tool 清理、`toolTracker` 清空、`publishState()` 照旧执行。
4. `.stop` 不再清除 `.waitingForInput` / `.waitingForApproval`（这是本次要修的误清）。代价是等待态必须有出口：
   - `.waitingForApproval`：quiet-expiry 600s 档兜底。
   - `.waitingForInput`：**不设自动过期**（用户可能真的要思考很久）。Task 1 之后 `session.idle` / `status=idle` **不再是出口**（`.stop` 对非 active 相位不改 phase，而 `isActive` 不含等待态），剩下的出口只有这几种：`question.replied`、`question.rejected`、`session.status=busy`、新一轮用户 prompt（`opencodePromptSubmitted` 直接置 `.processing`）。
     其中只有 `busy` 不依赖用户动作——这是已知残留风险，写进文档与验证清单，不在本计划内解决。
5. quiet-expiry 只降级为 `.idle`（不是 `.ended`），后续事件可把会话拉回 `.processing`。
6. `wasActive` 行为变化：Nook 中途启动、phase 从未进入 active 的会话，`.stop` 不再发完成通知。属改进，写进 PR 描述。
7. `session.status=retry` 映射成 `.processingStarted`。原先「有意不消费」在加入 90s 静默兜底后变成缺陷：重试期间 `lastActivity` 不刷新，phase 仍是 `.processing`，90s 后会闪一次 idle。`processingStarted` 恰好会刷新 `lastActivity` 并对 `.waitingForApproval` / `.waitingForTerminalApproval` 做抑制，语义安全。
8. 完成通知用「每轮一次」闩锁（`opencodeCompletionNotifiedSessions`），不依赖 phase。原因：chat items 与 passthrough 在不同 `Task` 中分发，chat item 可能在两条 `.stop` 之间把 phase 拉回 `.processing`，单靠 `wasActive` 会二次通知。闩锁在新一轮（prompt / `status=busy`）重置。
9. `question.rejected` 映射成 `.processingStarted`。Task 1 之后 `.stop` 不再清 `.waitingForInput`；用户拒绝问题后若该轮直接结束，没有 `busy` 可依赖，会永久停在等待态。正常拒答后模型继续跑，映射成 processing 与 `question.replied` 对称。
10. **≤1.17 结束信号不支持**：`status=idle` 只在 ≥1.18 是轮末信号；v1.15.13 / v1.17.x 会在 tool step 之间发 `status=idle`，不能作为轮末信号。旧版丢失 `session.idle` 时靠 90s 静默兜底（可能闪烁或按步通知）。

---

## Task 1: `processOpencodeStop` 幂等 + 等待态保护

**Files:**
- Modify: `Nook/Services/State/SessionStore.swift`（`processOpencodeStop`）
- Modify: `NookTests/TestSupport.swift`（移动 `NotificationRecorder`）
- Modify: `NookTests/SessionStoreCodexLifecycleTests.swift`（删除本地 `NotificationRecorder`）
- Test: `NookTests/SessionStoreOpencodeLifecycleTests.swift`（新建）

- [x] **Step 1: 把 `NotificationRecorder` 移到共享测试支持**

`NotificationRecorder` 目前是 `SessionStoreCodexLifecycleTests.swift` 末尾的 `private` 类，新测试文件看不到它。
把它原样剪切到 `NookTests/TestSupport.swift` 末尾（改为 `final class NotificationRecorder`，去掉 `private`），
并从 `SessionStoreCodexLifecycleTests.swift` 删除该定义。

- [x] **Step 2: 写失败测试**

新建 `NookTests/SessionStoreOpencodeLifecycleTests.swift`：

```swift
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
    /// 它的回收出口是 Task 3 的 600s quiet-expiry。
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
        await store.process(.opencodeStopped(sessionId: "approval", cwd: "/tmp/proj"))

        let session = await store.session(for: "approval")
        XCTAssertTrue(session?.phase.isWaitingForApproval == true)
        XCTAssertTrue(recorder.snapshot().isEmpty)
    }
}
```

- [x] **Step 3: 运行，确认失败**

```bash
xcodebuild test -project Nook.xcodeproj -scheme Nook -configuration Debug \
  -derivedDataPath build/TestDerivedData -destination 'platform=macOS' \
  -only-testing:NookTests/SessionStoreOpencodeLifecycleTests
```

Expected: `testDuplicateStopNotifiesExactlyOnce`、`testStopWhileWaitingForInputKeepsWaitingPhase`、
`testStopWhileWaitingForApprovalKeepsPhase` 失败（当前实现无条件设 idle 并每次发通知）。

- [x] **Step 4: 改 `processOpencodeStop`**

把函数体改成（只加 `wasActive` 分支，清理逻辑不动）：

```swift
    private func processOpencodeStop(sessionId: String, cwd: String) {
        if sessions[sessionId] == nil, !registeredSessionIds.contains(sessionId) {
            writeDebugLogAsync("[opencode-lifecycle] ignored pre-registration stop session=\(sessionId.prefix(12)) cwd=\(cwd)")
            return
        }
        var session = sessions[sessionId] ?? createOpencodeSession(sessionId: sessionId, cwd: cwd)
        let wasActive = session.phase.isActive
        let hadRunningTools = hasRunningTools(in: session)
        enrichOpencodeRuntimeMetadata(session: &session)
        session.lastActivity = Date()

        for index in session.chatItems.indices {
            if case .toolCall(var tool) = session.chatItems[index].type, tool.status == .running {
                tool.status = .interrupted
                session.chatItems[index] = ChatHistoryItem(
                    id: session.chatItems[index].id,
                    type: .toolCall(tool),
                    timestamp: session.chatItems[index].timestamp
                )
            }
        }

        session.toolTracker.inProgress.removeAll()

        // Only an active turn can be completed. A duplicate `.stop` (status=idle
        // + session.idle double-fire), a `.stop` while waiting for user input, or
        // one while an approval is pending must not re-notify or clobber the phase.
        // waitingForApproval is recovered by the quiet-expiry path; waitingForInput
        // has no timer and recovers only via question.replied / busy / a new prompt.
        if wasActive {
            session.phase = .idle
        }
        sessions[sessionId] = session
        publishState()

        // No completion sound/bounce for non-active sessions: Nook can be launched
        // mid-turn, and a late `.stop` must not announce a completion the user
        // never saw start.
        if wasActive && !hadRunningTools {
            publishCompletionNotification(for: session)
        }
    }
```

- [x] **Step 5: 运行，确认通过**

```bash
xcodebuild test -project Nook.xcodeproj -scheme Nook -configuration Debug \
  -derivedDataPath build/TestDerivedData -destination 'platform=macOS' \
  -only-testing:NookTests/SessionStoreOpencodeLifecycleTests
```

Expected: PASS。

- [x] **Step 6: Commit**

```bash
git add Nook/Services/State/SessionStore.swift NookTests/TestSupport.swift \
  NookTests/SessionStoreCodexLifecycleTests.swift NookTests/SessionStoreOpencodeLifecycleTests.swift
git commit -m "fix(opencode): make stop handling idempotent and waiting-safe"
```

---

## Task 2: `session.status=idle` 也产 `.stop`（并消费 `retry`）

**Files:**
- Modify: `Nook/Services/Hooks/OpencodeHookAdapter.swift`（`handleSessionStatus` 的 `case "idle"` / `case "retry"`，dispatch 的 `question.rejected`）
- Modify: `Nook/Services/State/SessionStore.swift`（完成通知去重闩锁）
- Test: `NookTests/OpencodeHookAdapterEventDrivenSelfHealTests.swift`（追加）
- Test: `NookTests/OpencodeChatItemAdapterTests.swift`（改现有断言）
- Test: `NookTests/SessionStoreOpencodeLifecycleTests.swift`（追加）

- [x] **Step 1: 写失败测试**

追加到 `OpencodeHookAdapterEventDrivenSelfHealTests`：

```swift
    func testSessionStatusIdleEmitsStop() {
        let sessionId = "ses_idle_\(UUID().uuidString)"
        _ = OpencodeHookAdapter.adapt(OpencodeHookEnvelope(
            origin: "opencode",
            type: "session.started",
            properties: [
                "sessionID": AnyCodable(sessionId),
                "cwd": AnyCodable("/tmp/test-project"),
                "pid": AnyCodable(12345),
            ]
        ))

        let events = OpencodeHookAdapter.adapt(OpencodeHookEnvelope(
            origin: "opencode",
            type: "session.status",
            properties: [
                "sessionID": AnyCodable(sessionId),
                "status": AnyCodable(["type": "idle"]),
            ]
        ))

        XCTAssertTrue(events.contains { event in
            if case .stop(let sid, _) = event { return sid == sessionId }
            return false
        }, "session.status=idle must emit .stop, got \(events)")
    }

    func testSessionStatusBusyDoesNotEmitStop() {
        let sessionId = "ses_busy_\(UUID().uuidString)"
        _ = OpencodeHookAdapter.adapt(OpencodeHookEnvelope(
            origin: "opencode",
            type: "session.started",
            properties: [
                "sessionID": AnyCodable(sessionId),
                "cwd": AnyCodable("/tmp/test-project"),
                "pid": AnyCodable(12345),
            ]
        ))

        let events = OpencodeHookAdapter.adapt(OpencodeHookEnvelope(
            origin: "opencode",
            type: "session.status",
            properties: [
                "sessionID": AnyCodable(sessionId),
                "status": AnyCodable(["type": "busy"]),
            ]
        ))

        XCTAssertFalse(events.contains { event in
            if case .stop = event { return true }
            return false
        })
    }

    /// Provider 退避重试期间不能被认为是空闲：必须产 `.processingStarted`
    /// 以刷新 SessionStore 的 lastActivity，否则 90s 静默兜底会误判。
    func testSessionStatusRetryRefreshesActivityWithoutStopping() {
        let sessionId = "ses_retry_\(UUID().uuidString)"
        _ = OpencodeHookAdapter.adapt(OpencodeHookEnvelope(
            origin: "opencode",
            type: "session.started",
            properties: [
                "sessionID": AnyCodable(sessionId),
                "cwd": AnyCodable("/tmp/test-project"),
                "pid": AnyCodable(12345),
            ]
        ))

        let events = OpencodeHookAdapter.adapt(OpencodeHookEnvelope(
            origin: "opencode",
            type: "session.status",
            properties: [
                "sessionID": AnyCodable(sessionId),
                "status": AnyCodable([
                    "type": "retry",
                    "attempt": 2,
                    "message": "rate limited",
                    "next": 1_700_000_000_000,
                ] as [String: Any]),
            ]
        ))

        XCTAssertTrue(events.contains { event in
            if case .processingStarted(let sid, _) = event { return sid == sessionId }
            return false
        }, "session.status=retry must emit .processingStarted, got \(events)")
        XCTAssertFalse(events.contains { event in
            if case .stop = event { return true }
            return false
        }, "session.status=retry must not end the turn")
    }

    /// 用户在 TUI 里拒绝/取消问题后，opencode 会发 `question.rejected`。
    /// 不消费它 + `.stop` 不再清等待态 = 问题面板永久可交互。
    /// 模型拒答后通常继续跑，所以映射成 `.processingStarted`；若该轮直接结束，
    /// 随后的 `status=idle` 会把 processing 正常收尾。
    func testQuestionRejectedResumesProcessing() {
        let sessionId = "ses_qrej_\(UUID().uuidString)"
        _ = OpencodeHookAdapter.adapt(OpencodeHookEnvelope(
            origin: "opencode",
            type: "session.started",
            properties: [
                "sessionID": AnyCodable(sessionId),
                "cwd": AnyCodable("/tmp/test-project"),
                "pid": AnyCodable(12345),
            ]
        ))

        let events = OpencodeHookAdapter.adapt(OpencodeHookEnvelope(
            origin: "opencode",
            type: "question.rejected",
            properties: [
                "sessionID": AnyCodable(sessionId),
                "requestID": AnyCodable("que_1"),
            ]
        ))

        XCTAssertTrue(events.contains { event in
            if case .processingStarted(let sid, _) = event { return sid == sessionId }
            return false
        }, "question.rejected must emit .processingStarted, got \(events)")
    }
```

追加到 `SessionStoreOpencodeLifecycleTests`：

```swift
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
        await store.process(.opencodeStopped(sessionId: "late", cwd: "/tmp/proj"))

        let session = await store.session(for: "late")
        XCTAssertEqual(session?.phase, .idle)
        XCTAssertEqual(recorder.snapshot().count, 1)
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
```

- [x] **Step 2: 改现有断言（否则 Task 4 全量测试会失败）**

`NookTests/OpencodeChatItemAdapterTests.swift` 的
`testEnvelopeStreamProducesPromptThinkingToolAndPassthroughEvents`：

```swift
        let idle = adapter.adaptAndConvert(envelope(
            "session.status",
            sessionId: sessionId,
            properties: ["status": ["type": "idle"]]
        ))
        XCTAssertTrue(idle.chatItemUpdates.isEmpty)
        XCTAssertEqual(idle.passthroughEvents.count, 1)
        guard case .stop(let idleSession, _) = idle.passthroughEvents[0] else {
            return XCTFail("session.status=idle must pass through as .stop")
        }
        XCTAssertEqual(idleSession, sessionId)
```

- [x] **Step 3: 运行，确认失败**

```bash
xcodebuild test -project Nook.xcodeproj -scheme Nook -configuration Debug \
  -derivedDataPath build/TestDerivedData -destination 'platform=macOS' \
  -only-testing:NookTests/OpencodeHookAdapterEventDrivenSelfHealTests \
  -only-testing:NookTests/OpencodeChatItemAdapterTests \
  -only-testing:NookTests/SessionStoreOpencodeLifecycleTests
```

Expected: `testSessionStatusIdleEmitsStop`、`testSessionStatusRetryRefreshesActivityWithoutStopping`、`testQuestionRejectedResumesProcessing`、`testDuplicateStopAfterLateChatItemNotifiesOnce` 与改后的 ChatItemAdapter 断言 FAIL
（当前 `idle` 分支不产 `.stop`；`retry` / `question.rejected` 走 `default` 返回空；重复通知没有闩锁）。`testNewTurnAfterCompletionNotifiesAgain` 当前应通过。

- [x] **Step 4: 改 `idle` 分支，并新增 `retry` 分支**

```swift
        case "idle":
            // v1.19 source: SessionStatus.set(idle) publishes session.status=idle
            // and session.idle from the same call (1:1). session.idle is
            // deprecated, so status=idle is the canonical end signal too.
            //
            // Deliberately no cleanupState() here: on older opencode versions
            // status=idle fires between tool steps, and clearing per-step buffers
            // would drop in-flight text. cleanupState stays on the legacy
            // session.idle path.
            //
            // The phase guard lives in SessionStore.processOpencodeStop: adapter
            // has no phase state and must emit unconditionally.
            //
            // recentlyStoppedSessions is pruned (30s cutoff) inside cleanupState,
            // which only runs on the legacy session.idle path. If that is the
            // event that got lost, this entry lingers until the next busy or the
            // next real session.idle. One entry per session, bounded, harmless —
            // and it is what suppresses a late session.updated from re-creating
            // the session as a phantom .sessionStart.
            lock.lock()
            recentlyStoppedSessions[sessionId] = Date()
            lock.unlock()
            let flushed = flushPendingText(forSession: sessionId, cwd: cwd)
            Self.logNotice("→ idle (turn end) session=\(sessionId) flushed=\(flushed.count)")
            return flushed + [.stop(sessionId: sessionId, cwd: cwd)]

        case "retry":
            // Provider backoff. retry.ts publishes status=retry once per attempt,
            // BEFORE sleeping (`next - now`) ms, so the wait itself is silent.
            // Without this branch lastActivity never refreshes during a
            // multi-minute backoff and the store's 90s quiet-expiry would flash
            // .idle mid-retry. .processingStarted is the right carrier: it
            // refreshes lastActivity and already suppresses itself for
            // waitingForApproval / waitingForTerminalApproval.
            //
            // Residual gap: if the provider sends a `retry-after` header larger
            // than the quiet window (default backoff caps at 30s, headers do
            // not), one attempt can outlast 90s. The following busy/retry pulls
            // the phase back to .processing, so the cost is a single flicker.
            let attempt = status["attempt"] as? Int ?? 0
            Self.logNotice("→ processingStarted (session.status=retry attempt=\(attempt)) session=\(sessionId) cwd=\(cwd)")
            return [.processingStarted(sessionId: sessionId, cwd: cwd)]
```

在外层 dispatch switch（`case "question.replied":` 旁边）新增：

```swift
        case "question.rejected":
            // User dismissed/cancelled the question in the TUI (or opencode
            // timed it out). The model normally resumes, so mirror
            // question.replied; if the turn ends instead, the following
            // status=idle now reaches processOpencodeStop with an active phase.
            let cwd: String = {
                lock.lock()
                let v = sessionCwd[sessionId] ?? ""
                lock.unlock()
                return v
            }()
            Self.logNotice("→ question.rejected session=\(sessionId) — transitioning to processing")
            handled = [.processingStarted(sessionId: sessionId, cwd: cwd)]
```

- [x] **Step 5: 状态层加「每轮一次」完成通知闩锁**

`processOpencodeStop` 的 `wasActive` 只能挡住连续两条 `.stop`。`HookSocketServer` 把
chat items 和 passthrough 分发到互不保证顺序的独立 `Task`：若一条 chat item 落在两条
`.stop` 之间，`applyRealtimeChatItemLifecycle` 会把 phase 拉回 `.processing`，第二条
`.stop` 会再次通知。用按轮重置的闩锁，而不是从 phase 推断：

```swift
    /// Sessions whose current turn already published a completion notification.
    /// Reset when a new turn starts (prompt / status=busy), not by chat items —
    /// a late chat item must not re-arm the notification.
    private var opencodeCompletionNotifiedSessions: Set<String> = []
```

在 `processOpencodePromptSubmitted` 开头（`registerSession` 之前）与
`processOpencodeProcessingStarted` 开头（guard 之后）各加：

```swift
        opencodeCompletionNotifiedSessions.remove(sessionId)
```

`processOpencodeStop` 的通知分支改为：

```swift
        if wasActive && !hadRunningTools && !opencodeCompletionNotifiedSessions.contains(sessionId) {
            opencodeCompletionNotifiedSessions.insert(sessionId)
            publishCompletionNotification(for: session)
        }
```

`resetForTesting()` 里加 `opencodeCompletionNotifiedSessions.removeAll()`。

- [x] **Step 6: 运行，确认通过**

```bash
xcodebuild test -project Nook.xcodeproj -scheme Nook -configuration Debug \
  -derivedDataPath build/TestDerivedData -destination 'platform=macOS' \
  -only-testing:NookTests/OpencodeHookAdapterEventDrivenSelfHealTests \
  -only-testing:NookTests/OpencodeChatItemAdapterTests \
  -only-testing:NookTests/SessionStoreOpencodeLifecycleTests
```

Expected: PASS。

- [x] **Step 7: Commit**

```bash
git add Nook/Services/Hooks/OpencodeHookAdapter.swift Nook/Services/State/SessionStore.swift \
  NookTests/OpencodeHookAdapterEventDrivenSelfHealTests.swift \
  NookTests/OpencodeChatItemAdapterTests.swift \
  NookTests/SessionStoreOpencodeLifecycleTests.swift
git commit -m "feat(opencode): treat session.status=idle as turn-end, refresh on retry"
```

> 评审后修复：`dd86f51`（通知闩锁重臂 / 自愈 / flush 顺序加固）。

---

## Task 3: opencode active-quiet 兜底

**Files:**
- Modify: `Nook/Services/State/SessionStore.swift`（常量、`recheckAllSessions`、测试钩子、抽 helper）
- Test: `NookTests/SessionStoreOpencodeLifecycleTests.swift`

- [x] **Step 1: 写失败测试**

追加：

```swift
    func testActiveQuietExpiryMarksOpencodeIdle() async {
        let store = SessionStore.shared
        await store.resetForTesting()
        await startProcessingSession(store, id: "quiet")
        await store.setLastActivityForTesting(sessionId: "quiet", secondsAgo: 120)
        await store.recheckAllSessionsForTesting()

        let session = await store.session(for: "quiet")
        XCTAssertEqual(session?.phase, .idle)
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
        let tool = expired?.chatItems.compactMap { item -> ChatItemToolCall? in
            if case .toolCall(let t) = item.type { return t }
            return nil
        }).first
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
        let expiredTool = expired?.chatItems.compactMap { item -> ChatItemToolCall? in
            if case .toolCall(let t) = item.type { return t }
            return nil
        }).first
        XCTAssertEqual(expiredTool?.status, .interrupted,
                       "approval tool must not stay in waitingForApproval after phase expires")
    }
```

- [x] **Step 2: 运行，确认失败**

```bash
xcodebuild test -project Nook.xcodeproj -scheme Nook -configuration Debug \
  -derivedDataPath build/TestDerivedData -destination 'platform=macOS' \
  -only-testing:NookTests/SessionStoreOpencodeLifecycleTests
```

Expected: `testActiveQuietExpiryMarksOpencodeIdle`、`testRunningToolGetsLongerQuietWindow`、
`testWaitingForApprovalExpiresAfterLongWindow` FAIL（无 opencode 分支）；
`testWaitingForInputIsNotExpired` PASS（isActive 不含 waiting）。

- [x] **Step 3: 加常量 + 测试钩子**

常量（放在 Codex 常量旁）：

```swift
    /// opencode can lose the whole end-of-turn batch (status=idle +
    /// session.idle + message.updated). Bound active states so a lost batch
    /// cannot leave the session stuck in .processing forever.
    /// See docs/debug/2026-10-23-opencode-lost-idle-stuck-processing.md.
    private let opencodeActiveQuietExpirationSeconds: TimeInterval = 90
    /// Running tools, compaction, and pending approvals can legitimately stay
    /// quiet for minutes. opencode has no heartbeat event, so this is the only
    /// signal — keep it generous.
    private let opencodeExtendedQuietExpirationSeconds: TimeInterval = 600
```

测试钩子（`#if DEBUG` 内，放在 `setSessionPidForTesting` 旁）：

```swift
    func setLastActivityForTesting(sessionId: String, secondsAgo: TimeInterval) {
        guard var session = sessions[sessionId] else { return }
        session.lastActivity = Date().addingTimeInterval(-secondsAgo)
        sessions[sessionId] = session
    }
```

- [x] **Step 4: 抽出 `interruptStalledTools` 并替换重复代码**

先做这一步，否则 Step 5 引用的 helper 还不存在，按顺序执行会在中途编译不过。

在 `finishDanglingCodexTools` 附近新增：

```swift
    /// Mark stalled tool calls as interrupted. `includeWaitingForApproval` is for
    /// phase expiry: a tool stuck in `.waitingForApproval` would otherwise keep
    /// pulsing forever in the chat row after the approval bar is dismissed.
    /// `.stop` (Task 1) deliberately keeps the default `false`: a real approval
    /// prompt may still be pending there.
    private func interruptStalledTools(
        in session: inout SessionState,
        includeWaitingForApproval: Bool = false
    ) {
        for index in session.chatItems.indices {
            guard case .toolCall(var tool) = session.chatItems[index].type else { continue }
            let stalled = tool.status == .running
                || (includeWaitingForApproval && tool.status == .waitingForApproval)
            guard stalled else { continue }
            tool.status = .interrupted
            session.chatItems[index] = ChatHistoryItem(
                id: session.chatItems[index].id,
                type: .toolCall(tool),
                timestamp: session.chatItems[index].timestamp
            )
        }
    }
```

把 Task 1 中 `processOpencodeStop` 里的同款 `for index in session.chatItems.indices { ... }` 换成
`interruptStalledTools(in: &session)`（默认参数，行为不变）。

- [x] **Step 5: 加 opencode quiet 分支**

插入点：`recheckAllSessions()` 里 **`if let pid = session.pid, shouldRemoveWhenProcessExits(session)` 块之后、Claude status-file 块之前**。
（先让「进程已退出 → 移除」优先，再考虑「静默过期 → 置 idle」。）

```swift
            if session.provider == .opencode,
               session.phase.isActive
                || session.phase.isWaitingForApproval
                || session.phase.isWaitingForTerminalApproval {
                let quietDuration = now.timeIntervalSince(session.lastActivity)
                let extended = session.phase == .compacting
                    || session.phase.isWaitingForApproval
                    || session.phase.isWaitingForTerminalApproval
                    || hasRunningTools(in: session)
                let quietLimit = extended
                    ? opencodeExtendedQuietExpirationSeconds
                    : opencodeActiveQuietExpirationSeconds

                if quietDuration > quietLimit {
                    var updatedSession = session
                    writeDebugLogAsync("[opencode-lifecycle] activeQuietExpired session=\(sessionId) quietSeconds=\(Int(quietDuration)) limitSeconds=\(Int(quietLimit)) phase=\(String(describing: session.phase))")
                    updatedSession.phase = .idle
                    updatedSession.completionNotificationAt = nil
                    interruptStalledTools(in: &updatedSession, includeWaitingForApproval: true)
                    updatedSession.toolTracker.inProgress.removeAll()
                    sessions[sessionId] = updatedSession
                    stateChanged = true
                    continue
                }
            }
```

两点说明：

- `.waitingForTerminalApproval` 目前只有 `processCodexPermissionRequested` 会设，opencode 进不去 → 这是纯防御分支。但 `processOpencodeProcessingStarted` 里已经有它的抑制分支，这里保持一致成本为零。
- **审批回收的代价要写进验证清单**：`.waitingForApproval` 600s 后置 `.idle`，审批条会消失，而 opencode 仍阻塞在权限请求上，用户只能回 TUI 处理。这是「不永久卡住」换来的代价，属于有意取舍。

- [x] **Step 6: 运行，确认通过**

```bash
xcodebuild test -project Nook.xcodeproj -scheme Nook -configuration Debug \
  -derivedDataPath build/TestDerivedData -destination 'platform=macOS' \
  -only-testing:NookTests/SessionStoreOpencodeLifecycleTests \
  -only-testing:NookTests/SessionStoreCodexLifecycleTests
```

Expected: 全 PASS（Codex 用例防回归）。

- [x] **Step 7: Commit**

```bash
git add Nook/Services/State/SessionStore.swift NookTests/SessionStoreOpencodeLifecycleTests.swift
git commit -m "fix(opencode): reap active and stuck-approval sessions after a quiet window"
```

> 评审后修复：`cc747c8`（tracker-aware 延长窗口 / 边界与可观测性测试）。

---

## Task 4: 同步注释与文档

**Files:**
- Modify: `Nook/Services/Hooks/OpencodeHookAdapter.swift`（顶部 docstring）
- Modify: `docs/specs/2026-06-17-opencode-v1.17-compatibility-matrix.md`（状态行 + 陷阱 4 正文）
- Modify: `docs/debug/2026-10-23-opencode-lost-idle-stuck-processing.md`（状态行 + 修复方向 A/B + 风险）

- [x] **Step 1: 更新 docstring**

已在 Task 2 完成（`d8e3bfc` / `dd86f51` 已同步 `OpencodeHookAdapter` 顶部 docstring）。

- [x] **Step 2: 更新 spec 状态与陷阱 4 正文**

- 头部：`结束信号兜底 🔴 未修复` → `✅ 已修复（2026-10-23）`
- 核心结论表 `v1.18+` 行：状态改为 `✅ 主体可用；结束信号双路（status=idle + session.idle）+ 静默兜底`
- v1.15.13 / v1.17.x 行追加：`status=idle` 在这些版本会在 tool step 之间触发，新的 idle→`.stop` 路径**不支持 ≤1.17**；它们依赖 `session.idle` + 90s 静默兜底
- 事件表：`session.status` 消费改为 `busy/retry → .processingStarted`、`idle → flush + .stop`；`session.idle` 标为 legacy 冗余（不再是唯一 `.stop` 来源）；新增 `question.rejected` 行
- 决策档案里「`retry` 有意不消费」那条改为已消费，并写清理由（静默兜底会误判）
- 陷阱 4 的「所以正确的冗余是…」段落改为**已实施事实**：
  - `handleSessionStatus(idle)` 在 flush 后无条件产 `.stop`
  - `SessionStore.processOpencodeStop` 用 `wasActive` guard 保证幂等/不覆盖等待态；清理逻辑无条件执行
  - 完成通知用每轮一次闩锁（prompt / `processingStarted` / TUI `.userPrompt` 重置）
  - quiet-expiry：90s（正常）/ 600s（running/queued tool / `.compacting` / `.waitingForApproval` / `.waitingForTerminalApproval`）
  - `.waitingForInput` 不自动过期（已知残留风险，明确写出），且 `.stop` 已不是它的出口
  - `question.rejected` 映射成 `.processingStarted`
  - 明确写出 ≤1.17 不支持：`status=idle` 在旧版会在 tool step 之间触发，不能当轮末信号；旧版依赖 `session.idle` + 90s 静默兜底
  - 删除「修复方案与阈值权衡见上述 debug 文档」这类指向"未实施"的措辞

- [x] **Step 3: 更新 debug 文档**

- 头部：`状态: 🔴 已定位，未修复` → `状态: ✅ 已修复（2026-10-23，commits 5991426…cc747c8）`
- TL;DR 补一段「修复」摘要（双结束信号 + 每轮闩锁 + 静默兜底 + retry / question.rejected）
- 修复方向 A / B 改写为「已实施」小节，写清最终阈值与 guard 语义；新增 C（每轮闩锁）/ D（retry / question.rejected）已实施项，原传输层重试 / reconcile 降为后续可选
- 残留风险段补五条：
  1. 90s 静默窗口对长 TTFT / 非流式 reasoning / 排队中的 turn / `retry-after` header >90s 会误判；下一个事件可恢复，代价是闪烁
  2. 审批 600s 回收会隐藏审批条，而 opencode 仍在阻塞；用户需回 TUI 处理
  3. `.waitingForInput` 无自动过期；`question.replied` / `question.rejected` / `busy` / 新一轮 prompt 全丢时会卡住
  4. ≤1.17 的 `status=idle` 在 tool step 之间触发，结束信号路径不支持；旧版靠 `session.idle` + 90s 静默兜底，可能闪烁或按步通知
  5. 最后一条 `.stop` 之后到达的 chat item 会把 phase 重新拉回 `.processing`，直到下一个静默窗口

- [x] **Step 4: 全量测试**

```bash
xcodebuild test -project Nook.xcodeproj -scheme Nook -configuration Debug \
  -derivedDataPath build/TestDerivedData -destination 'platform=macOS'
```

Expected: 全绿。

- [x] **Step 5: Commit**

```bash
git add Nook/Services/Hooks/OpencodeHookAdapter.swift \
  docs/specs/2026-06-17-opencode-v1.17-compatibility-matrix.md \
  docs/debug/2026-10-23-opencode-lost-idle-stuck-processing.md
git commit -m "docs(opencode): record session-end recovery as fixed"
```

---

## Task 5: plugin `send()` 失败日志（建议项，非阻塞）

**Files:**
- Modify: `Nook/Resources/opencode-plugin/index.js`

- [x] **Step 1: 加节流版的失败日志**

**不能直接 `logDebug` 每一条失败。** 用户没开 Nook 时 `send` 失败是常态，而 `message.part.delta`
一分钟几十条；`logDebug` 走 `fs.appendFileSync`（同步写）且文件永不轮转 —— 那等于给不装 Nook 的用户
加了一条同步 IO 热路径。所以按 type 节流，并且完全跳过 `message.part.delta`。

在 `logDebug` 定义之后新增：

```js
/// Send-failure logging is throttled: when Nook isn't running every send fails,
/// and `message.part.delta` alone fires dozens of times a minute. logDebug uses
/// appendFileSync, so un-throttled logging would mean one synchronous disk write
/// per token. Delta is skipped entirely; other types log at most once per 5s.
const SEND_FAILURE_LOG_INTERVAL_MS = 5000;
const sendFailureLoggedAt = new Map();
let sendFailureTotal = 0;

function logSendFailure(payload, err) {
  sendFailureTotal += 1;
  const type = payload?.type ?? "-";
  if (type === "message.part.delta") return;
  const now = Date.now();
  if (now - (sendFailureLoggedAt.get(type) ?? 0) < SEND_FAILURE_LOG_INTERVAL_MS) return;
  sendFailureLoggedAt.set(type, now);
  const sessionId = payload?.properties?.sessionID ?? "-";
  logDebug(
    `send failed type=${type} session=${sessionId} total=${sendFailureTotal}: ${err.message}`,
  );
}
```

`send()` 的 error 分支改为：

```js
      socket.on("error", (err) => {
        logSendFailure(payload, err);
        resolve();
      });
```

`close` 分支保持静默（正常写完也会 close，不能当失败）。

`total` 统计的是本进程累计失败次数（含被跳过的 delta），所以「日志里只有 1 条但 total=137」
正是「Nook 没开、事件全丢」的指纹——这正是今天事故里缺的那个可判读信号。

- [ ] **Step 2: 让 opencode 真正加载新插件**（用户手动执行）

三步缺一不可，只做前两步验证到的是**旧插件**：

1. 关掉所有 opencode 实例（插件在进程启动时加载，热改文件无效）。
2. 启动一次新编译的 Nook，让 `OpencodeHookInstaller.installIfNeeded()` 把改过的 `index.js`
   写进 `~/.config/opencode/plugins/nook/`（按内容比对，不需要升版本号）。确认落盘：
   ```bash
   grep -c "logSendFailure" ~/.config/opencode/plugins/nook/index.js   # 期望 >= 1
   ```
3. 重新启动 opencode。

- [ ] **Step 3: 手动验证**（用户手动执行）

关掉 Nook（或改 `SOCKET_PATH` 临时指向不存在的路径）→ 在 opencode 里跑一轮（要求带一次工具调用，
确保 delta 也在刷）→ 期望：

```bash
grep "send failed" /tmp/nook-plugin-debug.log | tail -5
ls -l /tmp/nook-plugin-debug.log   # 不应因本轮验证暴涨到 MB 级
```

判读：`message.part.delta` 不出现在日志里；其他 type 同一 5s 窗口内最多一条；
`total=` 单调递增。

- [x] **Step 4: Commit**

```bash
git add Nook/Resources/opencode-plugin/index.js
git commit -m "chore(opencode-plugin): log socket send failures (throttled)"
```

> 安装器按 `index.js` 内容比对决定是否重装（`OpencodeHookInstaller.isUpToDate`），不需要手动升版本号。
> `PLUGIN_VERSION`(1.5.2) 与 `package.json`(1.5.1) 的既存不一致不在本计划内处理。

---

## 风险与回滚

- **`status=idle` 到底每轮一次还是每步一次**：v1.19 源码是每轮一次——`status.set(idle)` 只由 `run-state.ts` 的 `onIdle` / `cancel` 与 `processor.ts` 的 halt/error 触发，而 `halt` 只在 `SessionRetry.policy` 耗尽后执行（`status=idle` 不会在 retry 中途发出）。更强的旁证：`adaptSubagentEvent` 只在 `session.status=idle` 时 `finalizeSubagent`，若每步都发，子会话早被反复 finalize 了。v1.15/1.17 的旧注释声称「tool 之间也会发」——若旧版本复测发现闪烁，回滚 Task 2（保留 Task 1/3 仍可兜底）。
- **双通知**：主防线是每轮一次闩锁（`opencodeCompletionNotifiedSessions`）——它不依赖 phase，能扛住 chat item 穿插把 phase 拉回 `.processing`；`wasActive` 只负责等待态收尾 / 非 active 轮次不进通知。两者必须与 Task 2 同时上线。
- **≤1.17 兼容性**：opencode ≤1.17 的 `status=idle` 每步触发；本次不兼容该路径（文档已标注），旧版可能每步闪 idle / 通知。
- **等待态清理**：Task 1 清理逻辑无条件执行，会把等待中的 running tool 标 `.interrupted`；若复测发现问题面板异常，改为「仅 active 时清理」。
- **长任务误杀**：opencode 无心跳，600s 仍可能短于真实长任务；后果是提前 `.idle`，不会丢会话。
- **retry 残留窗口**：默认退避上限 30s < 90s，retry 分支足以覆盖；但若服务端用 `retry-after` header 指定超过 90s 的单次等待，仍会闪一次 idle，随后 busy/retry 拉回。
- **审批条会消失**：`.waitingForApproval` 600s 后被回收，Nook UI 回到 idle，而 opencode 仍在阻塞——用户需回 TUI 处理。这是「不永久卡住」的代价，已写进验证清单。
- **`.waitingForInput` 无兜底**：出口是 `question.replied` / `question.rejected`（已消费 → `.processingStarted`）/ `busy` / 新一轮 prompt，其中只有 `busy` 不依赖用户动作。全丢则卡到进程退出。
- **无通知的 stop**：Nook 中途启动的会话不再补发完成通知（改进，PR 描述写明）。

---

## 验证（真实环境）

1. 设置里开 Debug log，跑一轮 opencode（含工具调用），记录 `SID`。
2. 按 session 分段统计（不要只比总数：`status=idle` 与 `session.idle` 按构造 1:1，相等没有信息量）。
   日志里的源标识是四句不同的 notice（busy / retry / idle / legacy stop），按源分别 grep：

```bash
SID=<opencode session id>
grep "session=$SID" /tmp/nook-debug.log | grep -c "→ idle (turn end)"                 # 每轮恰好 1
grep "session=$SID" /tmp/nook-debug.log | grep -c "→ stop (legacy session.idle)"      # 0 或 1（丢了就是 0，这正是修复目标）
grep "session=$SID" /tmp/nook-debug.log | grep -c "session.status=busy"               # 可远多于 idle（每 step 一次）
grep "session=$SID" /tmp/nook-debug.log | grep -c "session.status=retry"              # 无重试则 0
```

判读：`→ idle (turn end)` 每轮 1 次；`→ stop (legacy session.idle)` 为 0 说明 legacy 事件丢了、由
`status=idle` 单独救回（修复目标达成）；为 1 说明两条都到、`wasActive` guard 去重生效。
3. Nook UI：会话结束后不再显示 working；完成通知只响一次；working 不在 step 之间闪烁。
4. 重启 Nook（打断 socket）后再跑一轮，验证只收到 `status=idle` 也能结束。
5. 等待态三项（人工）：
   - 触发一次 AskUserQuestion，等 2 分钟 → 问题面板仍在，phase 不是 idle。
   - 制造一次审批挂起后不处理，等 10 分钟 → 审批条消失、会话回到 idle（**预期行为**，不是 bug）。
   - 制造一次 provider 重试（断网/限流）→ 重试期间 UI 保持 working，不闪 idle。
