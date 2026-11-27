import Darwin
import XCTest
@testable import Nook

@MainActor
final class HookSocketPermissionCleanupTests: XCTestCase {
    func testStopClosesEveryPendingPermissionForItsSession() async throws {
        try await verifyCleanup(event: "Stop", closesSecond: true)
    }

    func testPostToolUseClosesOnlyItsMatchingPermission() async throws {
        try await verifyCleanup(event: "PostToolUse", closesSecond: false)
    }

    private func verifyCleanup(event: String, closesSecond: Bool) async throws {
        let path = "/tmp/nook-perm-\(UUID().uuidString).sock"
        let server = HookSocketServer(socketPath: path)
        defer { server.stop() }
        let pending = expectation(description: "two permission sockets retained")
        pending.expectedFulfillmentCount = 2
        let finished = expectation(description: "cleanup event delivered")
        server.start(onEvent: { received in
            if received.event == "PermissionRequest" { pending.fulfill() }
            if received.event == event { finished.fulfill() }
        })
        let listening = await server.isListeningForTesting()
        XCTAssertTrue(listening)
        let first = try sendHook(event: "PermissionRequest", status: "waiting_for_approval", toolId: "first", to: path)
        defer { close(first) }
        let second = try sendHook(event: "PermissionRequest", status: "waiting_for_approval", toolId: "second", to: path)
        defer { close(second) }
        await fulfillment(of: [pending], timeout: 2)
        XCTAssertTrue(server.hasPendingPermission(sessionId: "permission-fixture"))

        let notification = try sendHook(event: event, status: "idle", toolId: "first", to: path)
        close(notification)
        await fulfillment(of: [finished], timeout: 2)
        let firstClosed = await Task.detached { Self.isClosed(first, timeoutMs: 1000) }.value
        XCTAssertTrue(firstClosed, "The completed permission connection must close without a user response")
        if closesSecond {
            let secondClosed = await Task.detached { Self.isClosed(second, timeoutMs: 1000) }.value
            XCTAssertTrue(secondClosed)
            XCTAssertFalse(server.hasPendingPermission(sessionId: "permission-fixture"))
        } else {
            XCTAssertFalse(Self.isClosed(second, timeoutMs: 0), "A different pending tool must stay connected")
            XCTAssertTrue(server.hasPendingPermission(sessionId: "permission-fixture"))
        }
    }

    /// Wait for actual socket EOF, with a bounded poll rather than a timing sleep.
    private nonisolated static func isClosed(_ client: Int32, timeoutMs: Int32) -> Bool {
        var descriptor = pollfd(fd: client, events: Int16(POLLIN | POLLHUP), revents: 0)
        guard poll(&descriptor, 1, timeoutMs) > 0 else { return false }
        var byte: UInt8 = 0
        return recv(client, &byte, 1, MSG_DONTWAIT) == 0
    }

    /// Leave the read half open, exactly as a hook waiting for permission does.
    private func sendHook(event: String, status: String, toolId: String, to path: String) throws -> Int32 {
        let client = socket(AF_UNIX, SOCK_STREAM, 0)
        guard client >= 0 else { throw POSIXError(.EIO) }
        do {
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
            let payload = try JSONSerialization.data(withJSONObject: [
                "session_id": "permission-fixture", "cwd": "/tmp", "event": event,
                "status": status, "tool": "Bash", "tool_use_id": toolId
            ])
            let written = payload.withUnsafeBytes { write(client, $0.baseAddress, $0.count) }
            guard written == payload.count else { throw POSIXError(.EIO) }
            shutdown(client, SHUT_WR)
            return client
        } catch {
            close(client)
            throw error
        }
    }
}
