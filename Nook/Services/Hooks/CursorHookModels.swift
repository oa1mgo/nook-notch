//
//  CursorHookModels.swift
//  Nook
//
//  Cursor hook payloads and the narrow Nook event surface.
//

import Foundation

/// Raw Cursor hook payload received over the shared Unix socket.
///
/// The Nook bridge normally adds `origin: "cursor"` before forwarding the
/// JSON Cursor provides on stdin. Cursor payloads can also arrive without
/// that stamp, so this model owns Cursor-shaped detection rather than leaking
/// provider details into the shared socket server.
struct CursorHookEnvelope: Decodable, Sendable {
    let origin: String?
    let hookEventName: String
    let conversationId: String?
    let generationId: String?
    let sessionIdField: String?
    let model: String?
    let cursorVersion: String?
    let workspaceRoots: [String]
    let transcriptPath: String?
    let cwdField: String?

    let prompt: String?
    let text: String?
    let toolName: String?
    let toolUseId: String?
    let toolInput: [String: AnyCodable]?
    let toolOutput: String?
    let errorMessage: String?
    let failureType: String?
    let status: String?
    let reason: String?
    let durationMs: Double?

    enum CodingKeys: String, CodingKey {
        case origin
        case hookEventName = "hook_event_name"
        case event
        case conversationId = "conversation_id"
        case generationId = "generation_id"
        case sessionIdField = "session_id"
        case model
        case cursorVersion = "cursor_version"
        case workspaceRoots = "workspace_roots"
        case transcriptPath = "transcript_path"
        case cwdField = "cwd"
        case prompt
        case text
        case toolName = "tool_name"
        case toolUseId = "tool_use_id"
        case toolInput = "tool_input"
        case toolOutput = "tool_output"
        case errorMessage = "error_message"
        case failureType = "failure_type"
        case status
        case reason
        case durationMs = "duration_ms"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        origin = try container.decodeIfPresent(String.self, forKey: .origin)
        hookEventName = try Self.decodeHookEventName(container)
        conversationId = try container.decodeIfPresent(String.self, forKey: .conversationId)
        generationId = try container.decodeIfPresent(String.self, forKey: .generationId)
        sessionIdField = try container.decodeIfPresent(String.self, forKey: .sessionIdField)
        model = try container.decodeIfPresent(String.self, forKey: .model)
        cursorVersion = try container.decodeIfPresent(String.self, forKey: .cursorVersion)
        workspaceRoots = (try? container.decodeIfPresent([String].self, forKey: .workspaceRoots)) ?? []
        transcriptPath = try container.decodeIfPresent(String.self, forKey: .transcriptPath)
        cwdField = try container.decodeIfPresent(String.self, forKey: .cwdField)
        prompt = try container.decodeIfPresent(String.self, forKey: .prompt)
        text = try container.decodeIfPresent(String.self, forKey: .text)
        toolName = try container.decodeIfPresent(String.self, forKey: .toolName)
        toolUseId = try container.decodeIfPresent(String.self, forKey: .toolUseId)
        toolInput = try container.decodeIfPresent([String: AnyCodable].self, forKey: .toolInput)
        toolOutput = try container.decodeIfPresent(String.self, forKey: .toolOutput)
        errorMessage = try container.decodeIfPresent(String.self, forKey: .errorMessage)
        failureType = try container.decodeIfPresent(String.self, forKey: .failureType)
        status = try container.decodeIfPresent(String.self, forKey: .status)
        reason = try container.decodeIfPresent(String.self, forKey: .reason)
        durationMs = try container.decodeIfPresent(Double.self, forKey: .durationMs)
    }

    var isCursorPayload: Bool {
        if origin?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "cursor" {
            return true
        }

        if Self.cursorOnlyEvents.contains(normalizedEventName) {
            return true
        }

        return false
    }

    var sessionId: String {
        // Cursor can emit per-run `session_id` values on tool/lifecycle hooks.
        // `conversation_id` is the stable chat identity Nook should group by.
        conversationId?.nilIfBlank
            ?? sessionIdField?.nilIfBlank
            ?? generationId?.nilIfBlank
            ?? "cursor-session"
    }

    var cwd: String {
        cwdField?.nilIfBlank
            ?? workspaceRoots.first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
            ?? FileManager.default.currentDirectoryPath
    }

    var normalizedEventName: String {
        hookEventName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: " ", with: "")
            .lowercased()
    }

    var displayInput: [String: String] {
        guard let toolInput else { return [:] }
        var result: [String: String] = [:]
        for (key, value) in toolInput {
            if let string = Self.stringValue(value.value), !string.isEmpty {
                result[key] = string
            }
        }
        return result
    }

    var inputSummary: String? {
        let input = displayInput
        if let command = input["command"], !command.isEmpty {
            return command
        }

        let priorityKeys = [
            "file_path", "filePath", "path", "query", "pattern",
            "url", "description", "prompt", "content"
        ]
        for key in priorityKeys {
            if let value = input[key], !value.isEmpty {
                return String(value.prefix(120))
            }
        }

        return toolName
    }

    var toolOutputSummary: String? {
        guard let output = toolOutput?.trimmingCharacters(in: .whitespacesAndNewlines),
              !output.isEmpty else {
            return nil
        }

        if let data = output.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) {
            if let summary = Self.summaryString(from: object) {
                return summary
            }
        }

        return output
    }

    var errorSummary: String? {
        if let errorMessage = errorMessage?.trimmingCharacters(in: .whitespacesAndNewlines),
           !errorMessage.isEmpty {
            return errorMessage
        }
        return failureType
    }

    private nonisolated static let cursorOnlyEvents: Set<String> = [
        "beforesubmitprompt",
        "afteragentresponse",
        "afteragentthought",
    ]

    private static func decodeHookEventName(
        _ container: KeyedDecodingContainer<CodingKeys>
    ) throws -> String {
        if let value = try container.decodeIfPresent(String.self, forKey: .hookEventName),
           !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return value
        }

        if let value = try container.decodeIfPresent(String.self, forKey: .event),
           !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return value
        }

        throw DecodingError.keyNotFound(
            CodingKeys.hookEventName,
            DecodingError.Context(
                codingPath: container.codingPath,
                debugDescription: "Cursor hook payload is missing hook_event_name/event"
            )
        )
    }

    private static func stringValue(_ value: Any?) -> String? {
        switch value {
        case let string as String:
            return string
        case let int as Int:
            return String(int)
        case let double as Double:
            return String(double)
        case let bool as Bool:
            return bool ? "true" : "false"
        case let dict as [String: Any]:
            guard JSONSerialization.isValidJSONObject(dict),
                  let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]) else {
                return nil
            }
            return String(data: data, encoding: .utf8)
        case let array as [Any]:
            guard JSONSerialization.isValidJSONObject(array),
                  let data = try? JSONSerialization.data(withJSONObject: array, options: []) else {
                return nil
            }
            return String(data: data, encoding: .utf8)
        default:
            return nil
        }
    }

    private static func summaryString(from value: Any) -> String? {
        if let string = stringValue(value)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !string.isEmpty {
            return string
        }

        guard let dict = value as? [String: Any] else { return nil }
        let priorityKeys = [
            "output", "result", "text", "content", "stdout", "stderr",
            "message", "error"
        ]
        for key in priorityKeys {
            if let summary = stringValue(dict[key])?.trimmingCharacters(in: .whitespacesAndNewlines),
               !summary.isEmpty {
                return summary
            }
        }

        return stringValue(dict)
    }
}

/// Narrow Cursor event surface consumed by SessionStore.
enum CursorSessionEvent: Sendable {
    case sessionStart(sessionId: String, cwd: String)
    case processingStarted(sessionId: String, cwd: String)
    case compactingStarted(sessionId: String, cwd: String)
    case stop(sessionId: String, cwd: String, status: String?)
    case sessionEnd(sessionId: String)
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
