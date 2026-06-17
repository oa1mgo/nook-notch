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

    /// Format tool input for display
    var formattedInput: String? {
        guard let input = toolInput else { return nil }

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
                return URL(fileURLWithPath: path).lastPathComponent
            }
        case .read:
            if let path = input["file_path"]?.value as? String {
                return URL(fileURLWithPath: path).lastPathComponent
            }
        default:
            break
        }

        // Default: show first string value found (skip description)
        let priorityKeys = ["command", "file_path", "path", "query", "pattern", "url"]
        for key in priorityKeys {
            if let value = input[key]?.value as? String {
                return value.count > 100 ? String(value.prefix(100)) + "..." : value
            }
        }

        // Fallback: first non-description string
        for (key, value) in input where key != "description" {
            if let str = value.value as? String {
                return str.count > 100 ? String(str.prefix(100)) + "..." : str
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
        lhs.receivedAt == rhs.receivedAt
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
        case (.idle, .compacting):
            return true

        // Processing transitions
        case (.processing, .waitingForInput):
            return true
        case (.processing, .waitingForApproval):
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
        case .waitingForApproval, .waitingForInput:
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
        case .compacting:
            return "compacting"
        case .ended:
            return "ended"
        }
    }
}
