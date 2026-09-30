# Bug: OpenCode subagent child session 触发 Nook 顶部"新会话"

> 日期: 2026-07-23 调查并修复
> 状态: 🟢 已修复（三层）
>   - **主修复 (方案 A)**: SessionStore registeredSessionIds 白名单
>   - **根因修复 B**: `adaptSubagentEvent` `session.status` / `session.idle` 拆分，避免 busy 触发 cleanupState
>   - **漏网修复 C (07-24)**: 让 `createOpencodeSession` / `createCodexSession` / `createSession` 内部自注册——修复"Nook 启动后感知不到 OpenCode 已存在 session"导致 chat-item 被 drop 的回归
> Owner: SessionStore (`Nook/Services/State/SessionStore.swift`) + OpencodeHookAdapter (`Nook/Services/Hooks/OpencodeHookAdapter.swift`)
> 关联日志: `docs/debug/2026-07-23-subagent-cleanup-bug.nook-debug.log` (7.1MB)

## 症状

用户跑一个会触发 opencode subagent (Task tool) 的任务，Nook 顶部 session 列表里**会出现新的 session 条目**（childId 的 `SessionState`），触发 completion sound/bounce。预期是 subagent 事件折叠在父会话的 tool list 里，不应该出现新条目。

## 关键事实（根因调查）

### OpenCode subagent 模型

opencode 的 `Task` tool 会为每个 subagent 创建一个独立 session（`parentID` 字段指向父 session）。Nook 协议上把 subagent session 折叠进父会话的 `subagentState`，不显示为顶层 session。

`OpencodeHookAdapter.swift` 的两层防护：

1. `subagentToParent` 映射表（L156-169）：`session.created` / `session.updated` 携带 `info.parentID` 时，记录到映射。**不发送** `.sessionStart`（L404-406）→ SessionStore 不会创建新 SessionState。
2. 事件路由拦截（L224-233）：`adapt()` 入口 `lookupParent(for: sessionId)` 命中后，所有事件走 `adaptSubagentEvent`，**不进入** per-session handlers。

### 真正的 bug：`adaptSubagentEvent` 自毁注册

`OpencodeHookAdapter.swift:301-315`:

```swift
case "session.status", "session.idle":
    // Subagent session is going idle — flush any text/reasoning buffers
    // that were accidentally accumulated for the child (...)
    let cwd: String = {...}
    let flushed = flushPendingText(forSession: childId, cwd: cwd)
    cleanupState(forSession: childId)   // ← 这里清空 subagentToParent[childId]！
    Self.logNotice("→ subagent stop routed to parent child=\(childId) ...")
    return flushed
```

`session.status` 和 `session.idle` 共用一个 case，都调用 `cleanupState`。**结果是 subagent child 的第一次 `session.status=busy` 就清空 `subagentToParent[childId]`**。

### 后续所有 child 事件都泄漏

`cleanupState` 清空 `subagentToParent[childId]` 后，`adapt()` 入口 `lookupParent` 返回 nil → 事件走 per-session handlers → emit 携带 childId 的 `OpencodeSessionEvent` → SessionStore 收到 `.realtimeChatItemBatch(updates with childId)` → `applyChatItemUpdate` 在 `sessions[childId] == nil` 时走 auto-create 路径（L1075-1087）→ 创建独立 `SessionState`。

### 完整事件链（child `ses_0724b89e2ffeEhEaBxGUi53XTh`，从同一次跑任务的日志）

```
T+0ms    session.status=busy for childId
         → subagent routing HIT
         → subagent stop routed to parent child=... flushed=0   ← cleanupState 清空了映射
T+30ms+  message.part.updated for childId                        ← 不再 routing HIT，泄漏
         → handlePartUpdated 返回 .assistantThinking(sessionId: childId, ...)
T+Nms    session.status=busy for childId                        ← 走 per-session handler
         → processingStarted session=<childId> cwd=             ← 接收方按 childId 路由
T+Nms    session.status=idle for childId
         → idle (between ops) session=<childId> flushed=0
T+Nms    session.idle for childId
         → cleanup session=<childId> messages=1
         → stop (legacy session.idle) session=<childId>         ← 走了 per-session handler！
T+Nms    [completion-notification] published ... session=<childId>
         [notch-notification] completionReceived session=<childId>
         [notch-notification] soundPlayed                       ← UI 看到"新会话"
```

## 日志统计（来自归档日志）

| 指标 | 数量 | 含义 |
|---|---|---|
| `DIAG #79` 命中 | 88 | preRegCount > 0，竞态条件存在 |
| `subagent routing HIT` | 240 | 注册后事件正确路由 |
| `subagent stop routed to parent` | 9 (含 childId) | subagent 实际终止事件 |
| `sessionStart (first sighting)` | 4 | 父会话，正常 |
| `auto-created session` (SessionStore L1082) | **0** | auto-create 路径**未触发** |
| `assistantThinking (final) session=<childId>` | **66** | 泄漏的 child reasoning，被默默写进 (不存在的) chatItems |
| `completion-notification published` 用 childId | **8** | `processOpencodeStop` 触发，UI 弹"新会话" |

> `auto-created session` 0 次看似反直觉——但日志是 SessionStore L1082 的 `DebugLog.shared.write` 路径，事件实际由 `processOpencodeStop` 走到 `createOpencodeSession`（L783）创建 SessionState，那个路径**不写** auto-created log（`createOpencodeSession` 是 helper）。所以日志不可见，但 SessionState 真实创建了。

## 修复方案对比

### 方案 A：SessionStore registeredSessionIds 白名单（采用）

**核心**：在 SessionStore 维护 `registeredSessionIds: Set<String>`，由各 provider 的 SessionStarted 路径填充。`realtimeChatItemBatch` / `chatItemBatch` / `chatItemUpdate` 入口过滤：未注册的 sessionId 直接 drop，不走 auto-create。

**优雅之处**：
- 不依赖 `OpencodeHookAdapter` 的 subagent 路由正确性（即使将来再出新 bug 也不会泄漏）
- 任何 subagent event（无论是否泄漏、何时泄漏）→ childId 不在白名单 → drop
- 不需要 DIAG #79 buffer
- 不需要修 `cleanupState` 时序
- 不需要拆分 `adaptSubagentEvent` 的 case
- 适用于未来所有 provider

**改动**（`SessionStore.swift`）：

1. 加字段 `private var registeredSessionIds: Set<String> = []` (L78)
2. `process()` 入口在 `codexSessionStarted` / `opencodeSessionStarted` / `cursorSessionStarted` 三个 case 各加一行 `registerSession(sessionId:)`
3. `processHookEvent` (Claude) 在 `isNewSession` 分支加 `registerSession`
4. `realtimeChatItemBatch` / `chatItemBatch` / `chatItemUpdate` 三个 case 改用 `applyChatItemUpdateIfRegistered` helper
5. 5 个 `sessions.removeValue` 清理点加 `unregisterSession`

helper：
```swift
private func applyChatItemUpdateIfRegistered(
    _ update: ChatItemUpdate,
    appliesLifecycleEffects: Bool = false
) {
    if !registeredSessionIds.contains(update.sessionId) {
        writeDebugLogAsync("[chat-item-update] dropped unregistered session=...")
        return
    }
    applyChatItemUpdate(update, appliesLifecycleEffects: appliesLifecycleEffects)
}
```

### 方案 B（采用为根因修复）：修 `adaptSubagentEvent` 不 cleanup

把 `OpencodeHookAdapter.swift:301` 拆成两个 case，只在 `session.idle` 和 `session.status=idle` 清理。`session.status=busy` 不清理映射。

**修复后**：

```swift
case "session.status":
    // session.status fires for both busy (work started) and idle
    // (between ops or truly ended). Only the *terminal* idle should
    // clear the subagent mapping — `session.status=busy` is the
    // subagent starting work, and clearing then would drop the
    // mapping while the subagent is still alive (...)
    let statusType = (props["status"]?.value as? [String: Any])?["type"] as? String ?? ""
    guard statusType == "idle" else { return [] }
    return finalizeSubagent(childId: childId, parentId: parentId)

case "session.idle":
    // Legacy compatibility event — subagent has truly terminated.
    return finalizeSubagent(childId: childId, parentId: parentId)
```

`finalizeSubagent` 是提取的 helper（原 301-315 那段逻辑），只在真正终止时调用 `cleanupState`。

**为什么这个修复也重要**：
- 方案 A 是"上游兜底"——SessionStore 拒绝未知 sessionId 的 chat-item update
- 方案 B 是"根因修复"——修复 cleanup 时序本身，让 subagent 路由正常工作（不再泄漏 event 到 per-session handlers）
- 两者叠加：方案 B 减少了泄漏（让 adaptSubagentEvent 正常工作），方案 A 兜底确保即使将来再出类似 bug 也不会出现"新会话"

### 方案 C（漏网 bug，2026-07-24 发现并修复）：self-register on createOpencodeSession

**症状回归**：方案 A + B 上线后次日，跑 motelet session 触发 subagent 的任务，**Nook ChatView 里只能看到一个 subagent 信息**（父会话 chatItems 缺失）。终端里 opencode 显示所有消息都正常发出。

**根因**：
1. Nook 进程在 09:30:48 启动（pid 53003）
2. motelet session `ses_06d2d7f5dffez1i9bv7h8WeOS1` 在 OpenCode 中**早已存在**（06:31 创建），Nook 启动时 OpenCode 没有重发 session.created
3. `registeredSessionIds` 在新进程启动时是空 Set —— 没有 sessionStart passthrough 触发注册
4. motelet session 持续 emit `session.status=busy` → `processOpencodeProcessingStarted` → `sessions[sessionId] ?? createOpencodeSession(...)` 创建 SessionState，但**没注册到 `registeredSessionIds`**
5. 后续 user prompt 走 `realtimeChatItemBatch` → `applyChatItemUpdateIfRegistered` wrapper → unregistered → **drop**（46 次 drop）
6. subagent events 走 `subagentToolExecuted(sessionId: parentId)` → `processSubagentToolExecuted` 用 `guard var session = sessions[sessionId]` 直接读 sessions dict → 正常处理（绕过 wrapper）

**日志证据**：
```
08:45:39.992Z  → userPromptSubmit (text part matched) session=ses_06d2d7f5
08:45:39.993Z  [chat-item-update] dropped unregistered session=ses_06d2d7f5
08:45:39.995Z  → processingStarted (session.status=busy) session=ses_06d2d7f5   ← 创建 SessionState
... 46 次 drop ...
08:48:46.256Z  [session-store] subagent tool executed session=ses_06d2d7f5 ... ← 正常
```

**修复**（`SessionStore.swift`）：让 `createOpencodeSession` / `createCodexSession` / `createSession(from:)` 内部调用 `registerSession`。任何路径创建 SessionState 都自动注册。

```swift
private func createOpencodeSession(sessionId: String, cwd: String) -> SessionState {
    // Self-register: callers like processOpencodeProcessingStarted,
    // processOpencodeStop, and processOpencodePermissionRequested
    // bootstrap a SessionState here when Nook missed the original
    // session.created event (e.g. the session existed in OpenCode
    // before Nook launched (...) Without the registration, the
    // applyChatItemUpdateIfRegistered filter downstream would drop
    // every subsequent chat-item update for this session — silently
    // hiding everything the user typed from the ChatView.
    registerSession(sessionId: sessionId)
    return SessionState(...)
}
```

**为什么这是优雅的修复**：
- 单一 source of truth：`createXxxSession` 是 SessionState 创建的唯一入口（5 处 `?? createXxxSession` 都走这里）
- 不需要在每个 `processOpencodeProcessingStarted` 等位置手动加 registerSession
- 幂等：`Set.insert` 重复调用无害
- subagent child 仍然走 wrapper drop（永远不会被这 3 个 helper 创建 SessionState——它们收到的是 childId 吗？答：subagent child 的 event 在 OpencodeHookAdapter 已经被路由到 `subagentToolExecuted(sessionId: parentId)`，所以 `processOpencodeProcessingStarted` 等处理 subagent event 时用的是 parentId）

### 方案 D（未来）：subagent 事件改写

让所有 subagent 事件携带 `parentId` 作为 sessionId，从源头让 SessionStore 看到的就是 parent sessionId。重构较大，留待未来真需要 subagent 作为顶层概念时再做。

## 验证

### Build
```
xcodebuild ... build
** BUILD SUCCEEDED **
```

### Test
```
xcodebuild ... test
** TEST SUCCEEDED **
Executed 25 tests, with 0 failures (0 unexpected) in 0.347 seconds
```

### 烟测步骤（用户跑 subagent 任务后验证）

跑触发 Task tool 的任务，然后：

```bash
grep "dropped unregistered" /tmp/nook-debug.log | head -10
# 预期：看到 subagent childId 的 drop 日志（childId 不在白名单）

grep "completion-notification.*published" /tmp/nook-debug.log
# 预期：只有父会话 ID 触发 completion notification，不再有 childId
```

## 相关代码位置

- SessionStore 主改（方案 A + C）：`Nook/Services/State/SessionStore.swift`
  - 字段定义：L78
  - 各 sessionStart 注册（入口）：L117, L154, L174
  - chat-item 入口过滤：L190, L194, L199
  - helper：L266-294
  - claude processHookEvent 注册：L316
  - 清理点：L332, L512, L2124, L2314, L2327, L2363
  - **方案 C**: `createOpencodeSession` (L833), `createCodexSession` (L378), `createSession(from:)` (L365) 内部自注册
- OpencodeHookAdapter 根因修复（方案 B）：`Nook/Services/Hooks/OpencodeHookAdapter.swift`
  - `adaptSubagentEvent` L288-322 (拆分 session.status / session.idle)
  - `finalizeSubagent` helper L324-336
- 原始 subagent 路由（未改）：`Nook/Services/Hooks/OpencodeHookAdapter.swift` L156-169, L224-233
- DIAG #79 诊断日志（未改）：`OpencodeHookAdapter.swift` L398-402

## 关联

- `OpencodeHookAdapter.swift` L301-315 (旧版本) 的 `cleanupState` 时序 bug **已修**（方案 B）
- 方案 A + B 双重保护：方案 B 让 adaptSubagentEvent 正常工作，方案 A 在 SessionStore 入口兜底
- 方案 C（subagent 事件改写 parentId）作为未来可选重构
- 归档日志 `2026-07-23-subagent-cleanup-bug.nook-debug.log` 保留供后续回归对比
