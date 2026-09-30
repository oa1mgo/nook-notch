//
//  SessionPhase.swift
//  Nook
//
//  Explicit state machine for Claude session lifecycle.
//  All state transitions are validated before being applied.
//

import Foundation

/// Permission context for tools waiting for approval
struct PermissionContext: Sendable {
    let toolUseId: String
    let toolName: String
    let toolInput: [String: AnyCodable]?
    let receivedAt: Date
    /// OpenCode permission request id (e.g. "per_xxx"). nil for Claude/Codex
    /// sessions where approval is delivered through the hook socket.
    let opencodeRequestId: String?
    /// Patterns that will be allowed when the user selects "Always allow"
    /// (e.g. ["/Users/wuruofan/mine/rfw/*"]). Populated from opencode's
    /// `permission.asked` event. Empty for Claude/Codex sessions.
    let alwaysPatterns: [String]

    init(
        toolUseId: String,
        toolName: String,
        toolInput: [String: AnyCodable]?,
        receivedAt: Date,
        opencodeRequestId: String? = nil,
        alwaysPatterns: [String] = []
    ) {
        self.toolUseId = toolUseId
        self.toolName = toolName
        self.toolInput = toolInput
        self.receivedAt = receivedAt
        self.opencodeRequestId = opencodeRequestId
        self.alwaysPatterns = alwaysPatterns
    }

    /// Format tool input for display
    /// Shortens a path by replacing the user's home directory with "~".
    private static func abbreviatePath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }

    var formattedInput: String? {
        guard let input = toolInput else { return nil }

        // opencode permission prompts use different field names than Claude
        // tool inputs. `external_directory` permission carries `filepath`
        // (one word) instead of `file_path`, and `permission` is a category
        // name ("read", "edit", "external_directory") rather than a tool
        // name. Handle these first so the permission row shows the actual
        // target (file path, command) instead of the opaque category.
        let lowerTool = toolName.lowercased()
        if lowerTool == "external_directory" {
            // opencode external-directory permission: show the file path
            // that triggered the external-directory check.
            // Note: opencode plugin stores filepath as "file_path" (underscore),
            // but permission.asked events may use "filepath" (no underscore).
            // Check both to handle either format.
            if let filepath = input["filepath"]?.value as? String ?? input["file_path"]?.value as? String {
                let short = Self.abbreviatePath(filepath)
                return short.count > 100 ? String(short.prefix(100)) + "..." : short
            }
            // Fallback: external_directory may carry a bash command that accesses
            // external paths. Extract the command for display.
            if let command = input["command"]?.value as? String {
                let short = Self.abbreviatePath(command)
                return short.count > 100 ? String(short.prefix(100)) + "..." : short
            }
        }

        // Switch on provider-agnostic kind — opencode emits lowercase
        // tool names ("bash", "read", "edit", "write") while Claude
        // emits PascalCase. A previous version used exact equality
        // (`toolName == "Bash"`) which only matched Claude sessions,
        // so opencode permission rows fell through to the generic
        // fallback and didn't show the actual command / file path.
        switch ToolCallItem.kind(of: toolName) {
        case .bash:
            if let command = input["command"]?.value as? String {
                return command.count > 100 ? String(command.prefix(100)) + "..." : command
            }
        case .write, .edit:
            if let path = input["file_path"]?.value as? String {
                let short = Self.abbreviatePath(path)
                return URL(fileURLWithPath: short).lastPathComponent
            }
        case .read:
            if let path = input["file_path"]?.value as? String {
                let short = Self.abbreviatePath(path)
                return URL(fileURLWithPath: short).lastPathComponent
            }
        default:
            break
        }

        // Default: show first string value found (skip description).
        // Includes `filepath` (opencode permission metadata) alongside
        // the standard Claude-style keys.
        let priorityKeys = ["command", "file_path", "filepath", "path", "query", "pattern", "url"]
        for key in priorityKeys {
            if let value = input[key]?.value as? String {
                let short = Self.abbreviatePath(value)
                return short.count > 100 ? String(short.prefix(100)) + "..." : short
            }
        }

        // Fallback: first non-description string
        for (key, value) in input where key != "description" {
            if let str = value.value as? String {
                let short = Self.abbreviatePath(str)
                return short.count > 100 ? String(short.prefix(100)) + "..." : short
            }
        }

        return nil
    }
}

extension PermissionContext: Equatable {
    nonisolated static func == (lhs: PermissionContext, rhs: PermissionContext) -> Bool {
        // Compare by identity fields only (AnyCodable doesn't conform to Equatable)
        lhs.toolUseId == rhs.toolUseId &&
        lhs.toolName == rhs.toolName &&
        lhs.receivedAt == rhs.receivedAt &&
        lhs.opencodeRequestId == rhs.opencodeRequestId
    }
}

/// Explicit session phases - the state machine
enum SessionPhase: Sendable {
    /// Session is idle, waiting for user input or new activity
    case idle

    /// Claude is actively processing (running tools, generating response)
    case processing

    /// Claude has finished and is waiting for user input
    case waitingForInput

    /// A tool is waiting for user permission approval
    case waitingForApproval(PermissionContext)

    /// A provider is waiting on an approval prompt that must be answered in
    /// the terminal because Nook cannot write a decision back for it.
    case waitingForTerminalApproval(PermissionContext)

    /// Context is being compacted (auto or manual)
    case compacting

    /// Session has ended
    case ended

    // MARK: - State Machine Transitions

    /// Check if a transition to the target phase is valid
    nonisolated func canTransition(to next: SessionPhase) -> Bool {
        switch (self, next) {
        // Terminal state - no transitions out
        case (.ended, _):
            return false

        // Any state can transition to ended
        case (_, .ended):
            return true

        // Idle transitions
        case (.idle, .processing):
            return true
        case (.idle, .waitingForApproval):
            return true  // Direct permission request on idle session
        case (.idle, .waitingForTerminalApproval):
            return true
        case (.idle, .compacting):
            return true

        // Processing transitions
        case (.processing, .waitingForInput):
            return true
        case (.processing, .waitingForApproval):
            return true
        case (.processing, .waitingForTerminalApproval):
            return true
        case (.processing, .compacting):
            return true
        case (.processing, .idle):
            return true  // Interrupt or quick completion

        // WaitingForInput transitions
        case (.waitingForInput, .processing):
            return true
        case (.waitingForInput, .idle):
            return true  // Can become idle
        case (.waitingForInput, .compacting):
            return true

        // WaitingForApproval transitions
        case (.waitingForApproval, .processing):
            return true  // Approved - tool will run
        case (.waitingForApproval, .idle):
            return true  // Denied or cancelled
        case (.waitingForApproval, .waitingForInput):
            return true  // Denied and Claude stopped
        case (.waitingForApproval, .waitingForApproval):
            return true  // Another tool needs approval (multiple pending permissions)

        // WaitingForTerminalApproval transitions
        case (.waitingForTerminalApproval, .processing):
            return true
        case (.waitingForTerminalApproval, .idle):
            return true
        case (.waitingForTerminalApproval, .waitingForInput):
            return true
        case (.waitingForTerminalApproval, .waitingForTerminalApproval):
            return true
        case (.waitingForTerminalApproval, .compacting):
            return true

        // Compacting transitions
        case (.compacting, .processing):
            return true
        case (.compacting, .idle):
            return true
        case (.compacting, .waitingForInput):
            return true

        // Allow staying in same state (no-op transitions)
        default:
            return self == next
        }
    }

    /// Attempt to transition to a new phase, returns the new phase if valid
    nonisolated func transition(to next: SessionPhase) -> SessionPhase? {
        canTransition(to: next) ? next : nil
    }

    /// Whether this phase indicates the session needs user attention
    nonisolated var needsAttention: Bool {
        switch self {
        case .waitingForApproval, .waitingForTerminalApproval, .waitingForInput:
            return true
        default:
            return false
        }
    }

    /// Whether this phase indicates active processing
    nonisolated var isActive: Bool {
        switch self {
        case .processing, .compacting:
            return true
        default:
            return false
        }
    }

    /// Whether this is a waitingForApproval phase
    nonisolated var isWaitingForApproval: Bool {
        if case .waitingForApproval = self {
            return true
        }
        return false
    }

    /// Whether this is a terminal-side approval phase
    nonisolated var isWaitingForTerminalApproval: Bool {
        if case .waitingForTerminalApproval = self {
            return true
        }
        return false
    }

    /// Whether this is a waitingForInput phase
    nonisolated var isWaitingForInput: Bool {
        if case .waitingForInput = self {
            return true
        }
        return false
    }

    /// Extract tool name if waiting for approval
    var approvalToolName: String? {
        if case .waitingForApproval(let ctx) = self {
            return ctx.toolName
        }
        return nil
    }

    /// Extract tool name if waiting for terminal-side approval
    var terminalApprovalToolName: String? {
        if case .waitingForTerminalApproval(let ctx) = self {
            return ctx.toolName
        }
        return nil
    }
}

// MARK: - Equatable

extension SessionPhase: Equatable {
    nonisolated static func == (lhs: SessionPhase, rhs: SessionPhase) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle): return true
        case (.processing, .processing): return true
        case (.waitingForInput, .waitingForInput): return true
        case (.waitingForApproval(let ctx1), .waitingForApproval(let ctx2)):
            return ctx1 == ctx2
        case (.waitingForTerminalApproval(let ctx1), .waitingForTerminalApproval(let ctx2)):
            return ctx1 == ctx2
        case (.compacting, .compacting): return true
        case (.ended, .ended): return true
        default: return false
        }
    }
}

// MARK: - Debug Description

extension SessionPhase: CustomStringConvertible {
    nonisolated var description: String {
        switch self {
        case .idle:
            return "idle"
        case .processing:
            return "processing"
        case .waitingForInput:
            return "waitingForInput"
        case .waitingForApproval(let ctx):
            return "waitingForApproval(\(ctx.toolName))"
        case .waitingForTerminalApproval(let ctx):
            return "waitingForTerminalApproval(\(ctx.toolName))"
        case .compacting:
            return "compacting"
        case .ended:
            return "ended"
        }
    }
}
