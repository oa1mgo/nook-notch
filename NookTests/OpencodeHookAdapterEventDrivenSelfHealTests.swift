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
}
