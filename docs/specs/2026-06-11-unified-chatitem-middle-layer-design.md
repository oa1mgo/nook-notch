# Unified ChatItem Middle Layer — Design Spec

> 调研日期: 2026-06-11
> 状态: 设计阶段（待 Phase 1+2 实施验证）
> 修订: 2026-06-16 — `BlockOrdering` 增加 `.appendOrder` 第四种策略
> 修订: 2026-06-17 — hook placeholder 策略由 ordering 驱动（`SessionProvider.needsHookPlaceholders`）
> 触发: opencode thinking 排序 bug 暴露三种 provider 架构差异

## Revision 2026-06-16 — `.appendOrder` 第四种排序策略

### 动机

Task 4（Claude adapter）实施过程发现原 spec 的 `BlockOrdering` 隐含假设「**所有 provider 都必须让 sorter 主动排序**」—— 这一点对 OpenCode 正确（事件乱序到达），对 Claude **错误**：

Claude JSONL（以及未来 Codex transcript）的特性是 **append-only + monotonic** —— 文件按时间顺序写入，append 顺序天然等于显示顺序。原 spec 把它们套进 `.filePosition(messageIndex, blockIndex)` 后，触发了 incremental sync 路径上的致命 bug：

- `ClaudeChatItemAdapter` 在每次 `scheduleFileSync` 触发时收到的是 `ConversationParser.parseIncremental()` 返回的 **newMessages（只有本次新增）**
- adapter 的 `messages.enumerated()` 让 `messageIndex` 从 0 重置
- 新插入的 chat item ordering 变成 `(0, 0)`、`(0, 1)`，被 `ChatItemSorter` 排到全 chat 顶部
- 视觉表现：最新 assistant text、最新 thinking、`No response requested.` 全部紧贴 user prompt 出现在顶部

HEAD baseline（`SessionStore.upsertBlocks()`）根本不排序，append 顺序就是 jsonl 顺序。中间层引入排序后，反而把原本正确的顺序打乱了。

### 新增 case

`BlockOrdering` 增加 `.appendOrder`：

```swift
enum BlockOrdering: Sendable, Equatable {
    case filePosition(messageIndex: Int, blockIndex: Int)     // ⚠ 仅全量 file parse
    case messageRelative(messageId: String, typePriority: BlockTypePriority, blockIndex: Int)  // OpenCode 事件流
    case timestamp(Date)                                       // fallback
    case appendOrder                                           // append-only + monotonic
}
```

`.appendOrder` 的语义：**provider 声明「append 顺序就是显示顺序，sorter 不应主动改动我」**。

### Sorter 配套改造

`ChatItemSorter.sorted()` 增加 fast path：当所有 items 的 ordering 都是 `.appendOrder` **或 missing** 时，直接返回 `items`，不调 `Array.sorted`。

`missing → 视为信任 append` 是有意为之 —— hook 路径（`processToolTracking`）直接 append item 但不更新 `blockOrderings` 字典，hook item 和 adapter item 混在一起时，hook item 的 ordering 是 missing。fast path 把 missing 等同于 `.appendOrder` 让两种来源的 item 都能正确展示。

### Provider 接入指南

| Provider 数据形态 | 推荐 ordering | 例子 |
|---|---|---|
| append-only + monotonic JSONL / transcript | `.appendOrder` | Claude JSONL, 未来 Codex transcript |
| 事件乱序到达（reasoning / response / tool 交错） | `.messageRelative` | OpenCode |
| 全量 file parse 且 messageIndex 全局稳定 | `.filePosition` | 历史遗留场景 |
| 都不适用 | `.timestamp` 兜底 | — |

> ⚠ **不要在 incremental sync 路径上用 `.filePosition`** —— `messageIndex` 在增量数据上无法保持全局稳定。Claude 的 incremental sync bug 正是踩到这个陷阱。

> **接入新 provider？** 除非你能证明数据源会产生乱序 item，否则默认 `.appendOrder`。OpenCode 是个特例（事件总线 + 异步 part 写入），不能套用这个默认。

### 修订影响

- `Nook/Models/ChatItemUpdate.swift` — `BlockOrdering` 加 `case appendOrder` + 完整 doc
- `Nook/Services/Shared/ChatItemSorter.swift` — fast path + `.appendOrder, .appendOrder → false` 兜底
- `Nook/Services/Hooks/ClaudeChatItemAdapter.swift` — 5 处 `BlockOrdering.filePosition(...)` 改 `.appendOrder`
- Claude adapter spec（`2026-06-16-clause-chatitem-adapter-design.md`）Task 2 ordering 列同步更新

### Revision 2026-06-17 — hook placeholder 策略由 ordering 驱动

#### 动机

`.appendOrder` 修订解决了 **adapter 路径** 的排序问题（sorter fast path 跳过排序），但遗漏了 **hook 路径** 对 ordering 的破坏：

```
时序：
1. Claude 生成响应 [thinking, toolUse(AskUserQuestion)]
2. Hook PreToolUse 立即创建 Question placeholder，timestamp = Date()（T1）
   chatItems: [userPrompt, Question(T1)]
3. JSONL sync 到达 → adapter 创建 thinking(T0)，append 到末尾
   chatItems: [userPrompt, Question(T1), thinking(T0)]
4. ChatItemSorter fast path（全 .appendOrder）→ 返回原序
   结果：Question 在 thinking 前面 ← 回归
```

根因：hook placeholder 用 `Date()` 创建（比 `message.timestamp` 晚），append 到 chatItems 末尾后，adapter 后续 append 的 thinking 只能排在它后面。sorter 的 fast path 忠实地保留了这个错误的 append 顺序。

#### 架构决策

**ordering 策略驱动 hook 路径行为**，而非 provider 名字打补丁：

```swift
// SessionProvider.swift
var needsHookPlaceholders: Bool {
    switch self {
    case .claude, .codex: return false  // append-order，adapter 权威
    case .opencode: return true          // 事件乱序，需要实时占位符
    }
}
```

- `needsHookPlaceholders == false`：hook 只更新 `toolTracker`（生命周期），不创建 chatItem。adapter 的 JSONL/transcript sync 用正确的 `message.timestamp` 创建 items。
- `needsHookPlaceholders == true`：hook 创建实时 placeholder，sorter 负责最终排序。

**为什么不用 `Date()` 修复**：对 append-order provider，任何 hook 创建的 item 都会破坏 append 顺序（Date() 永远 ≥ 最新的 message.timestamp）。唯一正确的做法是不创建。

**为什么不用 position-aware insert**：只解决同消息 case，跨消息 incremental sync 仍然出错（新消息的 thinking 被插到旧消息的 placeholder 前面）。

#### 涉及文件
- `Nook/Models/SessionProvider.swift` — 新增 `needsHookPlaceholders` 属性
- `Nook/Services/State/SessionStore.swift` — `processToolTracking` 和 `processSubagentStarted` 用 `provider.needsHookPlaceholders` 替代 `provider == .claude`

## Overview

Nook 当前支持三种 AI agent provider（Claude Code、OpenCode、Codex），但它们各自以完全不同的方式构建 `chatItems`，导致 SessionStore 成为 provider-specific 逻辑的集中地。本次重构引入一个 provider-agnostic 的中间格式 `ChatItemUpdate`，让所有 provider adapter 输出统一的有序块序列，由 SessionStore 通过单一入口处理。

**核心收益**：
- 修复 opencode thinking 排序 bug（reasoning 出现在 tool 之后）
- SessionStore 从 1916 行降至约 900 行，`process()` 从 30+ case 降至 ~12 case
- 新 provider 接入无需修改 SessionStore
- 移除 ChatView 中 codex 的特殊合并路径

## Architecture

### 当前架构问题

| Provider | 数据源 | 构建方式 | 顺序保证 | ID 方案 |
|---------|-------|---------|---------|---------|
| **Claude** | JSONL 文件 | `upsertBlocks()` 按 blockIndex 有序 upsert | JSONL 结构本身 | `messageId-type-blockIndex` |
| **OpenCode** | 事件总线 (Unix socket) | `processOpencode*()` 逐个 append | 事件到达时序 ⚠️ | `opencode-type-sessionId-timestamp` |
| **Codex** | JSONL transcript + live hooks | `CodexTranscriptParser` 直接构建 + ChatView 合并 | timestamp 排序 | `codex-message-sessionId-lineIndex` / tool call_id |

SessionStore 的 `process()` 包含 30+ case 巨型 switch，ChatView 需要 `!= .codex` 特殊 guard。

**根因**：adapter 输出"原始事件流"而非"规范化消息序列"，SessionStore 用 append 顺序作为展示顺序。

### 目标架构

```
改造前:
  Claude → HookEvent → SessionStore.processHookEvent() → upsertBlocks()
  OpenCode → OpencodeSessionEvent → SessionStore.process(.opencode*) → append
  Codex → CodexSessionEvent → SessionStore.process(.codex*) + ChatView.mergedCodexHistory()

改造后:
  Claude → ClaudeChatItemAdapter → [ChatItemUpdate] ─┐
  OpenCode → OpencodeChatItemAdapter → [ChatItemUpdate] ├→ SessionStore.applyChatItemUpdate()
  Codex → CodexChatItemAdapter → [ChatItemUpdate] ────┘         ↓
                                                          ChatItemSorter.sorted()
```

所有 provider 通过同一个 `applyChatItemUpdate()` 入口，排序由 `ChatItemSorter` 统一保证。

## Data Model

### 1. 核心中间格式

**新文件**: `Nook/Models/ChatItemUpdate.swift`

```swift
struct ChatItemUpdate: Sendable, Identifiable {
    let id: String                    // 稳定唯一标识
    let sessionId: String
    let block: ChatItemBlock          // 内容载荷
    let ordering: BlockOrdering       // 排序信息（解决 opencode 时序 bug 的关键）
    let mutation: BlockMutation       // 操作类型: insert / update / updateStatus
}

enum ChatItemBlock: Sendable, Equatable {
    case userPrompt(String)
    case assistantText(String)
    case thinking(String)
    case toolCall(ToolCallBlock)
    case image(ImageBlock)
    case interrupted
}

struct ToolCallBlock: Sendable, Equatable {
    let toolId: String
    let name: String
    let input: [String: String]
    var status: ToolStatus
    var result: String?
    var structuredResult: ToolResultData?
    var subagentTools: [SubagentToolCall]
    var isError: Bool
}

enum BlockOrdering: Sendable, Equatable {
    case filePosition(messageIndex: Int, blockIndex: Int)                       // ⚠ 仅全量 file parse
    case messageRelative(messageId: String, typePriority: BlockTypePriority, blockIndex: Int)  // OpenCode 事件流
    case timestamp(Date)                                                          // fallback
    case appendOrder                                                              // append-only + monotonic
}

enum BlockMutation: Sendable, Equatable {
    case insert, update, updateStatus, remove
}
```

**关键设计**：`BlockOrdering` 让每个块携带逻辑位置信息。OpenCode 的 `messageRelative(messageId, blockIndex)` 确保即使 thinking 在 tool 之后到达，排序器也能把它放到正确位置。

### 2. 统一 ID 生成器

```swift
enum ChatItemIdFactory {
    /// Claude: 基于 JSONL message ID + block 位置（已有，稳定）
    static func claudeBlockId(messageId: String, typePrefix: String, blockIndex: Int) -> String {
        "\(messageId)-\(typePrefix)-\(blockIndex)"
    }

    /// OpenCode: 基于 message ID + 逻辑块索引（新增，取代 timestamp-based ID）
    static func opencodeBlockId(messageId: String, typePrefix: String, blockIndex: Int) -> String {
        "opencode-\(messageId)-\(typePrefix)-\(blockIndex)"
    }

    /// Codex: 基于 transcript 行号或 call_id（已有）
    static func codexBlockId(sessionId: String, lineIndex: Int) -> String {
        "codex-message-\(sessionId)-\(lineIndex)"
    }

    static func toolId(provider: SessionProvider, rawId: String?) -> String {
        rawId ?? "\(provider.rawValue)-tool-\(Int(Date().timeIntervalSince1970 * 1000))"
    }
}
```

### 3. 排序器

**新文件**: `Nook/Services/Shared/ChatItemSorter.swift`

```swift
enum ChatItemSorter {
    /// Fast path: when every item is .appendOrder or has no ordering
    /// entry, return the input array verbatim — append order is
    /// display order for append-only + monotonic providers, and hook
    /// insertions are intentionally not registered in `orderings`.
    static func sorted(_ items: [ChatHistoryItem], orderings: [String: BlockOrdering]) -> [ChatHistoryItem] {
        if items.allSatisfy({ id in
            guard let o = orderings[id] else { return true }
            if case .appendOrder = o { return true }
            return false
        }) {
            return items
        }
        return items.sorted { a, b in
            compare(orderings[a.id], orderings[b.id], fallbackA: a, fallbackB: b)
        }
    }

    private static func compare(
        _ a: BlockOrdering?, _ b: BlockOrdering?,
        fallbackA: ChatHistoryItem, fallbackB: ChatHistoryItem
    ) -> Bool {
        switch (a, b) {
        case (.filePosition(let mi1, let bi1), .filePosition(let mi2, let bi2)):
            return (mi1, bi1) < (mi2, bi2)
        case (.messageRelative(let m1, let p1, let b1), .messageRelative(let m2, let p2, let b2)):
            // typePriority enforces causal ordering within a message
            if m1 == m2 {
                if p1 != p2 { return p1.rawValue < p2.rawValue }
                return b1 < b2
            }
            return m1 < m2  // messageID 字典序通常等于时间序
        case (.timestamp(let t1), .timestamp(let t2)):
            return t1 < t2
        case (.appendOrder, .appendOrder):
            return false  // fast path 兜底：保持原序
        default:
            return fallbackA.timestamp < fallbackB.timestamp
        }
    }
}
```

## Component Breakdown

### 各 Provider Adapter 的职责

每个 adapter 的职责：**把自身的原始数据翻译成 `[ChatItemUpdate]`**。

#### Claude → `ClaudeChatItemAdapter`

| 关注点 | 实现 |
|-------|------|
| 输入 | `FileUpdatePayload` (JSONL) + `HookEvent` |
| 输出 | `[ChatItemUpdate]` |
| 替代 | `SessionStore.upsertBlocks()` + `processToolTracking()` |
| Ordering | `filePosition(messageIndex, blockIndex)` |
| ID | `messageId-type-blockIndex`（不变） |

```swift
static func updatesFromFilePayload(_ payload: FileUpdatePayload) -> [ChatItemUpdate] {
    var updates: [ChatItemUpdate] = []
    for message in payload.messages {
        for (blockIndex, block) in message.content.enumerated() {
            // ... 映射每个 block 为 ChatItemUpdate
        }
    }
    return updates
}
```

#### OpenCode → `OpencodeChatItemAdapter`（关键改造）

| 关注点 | 实现 |
|-------|------|
| 输入 | `OpencodeSessionEvent` |
| 输出 | `[ChatItemUpdate]` |
| 替代 | 9 个 `processOpencode*()` 方法 |
| Ordering | `messageRelative(messageId, blockIndex)` |
| ID | `opencode-messageId-type-blockIndex`（从 timestamp 改为稳定） |
| 状态 | `blockIndexByMessage: [String: Int]` 计数器 |

```swift
final class OpencodeChatItemAdapter {
    private var blockIndexByMessage: [String: Int] = [:]

    func adapt(_ event: OpencodeSessionEvent) -> [ChatItemUpdate] {
        switch event {
        case .assistantThinking(let sessionId, _, let text):
            let msgId = extractMessageId(from: event)
            let idx = nextBlockIndex(for: msgId)
            return [ChatItemUpdate(
                id: ChatItemIdFactory.opencodeBlockId(messageId: msgId, typePrefix: "thinking", blockIndex: idx),
                sessionId: sessionId,
                block: .thinking(text),
                ordering: .messageRelative(messageId: msgId, blockIndex: idx),
                mutation: .insert,
                provider: .opencode
            )]
        // ... 其他 case 类似
        }
    }

    private func nextBlockIndex(for messageId: String) -> Int {
        let current = blockIndexByMessage[messageId] ?? 0
        blockIndexByMessage[messageId] = current + 1
        return current
    }
}
```

**关键改进**：
- 排序不再依赖事件到达顺序
- `finish=stop` batch flush 时，reasoning 和 text 各自获得正确的 blockIndex
- ID 稳定化 → 事件路径和 JSONL 路径产生相同 ID

#### Codex → `CodexChatItemAdapter`

| 关注点 | 实现 |
|-------|------|
| 输入 | transcript JSONL + `CodexSessionEvent` |
| 输出 | `[ChatItemUpdate]` |
| 替代 | `CodexTranscriptParser` 直接构建 + 4 个 `processCodex*()` + ChatView `mergedCodexHistory()` |
| Ordering | transcript 用 `filePosition`，live 用 `timestamp` |
| ID | `codex-message-sessionId-lineIndex` / tool call_id（不变） |

### SessionStore 简化

**改造前**：`process()` 有 30+ case。

**改造后**：

```swift
enum SessionEvent: Sendable {
    // 统一的 chat item 操作（所有 provider 共用）
    case chatItemUpdate(ChatItemUpdate)
    case chatItemBatch([ChatItemUpdate])

    // 统一的会话生命周期事件
    case sessionStarted(sessionId: String, provider: SessionProvider, cwd: String)
    case sessionStopped(sessionId: String)
    case sessionCleared(sessionId: String)
    case sessionEnded(sessionId: String)

    // 统一的权限事件（provider-agnostic）
    case permissionApproved(sessionId: String, toolUseId: String)
    case permissionDenied(sessionId: String, toolUseId: String, reason: String?)
    case permissionSocketFailed(sessionId: String, toolUseId: String)

    // 统一的 subagent 事件（provider-agnostic）
    case subagentStarted(sessionId: String, taskToolId: String)
    case subagentToolExecuted(sessionId: String, tool: SubagentToolCall)
    case subagentToolCompleted(sessionId: String, toolId: String, status: ToolStatus)
    case subagentStopped(sessionId: String, taskToolId: String)

    // 内部事件
    case loadHistory(sessionId: String, cwd: String)
    case interruptDetected(sessionId: String)
}
```

**核心方法 `applyChatItemUpdate()`**：

```swift
private func applyChatItemUpdate(_ update: ChatItemUpdate) {
    guard var session = sessions[update.sessionId] else { return }

    switch update.mutation {
    case .insert:
        let item = ChatHistoryItem(
            id: update.id,
            type: update.block.toChatHistoryItemType(),
            timestamp: Date()
        )
        if let idx = session.chatItems.firstIndex(where: { $0.id == update.id }) {
            session.chatItems[idx] = item
        } else {
            session.chatItems.append(item)
        }
        blockOrderings[update.id] = update.ordering

    case .update:
        if let idx = session.chatItems.firstIndex(where: { $0.id == update.id }) {
            session.chatItems[idx] = ChatHistoryItem(
                id: update.id,
                type: update.block.toChatHistoryItemType(),
                timestamp: session.chatItems[idx].timestamp
            )
        }

    case .updateStatus:
        if case .toolCall(let block) = update.block,
           let idx = session.chatItems.firstIndex(where: { $0.id == update.id }),
           case .toolCall(var existing) = session.chatItems[idx].type {
            existing.status = block.status
            existing.result = block.result ?? existing.result
            existing.structuredResult = block.structuredResult ?? existing.structuredResult
            session.chatItems[idx] = ChatHistoryItem(
                id: update.id,
                type: .toolCall(existing),
                timestamp: session.chatItems[idx].timestamp
            )
        }

    case .remove:
        session.chatItems.removeAll { $0.id == update.id }
        blockOrderings.removeValue(forKey: update.id)
    }

    // 每次 update 后保证有序
    session.chatItems = ChatItemSorter.sorted(session.chatItems, orderings: blockOrderings)
    sessions[update.sessionId] = session
}
```

### `process()` 简化后

```swift
func process(_ event: SessionEvent) async {
    switch event {
    case .chatItemUpdate(let update):
        applyChatItemUpdate(update)

    case .chatItemBatch(let updates):
        for update in updates {
            applyChatItemUpdate(update)
        }

    case .sessionStarted(let sessionId, let provider, let cwd):
        processSessionStart(sessionId: sessionId, provider: provider, cwd: cwd)

    case .sessionStopped(let sessionId):
        processSessionStop(sessionId: sessionId)

    case .permissionApproved(let sessionId, let toolUseId):
        await processPermissionApproved(sessionId: sessionId, toolUseId: toolUseId)

    // ... 其余 ~8 个 case，全部 provider-agnostic

    case .subagentStarted, .subagentToolExecuted, .subagentToolCompleted, .subagentStopped:
        processSubagentEvent(event)
    }

    publishState()
}
```

## Implementation Plan

按 6 个 Phase 渐进式迁移，每个 Phase 独立可测试：

### Task 1: 基础类型层（~120 行新增，零风险）
- 新建 `Nook/Models/ChatItemUpdate.swift`（类型定义）
- 新建 `Nook/Services/Shared/ChatItemSorter.swift`（排序器）
- 添加 `ChatItemBlock ↔ ChatHistoryItemType` 转换方法

### Task 2: OpenCode Adapter 改造（最高价值，直接修复 bug）
- 新建 `Nook/Services/Hooks/OpencodeChatItemAdapter.swift`
- OpencodeHookAdapter 同时输出 `[ChatItemUpdate]`（双轨运行验证）
- 切换 SessionStore 的 opencode case 到新路径
- 移除 9 个 `processOpencode*` 方法（~350 行）

### Task 3: Codex Adapter 改造
- 新建 `Nook/Services/Hooks/CodexChatItemAdapter.swift`
- `CodexTranscriptParser` 输出转为 `[ChatItemUpdate]`
- 移除 ChatView 中 `mergedCodexHistory()` / `!= .codex` guard / `refreshCodexHistory()`
- 移除 4 个 `processCodex*` 方法（~150 行）

### Task 4: Claude Adapter 改造
- 新建 `Nook/Services/Hooks/ClaudeChatItemAdapter.swift`
- 迁移 `upsertBlocks()` + `processToolTracking()` 到 adapter
- 移除 SessionStore 中 `upsertBlocks` + `processFileUpdate`（~200 行）

### Task 5: SessionEvent 瘦身
- 移除 provider-specific case，统一为 `chatItemUpdate`/`chatItemBatch` + 生命周期事件
- SessionStore `process()` 从 30+ case 缩减为 ~12 case

### Task 6: 清理遗留状态
- `OpencodeHookAdapter` 的 13 个 `static var` 迁移为实例变量
- 添加 session 结束时的状态清理
- 移除 ChatView 的 codex 特殊路径

## Impact Estimate

- **新增** ~800 行（5 个新文件）
- **移除** ~900 行（SessionStore + ChatView 瘦身）
- SessionStore 从 **1916 行降至约 900 行**
- `process()` 从 **30+ case 降至 ~12 case**
- 净减约 100 行代码

## Critical Files

| 文件 | 角色 |
|------|------|
| `Nook/Services/State/SessionStore.swift` | 改造核心（1916 → 900 行） |
| `Nook/Services/Hooks/OpencodeHookAdapter.swift` | thinking bug 根源 |
| `Nook/Services/Hooks/OpencodeHookModels.swift` | 当前 opencode 中间格式 |
| `Nook/Services/Hooks/CodexHookModels.swift` | 当前 codex 中间格式 |
| `Nook/Services/Session/CodexTranscriptParser.swift` | codex JSONL 解析 |
| `Nook/UI/Views/ChatView.swift` | codex 特殊路径所在 |
| `Nook/Services/Chat/ChatHistoryManager.swift` | history 管理 |
| `Nook/Models/SessionEvent.swift` | session event enum（30+ → 12 case） |

## Verification

1. **Task 2 完成后**：运行 opencode session，确认 thinking 出现在 tool 之前
2. **Task 3 完成后**：运行 codex session，确认 transcript + live 合并不丢失 items
3. **Task 4 完成后**：运行 claude session，确认 JSONL 同步行为不变
4. **每个 Task 完成后**：检查 `[chat-history]` 和 `[chat-view]` 诊断日志的 `thinkingCount` / `thinkingIds` 一致性

## Risk & Mitigations

| 风险 | 缓解 |
|------|------|
| 幂等性破坏：事件路径和 JSONL 路径产生不同 ID 导致 upsert 去重失效 | OpenCode 的 messageId 来自 `message.part.updated` 事件，需确认 JSONL 中 message ID 一致 |
| 性能：每次 update 后都排序可能比 append 慢 | 单次 update 用有序插入，仅 batch sync 时整体排序 |
| 向后兼容：每个 Phase 独立可测试 | 旧路径保留一个版本周期作为 fallback |
| Codex 双源合并：transcript + live 的 ID 可能冲突 | ChatItemSorter 的 `filePosition` 排序自然处理 |
| Codex 验证依赖外部协作：项目作者日常不使用 Codex，Task 3 改造无法自行回归验证 | Task 3 单独 PR + `needs-codex-verification` 标签；保留旧路径一个版本周期作为 fallback；双轨运行期日志对比新旧输出一致性；找使用 Codex 的朋友跑一遍验证 checklist |
