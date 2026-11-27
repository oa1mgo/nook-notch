import XCTest
@testable import Nook

@MainActor
final class SessionRuntimeTests: XCTestCase {
    func testStartAndStopAreIdempotent() async {
        let statusChecks = RuntimeStatusCheckRecorder()
        var starts = 0
        var stops = 0
        weak var registeredDelegate: SessionRuntime?
        let runtime = SessionRuntime(lifecycle: .init(
            startIngress: { owner in
                starts += 1
                registeredDelegate = owner
            },
            stopIngress: {
                stops += 1
                registeredDelegate = nil
            },
            setStatusChecksRunning: { await statusChecks.setRunning($0) }
        ))

        runtime.stop()
        runtime.start()
        runtime.start()
        XCTAssertTrue(runtime.isRunning)
        XCTAssertTrue(registeredDelegate === runtime)
        runtime.stop()
        runtime.stop()
        await runtime.waitForStatusCheckTransition()

        XCTAssertFalse(runtime.isRunning)
        XCTAssertNil(registeredDelegate)
        XCTAssertEqual(starts, 1)
        XCTAssertEqual(stops, 1)
        let transitions = await statusChecks.transitions
        XCTAssertEqual(transitions, [true, false])
    }

    func testImmediateStopAndRestartKeepAsynchronousStatusChecksInOrder() async {
        let statusChecks = RuntimeStatusCheckRecorder()
        let runtime = SessionRuntime(lifecycle: .init(
            startIngress: { _ in },
            stopIngress: {},
            setStatusChecksRunning: { await statusChecks.setRunning($0) }
        ))

        // No suspension between calls: none of their async tasks can begin on
        // the MainActor before the final desired state has been submitted.
        runtime.start()
        runtime.stop()
        runtime.start()
        runtime.stop()
        await runtime.waitForStatusCheckTransition()

        let transitions = await statusChecks.transitions
        XCTAssertEqual(transitions, [true, false, true, false])
    }

    func testStopWaitsForAnInFlightStatusCheckStart() async {
        let didBeginStart = expectation(description: "status start suspended")
        let gate = RuntimeStartGate()
        let statusChecks = RuntimeStatusCheckRecorder()
        let runtime = SessionRuntime(lifecycle: .init(
            startIngress: { _ in },
            stopIngress: {},
            setStatusChecksRunning: { running in
                if running {
                    didBeginStart.fulfill()
                    await gate.wait()
                }
                await statusChecks.setRunning(running)
            }
        ))

        runtime.start()
        await fulfillment(of: [didBeginStart], timeout: 2)
        runtime.stop()
        await gate.open()
        await runtime.waitForStatusCheckTransition()

        let transitions = await statusChecks.transitions
        XCTAssertEqual(transitions, [true, false])
    }

    func testRebuildingUIProjectionDoesNotReplaceRuntimeDelegate() async {
        let statusChecks = RuntimeStatusCheckRecorder()
        let runtime = SessionRuntime(lifecycle: .init(
            startIngress: { InterruptWatcherManager.shared.delegate = $0 },
            stopIngress: { InterruptWatcherManager.shared.delegate = nil },
            setStatusChecksRunning: { await statusChecks.setRunning($0) }
        ))
        runtime.start()
        do {
            let firstWindowMonitor = SessionMonitor()
            let secondWindowMonitor = SessionMonitor()
            XCTAssertTrue(InterruptWatcherManager.shared.delegate === runtime)
            withExtendedLifetime((firstWindowMonitor, secondWindowMonitor)) {}
        }
        XCTAssertTrue(InterruptWatcherManager.shared.delegate === runtime)
        runtime.stop()
        await runtime.waitForStatusCheckTransition()
        XCTAssertNil(InterruptWatcherManager.shared.delegate)
    }
}

private actor RuntimeStatusCheckRecorder {
    private(set) var transitions: [Bool] = []

    func setRunning(_ running: Bool) {
        transitions.append(running)
    }
}

private actor RuntimeStartGate {
    private var isOpen = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func open() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}
