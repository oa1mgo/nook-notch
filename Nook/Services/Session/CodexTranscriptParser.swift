//
//  CodexTranscriptParser.swift
//  Nook
//
//  Parses Codex rollout transcripts into chat history items for the detail view.
//

import Foundation

enum CodexTranscriptParser {
    nonisolated static func loadUpdates(sessionId: String, after lowerBound: Date? = nil) async -> [ChatItemUpdate] {
        await Task.detached(priority: .userInitiated) {
            guard let url = transcriptURL(for: sessionId) else { return [] }
            return parseTranscriptUpdates(at: url, sessionId: sessionId, after: lowerBound)
        }.value
    }

    nonisolated static func loadHistory(sessionId: String) async -> [ChatHistoryItem] {
        history(from: await loadUpdates(sessionId: sessionId))
    }

    nonisolated static func isSubagentSession(sessionId: String) -> Bool {
        guard let url = transcriptURL(for: sessionId),
              let handle = try? FileHandle(forReadingFrom: url) else {
            return false
        }

        defer { try? handle.close() }

        guard let lineData = try? handle.read(upToCount: 8192),
              let firstLine = String(data: lineData, encoding: .utf8)?
                .split(whereSeparator: \.isNewline)
                .first,
              let jsonData = firstLine.data(using: .utf8),
              let raw = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              raw["type"] as? String == "session_meta",
              let payload = raw["payload"] as? [String: Any] else {
            return false
        }

        if payload["agent_nickname"] as? String != nil || payload["agent_role"] as? String != nil {
            return true
        }

        if payload["forked_from_id"] as? String != nil {
            return true
        }

        if let source = payload["source"] as? [String: Any],
           source["subagent"] != nil {
            return true
        }

        return false
    }

    private nonisolated static func transcriptURL(for sessionId: String) -> URL? {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sessions", isDirectory: true)

        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        for case let url as URL in enumerator {
            guard url.lastPathComponent.contains(sessionId),
                  url.pathExtension == "jsonl" else {
                continue
            }
            return url
        }

        return nil
    }

    nonisolated static func parseTranscriptUpdates(
        at url: URL,
        sessionId: String,
        after lowerBound: Date?
    ) -> [ChatItemUpdate] {
        guard let data = try? Data(contentsOf: url),
              let contents = String(data: data, encoding: .utf8) else {
            return []
        }

        let lines = contents.split(whereSeparator: \.isNewline)
        var updates: [ChatItemUpdate] = []

        for (lineIndex, line) in lines.enumerated() {
            guard let jsonData = line.data(using: .utf8),
                  let raw = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                  let envelopeType = raw["type"] as? String,
                  let payload = raw["payload"] as? [String: Any] else {
                continue
            }

            let timestamp: Date
            if let parsedTimestamp = parseTimestamp(raw["timestamp"] as? String) {
                timestamp = parsedTimestamp
            } else if lowerBound != nil {
                continue
            } else {
                timestamp = Date()
            }
            if let lowerBound, timestamp <= lowerBound {
                continue
            }

            guard envelopeType == "response_item",
                  let payloadType = payload["type"] as? String else {
                continue
            }

            switch payloadType {
            case "message":
                guard let role = payload["role"] as? String,
                      role == "user" || role == "assistant" else {
                    continue
                }

                let text = extractMessageText(from: payload["content"])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if let update = CodexChatItemAdapter.messageUpdate(
                    sessionId: sessionId,
                    lineIndex: lineIndex,
                    role: role,
                    text: text,
                    timestamp: timestamp
                ) {
                    updates.append(update)
                }

            case "function_call", "custom_tool_call":
                let callId = payload["call_id"] as? String
                let name = (payload["name"] as? String) ?? "Tool"
                let input = parseToolInput(payload: payload)
                updates.append(CodexChatItemAdapter.toolCallUpdate(
                    sessionId: sessionId,
                    lineIndex: lineIndex,
                    callId: callId,
                    name: name,
                    input: input,
                    timestamp: timestamp
                ))

            case "function_call_output", "custom_tool_call_output":
                guard let callId = payload["call_id"] as? String else {
                    continue
                }
                updates.append(CodexChatItemAdapter.toolOutputUpdate(
                    sessionId: sessionId,
                    callId: callId,
                    result: normalizeToolOutput(payload["output"] as? String),
                    timestamp: timestamp
                ))

            default:
                continue
            }
        }

        return updates
    }

    private nonisolated static func history(from updates: [ChatItemUpdate]) -> [ChatHistoryItem] {
        var items: [ChatHistoryItem] = []
        var orderings: [String: BlockOrdering] = [:]

        for update in updates {
            ChatItemUpdateReducer.apply(update, items: &items, orderings: &orderings)
        }

        return items
    }

    private nonisolated static func extractMessageText(from rawContent: Any?) -> String {
        guard let content = rawContent as? [[String: Any]] else { return "" }

        let texts = content.compactMap { block -> String? in
            guard let type = block["type"] as? String else { return nil }
            switch type {
            case "input_text", "output_text":
                return block["text"] as? String
            default:
                return nil
            }
        }

        return texts.joined(separator: "\n\n")
    }

    private nonisolated static func parseToolInput(payload: [String: Any]) -> [String: String] {
        if let arguments = payload["arguments"] as? String {
            if let data = arguments.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                return flattenTopLevelDictionary(json)
            }

            let trimmed = arguments.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return ["arguments": trimmed]
            }
        }

        if let input = payload["input"] as? [String: Any] {
            return flattenTopLevelDictionary(input)
        }

        return [:]
    }

    private nonisolated static func flattenTopLevelDictionary(_ dictionary: [String: Any]) -> [String: String] {
        var flattened: [String: String] = [:]

        for (key, value) in dictionary {
            switch value {
            case let string as String:
                flattened[key] = string
            case let number as NSNumber:
                flattened[key] = number.stringValue
            default:
                if JSONSerialization.isValidJSONObject(value),
                   let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
                   let string = String(data: data, encoding: .utf8) {
                    flattened[key] = string
                }
            }
        }

        return flattened
    }

    private nonisolated static func normalizeToolOutput(_ output: String?) -> String? {
        guard let output else { return nil }
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private nonisolated static func parseTimestamp(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        if let date = Self.makeFractionalSecondsFormatter().date(from: raw) {
            return date
        }
        if let date = Self.makeBasicInternetFormatter().date(from: raw) {
            return date
        }
        return nil
    }

    private nonisolated static func makeFractionalSecondsFormatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }

    private nonisolated static func makeBasicInternetFormatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }
}
