import XCTest
@testable import Nook

final class SessionStateTests: XCTestCase {
    func testTerminalApprovalExposesActivePermissionAndPendingFields() {
        let context = PermissionContext(
            toolUseId: "tool-1",
            toolName: "Bash",
            toolInput: ["command": AnyCodable("rm -rf build")],
            receivedAt: fixedDate(10)
        )
        let session = SessionState(
            sessionId: "session",
            cwd: "/tmp/project",
            phase: .waitingForTerminalApproval(context)
        )

        XCTAssertEqual(session.activePermission?.toolUseId, "tool-1")
        XCTAssertEqual(session.pendingToolId, "tool-1")
        XCTAssertEqual(session.pendingToolName, "Bash")
        XCTAssertEqual(session.pendingToolInput, "rm -rf build")
        XCTAssertTrue(session.needsAttention)
        XCTAssertTrue(session.canInteract)
    }

    func testTerminalApprovalCanTransitionBackToProcessingOrIdle() {
        let context = PermissionContext(
            toolUseId: "tool-1",
            toolName: "Bash",
            toolInput: nil,
            receivedAt: fixedDate(10)
        )
        let phase = SessionPhase.waitingForTerminalApproval(context)

        XCTAssertTrue(phase.canTransition(to: .processing))
        XCTAssertTrue(phase.canTransition(to: .idle))
        XCTAssertTrue(phase.canTransition(to: .waitingForInput))
        XCTAssertTrue(phase.isWaitingForTerminalApproval)
    }
}
