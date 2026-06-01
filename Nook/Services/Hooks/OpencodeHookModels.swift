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
enum OpencodeSessionEvent: Sendable {
    case sessionStart(sessionId: String, cwd: String)
    case userPromptSubmit(sessionId: String, cwd: String, prompt: String?)
    case preBashTool(sessionId: String, cwd: String, toolName: String, toolUseId: String?, command: String?)
    case postBashTool(sessionId: String, cwd: String, toolName: String, toolUseId: String?, command: String?)
    case stop(sessionId: String, cwd: String)
}
