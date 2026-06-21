import XCTest
@testable import Nook

final class ClaudeChatItemAdapterTests: XCTestCase {
    func testHistoryLoadConvertsTextThinkingAndToolResultStatus() {
        let userMessage = ChatMessage(
            id: "user-message",
            role: .user,
            timestamp: fixedDate(10),
            content: [.text("Hello")]
        )
        let assistantMessage = ChatMessage(
            id: "assistant-message",
            role: .assistant,
            timestamp: fixedDate(20),
            content: [
                .thinking("Thinking"),
                .toolUse(ToolUseBlock(
                    id: "tool-1",
                    name: "Bash",
                    input: ["command": "exit 1"]
                )),
                .text("Done")
            ]
        )
        let toolResults = [
            "tool-1": ConversationParser.ToolResult(
                content: "command failed",
                stdout: nil,
                stderr: "permission denied",
                isError: true
            )
        ]

        let updates = ClaudeChatItemAdapter.updates(
            fromHistoryLoad: [userMessage, assistantMessage],
            completedTools: ["tool-1"],
            toolResults: toolResults,
            structuredResults: [:],
            sessionId: "claude-session"
        )

        XCTAssertEqual(updates.count, 4)
        XCTAssertTrue(updates.allSatisfy { $0.provider == .claude })
        XCTAssertTrue(updates.allSatisfy { update in
            if case .appendOrder = update.ordering { return true }
            return false
        })
        XCTAssertTrue(updates.allSatisfy { update in
            if case .insert = update.mutation { return true }
            return false
        })

        guard case .userPrompt(let prompt) = updates[0].block else {
            return XCTFail("Expected user prompt update")
        }
        XCTAssertEqual(prompt, "Hello")

        guard case .thinking(let thinking) = updates[1].block else {
            return XCTFail("Expected thinking update")
        }
        XCTAssertEqual(thinking, "Thinking")

        guard case .assistantText(let assistantText) = updates[3].block else {
            return XCTFail("Expected assistant text update")
        }
        XCTAssertEqual(assistantText, "Done")

        guard case .toolCall(let tool) = updates[2].block else {
            return XCTFail("Expected tool call update")
        }
        XCTAssertEqual(tool.toolId, "tool-1")
        XCTAssertEqual(tool.name, "Bash")
        XCTAssertEqual(tool.input["command"], "exit 1")
        XCTAssertEqual(tool.status, .error)
        XCTAssertEqual(tool.result, "permission denied")
    }

    func testAskUserQuestionRejectedResultStillBuildsStructuredQuestion() {
        let questionsJson = #"""
        [
          {
            "header": "Choice",
            "question": "Continue?",
            "options": [
              { "label": "Yes", "description": "Proceed" },
              { "label": "No", "description": "Stop" }
            ]
          }
        ]
        """#
        let message = ChatMessage(
            id: "assistant-message",
            role: .assistant,
            timestamp: fixedDate(30),
            content: [
                .toolUse(ToolUseBlock(
                    id: "question-tool",
                    name: "AskUserQuestion",
                    input: ["questions": questionsJson]
                ))
            ]
        )
        let toolResults = [
            "question-tool": ConversationParser.ToolResult(
                content: "user doesn't want to proceed",
                stdout: nil,
                stderr: nil,
                isError: true
            )
        ]

        let updates = ClaudeChatItemAdapter.updates(
            fromHistoryLoad: [message],
            completedTools: [],
            toolResults: toolResults,
            structuredResults: [:],
            sessionId: "claude-session"
        )

        XCTAssertEqual(updates.count, 1)
        guard case .toolCall(let tool) = updates[0].block else {
            return XCTFail("Expected tool call update")
        }
        XCTAssertEqual(tool.status, .interrupted)
        XCTAssertEqual(tool.result, "user doesn't want to proceed")
        guard case .askUserQuestion(let result) = tool.structuredResult else {
            return XCTFail("Expected AskUserQuestion structured result")
        }
        XCTAssertEqual(result.questions.count, 1)
        XCTAssertEqual(result.questions[0].header, "Choice")
        XCTAssertEqual(result.questions[0].question, "Continue?")
        XCTAssertEqual(result.questions[0].options.map(\.label), ["Yes", "No"])
    }
}
