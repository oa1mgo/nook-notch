//
//  SessionEvent.swift
//  Nook
//
//  Unified event types for the session state machine.
//  All state changes flow through SessionStore.process(event).
//

import Foundation

/// All events that can affect session state
/// This is the single entry point for state mutations
enum SessionEvent: Sendable {
    // MARK: - Hook Events (from HookSocketServer)

    /// A hook event was received from Claude Code
    case hookReceived(HookEvent)

    /// A Codex hook-backed session was created or resumed
    case codexSessionStarted(sessionId: String, cwd: String)

    /// Codex submitted a user prompt for the current turn
    case codexPromptSubmitted(sessionId: String, cwd: String, prompt: String?)

    /// Codex began running a Bash tool
    case codexBashStarted(sessionId: String, cwd: String, toolName: String, toolUseId: String?, command: String?)

    /// Codex finished running a Bash tool
    case codexBashFinished(sessionId: String, cwd: String, toolName: String, toolUseId: String?, command: String?)

    /// Codex began running any tool (Bash, apply_patch, MCP, etc.)
    case codexToolStarted(sessionId: String, cwd: String, toolName: String, toolUseId: String?, input: [String: String], inputSummary: String?)

    /// Codex finished running any tool.
    case codexToolFinished(sessionId: String, cwd: String, toolName: String, toolUseId: String?, inputSummary: String?)

    /// Codex is waiting on terminal-side user input, such as a permission prompt.
    case codexWaitingForUserInput(sessionId: String, cwd: String)

    /// Codex started or finished compacting context.
    case codexCompactingStarted(sessionId: String, cwd: String)
    case codexCompactingFinished(sessionId: String, cwd: String)

    /// Codex subagent lifecycle signals.
    case codexSubagentStarted(sessionId: String, cwd: String)
    case codexSubagentStopped(sessionId: String, cwd: String)

    /// Codex stopped the current turn
    case codexStopped(sessionId: String, cwd: String)

    /// An OpenCode session was created or resumed
    case opencodeSessionStarted(sessionId: String, cwd: String)

    /// OpenCode session entered a working state (thinking or running a tool)
    case opencodeProcessingStarted(sessionId: String, cwd: String)

    /// OpenCode is showing an interactive prompt (ask_user_question) and
    /// waiting for the user to pick an option before the model can continue.
    case opencodeWaitingForUserInput(sessionId: String, cwd: String)

    /// OpenCode stopped the current turn
    case opencodeStopped(sessionId: String, cwd: String)

    // MARK: - Unified ChatItem Updates (from provider adapters)

    /// A provider adapter produced a chat item operation (insert/update/remove).
    /// This is the unified entry point that replaces provider-specific cases
    /// for chat item mutations.
    case chatItemUpdate(ChatItemUpdate)

    /// A provider adapter produced multiple chat item operations in a batch.
    case chatItemBatch([ChatItemUpdate])

    // MARK: - Permission Events (user actions)

    /// User approved a permission request
    case permissionApproved(sessionId: String, toolUseId: String)

    /// User denied a permission request
    case permissionDenied(sessionId: String, toolUseId: String, reason: String?)

    /// Permission socket failed (connection died before response)
    case permissionSocketFailed(sessionId: String, toolUseId: String)

    // MARK: - File Events (from ConversationParser)

    /// JSONL file was updated with new content
    case fileUpdated(FileUpdatePayload)

    // MARK: - Tool Completion Events (from JSONL parsing)

    /// A tool was detected as completed via JSONL result
    /// This is the authoritative signal that a tool has finished
    case toolCompleted(sessionId: String, toolUseId: String, result: ToolCompletionResult)

    // MARK: - Interrupt Events (from JSONLInterruptWatcher)

    /// User interrupted Claude (detected via JSONL)
    case interruptDetected(sessionId: String)

    // MARK: - Subagent Events (Task tool tracking)

    /// A Task (subagent) tool has started
    case subagentStarted(sessionId: String, taskToolId: String)

    /// A tool was executed within an active subagent
    case subagentToolExecuted(sessionId: String, tool: SubagentToolCall)

    /// A subagent tool completed (status update)
    case subagentToolCompleted(sessionId: String, toolId: String, status: ToolStatus)

    /// A Task (subagent) tool has stopped
    case subagentStopped(sessionId: String, taskToolId: String)

    /// Agent file was updated with new subagent tools (from AgentFileWatcher)
    case agentFileUpdated(sessionId: String, taskToolId: String, tools: [SubagentToolInfo])

    // MARK: - Clear Events (from JSONL detection)

    /// User issued /clear command - reset UI state while keeping session alive
    case clearDetected(sessionId: String)

    // MARK: - Session Lifecycle

    /// Session has ended
    case sessionEnded(sessionId: String)

    /// Request to load initial history from file
    case loadHistory(sessionId: String, cwd: String)

    /// History load completed
    case historyLoaded(sessionId: String, messages: [ChatMessage], completedTools: Set<String>, toolResults: [String: ConversationParser.ToolResult], structuredResults: [String: ToolResultData], conversationInfo: ConversationInfo)
}

/// Payload for file update events
struct FileUpdatePayload: Sendable {
    let sessionId: String
    let cwd: String
    /// Messages to process - either only new messages (if isIncremental) or all messages
    let messages: [ChatMessage]
    /// When true, messages contains only NEW messages since last update
    /// When false, messages contains ALL messages (used for initial load or after /clear)
    let isIncremental: Bool
    let completedToolIds: Set<String>
    let toolResults: [String: ConversationParser.ToolResult]
    let structuredResults: [String: ToolResultData]
}

/// Result of a tool completion detected from JSONL
struct ToolCompletionResult: Sendable {
    let status: ToolStatus
    let result: String?
    let structuredResult: ToolResultData?

    nonisolated static func from(parserResult: ConversationParser.ToolResult?, structuredResult: ToolResultData?) -> ToolCompletionResult {
        let status: ToolStatus
        if parserResult?.isInterrupted == true {
            status = .interrupted
        } else if parserResult?.isError == true {
            status = .error
        } else {
            status = .success
        }

        var resultText: String? = nil
        if let r = parserResult {
            if !r.isInterrupted {
                if let stdout = r.stdout, !stdout.isEmpty {
                    resultText = stdout
                } else if let stderr = r.stderr, !stderr.isEmpty {
                    resultText = stderr
                } else if let content = r.content, !content.isEmpty {
                    resultText = content
                }
            }
        }

        return ToolCompletionResult(status: status, result: resultText, structuredResult: structuredResult)
    }
}

// MARK: - Hook Event Extensions

extension HookEvent {
    /// Determine the target session phase based on this hook event
    nonisolated func determinePhase() -> SessionPhase {
        // PreCompact takes priority
        if event == "PreCompact" {
            return .compacting
        }

        // Permission request creates waitingForApproval state
        if expectsResponse, let tool = tool {
            // AskUserQuestion is user input (not approval), so use
            // .waitingForInput for consistent cross-provider behavior.
            // Claude sends status: "waiting_for_input"; OpenCode sends
            // PermissionRequest — both should render the same way.
            if ToolKind.classify(tool) == .askUserQuestion {
                return .waitingForInput
            }
            return .waitingForApproval(PermissionContext(
                toolUseId: toolUseId ?? "",
                toolName: tool,
                toolInput: toolInput,
                receivedAt: Date()
            ))
        }

        switch status {
        case "waiting_for_input":
            return .waitingForInput
        case "running_tool", "processing", "starting":
            return .processing
        case "compacting":
            return .compacting
        case "ended":
            return .ended
        default:
            return .idle
        }
    }

    /// Whether this is a tool-related event
    nonisolated var isToolEvent: Bool {
        event == "PreToolUse" || event == "PostToolUse" || event == "PermissionRequest"
    }

    /// Whether this event should trigger a file sync
    nonisolated var shouldSyncFile: Bool {
        switch event {
        case "UserPromptSubmit", "PreToolUse", "PostToolUse", "Stop":
            return true
        default:
            return false
        }
    }
}

// MARK: - Debug Description

extension SessionEvent: CustomStringConvertible {
    nonisolated var description: String {
        switch self {
        case .hookReceived(let event):
            return "hookReceived(\(event.event), session: \(event.sessionId.prefix(8)))"
        case .codexSessionStarted(let sessionId, _):
            return "codexSessionStarted(session: \(sessionId.prefix(8)))"
        case .codexPromptSubmitted(let sessionId, _, _):
            return "codexPromptSubmitted(session: \(sessionId.prefix(8)))"
        case .codexBashStarted(let sessionId, _, let toolName, _, _):
            return "codexBashStarted(session: \(sessionId.prefix(8)), tool: \(toolName))"
        case .codexBashFinished(let sessionId, _, let toolName, _, _):
            return "codexBashFinished(session: \(sessionId.prefix(8)), tool: \(toolName))"
        case .codexToolStarted(let sessionId, _, let toolName, _, _, _):
            return "codexToolStarted(session: \(sessionId.prefix(8)), tool: \(toolName))"
        case .codexToolFinished(let sessionId, _, let toolName, _, _):
            return "codexToolFinished(session: \(sessionId.prefix(8)), tool: \(toolName))"
        case .codexWaitingForUserInput(let sessionId, _):
            return "codexWaitingForUserInput(session: \(sessionId.prefix(8)))"
        case .codexCompactingStarted(let sessionId, _):
            return "codexCompactingStarted(session: \(sessionId.prefix(8)))"
        case .codexCompactingFinished(let sessionId, _):
            return "codexCompactingFinished(session: \(sessionId.prefix(8)))"
        case .codexSubagentStarted(let sessionId, _):
            return "codexSubagentStarted(session: \(sessionId.prefix(8)))"
        case .codexSubagentStopped(let sessionId, _):
            return "codexSubagentStopped(session: \(sessionId.prefix(8)))"
        case .codexStopped(let sessionId, _):
            return "codexStopped(session: \(sessionId.prefix(8)))"
        case .opencodeSessionStarted(let sessionId, _):
            return "opencodeSessionStarted(session: \(sessionId.prefix(8)))"
        case .opencodeProcessingStarted(let sessionId, _):
            return "opencodeProcessingStarted(session: \(sessionId.prefix(8)))"
        case .opencodeWaitingForUserInput(let sessionId, _):
            return "opencodeWaitingForUserInput(session: \(sessionId.prefix(8)))"
        case .opencodeStopped(let sessionId, _):
            return "opencodeStopped(session: \(sessionId.prefix(8)))"
        case .permissionApproved(let sessionId, let toolUseId):
            return "permissionApproved(session: \(sessionId.prefix(8)), tool: \(toolUseId.prefix(12)))"
        case .permissionDenied(let sessionId, let toolUseId, _):
            return "permissionDenied(session: \(sessionId.prefix(8)), tool: \(toolUseId.prefix(12)))"
        case .permissionSocketFailed(let sessionId, let toolUseId):
            return "permissionSocketFailed(session: \(sessionId.prefix(8)), tool: \(toolUseId.prefix(12)))"
        case .fileUpdated(let payload):
            return "fileUpdated(session: \(payload.sessionId.prefix(8)), messages: \(payload.messages.count))"
        case .interruptDetected(let sessionId):
            return "interruptDetected(session: \(sessionId.prefix(8)))"
        case .clearDetected(let sessionId):
            return "clearDetected(session: \(sessionId.prefix(8)))"
        case .sessionEnded(let sessionId):
            return "sessionEnded(session: \(sessionId.prefix(8)))"
        case .loadHistory(let sessionId, _):
            return "loadHistory(session: \(sessionId.prefix(8)))"
        case .historyLoaded(let sessionId, let messages, _, _, _, _):
            return "historyLoaded(session: \(sessionId.prefix(8)), messages: \(messages.count))"
        case .toolCompleted(let sessionId, let toolUseId, let result):
            return "toolCompleted(session: \(sessionId.prefix(8)), tool: \(toolUseId.prefix(12)), status: \(result.status))"
        case .subagentStarted(let sessionId, let taskToolId):
            return "subagentStarted(session: \(sessionId.prefix(8)), task: \(taskToolId.prefix(12)))"
        case .subagentToolExecuted(let sessionId, let tool):
            return "subagentToolExecuted(session: \(sessionId.prefix(8)), tool: \(tool.name))"
        case .subagentToolCompleted(let sessionId, let toolId, let status):
            return "subagentToolCompleted(session: \(sessionId.prefix(8)), tool: \(toolId.prefix(12)), status: \(status))"
        case .subagentStopped(let sessionId, let taskToolId):
            return "subagentStopped(session: \(sessionId.prefix(8)), task: \(taskToolId.prefix(12)))"
        case .agentFileUpdated(let sessionId, let taskToolId, let tools):
            return "agentFileUpdated(session: \(sessionId.prefix(8)), task: \(taskToolId.prefix(12)), tools: \(tools.count))"
        case .chatItemUpdate(let update):
            return "chatItemUpdate(session: \(update.sessionId.prefix(8)), id: \(update.id.prefix(16)), mutation: \(update.mutation))"
        case .chatItemBatch(let updates):
            return "chatItemBatch(count: \(updates.count))"
        }
    }
}
