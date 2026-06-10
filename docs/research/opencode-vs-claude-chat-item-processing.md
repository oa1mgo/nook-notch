# OpenCode vs Claude Provider: Chat Item Processing Differences

> 调研日期: 2026-06-10
> 研究范围: Nook 中 `.opencode` 与 `.claude` 两种 provider 在 ChatHistoryItem 创建/更新链路上的全部差异

---

## 1. 架构全景

Nook 的双 provider 路径：

```
Claude Code (hooks)              OpenCode (event bus)
       │                                │
       ▼                                ▼
HookSocketServer              OpencodeHookAdapter
  └─ HookEvent                  └─ OpencodeSessionEvent
       │                                │
       ▼                                ▼
SessionStore.process(.hookReceived)    ClaudeSessionMonitor → SessionStore.process(.opencode*)
       │                                │
       ▼                                ▼
  ChatHistoryItem ◄──────── JSONL ◄─────┘
       (upsertBlocks)
```

核心差异：Claude 依赖 **JSONL 文件同步** 作为数据主干（hooks 只发控制信号），OpenCode 则通过 **事件总线** 直接驱动状态更新。

---

## 2. 事件入口对比

| 方面 | Claude (HookEvent) | OpenCode (OpencodeSessionEvent) |
|------|-------------------|----------------------------------|
| 传输层 | Unix domain socket | Unix domain socket（同端口，不同信封） |
| 解码目标 | `HookEvent` (AnyCodable) | `OpencodeHookEnvelope` (typed) |
| 路由函数 | `processHookEvent()` | `ClaudeSessionMonitor` → `SessionStore.process(.opencode*)` |
| JSONL 同步 | 每次事件触发 `shouldSyncFile` | 不由事件触发，仅靠定期检查 |
| Session 创建 | `createSession(from:)` → `.claude` | `createOpencodeSession()` → `.opencode` |

---

## 3. ChatHistoryItem 创建路径

### 3.1 用户消息

| | Claude | OpenCode |
|---|---|---|
| 来源 | JSONL `"role":"user"` block，经 `upsertBlocks` | 事件 `opencodePromptSubmitted` |
| 处理函数 | `upsertBlocks()` → `.user` case | `processOpencodePromptSubmitted()` |
| Item ID | `"\(message.id)-text-\(blockIndex)"` | `"opencode-prompt-\(sessionId)-\(timestamp)"` |
| 触发时机 | 文件同步（滞后） | 实时（毫秒级） |

### 3.2 助手文本

| | Claude | OpenCode |
|---|---|---|
| 来源 | JSONL `"role":"assistant"` block | 事件 `opencodeAssistantText` |
| 处理函数 | `upsertBlocks()` → `.text` case | `processOpencodeAssistantText()` |
| Item ID | `"\(message.id)-text-\(blockIndex)"` | `"opencode-assistant-\(sessionId)-\(timestamp)"` |
| 触发时机 | 文件同步（滞后） | 实时（flush 时） |
| 去重机制 | update by ID（幂等） | safety net `alreadyEmitted` 标记 |

### 3.3 Thinking 块

**这是差异最大的区域。** Claude 和 OpenCode 的 thinking block 不仅来源不同，缓存和路由逻辑也完全不同。

| | Claude | OpenCode |
|---|---|---|
| 来源 | JSONL `"type":"thinking"` block | 适配器 `message.part.updated(type=reasoning)` + delta |
| 处理函数 | `upsertBlocks()` → `.thinking` case | `processOpencodeAssistantThinking()` |
| Item ID | `"\(message.id)-thinking-\(blockIndex)"` | `"opencode-thinking-\(sessionId)-\(timestamp)"` |
| 到达时机 | 文件同步时批量到达 | 逐 delta 实时流式到达 |
| 空内容过滤 | 允许空文本（后续原地更新） | `trimmedText.isEmpty` 直接丢弃 |
| 额外逻辑 | 无 | 需要 handling reasoning-finalized routing（#73） |

**OpenCode 特有的 reasoning 处理管道（OpencodeHookAdapter 内）：**

```
message.part.updated(type=reasoning, text="")
  → knownReasoningMessageIds.insert(messageId)
  → handleReasoningPart → 发出 assistantThinking

message.part.delta(field=text, delta=...)
  → handlePartDelta → routing 选择器：
    isKnownReasoning && !isReasoningFinalized → pendingReasoningByMessage
    else → pendingTextByMessage

message.part.updated(type=reasoning, text="完整内容")
  → handleReasoningPart → reasoningFinalizedMessageIds.insert
  → 首次 emit assistantThinking，后续 delta 走 text 路由
```

### 3.4 工具调用

| | Claude | OpenCode |
|---|---|---|
| 创建事件 | Hook `PreToolUse` | Event `opencodeToolStarted` |
| 完成事件 | Hook `PostToolUse` | Event `opencodeToolFinished` |
| 创建函数 | `processToolTracking()` | `processOpencodeToolStarted()` |
| 输入 key | `"description"`（来自 `toolInput` dict） | `"command"`（非 task）或 `"description"`（task） |
| 状态设置 | `.success`（PostToolUse 无 error 信号） | `.error` 或 `.success`（通过 bash metadata 检测） |
| 结果存储 | `structuredResult`（JSONL 解析） | `result = output ?? error`（Route A，不做结构化解析） |
| task 容器跳过 | 无特殊处理 | `toolKind != .task` 才 stamp result |

**OpenCode 特有的工具完成处理：**

```
processOpencodeToolFinished:
  ToolKind.classify(toolName)
  isBash → tailContainsBashMetadata(output) → finalStatus
  outputIsError = error.isEmpty == false || (isBash && hasMetadataFooter)
  finalStatus = outputIsError ? .error : .success
  toolTracker.completeTool(id, success: !outputIsError)
  updateToolStatus(id, status: finalStatus)
  result stamping（跳过 .task）
```

### 3.5 子 agent 处理

| | Claude | OpenCode |
|---|---|---|
| 容器创建 | `PreToolUse` tool=Task/Agent → `subagentState.startTask()` | `subagentStarted` + `preTool` tool=task |
| 子工具来源 | Agent JSONL 文件解析 | 实时事件 `subagentToolExecuted` |
| 子工具填充 | `populateSubagentToolsFromAgentFiles()` | 直接 `subagentState.addSubagentTool()` + `syncSubagentToolsToChatItems()` |
| 子内容过滤 | 不适用（hook 不路由子 agent 内容） | 适配器级别抑制（`lastTaskPreMessageID` 窗口） |

---

## 4. 关键差异摘要

### 4.1 Thinking 块的双源问题

OpenCode 的 thinking block 会 **同时来自两个路径**：
1. 事件路径：`processOpencodeAssistantThinking()` → 实时创建 `ChatHistoryItem`
2. JSONL 路径：下次 `ChatHistoryManager` 轮询时，`upsertBlocks()` 又从 JSONL 文件中读到同一 thinking 块

目前通过 `emittedReasoningMessages` + safety net 中的 `alreadyEmitted` 检查去重。但如果 JSONL 中的 ID 与事件创建的 ID 不同（opencode-thinking-xxx vs message.id-thinking-yyy），**可能产生重复 render**。

### 4.2 Delta routing 的提供者特异性

OpenCode v1.15.13 中 `field=text` delta 既用于 reasoning 也用于 text，需要通过 `knownReasoningMessageIds` + `reasoningFinalizedMessageIds` 双重判断路由目标。Claude 不存在此问题（JSONL 中块类型明确）。

### 4.3 工具完成状态检测

| 场景 | Claude | OpenCode |
|------|--------|----------|
| 成功 | `status: .success` | `finalStatus: .success` |
| 超时 | 无信号（JSONL 可能不更新） | `tailContainsBashMetadata` → `.error` |
| 非零退出 | 无信号 | `tailContainsBashMetadata` → `.error` |
| 抛异常 | 无信号（PostToolUse 无 error） | `error != nil` → `.error` |

### 4.4 工具结果模型差异

| | Claude | OpenCode |
|---|---|---|
| 结果存储 | `structuredResult: ToolResultData`（JSONL 解析） | `result: String?`（纯文本，Route A） |
| 结构化解析 | `parseToolResultBlock()` + `extractStructuredResult()` | 无（显式选择 Route A） |
| 内容预览 | 结构化摘要（文件名、diff 统计） | 原始输出（可能很长） |

### 4.5 会话阶段机差异

| | Claude | OpenCode |
|---|---|---|
| Phase 控制 | `HookEvent.determinePhase()` + `SessionPhase.canTransition()` | `SessionStore` 直接设置 |
| Processing 判断 | 根据 hook `phase` 字段 | `hasRunningTools(in:)` |
| WaitingForInput | `question.asked` 事件 | `opencodeWaitingForUserInput` 事件 |
| **已知 Bug** | — | `processOpencodeToolStarted` 无条件覆盖 `.waitingForInput` 为 `.processing`（见 L623 注释） |

---

## 5. 共享路径：JSONL upsertBlocks

两条路径共享同一个 JSONL 文件同步机制。`upsertBlocks()` 包含对各提供者 ID 模式的适配：

```swift
// Claude: update existing runtime tool state (不覆盖 status/result)
if let existingIdx = session.chatItems.firstIndex(where: { $0.id == block.id }),
   case .toolCall(let existingTool) = session.chatItems[existingIdx].type {
    // 保留运行时状态
}

// OpenCode: 不覆盖已有的 user text
if case .user = existing.type { /* 保留原有用户文本 */ }
```

关键的幂等性假设：**ID 唯一性**。如果事件路径和 JSONL 路径对同一逻辑内容使用了不同的 ID 模式，幂等性就被破坏了。

---

## 6. OpenCode 特有功能（Claude 不适用）

| 功能 | 位置 | 说明 |
|------|------|------|
| 用户 prompt 尾部 echo 抑制 | `handleTextPart` L676-694 | opencode 在 reasoning messageID 上回显用户 prompt |
| Reasoning 追踪管道 | `handlePartDelta` L577-605 | `field=text` 的双路由歧义 |
| Subagent 窗口抑制 | `handleToolPart` L836-838 | 适配器级抑制 subagent 文本/思考 |
| Bash metadata 检测 | `tailContainsBashMetadata` L578-584 | 非零退出/超时检测 |
| Question 父消息抑制 | `suppressedTextMessages` L131 | question 工具的 parent assistant text 不应渲染 |
| 运行中进程发现 | `bestMatchingOpencodeProcess` | 通过 `ps` 发现 opencode 子进程 |

---

## 7. 潜在问题清单

1. **Thinking 块可能重复**：当事件路径和 JSONL 路径的 ID 不同时，`upsertBlocks` 无法去重
2. **Phase 覆盖时序**：`processOpencodeToolStarted` 的 `session.phase = .processing` 会覆盖 `processOpencodeWaitingForUserInput` 设置的 `.waitingForInput`
3. **工具结果无结构化解析**：Route A 意味着所有工具输出都是原始文本，task 容器的结果不会在 UI 中显示摘要
4. **static var 内存泄漏**：事件驱动的状态（`consumedUserMessageIDs`、`reasoningFinalizedMessageIds` 等）与上次提交分析的 13 个字段一样，永远不会被清理
5. **Claude 路径没有工具 error 检测**：PostToolUse 没有 error 信号，所有工具都标记为 `.success`
