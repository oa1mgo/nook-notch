// TerminalFallbackProvider.swift
// Nook
//
// Phase 1 placeholder for providers without a programmatic answer channel
// (Claude/Codex/Cursor). Clicking an option focuses the terminal so the
// user can type; inline answer is unsupported until Phase 2 (tmux sendKeys).

import Foundation

struct TerminalFallbackProvider: QuestionReplyProvider {
    let provider: SessionProvider
    let supportsInlineAnswer: Bool = false

    func sendAnswer(
        sessionId: String,
        requestId: String?,
        questions: [QuestionItem],
        answers: [String]
    ) async throws {
        throw QuestionReplyError.unsupportedProvider
    }

    @MainActor
    func focusTerminalForAnswer(session: SessionState) {
        guard let vm = NotchViewModel.shared else {
            DebugLog.shared.write("[question] focusTerminal: no NotchViewModel.shared")
            return
        }
        Task {
            let ok = await TerminalFocusHelper.tryFocusTerminal(for: session)
            if ok {
                vm.notchClose(restorePreviousApp: false)
            } else {
                DebugLog.shared.write("[question] focusTerminal failed")
            }
        }
    }
}
