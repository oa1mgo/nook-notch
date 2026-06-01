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

    var displayName: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        case .opencode: return "OpenCode"
        }
    }

    var systemImage: String {
        switch self {
        case .claude: return "circle.hexagongrid"
        case .codex: return "chevron.left.forwardslash.chevron.right"
        case .opencode: return "terminal"
        }
    }

    var defaultDirectoryName: String {
        switch self {
        case .claude: return ".claude"
        case .codex: return ".codex"
        case .opencode: return ".config/opencode"
        }
    }
}
