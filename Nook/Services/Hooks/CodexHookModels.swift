//
//  CodexHookModels.swift
//  Nook
//
//  Minimal Codex hook payloads used by the V1 hook bridge.
//

import Foundation

/// Minimal Codex hook envelope.
struct CodexHookEnvelope: Decodable, Sendable {
    let event: String
    let sessionId: String
    let cwd: String
    let toolName: String?
    let toolUseId: String?
    let toolInput: [String: AnyCodable]?
    let command: String?
    let prompt: String?

    enum CodingKeys: String, CodingKey {
        case event
        case hookEventName = "hook_event_name"
        case sessionId = "session_id"
        case sessionIdCamel = "sessionId"
        case cwd
        case toolName = "tool_name"
        case toolNameCamel = "toolName"
        case tool
        case name
        case toolUseId = "tool_use_id"
        case toolUseIdCamel = "toolUseId"
        case callId = "call_id"
        case callIdCamel = "callId"
        case toolInput = "tool_input"
        case toolInputCamel = "toolInput"
        case input
        case command
        case prompt
    }

    enum ToolInputCodingKeys: String, CodingKey {
        case command
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        event = try Self.decodeString(container, keys: [.event, .hookEventName])
        sessionId = try Self.decodeString(container, keys: [.sessionId, .sessionIdCamel])
        cwd = Self.decodeOptionalString(container, keys: [.cwd]) ?? FileManager.default.currentDirectoryPath
        toolName = Self.decodeOptionalString(container, keys: [.toolName, .toolNameCamel, .tool, .name])
        toolUseId = Self.decodeOptionalString(container, keys: [.toolUseId, .toolUseIdCamel, .callId, .callIdCamel])
        toolInput = Self.decodeOptionalToolInput(container)
        command = Self.decodeOptionalString(container, keys: [.command])
            ?? Self.stringValue(toolInput?["command"]?.value)
        prompt = Self.decodeOptionalString(container, keys: [.prompt])
    }

    var normalizedEventName: String {
        event
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: " ", with: "")
            .lowercased()
    }

    var isBashTool: Bool {
        toolName?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "bash"
    }

    var displayInput: [String: String] {
        guard let toolInput else {
            return command.map { ["command": $0] } ?? [:]
        }

        var result: [String: String] = [:]
        for (key, value) in toolInput {
            if let string = Self.stringValue(value.value), !string.isEmpty {
                result[key] = string
            }
        }

        if result["command"] == nil, let command {
            result["command"] = command
        }
        return result
    }

    var inputSummary: String? {
        if let command = displayInput["command"], !command.isEmpty {
            return command
        }

        let priorityKeys = [
            "file_path", "filePath", "path", "query", "pattern",
            "url", "description", "prompt", "content"
        ]
        for key in priorityKeys {
            if let value = displayInput[key], !value.isEmpty {
                return String(value.prefix(120))
            }
        }
        return toolName
    }

    private static func decodeOptionalToolInput(
        _ container: KeyedDecodingContainer<CodingKeys>
    ) -> [String: AnyCodable]? {
        for key in [CodingKeys.toolInput, .toolInputCamel, .input] {
            if let value = try? container.decodeIfPresent([String: AnyCodable].self, forKey: key) {
                return value
            }
        }
        return nil
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
                  let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]),
                  let string = String(data: data, encoding: .utf8) else {
                return nil
            }
            return string
        case let array as [Any]:
            guard JSONSerialization.isValidJSONObject(array),
                  let data = try? JSONSerialization.data(withJSONObject: array, options: []),
                  let string = String(data: data, encoding: .utf8) else {
                return nil
            }
            return string
        default:
            return nil
        }
    }

    private static func decodeString(
        _ container: KeyedDecodingContainer<CodingKeys>,
        keys: [CodingKeys]
    ) throws -> String {
        for key in keys {
            if let value = try container.decodeIfPresent(String.self, forKey: key) {
                return value
            }
        }

        throw DecodingError.keyNotFound(
            keys[0],
            DecodingError.Context(
                codingPath: container.codingPath,
                debugDescription: "Missing required Codex hook field"
            )
        )
    }

    private static func decodeOptionalString(
        _ container: KeyedDecodingContainer<CodingKeys>,
        keys: [CodingKeys]
    ) -> String? {
        for key in keys {
            if let value = try? container.decodeIfPresent(String.self, forKey: key) {
                return value
            }
        }
        return nil
    }
}

/// Narrow Codex event surface used by the V1 integration.
enum CodexSessionEvent: Sendable {
    case sessionStart(sessionId: String, cwd: String)
    case userPromptSubmit(sessionId: String, cwd: String, prompt: String?)
    case preTool(sessionId: String, cwd: String, toolName: String, toolUseId: String?, input: [String: String], inputSummary: String?)
    case postTool(sessionId: String, cwd: String, toolName: String, toolUseId: String?, inputSummary: String?)
    case waitingForUserInput(sessionId: String, cwd: String)
    case compactingStarted(sessionId: String, cwd: String)
    case compactingFinished(sessionId: String, cwd: String)
    case subagentStarted(sessionId: String, cwd: String)
    case subagentStopped(sessionId: String, cwd: String)
    case stop(sessionId: String, cwd: String)
}
