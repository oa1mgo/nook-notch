//
//  SessionProvider.swift
//  Nook
//
//  Provider metadata for sessions.
//

import Foundation

enum SessionProvider: String, Codable, Equatable, Sendable, CaseIterable {
    case claude
    case codex
    case opencode
    case cursor
    case antigravity

    var displayName: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        case .opencode: return "OpenCode"
        case .cursor: return "Cursor"
        case .antigravity: return "Antigravity"
        }
    }

    var systemImage: String {
        switch self {
        case .claude: return "circle.hexagongrid"
        case .codex: return "chevron.left.forwardslash.chevron.right"
        case .opencode: return "terminal"
        case .cursor: return "cube"
        case .antigravity: return "sparkles"
        }
    }

    var defaultDirectoryName: String {
        switch self {
        case .claude: return ".claude"
        case .codex: return ".codex"
        case .opencode: return ".config/opencode"
        case .cursor: return ".cursor"
        case .antigravity: return ".gemini/config"
        }
    }

    /// Whether the hook path should create real-time chatItem placeholders
    /// (PreToolUse → running toolCall, PostToolUse → status update).
    ///
    /// - **`false`** (append-order providers: Claude, Codex): the adapter's
    ///   JSONL/transcript sync is the authoritative source. Hook placeholders
    ///   would have `Date()` timestamps that break the append-only ordering
    ///   guarantee (e.g. a Question placeholder appearing before its thinking
    ///   bubble). The adapter creates items with correct `message.timestamp`
    ///   in source order — no placeholder needed.
    /// - **`true`** (event-driven providers: OpenCode, Cursor): events arrive
    ///   out-of-order; real-time placeholders give the user live feedback
    ///   while the sorter handles final ordering.
    ///
    /// When adding a new provider, set this based on the data source:
    /// append-only + monotonic → `false`; out-of-order event stream → `true`.
    var needsHookPlaceholders: Bool {
        switch self {
        case .claude, .codex: return false
        case .opencode, .cursor, .antigravity: return true
        }
    }
}
