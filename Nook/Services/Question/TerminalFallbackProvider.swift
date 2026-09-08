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

    /// Focus the terminal running the session. Returns whether focus succeeded.
    /// The caller (QuestionPanelView, which owns the NotchViewModel) decides
    /// whether to close the notch — the provider must not reach into a
    /// NotchViewModel singleton.
    @MainActor
    func focusTerminalForAnswer(session: SessionState) async -> Bool {
        let ok = await TerminalFocusHelper.tryFocusTerminal(for: session)
        if !ok {
            DebugLog.shared.write("[question] focusTerminal failed")
        }
        return ok
    }
}
