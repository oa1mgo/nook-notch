import Darwin
import XCTest
@testable import Nook

@MainActor
final class HookSocketServerBatchTests: XCTestCase {
    func testProviderEnvelopesDeliverContentAndLifecycleInOneCallback() async throws {
        let path = "/tmp/nook-batch-\(UUID().uuidString).sock"
        let server = HookSocketServer(socketPath: path)
        let openSession = "socket-open-\(UUID().uuidString)"
        let questionId = "question-\(UUID().uuidString)"
        let messageId = "message-\(UUID().uuidString)"
        defer {
            server.stop()
            finishFixture(openSession, toolId: questionId, messageId: messageId)
        }
        let openReceived = expectation(description: "complete OpenCode batch")
        let cursorReceived = expectation(description: "complete Cursor batch")
        server.start(callbacks: HookSocketCallbacks(
            onEvent: { _ in XCTFail("Provider envelope must not fall through to Claude") },
            onOpencodeBatch: { batch in
                XCTAssertEqual(batch.chatItemUpdates.count, 1)
                XCTAssertEqual(batch.chatItemUpdates.first?.sessionId, openSession)
                XCTAssertTrue(batch.passthroughEvents.contains {
                    if case .waitingForUserInput(let id, _, let tool, _, _) = $0 {
                        return id == openSession && tool == questionId
                    }
                    return false
                }, "The defensive question lifecycle must accompany its tool content")
                openReceived.fulfill()
            },
            onCursorBatch: { batch in
                XCTAssertEqual(batch.chatItemUpdates.count, 1)
                XCTAssertEqual(batch.chatItemUpdates.first?.sessionId, "socket-cursor")
                guard case .processingStarted(let id, _) = batch.passthroughEvents.first else {
                    return XCTFail("Content and processingStarted must arrive in the same callback")
                }
                XCTAssertEqual(id, "socket-cursor")
                cursorReceived.fulfill()
            }
        ))
        let listening = await server.isListeningForTesting()
        XCTAssertTrue(listening)
        try send([
            "origin": "opencode", "type": "message.part.updated",
            "properties": [
                "sessionID": openSession, "cwd": "/tmp/ingress-fixture",
                "part": ["type": "tool", "tool": "question", "callID": questionId, "messageID": messageId,
                         "state": ["status": "running", "input": ["questions": []]]]
            ]
        ], to: path)
        try send([
            "origin": "cursor", "hook_event_name": "preToolUse", "conversation_id": "socket-cursor",
            "cwd": "/tmp/ingress-fixture", "tool_name": "Bash", "tool_use_id": "socket-tool",
            "tool_input": ["command": "echo fixture"]
        ], to: path)
        await fulfillment(of: [openReceived, cursorReceived], timeout: 2)
    }

    private func finishFixture(_ sessionId: String, toolId: String, messageId: String) {
        let adapter = OpencodeChatItemAdapter.shared
        _ = adapter.adaptAndConvert(OpencodeHookEnvelope(origin: "opencode", type: "message.part.updated", properties: [
            "sessionID": AnyCodable(sessionId), "cwd": AnyCodable("/tmp/ingress-fixture"),
            "part": AnyCodable(["type": "tool", "tool": "question", "callID": toolId, "messageID": messageId,
                                "state": ["status": "completed", "output": "fixture complete"]])
        ]))
        _ = adapter.adaptAndConvert(OpencodeHookEnvelope(origin: "opencode", type: "session.idle", properties: [
            "sessionID": AnyCodable(sessionId)
        ]))
    }

    private func send(_ object: [String: Any], to path: String) throws {
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
        let payload = try JSONSerialization.data(withJSONObject: object)
        let written = payload.withUnsafeBytes { write(client, $0.baseAddress, $0.count) }
        XCTAssertEqual(written, payload.count)
        shutdown(client, SHUT_WR)
    }
}
