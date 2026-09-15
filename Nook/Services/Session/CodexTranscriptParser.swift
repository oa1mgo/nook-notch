//
//  CodexTranscriptParser.swift
//  Nook
//
//  Parses Codex rollout transcripts into chat history items for the detail view.
//

import Foundation

struct CodexTranscriptParseResult: Sendable {
    let updates: [ChatItemUpdate]
    let endOffset: UInt64
}

/// Offsets belong to files, not sessions: Desktop can rotate one session into
/// several rollout files. Never apply an old file's offset to its successor.
struct CodexTranscriptCursor: Sendable {
    struct FilePosition: Sendable {
        let identity: UInt64
        let offset: UInt64

        nonisolated init(identity: UInt64, offset: UInt64) {
            self.identity = identity
            self.offset = offset
        }
    }
    var files: [String: FilePosition] = [:]

    nonisolated init() {}
}

struct CodexTranscriptSyncResult: Sendable {
    let updates: [ChatItemUpdate]
    let cursor: CodexTranscriptCursor

    nonisolated init(updates: [ChatItemUpdate], cursor: CodexTranscriptCursor) {
        self.updates = updates
        self.cursor = cursor
    }
}

enum CodexTranscriptParser {
    nonisolated static var sessionsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sessions", isDirectory: true)
    }

    nonisolated static func loadUpdates(sessionId: String, after lowerBound: Date? = nil) async -> [ChatItemUpdate] {
        await loadSessionUpdates(sessionId: sessionId, after: lowerBound).updates
    }

    nonisolated static func loadSessionUpdates(
        sessionId: String,
        after lowerBound: Date? = nil,
        cursor: CodexTranscriptCursor = CodexTranscriptCursor(),
        root: URL = sessionsDirectory
    ) async -> CodexTranscriptSyncResult {
        let task = Task.detached(priority: .userInitiated) {
            var next = cursor
            var updates: [ChatItemUpdate] = []
            for url in transcriptURLs(for: sessionId, root: root) {
                guard !Task.isCancelled else { break }
                let path = url.resolvingSymlinksInPath().path
                let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
                let identity = (attributes?[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
                let previous = cursor.files[path]
                let offset = previous?.identity == identity ? previous?.offset ?? 0 : 0
                let result = parseTranscriptUpdates(
                    at: url, sessionId: sessionId, after: lowerBound, fromOffset: offset
                )
                next.files[path] = .init(identity: identity, offset: result.endOffset)
                updates.append(contentsOf: result.updates)
            }
            return CodexTranscriptSyncResult(updates: updates, cursor: next)
        }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    nonisolated static func loadHistory(sessionId: String) async -> [ChatHistoryItem] {
        history(from: await loadUpdates(sessionId: sessionId))
    }

    nonisolated static func isSubagentSession(sessionId: String, root: URL = sessionsDirectory) -> Bool {
        guard let url = transcriptURLs(for: sessionId, root: root).last,
              let payload = sessionMetadata(at: url) else {
            return false
        }

        if payload["agent_nickname"] as? String != nil || payload["agent_role"] as? String != nil {
            return true
        }

        // A user-created fork is still a direct conversation. Only explicit
        // agent metadata identifies a subagent; forked_from_id alone does not.
        if let source = payload["source"] as? [String: Any],
           source["subagent"] != nil {
            return true
        }

        return false
    }

    nonisolated static func transcriptURLs(for sessionId: String, root: URL = sessionsDirectory) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var urls: [URL] = []
        for case let url as URL in enumerator {
            guard url.lastPathComponent.contains(sessionId),
                  url.pathExtension == "jsonl",
                  sessionMetadata(at: url)?["id"] as? String == sessionId else {
                continue
            }
            urls.append(url)
        }

        // Rollout names carry their creation timestamp. Metadata identity above
        // prevents matching a different session/fork with a similar filename.
        return urls.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private nonisolated static func sessionMetadata(at url: URL) -> [String: Any]? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var data = Data()
        // session_meta includes instructions and routinely exceeds 8 KB.
        while data.count < 4 * 1024 * 1024 {
            guard let chunk = try? handle.read(upToCount: 16 * 1024), !chunk.isEmpty else { break }
            data.append(chunk)
            if let newline = data.firstIndex(of: 10) {
                data = Data(data[..<newline])
                break
            }
        }
        guard let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              raw["type"] as? String == "session_meta" else { return nil }
        return raw["payload"] as? [String: Any]
    }

    nonisolated static func parseTranscriptUpdates(
        at url: URL,
        sessionId: String,
        after lowerBound: Date?
    ) -> [ChatItemUpdate] {
        parseTranscriptUpdates(
            at: url,
            sessionId: sessionId,
            after: lowerBound,
            fromOffset: 0
        ).updates
    }

    nonisolated static func parseTranscriptUpdates(
        at url: URL,
        sessionId: String,
        after lowerBound: Date?,
        fromOffset: UInt64
    ) -> CodexTranscriptParseResult {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return CodexTranscriptParseResult(updates: [], endOffset: fromOffset)
        }
        defer { try? handle.close() }

        let fileSize = (try? handle.seekToEnd()) ?? 0
        let startOffset = fromOffset <= fileSize ? fromOffset : 0
        try? handle.seek(toOffset: startOffset)

        let data = handle.readDataToEndOfFile()
        var updates: [ChatItemUpdate] = []
        var committedOffset = startOffset
        var lineStartIndex = data.startIndex

        while lineStartIndex < data.endIndex,
              let newlineIndex = data[lineStartIndex..<data.endIndex].firstIndex(of: 10) {
            guard !Task.isCancelled else { break }
            var lineData = Data(data[lineStartIndex..<newlineIndex])
            if lineData.last == 13 {
                lineData = Data(lineData.dropLast())
            }
            let lineOffset = startOffset + UInt64(data.distance(from: data.startIndex, to: lineStartIndex))
            let stableLineIndex = Int(min(lineOffset, UInt64(Int.max)))

            parseTranscriptLine(
                lineData,
                sessionId: sessionId,
                stableLineIndex: stableLineIndex,
                sourceId: "\(url.lastPathComponent):\(lineOffset)",
                lowerBound: lowerBound,
                updates: &updates
            )

            let nextLineIndex = data.index(after: newlineIndex)
            committedOffset = startOffset + UInt64(data.distance(from: data.startIndex, to: nextLineIndex))
            lineStartIndex = nextLineIndex
        }

        if !Task.isCancelled, lineStartIndex < data.endIndex {
            var lineData = Data(data[lineStartIndex..<data.endIndex])
            if lineData.last == 13 {
                lineData = Data(lineData.dropLast())
            }
            let lineOffset = startOffset + UInt64(data.distance(from: data.startIndex, to: lineStartIndex))
            let stableLineIndex = Int(min(lineOffset, UInt64(Int.max)))
            if parseTranscriptLine(
                lineData,
                sessionId: sessionId,
                stableLineIndex: stableLineIndex,
                sourceId: "\(url.lastPathComponent):\(lineOffset)",
                lowerBound: lowerBound,
                updates: &updates
            ) {
                committedOffset = startOffset + UInt64(data.count)
            }
        }

        return CodexTranscriptParseResult(updates: updates, endOffset: committedOffset)
    }

    @discardableResult
    private nonisolated static func parseTranscriptLine(
        _ lineData: Data,
        sessionId: String,
        stableLineIndex: Int,
        sourceId: String,
        lowerBound: Date?,
        updates: inout [ChatItemUpdate]
    ) -> Bool {
        guard !lineData.isEmpty else { return true }
        guard let raw = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
            return false
        }
        guard let envelopeType = raw["type"] as? String,
              let payload = raw["payload"] as? [String: Any] else {
            return true
        }

        let timestamp: Date
        if let parsedTimestamp = parseTimestamp(raw["timestamp"] as? String) {
            timestamp = parsedTimestamp
        } else if lowerBound != nil {
            return true
        } else {
            timestamp = Date()
        }
        if let lowerBound, timestamp <= lowerBound {
            return true
        }

        guard let payloadType = payload["type"] as? String else {
            return true
        }

        // `response_item/message` rows with role=user are model input, not a
        // user-interface boundary. Current Codex can fold memories, environment
        // context, plugin recommendations, and the actual prompt into those rows.
        // Desktop uses item_completed/UserMessage; CLI rollouts may still use
        // user_message. Both are UI boundaries, unlike model-input messages.
        if envelopeType == "event_msg", payloadType == "item_completed",
           let item = payload["item"] as? [String: Any],
           item["type"] as? String == "UserMessage" {
            if let threadId = payload["thread_id"] as? String, threadId != sessionId { return true }
            let text = extractMessageText(from: item["content"])
            if let update = CodexChatItemAdapter.messageUpdate(
                sessionId: sessionId, lineIndex: stableLineIndex, role: "user",
                text: text, timestamp: timestamp,
                messageId: item["id"] as? String ?? sourceId
            ) {
                updates.append(update)
            }
            return true
        }
        if envelopeType == "event_msg", payloadType == "user_message" {
            let text = (payload["message"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if let update = CodexChatItemAdapter.messageUpdate(
                sessionId: sessionId,
                lineIndex: stableLineIndex,
                role: "user",
                text: text,
                timestamp: timestamp,
                messageId: payload["id"] as? String ?? sourceId
            ) {
                updates.append(update)
            }
            return true
        }

        guard envelopeType == "response_item" else { return true }

        switch payloadType {
        case "message":
            guard let role = payload["role"] as? String,
                  role == "assistant" else {
                return true
            }

            let text = extractMessageText(from: payload["content"])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let update = CodexChatItemAdapter.messageUpdate(
                sessionId: sessionId,
                lineIndex: stableLineIndex,
                role: role,
                text: text,
                timestamp: timestamp,
                messageId: payload["id"] as? String ?? sourceId
            ) {
                updates.append(update)
            }

        case "function_call", "custom_tool_call":
            let callId = payload["call_id"] as? String ?? "codex-tool-\(sessionId)-\(sourceId)"
            let name = (payload["name"] as? String) ?? "Tool"
            let input = parseToolInput(payload: payload)
            updates.append(CodexChatItemAdapter.toolCallUpdate(
                sessionId: sessionId,
                lineIndex: stableLineIndex,
                callId: callId,
                name: name,
                input: input,
                timestamp: timestamp
            ))

        case "function_call_output", "custom_tool_call_output":
            guard let callId = payload["call_id"] as? String else {
                return true
            }
            updates.append(CodexChatItemAdapter.toolOutputUpdate(
                sessionId: sessionId,
                callId: callId,
                result: normalizeToolOutput(payload["output"]),
                timestamp: timestamp
            ))

        default:
            break
        }

        return true
    }

    private nonisolated static func history(from updates: [ChatItemUpdate]) -> [ChatHistoryItem] {
        var items: [ChatHistoryItem] = []
        var orderings: [String: BlockOrdering] = [:]

        ChatItemUpdateReducer.applyBatch(updates, items: &items, orderings: &orderings)

        return items
    }

    private nonisolated static func extractMessageText(from rawContent: Any?) -> String {
        guard let content = rawContent as? [[String: Any]] else { return "" }

        let texts = content.compactMap { block -> String? in
            guard let type = block["type"] as? String else { return nil }
            switch type {
            case "text", "input_text", "output_text":
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

        if let input = payload["input"] as? String {
            if let data = input.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                return flattenTopLevelDictionary(json)
            }

            let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return ["input": trimmed]
            }
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

    private nonisolated static func normalizeToolOutput(_ output: Any?) -> String? {
        switch output {
        case let string as String:
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed

        case let content as [[String: Any]]:
            let text = content.compactMap { item -> String? in
                guard let rawText = item["text"] as? String else { return nil }
                let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }.joined(separator: "\n\n")
            return text.isEmpty ? nil : text

        case let number as NSNumber:
            return number.stringValue

        default:
            return nil
        }
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
