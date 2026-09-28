//  QuestionSelection.swift
//  Nook
//
//  Pure logic behind the question panel's selection model and key hints.
//  Kept free of view state so it can be unit tested (spec:
//  docs/specs/2026-09-28-question-focus-select-and-key-hints-design.md).
//
//  Single-select questions use "focus = selection": moving the focused
//  option IS the answer, so Space is a no-op there. Multi-select keeps
//  focus and selection independent (Space / click toggles).

import Foundation

enum QuestionSelection {

    /// The answer set a single-select question should hold while
    /// `focusedIndex` is focused. Empty for multi-select (no coupling) and
    /// for an out-of-range focus index (never invent a selection).
    static func syncSingleSelection(_ question: PendingQuestion, focusedIndex: Int) -> Set<String> {
        guard !question.multiple else { return [] }
        guard question.options.indices.contains(focusedIndex) else { return [] }
        return [question.options[focusedIndex].label]
    }

    /// Whether an option row should render its selected checkmark.
    /// Hides it for single-select + custom + non-empty text, because
    /// `sendAnswers` replaces the selection with the text — showing a
    /// checkmark next to the text would misrepresent what gets sent.
    /// `sendAnswers` trims before testing emptiness, so trim here too
    /// (otherwise a whitespace-only answer would hide the checkmark while
    /// the option is still what gets submitted).
    static func showsSelectionHighlight(_ question: PendingQuestion, text: String) -> Bool {
        if question.custom, !question.multiple,
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return false
        }
        return true
    }

    /// Key-hint tooltip for the current question card.
    static func tooltipText(for question: PendingQuestion) -> String {
        let move = question.multiple ? "⌃N/⌃P 移动" : "⌃N/⌃P 选择"
        var parts = [move]
        if question.multiple { parts.append("Space 选中") }
        if question.custom { parts.append("Tab 输入") }
        parts.append("Enter 发送")
        return parts.joined(separator: " · ")
    }
}
