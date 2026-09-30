import XCTest
@testable import Nook

final class ToolCallItemVisibilityTests: XCTestCase {
    // MARK: - Subagent tools list visibility

    private func subagentContainer(
        status: ToolStatus,
        subagentTools: [SubagentToolCall] = [SubagentToolCall(id: "t1", name: "Bash", input: [:], status: .success, timestamp: fixedDate(0))]
    ) -> ToolCallItem {
        ToolCallItem(
            name: "Task",
            input: ["description": "do the thing"],
            status: status,
            result: nil,
            structuredResult: nil,
            subagentTools: subagentTools
        )
    }

    /// Regression: while the subagent is running, the SubagentToolsList
    /// was previously force-shown regardless of `isExpanded`. Tapping the
    /// header during running silently toggled the state but produced no
    /// visual change, so the row appeared "stuck" expanded and the user
    /// reported "展开后就没法折叠了" (once expanded, can't be folded).
    /// Visibility must now follow `isExpanded` exactly so that toggling
    /// produces a visible result at any status.
    func testSubagentContainerHidesToolsListWhenCollapsedEvenWhileRunning() {
        let tool = subagentContainer(status: .running)

        XCTAssertFalse(tool.showsSubagentToolsList(isExpanded: false))
    }

    func testSubagentContainerShowsToolsListWhenExpandedWhileRunning() {
        let tool = subagentContainer(status: .running)

        XCTAssertTrue(tool.showsSubagentToolsList(isExpanded: true))
    }

    func testSubagentContainerShowsToolsListWhenExpandedAfterCompletion() {
        for status: ToolStatus in [.success, .error, .interrupted] {
            let tool = subagentContainer(status: status)
            XCTAssertTrue(
                tool.showsSubagentToolsList(isExpanded: true),
                "expanded finished subagent (\(status)) should show its tools list"
            )
        }
    }

    func testSubagentContainerHidesToolsListWhenCollapsedAfterCompletion() {
        for status: ToolStatus in [.success, .error, .interrupted] {
            let tool = subagentContainer(status: status)
            XCTAssertFalse(
                tool.showsSubagentToolsList(isExpanded: false),
                "collapsed finished subagent (\(status)) should hide its tools list"
            )
        }
    }

    func testSubagentContainerWithNoSubToolsNeverShowsList() {
        let tool = subagentContainer(status: .running, subagentTools: [])

        XCTAssertFalse(tool.showsSubagentToolsList(isExpanded: true))
        XCTAssertFalse(tool.showsSubagentToolsList(isExpanded: false))
    }

    func testNonSubagentContainerNeverShowsList() {
        let tool = ToolCallItem(
            name: "Bash",
            input: ["command": "ls"],
            status: .success,
            result: "ok",
            structuredResult: nil,
            subagentTools: []
        )

        XCTAssertFalse(tool.showsSubagentToolsList(isExpanded: true))
        XCTAssertFalse(tool.showsSubagentToolsList(isExpanded: false))
    }

    /// Toggling the visibility for the same item must be exact negation:
    /// expanded → hidden when collapsed, hidden → expanded when expanded.
    /// This is the property that was broken: previously `running` made
    /// "hidden when collapsed" return `true`, so the user could not
    /// produce a "hidden" result by clicking during running.
    func testToggleIsExactNegationAcrossAllStatuses() {
        let statuses: [ToolStatus] = [.running, .success, .error, .interrupted]
        for status in statuses {
            let tool = subagentContainer(status: status)
            XCTAssertNotEqual(
                tool.showsSubagentToolsList(isExpanded: true),
                tool.showsSubagentToolsList(isExpanded: false),
                "toggle must be a clean on/off for status=\(status)"
            )
        }
    }
}
