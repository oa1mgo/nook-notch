//
//  AntigravityHookModels.swift
//  Nook
//
//  Antigravity lifecycle hook payloads (camelCase protojson) and narrow
//  session event surface consumed by SessionStore.
//

import Foundation

/// Raw Antigravity hook payload received over the shared Unix socket.
///
/// The Nook bridge stamps `origin: "antigravity"` before forwarding the
/// camelCase protojson payload Antigravity provides on stdin. Raw payloads
/// without `origin` are also recognized via Antigravity-specific event names
/// or camelCase `conversationId` + `hookEventName` shape.
struct AntigravityHookEnvelope: Decodable, Sendable {
    struct ToolCallPayload: Decodable, Sendable {
        let id: String?
        let name: String?
        let args: [String: AnyCodable]?
    }

    let origin: String?
    let hookEventName: String
    let conversationId: String?
    let workspacePaths: [String]
    let transcriptPath: String?
    let artifactDirectoryPath: String?
    let modelName: String?
    let lastUserInput: String?
    let cwdField: String?

    let toolCall: ToolCallPayload?
    let stepIdx: Int?
    let invocationNum: Int?
    let initialNumSteps: Int?
    let executionNum: Int?
    let terminationReason: String?
    let error: String?
    let fullyIdle: Bool?
    let continuationActive: Bool?

    private let hasCamelCaseHookEventName: Bool

    enum CodingKeys: String, CodingKey {
        case origin
        case hookEventName
        case event
        case conversationId
        case workspacePaths
        case transcriptPath
        case artifactDirectoryPath
        case modelName
        case lastUserInput
        case cwdField = "cwd"
        case toolCall
        case stepIdx
        case invocationNum
        case initialNumSteps
        case executionNum
        case terminationReason
        case error
        case fullyIdle
        case continuationActive
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        origin = try container.decodeIfPresent(String.self, forKey: .origin)
        let camelEventName = try container.decodeIfPresent(String.self, forKey: .hookEventName)?.nilIfBlank
        hasCamelCaseHookEventName = camelEventName != nil
        if let camelEventName {
            hookEventName = camelEventName
        } else if let fallback = try container.decodeIfPresent(String.self, forKey: .event)?.nilIfBlank {
            hookEventName = fallback
        } else {
            throw DecodingError.keyNotFound(
                CodingKeys.hookEventName,
                DecodingError.Context(
                    codingPath: container.codingPath,
                    debugDescription: "Antigravity hook payload is missing hookEventName/event"
                )
            )
        }

        conversationId = try container.decodeIfPresent(String.self, forKey: .conversationId)
        workspacePaths = (try? container.decodeIfPresent([String].self, forKey: .workspacePaths)) ?? []
        transcriptPath = try container.decodeIfPresent(String.self, forKey: .transcriptPath)
        artifactDirectoryPath = try container.decodeIfPresent(String.self, forKey: .artifactDirectoryPath)
        modelName = try container.decodeIfPresent(String.self, forKey: .modelName)
        lastUserInput = try container.decodeIfPresent(String.self, forKey: .lastUserInput)
        cwdField = try container.decodeIfPresent(String.self, forKey: .cwdField)
        toolCall = try container.decodeIfPresent(ToolCallPayload.self, forKey: .toolCall)
        stepIdx = try container.decodeIfPresent(Int.self, forKey: .stepIdx)
        invocationNum = try container.decodeIfPresent(Int.self, forKey: .invocationNum)
        initialNumSteps = try container.decodeIfPresent(Int.self, forKey: .initialNumSteps)
        executionNum = try container.decodeIfPresent(Int.self, forKey: .executionNum)
        terminationReason = try container.decodeIfPresent(String.self, forKey: .terminationReason)
        error = try container.decodeIfPresent(String.self, forKey: .error)
        fullyIdle = try container.decodeIfPresent(Bool.self, forKey: .fullyIdle)
        continuationActive = try container.decodeIfPresent(Bool.self, forKey: .continuationActive)
    }

    var isAntigravityPayload: Bool {
        if origin?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "antigravity" {
            return true
        }

        if Self.antigravityOnlyEvents.contains(normalizedEventName) {
            return true
        }

        if hasCamelCaseHookEventName, conversationId?.nilIfBlank != nil {
            return true
        }

        return false
    }

    var sessionId: String {
        conversationId?.nilIfBlank ?? "antigravity-session"
    }

    var cwd: String {
        cwdField?.nilIfBlank
            ?? workspacePaths.first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
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

    var toolName: String? {
        toolCall?.name?.nilIfBlank
    }

    var toolUseId: String? {
        if let id = toolCall?.id?.nilIfBlank {
            return id
        }
        if let stepIdx {
            return "antigravity-\(sessionId)-step-\(stepIdx)"
        }
        return nil
    }

    var displayInput: [String: String] {
        guard let args = toolCall?.args else { return [:] }
        var result: [String: String] = [:]
        for (key, value) in args {
            if let string = Self.stringValue(value.value), !string.isEmpty {
                result[key] = string
            }
        }
        return result
    }

    var inputSummary: String? {
        let input = displayInput
        let priorityKeys = [
            "CommandLine", "command",
            "Path", "AbsolutePath", "TargetFile", "file_path", "filePath", "path",
            "Query", "query", "Pattern", "pattern",
            "Url", "url", "Prompt", "prompt",
            "toolSummary", "Description", "description", "Content", "content"
        ]
        for key in priorityKeys {
            if let value = input[key], !value.isEmpty {
                return String(value.prefix(120))
            }
        }
        return toolName
    }

    var errorSummary: String? {
        error?.nilIfBlank
    }

    private nonisolated static let antigravityOnlyEvents: Set<String> = [
        "preinvocation",
        "postinvocation",
    ]

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
}

/// Narrow Antigravity event surface consumed by SessionStore.
enum AntigravitySessionEvent: Sendable {
    case sessionStart(sessionId: String, cwd: String)
    case processingStarted(sessionId: String, cwd: String)
    case waitingForInput(sessionId: String, cwd: String)
    case stop(sessionId: String, cwd: String, terminationReason: String?, error: String?)
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
