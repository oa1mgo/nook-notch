import XCTest
@testable import Nook

final class CursorSessionStateReducerTests: XCTestCase {
    func testProcessingStartedCreatesCursorProcessingSession() {
        let result = CursorSessionStateReducer.reduce(
            existingSession: nil,
            sessionId: "cursor-session",
            event: .processingStarted(cwd: "/tmp/project")
        )

        let session = result.session
        XCTAssertTrue(result.didCreateSession)
        XCTAssertEqual(session?.provider, .cursor)
        XCTAssertEqual(session?.cwd, "/tmp/project")
        XCTAssertEqual(session?.phase, .processing)
        XCTAssertNil(session?.completionNotificationAt)
    }

    func testCompletedStopMarksDanglingToolsSuccessfulAndKeepsCompletionMarker() throws {
        let session = SessionState(
            sessionId: "cursor-session",
            provider: .cursor,
            cwd: "/tmp/project",
            phase: .processing,
            chatItems: [makeToolItem(id: "tool", status: .running)],
            toolTracker: ToolTracker(
                inProgress: [
                    "tool": ToolInProgress(
                        id: "tool",
                        name: "Bash",
                        startTime: fixedDate(0),
                        phase: .running
                    )
                ]
            )
        )

        let result = CursorSessionStateReducer.reduce(
            existingSession: session,
            sessionId: "cursor-session",
            event: .stop(cwd: "/tmp/project", status: "completed")
        )

        let stopped = try XCTUnwrap(result.session)
        XCTAssertFalse(result.didCreateSession)
        XCTAssertEqual(stopped.phase, .idle)
        XCTAssertNotNil(stopped.completionNotificationAt)
        XCTAssertTrue(stopped.toolTracker.inProgress.isEmpty)

        guard case .toolCall(let tool) = stopped.chatItems[0].type else {
            return XCTFail("Expected tool call")
        }
        XCTAssertEqual(tool.status, .success)
    }

    func testErrorStopDoesNotCreateCompletionMarkerAndMarksDanglingToolsError() throws {
        let session = SessionState(
            sessionId: "cursor-session",
            provider: .cursor,
            cwd: "/tmp/project",
            phase: .processing,
            chatItems: [makeToolItem(id: "tool", status: .waitingForApproval)]
        )

        let result = CursorSessionStateReducer.reduce(
            existingSession: session,
            sessionId: "cursor-session",
            event: .stop(cwd: "/tmp/project", status: "error")
        )

        let stopped = try XCTUnwrap(result.session)
        XCTAssertNil(stopped.completionNotificationAt)

        guard case .toolCall(let tool) = stopped.chatItems[0].type else {
            return XCTFail("Expected tool call")
        }
        XCTAssertEqual(tool.status, .error)
    }
}
