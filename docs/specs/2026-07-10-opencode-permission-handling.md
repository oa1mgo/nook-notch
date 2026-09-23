# opencode Permission Handling — 事件识别、状态切换、回复路径

> 日期: 2026-07-10
> 状态: ✅ 已实现 + 2026-07-14 补丁（notch 染色 / popover 样式 / plugin 自动升级）
> 适用: opencode provider 的 `permission.asked` / `permission.replied` 事件接入 Nook
> 关联: [opencode v1.17 Event Compatibility Matrix](2026-06-17-opencode-v1.17-compatibility-matrix.md) · [PROGRESS.md](../../PROGRESS.md)
> 范围: **仅 permission 场景**。Question（`question.asked`）的回复能力是独立 PR，不在本 spec 内。

## TL;DR

opencode 的 `permission.asked` 事件已经通过 Nook plugin 到达 `OpencodeHookAdapter`，但 `adapt(_:)` 的 switch 没有 `case "permission.asked"`，事件落到 `default: return []` 被丢弃——notch 卡在 `.processing`。本 spec 补齐事件识别 → 状态切换 → 回复路径的完整链路。

改动范围：~200 行，6 个文件，零新文件。分两个 Step 合入一个 PR。

---

## 问题陈述

### 现象

opencode 会话触发 tool permission（如 bash、edit）时，Nook notch 保持 `.processing` 状态，不显示 Allow/Deny 按钮。

### 根因

```
opencode Bus → Nook plugin (index.js) → HookSocketServer → OpencodeHookAdapter.adapt(_:)
                                                                    ↓
                                              switch envelope.type {
                                                case "session.updated" → ✅
                                                case "question.asked"  → ✅
                                                case "permission.asked" → ❌ 无此 case
                                                default: return []      ← 事件被丢弃
                                              }
```

`OpencodeChatItemAdapter.adaptAndConvert` 收到空 `events` → `HookSocketServer.decodeIncomingEvent` 走 `.opencodeSkipped` → 仅 `logger.debug`，SessionStore 完全不知道有 permission 请求。

### Codex 对照

Codex 已有完整链路：`CodexHookAdapter.permissionRequest` → `SessionStore.codexPermissionRequested` → `PermissionContext` + `.waitingForApproval` phase → `InlineApprovalButtons` → `HookSocketServer.respondToPermission`（socket reply）。本 spec 让 opencode 走同一条 UI 路径。

---

## opencode Permission 事件 Schema

来源：[opencode/packages/opencode/src/permission/index.ts](../../../opencode/packages/opencode/src/permission/index.ts)

### `permission.asked`（Bus 事件）

```ts
// BusEvent.define("permission.asked", Request)
{
  id:          PermissionID,          // 后续 reply 用此 id
  sessionID:   SessionID,
  permission:  string,                // "bash" | "read" | "edit" | "write" | "webfetch"
                                      // | "list" | "glob" | "grep" | "skill" | "task"
                                      // | "doom_loop" | "external_directory" | ...
  patterns:    string[],              // 动作粒度：命令/glob/路径
  metadata:    { [k: string]: any },  // 展示内容（部分工具为空对象）
  always:      string[],              // "always" 写入 session ruleset 的规则
  tool: {                              // optional
    messageID:  MessageID,
    callID:     string,                // 反查 ChatItem 的 key
  }
}
```

### `permission.replied`（Bus 事件）

```ts
// BusEvent.define("permission.replied", ...)
{
  sessionID:  SessionID,
  requestID:  PermissionID,
  reply:      "once" | "always" | "reject",
}
```

### 回复 API

```
POST /permission/:requestID/reply
Content-Type: application/json

{ "reply": "once" | "always" | "reject", "message"? : string }
```

- `"once"` — 放行当前 tool call，下次同样 pattern 还会问
- `"always"` — 放行 + 把 `request.always` 写入 session ruleset，后续同 pattern 自动放行
- `"reject"` — 抛 RejectedError；**opencode 自动 reject 同 session 其他所有 pending permission**（[permission/index.ts:221-230](../../../opencode/packages/opencode/src/permission/index.ts#L221-L230)）
- `"reject"` + `message` — 抛 CorrectedError，`message` 作为 feedback 喂回 LLM

### 各工具的 metadata / patterns / always 实际值

| permission | patterns | always | metadata | 展示建议 |
| --- | --- | --- | --- | --- |
| `bash` | 实际命令字符串 | `bash prefix *`（如 `git *`） | `{}` | patterns[0] 显示命令 |
| `read` | 文件绝对路径 | `*` | `{}` | patterns[0] 显示路径 |
| `edit` | 相对路径 | `*` | `{ filepath, diff }` | **显示 diff 预览** |
| `write` | 相对路径 | `*` | `{ filepath, diff }` | **显示 diff 预览** |
| `list` | 目录路径 | `*` | `{ path }` | metadata.path |
| `glob` | glob 表达式 | `*` | `{ pattern, path }` | metadata.pattern |
| `webfetch` | URL | `*` | `{ url, format, timeout }` | metadata.url |
| `skill` | skill 名 | skill 名 | `{}` | patterns[0] |
| `external_directory` | 外部目录 glob | 外部目录 glob | `{ filepath, parentDir }` | metadata.filepath |
| `doom_loop` | tool 名 | tool 名 | `{ tool, input }` | metadata.tool + metadata.input |

---

## 设计方案

### Step 1: 事件识别 + 状态切换

**目标**：`permission.asked` 到达后，notch 从 `.processing` 切到 `.waitingForApproval`，session row 出现 Allow/Deny 按钮。

#### 1.1 OpencodeHookAdapter.adapt 加 case

文件：`Nook/Services/Hooks/OpencodeHookAdapter.swift`（~L249-266 switch）

```swift
case "permission.asked":
    return handlePermissionAsked(envelope)
```

#### 1.2 handlePermissionAsked 实现

文件：`Nook/Services/Hooks/OpencodeHookAdapter.swift`（新方法）

```
输入：OpencodeHookEnvelope
解析：id, sessionID, permission, patterns, metadata, always, tool.{callID, messageID}
校验：callID 缺失时 logNotice + return []（宁可漏一次也不切错误状态）
拼装 inputSummary：
  1. metadata.diff → 截取首行 + "..." 作为 summary
  2. metadata.filepath → filepath
  3. metadata.url → url
  4. patterns[0] → fallback
输出：[OpencodeSessionEvent.permissionAsked(OpencodePermissionRequest)]
```

`OpencodePermissionRequest` 结构：

```swift
struct OpencodePermissionRequest: Equatable, Sendable {
    let sessionId: String
    let cwd: String
    let permission: String          // "bash" / "edit" / ...
    let requestId: String           // permission.asked.id → 后续 reply 用
    let toolUseId: String           // tool.callID → 反查 ChatItem
    let patterns: [String]
    let metadata: [String: AnyCodable]
    let always: [String]            // "always" 按钮 pattern 展示
    let input: [String: String]     // callID 反查 chat item state.input
    let inputSummary: String?
}
```

#### 1.3 OpencodeSessionEvent 加 case

文件：`Nook/Services/Hooks/OpencodeChatItemAdapter.swift`

```swift
case permissionAsked(OpencodePermissionRequest)
```

#### 1.4 SessionEvent 加 case

文件：`Nook/Models/SessionEvent.swift`

```swift
case opencodePermissionRequested(
    sessionId: String,
    cwd: String,
    permission: String,
    requestId: String,
    toolUseId: String,
    input: [String: String],
    inputSummary: String?,
    always: [String]
)
```

#### 1.5 SessionMonitor 分发

文件：`Nook/Services/Session/SessionMonitor.swift`（`onOpencodeEvent` switch）

```swift
case .permissionAsked(let req):
    await SessionStore.shared.process(.opencodePermissionRequested(
        sessionId: req.sessionId,
        cwd: req.cwd,
        permission: req.permission,
        requestId: req.requestId,
        toolUseId: req.toolUseId,
        input: req.input,
        inputSummary: req.inputSummary,
        always: req.always
    ))
```

#### 1.6 SessionStore 处理

文件：`Nook/Services/State/SessionStore.swift`

新方法 `processOpencodePermissionRequested`，照抄 `processCodexPermissionRequested`（L618-679），差异点：

| 项 | Codex | opencode |
| --- | --- | --- |
| provider gate | `.codex` | `.opencode` |
| toolName 来源 | `event.tool` | `request.permission` |
| toolUseId | `latestRunningCodexToolId(...)` | `request.toolUseId`（直接用 callID，opencode 带了） |
| inputSummary | `event.input` | `request.inputSummary` |
| **requestId** | 无 | **`request.requestId`** → 存入 `PermissionContext.opencodeRequestId` |

#### 1.7 PermissionContext 扩展

文件：`Nook/Models/SessionState.swift`

```swift
struct PermissionContext: Equatable, Sendable {
    let toolUseId: String
    let toolName: String
    let toolInput: [String: AnyCodable]?
    let receivedAt: Date
    var opencodeRequestId: String?   // ← 新增，opencode permission.asked.id
    var alwaysPattern: String?       // ← 新增，"Always" 按钮展示的 pattern
}
```

`alwaysPattern` 取值：`always.first`（opencode 的 `always` 数组通常只有一个 pattern）。

---

### Step 2: 回复路径（让 Allow/Deny/Always 真的生效）

**核心问题**：opencode permission 回复走 HTTP API，Codex 走 Nook Unix socket。两条路径完全不同。

**方案**：plugin 起一个 command server socket，Nook 连上去发 command，plugin 在 opencode 进程内调 SDK。

#### 2.1 plugin 加 command server

文件：`Nook/Resources/opencode-plugin/index.js`

当前 plugin 只有 `event` 钩子（单向往 Nook 发 bus event）。需要新增反向通道让 Nook 能发命令给 plugin。

**架构**：plugin 在 `/tmp/nook-command.sock` 上起 `net.createServer`，接收 Nook 发来的 command JSON，解析后调 `input.client.permission.reply(...)`。

```js
import net from "node:net";
import fs from "node:fs";

const SOCKET_PATH = "/tmp/nook.sock";
const COMMAND_SOCKET_PATH = "/tmp/nook-command.sock";

function send(payload) { /* ... 原有实现不变 ... */ }

/// 在独立 socket 上监听 Nook 的 command
function startCommandServer(input) {
  // 清理可能残留的旧 socket 文件
  try { fs.unlinkSync(COMMAND_SOCKET_PATH); } catch {}
  const cmdServer = net.createServer((socket) => {
    let buf = "";
    socket.on("data", (data) => { buf += data.toString(); });
    socket.on("end", async () => {
      try {
        const cmd = JSON.parse(buf.trim());
        await handleCommand(cmd, input);
      } catch { /* 忽略解析失败 */ }
    });
  });
  cmdServer.listen(COMMAND_SOCKET_PATH, () => {});
  cmdServer.on("error", () => {}); // 静默，不 crash opencode
}

async function handleCommand(cmd, input) {
  if (cmd.cmd === "permission.reply") {
    await input.client.permission.reply({
      requestID: cmd.requestId,
      reply: cmd.reply,          // "once" | "always" | "reject"
      message: cmd.message,      // optional
      directory: input.directory,
    });
  }
}

/// OpenCode server plugin entry point.
/// `input` 由 opencode 框架在 plugin 加载时传入（见 plugin/index.ts:85），
/// 包含 client（OpencodeClient SDK 实例）、directory、serverUrl 等。
/// 在闭包内捕获 input 供 event hook 和 command server 使用。
export default function server(input) {
  // 启动 command server，传入 input 供 SDK 调用
  startCommandServer(input);

  return {
    event: async ({ event }) => {
      await send({
        origin: "opencode",
        type: event.type,
        properties: event.properties,
      });
    },
  };
}
```

**为什么用独立 socket 而不是复用 `/tmp/nook.sock`**：
1. `/tmp/nook.sock` 是 Nook 的 `HookSocketServer` 在 listen——一个 socket 只能有一个 server 端
2. plugin 是 opencode 进程内的 guest，不应该抢 Nook 的 socket server 角色
3. 独立 socket 让双向通信职责清晰：`/tmp/nook.sock` = plugin → Nook（event），`/tmp/nook-command.sock` = Nook → plugin（command）

**SDK 调用说明**（来源：[opencode SDK v2/sdk.gen.ts:2470-2503](../../../opencode/packages/sdk/js/src/v2/gen/sdk.gen.ts#L2470-L2503)）：

```ts
// 正确的 SDK 调用路径
input.client.permission.reply({
  requestID: string,        // permission.asked.id
  reply: "once" | "always" | "reject",
  message?: string,         // reject 时的 feedback，喂回 LLM
  directory?: string,       // 项目目录，SDK 拼到 query param
})
```

- `input.client`（不是 `input.api`）是 opencode 生成的 `OpencodeClient` 实例
- `directory` 参数虽然当前 server 端不校验，但传了更安全（未来版本可能要求）
- `pluginInput.directory` 在 plugin 生命周期内不变，闭包安全

> 为什么不 Nook 直接 HTTP：
> 1. opencode server port 不固定（默认 4096 但冲突后 fallback 随机端口，[server.ts:274](../../../opencode/packages/opencode/src/server/server.ts#L274)）
> 2. plugin 已在 opencode 进程内，有 `input.client` 直接调用，最稳
> 3. 不需要处理 CORS / OPENCODE_SERVER_PASSWORD
> 4. SDK 内部走 `Server.Default().fetch(...)` 绕过网络栈（[plugin/index.ts:114](../../../opencode/packages/opencode/src/plugin/index.ts#L114)），零延迟

#### 2.2 OpencodeHookAdapter 发 command

文件：`Nook/Services/Hooks/OpencodeHookAdapter.swift`

新方法 `sendCommand(_ cmd: [String: Any])`：往 `/tmp/nook-command.sock` 写 JSON + 换行。

```swift
private static let commandSocketPath = "/tmp/nook-command.sock"

static func sendCommand(_ cmd: [String: Any]) {
    // 连接 plugin 的 command server socket
    // fire-and-forget：写完即关，不等响应
    // 连接失败时 logNotice，不 crash（plugin 可能未启动/已退出）
    do {
        let socket = try Socket.createClient()
        try socket.connect(to: commandSocketPath)
        let data = (try JSONSerialization.data(withJSONObject: cmd) + "\n".data(using: .utf8)!)
        try socket.write(data: data)
        socket.close()
    } catch {
        logNotice("sendCommand failed: \(error.localizedDescription)")
    }
}
```

> 注意：这里连的是 **plugin 的 command server**（`/tmp/nook-command.sock`），不是 Nook 自己的 event socket（`/tmp/nook.sock`）。两者方向相反，互不干扰。

#### 2.3 SessionMonitor 分流 approve/deny

文件：`Nook/Services/Session/SessionMonitor.swift`（L190-225）

```swift
func approvePermission(sessionId: String) {
    Task {
        guard let session = await SessionStore.shared.session(for: sessionId),
              let permission = session.activePermission else { return }

        if session.provider == .opencode, let requestId = permission.opencodeRequestId {
            // opencode: 走 plugin command
            OpencodeHookAdapter.sendCommand([
                "cmd": "permission.reply",
                "requestId": requestId,
                "reply": "once"    // 默认 once，Always 走下面的 approveAlways
            ])
        } else {
            // Codex / Claude: 走老路
            HookSocketServer.shared.respondToPermission(
                toolUseId: permission.toolUseId,
                decision: "allow"
            )
        }

        await SessionStore.shared.process(
            .permissionApproved(sessionId: sessionId, toolUseId: permission.toolUseId)
        )
    }
}

func approvePermissionAlways(sessionId: String) {
    Task {
        guard let session = await SessionStore.shared.session(for: sessionId),
              let permission = session.activePermission else { return }

        if session.provider == .opencode, let requestId = permission.opencodeRequestId {
            OpencodeHookAdapter.sendCommand([
                "cmd": "permission.reply",
                "requestId": requestId,
                "reply": "always"
            ])
        }
        // Codex 不支持 always，走普通 allow
        else {
            HookSocketServer.shared.respondToPermission(
                toolUseId: permission.toolUseId,
                decision: "allow"
            )
        }

        await SessionStore.shared.process(
            .permissionApproved(sessionId: sessionId, toolUseId: permission.toolUseId)
        )
    }
}

func denyPermission(sessionId: String, reason: String?) {
    Task {
        guard let session = await SessionStore.shared.session(for: sessionId),
              let permission = session.activePermission else { return }

        if session.provider == .opencode, let requestId = permission.opencodeRequestId {
            var cmd: [String: Any] = [
                "cmd": "permission.reply",
                "requestId": requestId,
                "reply": "reject",
            ]
            if let reason { cmd["message"] = reason }
            OpencodeHookAdapter.sendCommand(cmd)
        } else {
            HookSocketServer.shared.respondToPermission(
                toolUseId: permission.toolUseId,
                decision: "deny",
                reason: reason
            )
        }

        await SessionStore.shared.process(
            .permissionDenied(sessionId: sessionId, toolUseId: permission.toolUseId, reason: reason)
        )
    }
}
```

#### 2.4 UI：Allow 按钮改为 Menu（三选一）

文件：`Nook/UI/Views/SessionListView.swift`（`InlineApprovalButtons`）

将 `Allow` 按钮改为 `Menu`，macOS 原生下拉。**当 `alwaysPattern` 不可用时退化为普通 Button**（Codex 场景）：

```swift
// alwaysPattern 有值时 → Menu（三选一）
// alwaysPattern 为 nil 时 → 原始 Button（二选一，Codex 兼容）
if let alwaysPattern, let onApproveAlways {
    Menu {
        Button("Allow once") { onApprove() }
        Button("Always allow \(alwaysPattern)") { onApproveAlways() }
    } label: {
        Text("Allow")
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(.black)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color.white.opacity(0.9))
            .clipShape(Capsule())
    }
} else {
    Button { onApprove() } label: {
        Text("Allow")
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(.black)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color.white.opacity(0.9))
            .clipShape(Capsule())
    }
    .buttonStyle(.plain)
}
```

- 默认点击 `Allow` = `once`（安全默认值）
- 下拉第二项 `Always allow xxx` 显示具体 pattern（如 `Always allow git *`）
- `alwaysPattern` 为 `nil`（Codex 场景）或 `onApproveAlways` 为 `nil` 时退化为普通 Button，保持原行为
- `alwaysPattern == "*"` 仍然显示为 `Always allow *`——不美化，让用户看到真实范围
- `onApproveAlways` 回调调 `SessionMonitor.approvePermissionAlways`

**签名变更**：

```swift
// 改前
struct InlineApprovalButtons: View {
    let onChat: () -> Void
    let onApprove: () -> Void
    let onReject: () -> Void
}

// 改后
struct InlineApprovalButtons: View {
    let onChat: () -> Void
    let onApprove: () -> Void          // once
    let onApproveAlways: (() -> Void)? // always，nil 则不显示选项
    let onReject: () -> Void
    let alwaysPattern: String?         // 展示用，如 "git *"
}
```

`InstanceRow` 传入 `alwaysPattern: session.activePermission?.alwaysPattern`，`onApproveAlways` 在 provider == .opencode 时传入，否则 nil。

---

## 完整改动文件清单

| 文件 | Step | 改动 |
| --- | --- | --- |
| `OpencodeHookAdapter.swift` | 1+2 | 加 `case "permission.asked"` + `handlePermissionAsked` + `sendCommand` |
| `OpencodeChatItemAdapter.swift` | 1 | 加 `case permissionAsked` + `OpencodePermissionRequest` struct |
| `SessionEvent.swift` | 1 | 加 `case opencodePermissionRequested(...)` |
| `SessionMonitor.swift` | 1+2 | 加 `onOpencodeEvent` 分发 + `approvePermissionAlways` + 分流逻辑 |
| `SessionStore.swift` | 1 | 加 `case .opencodePermissionRequested` + `processOpencodePermissionRequested` |
| `SessionState.swift` | 1 | `PermissionContext` 加 `opencodeRequestId` + `alwaysPattern` |
| `index.js` (plugin) | 2 | 加 command 处理（`permission.reply`） |
| `SessionListView.swift` | 2 | `InlineApprovalButtons` 改 Menu + 签名调整 |

---

## 不在本 spec 范围

| 项 | 理由 | 计划 |
| --- | --- | --- |
| `question.asked` 回复能力 | 回复是多选答案，UI/API 跟 permission 完全不同 | Step 3，独立 PR |
| DEFENSIVE 兜底（tool name=permission） | 当前 opencode 不会以 tool 形式发 permission | Step 4，防御性 |
| `permission.replied` 监听 | 悬空清理可用 tool completion 事件代替 | Step 4 |
| phase 超时回退（5s 无 replied → 回 `.processing`） | 需要 SessionStore 加 timer / 状态机，改动膨胀 | 后续，可放在 Step 4 |
| subagent 触发的 permission | subagent 的 permission 在 opencode 内部自决，不暴露给父 session | 暂不处理 |
| diff 预览 hover-expand | 视觉增强，非核心 | 后续 |
| 键盘快捷键 | ~~⌘↩ / ⌘⌫~~ 改为 Y/N/A（与 ChatApprovalBar 一致）；chat 页已上线，instances 页由 `docs/superpowers/specs/2026-09-23-session-list-permission-shortcuts-design.md` 实现 | 已取代 |

---

## 验收标准

1. opencode 会话触发 bash permission → notch 从 "Processing..." 切到 "Waiting for approval"，session row 显示 `bash` + 命令预览 + `[Deny] [Allow▾]`
2. 点击 Allow once → tool 放行，notch 回到 processing
3. 点击 Always allow `git *` → tool 放行 + 后续同 session 的 git 命令不再弹
4. 点击 Deny → tool 被拒 + 同 session 其他 pending permission 也被拒
5. Codex 会话的 Allow/Deny 行为不变（仍走 socket reply）
6. `permission.asked` 缺少 `tool.callID` 时，事件被静默跳过（log debug），notch 不误切状态

---

## 风险与缓解

| 风险 | 缓解 |
| --- | --- |
| plugin `input.client` 生命周期 | `input` 在 `server(input)` 工厂闭包内捕获，传给 `startCommandServer(input)`。`input.client` 是 `OpencodeClient` 单例，生命周期 = opencode 进程生命周期，不存在提前释放 |
| `/tmp/nook-command.sock` 残留（opencode 异常退出未清理） | `sendCommand` 连接失败时仅 `logNotice`，不 crash。下次 opencode 启动时 plugin 会重新 `listen()` 覆盖旧 socket 文件。Nook 侧也可以在连接前先 `unlink` 残留文件 |
| `always` pattern 为 `*`（如 edit）误导用户 | Menu 里显示原始 pattern：`Always allow *`，不美化。后续可在 UI 层加"所有文件"的中文映射 |
| opencode 版本升级后 `permission.asked` schema 变化 | `handlePermissionAsked` 对每个字段做 optional 解析，缺字段时 degrade gracefully（缺 callID → 跳过，缺 metadata → summary 用 patterns[0]） |
| plugin 的 `event` 钩子拿不到 `input` | `input` 只在 `server(input)` 工厂函数调用时可用（[plugin/index.ts:85](../../../opencode/packages/opencode/src/plugin/index.ts#L85)），不在每次 `event` 回调里传入。正确做法：在 `server(input)` 闭包内捕获 `input`，传给 `startCommandServer(input)`——跟 opencode 内置的 [github-copilot 插件](../../../opencode/packages/opencode/src/plugin/github-copilot/copilot.ts#L41) 同模式（`const sdk = input.client`） |

## 手动验证步骤

1. 启动 opencode（`opencode`），确认 plugin 加载成功（`/tmp/nook-command.sock` 存在）
2. 触发需要 permission 的操作（如 `bash: rm -rf /tmp/test`），确认 notch 从 "Processing..." 切到 "Waiting for approval"
3. 点击 `Allow` → 确认 tool 放行，notch 回到 processing
4. 再次触发 bash permission → 点击 `Allow▾` → 选择 `Always allow bash *` → 确认 tool 放行 + 后续 bash 不再弹
5. 触发 bash permission → 点击 `Deny` → 确认 tool 被拒 + 同 session 其他 pending permission 也被拒
6. 启动 Codex 会话触发 permission → 确认 Allow/Deny 行为不变（走 socket reply）
7. 在 debug log 里搜索 `permission.asked` → 确认有 `→ permissionAsked` 行
8. 断开 `/tmp/nook-command.sock` → 点击 Allow → 确认 notch 不 crash（仅 log 一行 sendCommand failed）

---

## 2026-07-14 补丁：UI 染色 / Popover 样式 / Plugin 自动升级

### 背景

permission 主链路在初版基础上发现三个回归：

1. **Notch 关闭态左侧问号颜色不跟随 agent**
   `NotchView.headerRow` 里 `PermissionIndicatorIcon` 的颜色被硬编码为 Claude 橙 `Color(red: 0.85, green: 0.47, blue: 0.34)`。opencode 触发 permission 时图标仍是橙色，与 opencode 的绿色品牌色不一致。

2. **Allow 下拉是系统 Menu，视觉与 Deny/Allow 胶囊按钮不协调**
   `InlineApprovalButtons` 用 SwiftUI `Menu` 实现 "Allow once / Always allow xxx" 二选一。点开后是 macOS 原生下拉（白底蓝字），和周围深色玻璃质感的胶囊按钮形成强烈对比。

3. **点击 Allow always 不生效（opencode 仍在阻塞）**
   用户安装的 plugin 是 6月12日的旧版本，没有 command server（`/tmp/nook-command.sock` 不存在）。但 `OpencodeHookInstaller.installIfNeeded` 只检查文件存在 + config 引用，不检查内容版本，所以新版 plugin 永远不会被部署——`approvePermissionAlways` 调用 `sendCommand` 连接失败被静默忽略，opencode 永远收不到 reply。

### 改动

#### Fix 1: NotchView 关闭态染色

`NotchView.swift` L752-775：`PermissionIndicatorIcon` 的颜色改用 `SessionLoadingStyle.tint(for: pendingProvider)`，其中 `pendingProvider` 来自 `activePendingPermissionActivityType`（已有的 provider 优先级 helper）。带 0.3s easeInOut 颜色过渡。

#### Fix 2: 自定义 Popover 替代系统 Menu

`SessionListView.swift` 新增 `AllowPopoverButton`：

- 沿用 SwiftUI `.popover(isPresented:arrowEdge:.top)` 提供定位 + 外部点击 dismiss
- popover 内部是手画的暗色玻璃卡片（`Color.black.opacity(0.96)` + `RoundedRectangle(cornerRadius:8)` + 0.5pt 白色描边）
- 每行用 `Button` + `RoundedRectangle(cornerRadius:5)` hover 态白字 12% 高亮
- Label 是带 chevron 的 "Allow ▾" 胶囊，chevron 在展开时翻转 180°

`alwaysPattern == nil`（Codex 场景）仍走原 `Button` 分支，行为不变。

#### Fix 3: OpencodeHookInstaller 内容比对

`OpencodeHookInstaller.swift`：

- 新增 `installedFilesMatchBundled()`：byte-identical 比对 bundled `index.js` + `package.json` 与 installed 副本
- 新增 `bundledPluginFiles()`：从 bundle 找到 plugin 文件并读取内容
- `installIfNeeded` 改为：当 `!isInstalled() || !installedFilesMatchBundled()` 时强制 `copyPluginFiles()`（无条件覆盖）
- 已经在 config 注册过的（`wasRegistered == true`）跳过 CLI/config edit 路径，仅刷新文件

### 其他 agent 是否受影响

- **Codex** `CodexHookInstaller.installBridgeScript()`：每次启动无条件 `script.write(to: atomically:)` 覆盖。**没有版本问题。**
- **Cursor** `CursorHookInstaller.installBridgeScript()`：同上。**没有版本问题。**
- **Claude** `HookInstaller.installIfNeeded()`：每次启动无条件 `removeItem + copyItem` 覆盖 `nook-state.py`。**没有版本问题。**

只有 opencode 因为最早的 `installIfNeeded` 是 "安装一次就不再覆盖" 模式，所以唯一需要补丁的 installer 是它。

### 验收（用户验证后补）

- [ ] opencode permission 触发时，notch 关闭态左侧问号图标颜色是 opencode 绿
- [ ] claude permission 触发时，仍是橙色（无回归）
- [ ] 点击 `Allow ▾` 弹出深色 popover，hover 行有 12% 白色高亮
- [ ] 点击 popover 外部任意位置 popover 关闭
- [ ] 点击 `Allow once` → tool 放行
- [ ] 点击 `Always allow bash *` → tool 放行 + 后续 bash 不再弹
- [ ] 升级 Nook 到新版（带新 plugin）后，重启 Nook → `~/.config/opencode/plugins/nook/index.js` 自动更新
- [ ] `/tmp/nook-command.sock` 存在
