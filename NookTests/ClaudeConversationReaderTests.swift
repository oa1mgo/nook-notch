import XCTest
@testable import Nook

@MainActor
final class ClaudeConversationReaderTests: XCTestCase {
    private let sessionId = "session"
    private let cwd = "/tmp/claude-reader-a"

    func testDiscardedCandidateDoesNotConsumeRowsWhenFileKeepsGrowing() async throws {
        let root = try makeProjectsRoot()
        let file = try writeMessages([message(id: "base")], root: root, cwd: cwd)
        let reader = ConversationParser(projectsRoot: root)
        let accepted = await reader.readSnapshot(sessionId: sessionId, cwd: cwd, cursor: nil)
        try append([message(id: "first")], to: file)
        let discarded = await reader.readSnapshot(sessionId: sessionId, cwd: cwd, cursor: accepted.cursor)
        XCTAssertEqual(discarded.newMessages.map(\.id), ["first"])

        try append([message(id: "second")], to: file)
        let retried = await reader.readSnapshot(sessionId: sessionId, cwd: cwd, cursor: accepted.cursor)
        XCTAssertEqual(retried.newMessages.map(\.id), ["first", "second"])
        XCTAssertEqual(retried.allMessages.map(\.id), ["base", "first", "second"])

        let unchanged = await reader.readSnapshot(sessionId: sessionId, cwd: cwd, cursor: retried.cursor)
        XCTAssertTrue(unchanged.newMessages.isEmpty)
        XCTAssertEqual(unchanged.allMessages.map(\.id), ["base", "first", "second"])
    }

    func testDiscardedClearIsReplayedUntilItsCursorIsAccepted() async throws {
        let root = try makeProjectsRoot()
        let file = try writeMessages([message(id: "before")], root: root, cwd: cwd)
        let reader = ConversationParser(projectsRoot: root)
        let accepted = await reader.readSnapshot(sessionId: sessionId, cwd: cwd, cursor: nil)
        try append([message(id: "also-before"), clearCommand, message(id: "after")], to: file)
        let discarded = await reader.readSnapshot(sessionId: sessionId, cwd: cwd, cursor: accepted.cursor)
        XCTAssertTrue(discarded.clearDetected)
        XCTAssertEqual(discarded.newMessages.map(\.id), ["after"])
        XCTAssertEqual(discarded.allMessages.map(\.id), ["after"])

        try append([message(id: "latest")], to: file)
        let retried = await reader.readSnapshot(sessionId: sessionId, cwd: cwd, cursor: accepted.cursor)
        XCTAssertTrue(retried.clearDetected)
        XCTAssertEqual(retried.newMessages.map(\.id), ["after", "latest"])
        XCTAssertEqual(retried.allMessages.map(\.id), ["after", "latest"])

        let unchanged = await reader.readSnapshot(sessionId: sessionId, cwd: cwd, cursor: retried.cursor)
        XCTAssertFalse(unchanged.clearDetected)
        XCTAssertTrue(unchanged.newMessages.isEmpty)
    }

    func testFirstReadWithClearExcludesEarlierRowsFromBothViews() async throws {
        let root = try makeProjectsRoot()
        _ = try writeMessages([message(id: "before"), clearCommand, message(id: "after")], root: root, cwd: cwd)
        let reader = ConversationParser(projectsRoot: root)
        let snapshot = await reader.readSnapshot(sessionId: sessionId, cwd: cwd, cursor: ClaudeConversationCursor())
        XCTAssertEqual(snapshot.newMessages.map(\.id), ["after"])
        XCTAssertEqual(snapshot.allMessages.map(\.id), ["after"])
    }

    func testCursorIsBoundToFullSourcePathRatherThanSessionID() async throws {
        let root = try makeProjectsRoot()
        let otherCwd = "/tmp/claude-reader-b"
        let firstFile = try writeMessages([message(id: "a")], root: root, cwd: cwd)
        _ = try writeMessages([message(id: "b")], root: root, cwd: otherCwd)
        let reader = ConversationParser(projectsRoot: root)
        let a = await reader.readSnapshot(sessionId: sessionId, cwd: cwd, cursor: nil)
        let b = await reader.readSnapshot(sessionId: sessionId, cwd: otherCwd, cursor: a.cursor)
        XCTAssertEqual(b.newMessages.map(\.id), ["b"])
        XCTAssertEqual(b.allMessages.map(\.id), ["b"])

        try append([message(id: "a-next")], to: firstFile)
        let aNext = await reader.readSnapshot(sessionId: sessionId, cwd: cwd, cursor: a.cursor)
        XCTAssertEqual(aNext.newMessages.map(\.id), ["a-next"])
        XCTAssertEqual(aNext.allMessages.map(\.id), ["a", "a-next"])

        let secondRoot = try makeProjectsRoot()
        _ = try writeMessages([message(id: "other-root")], root: secondRoot, cwd: cwd)
        let secondReader = ConversationParser(projectsRoot: secondRoot)
        let other = await secondReader.readSnapshot(sessionId: sessionId, cwd: cwd, cursor: aNext.cursor)
        XCTAssertEqual(other.allMessages.map(\.id), ["other-root"])
    }

    func testSnapshotContainsResultsWithoutAdvancingLegacyState() async throws {
        let root = try makeProjectsRoot()
        _ = try writeMessages([
            toolUse,
            toolResult,
            message(id: "answer", role: "assistant"),
        ], root: root, cwd: cwd)
        let reader = ConversationParser(projectsRoot: root)
        let snapshot = await reader.readSnapshot(sessionId: sessionId, cwd: cwd, cursor: nil)

        XCTAssertEqual(snapshot.allMessages.map(\.id), ["tool-message", "answer"])
        XCTAssertEqual(snapshot.completedToolIds, ["tool"])
        XCTAssertEqual(snapshot.toolResults["tool"]?.stdout, "done")
        guard case .bash(let result) = snapshot.structuredResults["tool"] else {
            return XCTFail("Expected the tool result from the same snapshot")
        }
        XCTAssertEqual(result.stdout, "done")
        XCTAssertEqual(snapshot.conversationInfo.lastMessage, "answer")

        let legacyCompletions = await reader.completedToolIds(for: sessionId)
        XCTAssertTrue(legacyCompletions.isEmpty, "Candidate reads must not mutate the legacy shared cursor")
        let replay = await reader.readSnapshot(sessionId: sessionId, cwd: cwd, cursor: nil)
        XCTAssertEqual(replay.newMessages.map(\.id), ["tool-message", "answer"])
        XCTAssertEqual(replay.completedToolIds, ["tool"])
    }

    func testResultOnlyAppendProducesCompletionWithoutNewMessages() async throws {
        let root = try makeProjectsRoot()
        let file = try writeMessages([toolUse], root: root, cwd: cwd)
        let reader = ConversationParser(projectsRoot: root)
        let accepted = await reader.readSnapshot(sessionId: sessionId, cwd: cwd, cursor: nil)
        XCTAssertTrue(accepted.completedToolIds.isEmpty)

        try append([toolResult], to: file)
        let completed = await reader.readSnapshot(sessionId: sessionId, cwd: cwd, cursor: accepted.cursor)
        XCTAssertTrue(completed.newMessages.isEmpty)
        XCTAssertEqual(completed.allMessages.map(\.id), ["tool-message"])
        XCTAssertEqual(completed.completedToolIds, ["tool"])
        XCTAssertEqual(completed.toolResults["tool"]?.stdout, "done")
    }

    func testSubagentReaderUsesInjectedRootAndNestedPath() async throws {
        let root = try makeProjectsRoot()
        let project = root.appendingPathComponent(projectDirectory(cwd))
        let directory = project.appendingPathComponent(sessionId).appendingPathComponent("subagents")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("agent-child.jsonl")
        try (toolUse + "\n" + toolResult + "\n").write(to: file, atomically: true, encoding: .utf8)
        let reader = ConversationParser(projectsRoot: root)
        let tools = await reader.readSubagentTools(sessionId: sessionId, agentId: "child", cwd: cwd)
        XCTAssertEqual(tools.map(\.id), ["tool"])
        XCTAssertEqual(tools.first?.name, "Bash")
        XCTAssertEqual(tools.first?.isCompleted, true)
    }

    private var clearCommand: String {
        #"{"type":"user","uuid":"clear","message":{"content":"<command-name>/clear</command-name>"}}"#
    }

    private var toolUse: String {
        #"{"type":"assistant","uuid":"tool-message","timestamp":"2026-10-22T00:00:00.000Z","message":{"content":[{"type":"tool_use","id":"tool","name":"Bash","input":{"command":"echo done"}}]}}"#
    }

    private var toolResult: String {
        #"{"type":"user","uuid":"tool-result","toolName":"Bash","toolUseResult":{"stdout":"done","stderr":""},"message":{"content":[{"type":"tool_result","tool_use_id":"tool","content":"done","is_error":false}]}}"#
    }

    private func message(id: String, role: String = "user") -> String {
        "{\"type\":\"\(role)\",\"uuid\":\"\(id)\",\"timestamp\":\"2026-10-22T00:00:00.000Z\",\"message\":{\"content\":\"\(id)\"}}"
    }

    private func makeProjectsRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("nook-claude-reader-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func projectDirectory(_ cwd: String) -> String {
        cwd.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ".", with: "-")
    }

    private func writeMessages(_ rows: [String], root: URL, cwd: String) throws -> URL {
        let directory = root.appendingPathComponent(projectDirectory(cwd), isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent(sessionId + ".jsonl")
        try (rows.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    private func append(_ rows: [String], to file: URL) throws {
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((rows.joined(separator: "\n") + "\n").utf8))
    }
}
