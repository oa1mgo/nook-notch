import XCTest
@testable import Nook

@MainActor
final class CodexHookAdapterTests: XCTestCase {
    func testPreToolUseDecodesAliasesAndCommandInput() throws {
        let envelope = try decodeCodexEnvelope(#"""
        {
          "origin": "codex",
          "hook_event_name": "Pre-Tool Use",
          "sessionId": "codex-session",
          "cwd": "/tmp/project",
          "toolName": "Bash",
          "callId": "call-1",
          "input": {
            "command": "echo hi"
          }
        }
        """#)

        guard case .preTool(let sessionId, let cwd, let toolName, let toolUseId, let input, let inputSummary) = CodexHookAdapter.adapt(envelope) else {
            return XCTFail("Expected preTool event")
        }

        XCTAssertEqual(sessionId, "codex-session")
        XCTAssertEqual(cwd, "/tmp/project")
        XCTAssertEqual(toolName, "Bash")
        XCTAssertEqual(toolUseId, "call-1")
        XCTAssertEqual(input["command"], "echo hi")
        XCTAssertEqual(inputSummary, "echo hi")
    }

    func testPostToolUseMarksProviderErrors() throws {
        let envelope = try decodeCodexEnvelope(#"""
        {
          "origin": "codex",
          "event": "post_tool_use",
          "session_id": "codex-session",
          "cwd": "/tmp/project",
          "tool_name": "Bash",
          "tool_use_id": "call-2",
          "tool_response": {
            "status": "failed",
            "stderr": "permission denied"
          }
        }
        """#)

        guard case .postTool(let sessionId, _, let toolName, let toolUseId, _, let output, let isError) = CodexHookAdapter.adapt(envelope) else {
            return XCTFail("Expected postTool event")
        }

        XCTAssertEqual(sessionId, "codex-session")
        XCTAssertEqual(toolName, "Bash")
        XCTAssertEqual(toolUseId, "call-2")
        XCTAssertEqual(output, #"{"status":"failed","stderr":"permission denied"}"#)
        XCTAssertTrue(isError)
    }

    func testLegacyCodexPayloadWithoutStatusIsAccepted() throws {
        let envelope = try decodeCodexEnvelope(#"""
        {
          "event": "Stop",
          "session_id": "legacy-session",
          "cwd": "/tmp/project"
        }
        """#)

        XCTAssertTrue(envelope.isCodexPayload)
        guard case .stop(let sessionId, let cwd) = CodexHookAdapter.adapt(envelope) else {
            return XCTFail("Expected stop event")
        }

        XCTAssertEqual(sessionId, "legacy-session")
        XCTAssertEqual(cwd, "/tmp/project")
    }

    func testClaudeLikePayloadWithStatusIsNotCodex() throws {
        let envelope = try decodeCodexEnvelope(#"""
        {
          "event": "Stop",
          "session_id": "claude-session",
          "cwd": "/tmp/project",
          "status": "ended"
        }
        """#)

        XCTAssertFalse(envelope.isCodexPayload)
    }

    private func decodeCodexEnvelope(_ json: String) throws -> CodexHookEnvelope {
        try JSONDecoder().decode(CodexHookEnvelope.self, from: Data(json.utf8))
    }
}
