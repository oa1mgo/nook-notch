// OpencodeQuestionReplyProvider.swift
// Nook
//
// Real Phase 1 answer channel for OpenCode: sends a `question.reply` command
// over the pid-scoped command socket; the plugin forwards it to opencode's
// /api/session/:id/question/:requestID/reply. Transport is fire-and-forget,
// so success is signalled back via the phase transition (see QuestionPanelView
// .onChange), not by this method returning.

import Foundation

final class OpencodeQuestionReplyProvider: QuestionReplyProvider, @unchecked Sendable {
    let provider: SessionProvider = .opencode
    let supportsInlineAnswer: Bool = true

    func sendAnswer(
        sessionId: String,
        requestId: String?,
        questions: [QuestionItem],
        answers: [String]
    ) async throws {
        guard let requestId else {
            throw QuestionReplyError.missingRequestId
        }

        let wireAnswers: [[String]] = answers.map { [$0] }
        let payload: [String: Any] = [
            "cmd": "question.reply",
            "sessionId": sessionId,
            "requestId": requestId,
            "answers": wireAnswers
        ]

        // SessionStore is an actor and `sessions` is private; the public
        // lookup is `session(for:)`, awaited directly (no MainActor hop).
        let pid = await SessionStore.shared.session(for: sessionId)?.pid

        // sendCommand is sync fire-and-forget (mirrors SessionMonitor's
        // permission.reply call sites); transport failure surfaces later via
        // the phase transition, not here.
        OpencodeCommandSocket.shared.sendCommand(payload, pid: pid)
    }
}
