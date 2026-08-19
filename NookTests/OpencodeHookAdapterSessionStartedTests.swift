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
            if case .sessionStart(let sid, let cwd) = event {
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
            if case .sessionStart(let sid, _) = event { return sid == sessionId }
            return false
        }, "session.started must bypass recentlyStopped and still emit .sessionStart")
    }
}
