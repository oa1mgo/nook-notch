import Combine
import XCTest
@testable import Nook

/// Suspend the parser at its I/O boundary so lifecycle transitions can be
/// exercised deterministically, without files, sleeps, or a live Claude process.
@MainActor
final class SessionStoreClaudeReadTests: XCTestCase {
    func testEndedSessionRejectsAnInFlightHistoryResult() async throws {
        let (store, reader) = makeStore()
        await startSession(store)
        let finished = begin("history load") {
            await store.process(.loadHistory(sessionId: "session", cwd: "/tmp/project"))
        }
        let request = try await nextRead(reader, number: 1)

        await store.process(.sessionEnded(sessionId: "session"))
        await reader.complete(request.id, with: snapshot(["stale"]))
        await fulfillment(of: [finished], timeout: 2)

        let session = await store.session(for: "session")
        let resources = await store.sessionResourceIDsForTesting()
        XCTAssertNil(session)
        XCTAssertTrue(resources.isEmpty)
    }

    func testOldResultCannotOverwriteRecreatedSessionWithTheSameID() async throws {
        let (store, reader) = makeStore()
        await startSession(store)
        let oldFinished = begin("old history") {
            await store.process(.loadHistory(sessionId: "session", cwd: "/tmp/project"))
        }
        let oldRead = try await nextRead(reader, number: 1)
        await store.process(.sessionEnded(sessionId: "session"))
        await startSession(store)
        let freshFinished = begin("recreated history") {
            await store.process(.loadHistory(sessionId: "session", cwd: "/tmp/project"))
        }
        let freshRead = try await nextRead(reader, number: 2)
        XCTAssertTrue(freshRead.startsFromBeginning)
        await reader.complete(freshRead.id, with: snapshot(["fresh"]))
        await fulfillment(of: [freshFinished], timeout: 2)
        await reader.complete(oldRead.id, with: snapshot(["stale"]))
        await fulfillment(of: [oldFinished], timeout: 2)

        let session = await store.session(for: "session")
        XCTAssertEqual(session?.chatItems.map(\.id), ["fresh-text-0"])
        XCTAssertEqual(session?.conversationInfo.lastMessage, "fresh")
    }

    func testResetInvalidatesReadsEvenWhenTheSameSessionIsRegisteredAgain() async throws {
        let (store, reader) = makeStore()
        await startSession(store)
        let oldFinished = begin("pre-reset history") {
            await store.process(.loadHistory(sessionId: "session", cwd: "/tmp/project"))
        }
        let oldRead = try await nextRead(reader, number: 1)
        await store.resetForTesting()
        await startSession(store)
        let freshFinished = begin("post-reset history") {
            await store.process(.loadHistory(sessionId: "session", cwd: "/tmp/project"))
        }
        let freshRead = try await nextRead(reader, number: 2)
        XCTAssertTrue(freshRead.startsFromBeginning)
        await reader.complete(freshRead.id, with: snapshot(["after-reset"]))
        await fulfillment(of: [freshFinished], timeout: 2)
        await reader.complete(oldRead.id, with: snapshot(["before-reset"]))
        await fulfillment(of: [oldFinished], timeout: 2)

        let session = await store.session(for: "session")
        XCTAssertEqual(session?.chatItems.map(\.id), ["after-reset-text-0"])
    }

    func testClearInvalidatesTheReadFromBeforeClear() async throws {
        let (store, reader) = makeStore()
        await startSession(store)
        let oldFinished = begin("pre-clear sync") {
            await store.process(.syncHistory(sessionId: "session", cwd: "/tmp/project"))
        }
        let oldRead = try await nextRead(reader, number: 1)
        await store.process(.clearDetected(sessionId: "session"))
        let freshRead = try await nextRead(reader, number: 2)
        XCTAssertTrue(freshRead.startsFromBeginning)
        await reader.complete(freshRead.id, with: snapshot(["after-clear"]))
        await waitForSync(store)
        await reader.complete(oldRead.id, with: snapshot(["before-clear"]))
        await fulfillment(of: [oldFinished], timeout: 2)

        let session = await store.session(for: "session")
        XCTAssertEqual(session?.chatItems.map(\.id), ["after-clear-text-0"])
        XCTAssertEqual(session?.conversationInfo.lastMessage, "after-clear")
    }

    func testHistoryResultMergesContentWithoutOverwritingANewerHookPhase() async throws {
        let (store, reader) = makeStore()
        await startSession(store)
        let finished = begin("sync during hook transition") {
            await store.process(.syncHistory(sessionId: "session", cwd: "/tmp/project"))
        }
        let request = try await nextRead(reader, number: 1)
        await store.process(.hookReceived(hook(event: "PreCompact", status: "compacting")))
        let afterHook = await store.session(for: "session")
        await reader.complete(request.id, with: snapshot(["history"]))
        await fulfillment(of: [finished], timeout: 2)

        let session = await store.session(for: "session")
        XCTAssertEqual(session?.phase, .compacting)
        XCTAssertEqual(session?.lastActivity, afterHook?.lastActivity)
        XCTAssertEqual(session?.chatItems.map(\.id), ["history-text-0"])
    }

    func testHooksDuringAReadCoalesceIntoOneFollowupWithoutLosingContent() async throws {
        let (store, reader) = makeStore()
        await startSession(store)
        await store.process(.hookReceived(hook(event: "UserPromptSubmit", status: "processing")))
        let first = try await nextRead(reader, number: 1)
        await store.process(.hookReceived(hook(event: "PostToolUse", status: "processing")))
        await store.process(.hookReceived(hook(event: "PostToolUse", status: "processing")))
        let whileSuspended = await reader.requests
        XCTAssertEqual(whileSuspended.count, 1, "The in-flight read must not be cancelled/replaced by each hook")
        await reader.complete(first.id, with: snapshot(["A"]))
        let second = try await nextRead(reader, number: 2)
        XCTAssertFalse(second.startsFromBeginning, "The next pass continues from the accepted cursor")
        await reader.complete(second.id, with: snapshot(["A", "B"], newIDs: ["B"]))
        await waitForSync(store)

        let session = await store.session(for: "session")
        let requests = await reader.requests
        let maximum = await reader.maximumActiveReadsBySession
        XCTAssertEqual(session?.chatItems.map(\.id), ["A-text-0", "B-text-0"])
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(maximum["session"], 1)
    }

    func testIndependentSessionsCanReadConcurrentlyAndKeepTheirResultsSeparate() async throws {
        let (store, reader) = makeStore()
        await startSession(store, sessionId: "A")
        await startSession(store, sessionId: "B")
        let aFinished = begin("A history") {
            await store.process(.loadHistory(sessionId: "A", cwd: "/tmp/project"))
        }
        let first = try await nextRead(reader, number: 1)
        let bFinished = begin("B history") {
            await store.process(.loadHistory(sessionId: "B", cwd: "/tmp/project"))
        }
        let second = try await nextRead(reader, number: 2)
        XCTAssertEqual(first.sessionId, "A")
        XCTAssertEqual(second.sessionId, "B")
        await store.process(.sessionEnded(sessionId: "A"))
        await reader.complete(second.id, with: snapshot(["B-message"]))
        await fulfillment(of: [bFinished], timeout: 2)
        await reader.complete(first.id, with: snapshot(["A-stale"]))
        await fulfillment(of: [aFinished], timeout: 2)

        let a = await store.session(for: "A")
        let b = await store.session(for: "B")
        XCTAssertNil(a)
        XCTAssertEqual(b?.chatItems.map(\.id), ["B-message-text-0"])
    }

    func testMissingAndNonClaudeSessionsNeverEnterTheClaudeReader() async {
        let (store, reader) = makeStore()
        await store.process(.cursorSessionStarted(sessionId: "cursor", cwd: "/tmp/project"))
        let finished = begin("ignore unsupported reads") {
            for sessionId in ["missing", "cursor"] {
                await store.process(.loadHistory(sessionId: sessionId, cwd: "/tmp/project"))
                await store.process(.syncHistory(sessionId: sessionId, cwd: "/tmp/project"))
            }
        }
        await fulfillment(of: [finished], timeout: 2)
        let requests = await reader.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testChatHistoryManagerSyncUsesTheInjectedStoreReader() async throws {
        let (store, reader) = makeStore()
        await startSession(store)
        let manager = ChatHistoryManager(store: store)
        let projected = expectation(description: "manager publishes synced history")
        let subscription = manager.$histories
            .filter { $0["session"]?.map(\.id) == ["through-store-text-0"] }
            .prefix(1)
            .sink { _ in projected.fulfill() }
        defer { subscription.cancel() }
        let finished = begin("manager sync") {
            await manager.syncFromFile(sessionId: "session", cwd: "/tmp/project")
        }
        let request = try await nextRead(reader, number: 1)
        XCTAssertTrue(request.startsFromBeginning)
        await reader.complete(request.id, with: snapshot(["through-store"]))
        await fulfillment(of: [finished, projected], timeout: 2)
        let session = await store.session(for: "session")
        XCTAssertNotNil(session?.toolTracker.lastSyncTime, "syncFromFile retains file-sync effects")
    }

    func testSubagentReadMergesIntoLatestParentAndPreservesNewItems() async throws {
        let (store, reader) = makeStore()
        await startSession(store)
        await store.process(.chatItemUpdate(ChatItemUpdate(
            id: "parent", sessionId: "session", block: .toolCall(makeToolCall(id: "parent", name: "Task")),
            ordering: .appendOrder, mutation: .insert, provider: .claude
        )))
        let finished = begin("sync with subagent I/O") {
            await store.process(.syncHistory(sessionId: "session", cwd: "/tmp/project"))
        }
        let request = try await nextRead(reader, number: 1)
        let parent = ChatMessage(
            id: "parent-message", role: .assistant, timestamp: fixedDate(1),
            content: [.toolUse(ToolUseBlock(id: "parent", name: "Task", input: ["description": "Read files"]))]
        )
        let taskResult = TaskResult(
            agentId: "agent", status: "completed", content: "done", prompt: nil,
            totalDurationMs: nil, totalTokens: nil, totalToolUseCount: nil
        )
        let fileSnapshot = ClaudeConversationSnapshot(
            newMessages: [parent], allMessages: [parent], completedToolIds: [], toolResults: [:],
            structuredResults: ["parent": .task(taskResult)],
            conversationInfo: snapshot([]).conversationInfo,
            clearDetected: false, cursor: ClaudeConversationCursor()
        )
        await reader.complete(request.id, with: fileSnapshot)
        let subagentArrived = expectation(description: "subagent read suspended")
        await reader.observeSubagentRead(number: 1, expectation: subagentArrived)
        await fulfillment(of: [subagentArrived], timeout: 2)

        await store.process(.toolCompleted(
            sessionId: "session", toolUseId: "parent",
            result: ToolCompletionResult(status: .error, result: "new failure", structuredResult: nil)
        ))
        await store.process(.hookReceived(hook(event: "PreCompact", status: "compacting")))
        await store.process(.chatItemUpdate(ChatItemUpdate(
            id: "new-item", sessionId: "session", block: .assistantText("arrived during subagent read"),
            ordering: .appendOrder, mutation: .insert, provider: .claude
        )))
        await reader.completeSubagentRead(1, with: [ConversationParser.SubagentToolInfo(
            id: "child", name: "Read", input: ["file_path": "/tmp/example"],
            isCompleted: true, timestamp: nil
        )])
        await fulfillment(of: [finished], timeout: 2)

        let session = await store.session(for: "session")
        XCTAssertEqual(session?.phase, .compacting)
        XCTAssertEqual(session?.chatItems.map(\.id), ["parent", "new-item"])
        guard let item = session?.chatItems.first, case .toolCall(let tool) = item.type else {
            return XCTFail("Expected the parent tool to remain")
        }
        XCTAssertEqual(tool.status, .error)
        XCTAssertEqual(tool.result, "new failure")
        XCTAssertEqual(tool.subagentTools.map(\.id), ["child"])
        XCTAssertEqual(tool.subagentTools.first?.status, .success)
    }

    func testOldReadFinishingCannotRemoveTheRecreatedSessionsActiveFlight() async throws {
        let (store, reader) = makeStore()
        await startSession(store)
        let oldFinished = begin("old generation") {
            await store.process(.loadHistory(sessionId: "session", cwd: "/tmp/project"))
        }
        let oldRead = try await nextRead(reader, number: 1)
        await store.process(.sessionEnded(sessionId: "session"))
        await startSession(store)
        let freshFinished = begin("new generation") {
            await store.process(.loadHistory(sessionId: "session", cwd: "/tmp/project"))
        }
        let freshRead = try await nextRead(reader, number: 2)
        await reader.complete(oldRead.id, with: snapshot(["stale"]))
        await fulfillment(of: [oldFinished], timeout: 2)

        await store.process(.hookReceived(hook(event: "PostToolUse", status: "processing")))
        await waitForPendingRead(store, fullHistory: false, appliesSyncEffects: true)
        let readsWhileFreshIsSuspended = await reader.requests
        XCTAssertEqual(readsWhileFreshIsSuspended.count, 2,
                       "The old flight's defer must not remove the replacement's task handle")
        await reader.complete(freshRead.id, with: snapshot(["fresh"]))
        let followup = try await nextRead(reader, number: 3)
        await reader.complete(followup.id, with: snapshot(["fresh", "followup"], newIDs: ["followup"]))
        await fulfillment(of: [freshFinished], timeout: 2)
        let session = await store.session(for: "session")
        XCTAssertEqual(session?.chatItems.map(\.id), ["fresh-text-0", "followup-text-0"])
    }

    func testHistoryAndHookRequestsMergeFullContentAndSyncEffects() async throws {
        let (store, reader) = makeStore()
        await startSession(store)
        await store.process(.hookReceived(hook(event: "UserPromptSubmit", status: "processing")))
        let first = try await nextRead(reader, number: 1)
        let historyFinished = begin("history queued during incremental read") {
            await store.process(.loadHistory(sessionId: "session", cwd: "/tmp/project"))
        }
        await waitForPendingRead(store, fullHistory: true, appliesSyncEffects: false)
        await store.process(.hookReceived(hook(event: "PostToolUse", status: "processing")))
        await waitForPendingRead(store, fullHistory: true, appliesSyncEffects: true)
        await reader.complete(first.id, with: snapshot(["A"]))
        let second = try await nextRead(reader, number: 2)
        await reader.complete(second.id, with: snapshot(["A", "history-only", "B"], newIDs: ["B"]))
        await fulfillment(of: [historyFinished], timeout: 2)

        let session = await store.session(for: "session")
        let requests = await reader.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(session?.chatItems.map(\.id), ["A-text-0", "history-only-text-0", "B-text-0"])
        XCTAssertEqual(session?.phase, .processing)
        XCTAssertNotNil(session?.toolTracker.lastSyncTime)
    }

    func testClearReportedByContentOnlyHistoryPreservesLiveTrackingAndPhase() async throws {
        let (store, reader) = makeStore()
        await startSession(store)
        await store.process(.hookReceived(hook(
            event: "PreToolUse", status: "running_tool", tool: "Agent", toolUseId: "live-agent"
        )))
        let seed = try await nextRead(reader, number: 1)
        await reader.complete(seed.id, with: snapshot([]))
        await waitForSync(store)
        let before = await store.session(for: "session")
        XCTAssertNotNil(before?.toolTracker.inProgress["live-agent"])
        XCTAssertNotNil(before?.subagentState.activeTasks["live-agent"])

        let finished = begin("content-only history reporting clear") {
            await store.process(.loadHistory(sessionId: "session", cwd: "/tmp/project"))
        }
        let request = try await nextRead(reader, number: 2)
        await reader.complete(request.id, with: snapshot(["after-clear"], clearDetected: true))
        await fulfillment(of: [finished], timeout: 2)
        let after = await store.session(for: "session")
        XCTAssertEqual(after?.phase, before?.phase)
        XCTAssertEqual(after?.toolTracker, before?.toolTracker)
        XCTAssertEqual(after?.subagentState, before?.subagentState)
        XCTAssertEqual(after?.needsClearReconciliation, true)
    }

    func testClearSyncPreservesTrackingCreatedByAHookDuringTheRead() async throws {
        let (store, reader) = makeStore()
        await startSession(store)
        let finished = begin("clear sync with newer live tool") {
            await store.process(.syncHistory(sessionId: "session", cwd: "/tmp/project"))
        }
        let request = try await nextRead(reader, number: 1)
        await store.process(.hookReceived(hook(
            event: "PreToolUse", status: "running_tool", tool: "Agent", toolUseId: "new-agent"
        )))
        let duringRead = await store.session(for: "session")
        XCTAssertTrue(duringRead?.chatItems.isEmpty == true, "Claude hooks do not create chat placeholders")
        await reader.complete(request.id, with: snapshot([], clearDetected: true))
        let followup = try await nextRead(reader, number: 2)
        let afterClearCommit = await store.session(for: "session")
        XCTAssertNotNil(afterClearCommit?.toolTracker.inProgress["new-agent"])
        XCTAssertNotNil(afterClearCommit?.subagentState.activeTasks["new-agent"])
        XCTAssertEqual(afterClearCommit?.phase, .processing)
        await reader.complete(followup.id, with: snapshot([]))
        await fulfillment(of: [finished], timeout: 2)
        let final = await store.session(for: "session")
        XCTAssertNotNil(final?.toolTracker.inProgress["new-agent"])
        XCTAssertNotNil(final?.subagentState.activeTasks["new-agent"])
    }

    func testSubagentResultCannotResurrectStateAfterSessionEndAndRecreation() async throws {
        let (store, reader) = makeStore()
        await startSession(store)
        let finished = begin("old generation subagent sync") {
            await store.process(.syncHistory(sessionId: "session", cwd: "/tmp/project"))
        }
        let request = try await nextRead(reader, number: 1)
        let parent = ChatMessage(
            id: "old-parent", role: .assistant, timestamp: fixedDate(1),
            content: [.toolUse(ToolUseBlock(id: "parent", name: "Agent", input: ["description": "stale description"]))]
        )
        await reader.complete(request.id, with: ClaudeConversationSnapshot(
            newMessages: [parent], allMessages: [parent], completedToolIds: [], toolResults: [:],
            structuredResults: ["parent": .task(TaskResult(
                agentId: "old-agent", status: "completed", content: "old output", prompt: nil,
                totalDurationMs: nil, totalTokens: nil, totalToolUseCount: nil
            ))],
            conversationInfo: snapshot(["stale metadata"]).conversationInfo,
            clearDetected: false, cursor: ClaudeConversationCursor()
        ))
        let subagentArrived = expectation(description: "old generation subagent read suspended")
        await reader.observeSubagentRead(number: 1, expectation: subagentArrived)
        await fulfillment(of: [subagentArrived], timeout: 2)

        await store.process(.sessionEnded(sessionId: "session"))
        await startSession(store)
        await reader.completeSubagentRead(1, with: [ConversationParser.SubagentToolInfo(
            id: "stale-child", name: "Read", input: [:], isCompleted: true, timestamp: nil
        )])
        await fulfillment(of: [finished], timeout: 2)

        let recreated = await store.session(for: "session")
        XCTAssertEqual(recreated?.phase, .idle)
        XCTAssertTrue(recreated?.chatItems.isEmpty == true)
        XCTAssertTrue(recreated?.subagentState.agentDescriptions.isEmpty == true)
        XCTAssertNil(recreated?.toolTracker.lastSyncTime)
        XCTAssertNil(recreated?.conversationInfo.lastMessage)
    }

    func testResultOnlyIncrementalSyncCompletesRunningToolWithoutRollingBackNewPhase() async throws {
        let (store, reader) = makeStore()
        await startSession(store)
        await store.process(.chatItemUpdate(ChatItemUpdate(
            id: "tool", sessionId: "session", block: .toolCall(makeToolCall(id: "tool")),
            ordering: .appendOrder, mutation: .insert, provider: .claude
        )))
        await store.process(.hookReceived(hook(event: "UserPromptSubmit", status: "processing")))
        let seed = try await nextRead(reader, number: 1)
        await reader.complete(seed.id, with: snapshot([]))
        await waitForSync(store)

        await store.process(.hookReceived(hook(event: "PostToolUse", status: "processing")))
        let request = try await nextRead(reader, number: 2)
        XCTAssertFalse(request.startsFromBeginning)
        await store.process(.hookReceived(hook(event: "PreCompact", status: "compacting")))
        await reader.complete(request.id, with: ClaudeConversationSnapshot(
            newMessages: [], allMessages: [], completedToolIds: ["tool"],
            toolResults: ["tool": ConversationParser.ToolResult(
                content: "result arrived without a new message", stdout: nil, stderr: nil, isError: false
            )],
            structuredResults: [:], conversationInfo: snapshot([]).conversationInfo,
            clearDetected: false, cursor: ClaudeConversationCursor()
        ))
        await waitForSync(store)

        let session = await store.session(for: "session")
        XCTAssertEqual(session?.phase, .compacting)
        guard let item = session?.chatItems.first, case .toolCall(let tool) = item.type else {
            return XCTFail("Expected the existing tool")
        }
        XCTAssertEqual(tool.status, .success)
        XCTAssertEqual(tool.result, "result arrived without a new message")
    }

    private func makeStore() -> (SessionStore, GatedClaudeConversationReader) {
        let reader = GatedClaudeConversationReader()
        let store = SessionStore(claudeReader: reader, claudeSyncDebounceNs: 0)
        addTeardownBlock {
            await store.resetForTesting()
            await reader.close()
        }
        return (store, reader)
    }

    private func startSession(_ store: SessionStore, sessionId: String = "session") async {
        await store.process(.hookReceived(hook(sessionId: sessionId, event: "SessionStart", status: "idle")))
    }

    private func hook(
        sessionId: String = "session", event: String, status: String,
        tool: String? = nil, toolUseId: String? = nil
    ) -> HookEvent {
        HookEvent(
            sessionId: sessionId, cwd: "/tmp/project", event: event, status: status,
            pid: nil, tty: nil, tool: tool, toolInput: nil, toolUseId: toolUseId,
            notificationType: nil, message: nil
        )
    }

    private func snapshot(
        _ ids: [String], newIDs: [String]? = nil, clearDetected: Bool = false
    ) -> ClaudeConversationSnapshot {
        func messages(_ ids: [String]) -> [ChatMessage] {
            ids.map { ChatMessage(id: $0, role: .assistant, timestamp: fixedDate(1), content: [.text($0)]) }
        }
        return ClaudeConversationSnapshot(
            newMessages: messages(newIDs ?? ids), allMessages: messages(ids),
            completedToolIds: [], toolResults: [:], structuredResults: [:],
            conversationInfo: ConversationInfo(
                summary: nil, lastMessage: ids.last, lastMessageRole: "assistant",
                lastToolName: nil, firstUserMessage: nil, lastUserMessageDate: nil
            ),
            clearDetected: clearDetected, cursor: ClaudeConversationCursor()
        )
    }

    private func begin(_ description: String, action: @escaping @MainActor () async -> Void) -> XCTestExpectation {
        let finished = expectation(description: description)
        Task {
            await action()
            finished.fulfill()
        }
        return finished
    }

    private func nextRead(_ reader: GatedClaudeConversationReader, number: Int) async throws -> GatedClaudeConversationReader.Request {
        let arrived = expectation(description: "Claude read \(number) started")
        await reader.observeRead(number: number, expectation: arrived)
        await fulfillment(of: [arrived], timeout: 2)
        let request = await reader.requests.first { $0.id == number }
        return try XCTUnwrap(request, "The reader never received request \(number)")
    }

    private func waitForPendingRead(
        _ store: SessionStore, fullHistory: Bool, appliesSyncEffects: Bool
    ) async {
        let observed = expectation(description: "pending read flags are registered")
        let observer = Task {
            while !Task.isCancelled {
                if let pending = await store.pendingClaudeReadForTesting(sessionId: "session"),
                   pending.fullHistory == fullHistory,
                   pending.appliesSyncEffects == appliesSyncEffects {
                    observed.fulfill()
                    return
                }
                await Task.yield()
            }
        }
        await fulfillment(of: [observed], timeout: 2)
        observer.cancel()
    }

    private func waitForSync(_ store: SessionStore, sessionId: String = "session") async {
        let finished = begin("all requested Claude sync passes finished") {
            await store.waitForClaudeSyncForTesting(sessionId: sessionId)
        }
        await fulfillment(of: [finished], timeout: 2)
    }
}

private actor GatedClaudeConversationReader: ClaudeConversationReading {
    struct Request: Sendable {
        let id: Int
        let sessionId: String
        let startsFromBeginning: Bool
    }

    private(set) var requests: [Request] = []
    private(set) var maximumActiveReadsBySession: [String: Int] = [:]
    private var pending: [Int: CheckedContinuation<ClaudeConversationSnapshot, Never>] = [:]
    private var observers: [Int: XCTestExpectation] = [:]
    private var subagentReadCount = 0
    private var pendingSubagents: [Int: CheckedContinuation<[ConversationParser.SubagentToolInfo], Never>] = [:]
    private var subagentObservers: [Int: XCTestExpectation] = [:]
    private var isClosed = false

    func readSnapshot(sessionId: String, cwd: String, cursor: ClaudeConversationCursor?) async -> ClaudeConversationSnapshot {
        if isClosed { return Self.emptySnapshot() }
        let request = Request(id: requests.count + 1, sessionId: sessionId, startsFromBeginning: cursor == nil)
        requests.append(request)
        return await withCheckedContinuation { continuation in
            pending[request.id] = continuation
            let active = requests.filter { $0.sessionId == sessionId && pending[$0.id] != nil }.count
            maximumActiveReadsBySession[sessionId] = max(maximumActiveReadsBySession[sessionId] ?? 0, active)
            observers.removeValue(forKey: request.id)?.fulfill()
        }
    }

    func readSubagentTools(sessionId: String, agentId: String, cwd: String) async -> [ConversationParser.SubagentToolInfo] {
        if isClosed { return [] }
        subagentReadCount += 1
        let number = subagentReadCount
        return await withCheckedContinuation { continuation in
            pendingSubagents[number] = continuation
            subagentObservers.removeValue(forKey: number)?.fulfill()
        }
    }

    func observeSubagentRead(number: Int, expectation: XCTestExpectation) {
        if subagentReadCount >= number {
            expectation.fulfill()
        } else {
            subagentObservers[number] = expectation
        }
    }

    func completeSubagentRead(_ number: Int, with tools: [ConversationParser.SubagentToolInfo]) {
        pendingSubagents.removeValue(forKey: number)?.resume(returning: tools)
    }

    func observeRead(number: Int, expectation: XCTestExpectation) {
        if requests.contains(where: { $0.id == number }) {
            expectation.fulfill()
        } else {
            observers[number] = expectation
        }
    }

    func complete(_ id: Int, with snapshot: ClaudeConversationSnapshot) {
        pending.removeValue(forKey: id)?.resume(returning: snapshot)
    }

    func close() {
        isClosed = true
        for continuation in pending.values {
            continuation.resume(returning: Self.emptySnapshot())
        }
        pending.removeAll()
        observers.removeAll()
        for continuation in pendingSubagents.values {
            continuation.resume(returning: [])
        }
        pendingSubagents.removeAll()
        subagentObservers.removeAll()
    }

    private static func emptySnapshot() -> ClaudeConversationSnapshot {
        ClaudeConversationSnapshot(
            newMessages: [], allMessages: [], completedToolIds: [], toolResults: [:], structuredResults: [:],
            conversationInfo: ConversationInfo(
                summary: nil, lastMessage: nil, lastMessageRole: nil,
                lastToolName: nil, firstUserMessage: nil, lastUserMessageDate: nil
            ),
            clearDetected: false, cursor: ClaudeConversationCursor()
        )
    }
}
