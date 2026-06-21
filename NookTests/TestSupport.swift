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
