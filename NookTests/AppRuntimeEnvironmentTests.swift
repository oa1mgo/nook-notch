import AppKit
import XCTest
@testable import Nook

@MainActor
final class AppRuntimeEnvironmentTests: XCTestCase {
    func testRegularLaunchDoesNotLookLikeTestHost() {
        XCTAssertFalse(AppRuntimeEnvironment.isXCTestHost(
            environment: ["PATH": "/usr/bin", "XCTestConfigurationFilePath": ""],
            testCaseClassLoaded: false
        ))
    }

    func testEarlyLaunchRecognizesEachXCTestMarker() {
        for key in ["XCTestConfigurationFilePath", "XCTestBundlePath", "XCTestSessionIdentifier"] {
            XCTAssertTrue(AppRuntimeEnvironment.isXCTestHost(
                environment: [key: "test-runner-value"],
                testCaseClassLoaded: false
            ), key)
        }
    }

    func testLoadedXCTestClassIsFallbackWithoutEnvironmentMarkers() {
        XCTAssertTrue(AppRuntimeEnvironment.isXCTestHost(
            environment: [:],
            testCaseClassLoaded: true
        ))
    }

    func testHostedApplicationSkipsWindowBootstrapAndTerminationEffects() async throws {
        XCTAssertTrue(AppRuntimeEnvironment.isXCTestHost())
        let delegate = try XCTUnwrap(AppDelegate.shared)
        XCTAssertNil(delegate.windowController)
        // Calling the host's termination hook must take the same inert path.
        delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        XCTAssertNil(delegate.windowController)
    }
}
