import Darwin
import XCTest
@testable import Nook

@MainActor
final class HookSocketServerLifecycleTests: XCTestCase {
    func testImmediateStopFinishesQueuedStartAndUnlinksItsSocket() async {
        let path = "/tmp/nook-test-\(UUID().uuidString).sock"
        let server = HookSocketServer(socketPath: path)
        defer { server.stop() }

        for _ in 0..<10 {
            server.start(onEvent: { _ in })
            server.stop()
            let isListening = await server.isListeningForTesting()
            XCTAssertFalse(isListening)
            XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        }
    }

    func testRestartKeepsNewListenerAndReplacesOldCallbacks() async throws {
        let path = "/tmp/nook-test-\(UUID().uuidString).sock"
        let server = HookSocketServer(socketPath: path)
        defer { server.stop() }
        let received = expectation(description: "restarted listener receives event")

        server.start(onEvent: { _ in XCTFail("Stopped listener must not receive events") })
        server.stop()
        server.start(onEvent: { event in
            XCTAssertEqual(event.sessionId, "runtime-lifecycle-test")
            received.fulfill()
        })
        let isListening = await server.isListeningForTesting()
        XCTAssertTrue(isListening)
        try sendHook(to: path)
        await fulfillment(of: [received], timeout: 2)
    }

    private func sendHook(to path: String) throws {
        let client = socket(AF_UNIX, SOCK_STREAM, 0)
        guard client >= 0 else { throw POSIXError(.EIO) }
        defer { close(client) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        path.withCString { source in
            withUnsafeMutablePointer(to: &address.sun_path) { destination in
                _ = strcpy(UnsafeMutableRawPointer(destination).assumingMemoryBound(to: CChar.self), source)
            }
        }
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(client, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else { throw POSIXError(.ECONNREFUSED) }
        let payload = Data(#"{"session_id":"runtime-lifecycle-test","cwd":"/tmp","event":"Stop","status":"idle"}"#.utf8)
        let written = payload.withUnsafeBytes { write(client, $0.baseAddress, $0.count) }
        XCTAssertEqual(written, payload.count)
        shutdown(client, SHUT_WR)
    }
}
