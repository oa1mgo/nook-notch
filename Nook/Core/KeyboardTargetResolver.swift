//  KeyboardTargetResolver.swift
//  Nook
//
//  Keyboard target resolution shared by permission Y/N/A and question ⌃R
//  (mirrors permission-shortcuts spec §2:
//  docs/superpowers/specs/2026-09-23-session-list-permission-shortcuts-design.md).
//  Spec: docs/specs/2026-09-29-session-list-reply-shortcut-target-design.md

import Foundation

enum KeyboardTargetResolver {
    /// 0 → none; 1 → the single target regardless of highlight; 2+ → the
    /// highlighted session must itself be a target, else none.
    /// `highlighted` is nil when there is no valid highlight
    /// (`keyboardSelectedIndex == -1` or out of range).
    /// Match by sessionId — SessionState's synthesized Equatable deep-compares
    /// chatItems/toolTracker etc., and "same session" is an id question.
    static func resolve(from targets: [SessionState], highlighted: SessionState?) -> SessionState? {
        switch targets.count {
        case 0: return nil
        case 1: return targets[0]
        default:
            guard let highlighted,
                  targets.contains(where: { $0.sessionId == highlighted.sessionId })
            else { return nil }
            return highlighted
        }
    }
}
