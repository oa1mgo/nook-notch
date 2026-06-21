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

    func testOffsetParsingOnlyReadsAppendedRows() throws {
        let url = try writeTemporaryJSONL(
            """
            {"timestamp":"2026-06-21T00:00:01Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"first"}]}}
            """
        )

        let first = CodexTranscriptParser.parseTranscriptUpdates(
            at: url,
            sessionId: "codex-session",
            after: nil,
            fromOffset: 0
        )
        XCTAssertEqual(first.updates.count, 1)
        XCTAssertGreaterThan(first.endOffset, 0)

        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        handle.write(Data(
            """

            {"timestamp":"2026-06-21T00:00:02Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"second"}]}}
            """.utf8
        ))

        let second = CodexTranscriptParser.parseTranscriptUpdates(
            at: url,
            sessionId: "codex-session",
            after: nil,
            fromOffset: first.endOffset
        )

        XCTAssertEqual(second.updates.count, 1)
        XCTAssertGreaterThan(second.endOffset, first.endOffset)
        guard case .assistantText(let text) = second.updates[0].block else {
            return XCTFail("Expected assistant text update")
        }
        XCTAssertEqual(text, "second")
    }

    func testOffsetParsingDoesNotAdvancePastPartialTrailingRow() throws {
        let completeLine = #"{"timestamp":"2026-06-21T00:00:01Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"first"}]}}"#
        let partialLine = #"{"timestamp":"2026-06-21T00:00:02Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"sec"#
        let url = try writeTemporaryJSONL(completeLine + "\n" + partialLine)

        let first = CodexTranscriptParser.parseTranscriptUpdates(
            at: url,
            sessionId: "codex-session",
            after: nil,
            fromOffset: 0
        )
        XCTAssertEqual(first.updates.count, 1)

        let fileSize = try XCTUnwrap(
            (FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.uint64Value
        )
        XCTAssertLessThan(first.endOffset, fileSize)

        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        handle.write(Data(#"ond"}]}}"#.utf8))
        handle.write(Data("\n".utf8))

        let second = CodexTranscriptParser.parseTranscriptUpdates(
            at: url,
            sessionId: "codex-session",
            after: nil,
            fromOffset: first.endOffset
        )

        XCTAssertEqual(second.updates.count, 1)
        guard case .assistantText(let text) = second.updates[0].block else {
            return XCTFail("Expected assistant text update")
        }
        XCTAssertEqual(text, "second")
    }
}
