# Claude ChatItem Adapter — Design Spec (Task 4)

> 日期: 2026-06-16
> 状态: ⚠ 已实施 — ordering 设计 2026-06-16 修订
> 前置: [Unified ChatItem Middle Layer Design](2026-06-11-unified-chatitem-middle-layer-design.md) — Task 1 + Task 2 已完成
> 触发: 将 Claude provider 接入统一 ChatItemUpdate 管道

> **修订记录 2026-06-16** — `BlockOrdering.filePosition(messageIndex, blockIndex)` 替换为
> `BlockOrdering.appendOrder`。详见 [base design Revision 2026-06-16](2026-06-11-unified-chatitem-middle-layer-design.md#revision-2026-06-16--appendorder-第四种排序策略)。
>
> **修订原因**：原 `.filePosition` 假设 `messageIndex` 在每次 `messages.enumerated()` 后全局稳定。
> 但 `ConversationParser.parseIncremental()` 在 incremental sync 路径上只返回本次新增的
> `newMessages`，导致新消息 `messageIndex` 从 0 重置、被 `ChatItemSorter` 排到全 chat 顶部
> （最终 assistant text、最新 thinking、`No response requested.` 全部贴到 user prompt 下面）。
>
> Claude JSONL 是 append-only + monotonic，append 顺序天然就是显示顺序 — 用 `.appendOrder`
> 让 `ChatItemSorter` 走 fast path 直接返回 items，**保留 HEAD baseline 的正确展示顺序**。

## Overview

统一 ChatItem 中间层的 Task 1（基础类型）和 Task 2（OpenCode adapter）已完成。本次设计覆盖 Task 4：将 Claude 的 chat item 构建逻辑从 `SessionStore` 提取到 `ClaudeChatItemAdapter`，让 Claude 走统一管道 `ClaudeChatItemAdapter → [ChatItemUpdate] → SessionStore.applyChatItemUpdate()`。

**核心收益**：移除 `upsertBlocks()` (~155 行)，Claude 与 OpenCode 走统一渲染管线，为 Task 5（SessionEvent 瘦身）铺路。

## 架构关键决策

### Claude 的双路径架构

Claude 与 OpenCode 有本质区别：
- **OpenCode**：事件驱动，每个事件实时产生一个 chat item → adapter 是事件级的
- **Claude**：双路径——hook 事件创建实时占位符，JSONL 文件同步是权威数据源

```
Hook 路径 (实时):  HookEvent → processHookEvent() → processToolTracking() → 直接创建 chatItems
JSONL 路径 (权威): scheduleFileSync() → ConversationParser → processFileUpdate() → upsertBlocks()
```

### 只迁移 JSONL 路径，保留 Hook 路径

**关键发现**：`applyChatItemUpdate()` 行 794-863 有重大生命周期副作用（phase 转换、conversationInfo 更新、`enrichOpencodeRuntimeMetadata`）。这些副作用是为 OpenCode 实时事件流设计的。如果 Claude hook 路径也走 adapter，这些副作用会：

1. **Phase 闪烁**：JSONL 批量处理时 toolCall→processing, text→idle 快速交替
2. **conversationInfo 覆盖**：覆盖 `processFileUpdate()` 中 ConversationParser 的结果
3. **toolTracker 重复更新**：`processToolTracking()` 已经管理

因此 **只迁移 JSONL 路径**，Hook 路径保持 `processToolTracking()` 直接操作 chatItems。

### `applyChatItemUpdate()` 副作用隔离

为 Claude 的 JSONL batch 添加 provider guard，跳过 OpenCode 专属的生命周期副作用：

```swift
// 行 794-863: 只对 OpenCode 执行生命周期副作用
// Claude 的 phase/conversationInfo 由 processHookEvent/processFileUpdate 管理
if update.provider == .opencode {
    enrichOpencodeRuntimeMetadata(session: &session)
    session.lastActivity = now
    // ... phase transitions, conversationInfo, toolTracker ...
}
```

---

## Implementation Plan

### Task 1: 增强 `applyChatItemUpdate()` — 匹配 upsertBlocks 语义

**文件**: `Nook/Services/State/SessionStore.swift`

当前 `.insert` 对已存在 item 做全量替换（仅保留 timestamp）。需增强为与 `upsertBlocks()` 一致的 upsert 语义：

#### 1a: tool call 运行时状态保留（对应 upsertBlocks 行 1590-1604）

当 `.insert` 命中已存在的 toolCall item 时：
- 保留 `status`、`result`、`structuredResult`、`subagentTools`（来自 hook 路径的实时状态）
- 更新 `name`、`input`（JSONL 可能有更完整的结构化数据）

#### 1b: 文本去重（对应 upsertBlocks 行 1632-1659）

- 已存在的 `.user` prompt 不被覆盖（early return）
- assistant text: 不覆盖 non-empty→empty，不覆盖 empty→empty

#### 1c: thinking 去重（对应 upsertBlocks 行 1661-1684）

- 已存在且 both empty → skip
- 新增空 thinking → 由现有 guard（行 703-707）拦截

#### 1d: interrupted 去重（对应 upsertBlocks 行 1702-1710）

- 已存在 → skip（interrupted 只插入一次）

#### 1e: 生命周期副作用 provider 隔离

在行 794 的 `if update.mutation == .insert || ...` 块外层加 `if update.provider == .opencode` guard，确保 Claude 的 batch JSONL updates 不触发 OpenCode 专属的 phase/conversationInfo/toolTracker 副作用。

**兼容性**：这些增强对所有 provider 通用安全。OpenCode 的 `.insert` 对已存在 toolCall 保留状态也是正确行为（防止重入时状态回退）。

---

### Task 2: 创建 `ClaudeChatItemAdapter`

**新文件**: `Nook/Services/Hooks/ClaudeChatItemAdapter.swift`

#### 设计

```swift
/// Stateless adapter: Claude JSONL → [ChatItemUpdate]
/// 无状态原因：JSONL messages 自带稳定 ID (message.id) + blockIndex (enumeration)
enum ClaudeChatItemAdapter {
    static func updates(fromFileUpdate payload: FileUpdatePayload) -> [ChatItemUpdate]
    static func updates(fromHistoryLoad messages: [ChatMessage], ...) -> [ChatItemUpdate]
}
```

#### 核心方法: `updates(fromFileUpdate:)`

遍历 `payload.messages` 的每个 message（带 messageIndex）的每个 block（带 blockIndex）：

| MessageBlock | ChatItemBlock | ID | Ordering |
|---|---|---|---|
| `.text` + user role | `.userPrompt(text)` | `messageId-text-blockIndex` | `.appendOrder` |
| `.text` + assistant role | `.assistantText(text)` | `messageId-text-blockIndex` | `.appendOrder` |
| `.thinking(text)` | `.thinking(text)` — 空则 skip | `messageId-thinking-blockIndex` | `.appendOrder` |
| `.toolUse(tool)` | `.toolCall(ChatItemToolCall(...))` | `tool.id`（JSONL 全局唯一） | `.appendOrder` |
| `.image(block)` | `.image(block)` | `messageId-image-blockIndex` | `.appendOrder` |
| `.interrupted` | `.interrupted` | `messageId-interrupted-blockIndex` | `.appendOrder` |

所有 mutation 均为 `.insert`（adapter 不感知 session 状态，upsert 由 `applyChatItemUpdate()` 处理）。

**tool call 特殊处理**：
- status: `completedToolIds.contains(tool.id) ? .success : .running`
- result: 从 `toolResults[tool.id]` 提取（stdout > stderr > content）
- structuredResult: `structuredResults[tool.id]`
- subagentTools: `[]`（由后续 `populateSubagentToolsFromAgentFiles()` 填充）

#### 辅助方法

```swift
private static func extractToolResult(
    _ toolId: String,
    from results: [String: ConversationParser.ToolResult]
) -> String?
```

---

### Task 3: 迁移 JSONL 同步路径

**文件**: `Nook/Services/State/SessionStore.swift`

#### 3a: `processFileUpdate()` 迁移

替换 `upsertBlocks()` 调用（行 1452-1458）为：

```swift
let updates = ClaudeChatItemAdapter.updates(fromFileUpdate: payload)
for update in updates {
    applyChatItemUpdate(update)
}
```

保留不变：
- conversationInfo 解析（行 1414-1418）
- clear reconciliation（行 1420-1450）
- `toolTracker.lastSyncTime`（行 1464）
- `populateSubagentToolsFromAgentFiles()`（行 1466-1471）
- `emitToolCompletionEvents()`（行 1475-1481）

移除：non-incremental sort（行 1460-1462）— `ChatItemSorter` 在每次 `applyChatItemUpdate()` 后自动排序。

#### 3b: `processHistoryLoaded()` 迁移

替换 `upsertBlocks()` 调用（行 1831-1837）为 adapter 调用。移除 timestamp sort（行 1840）。

---

### Task 4: 清理

#### 4a: 移除 `upsertBlocks()` 静态方法（行 1560-1714，~155 行）

#### 4b: 添加 `ClaudeChatItemAdapter.swift` 到 Xcode 项目

#### 预期行数变化
- **新增**: ~150 行（adapter）+ ~40 行（applyChatItemUpdate 增强）
- **移除**: ~160 行（upsertBlocks + non-incremental sort）
- **净变化**: ~+30 行（SessionStore 净减 ~120 行，新增 adapter 文件 ~150 行）

---

### Task 5: 验证

#### 编译验证
`xcodebuild` 确认编译通过。

#### 功能验证清单

| 场景 | 预期行为 |
|---|---|
| 启动 Claude session，执行简单操作 | text/thinking/tool 正确显示，排序正确 |
| Tool call 生命周期 | Hook 创建 running placeholder → JSONL sync 保留状态，更新 input |
| `/clear` 后 re-sync | Clear reconciliation 正确过滤，新消息正确显示 |
| 历史加载 | 重启后 chat items 正确恢复，appendOrder（保持 append 顺序）正确 |
| Subagent (Task/Agent) | subagent tools 正确挂载到父 Task，populateSubagentTools 正常工作 |
| PermissionRequest | `updateToolStatus()` 路径不受影响 |
| 空 thinking/text | 去重规则正确：空 thinking 不插入，空→空 text 不更新，非空→空 assistant text 不覆盖 |

#### 诊断日志
- `[chat-item-update]` 日志的 `totalItems` 与迁移前一致
- `[chat-history]` / `[chat-view]` thinkingCount 一致性

---

## 不在本次范围

- **Hook 路径迁移**（`processToolTracking()` → adapter）：因 `applyChatItemUpdate()` 生命周期副作用问题，保留原路径。Task 5 SessionEvent 瘦身时可重新评估。
- **Codex adapter（Task 3）**：独立任务
- **`processToolTracking()` 移除**：仍需要为 hook 路径创建实时占位符
- **`toolTracker` 移除**：仍用于 `lastSyncTime` 和 `hasRunningTools()`

## 涉及文件

| 文件 | 改动 |
|------|------|
| `Nook/Services/Hooks/ClaudeChatItemAdapter.swift` | **新建** — 无状态 adapter |
| `Nook/Services/State/SessionStore.swift` | 增强 `applyChatItemUpdate()`；迁移 `processFileUpdate()` / `processHistoryLoaded()`；移除 `upsertBlocks()` |
| `Nook.xcodeproj/project.pbxproj` | 添加新文件引用 |
