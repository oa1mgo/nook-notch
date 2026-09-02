//
//  QuestionReplyProviderRegistry.swift
//  Nook
//
//  Registry mapping each SessionProvider to its QuestionReplyProvider.
//

import Foundation

@MainActor
final class QuestionReplyProviderRegistry {
    static let shared = QuestionReplyProviderRegistry()
    private var providers: [SessionProvider: any QuestionReplyProvider] = [:]

    func register(_ provider: any QuestionReplyProvider) {
        providers[provider.provider] = provider
    }

    func provider(for session: SessionState) throws -> any QuestionReplyProvider {
        guard let p = providers[session.provider] else {
            throw QuestionReplyError.unsupportedProvider
        }
        return p
    }
}
