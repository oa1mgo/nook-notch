//
//  ToolKind.swift
//  Nook
//
//  Provider-agnostic classification of a tool name. Lives in Models
//  (not Services) so it can be referenced from both Models — e.g.
//  `SessionPhase` for permission-row descriptions, `ToolResultData`
//  for status display — and Services — e.g. `ToolCallItem.kind` and
//  `SubagentToolCall.displayText` — without creating a Models →
//  Services reverse dependency.
//
//  Tool names differ across providers:
//    - Claude Code emits PascalCase ("Bash", "Read", "Edit", "Write",
//      "Grep", "Glob", "Task", "Agent", "TodoWrite", "TaskUpdate", "WebFetch",
//      "WebSearch", "AskUserQuestion", "EnterPlanMode", "ExitPlanMode",
//      "AgentOutputTool", "BashOutput", "KillShell")
//    - OpenCode emits lowercase ("bash", "read", "edit", "write",
//      "grep", "glob", "task", "todowrite", "webfetch", "websearch",
//      "question")
//  Use `ToolKind.classify(_:)` (or `ToolCallItem.kind` in Services)
//  instead of string equality on `name` so opencode and Claude behave
//  identically.
//

import Foundation

/// Provider-agnostic tool classification. The `unknown` case is the
/// fallback for MCP tools, codex, or any provider-specific tool that
/// has no first-class mapping.
enum ToolKind: Sendable, Equatable {
    case bash
    case read
    case edit
    case write
    case grep
    case glob
    case task                // subagent container (Task / Agent / task)
    case todoWrite
    case webFetch
    case webSearch
    case askUserQuestion
    case enterPlanMode
    case exitPlanMode
    case agentOutputTool
    case bashOutput
    case killShell
    case unknown             // MCP tools, codex, or any other provider-specific tool

    /// Map a raw tool name (any casing) to its `ToolKind`. Returns
    /// `.unknown` for nil, empty, or unrecognized names. The matching
    /// is case-insensitive — opencode emits lowercase tool names
    /// while Claude emits PascalCase.
    static func classify(_ name: String?) -> ToolKind {
        guard let n = name?.lowercased(), !n.isEmpty else { return .unknown }
        switch n {
        case "bash", "run_command": return .bash
        case "read", "read_file", "view_file": return .read
        case "edit", "edit_file", "replace_file_content", "multi_replace_file_content": return .edit
        case "write", "write_file", "write_to_file": return .write
        case "grep", "grep_search": return .grep
        case "glob", "find_by_name": return .glob
        case "task", "agent", "invoke_subagent": return .task          // Claude "Agent" is the subagent container too
        case "todowrite", "todo", "taskupdate": return .todoWrite
        case "webfetch": return .webFetch
        case "websearch", "search_web": return .webSearch
        case "question", "askuserquestion", "ask_question": return .askUserQuestion
        case "enterplanmode", "plan-enter": return .enterPlanMode
        case "exitplanmode", "plan-exit": return .exitPlanMode
        case "agentoutputtool": return .agentOutputTool
        case "bashoutput": return .bashOutput
        case "killshell": return .killShell
        default: return .unknown
        }
    }
}
