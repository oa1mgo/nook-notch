// QuestionReplyProviderTests.swift
// NookTests
//
// Unit tests for the question-reply providers and registry.

import XCTest
@testable import Nook

@MainActor
final class QuestionReplyProviderTests: XCTestCase {
    private func makeSession(provider: SessionProvider) -> SessionState {
        SessionState(
            sessionId: "session-\(provider.rawValue)",
            provider: provider,
            cwd: "/tmp/project"
        )
    }

    // The registry tests are `async` on purpose: XCTest invokes synchronous
    // test methods via NSInvocation without a surrounding Swift task, and
    // releasing the @MainActor registry there crashes in
    // swift_task_deinitOnExecutor (isolated-deinit hop with no task context).
    func testRegistryReturnsRegisteredProvider() async throws {
        let registry = QuestionReplyProviderRegistry()
        registry.register(TerminalFallbackProvider(provider: .claude))

        let resolved = try registry.provider(for: makeSession(provider: .claude))
        XCTAssertFalse(resolved.supportsInlineAnswer)
        XCTAssertEqual(resolved.provider, .claude)
    }

    func testRegistryThrowsOnMissingProvider() async throws {
        let registry = QuestionReplyProviderRegistry()
        XCTAssertThrowsError(try registry.provider(for: makeSession(provider: .codex))) { error in
            XCTAssertEqual(error as? QuestionReplyError, .unsupportedProvider)
        }
    }

    func testTerminalFallbackDoesNotSupportInline() {
        XCTAssertFalse(TerminalFallbackProvider(provider: .codex).supportsInlineAnswer)
    }

    func testOpencodeSupportsInline() {
        let provider = OpencodeQuestionReplyProvider()
        XCTAssertTrue(provider.supportsInlineAnswer)
        XCTAssertEqual(provider.provider, .opencode)
    }

    func testTerminalFallbackSendAnswerThrows() async throws {
        let question = QuestionItem(
            question: "Pick one",
            header: "Choice",
            options: [QuestionOption(label: "A", description: nil)]
        )
        do {
            try await TerminalFallbackProvider(provider: .claude).sendAnswer(
                sessionId: "session",
                requestId: "req-1",
                questions: [question],
                answers: ["A"]
            )
            XCTFail("sendAnswer should throw for terminal fallback")
        } catch {
            XCTAssertEqual(error as? QuestionReplyError, .unsupportedProvider)
        }
    }
}
