//
//  ToolResultData.swift
//  Nook
//
//  Structured models for all Claude Code tool results
//

import Foundation

// MARK: - Tool Result Wrapper

/// Structured tool result data - parsed from JSONL tool_result blocks
enum ToolResultData: Equatable, Sendable {
    case read(ReadResult)
    case edit(EditResult)
    case write(WriteResult)
    case bash(BashResult)
    case grep(GrepResult)
    case glob(GlobResult)
    case todoWrite(TodoWriteResult)
    case task(TaskResult)
    case webFetch(WebFetchResult)
    case webSearch(WebSearchResult)
    case askUserQuestion(AskUserQuestionResult)
    case bashOutput(BashOutputResult)
    case killShell(KillShellResult)
    case exitPlanMode(ExitPlanModeResult)
    case mcp(MCPResult)
    case generic(GenericResult)
}

// MARK: - Read Tool Result

struct ReadResult: Equatable, Sendable {
    let filePath: String
    let content: String
    let numLines: Int
    let startLine: Int
    let totalLines: Int

    var filename: String {
        URL(fileURLWithPath: filePath).lastPathComponent
    }
}

// MARK: - Edit Tool Result

struct EditResult: Equatable, Sendable {
    let filePath: String
    let oldString: String
    let newString: String
    let replaceAll: Bool
    let userModified: Bool
    let structuredPatch: [PatchHunk]?

    var filename: String {
        URL(fileURLWithPath: filePath).lastPathComponent
    }
}

struct PatchHunk: Equatable, Sendable {
    let oldStart: Int
    let oldLines: Int
    let newStart: Int
    let newLines: Int
    let lines: [String]
}

// MARK: - Write Tool Result

struct WriteResult: Equatable, Sendable {
    enum WriteType: String, Equatable, Sendable {
        case create
        case overwrite
    }

    let type: WriteType
    let filePath: String
    let content: String
    let structuredPatch: [PatchHunk]?

    var filename: String {
        URL(fileURLWithPath: filePath).lastPathComponent
    }
}

// MARK: - Bash Tool Result

struct BashResult: Equatable, Sendable {
    let stdout: String
    let stderr: String
    let interrupted: Bool
    let isImage: Bool
    let returnCodeInterpretation: String?
    let backgroundTaskId: String?

    var hasOutput: Bool {
        !stdout.isEmpty || !stderr.isEmpty
    }

    var displayOutput: String {
        if !stdout.isEmpty {
            return stdout
        }
        if !stderr.isEmpty {
            return stderr
        }
        return "(No content)"
    }
}

// MARK: - Grep Tool Result

struct GrepResult: Equatable, Sendable {
    enum Mode: String, Equatable, Sendable {
        case filesWithMatches = "files_with_matches"
        case content
        case count
    }

    let mode: Mode
    let filenames: [String]
    let numFiles: Int
    let content: String?
    let numLines: Int?
    let appliedLimit: Int?
}

// MARK: - Glob Tool Result

struct GlobResult: Equatable, Sendable {
    let filenames: [String]
    let durationMs: Int
    let numFiles: Int
    let truncated: Bool
}

// MARK: - TodoWrite Tool Result

struct TodoWriteResult: Equatable, Sendable {
    let oldTodos: [TodoItem]
    let newTodos: [TodoItem]
}

struct TodoItem: Equatable, Sendable {
    let content: String
    let status: String // "pending", "in_progress", "completed"
    let activeForm: String?
}

// MARK: - Task (Agent) Tool Result

struct TaskResult: Equatable, Sendable {
    let agentId: String
    let status: String
    let content: String
    let prompt: String?
    let totalDurationMs: Int?
    let totalTokens: Int?
    let totalToolUseCount: Int?
}

// MARK: - WebFetch Tool Result

struct WebFetchResult: Equatable, Sendable {
    let url: String
    let code: Int
    let codeText: String
    let bytes: Int
    let durationMs: Int
    let result: String
}

// MARK: - WebSearch Tool Result

struct WebSearchResult: Equatable, Sendable {
    let query: String
    let durationSeconds: Double
    let results: [SearchResultItem]
}

struct SearchResultItem: Equatable, Sendable {
    let title: String
    let url: String
    let snippet: String
}

// MARK: - AskUserQuestion Tool Result

struct AskUserQuestionResult: Equatable, Sendable {
    let questions: [QuestionItem]
    let answers: [String: String]
}

struct QuestionItem: Equatable, Sendable {
    let question: String
    let header: String?
    let options: [QuestionOption]
}

struct QuestionOption: Equatable, Sendable {
    let label: String
    let description: String?
}

// MARK: - BashOutput Tool Result

struct BashOutputResult: Equatable, Sendable {
    let shellId: String
    let status: String
    let stdout: String
    let stderr: String
    let stdoutLines: Int
    let stderrLines: Int
    let exitCode: Int?
    let command: String?
    let timestamp: String?
}

// MARK: - KillShell Tool Result

struct KillShellResult: Equatable, Sendable {
    let shellId: String
    let message: String
}

// MARK: - ExitPlanMode Tool Result

struct ExitPlanModeResult: Equatable, Sendable {
    let filePath: String?
    let plan: String?
    let isAgent: Bool
}

// MARK: - MCP Tool Result (Generic)

struct MCPResult: Equatable, @unchecked Sendable {
    let serverName: String
    let toolName: String
    let rawResult: [String: Any]

    static func == (lhs: MCPResult, rhs: MCPResult) -> Bool {
        lhs.serverName == rhs.serverName &&
        lhs.toolName == rhs.toolName &&
        NSDictionary(dictionary: lhs.rawResult).isEqual(to: rhs.rawResult)
    }
}

// MARK: - Generic Tool Result (Fallback)

struct GenericResult: Equatable, @unchecked Sendable {
    let rawContent: String?
    let rawData: [String: Any]?

    static func == (lhs: GenericResult, rhs: GenericResult) -> Bool {
        guard lhs.rawContent == rhs.rawContent else { return false }
        // Compare rawData dictionaries if both present
        if let lhsData = lhs.rawData, let rhsData = rhs.rawData {
            return NSDictionary(dictionary: lhsData).isEqual(to: rhsData)
        }
        return lhs.rawData == nil && rhs.rawData == nil
    }
}

// MARK: - Tool Status Display

struct ToolStatusDisplay {
    let text: String
    let isRunning: Bool

    /// Get running status text for a tool
    static func running(for toolName: String, input: [String: String]) -> ToolStatusDisplay {
        // Switch on provider-agnostic kind (opencode emits "bash" lowercase
        // while Claude emits "Bash" PascalCase) so the running banner shows
        // the actual command / pattern / url / etc. for both providers
        // instead of falling through to a generic "Running...".
        switch ToolCallItem.kind(of: toolName) {
        case .read:
            return ToolStatusDisplay(text: "Reading...", isRunning: true)
        case .edit:
            return ToolStatusDisplay(text: "Editing...", isRunning: true)
        case .write:
            return ToolStatusDisplay(text: "Writing...", isRunning: true)
        case .bash:
            // Tool input is provider-specific. Claude hooks put the command
            // under "description"; the OpenCode hook adapter puts it under
            // "command". For subagent bash tools (and any other source that
            // passes a precomputed one-liner) the key is "summary". Check
            // all three so the chat view shows the actual command (e.g.
            // "git status && git diff HEAD --stat") rather than a generic
            // "Running..." placeholder.
            if let cmd = input["command"]?.trimmingCharacters(in: .whitespacesAndNewlines),
               !cmd.isEmpty {
                let firstLine = cmd.components(separatedBy: "\n").first ?? cmd
                return ToolStatusDisplay(text: String(firstLine.prefix(80)), isRunning: true)
            }
            if let desc = input["description"]?.trimmingCharacters(in: .whitespacesAndNewlines),
               !desc.isEmpty {
                return ToolStatusDisplay(text: desc, isRunning: true)
            }
            if let summary = input["summary"]?.trimmingCharacters(in: .whitespacesAndNewlines),
               !summary.isEmpty {
                return ToolStatusDisplay(text: summary, isRunning: true)
            }
            return ToolStatusDisplay(text: "Running...", isRunning: true)
        case .grep, .glob:
            if let pattern = input["pattern"] {
                return ToolStatusDisplay(text: "Searching: \(pattern)", isRunning: true)
            }
            return ToolStatusDisplay(text: "Searching...", isRunning: true)
        case .webSearch:
            if let query = input["query"] {
                return ToolStatusDisplay(text: "Searching: \(query)", isRunning: true)
            }
            return ToolStatusDisplay(text: "Searching...", isRunning: true)
        case .webFetch:
            return ToolStatusDisplay(text: "Fetching...", isRunning: true)
        case .task:
            if let desc = input["description"], !desc.isEmpty {
                return ToolStatusDisplay(text: desc, isRunning: true)
            }
            return ToolStatusDisplay(text: "Running agent...", isRunning: true)
        case .todoWrite:
            return ToolStatusDisplay(text: "Updating todos...", isRunning: true)
        case .enterPlanMode:
            return ToolStatusDisplay(text: "Entering plan mode...", isRunning: true)
        case .exitPlanMode:
            return ToolStatusDisplay(text: "Exiting plan mode...", isRunning: true)
        default:
            return ToolStatusDisplay(text: "Running...", isRunning: true)
        }
    }

    /// Get completed status text for a tool result
    static func completed(for toolName: String, result: ToolResultData?) -> ToolStatusDisplay {
        guard let result = result else {
            return ToolStatusDisplay(text: "Completed", isRunning: false)
        }

        switch result {
        case .read(let r):
            let lineText = r.totalLines > r.numLines ? "\(r.numLines)+ lines" : "\(r.numLines) lines"
            return ToolStatusDisplay(text: "Read \(r.filename) (\(lineText))", isRunning: false)

        case .edit(let r):
            return ToolStatusDisplay(text: "Edited \(r.filename)", isRunning: false)

        case .write(let r):
            let action = r.type == .create ? "Created" : "Wrote"
            return ToolStatusDisplay(text: "\(action) \(r.filename)", isRunning: false)

        case .bash(let r):
            if let bgId = r.backgroundTaskId {
                return ToolStatusDisplay(text: "Running in background (\(bgId))", isRunning: false)
            }
            if let interpretation = r.returnCodeInterpretation {
                return ToolStatusDisplay(text: interpretation, isRunning: false)
            }
            return ToolStatusDisplay(text: "Completed", isRunning: false)

        case .grep(let r):
            let fileWord = r.numFiles == 1 ? "file" : "files"
            return ToolStatusDisplay(text: "Found \(r.numFiles) \(fileWord)", isRunning: false)

        case .glob(let r):
            let fileWord = r.numFiles == 1 ? "file" : "files"
            if r.numFiles == 0 {
                return ToolStatusDisplay(text: "No files found", isRunning: false)
            }
            return ToolStatusDisplay(text: "Found \(r.numFiles) \(fileWord)", isRunning: false)

        case .todoWrite:
            return ToolStatusDisplay(text: "Updated todos", isRunning: false)

        case .task(let r):
            return ToolStatusDisplay(text: r.status.capitalized, isRunning: false)

        case .webFetch(let r):
            return ToolStatusDisplay(text: "\(r.code) \(r.codeText)", isRunning: false)

        case .webSearch(let r):
            let time = r.durationSeconds >= 1 ?
                "\(Int(r.durationSeconds))s" :
                "\(Int(r.durationSeconds * 1000))ms"
            let searchWord = r.results.count == 1 ? "search" : "searches"
            return ToolStatusDisplay(text: "Did 1 \(searchWord) in \(time)", isRunning: false)

        case .askUserQuestion:
            return ToolStatusDisplay(text: "Answered", isRunning: false)

        case .bashOutput(let r):
            return ToolStatusDisplay(text: "Status: \(r.status)", isRunning: false)

        case .killShell:
            return ToolStatusDisplay(text: "Terminated", isRunning: false)

        case .exitPlanMode:
            return ToolStatusDisplay(text: "Plan ready", isRunning: false)

        case .mcp:
            return ToolStatusDisplay(text: "Completed", isRunning: false)

        case .generic:
            return ToolStatusDisplay(text: "Completed", isRunning: false)
        }
    }
}
