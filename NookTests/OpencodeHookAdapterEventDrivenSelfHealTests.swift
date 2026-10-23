import XCTest
@testable import Nook

@MainActor
final class OpencodeHookAdapterEventDrivenSelfHealTests: XCTestCase {
    /// A business event (here `permission.asked`) arriving for a session Nook
    /// has never registered must self-heal: register the session from the
    /// plugin-injected `cwd` and emit a first-sighting `.sessionStart` *before*
    /// the business event, so the permission popup is never dropped as
    /// "pre-registration" (the race seen right after a Nook/opencode restart
    /// where the plugin's `session.started` probe was still pending).
    func testPermissionAskedSelfHealsUnregisteredSession() {
        let sessionId = "ses_heal_\(UUID().uuidString)"
        let envelope = OpencodeHookEnvelope(
            origin: "opencode",
            type: "permission.asked",
            properties: [
                "sessionID": AnyCodable(sessionId),
                "cwd": AnyCodable("/tmp/test-project"),
                "pid": AnyCodable(12345),
                "id": AnyCodable("per_abc"),
                "permission": AnyCodable("bash"),
            ]
        )
        let events = OpencodeHookAdapter.adapt(envelope)

        // First event must be the self-heal .sessionStart.
        guard let first = events.first,
              case .sessionStart(let sid, let cwd, _, _) = first,
              sid == sessionId, cwd == "/tmp/test-project" else {
            return XCTFail("permission.asked should self-heal with a leading .sessionStart, got \(events)")
        }
        // The permission popup must also be present.
        XCTAssertTrue(events.contains { event in
            if case .permissionAsked(let psid, _, let reqId, _, _, _, _, _) = event {
                return psid == sessionId && reqId == "per_abc"
            }
            return false
        }, "permission.asked must still be emitted after self-heal, got \(events)")
    }

    /// Without an injected `cwd` the business event cannot self-heal, so the
    /// session stays unregistered and the event is dropped (no .sessionStart,
    /// no business event emitted) rather than creating a phantom with empty cwd.
    func testBusinessEventWithoutCwdDoesNotSelfHeal() {
        let sessionId = "ses_no_cwd_\(UUID().uuidString)"
        let envelope = OpencodeHookEnvelope(
            origin: "opencode",
            type: "permission.asked",
            properties: [
                "sessionID": AnyCodable(sessionId),
                "id": AnyCodable("per_xyz"),
                "permission": AnyCodable("bash"),
            ]
        )
        let events = OpencodeHookAdapter.adapt(envelope)
        XCTAssertFalse(events.contains { event in
            if case .sessionStart(let sid, _, _, _) = event { return sid == sessionId }
            return false
        }, "permission.asked without cwd must NOT self-heal, got \(events)")
    }

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
}
