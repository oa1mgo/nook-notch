//
//  AntigravityAdapterTests.swift
//  NookTests
//
//  Tests for Antigravity hook decoding, ChatItem adaptation, lifecycle
//  state reduction, ToolKind mapping, and hooks.json installation.
//

import XCTest
@testable import Nook

final class AntigravityAdapterTests: XCTestCase {

    // MARK: - Envelope Decoding & Classification

    func testEnvelopeDecodesCamelCaseProtoJSONWithOrigin() throws {
        let json = """
        {
          "origin": "antigravity",
          "hookEventName": "PreToolUse",
          "conversationId": "conv-agy-123",
          "workspacePaths": ["/tmp/project-a"],
          "cwd": "/tmp/project-a/sub",
          "modelName": "auto",
          "lastUserInput": "Run unit tests",
          "stepIdx": 7,
          "toolCall": {
            "id": "toolu_42",
            "name": "run_command",
            "args": {
              "CommandLine": "xcodebuild test"
            }
          }
        }
        """

        let envelope = try JSONDecoder().decode(AntigravityHookEnvelope.self, from: Data(json.utf8))
        XCTAssertTrue(envelope.isAntigravityPayload)
        XCTAssertEqual(envelope.sessionId, "conv-agy-123")
        XCTAssertEqual(envelope.cwd, "/tmp/project-a/sub")
        XCTAssertEqual(envelope.toolName, "run_command")
        XCTAssertEqual(envelope.toolUseId, "toolu_42")
        XCTAssertEqual(envelope.displayInput["CommandLine"], "xcodebuild test")
        XCTAssertEqual(envelope.inputSummary, "xcodebuild test")
    }

    func testEnvelopeFallsBackToWorkspacePathAndStepId() throws {
        let json = """
        {
          "hookEventName": "PreInvocation",
          "conversationId": "conv-agy-fallback",
          "workspacePaths": ["/tmp/workspace-root"],
          "lastUserInput": "Fix the bug",
          "stepIdx": 3
        }
        """

        let envelope = try JSONDecoder().decode(AntigravityHookEnvelope.self, from: Data(json.utf8))
        XCTAssertTrue(envelope.isAntigravityPayload)
        XCTAssertEqual(envelope.cwd, "/tmp/workspace-root")
        XCTAssertEqual(envelope.toolUseId, "antigravity-conv-agy-fallback-step-3")
    }

    func testNonAntigravityPayloadIsRejected() throws {
        let cursorJson = """
        {
          "origin": "cursor",
          "event": "beforeSubmitPrompt",
          "session_id": "cursor-1"
        }
        """

        let envelope = try JSONDecoder().decode(AntigravityHookEnvelope.self, from: Data(cursorJson.utf8))
        XCTAssertFalse(envelope.isAntigravityPayload)
        XCTAssertNil(AntigravityHookAdapter.adapt(envelope))
    }

    // MARK: - ChatItem & Hook Adaptation

    func testPreInvocationEmitsStablePromptAndProcessing() throws {
        let json = """
        {
          "origin": "antigravity",
          "hookEventName": "PreInvocation",
          "conversationId": "conv-1",
          "cwd": "/tmp/nook",
          "lastUserInput": "Add Antigravity support",
          "invocationNum": 1
        }
        """

        let envelope = try JSONDecoder().decode(AntigravityHookEnvelope.self, from: Data(json.utf8))
        let result1 = AntigravityChatItemAdapter.shared.adaptAndConvert(envelope)
        let result2 = AntigravityChatItemAdapter.shared.adaptAndConvert(envelope)

        XCTAssertEqual(result1.chatItemUpdates.count, 1)
        XCTAssertEqual(result1.chatItemUpdates.first?.id, result2.chatItemUpdates.first?.id)
        XCTAssertEqual(result1.chatItemUpdates.first?.provider, .antigravity)
        if case .userPrompt(let prompt) = result1.chatItemUpdates.first?.block {
            XCTAssertEqual(prompt, "Add Antigravity support")
        } else {
            XCTFail("Expected userPrompt block")
        }

        XCTAssertEqual(result1.passthroughEvents.count, 1)
        if case .processingStarted(let sessionId, let cwd) = result1.passthroughEvents.first {
            XCTAssertEqual(sessionId, "conv-1")
            XCTAssertEqual(cwd, "/tmp/nook")
        } else {
            XCTFail("Expected processingStarted event")
        }
    }

    func testAskQuestionPreToolUseTransitionsToWaitingForInput() throws {
        let json = """
        {
          "origin": "antigravity",
          "hookEventName": "PreToolUse",
          "conversationId": "conv-q",
          "cwd": "/tmp/nook",
          "toolCall": {
            "id": "call-ask-1",
            "name": "ask_question",
            "args": {
              "questions": "Proceed?"
            }
          }
        }
        """

        let envelope = try JSONDecoder().decode(AntigravityHookEnvelope.self, from: Data(json.utf8))
        let result = AntigravityChatItemAdapter.shared.adaptAndConvert(envelope)

        XCTAssertEqual(result.chatItemUpdates.count, 1)
        if case .waitingForInput(let sessionId, _) = result.passthroughEvents.first {
            XCTAssertEqual(sessionId, "conv-q")
        } else {
            XCTFail("Expected waitingForInput event for ask_question tool")
        }
    }

    func testPostToolUseErrorMarksToolAsError() throws {
        let json = """
        {
          "origin": "antigravity",
          "hookEventName": "PostToolUse",
          "conversationId": "conv-err",
          "cwd": "/tmp/nook",
          "error": "exit status 1",
          "toolCall": {
            "id": "toolu_99",
            "name": "run_command",
            "args": { "CommandLine": "false" }
          }
        }
        """

        let envelope = try JSONDecoder().decode(AntigravityHookEnvelope.self, from: Data(json.utf8))
        let result = AntigravityChatItemAdapter.shared.adaptAndConvert(envelope)

        XCTAssertEqual(result.chatItemUpdates.count, 2)
        XCTAssertEqual(result.chatItemUpdates.first?.mutation, .insert)
        let statusUpdate = try XCTUnwrap(result.chatItemUpdates.last)
        XCTAssertEqual(statusUpdate.mutation, .updateStatus)
        XCTAssertTrue(statusUpdate.isError)
        if case .toolCall(let tool) = statusUpdate.block {
            XCTAssertEqual(tool.status, .error)
            XCTAssertEqual(tool.result, "exit status 1")
        } else {
            XCTFail("Expected toolCall block")
        }

        // Verify standalone PostToolUse (without prior PreToolUse) inserts into reducer.
        var items: [ChatHistoryItem] = []
        var orderings: [String: BlockOrdering] = [:]
        ChatItemUpdateReducer.applyBatch(result.chatItemUpdates, items: &items, orderings: &orderings)
        XCTAssertEqual(items.count, 1)
        if case .toolCall(let reducedTool) = items.first?.type {
            XCTAssertEqual(reducedTool.status, .error)
            XCTAssertEqual(reducedTool.result, "exit status 1")
        } else {
            XCTFail("Expected reduced toolCall item")
        }
    }

    // MARK: - Lifecycle State Reducer

    func testReducerFinishesDanglingToolsAndSetsCompletionMarker() {
        let runningTool = ChatHistoryItem(
            id: "tool-1",
            type: .toolCall(ToolCallItem(
                name: "run_command",
                input: ["CommandLine": "swift test"],
                status: .running,
                result: nil,
                structuredResult: nil,
                subagentTools: []
            )),
            timestamp: Date()
        )
        let session = SessionState(
            sessionId: "agy-1",
            provider: .antigravity,
            cwd: "/tmp/nook",
            projectName: "nook",
            phase: .processing,
            chatItems: [runningTool]
        )

        let normalStop = AntigravitySessionStateReducer.reduce(
            existingSession: session,
            sessionId: "agy-1",
            event: .stop(cwd: "/tmp/nook", terminationReason: "NO_TOOL_CALL", error: nil)
        )
        XCTAssertEqual(normalStop.session?.phase, .idle)
        XCTAssertNotNil(normalStop.session?.completionNotificationAt)
        if case .toolCall(let tool) = normalStop.session?.chatItems.first?.type {
            XCTAssertEqual(tool.status, .success)
        } else {
            XCTFail("Expected toolCall item")
        }

        let canceledStop = AntigravitySessionStateReducer.reduce(
            existingSession: session,
            sessionId: "agy-1",
            event: .stop(cwd: "/tmp/nook", terminationReason: "USER_CANCELED", error: nil)
        )
        XCTAssertEqual(canceledStop.session?.phase, .idle)
        XCTAssertNil(canceledStop.session?.completionNotificationAt)
        if case .toolCall(let tool) = canceledStop.session?.chatItems.first?.type {
            XCTAssertEqual(tool.status, .interrupted)
        } else {
            XCTFail("Expected toolCall item")
        }

        let errorStop = AntigravitySessionStateReducer.reduce(
            existingSession: session,
            sessionId: "agy-1",
            event: .stop(cwd: "/tmp/nook", terminationReason: "ERROR", error: "boom")
        )
        XCTAssertEqual(errorStop.session?.phase, .idle)
        XCTAssertNil(errorStop.session?.completionNotificationAt)
        if case .toolCall(let tool) = errorStop.session?.chatItems.first?.type {
            XCTAssertEqual(tool.status, .error)
        } else {
            XCTFail("Expected toolCall item")
        }
    }

    func testReducerIgnoresProviderMismatch() {
        let claudeSession = SessionState(
            sessionId: "shared-id",
            provider: .claude,
            cwd: "/tmp/nook",
            projectName: "nook",
            phase: .processing
        )

        let result = AntigravitySessionStateReducer.reduce(
            existingSession: claudeSession,
            sessionId: "shared-id",
            event: .processingStarted(cwd: "/tmp/nook")
        )
        XCTAssertNil(result.session)
        XCTAssertFalse(result.didCreateSession)
    }

    // MARK: - ToolKind Classification

    func testToolKindClassifiesAntigravityTools() {
        XCTAssertEqual(ToolKind.classify("run_command"), .bash)
        XCTAssertEqual(ToolKind.classify("read_file"), .read)
        XCTAssertEqual(ToolKind.classify("view_file"), .read)
        XCTAssertEqual(ToolKind.classify("edit_file"), .edit)
        XCTAssertEqual(ToolKind.classify("write_file"), .write)
        XCTAssertEqual(ToolKind.classify("grep_search"), .grep)
        XCTAssertEqual(ToolKind.classify("find_by_name"), .glob)
        XCTAssertEqual(ToolKind.classify("invoke_subagent"), .task)
        XCTAssertEqual(ToolKind.classify("search_web"), .webSearch)
        XCTAssertEqual(ToolKind.classify("ask_question"), .askUserQuestion)
    }

    // MARK: - Hook Installer

    func testHookInstallerInstallsAndUninstallsPreservingUserHooks() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("nook-agy-installer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let hooksFile = tempDir.appendingPathComponent("hooks.json")
        let existingUserHooks: [String: Any] = [
            "my-custom-lint": [
                "PostToolUse": [
                    [
                        "matcher": "edit_file",
                        "hooks": [["type": "command", "command": "./lint.sh"]]
                    ]
                ]
            ]
        ]
        let existingData = try JSONSerialization.data(withJSONObject: existingUserHooks, options: [.prettyPrinted])
        try existingData.write(to: hooksFile)

        XCTAssertFalse(AntigravityHookInstaller.isInstalled(configDir: tempDir))

        AntigravityHookInstaller.installIfNeeded(configDir: tempDir)
        XCTAssertTrue(AntigravityHookInstaller.isInstalled(configDir: tempDir))

        let installedData = try Data(contentsOf: hooksFile)
        let installedJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: installedData) as? [String: Any])
        XCTAssertNotNil(installedJSON["my-custom-lint"], "User hook group must be preserved")
        let nookGroup = try XCTUnwrap(installedJSON["nook"] as? [String: Any])
        XCTAssertEqual(nookGroup["enabled"] as? Bool, true)
        XCTAssertNotNil(nookGroup["SessionStart"] as? [[String: Any]])
        XCTAssertNotNil(nookGroup["PreInvocation"] as? [[String: Any]])
        XCTAssertNotNil(nookGroup["PostInvocation"] as? [[String: Any]])
        XCTAssertNotNil(nookGroup["Stop"] as? [[String: Any]])

        XCTAssertNil(nookGroup["PreToolUse"], "PreToolUse must be omitted so Antigravity permission prompts stay untouched")
        let postToolGroups = try XCTUnwrap(nookGroup["PostToolUse"] as? [[String: Any]])
        XCTAssertEqual(postToolGroups.first?["matcher"] as? String, "*")
        let postToolHandlers = try XCTUnwrap(postToolGroups.first?["hooks"] as? [[String: Any]])
        XCTAssertEqual(postToolHandlers.count, 1)

        AntigravityHookInstaller.uninstall(configDir: tempDir)
        XCTAssertFalse(AntigravityHookInstaller.isInstalled(configDir: tempDir))

        let afterUninstallData = try Data(contentsOf: hooksFile)
        let afterUninstallJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: afterUninstallData) as? [String: Any])
        XCTAssertNil(afterUninstallJSON["nook"])
        XCTAssertNotNil(afterUninstallJSON["my-custom-lint"], "User hook group must survive uninstall")
    }
}
