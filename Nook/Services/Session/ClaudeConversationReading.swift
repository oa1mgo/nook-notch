import Foundation

/// Reads candidate file state. The caller owns the cursor and commits it only
/// when the result still belongs to the current session lifetime.
nonisolated protocol ClaudeConversationReading: Sendable {
    func readSnapshot(
        sessionId: String,
        cwd: String,
        cursor: ClaudeConversationCursor?
    ) async -> ClaudeConversationSnapshot

    func readSubagentTools(
        sessionId: String,
        agentId: String,
        cwd: String
    ) async -> [ConversationParser.SubagentToolInfo]
}

typealias ClaudeConversationCursor = ConversationParser.Cursor

nonisolated struct ClaudeConversationSnapshot: Sendable {
    let newMessages: [ChatMessage]
    let allMessages: [ChatMessage]
    let completedToolIds: Set<String>
    let toolResults: [String: ConversationParser.ToolResult]
    let structuredResults: [String: ToolResultData]
    let conversationInfo: ConversationInfo
    let clearDetected: Bool
    let cursor: ClaudeConversationCursor

    nonisolated init(
        newMessages: [ChatMessage],
        allMessages: [ChatMessage],
        completedToolIds: Set<String>,
        toolResults: [String: ConversationParser.ToolResult],
        structuredResults: [String: ToolResultData],
        conversationInfo: ConversationInfo,
        clearDetected: Bool,
        cursor: ClaudeConversationCursor
    ) {
        self.newMessages = newMessages
        self.allMessages = allMessages
        self.completedToolIds = completedToolIds
        self.toolResults = toolResults
        self.structuredResults = structuredResults
        self.conversationInfo = conversationInfo
        self.clearDetected = clearDetected
        self.cursor = cursor
    }
}
