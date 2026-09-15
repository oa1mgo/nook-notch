import Foundation
import XCTest
@testable import Nook

func fixedDate(_ seconds: TimeInterval) -> Date {
    Date(timeIntervalSince1970: seconds)
}

func makeToolCall(
    id: String,
    name: String = "Bash",
    input: [String: String] = [:],
    status: ToolStatus = .running,
    result: String? = nil,
    structuredResult: ToolResultData? = nil,
    subagentTools: [SubagentToolCall] = []
) -> ChatItemToolCall {
    ChatItemToolCall(
        toolId: id,
        name: name,
        input: input,
        status: status,
        result: result,
        structuredResult: structuredResult,
        subagentTools: subagentTools
    )
}

func makeToolItem(
    id: String,
    status: ToolStatus = .running,
    result: String? = nil,
    timestamp: Date = fixedDate(0)
) -> ChatHistoryItem {
    ChatHistoryItem(
        id: id,
        type: .toolCall(ToolCallItem(
            name: "Bash",
            input: ["command": "echo hi"],
            status: status,
            result: result,
            structuredResult: nil,
            subagentTools: []
        )),
        timestamp: timestamp
    )
}

extension XCTestCase {
    func makeCodexTestDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("nook-codex-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    @discardableResult
    func writeCodexFragment(in root: URL, name: String = "rollout-session.jsonl", sessionId: String = "session", rows: [String], extraMetadata: [String: Any] = [:]) throws -> URL {
        var metadata = extraMetadata
        metadata["id"] = sessionId
        let meta = try JSONSerialization.data(withJSONObject: ["type": "session_meta", "payload": metadata], options: [.sortedKeys])
        let url = root.appendingPathComponent(name)
        let contents = String(decoding: meta, as: UTF8.self) + "\n" + rows.joined(separator: "\n") + "\n"
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func writeTemporaryJSONL(_ contents: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("nook-tests-\(UUID().uuidString)")
            .appendingPathExtension("jsonl")
        try contents.write(to: url, atomically: true, encoding: .utf8)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }
}

func codexUserRow(id: String, text: String, sessionId: String = "session", second: Int = 1, timestamp: String? = nil) -> String {
    codexJSONRow([
        "timestamp": timestamp ?? String(format: "2026-09-15T00:00:%02dZ", second),
        "type": "event_msg",
        "payload": ["type": "item_completed", "thread_id": sessionId, "turn_id": "turn-\(id)",
                    "item": ["type": "UserMessage", "id": id, "content": [["type": "text", "text": text]]]]
    ])
}

func codexAssistantRow(text: String, second: Int = 1, id: String? = nil) -> String {
    var payload: [String: Any] = ["type": "message", "role": "assistant", "content": [["type": "output_text", "text": text]]]
    payload["id"] = id
    return codexJSONRow(["timestamp": String(format: "2026-09-15T00:00:%02dZ", second), "type": "response_item", "payload": payload])
}

func codexJSONRow(_ row: [String: Any]) -> String {
    String(decoding: try! JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]), as: UTF8.self)
}

func appendCodexRows(_ rows: String, to url: URL) throws {
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: Data((rows + "\n").utf8))
}
