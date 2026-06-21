import XCTest
@testable import Nook

final class OpencodeChatItemAdapterTests: XCTestCase {
    func testEnvelopeStreamProducesPromptThinkingToolAndPassthroughEvents() {
        let sessionId = "opencode-session-\(UUID().uuidString)"
        let adapter = OpencodeChatItemAdapter.shared
        adapter.clearSession(sessionId)

        let sessionStart = adapter.adaptAndConvert(envelope(
            "session.updated",
            sessionId: sessionId,
            properties: ["info": ["directory": "/tmp/project"]]
        ))
        XCTAssertEqual(sessionStart.chatItemUpdates.count, 0)
        XCTAssertEqual(sessionStart.passthroughEvents.count, 1)
        guard case .sessionStart(let startedSession, let cwd) = sessionStart.passthroughEvents[0] else {
            return XCTFail("Expected sessionStart passthrough")
        }
        XCTAssertEqual(startedSession, sessionId)
        XCTAssertEqual(cwd, "/tmp/project")

        _ = adapter.adaptAndConvert(envelope(
            "message.updated",
            sessionId: sessionId,
            properties: ["info": ["id": "msg-user", "role": "user"]]
        ))
        let prompt = adapter.adaptAndConvert(envelope(
            "message.part.updated",
            sessionId: sessionId,
            properties: [
                "part": [
                    "type": "text",
                    "messageID": "msg-user",
                    "text": "build this"
                ]
            ]
        ))
        XCTAssertEqual(prompt.passthroughEvents.count, 0)
        XCTAssertEqual(prompt.chatItemUpdates.count, 1)
        XCTAssertEqual(prompt.chatItemUpdates[0].provider, .opencode)
        guard case .userPrompt(let promptText) = prompt.chatItemUpdates[0].block else {
            return XCTFail("Expected user prompt update")
        }
        XCTAssertEqual(promptText, "build this")

        let thinking = adapter.adaptAndConvert(envelope(
            "message.part.updated",
            sessionId: sessionId,
            properties: [
                "part": [
                    "type": "reasoning",
                    "messageID": "msg-assistant",
                    "text": "Need to inspect files."
                ]
            ]
        ))
        XCTAssertEqual(thinking.chatItemUpdates.count, 1)
        guard case .thinking(let thinkingText) = thinking.chatItemUpdates[0].block else {
            return XCTFail("Expected thinking update")
        }
        XCTAssertEqual(thinkingText, "Need to inspect files.")
        assertMessageRelativeOrdering(
            thinking.chatItemUpdates[0],
            messageId: "msg-assistant",
            typePriority: .reasoning,
            blockIndex: 0
        )

        let preTool = adapter.adaptAndConvert(envelope(
            "message.part.updated",
            sessionId: sessionId,
            properties: [
                "part": [
                    "type": "tool",
                    "messageID": "msg-assistant",
                    "tool": "bash",
                    "callID": "call-1",
                    "state": [
                        "status": "running",
                        "input": ["command": "echo hi"]
                    ]
                ]
            ]
        ))
        XCTAssertEqual(preTool.chatItemUpdates.count, 1)
        guard case .toolCall(let runningTool) = preTool.chatItemUpdates[0].block else {
            return XCTFail("Expected running tool call")
        }
        XCTAssertEqual(runningTool.toolId, "call-1")
        XCTAssertEqual(runningTool.status, .running)
        XCTAssertEqual(runningTool.input["command"], "echo hi")
        assertMessageRelativeOrdering(
            preTool.chatItemUpdates[0],
            messageId: "msg-assistant",
            typePriority: .action,
            blockIndex: 1
        )

        let postTool = adapter.adaptAndConvert(envelope(
            "message.part.updated",
            sessionId: sessionId,
            properties: [
                "part": [
                    "type": "tool",
                    "messageID": "msg-assistant",
                    "tool": "bash",
                    "callID": "call-1",
                    "state": [
                        "status": "completed",
                        "output": "hi\n"
                    ]
                ]
            ]
        ))
        XCTAssertEqual(postTool.chatItemUpdates.count, 1)
        guard case .updateStatus = postTool.chatItemUpdates[0].mutation else {
            return XCTFail("Expected tool status update")
        }
        guard case .toolCall(let completedTool) = postTool.chatItemUpdates[0].block else {
            return XCTFail("Expected completed tool call")
        }
        XCTAssertEqual(completedTool.status, .success)
        XCTAssertEqual(completedTool.result, "hi\n")

        let stop = adapter.adaptAndConvert(envelope(
            "session.status",
            sessionId: sessionId,
            properties: ["status": ["type": "idle"]]
        ))
        XCTAssertTrue(stop.chatItemUpdates.isEmpty)
        XCTAssertEqual(stop.passthroughEvents.count, 1)
        guard case .stop(let stoppedSession, _) = stop.passthroughEvents[0] else {
            return XCTFail("Expected stop passthrough")
        }
        XCTAssertEqual(stoppedSession, sessionId)

        adapter.clearSession(sessionId)
    }

    func testBashMetadataMarksCompletedToolAsError() {
        let sessionId = "opencode-session-\(UUID().uuidString)"
        let adapter = OpencodeChatItemAdapter.shared
        adapter.clearSession(sessionId)

        _ = adapter.adaptAndConvert(envelope(
            "session.updated",
            sessionId: sessionId,
            properties: ["info": ["directory": "/tmp/project"]]
        ))
        _ = adapter.adaptAndConvert(envelope(
            "message.part.updated",
            sessionId: sessionId,
            properties: [
                "part": [
                    "type": "tool",
                    "messageID": "msg-assistant",
                    "tool": "bash",
                    "callID": "call-error",
                    "state": [
                        "status": "running",
                        "input": ["command": "sleep 10"]
                    ]
                ]
            ]
        ))

        let result = adapter.adaptAndConvert(envelope(
            "message.part.updated",
            sessionId: sessionId,
            properties: [
                "part": [
                    "type": "tool",
                    "messageID": "msg-assistant",
                    "tool": "bash",
                    "callID": "call-error",
                    "state": [
                        "status": "completed",
                        "output": "timed out\n<bash_metadata>{}</bash_metadata>"
                    ]
                ]
            ]
        ))

        XCTAssertEqual(result.chatItemUpdates.count, 1)
        XCTAssertTrue(result.chatItemUpdates[0].isError)
        guard case .toolCall(let tool) = result.chatItemUpdates[0].block else {
            return XCTFail("Expected tool call")
        }
        XCTAssertEqual(tool.status, .error)
        XCTAssertEqual(tool.result, "timed out\n<bash_metadata>{}</bash_metadata>")

        _ = adapter.adaptAndConvert(envelope(
            "session.status",
            sessionId: sessionId,
            properties: ["status": ["type": "idle"]]
        ))
        adapter.clearSession(sessionId)
    }

    private func envelope(
        _ type: String,
        sessionId: String,
        properties: [String: Any]
    ) -> OpencodeHookEnvelope {
        var allProperties = properties
        allProperties["sessionID"] = sessionId
        return OpencodeHookEnvelope(
            origin: "opencode",
            type: type,
            properties: allProperties.mapValues { AnyCodable($0) }
        )
    }

    private func assertMessageRelativeOrdering(
        _ update: ChatItemUpdate,
        messageId: String,
        typePriority: BlockTypePriority,
        blockIndex: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .messageRelative(let actualMessageId, let actualTypePriority, let actualBlockIndex) = update.ordering else {
            return XCTFail("Expected message-relative ordering", file: file, line: line)
        }
        XCTAssertEqual(actualMessageId, messageId, file: file, line: line)
        XCTAssertEqual(actualTypePriority.rawValue, typePriority.rawValue, file: file, line: line)
        XCTAssertEqual(actualBlockIndex, blockIndex, file: file, line: line)
    }
}
