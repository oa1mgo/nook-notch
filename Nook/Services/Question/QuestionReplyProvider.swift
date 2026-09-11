//
//  QuestionReplyProvider.swift
//  Nook
//
//  Protocol abstraction for sending answers back to provider question prompts.
//

import Foundation

// MARK: - QuestionReplyError

enum QuestionReplyError: LocalizedError, Equatable {
    case missingRequestId
    case unsupportedProvider
    case transportError(String)

    var errorDescription: String? {
        switch self {
        case .missingRequestId:
            return "No request ID available to reply"
        case .unsupportedProvider:
            return "Provider does not support inline answer (use Terminal)"
        case .transportError(let msg):
            return "Transport error: \(msg)"
        }
    }
}

// MARK: - QuestionReplyProvider

/// Sends answers to a provider's interactive question prompt.
///
/// Implementations are stored in `QuestionReplyProviderRegistry` keyed by
/// `SessionProvider`, and invoked from arbitrary async contexts. Conforming
/// types must therefore be `Sendable` so the registry can be shared across
/// actors without isolation hops.
protocol QuestionReplyProvider: Sendable {
    var provider: SessionProvider { get }

    /// Whether this provider can answer inline without dropping to Terminal.
    /// `false` means the caller should fall back to a Terminal UI.
    var supportsInlineAnswer: Bool { get }

    /// Deliver an answer to the provider's question prompt.
    ///
    /// Implementations may hop to any actor (e.g. a socket writer) before
    /// returning; the call must complete only after the answer has been
    /// accepted (or thrown on failure).
    ///
    /// - Parameter requestId: Provider-issued request id; `nil` indicates
    ///   the provider does not require one and the implementation should
    ///   synthesize or look up an appropriate id.
    func sendAnswer(
        sessionId: String,
        requestId: String?,
        questions: [QuestionItem],
        answers: [[String]]
    ) async throws
}