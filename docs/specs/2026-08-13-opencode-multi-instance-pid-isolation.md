# OpenCode 多实例 pid 隔离 — 设计

> 日期: 2026-08-13
> 状态: ✅ 实现中（Task 1-6 完成并端到端验证，Task 7 未做，Task 8 部分验证）
> 适用: opencode provider（多实例共存时）
> 关联: [2026-08-09-opencode-server-api-input.md](2026-08-09-opencode-server-api-input.md) · [2026-06-17-opencode-v1.17-compatibility-matrix.md](2026-06-17-opencode-v1.17-compatibility-matrix.md)
> 实现: [docs/superpowers/plans/2026-08-13-opencode-multi-instance-pid-isolation.md](../superpowers/plans/2026-08-13-opencode-multi-instance-pid-isolation.md)
> Review: GLM 5.2 review 已处理（13 项，含 4 阻塞级全采纳）

## TL;DR

单实例 server API 输入已可用（见 08-09 spec）。但当**多个 opencode 实例**共存时（不同 tmux 窗格、不同项目、不同 `--port`），当前架构用全局单值承载实例信息，导致三个问题：serverPort 串台、permission reply 落错实例、用户消息沉底。

本 spec 以 **opencode 进程 pid 作为唯一实例标识**，统一修复三者。核心改动：plugin 上报带 pid、command socket 按 pid 命名、Nook 侧 pid→port 映射。

改动范围：~300 行，8 个文件，1 个 plugin，2 个测试文件。

---

## 问题陈述

### 场景

用户开两个 opencode 实例（各在独立 tmux 窗格，其中一个 `--port` 启动）。Nook 需要正确区分它们。

### 问题 A：serverPort 串台

**现象**：两个实例都 `--port` 启动，session 列表中的 serverPort 值错误（一个 session 显示另一个实例的端口）。

**根因**：

`OpencodeHookAdapter.handleServerPort` 收到的 `serverPort` 事件无进程标识，`SessionStore` 只存全局单值：

```swift
// SessionStore.swift:45 附近
private var opencodeServerPort: Int?
```

多个实例上报时，**后上报者覆盖前者**（`processOpencodeServerPortReceived` 的 `"?"` 分支把所有 nil serverPort session 一次性应用）。session 被错误绑定到别的 server → `sendViaServerAPI` 把消息发到错误的进程。

### 问题 B：permission reply 落错实例

**现象**：session A 弹出 permission.asked，点击 3 按钮（approve / always / deny）后 opencode 端无反应，或报错。

**根因**：plugin 的 `startCommandServer` 用固定路径，且 listen 前先 `fs.unlinkSync(COMMAND_SOCKET_PATH)`（index.js:44）：

```js
// index.js:9
const COMMAND_SOCKET_PATH = "/tmp/nook-command.sock";
// index.js:44 启动时
try { fs.unlinkSync(COMMAND_SOCKET_PATH); } catch {}
```

两个 opencode 进程**顺序启动**时：实例 2 启动会 unlink 实例 1 的 socket 文件再 listen，实例 1 的 listener 失联（路径已被实例 2 抢占），Nook 的 `permission.reply` 全部路由到实例 2 → 实例 2 没有该 permission 记录时返回 `PermissionNotFoundError`（运行日志已确认出现三次）。若两实例**同时**启动（unlink+listen 竞态），则可能出现内核对新连接负载均衡的第二种失真。两者都会导致 reply 落错实例。

### 问题 C：用户消息沉底

**现象**：server API 发送的用户 prompt 在 ChatView 中一直沉在底部，不随对话流动。

**根因**：同一条用户消息有两条插入路径，各自带不同 messageId：

| 路径 | messageId | 前缀 |
|------|-----------|------|
| 本地 prompt（`ChatView.sendMessage` → `processOpencodePromptSubmitted`） | `opencode-prompt-{sessionId}-{ts}` | `o` |
| server API 回传（adapter 收到 `.userPromptSubmitted`） | 真实 `msg_xxx` | `m` |

dedup（`ChatItemUpdateReducer.swift:61`）保证只保留一个 item，但 **ordering 由后到者决定**。`ChatItemSorter.swift:75` 对不同 messageId 按**字典序** `m1 < m2` 比较：

```
opencode-prompt-...  (o > m)  → 永远排在 msg_xxx 之后
```

server API 场景下本地 prompt 总是后到（`await sendToSession` 完成之后才插入），所以 dedup 后 ordering 用本地假 id → 用户 prompt 恒沉底。

---

## 设计决策

### 决策 1：以 pid 为实例标识（核心）

**理由**：

- **plugin 内 `process.pid` 在 worker thread 中与主进程相同**（Node worker_threads 共享进程 pid）。已验证依据：opencode 二进制内含 `worker_threads`/`parentPort` 支持代码；且当前运行中的 opencode 实例（`ps aux` 观察 81397/81566）无独立的 node/bun 子进程 → plugin 不跑在 child_process，与主进程共享 pid。**注：此为本方案命门，plan Task 1 增加 Step 0 实跑验证。**
- **Nook 已能可靠拿到每个 session 的 opencode 进程 pid**：`SessionStore.enrichOpencodeRuntimeMetadata`（SessionStore.swift:1459）→ `bestMatchingOpencodeProcess(for: cwd)`（:1471）按 cwd 精确匹配进程树
- pid 在同一时刻全局唯一，天然区分多实例

**替代方案（否决）**：
- 用 sessionId：serverPort 事件无 sessionId（全局），无法关联
- 用 port 本身做 key：port 也可能重复（两个实例都用 4096），且 command socket 与 port 无直接关系
- 用 cwd 做 key：serverPort 事件不带 cwd，plugin 也无权威 cwd

### 决策 2：command socket 按 pid 命名

`/tmp/nook-command.sock` → `/tmp/nook-command-{pid}.sock`。Nook 按 session.pid 连接对应实例，根治 B。

### 决策 3：本地 prompt 不参与字典序

本地 prompt 改用 `.appendOrder`（现有 `BlockOrdering` 值，ChatItemSorter.swift:70 已支持按 timestamp 比较），不再伪造 messageId。同时 reducer 的 dedup 分支**只允许 `messageRelative` 覆盖 `appendOrder`，反向不降级**，确保真实 messageId 永远赢。

### 决策 4：兼容旧 plugin

无 pid 上报 / 固定 socket 路径的旧 plugin 走 fallback（全局单值 + legacy socket 路径）。

---

## 架构

```
plugin (worker thread, pid = opencode 主进程 pid)
  ├─ serverPort 事件: properties = { port, pid }
  ├─ permission.asked 等事件: properties = { ...原有, pid }
  └─ command socket: /tmp/nook-command-<pid>.sock

Nook
  ├─ opencodeServerPorts: [Int: Int]      // pid → port（替换全局单值）
  ├─ opencodeServerPortFallback: Int?     // 旧 plugin 无 pid 时兜底
  ├─ SessionState.pid ← enrichOpencodeRuntimeMetadata（已存在）
  └─ session.serverPort ← opencodeServerPorts[session.pid] ?? fallback
```

### 数据流

**serverPort 绑定（A）**：
1. plugin 上报 `serverPort { port, pid }`
2. adapter 解析 pid → `serverPortReceived(sessionId:, port:, version:, pid:)`
3. SessionStore 存 `opencodeServerPorts[pid] = port`
4. session 的 pid 由 enrich 解析（已存在），`serverPort` 从映射查表回填

**permission 路由（B）**：
1. plugin 上报 `permission.asked`（properties 带 pid）
2. session 已有 pid（enrich），SessionMonitor 点击按钮时 `sendCommand(payload, pid: session.pid)`
3. `OpencodeCommandSocket.sendCommand` 按 pid 拼 socket 路径 → 连接正确实例

**用户消息排序（C）**：
1. 本地 prompt：`processOpencodePromptSubmitted` 用 `.appendOrder`
2. adapter 回传：真实 messageId 用 `.messageRelative`
3. dedup：messageRelative 优先保留

---

## 组件改动

| 文件 | 改动 |
|------|------|
| `Nook/Resources/opencode-plugin/index.js` | 版本 1.2.0；`COMMAND_SOCKET_PATH` 按 pid；serverPort 上报带 pid；转发事件带 pid |
| `Nook/Services/Hooks/OpencodeHookModels.swift` | `serverPortReceived(sessionId:, port:, version:, pid:)` |
| `Nook/Services/Hooks/OpencodeHookAdapter.swift` | `handleServerPort` 解析 pid 并透传 |
| `Nook/Services/State/SessionStore.swift` | `opencodeServerPorts: [Int: Int]` + fallback；`processOpencodeServerPortReceived` 按 pid 精确绑定；enrich 后回填 port；`processOpencodePromptSubmitted` 本地 prompt 改 `.appendOrder` |
| `Nook/Services/Hooks/OpencodeCommandSocket.swift` | `socketPath(forPid:)`；`sendCommand(_:pid:)` |
| `Nook/Services/Session/SessionMonitor.swift` | 3 处 permission reply 传 `session.pid`；`serverPortReceived` → `opencodeServerPortReceived` 转发带 pid |
| `Nook/Models/SessionEvent.swift` | `opencodeServerPortReceived` 加 `pid: Int?`，description 同步 |
| `Nook/Services/Shared/ChatItemUpdateReducer.swift` | dedup 分支保留 messageRelative ordering |
| `NookTests/SessionStoreServerPortTests.swift` | 新测试：pid 绑定不串台 |
| `NookTests/ChatItemUpdateReducerTests.swift` | 新测试：dedup ordering 保留方向 |

---

## 边界条件

| 场景 | 处理 |
|------|------|
| 旧 plugin（无 pid 上报） | `processOpencodeServerPortReceived` 无 pid → 写 `opencodeServerPortFallback` 并广播到 nil serverPort session |
| 旧 plugin（固定 command socket） | `sendCommand(_:pid: nil)` → legacy 路径 |
| 单实例（最常见） | pid = 该实例，行为与之前一致 |
| 多实例同 cwd（edge case） | `bestMatchingOpencodeProcess` 取 pid 最大者，可能串。**缓解**：落地后 plugin 事件（permission.asked 等）自带 pid，`processOpencodePermissionRequested` 等入口可用事件 pid 直接覆盖 enrich 的猜测值，彻底消除同 cwd 歧义。本 spec 记录该路径，不在首期 plan 强制实现 |
| permission 无 opencodeRequestId（Claude/Codex） | 不受影响，仍走 hook socket |
| 探测端口（probe） | 无法得知 pid，写入 fallback 并广播 |
| socket 文件残留 | 插件退出不清理 pid socket，下次启动 unlink 自己的 pid 路径，无冲突 |
| 多 plugin 写同一 debug log | 所有实例写 `/tmp/nook-plugin-debug.log`，按行区分，不阻塞 |

---

## 验收标准

1. 两个 opencode 实例各 `--port` 启动 → 各自 session.serverPort 为各自端口，互不覆盖
2. 实例 A 触发 permission.asked → 点击 3 按钮任一 → 实例 A 收到 reply（plugin 日志 `reply OK`），不再 `PermissionNotFoundError`
3. server API 发送消息 → 用户 prompt 在正确位置流动，不沉底
4. 单实例场景行为完全不变
5. 所有测试通过 + xcodebuild 编译通过

## 实测记录（2026-08-14）

1. **serverPort 各归其位** ✅：92784（`--port`）→ `serverPort=4096` 正常映射；92710（galaxy，无 port）与 51926（motelet，无 port）→ `port=0` 被 Nook 过滤，无串台。
2. **permission reply 落到正确实例** ✅：motelet（pid=51926）触发 permission.asked → 在 Nook 点 once → plugin 日志 `pid=51926 reply OK res={"data":true}`，不再 `PermissionNotFoundError`。旧版（08-12）日志中的 PermissionNotFoundError 为 Task 5/6 实施前的遗留。
3. **用户消息沉底（问题 C）** 🔲：Task 7 未实施，待验证。
4. 期间发现并解决的临时问题：motelet 会话在 Nook 重启后短暂缺失，根因是重启后 adapter `sessionCwd` 内存清空需重新 first-sighting，已自愈（`sessionStart (first sighting)` → 注册 → 显示），非持久 bug。
