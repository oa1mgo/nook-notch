import XCTest
@testable import Nook

final class CodexTranscriptParserTests: XCTestCase {
    func testDesktopUserMessageBoundaryExcludesModelContext() throws {
        let url = try writeTemporaryJSONL("""
        {"timestamp":"2026-09-15T09:33:27.702Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"<environment_context>private context</environment_context>"}],"internal_chat_message_metadata_passthrough":{"content_item_kinds":["environments.environment_context"]}}}
        {"timestamp":"2026-09-15T09:33:27.771Z","type":"response_item","payload":{"type":"message","id":"msg-user","role":"user","content":[{"type":"input_text","text":"修复消息展示"}],"internal_chat_message_metadata_passthrough":{"content_item_kinds":["user.text"]}}}
        {"timestamp":"2026-09-15T09:33:27.772Z","type":"event_msg","payload":{"type":"item_completed","thread_id":"session","turn_id":"turn","item":{"type":"UserMessage","id":"direct-user","client_id":"client","content":[{"type":"text","text":"修复消息展示","text_elements":[]}]}}}
        {"timestamp":"2026-09-15T09:33:28.000Z","type":"response_item","payload":{"type":"message","id":"answer","role":"assistant","content":[{"type":"output_text","text":"收到"}]}}
        """)
        let updates = CodexTranscriptParser.parseTranscriptUpdates(at: url, sessionId: "session", after: nil)
        XCTAssertEqual(updates.map(\.block), [.userPrompt("修复消息展示"), .assistantText("收到")])
    }

    func testDirectTextIsNotFilteredByItsContentsAndOtherThreadIsIgnored() throws {
        let url = try writeTemporaryJSONL([
            codexUserRow(id: "one", text: "<environment_context>用户在讨论这个标签</environment_context>"),
            codexUserRow(id: "two", text: "same"),
            codexUserRow(id: "three", text: "same"),
            codexUserRow(id: "foreign", text: "other session", sessionId: "another")
        ].joined(separator: "\n"))
        let updates = CodexTranscriptParser.parseTranscriptUpdates(at: url, sessionId: "session", after: nil)
        XCTAssertEqual(updates.count, 3)
        XCTAssertEqual(Set(updates.map(\.id)).count, 3)
        XCTAssertEqual(updates[1].block, updates[2].block)
    }

    func testFallbackMessageIDsStayStableAcrossFullAndIncrementalReads() throws {
        let url = try writeTemporaryJSONL(codexAssistantRow(text: "first") + "\n")
        let first = CodexTranscriptParser.parseTranscriptUpdates(at: url, sessionId: "session", after: nil, fromOffset: 0)
        try appendCodexRows(codexAssistantRow(text: "second", second: 2), to: url)
        let incremental = CodexTranscriptParser.parseTranscriptUpdates(at: url, sessionId: "session", after: nil, fromOffset: first.endOffset)
        let full = CodexTranscriptParser.parseTranscriptUpdates(at: url, sessionId: "session", after: nil)
        XCTAssertEqual(full.map(\.id), first.updates.map(\.id) + incremental.updates.map(\.id))
    }

    func testAllFragmentsLoadWithExactMetadataIdentityAndIndependentOffsets() async throws {
        let root = try makeCodexTestDirectory()
        let latest = try writeCodexFragment(in: root, name: "rollout-2026-09-15-session_suffix.jsonl", rows: [codexUserRow(id: "new", text: "new", second: 3)])
        let old = try writeCodexFragment(in: root, name: "rollout-2026-09-01-session.jsonl", rows: [codexUserRow(id: "old", text: "old")])
        _ = try writeCodexFragment(in: root, name: "rollout-2026-09-02-session_child.jsonl", sessionId: "other", rows: [codexUserRow(id: "wrong", text: "wrong")])
        let first = await CodexTranscriptParser.loadSessionUpdates(sessionId: "session", root: root)
        XCTAssertEqual(first.updates.map(\.block), [.userPrompt("old"), .userPrompt("new")])
        XCTAssertEqual(first.cursor.files.count, 2)
        let unchanged = await CodexTranscriptParser.loadSessionUpdates(sessionId: "session", cursor: first.cursor, root: root)
        XCTAssertTrue(unchanged.updates.isEmpty)
        try appendCodexRows(codexAssistantRow(text: "old fragment late write", second: 4), to: old)
        try appendCodexRows(codexAssistantRow(text: "latest write", second: 5), to: latest)
        let next = await CodexTranscriptParser.loadSessionUpdates(sessionId: "session", cursor: unchanged.cursor, root: root)
        XCTAssertEqual(next.updates.count, 2)
        XCTAssertEqual(Set(next.updates.map(\.id)).count, 2)
    }

    func testNewFragmentDoesNotReusePreviousOffsetOrFallbackIDs() async throws {
        let root = try makeCodexTestDirectory()
        _ = try writeCodexFragment(in: root, name: "rollout-01-session.jsonl", rows: [codexAssistantRow(text: "first")])
        let first = await CodexTranscriptParser.loadSessionUpdates(sessionId: "session", root: root)
        _ = try writeCodexFragment(in: root, name: "rollout-02-session_part.jsonl", rows: [codexAssistantRow(text: "other")])
        let next = await CodexTranscriptParser.loadSessionUpdates(sessionId: "session", cursor: first.cursor, root: root)
        XCTAssertEqual(next.updates.map(\.block), [.assistantText("other")])
        XCTAssertNotEqual(first.updates.first?.id, next.updates.first?.id)
    }

    func testNativeMessageIDsDeduplicateOverlappingFragments() async throws {
        let root = try makeCodexTestDirectory()
        let rows = [codexUserRow(id: "same-id", text: "replayed"), codexAssistantRow(text: "answer", id: "answer-id")]
        _ = try writeCodexFragment(in: root, name: "rollout-01-session.jsonl", rows: rows)
        _ = try writeCodexFragment(in: root, name: "rollout-02-session_part.jsonl", rows: rows)
        let result = await CodexTranscriptParser.loadSessionUpdates(sessionId: "session", root: root)
        var items: [ChatHistoryItem] = []
        var orderings: [String: BlockOrdering] = [:]
        ChatItemUpdateReducer.applyBatch(result.updates, items: &items, orderings: &orderings)
        XCTAssertEqual(items.map(\.type), [.user("replayed"), .assistant("answer")])
    }

    func testAtomicFileReplacementRestartsEvenWhenLarger() async throws {
        let root = try makeCodexTestDirectory()
        let url = try writeCodexFragment(in: root, name: "rollout-session.jsonl", rows: [codexUserRow(id: "one", text: "before")])
        let first = await CodexTranscriptParser.loadSessionUpdates(sessionId: "session", root: root)
        _ = try writeCodexFragment(in: root, name: url.lastPathComponent, rows: [codexUserRow(id: "two", text: String(repeating: "after", count: 200))])
        let next = await CodexTranscriptParser.loadSessionUpdates(sessionId: "session", cursor: first.cursor, root: root)
        XCTAssertEqual(next.updates.count, 1)
        XCTAssertNotEqual(next.updates.first?.id, first.updates.first?.id)
    }

    func testLowerBoundAppliesToAllFragmentsAndSubsequentAppends() async throws {
        let root = try makeCodexTestDirectory()
        _ = try writeCodexFragment(in: root, name: "rollout-01-session.jsonl", rows: [codexUserRow(id: "old", text: "old")])
        let latest = try writeCodexFragment(in: root, name: "rollout-02-session.jsonl", rows: [codexUserRow(id: "new", text: "new", second: 3)])
        let bound = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-09-15T00:00:02Z"))
        let first = await CodexTranscriptParser.loadSessionUpdates(sessionId: "session", after: bound, root: root)
        XCTAssertEqual(first.updates.map(\.block), [.userPrompt("new")])
        try appendCodexRows(codexUserRow(id: "late-old", text: "late old"), to: latest)
        let next = await CodexTranscriptParser.loadSessionUpdates(sessionId: "session", after: bound, cursor: first.cursor, root: root)
        XCTAssertTrue(next.updates.isEmpty)
        let key = latest.resolvingSymlinksInPath().path
        let beforeOffset = try XCTUnwrap(first.cursor.files[key]?.offset)
        let afterOffset = try XCTUnwrap(next.cursor.files[key]?.offset)
        XCTAssertGreaterThan(afterOffset, beforeOffset)
    }

    func testLargeMetadataAndUserForkAreNotMistakenForSubagents() throws {
        let root = try makeCodexTestDirectory()
        _ = try writeCodexFragment(in: root, name: "rollout-session.jsonl", rows: [], extraMetadata: ["forked_from_id": "parent", "instructions": String(repeating: "x", count: 20_000)])
        XCTAssertEqual(CodexTranscriptParser.transcriptURLs(for: "session", root: root).count, 1)
        XCTAssertFalse(CodexTranscriptParser.isSubagentSession(sessionId: "session", root: root))
        _ = try writeCodexFragment(in: root, name: "rollout-agent.jsonl", sessionId: "agent", rows: [], extraMetadata: ["source": ["subagent": ["thread_spawn": ["parent_thread_id": "session"]]]])
        XCTAssertTrue(CodexTranscriptParser.isSubagentSession(sessionId: "agent", root: root))
    }

    func testLowerBoundSkipsOldAndInvalidTimestampRows() throws {
        let lowerBound = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-06-21T00:00:00Z"))
        let url = try writeTemporaryJSONL(
            """
            {"timestamp":"2026-06-20T23:59:59Z","type":"event_msg","payload":{"type":"user_message","message":"old prompt"}}
            {"timestamp":"not-a-date","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"bad timestamp"}]}}
            {"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"missing timestamp"}]}}
            {"timestamp":"2026-06-21T00:00:01Z","type":"event_msg","payload":{"type":"user_message","message":"new prompt"}}
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

    func testOnlyDirectUserInteractionIsAddedToHistory() throws {
        let url = try writeTemporaryJSONL(
            """
            {"timestamp":"2026-06-21T00:00:01Z","type":"event_msg","payload":{"type":"user_message","message":"direct prompt"}}
            {"timestamp":"2026-06-21T00:00:01Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"direct prompt"},{"type":"input_text","text":"<codex_internal_context>memory</codex_internal_context>"},{"type":"input_text","text":"<environment_context>workspace</environment_context>"}]}}
            {"timestamp":"2026-06-21T00:00:02Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"answer"}],"phase":"final_answer"}}
            """
        )

        let updates = CodexTranscriptParser.parseTranscriptUpdates(
            at: url,
            sessionId: "codex-session",
            after: nil
        )

        XCTAssertEqual(updates.count, 2)
        guard case .userPrompt(let prompt) = updates[0].block else {
            return XCTFail("Expected direct user prompt")
        }
        XCTAssertEqual(prompt, "direct prompt")
        guard case .assistantText(let answer) = updates[1].block else {
            return XCTFail("Expected assistant answer")
        }
        XCTAssertEqual(answer, "answer")
    }

    func testStringToolInputAndArrayToolOutputArePreserved() throws {
        let url = try writeTemporaryJSONL(
            """
            {"timestamp":"2026-06-21T00:00:01Z","type":"response_item","payload":{"type":"custom_tool_call","call_id":"call-1","name":"exec","input":"await tools.exec_command({cmd: \\"pwd\\"})"}}
            {"timestamp":"2026-06-21T00:00:02Z","type":"response_item","payload":{"type":"custom_tool_call_output","call_id":"call-1","output":[{"type":"input_text","text":"first"},{"type":"input_image","image_url":"data:image/png;base64,abc"},{"type":"input_text","text":"second"}]}}
            """
        )

        let updates = CodexTranscriptParser.parseTranscriptUpdates(
            at: url,
            sessionId: "codex-session",
            after: nil
        )

        XCTAssertEqual(updates.count, 2)
        guard case .toolCall(let toolCall) = updates[0].block else {
            return XCTFail("Expected tool call")
        }
        XCTAssertEqual(toolCall.input["input"], #"await tools.exec_command({cmd: "pwd"})"#)

        guard case .toolCall(let toolOutput) = updates[1].block else {
            return XCTFail("Expected tool output")
        }
        XCTAssertEqual(toolOutput.result, "first\n\nsecond")
    }

    func testOffsetParsingOnlyReadsAppendedRows() throws {
        let url = try writeTemporaryJSONL(
            """
            {"timestamp":"2026-06-21T00:00:01Z","type":"event_msg","payload":{"type":"user_message","message":"first"}}
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
        let completeLine = #"{"timestamp":"2026-06-21T00:00:01Z","type":"event_msg","payload":{"type":"user_message","message":"first"}}"#
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
