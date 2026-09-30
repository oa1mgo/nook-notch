import XCTest
@testable import Nook

/// 2026-09-28 question-page keyboard bug:
///
/// ShortcutManager's local monitor (installed first at app start) consumed
/// the default ⌃N/⌃P/Enter/⌃R combos before QuestionPanelView's monitor
/// could see them, and `handleShortcutAction` ignores those actions on
/// `.question` — so option navigation appeared dead (0 "keyDown
/// intercepted" lines in the debug log). `isOwnedByQuestionPanel` marks
/// the actions that must yield to the panel.
///
/// Note: the reply-trigger lifecycle (keyboardReplyTrigger cleared in
/// notchOpen/navigateBack/exitChat, consumed in SessionListView.onReceive)
/// is NOT covered here — instantiating @MainActor NotchViewModel in the
/// XCTest host process crashes in its deinit
/// (BUG_IN_CLIENT_OF_LIBMALLOC inside swift_task_deinitOnExecutorImpl).
/// Verify by hand: ⌃R into question, ⌃H back to list, panel must not bounce.
final class QuestionPanelKeyboardRoutingTests: XCTestCase {

    func testQuestionPanelOwnsNavigationAndActivationActions() {
        // ⌃P/⌃N/↑/↓/Enter: option focus + send inside the panel.
        XCTAssertTrue(ShortcutAction.selectPrevious.isOwnedByQuestionPanel)
        XCTAssertTrue(ShortcutAction.selectNext.isOwnedByQuestionPanel)
        XCTAssertTrue(ShortcutAction.enterSession.isOwnedByQuestionPanel)
        // ⌃R is a no-op while already on the panel.
        XCTAssertTrue(ShortcutAction.replyToQuestion.isOwnedByQuestionPanel)
    }

    func testGlobalActionsStillWorkOnQuestionPage() {
        // ⌃H (navigateBack) must still leave the panel; Esc (closeNotch)
        // and ⌘, stay with ShortcutManager — except Esc is re-delegated to
        // QuestionPanelView, which decides blur vs. close.
        XCTAssertFalse(ShortcutAction.toggleNotch.isOwnedByQuestionPanel)
        XCTAssertFalse(ShortcutAction.closeNotch.isOwnedByQuestionPanel)
        XCTAssertFalse(ShortcutAction.navigateBack.isOwnedByQuestionPanel)
        XCTAssertFalse(ShortcutAction.openSettings.isOwnedByQuestionPanel)
    }
}
