import XCTest
@testable import Nook

/// Pure-function core of the question panel: the "focus = selection" model
/// for single-select questions and the key-hint tooltip (spec 2026-09-28).
final class QuestionPanelSelectionTests: XCTestCase {

    private func question(multiple: Bool = false, custom: Bool = false) -> PendingQuestion {
        PendingQuestion(
            id: "q0",
            questionText: "Pick one",
            header: nil,
            options: [
                QuestionOption(label: "A", description: nil),
                QuestionOption(label: "B", description: nil),
                QuestionOption(label: "C", description: nil),
            ],
            multiple: multiple,
            custom: custom
        )
    }

    // MARK: - syncSingleSelection

    func testSyncReturnsFocusedLabelOnly() {
        let q = question()
        XCTAssertEqual(QuestionSelection.syncSingleSelection(q, focusedIndex: 1), ["B"])
    }

    func testSyncReturnsEmptyForMultiSelect() {
        let q = question(multiple: true)
        XCTAssertTrue(QuestionSelection.syncSingleSelection(q, focusedIndex: 1).isEmpty,
                      "multi-select keeps focus independent from selection")
    }

    func testSyncReturnsEmptyWhenFocusOutOfRange() {
        let q = question()
        XCTAssertTrue(QuestionSelection.syncSingleSelection(q, focusedIndex: 7).isEmpty,
                      "out-of-range focus must not invent a selection")
    }

    func testSyncReturnsEmptyWhenFocusIsNegative() {
        let q = question()
        XCTAssertTrue(QuestionSelection.syncSingleSelection(q, focusedIndex: -1).isEmpty,
                      "negative focus must not wrap or invent a selection")
    }

    // MARK: - showsSelectionHighlight

    func testHighlightShownForPlainSingleSelect() {
        XCTAssertTrue(QuestionSelection.showsSelectionHighlight(question(), text: ""))
    }

    func testHighlightHiddenWhenCustomTextReplacesSelection() {
        XCTAssertFalse(
            QuestionSelection.showsSelectionHighlight(question(custom: true), text: "my answer"),
            "single-select + custom + text: text REPLACES the option (sendAnswers), so the checkmark would lie"
        )
    }

    func testHighlightShownForCustomWithEmptyText() {
        XCTAssertTrue(QuestionSelection.showsSelectionHighlight(question(custom: true), text: "   "))
    }

    func testHighlightShownForCustomWithNewlineOnlyText() {
        XCTAssertTrue(
            QuestionSelection.showsSelectionHighlight(question(custom: true), text: "\n"),
            "newline-only text trims to empty, so the option is what gets submitted"
        )
    }

    func testHighlightShownForMultiSelectWithCustomText() {
        XCTAssertTrue(
            QuestionSelection.showsSelectionHighlight(question(multiple: true, custom: true), text: "extra"),
            "multi-select + custom: text is APPENDED to selections, both are sent"
        )
    }

    // MARK: - tooltipText

    func testTooltipForSingleSelect() {
        XCTAssertEqual(
            QuestionSelection.tooltipText(for: question()),
            "⌃N/⌃P 选择 · Enter 发送"
        )
    }

    func testTooltipForMultiSelect() {
        XCTAssertEqual(
            QuestionSelection.tooltipText(for: question(multiple: true)),
            "⌃N/⌃P 移动 · Space 选中 · Enter 发送"
        )
    }

    func testTooltipForSingleSelectCustom() {
        XCTAssertEqual(
            QuestionSelection.tooltipText(for: question(custom: true)),
            "⌃N/⌃P 选择 · Tab 输入 · Enter 发送"
        )
    }

    func testTooltipForMultiSelectCustom() {
        XCTAssertEqual(
            QuestionSelection.tooltipText(for: question(multiple: true, custom: true)),
            "⌃N/⌃P 移动 · Space 选中 · Tab 输入 · Enter 发送"
        )
    }

    // MARK: - rowKeyHint

    func testRowKeyHintForSingleSelect() {
        XCTAssertEqual(QuestionSelection.rowKeyHint(for: question()), "⌃N/⌃P 选择")
    }

    func testRowKeyHintForMultiSelect() {
        XCTAssertEqual(QuestionSelection.rowKeyHint(for: question(multiple: true)), "Space 选中")
    }
}
