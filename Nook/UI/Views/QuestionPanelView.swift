// QuestionPanelView.swift
// Nook
//
// Expanded notch panel for answering an AskUserQuestion (OpenCode in Phase 1;
// other providers get a "Go to Terminal" fallback). Single-question renders a
// compact card; multiple questions render a left/right swiper where EVERY card
// keeps its answer controls. Notch auto-closes when the session leaves
// .waitingForInput (SSOT), with an optimistic close after send as backup.
//
// Selection model:
//   - Each question supports multi-select when QuestionItem.multiple is true.
//   - State is `selectedAnswers: [Int: Set<String>]` — labels per question.
//   - Custom text input is hidden when QuestionItem.custom is false.
//   - Send is the ONLY way to submit; clicking an option never auto-sends.
//     (Auto-send caused mis-clicks: tapping one option in a multi-question
//     batch sent an incomplete payload, and tapping any option in a multi-
//     select question sent immediately before the user could pick more.)

import SwiftUI

struct QuestionPanelView: View {
    let session: SessionState
    let replyProvider: QuestionReplyProvider
    @ObservedObject var viewModel: NotchViewModel
    let onClose: () -> Void

    @State private var pendingQuestions: [PendingQuestion] = []
    @State private var currentIndex: Int = 0
    @State private var freeText: String = ""
    @State private var selectedAnswers: [Int: Set<String>] = [:]
    @State private var isSending: Bool = false
    @State private var errorMessage: String?

    private var context: AskUserQuestionContext? { session.pendingQuestionContext }

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            // Capability check first: the terminal-fallback path may legitimately
            // have no questions/context yet (opencode-less providers), so it must
            // still render the "Go to Terminal" button instead of spinning on
            // loadingPlaceholder forever. Only inline-answer providers gate on
            // questions being loaded.
            if !replyProvider.supportsInlineAnswer {
                terminalFallbackCard
            } else if pendingQuestions.isEmpty {
                loadingPlaceholder
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
            if pendingQuestions[currentIndex].custom {
                freeFormInput
            }
            sendBar
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
                if pendingQuestions[currentIndex].custom {
                    freeFormInput
                }
                sendBar
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
            HStack(spacing: 6) {
                Text(q.questionText).font(.system(size: 14, weight: .semibold)).foregroundColor(.white)
                    .fixedSize(horizontal: false, vertical: true)
                if q.multiple {
                    Text("可多选").font(.system(size: 9, weight: .semibold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.orange.opacity(0.25))
                        .foregroundColor(.orange)
                        .clipShape(Capsule())
                }
            }
        }
    }

    private func optionsList(questionIndex: Int) -> some View {
        let q = pendingQuestions[questionIndex]
        let selected = selectedAnswers[questionIndex] ?? []
        return VStack(spacing: 5) {
            ForEach(Array(q.options.enumerated()), id: \.offset) { optIndex, option in
                let isSelected = selected.contains(option.label)
                Button { toggleOption(questionIndex: questionIndex, label: option.label) } label: {
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
        TextField("自定义回答...", text: $freeText)
            .textFieldStyle(.plain).font(.system(size: 11))
            .padding(8).background(Color.white.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    /// Send bar — single source of truth for "submit my answers".
    /// Disabled until every question has at least one answer (selection OR
    /// custom text). Same white-pill capsule as the permission Allow button
    /// for visual consistency across the app.
    private var sendBar: some View {
        HStack {
            Spacer()
            Button { sendAnswers() } label: {
                Text("Send").font(.system(size: 11, weight: .medium))
                    .foregroundColor(.black)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(Color.white.opacity(canSend ? 0.92 : 0.35))
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(!canSend || isSending)
            .help("Send your answer to the agent")
        }
    }

    private var canSend: Bool {
        guard !pendingQuestions.isEmpty else { return false }
        for i in 0..<pendingQuestions.count {
            let q = pendingQuestions[i]
            let selected = selectedAnswers[i] ?? []
            // For single-select (multiple=false): exactly 1 selection OR custom text for this index
            // For multi-select (multiple=true): at least 1 selection OR custom text for this index
            if !q.custom {
                // No custom input allowed for this question — must pick at least one option
                if selected.isEmpty { return false }
            } else {
                // Custom input is offered; text counts as answer for currentIndex only
                if i == currentIndex && !freeText.trimmingCharacters(in: .whitespaces).isEmpty {
                    continue
                }
                if selected.isEmpty { return false }
            }
        }
        return true
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
            PendingQuestion(
                id: "q\(i)",
                questionText: q.question,
                header: q.header,
                options: q.options,
                multiple: q.multiple,
                custom: q.custom
            )
        }
    }

    /// Toggle a label in the multi-select set. Picking an option NEVER sends —
    /// the user must explicitly press Send. (Previous behaviour auto-sent on
    /// every click which caused mis-clicks in multi-question flows.)
    private func toggleOption(questionIndex: Int, label: String) {
        var set = selectedAnswers[questionIndex] ?? []
        if set.contains(label) {
            set.remove(label)
        } else {
            // Single-select questions: replace any prior selection
            if !pendingQuestions[questionIndex].multiple {
                set = [label]
            } else {
                set.insert(label)
            }
        }
        selectedAnswers[questionIndex] = set
    }

    private func sendAnswers() {
        guard canSend, !isSending else { return }
        isSending = true
        errorMessage = nil

        // Build [[String]] — one inner array per question; custom text (if any
        // and not empty) replaces the option selection for the current question.
        let answers: [[String]] = (0..<pendingQuestions.count).map { i in
            var labels = Array(selectedAnswers[i] ?? [])
            let q = pendingQuestions[i]
            if q.custom, i == currentIndex {
                let text = freeText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    labels = labels.filter { $0 != text }
                    labels.append(text)
                }
            }
            // Guarantee non-empty arrays (canSend already enforced this)
            return labels.isEmpty ? [""] : labels
        }

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