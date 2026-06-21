import XCTest
@testable import Nook

final class CodexTranscriptParserTests: XCTestCase {
    func testLowerBoundSkipsOldAndInvalidTimestampRows() throws {
        let lowerBound = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-06-21T00:00:00Z"))
        let url = try writeTemporaryJSONL(
            """
            {"timestamp":"2026-06-20T23:59:59Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"old prompt"}]}}
            {"timestamp":"not-a-date","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"bad timestamp"}]}}
            {"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"missing timestamp"}]}}
            {"timestamp":"2026-06-21T00:00:01Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"new prompt"}]}}
            {"timestamp":"2026-06-21T00:00:02Z","type":"response_item","payload":{"type":"function_call","call_id":"call-1","name":"Bash","arguments":"{\\"command\\":\\"echo hi\\",\\"count\\":2}"}}
            {"timestamp":"2026-06-21T00:00:03Z","type":"response_item","payload":{"type":"function_call_output","call_id":"call-1","output":"  done  "}}
            """
        )

        let updates = CodexTranscriptParser.parseTranscriptUpdates(
            at: url,
            sessionId: "codex-session",
            after: lowerBound
        )

        XCTAssertEqual(updates.count, 3)

        guard case .userPrompt(let prompt) = updates[0].block else {
            return XCTFail("Expected user prompt update")
        }
        XCTAssertEqual(prompt, "new prompt")

        guard case .toolCall(let toolCall) = updates[1].block else {
            return XCTFail("Expected tool call update")
        }
        XCTAssertEqual(toolCall.toolId, "call-1")
        XCTAssertEqual(toolCall.name, "Bash")
        XCTAssertEqual(toolCall.input["command"], "echo hi")
        XCTAssertEqual(toolCall.input["count"], "2")
        XCTAssertEqual(toolCall.status, .running)

        guard case .toolCall(let toolOutput) = updates[2].block else {
            return XCTFail("Expected tool output update")
        }
        XCTAssertEqual(toolOutput.toolId, "call-1")
        XCTAssertEqual(toolOutput.status, .success)
        XCTAssertEqual(toolOutput.result, "done")
    }

    func testMissingTimestampRowsAreAllowedWithoutLowerBound() throws {
        let url = try writeTemporaryJSONL(
            """
            {"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"hello"}]}}
            """
        )

        let updates = CodexTranscriptParser.parseTranscriptUpdates(
            at: url,
            sessionId: "codex-session",
            after: nil
        )

        XCTAssertEqual(updates.count, 1)
        guard case .assistantText(let text) = updates[0].block else {
            return XCTFail("Expected assistant text update")
        }
        XCTAssertEqual(text, "hello")
        XCTAssertNotNil(updates[0].messageTimestamp)
    }
}
