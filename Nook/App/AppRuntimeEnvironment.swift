import Foundation

/// Hosted XCTest processes load the application executable but must not start
/// its real services. Environment markers cover early launch before XCTestCase
/// is loaded; the class check also supports runners without those markers.
enum AppRuntimeEnvironment {
    static func isXCTestHost(
        environment: [String: String] = Foundation.ProcessInfo.processInfo.environment,
        testCaseClassLoaded: Bool = NSClassFromString("XCTestCase") != nil
    ) -> Bool {
        testCaseClassLoaded || [
            "XCTestConfigurationFilePath",
            "XCTestBundlePath",
            "XCTestSessionIdentifier",
        ].contains { key in
            guard let value = environment[key] else { return false }
            return !value.isEmpty
        }
    }
}
