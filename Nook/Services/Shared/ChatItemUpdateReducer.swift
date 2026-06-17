//
//  ChatItemUpdateReducer.swift
//  Nook
//
//  Pure reducer for applying provider-normalized ChatItemUpdate operations.
//

import Foundation

enum ChatItemUpdateReducer {
    @discardableResult
    nonisolated static func apply(
        _ update: ChatItemUpdate,
        items: inout [ChatHistoryItem],
        orderings: inout [String: BlockOrdering],
        now: Date = Date()
    ) -> Bool {
        if case .thinking(let text) = update.block,
           text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return false
        }

        switch update.mutation {
        case .insert:
            applyInsert(update, items: &items, orderings: &orderings, now: now)

        case .update:
            applyUpdate(update, items: &items)

        case .updateStatus:
            applyStatusUpdate(update, items: &items)

        case .remove:
            items.removeAll { $0.id == update.id }
            orderings.removeValue(forKey: update.id)
        }

        items = ChatItemSorter.sorted(items, orderings: orderings)
        return true
    }

    private nonisolated static func applyInsert(
        _ update: ChatItemUpdate,
        items: inout [ChatHistoryItem],
        orderings: inout [String: BlockOrdering],
        now: Date
    ) {
        if let idx = items.firstIndex(where: { $0.id == update.id }) {
            let originalTimestamp = items[idx].timestamp
            let existingType = items[idx].type

            if case .toolCall(let newTool) = update.block,
               case .toolCall(let existingTool) = existingType {
                let merged = ToolCallItem(
                    name: newTool.name,
                    input: newTool.input,
                    status: existingTool.status,
                    result: existingTool.result,
                    structuredResult: existingTool.structuredResult ?? newTool.structuredResult,
                    subagentTools: existingTool.subagentTools
                )
                items[idx] = ChatHistoryItem(
                    id: update.id,
                    type: .toolCall(merged),
                    timestamp: originalTimestamp
                )
                orderings[update.id] = update.ordering
                return
            }

            if case .user = existingType {
                return
            }

            if case .assistantText(let newText) = update.block,
               case .assistant(let existing) = existingType {
                let newTrimmed = newText.trimmingCharacters(in: .whitespacesAndNewlines)
                let existingTrimmed = existing.trimmingCharacters(in: .whitespacesAndNewlines)
                if existingTrimmed.isEmpty && newTrimmed.isEmpty { return }
                if !existingTrimmed.isEmpty && newTrimmed.isEmpty { return }
            }

            if case .thinking(let newText) = update.block,
               case .thinking(let existing) = existingType,
               existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               newText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return
            }

            if case .interrupted = existingType {
                return
            }

            items[idx] = ChatHistoryItem(
                id: update.id,
                    type: historyItemType(from: update.block),
                timestamp: originalTimestamp
            )
        } else {
            items.append(ChatHistoryItem(
                id: update.id,
                type: historyItemType(from: update.block),
                timestamp: update.messageTimestamp ?? now
            ))
        }
        orderings[update.id] = update.ordering
    }

    private nonisolated static func applyUpdate(
        _ update: ChatItemUpdate,
        items: inout [ChatHistoryItem]
    ) {
        guard let idx = items.firstIndex(where: { $0.id == update.id }) else {
            return
        }

        let originalTimestamp = items[idx].timestamp
        items[idx] = ChatHistoryItem(
            id: update.id,
            type: historyItemType(from: update.block),
            timestamp: originalTimestamp
        )
    }

    private nonisolated static func applyStatusUpdate(
        _ update: ChatItemUpdate,
        items: inout [ChatHistoryItem]
    ) {
        guard case .toolCall(let block) = update.block,
              let idx = items.firstIndex(where: { $0.id == update.id }),
              case .toolCall(var existing) = items[idx].type else {
            return
        }

        existing.status = block.status
        if let result = block.result {
            existing.result = result
        }
        if let structuredResult = block.structuredResult {
            existing.structuredResult = structuredResult
        }

        if existing.isSubagentContainer && existing.structuredResult == nil {
            let statusString: String = {
                switch existing.status {
                case .success: return "completed"
                case .error: return "error"
                case .interrupted: return "interrupted"
                default: return "unknown"
                }
            }()
            existing.structuredResult = .task(TaskResult(
                agentId: update.id,
                status: statusString,
                content: existing.result ?? "",
                prompt: nil,
                totalDurationMs: nil,
                totalTokens: nil,
                totalToolUseCount: existing.subagentTools.isEmpty ? nil : existing.subagentTools.count
            ))
        }

        items[idx] = ChatHistoryItem(
            id: update.id,
            type: .toolCall(existing),
            timestamp: items[idx].timestamp
        )
    }

    private nonisolated static func historyItemType(from block: ChatItemBlock) -> ChatHistoryItemType {
        switch block {
        case .userPrompt(let text):
            return .user(text)
        case .assistantText(let text):
            return .assistant(text)
        case .thinking(let text):
            return .thinking(text)
        case .toolCall(let tc):
            return .toolCall(ToolCallItem(
                name: tc.name,
                input: tc.input,
                status: tc.status,
                result: tc.result,
                structuredResult: tc.structuredResult,
                subagentTools: tc.subagentTools
            ))
        case .image(let block):
            return .image(block)
        case .interrupted:
            return .interrupted
        }
    }
}
