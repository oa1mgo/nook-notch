# Bug: OpenCode 会话已完成但 Nook 永久显示 working

> 日期: 2026-10-23 调查
> 状态: ✅ 已修复（2026-10-23，commits `5991426`…`cc747c8`）
> 受影响会话: `ses_e9d995a00ffeqIbY45AYdWUi0E`（cwd `~/mine/rfw/obook-r7s`）
> Owner: `SessionStore`（生命周期兜底）+ `Nook/Resources/opencode-plugin/index.js`（事件传输）
> 关联: [opencode v1.17 兼容矩阵](../specs/2026-06-17-opencode-v1.17-compatibility-matrix.md) · [unified ChatItem 中间层](../specs/2026-06-11-unified-chatitem-middle-layer-design.md)
> 证据日志: `/tmp/nook-debug.log`（2026-10-22 06:58Z ~ 2026-10-23 01:43Z 窗口）

## 症状

用户前一天（2026-10-22 16:16 本地）跑完一轮 opencode 对话，会话在 opencode 侧正常结束。第二天 Nook 顶部/会话列表仍把该会话显示为 working（`phase = .processing`），且不会自行恢复。

## 结论（TL;DR）

**不是事件乱序，是最后一批完成事件丢失。**

opencode 侧已收到 `finish=stop` 并完成落库；Nook 只收到流式文本的最后一条 `message.part.updated(text)`，此后 `step-finish` / `message.updated(finish=stop)` / `session.idle` **全部未到达**。

其中 `step-finish` 与 `message.updated` 的 sqlite 落库记录能证明「事件已产生、但没送到 Nook」；`session.idle` 是 ephemeral bus event、不落库，因此无法区分「opencode 没发」还是「发了没送到」——能确认的只有「Nook 没收到」。由于：

1. 当时 Nook 的 `.stop` 只由 `session.idle` 产生（`finish=stop` 只 flush 文本，不发 `.stop`），而 v1.19 schema 已把 `session.idle` 标为 deprecated——同点发布的 `session.status=idle` 当时只 flush、不产 `.stop`；
2. opencode 的进程退出清理要求 pid 消失，而该实例的 `opencode --port` 进程（pid 70721）至今存活；
3. `recheckAllSessions()` 当时只有 Codex 有静默超时兜底，opencode 没有；

所以 phase 永久停在 `.processing`。

**修复（2026-10-23）**：`session.status=idle` 与 `session.idle` 都作为结束信号（flush 后产 `.stop`）；`SessionStore.processOpencodeStop` 用 `wasActive` guard 保证幂等且不覆盖等待态；完成通知加「每轮一次」闩锁；`recheckAllSessions()` 增加 opencode 静默兜底（90s / 600s，`.waitingForInput` 不过期）；`session.status=retry` 与 `question.rejected` 映射成 `.processingStarted`。详见下文「修复方案（已实施）」与「残留风险」。

## 证据

> 事故当时的 opencode 精确版本号未记录（日志未打印）。调查时本机 CLI 为 `1.19.3`，
> 只能确认属于 v1.18+ 系列；不要据此断言具体 patch 版本的行为。

### opencode 侧状态（只读查询 `~/.local/share/opencode/opencode.db`）

```
session  ses_e9d995a00ffeqIbY45AYdWUi0E
         time_updated = 1792657012101  → 2026-10-22 16:16:52.101 (+08:00)

message  msg_162aedccf001bUDG769lFF6P8f  role=assistant  finish=stop
         time_updated = 1792657012075  → 2026-10-22 16:16:52.075

part     prt_162af3532001wPBA0oUnKsSOSB  type=step-finish
         time_updated = 1792657012019  → 2026-10-22 16:16:52.019
```

即：opencode 在 16:16:52 已判定该轮结束，消息与 step-finish 均已落库。

### 进程状态

```
$ ps -p 70721 -o pid,lstart,etime,stat,command
 70721 Thu Oct 22 14:57:22 2026  18:47:59  S+  opencode --port

$ lsof -p 70721 | awk '$4=="cwd"{print $NF}'
/Users/wuruofan/mine/rfw/obook-r7s
```

opencode 实例存活 → `SessionStore.recheckAllSessions()` 的进程退出分支不会触发。
该分支的条件是 `if let pid = session.pid, shouldRemoveWhenProcessExits(session)`；
`shouldRemoveWhenProcessExits` 对 `.opencode` 返回 `true`，但前提是 `isProcessRunning(pid:)`
（即 `kill(pid, 0)`）失败。

### 时间线对照

> 两个时间源不同：左列是 opencode 的事件发生/落库时间，右列是 Nook 的接收时间。
> 日志显示最后一串 delta 在 51.717 停滞后于 52.642~52.646 集中到达，Nook 的接收时间
> 整体滞后约 0.6s，因此 **52.646 不能与 52.019 直接比较**；关键是 52.646 之后该 session 再无事件。

| opencode 事件顺序 | opencode 落库 | Nook 接收 |
|---|---|---|
| text part 创建（空） | 16:16:43.423 | 16:16:43.423 ✅ |
| text part 完成 | 16:16:51.971 | **16:16:52.646 ✅（最后一条）** |
| `step-finish` | 16:16:52.019 | ❌ 未收到 |
| `message.updated(finish=stop)` | 16:16:52.075 | ❌ 未收到 |
| `session.idle` | 不落库（bus event） | ❌ 未收到 |

Nook 日志在 16:16:52.646 之后直到 08:43（次日）没有任何该 session 的事件；
同期日志文件本身仍在写入（carousel tick、file.watcher），排除"Nook 卡死/日志断流"。

### 会话此前的 idle 是正常的

同一 session 在前一天 07:02:54、07:45:32（UTC）各收到过一次完整的
`session.status=idle` + `session.idle` → `.stop`，说明链路本身可用，不是长期失联。
最后一批恰好丢在"结束"这个最关键的节点上。

## 为什么不是乱序

之前遇到的"opencode 事件乱序"是 **ChatItem 渲染层**的问题
（reasoning / response / tool 交错到达，见 `2026-06-11-unified-chatitem-middle-layer-design.md`），
由 `BlockOrdering.messageRelative` + sorter 处理，与本次现象不同。

判断本次不是乱序的依据：

1. 若是乱序，`finish=stop` / `step-finish` 应出现在最后一条 text **之前**，且后续仍会有该 session 的迟到事件。日志中 52.646 之后该 session **零事件**——是干净截断。
2. 前一轮（16:16:29）的 `step-finish` + `message.updated` 顺序完全正常，说明 adapter 的解析顺序没问题。
3. opencode DB 中三条结束事件的落库时间都晚于 text part（51.971 → 52.019 → 52.075），
   不存在"结束事件先到、又被后续旧事件覆盖成 processing"的窗口。

## 根因链

1. **传输层丢事件**：plugin 的 `send()`（`Nook/Resources/opencode-plugin/index.js` 顶部）对每条事件新建一个 Unix socket 连接，失败静默 `resolve()`，没有重试或 ACK。opencode 在 52ms 内连续产生 `step-finish` / `message.updated`（均已落库），但未到达 Nook；`session.idle` 同样未到达。
2. **协议层没有启用第二结束信号（已修复）**：当时 `OpencodeHookAdapter.handleMessageUpdated` 在 `finish=stop` 分支只 flush 文本缓冲，不 emit `.stop`；`handleSessionStatus` 的 `idle` 分支也只 flush，不结束会话。`.stop` 只能由 `handleSessionIdle` 产生。而源码里 `session.status=idle` 与 `session.idle` 是同一次 `set()` 里先后 publish 的（见修复方案 B），本可互为冗余。
3. **状态层无静默兜底（已修复）**：当时 `recheckAllSessions()` 的 active-quiet 过期分支条件是 `session.provider == .codex && session.phase.isActive`，只对 Codex 生效。opencode 会话只能靠事件或进程退出，二者本次都不可用。

## 修复方案（已实施）

### A. 静默兜底（已实施）

`recheckAllSessions()` 增加 `.opencode` 分支，复用 Codex 的策略并扩展：

- 无运行中工具：静默 > 90s → `.idle`
- 有运行中/排队中的工具（chat item 的 `running` / `waitingForApproval`，或 `toolTracker.inProgress` 非空）、`.compacting`、`waitingForApproval`、`waitingForTerminalApproval`：静默 > 600s → `.idle`
- `.waitingForInput` **永不自动过期**（用户可能真的要思考很久）
- 过期时：`.idle`、清 `completionNotificationAt`、把停滞工具（含 `waitingForApproval`）标 `.interrupted`、清 `toolTracker.inProgress`

代价：误判风险。若某轮真的在等 provider 且无工具、超 90s，会被提前标 idle；
但由于 `.idle` 不是 `.ended`，后续事件可重新拉回 `.processing`，风险可接受。更完整的残留风险见下文。

### B. 双结束信号（已实施）

源码依据（本地 opencode v1.19.x）：

- `packages/opencode/src/session/status.ts` 的 `SessionStatus.set()` 在 `status.type === "idle"` 时，
  先 `publish(Event.Status, {status:{type:"idle"}})`，紧接着 `publish(Event.Idle, {sessionID})` ——
  `session.status=idle` 与 `session.idle` 是同一次调用产生的 **1:1 双发**。
- `packages/schema/src/session-status-event.ts` 里 `session.idle` 已标注 `// deprecated`。

落地行为：

- `handleSessionStatus` 的 `idle` 分支：flush 之后**无条件 emit `.stop`**（adapter 不持有 phase，不做判断）。
- `handleSessionIdle`：**先 flush，再 `cleanupState`**，最后 emit `.stop`（旧版本兜底 + 幂等）。
- phase guard 落在 `SessionStore.processOpencodeStop`：只有 `phase.isActive`（`.processing` / `.compacting`）
  才做「phase → `.idle`」+ 完成通知；`.waitingForInput` / `.waitingForApproval` / `.waitingForTerminalApproval`
  / 已 `.idle` 不动（避免把等待态覆盖成结束态）。
- 清理逻辑无条件执行（running tool → `.interrupted`、`toolTracker.inProgress` 清空、`publishState()`），
  等待态被 stop 时也要收尾。
- 不建议只让 `finish=stop` emit `.stop`：`finish` 是 message 级字段，每个 `step-finish` 都会用 provider 的 reason
  覆写它（`processor.ts` 里 `ctx.assistantMessage.finish = value.reason`）；中间 step 的 reason 是 `tool-calls`，
  只有最后一步是 `stop`。它是跟着 step 走的信号，还会被后续 `message.updated` 重复携带，不是稳定的「本轮结束」。
- `status=idle` 的语义才是"本轮结束"，且与 `session.idle` 同点双发，改造它不会新增闪烁面
  （凡是会闪的 `session.idle` 同样会闪）。冗余的是传输报文：同一个 `set()` 没被调用时两条一起没有，
  这种「产生路径」缺失只能靠 A 方案的静默兜底。
- **版本口径**：`status=idle` 只在 opencode ≥1.18 是轮末信号；v1.15.13 / v1.17.x 会在 tool step 之间发
  `status=idle`，因此该路径对 ≤1.17 **不支持**——这些版本依赖 `session.idle` + 90s 静默兜底。
  旧版若丢失 `session.idle`，可能出现 step 间闪烁或按步通知。

实现注意（已处理）：adapter 不持有 phase，`isActive` 判断落在 `SessionStore.processOpencodeStop`。
**guard 没有写成函数入口早退**：`processOpencodeStop` 在 phase 转移之前还会把 running tool 标 `.interrupted`、
清空 `toolTracker.inProgress`、`publishState()` 并发完成通知；入口 guard 会把这些一起跳过。
只把「phase → `.idle`」与完成通知放进 `wasActive` 条件，清理照旧执行，否则等待态被 stop 时会漏收尾。
若某版本在等待用户输入时也发 `status=idle`，该 guard 会挡住误停。

`handleMessageUpdated` 的 `finish=stop` 分支维持「只 flush」：它的价值是把最后一段文本冲刷到 UI，
不作为结束信号。

### C. 每轮一次完成通知闩锁（已实施）

`processOpencodeStop` 的 `wasActive` 只能挡住连续两条 `.stop`。`HookSocketServer` 把 chat items 和 passthrough
分发到互不保证顺序的独立 `Task`：若一条 chat item 落在两条 `.stop` 之间，`applyRealtimeChatItemLifecycle`
会把 phase 拉回 `.processing`，第二条 `.stop` 会再次通知。

落地为 `SessionStore.opencodeCompletionNotifiedSessions`：

- 通知前检查闩锁，插入后 `publishCompletionNotification(for:)`；
- 在 `processOpencodePromptSubmitted`、`processOpencodeProcessingStarted`、TUI `.userPrompt`
  （`applyRealtimeChatItemLifecycle`）时重置；
- 会话注销 / `resetForTesting()` 时移除。

### D. retry / question.rejected（已实施）

- `session.status=retry` → `.processingStarted`。`retry.ts` 在进入退避等待之前按 attempt 发一次 `status=retry`，
  退避本身静默；不消费会让 `lastActivity` 不刷新，90s 静默兜底在重试中途误判。
- `question.rejected` → `.processingStarted`。用户拒绝/取消问题后模型通常继续跑；若该轮直接结束，
  随后的 `status=idle` 会正常收尾。
- `question.replied` 保持原有 `.processingStarted` 映射。

### E. 传输层重试 / ACK（后续可选，未纳入本次修复）

失败时写入内存队列，指数退避重发；或 Nook 侧对 JSON 行做 ACK，plugin 未收到 ACK 则重发。
彻底但改动面大（协议 + 两侧），作为后续。

### F. 主动 reconcile（后续可选，未纳入本次修复）

周期性通过 opencode server API 查询 `session.status()` 对齐 phase。
需要 serverPort + directory 路由（见 `2026-08-13-opencode-multi-instance-pid-isolation.md`），
且在无 `--port` 的实例上不可用，因此只能作为补充。

## 残留风险

1. **90s 静默窗口可能误判**：长 TTFT、非流式 reasoning、排队中的 turn、或服务端 `retry-after` header >90s 时，
   会在真实工作期间被标 `.idle`。下一个事件会把会话拉回 `.processing`，代价是一次闪烁；不会丢会话。
2. **审批条可能提前消失**：`.waitingForApproval` 在 600s 后被回收为 `.idle`，Nook 的审批条消失，
   而 opencode 可能仍阻塞在权限请求上——用户需回 TUI 处理。这是「不永久卡住」换来的有意取舍。
3. **`.waitingForInput` 出口有限**：只有 `question.replied`、`session.status=busy`、新一轮用户 prompt
   三个出口，其中只有 `busy` 不依赖用户动作；三者全丢则卡到进程退出。
4. **≤1.17 不支持新的结束信号路径**：v1.15.13 / v1.17.x 的 `session.status=idle` 在 tool step 之间触发，
   不能当轮末信号。这些版本依赖 `session.idle` + 90s 静默兜底；旧版丢失 `session.idle` 时可能出现
   step 间闪烁或按步通知。
5. **最后一条 `.stop` 之后到达的 chat item 会重新标记 processing**：`applyRealtimeChatItemLifecycle` 对
   opencode 的 `assistantText` / tool 完成会把 phase 拉回 `.processing`。若发生在最后一条 `.stop` 之后，
   会一直显示到下一个静默窗口过期。

## 验证方法（修复后）

1. 构造一次正常完成：确认 `session.status=idle` / `session.idle` 到达时 phase → `.idle`，完成通知只响一次。
2. 模拟单条丢失：临时让 plugin 只丢弃 `session.idle`（或只丢弃 `status=idle`），确认另一条仍能结束会话。
3. 模拟双条丢失：同时丢弃两条结束信号，确认 90s 静默兜底把 phase 降为 `.idle`；有 tool running / 审批挂起时走 600s。
4. 回归：长工具（>90s 无输出）不能被误判；`.waitingForInput` 任意久都不自动过期。
5. 单元测试：`NookTests/SessionStoreOpencodeLifecycleTests.swift` 覆盖重复 `.stop`、等待态保护、quiet-expiry 边界、
   审批回收；`NookTests/OpencodeHookAdapterEventDrivenSelfHealTests.swift` 覆盖 `status=idle` / `retry` / `question.rejected`。

## 相关代码位置

> 不使用行号锚点（行号必漂）——按「文件 + 函数/分支条件」定位。

- `Nook/Services/State/SessionStore.swift`
  - `recheckAllSessions()`：Codex quiet-expiry 分支（`session.provider == .codex && session.phase.isActive`，阈值字段 `codexActiveQuietExpirationSeconds` / `codexRunningToolQuietExpirationSeconds`）
  - 同一函数内的 opencode quiet-expiry 分支（`session.provider == .opencode` 且 `isActive` / `isWaitingForApproval` / `isWaitingForTerminalApproval`；阈值 `opencodeActiveQuietExpirationSeconds` / `opencodeExtendedQuietExpirationSeconds`；`.waitingForInput` 不在条件内）
  - 同一函数内的进程退出分支（`if let pid = session.pid, shouldRemoveWhenProcessExits(session)`）
  - `processOpencodeStop`：`wasActive` guard 控制 phase → `.idle` 与完成通知；清理逻辑无条件执行
  - `opencodeCompletionNotifiedSessions`：每轮一次完成通知闩锁（prompt / `processingStarted` / TUI `.userPrompt` 重置）
  - `interruptStalledTools(in:includeWaitingForApproval:)`：`processOpencodeStop` 默认不含审批态，quiet-expiry 含审批态
  - `shouldRemoveWhenProcessExits`（`.opencode` → `true`）、`isProcessRunning(pid:)`
  - `enrichOpencodeRuntimeMetadata`（按 cwd 精确匹配 opencode 进程）
- `Nook/Services/Hooks/OpencodeHookAdapter.swift`
  - `handleMessageUpdated`：`role == "assistant" && finish == "stop"` 分支（只 flush，不作为结束信号）
  - `handleSessionStatus`：`busy` / `retry` → `.processingStarted`；`idle` → flush + `.stop`
  - `handleSessionIdle`：先 flush、再 `cleanupState`、最后产 `.stop`（legacy 路径）
  - dispatch 的 `question.replied` / `question.rejected` → `.processingStarted`
- `Nook/Resources/opencode-plugin/index.js`
  - `send()`（best-effort，失败静默 `resolve()`，无重试/ACK）

## 附：原始日志取样

```
[2026-10-22T08:16:52.646Z] [opencode] event type=message.part.updated
  session=ses_e9d995a00ffeqIbY45AYdWUi0E partType=text
  text=先把 #16 认下来：我去核了 `tools/r7s_deploy_v64.py
# ← 之后该 session 再无任何事件（直到日志窗口结束）
```
