import XCTest
@testable import Nook

@MainActor
final class OpencodeHookAdapterSessionStartedTests: XCTestCase {
    /// A `session.started` event (plugin reports the current session after a
    /// resume where opencode never emitted session.created/updated) must
    /// trigger a first-sighting `.sessionStart` so Nook can self-heal the
    /// missing registration — instead of dropping every subsequent event as
    /// "pre-registration".
    func testSessionStartedTriggersFirstSighting() {
        let sessionId = "ses_started_\(UUID().uuidString)"
        let envelope = OpencodeHookEnvelope(
            origin: "opencode",
            type: "session.started",
            properties: [
                "sessionID": AnyCodable(sessionId),
                "cwd": AnyCodable("/tmp/test-project"),
                "pid": AnyCodable(12345),
            ]
        )
        let events = OpencodeHookAdapter.adapt(envelope)
        guard events.contains(where: { event in
            if case .sessionStart(let sid, let cwd, _, _) = event {
                return sid == sessionId && cwd == "/tmp/test-project"
            }
            return false
        }) else {
            return XCTFail("session.started should emit a first-sighting .sessionStart, got \(events)")
        }
    }

    /// `session.started` is an explicit "this session is live now" signal, so
    /// it must bypass the `recentlyStopped` guard that suppresses late
    /// session.updated events racing with session.idle.
    func testSessionStartedBypassesRecentlyStopped() {
        let sessionId = "ses_started_stopped_\(UUID().uuidString)"
        // Simulate a prior stop that would suppress a later session.updated.
        let idle = OpencodeHookEnvelope(
            origin: "opencode",
            type: "session.idle",
            properties: ["sessionID": AnyCodable(sessionId)]
        )
        _ = OpencodeHookAdapter.adapt(idle)

        let start = OpencodeHookEnvelope(
            origin: "opencode",
            type: "session.started",
            properties: [
                "sessionID": AnyCodable(sessionId),
                "cwd": AnyCodable("/tmp/test-project"),
                "pid": AnyCodable(12345),
            ]
        )
        let events = OpencodeHookAdapter.adapt(start)
        XCTAssertTrue(events.contains { event in
            if case .sessionStart(let sid, _, _, _) = event { return sid == sessionId }
            return false
        }, "session.started must bypass recentlyStopped and still emit .sessionStart")
    }

    /// `session.started` from the plugin's session.list() fallback must be
    /// marked provisional: the id was guessed from storage ("most recently
    /// updated"), not confirmed as the session opencode is actually using.
    /// Nook uses this flag to drop the guessed entry when the same pid later
    /// creates a real session (`--port` connect-then-new-session case).
    func testSessionStartedWithListFallbackSourceIsProvisional() {
        let sessionId = "ses_provisional_\(UUID().uuidString)"
        let envelope = OpencodeHookEnvelope(
            origin: "opencode",
            type: "session.started",
            properties: [
                "sessionID": AnyCodable(sessionId),
                "cwd": AnyCodable("/tmp/test-project"),
                "pid": AnyCodable(12345),
                "source": AnyCodable("list-fallback"),
            ]
        )
        let events = OpencodeHookAdapter.adapt(envelope)
        guard let start = events.first(where: {
            if case .sessionStart = $0 { return true }
            return false
        }) else {
            return XCTFail("expected .sessionStart, got \(events)")
        }
        guard case .sessionStart(_, _, let provisional, let pid) = start else {
            return XCTFail("unexpected event \(start)")
        }
        XCTAssertTrue(provisional, "list-fallback session.started must be provisional")
        XCTAssertEqual(pid, 12345)
    }

    /// `session.started` with a real session id from status() must NOT be
    /// provisional — resume self-heal relies on it staying permanent.
    func testSessionStartedWithoutSourceIsNotProvisional() {
        let sessionId = "ses_confirmed_\(UUID().uuidString)"
        let envelope = OpencodeHookEnvelope(
            origin: "opencode",
            type: "session.started",
            properties: [
                "sessionID": AnyCodable(sessionId),
                "cwd": AnyCodable("/tmp/test-project"),
                "pid": AnyCodable(12345),
            ]
        )
        let events = OpencodeHookAdapter.adapt(envelope)
        guard let start = events.first(where: {
            if case .sessionStart = $0 { return true }
            return false
        }) else {
            return XCTFail("expected .sessionStart, got \(events)")
        }
        guard case .sessionStart(_, _, let provisional, _) = start else {
            return XCTFail("unexpected event \(start)")
        }
        XCTAssertFalse(provisional, "session.started from status() must not be provisional")
    }

    /// A real `session.created` is authoritative — never provisional, and it
    /// must carry the plugin-injected pid so SessionStore can match it
    /// against provisional entries from the same instance.
    func testSessionCreatedIsNotProvisionalAndCarriesPid() {
        let sessionId = "ses_created_\(UUID().uuidString)"
        let envelope = OpencodeHookEnvelope(
            origin: "opencode",
            type: "session.created",
            properties: [
                "sessionID": AnyCodable(sessionId),
                "info": AnyCodable(["directory": "/tmp/test-project"]),
                "pid": AnyCodable(4242),
            ]
        )
        let events = OpencodeHookAdapter.adapt(envelope)
        guard let start = events.first(where: {
            if case .sessionStart = $0 { return true }
            return false
        }) else {
            return XCTFail("expected .sessionStart, got \(events)")
        }
        guard case .sessionStart(_, _, let provisional, let pid) = start else {
            return XCTFail("unexpected event \(start)")
        }
        XCTAssertFalse(provisional, "session.created must not be provisional")
        XCTAssertEqual(pid, 4242)
    }
}
