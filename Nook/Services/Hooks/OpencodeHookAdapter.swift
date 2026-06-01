//
//  OpencodeHookAdapter.swift
//  Nook
//
//  Translates raw OpenCode bus events (from the plugin socket) into the
//  normalised OpencodeSessionEvent enum that Nook's session store consumes.
//
//  Event model (reverse‑engineered from opencode v1.15.12 bus):
//    session.created       → sessionStart
//    message.updated       → user prompt detection
//    message.part.updated  → user text + bash tool lifecycle
//    session.idle          → stop
//

import Foundation

final class OpencodeHookAdapter: @unchecked Sendable {

    // MARK: - State (per‑session user‑text cache)

    private static var lock = NSLock()
    /// sessionID → messageID of the most recent user message
    private static var latestUserMsgID: [String: String] = [:]
    /// messageID → text content from message.part.updated(text)
    private static var userTextCache: [String: String] = [:]
    /// sessionID → cwd extracted from session.created
    private static var sessionCwd: [String: String] = [:]

    // MARK: - Public API

    /// Try to convert a raw envelope into a tracked Nook event.
    /// Returns nil for events Nook does not care about.
    static func adapt(_ envelope: OpencodeHookEnvelope) -> OpencodeSessionEvent? {
        guard envelope.origin == "opencode" else { return nil }
        let props = envelope.properties ?? [:]

        switch envelope.type {
        case "session.created":
            return handleSessionCreated(props)
        case "message.updated":
            return handleMessageUpdated(props)
        case "message.part.updated":
            return handlePartUpdated(props)
        case "session.idle":
            return handleSessionIdle(props)
        default:
            return nil
        }
    }

    // MARK: - Event Handlers

    private static func handleSessionCreated(_ props: [String: AnyCodable]) -> OpencodeSessionEvent? {
        guard let sessionId = props["sessionID"]?.value as? String else { return nil }
        let info = props["info"]?.value as? [String: Any]
        let cwd = info?["directory"] as? String ?? ""

        lock.lock()
        sessionCwd[sessionId] = cwd
        lock.unlock()

        return .sessionStart(sessionId: sessionId, cwd: cwd)
    }

    private static func handleMessageUpdated(_ props: [String: AnyCodable]) -> OpencodeSessionEvent? {
        guard let sessionId = props["sessionID"]?.value as? String else { return nil }
        guard let info = props["info"]?.value as? [String: Any] else { return nil }
        guard info["role"] as? String == "user" else { return nil }

        let messageId = info["id"] as? String ?? ""

        lock.lock()
        latestUserMsgID[sessionId] = messageId

        // Check if we already have the text cached
        let cachedText = userTextCache[messageId]
        let cwd = sessionCwd[sessionId] ?? ""
        lock.unlock()

        if let text = cachedText {
            return .userPromptSubmit(sessionId: sessionId, cwd: cwd, prompt: text)
        }

        return nil
    }

    private static func handlePartUpdated(_ props: [String: AnyCodable]) -> OpencodeSessionEvent? {
        guard let sessionId = props["sessionID"]?.value as? String else { return nil }
        guard let part = props["part"]?.value as? [String: Any] else { return nil }
        guard let partType = part["type"] as? String else { return nil }

        let cwd: String = {
            lock.lock()
            let v = sessionCwd[sessionId] ?? ""
            lock.unlock()
            return v
        }()

        switch partType {
        case "text":
            return handleTextPart(sessionId: sessionId, cwd: cwd, part: part)
        case "tool":
            return handleToolPart(sessionId: sessionId, cwd: cwd, part: part)
        default:
            return nil
        }
    }

    private static func handleSessionIdle(_ props: [String: AnyCodable]) -> OpencodeSessionEvent? {
        guard let sessionId = props["sessionID"]?.value as? String else { return nil }
        let cwd: String = {
            lock.lock()
            let v = sessionCwd[sessionId] ?? ""
            lock.unlock()
            return v
        }()
        return .stop(sessionId: sessionId, cwd: cwd)
    }

    // MARK: - Part Handlers

    private static func handleTextPart(sessionId: String, cwd: String, part: [String: Any]) -> OpencodeSessionEvent? {
        let messageId = part["messageID"] as? String ?? ""
        let text = part["text"] as? String ?? ""

        lock.lock()
        // Check if this text belongs to a user message
        if let pendingMsgID = latestUserMsgID[sessionId], pendingMsgID == messageId {
            latestUserMsgID.removeValue(forKey: sessionId)
            lock.unlock()
            return .userPromptSubmit(sessionId: sessionId, cwd: cwd, prompt: text)
        }
        // Cache it in case message.updated arrives later
        if !messageId.isEmpty && !text.isEmpty {
            userTextCache[messageId] = text
        }
        lock.unlock()
        return nil
    }

    private static func handleToolPart(sessionId: String, cwd: String, part: [String: Any]) -> OpencodeSessionEvent? {
        guard let toolName = part["tool"] as? String else { return nil }
        guard toolName.lowercased() == "bash" else { return nil }
        guard let state = part["state"] as? [String: Any] else { return nil }
        guard let status = state["status"] as? String else { return nil }

        let callId = part["callID"] as? String
        let input = state["input"] as? [String: Any]
        let command = input?["command"] as? String

        switch status {
        case "running":
            return .preBashTool(
                sessionId: sessionId, cwd: cwd,
                toolName: toolName, toolUseId: callId, command: command
            )
        case "completed":
            return .postBashTool(
                sessionId: sessionId, cwd: cwd,
                toolName: toolName, toolUseId: callId, command: command
            )
        default:
            return nil
        }
    }
}
