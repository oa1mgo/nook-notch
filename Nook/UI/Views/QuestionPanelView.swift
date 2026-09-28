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

import OSLog
import SwiftUI

struct QuestionPanelView: View {
    let session: SessionState
    let replyProvider: QuestionReplyProvider
    @ObservedObject var viewModel: NotchViewModel
    let onClose: () -> Void

    @State private var pendingQuestions: [PendingQuestion] = []
    @State private var currentIndex: Int = 0
    @State private var freeTexts: [Int: String] = [:]
    @State private var selectedAnswers: [Int: Set<String>] = [:]
    @State private var isSending: Bool = false
    @State private var errorMessage: String?
    /// Manual focus tracking for option rows — not using @FocusState because
    /// NSPanel doesn't participate in SwiftUI's focus chain reliably.
    @State private var focusedOptionIndex: Int = 0
    /// TextField focus — kept as @FocusState so .focused() modifier works
    /// and Tab can programmatically activate it.
    @FocusState private var isTextFieldFocused: Bool
    @State private var localMonitor: Any?

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
        .padding(.bottom, 6)
    }

    // MARK: - Single

    private var singleQuestionCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Multi-question pager lives in the same row as Back so the
            // top chrome stays compact. Rendered as an overlay so MenuRow
            // owns the hover/focus styling.
            ZStack(alignment: .trailing) {
                backRow
                HStack(spacing: 6) {
                    if !pendingQuestions.isEmpty {
                        Image(systemName: "info.circle")
                            .font(.system(size: 11))
                            .foregroundColor(.white.opacity(0.4))
                            .fixedSize()
                            .help(QuestionSelection.tooltipText(for: pendingQuestions[currentIndex]))
                    }
                    if pendingQuestions.count > 1 {
                        PagerChevronButton(systemImage: "chevron.left", disabled: currentIndex == 0) {
                            goPreviousQuestion()
                        }
                        .help("Ctrl+[ Previous question")

                        Text("\(currentIndex + 1)/\(pendingQuestions.count)")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.white.opacity(0.85))
                            .fixedSize()

                        PagerChevronButton(systemImage: "chevron.right", disabled: currentIndex == pendingQuestions.count - 1) {
                            goNextQuestion()
                        }
                        .help("Ctrl+] Next question")
                    }
                }
                .padding(.trailing, 12)
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
        .onAppear {
            DebugLog.shared.log(Self.logger, "QUESTION-PANEL: onAppear fired, keyWindow=\(NSApp.keyWindow != nil)")
            // Ensure the notch window is key so keyboard events reach our monitor.
            if NSApp.keyWindow == nil {
                DebugLog.shared.log(Self.logger, "QUESTION-PANEL: no keyWindow, activating")
                NSApp.activate(ignoringOtherApps: false)
                NSApp.windows.first { $0 is NotchPanel }?.makeKey()
            }
            installKeyboardMonitor()
            if focusedOptionIndex >= pendingQuestions[currentIndex].options.count {
                focusedOptionIndex = 0
            }
            syncSelectionToFocus()
        }
        .onDisappear {
            removeKeyboardMonitor()
        }
    }

    // MARK: - Building blocks

    // MARK: - Building blocks

    private func questionTitle(_ q: PendingQuestion) -> some View {
        // Body title: question text + multi-select pill on the right.
        // Header label (e.g. "phonics 系统细节") and project name
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
        // Single-select + custom + text: the text REPLACES the selection on
        // send, so don't show a checkmark next to it.
        let showHighlight = QuestionSelection.showsSelectionHighlight(
            q,
            text: freeTexts[questionIndex] ?? ""
        )
        return VStack(spacing: 4) {
            ForEach(Array(q.options.enumerated()), id: \.offset) { optIndex, option in
                let isSelected = showHighlight && selected.contains(option.label)
                OptionRow(
                    letter: letterLabel(for: optIndex),
                    label: option.label,
                    description: option.description,
                    isSelected: isSelected,
                    isFocused: focusedOptionIndex == optIndex,
                    isSending: isSending,
                    keyHint: q.multiple ? "Space to select" : "⌃N/⌃P 选择",
                ) {
                    focusedOptionIndex = optIndex
                    if q.multiple {
                        toggleOption(questionIndex: questionIndex, label: option.label)
                    } else {
                        syncSelectionToFocus()
                    }
                }
            }
        }
    }

    private var freeFormInput: some View {
        // Match ChatView.inputBar style so the two text inputs feel like
        // siblings: same corner radius (20), same border stroke, same
        // padding (h14 v10 — gives ~34pt total height to match the
        // arrow.up.circle.fill button's natural height). Font is a bit
        // smaller (11 vs 13) because the question panel is narrower.
        TextField("Tab to type custom answer...", text: currentFreeText)
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
            .focused($isTextFieldFocused)
            .onSubmit { if canSend { sendAnswers() } }
            .help("Tab to focus · Enter to send")
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
        .help("Enter to send")
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

    // MARK: - Keyboard (AppKit local monitor — works in NSPanel)

    private static let logger = Logger(subsystem: "com.celestial.Nook", category: "QuestionPanel")

    private func installKeyboardMonitor() {
        guard localMonitor == nil else { return }
        DebugLog.shared.log(Self.logger, "QUESTION-PANEL: installKeyboardMonitor called")
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            DebugLog.shared.log(Self.logger, "QUESTION-PANEL: keyDown intercepted keyCode=\(event.keyCode) chars=\(event.charactersIgnoringModifiers ?? "?") window=\(event.window != nil)")
            return self.handleKeyDown(event)
        }
        DebugLog.shared.log(Self.logger, "QUESTION-PANEL: localMonitor installed=\(localMonitor != nil)")
    }

    private func removeKeyboardMonitor() {
        if let monitor = localMonitor {
            NSEvent.removeMonitor(monitor)
            localMonitor = nil
        }
    }

    private func handleKeyDown(_ event: NSEvent) -> NSEvent? {
        // Only handle when our panel is key window
        guard NSApp.keyWindow != nil else { return event }

        let chars = event.charactersIgnoringModifiers ?? ""
        let mods = event.modifierFlags
        let hasCtrl = mods.contains(.control)
        let hasCmd = mods.contains(.command)
        let hasShift = mods.contains(.shift)

        guard !hasCmd else { return event }

        // ── Esc: blur text field or close notch ──
        if event.keyCode == 53 { // Escape
            if isTextFieldFocused {
                // IME composition in progress: let the field editor cancel it.
                if let textView = NSApp.keyWindow?.firstResponder as? NSTextView,
                   textView.hasMarkedText() {
                    return event
                }
                isTextFieldFocused = false
                return nil
            }
            // ShortcutManager defers Esc on this page (isOwnedByQuestionPanel),
            // so closing the notch is our responsibility now.
            NotificationCenter.default.post(name: .shortcutAction, object: ShortcutAction.closeNotch)
            return nil
        }

        // ── When text field has focus, let it handle all keys ──
        // (arrow keys, typing, IME, etc.) except Esc and Ctrl shortcuts.
        if isTextFieldFocused {
            // Ctrl+[/] still navigate questions even in text field
            if hasCtrl && (chars == "[" || event.keyCode == 33) { goPreviousQuestion(); return nil }
            if hasCtrl && (chars == "]" || event.keyCode == 30) { goNextQuestion(); return nil }
            // Tab toggles back to options
            if event.keyCode == 48 { // Tab
                isTextFieldFocused = false
                return nil
            }
            // Everything else passes through to the TextField
            return event
        }

        // ── Question navigation: Ctrl+]/Ctrl+[ ──
        if hasCtrl && (chars == "]" || event.keyCode == 30) { goNextQuestion(); return nil }
        if hasCtrl && (chars == "[" || event.keyCode == 33) { goPreviousQuestion(); return nil }

        // ── Option focus: Up/Down / Ctrl+N/P ──
        if event.keyCode == 126 || (hasCtrl && chars == "p") { // Up / Ctrl+P
            moveFocusUp(); return nil
        }
        if event.keyCode == 125 || (hasCtrl && chars == "n") { // Down / Ctrl+N
            moveFocusDown(); return nil
        }

        // ── Space: toggle selection (multi-select only) ──
        if event.keyCode == 49 && !hasCtrl && !hasShift { // Space
            let q = pendingQuestions[currentIndex]
            guard focusedOptionIndex < q.options.count else { return event }
            // Single-select is "focus = selection" — toggling would clear the
            // answer while focus stays put, breaking the invariant.
            if !q.multiple { return nil }
            toggleOption(questionIndex: currentIndex, label: q.options[focusedOptionIndex].label)
            return nil
        }

        // ── Enter: send ──
        if event.keyCode == 36 { // Return
            if canSend { sendAnswers() }
            return nil
        }

        // ── Tab: focus text field (only for custom questions) ──
        if event.keyCode == 48 { // Tab
            if pendingQuestions[currentIndex].custom {
                isTextFieldFocused = true
                return nil
            }
        }

        return event
    }

    private func moveFocusUp() {
        let count = pendingQuestions[currentIndex].options.count
        guard count > 0 else { return }
        focusedOptionIndex = focusedOptionIndex > 0 ? focusedOptionIndex - 1 : count - 1
        syncSelectionToFocus()
    }

    private func moveFocusDown() {
        let count = pendingQuestions[currentIndex].options.count
        guard count > 0 else { return }
        focusedOptionIndex = focusedOptionIndex < count - 1 ? focusedOptionIndex + 1 : 0
        syncSelectionToFocus()
    }

    private func goNextQuestion() {
        guard currentIndex < pendingQuestions.count - 1 else { return }
        currentIndex += 1
        focusedOptionIndex = 0
        isTextFieldFocused = false
        syncSelectionToFocus()
    }

    private func goPreviousQuestion() {
        guard currentIndex > 0 else { return }
        currentIndex -= 1
        focusedOptionIndex = 0
        isTextFieldFocused = false
        syncSelectionToFocus()
    }

    /// Keep the single-select answer in lockstep with the focused option
    /// (spec 2026-09-28: single-select is "focus = selection"). No-op for
    /// multi-select — there focus and selection are independent.
    private func syncSelectionToFocus() {
        guard pendingQuestions.indices.contains(currentIndex) else { return }
        let synced = QuestionSelection.syncSingleSelection(
            pendingQuestions[currentIndex],
            focusedIndex: focusedOptionIndex
        )
        if synced.isEmpty {
            // Multi-select: never clobber the user's explicit choices.
            return
        }
        selectedAnswers[currentIndex] = synced
    }

    /// Toggle a label in a MULTI-select question's answer set (Space key +
    /// option click). Single-select never goes here — it is "focus =
    /// selection" (see `syncSelectionToFocus`). Picking an option NEVER
    /// sends — the user must explicitly press Send. (Previous behaviour
    /// auto-sent on every click which caused mis-clicks in multi-question
    /// flows.)
    private func toggleOption(questionIndex: Int, label: String) {
        var set = selectedAnswers[questionIndex] ?? []
        if set.contains(label) {
            set.remove(label)
        } else {
            set.insert(label)
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

// MARK: - Option Row (matches settings page hover/focus style)

private struct OptionRow: View {
    let letter: String
    let label: String
    let description: String?
    let isSelected: Bool
    let isFocused: Bool
    let isSending: Bool
    /// Key-hint for this row's hover tooltip; single-select differs from
    /// multi-select because Space is a no-op there (focus = selection).
    let keyHint: String
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button { action() } label: {
            HStack(spacing: 10) {
                Text(letter).font(.system(size: 10, weight: .semibold))
                    .frame(width: 20, height: 20)
                    .background(isSelected ? TerminalColors.green.opacity(0.35) : Color.white.opacity(0.12))
                    .clipShape(Circle())
                VStack(alignment: .leading, spacing: 1) {
                    Text(label)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundColor(isHovered ? .white : .white.opacity(0.9))
                        .lineLimit(1)
                    if let desc = description, !desc.isEmpty {
                        Text(desc)
                            .font(.system(size: 9.5))
                            .foregroundColor(.white.opacity(0.5))
                            .lineLimit(1)
                    }
                }
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundColor(TerminalColors.green)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(isFocused ? Color.white.opacity(0.12) : (isHovered ? Color.white.opacity(0.08) : Color.clear))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .disabled(isSending)
        .onHover { isHovered = $0 }
        .help("\(keyHint) · Enter to send")
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
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(foreground)
                .frame(width: 24, height: 28)
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