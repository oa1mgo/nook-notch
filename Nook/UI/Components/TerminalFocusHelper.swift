// TerminalFocusHelper.swift
// Nook
//
// Standalone extraction of ChatView's terminal-focus logic so the question
// panel (and any future caller) can reuse the 3-tier fallback without a view.

import AppKit
import Foundation

enum TerminalFocusHelper {
    /// Try every terminal focus method in order; return true on first success.
    /// Order: tmux (yabai) → non-tmux process tree → last-resort bundle ID.
    /// Copied verbatim from ChatView.tryFocusTerminal (lines 584-632), with
    /// `session` promoted to a parameter and `viewModel` removed (unused here).
    @MainActor
    static func tryFocusTerminal(for session: SessionState) async -> Bool {
        if session.isInTmux, let pid = session.pid {
            if await YabaiController.shared.focusWindow(forClaudePid: pid) {
                DebugLog.shared.write("[focus] tmux focusWindow(forClaudePid) succeeded")
                return true
            }
            DebugLog.shared.write("[focus] tmux focusWindow(forClaudePid) failed, trying forWorkingDirectory")
            if await YabaiController.shared.focusWindow(forWorkingDirectory: session.cwd) {
                DebugLog.shared.write("[focus] tmux focusWindow(forWorkingDirectory) succeeded")
                return true
            }
            DebugLog.shared.write("[focus] tmux path failed, falling through to non-tmux fallback")
        }
        if let pid = session.pid {
            if await focusTerminalApp(forChildPid: Int(pid)) {
                DebugLog.shared.write("[focus] non-tmux focusTerminalApp succeeded")
                return true
            }
            DebugLog.shared.write("[focus] non-tmux focusTerminalApp failed: could not find terminal app for pid=\(pid)")
            let terminalBundleIds = ["com.mitchellh.ghostty", "com.googlecode.iterm2", "com.apple.Terminal"]
            for bundleId in terminalBundleIds {
                if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first {
                    let ok = app.activate()
                    DebugLog.shared.write("[focus] last-resort activate bundleId=\(bundleId) success=\(ok)")
                    if ok { return true }
                }
            }
            DebugLog.shared.write("[focus] all focus methods failed")
        } else {
            DebugLog.shared.write("[focus] session.pid is nil, cannot focus terminal")
        }
        return false
    }

    /// Copied verbatim from ChatView.focusTerminalApp(forChildPid:) (lines 637-660).
    @MainActor
    private static func focusTerminalApp(forChildPid childPid: Int) async -> Bool {
        let tree = ProcessTreeBuilder.shared.buildTree()
        guard let terminalPid = ProcessTreeBuilder.shared.findTerminalPid(
            forProcess: childPid, tree: tree
        ) else {
            return false
        }
        guard let app = NSRunningApplication(processIdentifier: pid_t(terminalPid)),
              let bundleId = app.bundleIdentifier,
              TerminalAppRegistry.isTerminalBundle(bundleId) else {
            return false
        }
        let activated = app.activate()
        DebugLog.shared.write("[focus] activated terminal app pid=\(terminalPid) bundleId=\(bundleId) success=\(activated)")
        return activated
    }
}
