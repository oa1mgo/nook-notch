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
    /// Per-question custom text. Keyed by question index so each question
    /// retains its own input when the user paginates between questions.
    @State private var freeTexts: [Int: String] = [:]
    @State private var selectedAnswers: [Int: Set<String>] = [:]
    @State private var isSending: Bool = false
    @State private var errorMessage: String?

    private var context: AskUserQuestionContext? { session.pendingQuestionContext }

    /// Binding to the current question's free-text input.
    private var currentFreeText: Binding<String> {
        Binding(
            get: { freeTexts[currentIndex] ?? "" },
            set: { freeTexts[currentIndex] = $0 }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            // Capability check first: the terminal-fallback path may legitimately
            // have no questions/context yet (opencode-less providers), so it must
            // still render the "Go to Terminal" button instead of spinning on
            // loadingPlaceholder forever. Only inline-answer providers gate on
            // questions being loaded.
            if !replyProvider.supportsInlineAnswer {
                terminalFallbackCard
            } else if pendingQuestions.isEmpty {
                loadingPlaceholder
            } else {
                singleQuestionCard
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

    // MARK: - Back row (matches settings pages)

    /// First row of the question card. Uses the same `MenuRow` component
    /// as ShortcutSettingsView / AgentSettingsView / PerformanceSettingsView
    /// — pixel-identical hover background, text/icon opacity, padding,
    /// and focus ring. Trailing element is the multi-question pager
    /// (‹ N/M ›) which reuses MenuRow's `trailingLabel` slot when present
    /// and an `HStack` overlay when the pager needs both arrows.
    private var backRow: some View {
        MenuRow(
            icon: "chevron.left",
            label: "Back",
            trailingIcon: nil,
            primaryTextColor: .white,
            isFocused: false,
            action: onClose
        )
    }

    // MARK: - Single

    private var singleQuestionCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Multi-question pager lives in the same row as Back so the
            // top chrome stays compact. Rendered as an overlay so MenuRow
            // owns the hover/focus styling.
            ZStack(alignment: .trailing) {
                backRow
                if pendingQuestions.count > 1 {
                    HStack(spacing: 6) {
                        PagerChevronButton(systemImage: "chevron.left", disabled: currentIndex == 0) {
                            if currentIndex > 0 { currentIndex -= 1 }
                        }
                        .help("Previous question")

                        Text("\(currentIndex + 1)/\(pendingQuestions.count)")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.white.opacity(0.85))
                            .fixedSize()

                        PagerChevronButton(systemImage: "chevron.right", disabled: currentIndex == pendingQuestions.count - 1) {
                            if currentIndex < pendingQuestions.count - 1 { currentIndex += 1 }
                        }
                        .help("Next question")
                    }
                    .padding(.trailing, 12)
                }
            }
            Divider().background(Color.white.opacity(0.06))
            VStack(alignment: .leading, spacing: 12) {
                questionTitle(pendingQuestions[currentIndex])
                // ScrollView so 1-10+ options fit. Sized to content (no
                // .frame(maxHeight: .infinity)) so a 3-option question
                // doesn't leave a blank band below — the question panel
                // shrinks to fit. When options overflow the panel cap
                // (see openedSize.height in NotchViewModel), the panel's
                // outer frame still enforces the upper bound, and SwiftUI
                // clips gracefully. The Divider + bottomActionRow stay
                // pinned at the bottom of the VStack.
                //
                // `fixedSize(horizontal: false, vertical: true)` forces
                // the ScrollView to size to its content's intrinsic
                // height instead of expanding to fill the parent VStack.
                ScrollView(.vertical, showsIndicators: true) {
                    optionsList(questionIndex: currentIndex)
                }
                .fixedSize(horizontal: false, vertical: true)
                .scrollContentBackground(.hidden)
                Divider().background(Color.white.opacity(0.08))
                bottomActionRow
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 14)
        }
    }

    // MARK: - Building blocks

    // MARK: - Building blocks

    private func questionTitle(_ q: PendingQuestion) -> some View {
        // Body title: just the question text + multi-select pill on the
        // right. Header label (e.g. "phonics 系统细节") and project name
        // moved up to `headerBar` (iOS-nav style: ‹ Header … projectName),
        // so this section is the actual question being asked.
        HStack(alignment: .top, spacing: 8) {
            Text(q.questionText)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.white)
                .fixedSize(horizontal: false, vertical: true)
            if q.multiple {
                Text("可多选")
                    .font(.system(size: 9, weight: .semibold))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.orange.opacity(0.25))
                    .foregroundColor(.orange)
                    .clipShape(Capsule())
            }
        }
    }

    private func optionsList(questionIndex: Int) -> some View {
        let q = pendingQuestions[questionIndex]
        let selected = selectedAnswers[questionIndex] ?? []
        return VStack(spacing: 4) {
            ForEach(Array(q.options.enumerated()), id: \.offset) { optIndex, option in
                let isSelected = selected.contains(option.label)
                Button { toggleOption(questionIndex: questionIndex, label: option.label) } label: {
                    HStack(spacing: 10) {
                        Text(letterLabel(for: optIndex)).font(.system(size: 10, weight: .semibold))
                            .frame(width: 20, height: 20)
                            .background(isSelected ? Color.orange.opacity(0.35) : Color.white.opacity(0.12))
                            .clipShape(Circle())
                        VStack(alignment: .leading, spacing: 1) {
                            Text(option.label)
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundColor(.white)
                                .lineLimit(1)
                            if let desc = option.description, !desc.isEmpty {
                                Text(desc)
                                    .font(.system(size: 9.5))
                                    .foregroundColor(.white.opacity(0.5))
                                    .lineLimit(1)
                            }
                        }
                        Spacer()
                        if isSelected {
                            Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundColor(.orange)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.white.opacity(isSelected ? 0.12 : 0.07))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .disabled(isSending)
            }
        }
    }

    private var freeFormInput: some View {
        // Match ChatView.inputBar style so the two text inputs feel like
        // siblings: same corner radius (20), same border stroke, same
        // padding (h14 v10 — gives ~34pt total height to match the
        // arrow.up.circle.fill button's natural height). Font is a bit
        // smaller (11 vs 13) because the question panel is narrower.
        TextField("自定义回答...", text: currentFreeText)
            .textFieldStyle(.plain)
            .font(.system(size: 11))
            .foregroundColor(.white.opacity(0.9))
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 20)
                    .fill(Color.white.opacity(0.08))
                    .overlay(
                        RoundedRectangle(cornerRadius: 20)
                            .strokeBorder(Color.white.opacity(0.1), lineWidth: 1)
                    )
            )
            .onSubmit { if canSend { sendAnswers() } }
    }

    /// Bottom action row: free-text input (if allowed) and Send button share
    /// the same row so the panel doesn't grow vertically with two stacked
    /// bars. When custom input isn't allowed, only the Send button renders.
    private var bottomActionRow: some View {
        HStack(spacing: 8) {
            if pendingQuestions[currentIndex].custom {
                freeFormInput
            }
            sendButton
        }
    }

    /// Send button — single source of truth for "submit my answers".
    /// Disabled until every question has at least one answer (selection OR
    /// custom text). Uses the same arrow.up.circle.fill SF Symbol as
    /// ChatView.inputBar's send button so the two input rows feel like
    /// siblings across the app.
    private var sendButton: some View {
        Button { sendAnswers() } label: {
            Image(systemName: "arrow.up.circle.fill")
                .font(.system(size: 28))
                .foregroundColor(canSend ? Color.white.opacity(0.94) : Color.white.opacity(0.35))
        }
        .buttonStyle(.plain)
        .disabled(!canSend || isSending)
        .help("Send your answer to the agent")
    }

    private var canSend: Bool {
        guard !pendingQuestions.isEmpty else {
            DebugLog.shared.write("[question-send] canSend=false: pendingQuestions.isEmpty")
            return false
        }
        for i in 0..<pendingQuestions.count {
            let q = pendingQuestions[i]
            let selected = selectedAnswers[i] ?? []
            let text = (freeTexts[i] ?? "").trimmingCharacters(in: .whitespaces)
            if !q.custom {
                if selected.isEmpty {
                    DebugLog.shared.write("[question-send] canSend=false: q\(i) custom=false selected.isEmpty")
                    return false
                }
            } else {
                if !text.isEmpty { continue }
                if selected.isEmpty {
                    DebugLog.shared.write("[question-send] canSend=false: q\(i) custom=true text.empty selected.isEmpty")
                    return false
                }
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
        guard canSend, !isSending else {
            DebugLog.shared.write("[question-send] BLOCKED canSend=\(canSend) isSending=\(isSending) currentIndex=\(currentIndex)")
            return
        }
        isSending = true
        errorMessage = nil
        DebugLog.shared.write("[question-send] START session=\(session.sessionId.prefix(8)) requestID=\(context?.requestId ?? "<nil>") questions=\(pendingQuestions.count) answers=\(freeTexts)")

        // Build [[String]] — one inner array per question.
        // For single-select: custom text replaces any option selection.
        // For multi-select: custom text is appended to selections.
        let answers: [[String]] = (0..<pendingQuestions.count).map { i in
            let q = pendingQuestions[i]
            let text = (freeTexts[i] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if q.custom, !text.isEmpty {
                if q.multiple {
                    // Multi-select: custom text alongside selections
                    var labels = Array(selectedAnswers[i] ?? [])
                    labels = labels.filter { $0 != text }
                    labels.append(text)
                    return labels
                } else {
                    // Single-select: custom text replaces option selection
                    return [text]
                }
            }
            var labels = Array(selectedAnswers[i] ?? [])
            return labels.isEmpty ? [""] : labels
        }

        Task {
            do {
                DebugLog.shared.write("[question-send] calling replyProvider.sendAnswer requestID=\(context?.requestId ?? "<nil>") answers=\(answers)")
                try await replyProvider.sendAnswer(
                    sessionId: session.sessionId,
                    requestId: context?.requestId,
                    questions: context?.questions ?? [],
                    answers: answers
                )
                // Transport is fire-and-forget; the .onChange(phase) is the SSOT
                // for closing. Optimistic close here as a backup (idempotent).
                DebugLog.shared.write("[question-send] OK — closing notch")
                await MainActor.run { viewModel.notchClose(restorePreviousApp: false) }
            } catch {
                DebugLog.shared.write("[question-send] FAILED: \(error.localizedDescription)")
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

// MARK: - Pager Chevron Button

private struct PagerChevronButton: View {
    let systemImage: String
    let disabled: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button {
            action()
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(foreground)
                .frame(width: 18, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isHovered && !disabled ? Color.white.opacity(0.12) : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .disabled(disabled)
    }

    private var foreground: Color {
        if disabled { return .white.opacity(0.15) }
        if isHovered { return .white }
        return .white.opacity(0.65)
    }
}