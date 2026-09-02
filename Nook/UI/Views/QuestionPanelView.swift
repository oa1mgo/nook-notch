// QuestionPanelView.swift
// Nook
//
// Expanded notch panel for answering an AskUserQuestion (OpenCode in Phase 1;
// other providers get a "Go to Terminal" fallback). Single-question renders a
// compact card; multiple questions render a left/right swiper where EVERY card
// keeps its answer controls. Notch auto-closes when the session leaves
// .waitingForInput (SSOT), with an optimistic close after send as backup.

import SwiftUI

struct QuestionPanelView: View {
    let session: SessionState
    let replyProvider: QuestionReplyProvider
    @ObservedObject var viewModel: NotchViewModel
    let onClose: () -> Void

    @State private var pendingQuestions: [PendingQuestion] = []
    @State private var currentIndex: Int = 0
    @State private var freeText: String = ""
    @State private var selectedAnswers: [Int: String] = [:]
    @State private var isSending: Bool = false
    @State private var errorMessage: String?

    private var context: AskUserQuestionContext? { session.pendingQuestionContext }

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            if pendingQuestions.isEmpty {
                loadingPlaceholder
            } else if !replyProvider.supportsInlineAnswer {
                terminalFallbackCard
            } else if pendingQuestions.count == 1 {
                singleQuestionCard
            } else {
                multiQuestionSwiper
            }
            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 10))
                    .foregroundColor(.red.opacity(0.9))
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            }
        }
        .onAppear { loadPendingQuestions() }
        // [SSOT] Close only when the agent actually advances the phase.
        .onChange(of: session.phase) { _, newPhase in
            if newPhase != .waitingForInput { onClose() }
        }
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack {
            HStack(spacing: 6) {
                Circle().fill(Color.orange).frame(width: 18, height: 18)
                    .overlay(Text("?").font(.system(size: 11, weight: .bold)).foregroundColor(.black))
                Text("\(session.provider.rawValue.uppercased()) · QUESTION")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.orange)
            }
            Spacer()
            if replyProvider.supportsInlineAnswer {
                Text("Session · \(String(session.sessionId.prefix(6)))")
                    .font(.system(size: 9)).foregroundColor(.white.opacity(0.4))
            }
            if pendingQuestions.count > 1 {
                HStack(spacing: 4) {
                    ForEach(0..<pendingQuestions.count, id: \.self) { i in
                        Capsule().fill(i == currentIndex ? Color.orange : Color.white.opacity(0.18))
                            .frame(width: 8, height: 3)
                    }
                    Text("\(currentIndex + 1)/\(pendingQuestions.count)")
                        .font(.system(size: 9)).foregroundColor(.white.opacity(0.5))
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    // MARK: - Single

    private var singleQuestionCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            questionTitle(pendingQuestions[currentIndex])
            optionsList(questionIndex: currentIndex)
            Divider().background(Color.white.opacity(0.08))
            freeFormInput
        }
        .padding(16)
    }

    // MARK: - Multi (swiper) — top padding matches single; content indented for ‹ ›

    private var multiQuestionSwiper: some View {
        HStack(spacing: 4) {
            Button { if currentIndex > 0 { currentIndex -= 1 } } label: {
                Text("‹").font(.system(size: 20)).foregroundColor(.white.opacity(currentIndex == 0 ? 0.15 : 0.5))
            }
            .buttonStyle(.plain).disabled(currentIndex == 0)

            VStack(alignment: .leading, spacing: 12) {
                questionTitle(pendingQuestions[currentIndex])
                optionsList(questionIndex: currentIndex)
                Divider().background(Color.white.opacity(0.08))
                freeFormInput
            }
            .frame(maxWidth: .infinity)

            Button { if currentIndex < pendingQuestions.count - 1 { currentIndex += 1 } } label: {
                Text("›").font(.system(size: 20)).foregroundColor(.white.opacity(currentIndex == pendingQuestions.count - 1 ? 0.15 : 0.5))
            }
            .buttonStyle(.plain).disabled(currentIndex == pendingQuestions.count - 1)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 14)
    }

    // MARK: - Building blocks

    private func questionTitle(_ q: PendingQuestion) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            if let header = q.header {
                Text(header).font(.system(size: 9.5, weight: .semibold))
                    .foregroundColor(.white.opacity(0.4)).textCase(.uppercase)
            }
            Text(q.questionText).font(.system(size: 14, weight: .semibold)).foregroundColor(.white)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func optionsList(questionIndex: Int) -> some View {
        let q = pendingQuestions[questionIndex]
        return VStack(spacing: 5) {
            ForEach(Array(q.options.enumerated()), id: \.offset) { optIndex, option in
                let isSelected = selectedAnswers[questionIndex] == option.label
                Button { pickOption(questionIndex: questionIndex, label: option.label) } label: {
                    HStack(spacing: 10) {
                        Text(letterLabel(for: optIndex)).font(.system(size: 11, weight: .semibold))
                            .frame(width: 22, height: 22)
                            .background(isSelected ? Color.orange.opacity(0.35) : Color.white.opacity(0.12))
                            .clipShape(Circle())
                        VStack(alignment: .leading) {
                            Text(option.label).font(.system(size: 12, weight: .medium)).foregroundColor(.white)
                            if let desc = option.description, !desc.isEmpty {
                                Text(desc).font(.system(size: 10)).foregroundColor(.white.opacity(0.5))
                                    .lineLimit(2)
                            }
                        }
                        Spacer()
                        if isSelected {
                            Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundColor(.orange)
                        }
                    }
                    .padding(10)
                    .background(Color.white.opacity(isSelected ? 0.12 : 0.07))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .disabled(isSending)
            }
        }
    }

    private var freeFormInput: some View {
        HStack(spacing: 8) {
            TextField("自定义回答...", text: $freeText)
                .textFieldStyle(.plain).font(.system(size: 11))
                .padding(8).background(Color.white.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .onSubmit { sendFreeForm() }
            Button { sendFreeForm() } label: {
                Text("Send ⏎").font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(.borderedProminent).tint(.orange)
            .disabled(isSending || freeText.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    // MARK: - Terminal fallback (Claude/Codex/Cursor Phase 1)

    private var terminalFallbackCard: some View {
        VStack(spacing: 14) {
            if let q = pendingQuestions.first {
                questionTitle(q)
                Text(q.options.map(\.label).joined(separator: " · "))
                    .font(.system(size: 10)).foregroundColor(.white.opacity(0.5))
            }
            Button("Go to Terminal →") { goToTerminal() }
                .buttonStyle(.borderedProminent).tint(.orange)
        }
        .padding(16)
    }

    private var loadingPlaceholder: some View {
        VStack(spacing: 8) {
            ProgressView().tint(.white)
            Text("Loading question...").font(.system(size: 11)).foregroundColor(.white.opacity(0.5))
        }
        .frame(maxWidth: .infinity, minHeight: 160)
    }

    // MARK: - Actions

    private func loadPendingQuestions() {
        pendingQuestions = (context?.questions ?? []).enumerated().map { i, q in
            PendingQuestion(id: "q\(i)", questionText: q.question, header: q.header, options: q.options)
        }
    }

    private func pickOption(questionIndex: Int, label: String) {
        selectedAnswers[questionIndex] = label
        tryAutoSendIfComplete()
    }

    private func sendFreeForm() {
        let text = freeText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        selectedAnswers[currentIndex] = text
        tryAutoSendIfComplete()
    }

    private func tryAutoSendIfComplete() {
        // Send only when every question has an answer (prevents premature partial send).
        guard selectedAnswers.count == pendingQuestions.count, !pendingQuestions.isEmpty else { return }
        let answers = (0..<pendingQuestions.count).map { selectedAnswers[$0] ?? "" }
        sendAnswers(answers)
    }

    private func sendAnswers(_ answers: [String]) {
        guard !isSending else { return }
        isSending = true
        errorMessage = nil
        Task {
            do {
                try await replyProvider.sendAnswer(
                    sessionId: session.sessionId,
                    requestId: context?.requestId,
                    questions: context?.questions ?? [],
                    answers: answers
                )
                // Transport is fire-and-forget; the .onChange(phase) is the SSOT
                // for closing. Optimistic close here as a backup (idempotent).
                await MainActor.run { viewModel.notchClose(restorePreviousApp: false) }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isSending = false
                }
            }
        }
    }

    private func goToTerminal() {
        Task {
            if let fallback = replyProvider as? TerminalFallbackProvider {
                let ok = await fallback.focusTerminalForAnswer(session: session)
                if ok { await MainActor.run { viewModel.notchClose(restorePreviousApp: false) } }
            }
        }
    }

    private func letterLabel(for index: Int) -> String {
        String(UnicodeScalar(65 + index) ?? "A")
    }
}
