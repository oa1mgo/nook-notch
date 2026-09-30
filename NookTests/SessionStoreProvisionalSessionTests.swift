import XCTest
@testable import Nook

/// Provisional opencode sessions: `session.started` from the plugin's
/// session.list() fallback guesses the "most recently updated" session id.
/// In `--port` connect mode the TUI often creates a NEW session instead of
/// resuming the guessed one, which used to leave a phantom Idle entry in the
/// session list. A provisional entry is removed when the same pid starts a
/// different session and the provisional one never saw any activity.
@MainActor
final class SessionStoreProvisionalSessionTests: XCTestCase {
    private let store = SessionStore.shared

    /// `--port` connect: plugin guesses session P (provisional), user then
    /// sends a message and opencode creates real session N on the same pid.
    /// P must be removed so only N shows in the list.
    func testProvisionalSessionRemovedWhenSamePidStartsNewSession() async {
        await store.resetForTesting()

        await store.process(.opencodeSessionStarted(sessionId: "P", cwd: "/tmp/proj", provisional: true, pid: 100))
        let before = await store.session(for: "P")
        XCTAssertNotNil(before, "provisional session should register first")

        await store.process(.opencodeSessionStarted(sessionId: "N", cwd: "/tmp/proj", provisional: false, pid: 100))

        let afterP = await store.session(for: "P")
        XCTAssertNil(afterP, "inactive provisional session must be removed when same pid starts a new session")
        let afterN = await store.session(for: "N")
        XCTAssertNotNil(afterN, "real session must survive")
    }

    /// Resume mode: no new session.created arrives — the provisional entry
    /// IS the live session and must be kept.
    func testProvisionalSessionKeptWhenNoNewSessionAppears() async {
        await store.resetForTesting()

        await store.process(.opencodeSessionStarted(sessionId: "P", cwd: "/tmp/proj", provisional: true, pid: 100))

        let p = await store.session(for: "P")
        XCTAssertNotNil(p, "provisional session must be kept in resume mode")
    }

    /// A different opencode instance (pid) creating a session must NOT
    /// remove another instance's provisional entry.
    func testProvisionalSessionKeptWhenNewSessionHasDifferentPid() async {
        await store.resetForTesting()

        await store.process(.opencodeSessionStarted(sessionId: "P", cwd: "/tmp/proj", provisional: true, pid: 100))
        await store.process(.opencodeSessionStarted(sessionId: "N", cwd: "/tmp/other", provisional: false, pid: 200))

        let p = await store.session(for: "P")
        XCTAssertNotNil(p, "provisional session of another pid must be kept")
    }

    /// If the provisional session already saw user/assistant activity it is
    /// real — a later session.created on the same pid must not remove it.
    func testProvisionalSessionKeptWhenItHasChatActivity() async {
        await store.resetForTesting()

        await store.process(.opencodeSessionStarted(sessionId: "P", cwd: "/tmp/proj", provisional: true, pid: 100))
        await store.process(.opencodePromptSubmitted(sessionId: "P", cwd: "/tmp/proj", prompt: "hello"))

        await store.process(.opencodeSessionStarted(sessionId: "N", cwd: "/tmp/proj", provisional: false, pid: 100))

        let p = await store.session(for: "P")
        XCTAssertNotNil(p, "provisional session with chat activity must be kept")
    }

    /// Non-provisional sessions are never garbage-collected by this path.
    func testRegularSessionNotRemovedWhenSamePidStartsAnotherSession() async {
        await store.resetForTesting()

        await store.process(.opencodeSessionStarted(sessionId: "A", cwd: "/tmp/proj", provisional: false, pid: 100))
        await store.process(.opencodeSessionStarted(sessionId: "B", cwd: "/tmp/proj", provisional: false, pid: 100))

        let a = await store.session(for: "A")
        XCTAssertNotNil(a, "regular sessions must not be removed")
        let b = await store.session(for: "B")
        XCTAssertNotNil(b)
    }

    /// Conservative: a new session with unknown pid must not remove anything.
    func testProvisionalSessionKeptWhenNewSessionPidIsNil() async {
        await store.resetForTesting()

        await store.process(.opencodeSessionStarted(sessionId: "P", cwd: "/tmp/proj", provisional: true, pid: 100))
        await store.process(.opencodeSessionStarted(sessionId: "N", cwd: "/tmp/proj", provisional: false, pid: nil))

        let p = await store.session(for: "P")
        XCTAssertNotNil(p, "unknown pid must not trigger provisional cleanup")
    }
}
