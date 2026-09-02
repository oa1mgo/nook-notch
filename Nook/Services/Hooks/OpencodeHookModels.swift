//
//  OpencodeHookModels.swift
//  Nook
//
//  OpenCode bus event envelope and the narrow Nook event surface.
//
//  The plugin (Resources/opencode-plugin/index.js) forwards every bus
//  event with `origin: "opencode"`.  We decode the socket payload into
//  OpencodeHookEnvelope and then let the adapter filter + normalise
//  into OpencodeSessionEvent — only the 5 events Nook tracks.
//

import Foundation

/// Raw envelope received from the Nook OpenCode plugin over the Unix socket.
struct OpencodeHookEnvelope: Decodable, Sendable {
    let origin: String
    let type: String
    let properties: [String: AnyCodable]?
}

/// Normalised event surface — the only OpenCode events Nook currently cares about.
///
/// Mirrors CodexSessionEvent so the two integrations share the same
/// session-tracking machinery inside SessionStore.
///
/// `messageId` on chat-item-producing events (assistantThinking/Text, preTool,
/// postTool, userPromptSubmitted) carries the opencode message ID for use by
/// OpencodeChatItemAdapter's BlockOrdering. It is optional with a default of
/// nil so existing call sites continue to compile without changes.
enum OpencodeSessionEvent: Sendable {
    case sessionStart(sessionId: String, cwd: String)
    case userPromptSubmitted(sessionId: String, cwd: String, prompt: String?, messageId: String? = nil)
    case processingStarted(sessionId: String, cwd: String)
    case waitingForUserInput(sessionId: String, cwd: String, requestId: String?)
    case assistantThinking(sessionId: String, cwd: String, text: String, messageId: String? = nil)
    /// Streaming assistant reasoning (thinking) — emitted on every
    /// `message.part.delta` when the delta is routed into the reasoning buffer.
    /// `text` is the FULL accumulated reasoning text so far, so the consumer
    /// can upsert a single chat item per messageID instead of appending chunks.
    /// The messageID is pre-marked in `emittedReasoningMessages`, which makes
    /// the final `message.part.updated(type=reasoning)` event and the safety
    /// net flushes skip this messageID (no duplicate emit).
    case assistantThinkingStreaming(sessionId: String, cwd: String, text: String, messageId: String)
    case assistantText(sessionId: String, cwd: String, text: String, messageId: String? = nil)
    /// Streaming assistant text — emitted on every `message.part.delta` after
    /// the delta is accumulated into the buffer. `text` is the FULL accumulated
    /// text so far (not just the delta), so the consumer can upsert a single
    /// chat item per messageID instead of appending chunks. The messageID is
    /// pre-marked in `emittedTextMessages`, which makes the finish=stop flush
    /// and the session-idle safety net skip it (no duplicate emit).
    case assistantTextStreaming(sessionId: String, cwd: String, text: String, messageId: String)
    /// Retract a previously streamed assistant text for this messageID.
    /// Used when `question.asked` tags the parent message as suppressed AFTER
    /// its text has already been streamed into the chat view — the streaming
    /// item must be removed or the question prompt would linger visibly.
    case assistantStreamingCancelled(sessionId: String, messageId: String)
    case preTool(sessionId: String, cwd: String, toolName: String, toolUseId: String?, inputSummary: String?, input: [String: String] = [:], messageId: String? = nil)
    case postTool(sessionId: String, cwd: String, toolName: String, toolUseId: String?, inputSummary: String?, output: String? = nil, error: String? = nil, messageId: String? = nil)
    case image(sessionId: String, cwd: String, mediaType: String, base64Data: String, messageId: String? = nil)
    case permissionAsked(sessionId: String, cwd: String, requestId: String, toolName: String, toolUseId: String?, input: [String: String], inputSummary: String?, alwaysPatterns: [String])
    case serverPortReceived(sessionId: String, port: Int, version: String?, pid: Int?)
    case stop(sessionId: String, cwd: String)
    // MARK: - Subagent events
    // All subagent events are scoped to the PARENT session — the adapter
    // already rewrites child session ids before emitting these. Subagent
    // tool events carry the call id from the child's message stream (kept
    // as the subagent tool id) so postTool status updates can correlate.
    case subagentStarted(sessionId: String, taskToolId: String)
    case subagentToolExecuted(sessionId: String, tool: SubagentToolCall)
    case subagentToolCompleted(sessionId: String, toolId: String, status: ToolStatus)
    case subagentStopped(sessionId: String, taskToolId: String)
}
