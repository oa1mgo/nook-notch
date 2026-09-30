# OpenCode 多实例 pid 隔离 — 实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 实现 [spec: OpenCode 多实例 pid 隔离](../specs/2026-08-13-opencode-multi-instance-pid-isolation.md) —— 用 opencode 进程 pid 统一修复 serverPort 串台 / permission 落错实例 / 用户消息沉底。

**Architecture:** 见 spec「架构」章节。核心：plugin 上报带 pid + command socket 按 pid 命名 + Nook 侧 pid→port 映射 + 本地 prompt 用 appendOrder。

**Tech Stack:** JavaScript (opencode plugin) + Swift (Nook App) + XCTest (NookTests target)

---

## 任务分解

### Task 1: Plugin 上报带 pid，command socket 按 pid 命名

**Files:**
- Modify: `Nook/Resources/opencode-plugin/index.js`

**背景**：plugin 的 `process.pid` 在 worker thread 中与主进程相同，是 opencode 实例的唯一标识（spec 决策 1，命门）。所有上报到 Nook 的事件都要带 pid；command socket 路径改为 pid 专属，避免多实例抢同一 socket（spec 决策 2）。

- [ ] **Step 0: 实跑验证 process.pid 假设（spec 命门）**

在 plan 实施前先实证：`process.pid` 在 plugin 的 worker thread 中 === opencode 主进程 pid。方法：

```bash
# 1. 启动一个 opencode 实例，记录其 pid
#    pgrep -x 精确匹配进程名，避免 -f 误匹配命令行含 opencode 的其他进程
ps -o pid,command -p $(pgrep -x opencode | head -1)
# 2. 在 index.js 的 logDebug 加一行 `logDebug(`pid=${process.pid}`)`
#    （或直接看已有 serverPort 上报的 pid 字段与 pgrep 结果比对）
# 3. 重启该实例，tail /tmp/nook-plugin-debug.log 确认 pid 一致
```

若发现 pid 不一致（plugin 跑在独立 child_process），立即停止，回滚方案（pid 标识不成立），与 spec 决策 1 冲突需要重新设计。

- [ ] **Step 1: 修改 plugin 代码**

```js
const PLUGIN_VERSION = "1.2.0";
const INSTANCE_PID = process.pid;
const COMMAND_SOCKET_PATH = `/tmp/nook-command-${INSTANCE_PID}.sock`;
```

`logDebug` 全局前缀 pid（多实例写同一 log 时按行区分实例）：

```js
function logDebug(message) {
  try {
    fs.appendFileSync(DEBUG_LOG, `[${new Date().toISOString()}] pid=${INSTANCE_PID} ${message}\n`);
  } catch {}
}
```

退出时清理 pid socket，避免 `/tmp` 累积残留：

```js
process.on("exit", () => {
  try { fs.unlinkSync(COMMAND_SOCKET_PATH); } catch {}
});
```

`sendServerPort()` 的 payload 加 pid：

```js
send({
  origin: "opencode",
  type: "serverPort",
  properties: { port, pid: INSTANCE_PID },
}).then(...)
```

`event` handler 转发时把 pid 合并进 properties（防御：properties 可能非对象）：

```js
event: async ({ event }) => {
  if (event.type === "permission.asked") {
    logDebug(`permission.asked pid=${INSTANCE_PID} props=${JSON.stringify(event.properties)}`);
  }
  const props = (typeof event.properties === "object" && event.properties !== null)
    ? { ...event.properties, pid: INSTANCE_PID }
    : { pid: INSTANCE_PID };
  await send({
    origin: "opencode",
    type: event.type,
    properties: props,
  });
},
```

- [ ] **Step 2: 同步 package.json 版本（UI 一致性）**

`Nook/Resources/opencode-plugin/package.json:3` 的 `"version"` 与 `PLUGIN_VERSION` 同步升到 `1.2.0`（AgentSettingsView.swift:64-66 从安装的 package.json 读"已安装版本"，不一致会误报）。

```bash
# 手动把 package.json 的 "version": "1.1.0" → "1.2.0"
```

- [ ] **Step 3: 语法检查 + 同步安装位置**

```bash
node --check Nook/Resources/opencode-plugin/index.js
cp Nook/Resources/opencode-plugin/index.js ~/.config/opencode/plugins/nook/index.js
cp Nook/Resources/opencode-plugin/package.json ~/.config/opencode/plugins/nook/package.json
```

- [ ] **Step 4: Commit**

```bash
git add Nook/Resources/opencode-plugin/index.js Nook/Resources/opencode-plugin/package.json
git commit -m "feat(plugin): pid-scoped command socket + pid in events"
```

---

### Task 2: 事件模型 — serverPortReceived 带 pid（全链路 3 处）

**Files:**
- Modify: `Nook/Services/Hooks/OpencodeHookModels.swift:42`
- Modify: `Nook/Models/SessionEvent.swift:73`（+ description :318）
- Modify: `Nook/Services/Session/SessionMonitor.swift:118`（转发）
- Modify: `Nook/Services/State/SessionStore.swift:199`（解构）+ `:1119` `processOpencodeServerPortReceived` 签名（实现体在 Task 4 改）

**背景**：pid 要贯穿到 SessionStore 需过 4 层：adapter 事件模型 → SessionMonitor 转发 → SessionStore 的 SessionEvent 模型 → 解构 → 函数签名。**缺任一环编译失败**，且这 5 处必须**同一 commit 内改完**才能编译通过（SessionEvent case 加 pid 后，`SessionStore.swift:199` 的 3 参数解构会立即报错）。

- [ ] **Step 1: 更新 OpencodeHookModels.swift**

```swift
case serverPortReceived(sessionId: String, port: Int, version: String?, pid: Int?)
```

- [ ] **Step 2: 更新 SessionEvent.swift**

```swift
// :73
case opencodeServerPortReceived(sessionId: String, port: Int, version: String?, pid: Int?)
// :318-319 description
case .opencodeServerPortReceived(let sessionId, let port, let version, let pid):
    return "opencodeServerPortReceived(session: \(sessionId.prefix(8)), port: \(port), pid: \(pid ?? -1), version: \(version ?? "-"))"
```

- [ ] **Step 3: 更新 SessionMonitor.swift:118 转发**

```swift
case .serverPortReceived(let sessionId, let port, let version, let pid):
    await SessionStore.shared.process(.opencodeServerPortReceived(sessionId: sessionId, port: port, version: version, pid: pid))
```

- [ ] **Step 4: 更新 SessionStore.swift:199 解构 + 函数签名**

`:199` 解构（调用签名加 pid）：

```swift
case .opencodeServerPortReceived(let sessionId, let port, let version, let pid):
    await processOpencodeServerPortReceived(sessionId: sessionId, port: port, version: version, pid: pid)
```

`:1119` `processOpencodeServerPortReceived` 签名加 pid 参数。**保留 `SessionStore.swift:1119-1140` 的完整实现体不变**，仅签名加 `pid: Int?`（函数体内暂时 unused，会触发 warning 但可编译；Task 4 才改为 pid 映射）：

```swift
// 只改这一行签名，实现体一行不动
private func processOpencodeServerPortReceived(sessionId: String, port: Int, version: String?, pid: Int?) {
    // ...完整保留原有 1119-1140 实现体，本任务不改动...
}
```

- [ ] **Step 5: 编译验证 + Commit**

```bash
xcodebuild -project Nook.xcodeproj -scheme Nook -configuration Debug -destination 'platform=macOS' build
git add Nook/Services/Hooks/OpencodeHookModels.swift Nook/Models/SessionEvent.swift Nook/Services/Session/SessionMonitor.swift Nook/Services/State/SessionStore.swift
git commit -m "feat(model): serverPortReceived carries instance pid through the event chain"
```

---

### Task 3: OpencodeHookAdapter — 解析 pid 并透传

**Files:**
- Modify: `Nook/Services/Hooks/OpencodeHookAdapter.swift`（`handleServerPort`）

**背景**：`serverPort` 事件 properties 现在带 `pid`，adapter 解析后透传到 `serverPortReceived`。

- [ ] **Step 1: 更新 handleServerPort**

```swift
private static func handleServerPort(_ props: [String: AnyCodable], sessionId: String) -> [OpencodeSessionEvent] {
    guard let raw = props["port"]?.value, let port = (raw as? Int) ?? Int(raw as? String ?? "") else {
        Self.logNotice("→ serverPort dropped (no port) session=\(sessionId)")
        return []
    }
    let version = props["version"]?.value as? String
    let pid = (props["pid"]?.value as? Int) ?? Int(props["pid"]?.value as? String ?? "")
    let cwd: String = {
        lock.lock()
        let v = sessionCwd[sessionId] ?? ""
        lock.unlock()
        return v
    }()
    Self.logNotice("→ serverPort session=\(sessionId) port=\(port) pid=\(pid ?? -1) version=\(version ?? "-")")
    return [.serverPortReceived(sessionId: sessionId, port: port, version: version, pid: pid)]
}
```

- [ ] **Step 2: 编译验证 + Commit**

```bash
xcodebuild -project Nook.xcodeproj -scheme Nook -configuration Debug -destination 'platform=macOS' build
git add Nook/Services/Hooks/OpencodeHookAdapter.swift
git commit -m "feat(adapter): parse and forward instance pid"
```

---

### Task 4: SessionStore — pid → port 映射，按 session.pid 绑定

**Files:**
- Modify: `Nook/Services/State/SessionStore.swift`（属性区、createOpencodeSession、processOpencodeServerPortReceived、probeOpencodeServerPort、enrichOpencodeRuntimeMetadata）
- Test: `NookTests/SessionStoreServerPortTests.swift`

**背景**：用 `[pid: port]` 字典替代全局单值。session 的 `serverPort` 从其 `pid`（enrichOpencodeRuntimeMetadata 已设置）查表得到。保留 fallback：无 pid 的上报走全局广播（兼容旧 plugin，spec 决策 4）。

**注意**：`SessionStore` 是 `actor`，`process(_:)` 是 async，测试必须 `await`。`setSessionPidForTesting(sessionId:pid:)` 存在于 `SessionStore.swift:2693`（DEBUG 编译条件），可注入 pid 做端到端断言。

- [ ] **Step 1: 写 failing 测试**

新建 `NookTests/SessionStoreServerPortTests.swift`，验证 pid → port 精确绑定不串台 + fallback 路径：

```swift
import XCTest
@testable import Nook

final class SessionStoreServerPortTests: XCTestCase {
    /// 多实例：各 session 的 serverPort 由自身 pid 绑定，互不串台。
    func testServerPortBoundByPidDoesNotLeakAcrossInstances() async {
        let store = SessionStore.shared
        await store.resetForTesting()  // 单例 actor，防止跨测试污染

        await store.process(.opencodeSessionStarted(sessionId: "A", cwd: "/tmp/proj-a"))
        await store.process(.opencodeSessionStarted(sessionId: "B", cwd: "/tmp/proj-b"))

        // 模拟 enrichOpencodeRuntimeMetadata 按 cwd 解析出的进程 pid
        await store.setSessionPidForTesting(sessionId: "A", pid: 100)
        await store.setSessionPidForTesting(sessionId: "B", pid: 200)

        // 两个实例各上报端口
        await store.process(.opencodeServerPortReceived(sessionId: "?", port: 4096, version: nil, pid: 100))
        await store.process(.opencodeServerPortReceived(sessionId: "?", port: 55123, version: nil, pid: 200))

        let a = await store.session(for: "A")
        let b = await store.session(for: "B")
        XCTAssertEqual(a?.serverPort, 4096)
        XCTAssertEqual(b?.serverPort, 55123)
    }

    /// 旧 plugin（无 pid）：fallback 广播到所有 opencode session。
    func testServerPortFallbackBroadcastsWhenNoPid() async {
        let store = SessionStore.shared
        await store.resetForTesting()  // 单例 actor，防止跨测试污染

        await store.process(.opencodeSessionStarted(sessionId: "A", cwd: "/tmp/proj-a"))
        await store.process(.opencodeServerPortReceived(sessionId: "?", port: 4096, version: nil, pid: nil))

        let a = await store.session(for: "A")
        XCTAssertEqual(a?.serverPort, 4096)
    }
}
```

**确认测试现有注入模式**：查看 `NookTests/SessionStoreCodexLifecycleTests.swift`，若 `process(.opencodeSessionStarted(...))` 需额外参数或 state 清理，按现有模式对齐。

- [ ] **Step 2: 运行测试确认失败**

```bash
xcodebuild -project Nook.xcodeproj -scheme Nook -configuration Debug -destination 'platform=macOS' test -only-testing:NookTests/SessionStoreServerPortTests
```

（期望失败：当前实现不区分 pid，A/B 都会拿到最后上报的 55123。）

- [ ] **Step 3: 实现 pid → port 映射**

`opencodeServerPort` 在 SessionStore 的全部引用点（共 8 处）及替换策略：

| 行号 | 代码 | 替换策略 |
|------|------|----------|
| :45 | `private var opencodeServerPort: Int?` | 删除，改为下面两个属性 |
| :889 | `serverPort: opencodeServerPort`（createOpencodeSession） | 改 `nil`（后续 enrich / serverPort 事件回填） |
| :945 | `session.serverPort == nil && opencodeServerPort == nil`（processOpencodeSessionStart probe 条件） | 改 `... && opencodeServerPortFallback == nil && opencodeServerPorts.isEmpty` |
| :960 | `session.serverPort == nil && opencodeServerPort == nil`（processOpencodeProcessingStarted probe 条件） | 同上 |
| :1093 | `guard opencodeServerPort == nil else { return }`（probeOpencodeServerPort） | 改 `guard opencodeServerPortFallback == nil && opencodeServerPorts.isEmpty else { return }` |
| :1102 | `applyOpencodeServerPort(port)`（probe 内调用） | 删除该调用，probe 直接写 fallback |
| :1110-1117 | `applyOpencodeServerPort` 函数体 | **整个函数删除**（probe 不再间接，直接写 `opencodeServerPortFallback`） |
| :1127 | `opencodeServerPort = port`（processOpencodeServerPortReceived 的 `"?"` 分支） | 改 `opencodeServerPortFallback = port` |

属性区（替换 :45）：

```swift
/// pid → server port, for multi-instance opencode. Sessions bind their
/// serverPort from the pid that enrichOpencodeRuntimeMetadata resolves.
private var opencodeServerPorts: [Int: Int] = [:]
/// Legacy fallback: port from a plugin that reports no pid, or from probe.
private var opencodeServerPortFallback: Int?
```

**探测语义**：:945/:960/:1093 统一为"完全不知道任何端口（无 fallback 且无 pid 映射）才探测"。探测结果无 pid，写入 fallback 并广播到 nil serverPort session。

**消除重复**：probe 回填（:320-323）与 `processOpencodeServerPortReceived` 的 fallback 分支（:344-347）是同一段"写 fallback + for 循环回填 nil session"。提取私有方法复用，两处调用：

```swift
/// Legacy plugin / probe path: write global fallback and backfill all
/// opencode sessions that don't have a port yet.
private func applyOpencodeFallbackPort(_ port: Int) {
    opencodeServerPortFallback = port
    for (id, var session) in sessions where session.provider == .opencode && session.serverPort == nil {
        session.serverPort = port
        sessions[id] = session
    }
    publishState()
}
```

`probeOpencodeServerPort`（:1092-1108）改造：

```swift
private func probeOpencodeServerPort() async {
    guard opencodeServerPortFallback == nil && opencodeServerPorts.isEmpty else { return }
    let ports = [4096, 4097, 4098]
    for port in ports {
        guard let url = URL(string: "http://127.0.0.1:\(port)/global/health") else { continue }
        var request = URLRequest(url: url)
        request.timeoutInterval = 1
        if let (_, response) = try? await URLSession.shared.data(for: request),
           let http = response as? HTTPURLResponse, http.statusCode == 200 {
            writeDebugLogAsync("[opencode-server] probe OK port=\(port)")
            applyOpencodeFallbackPort(port)
            return
        }
    }
    writeDebugLogAsync("[opencode-server] probe FAILED (TUI mode or no server)")
}
```

`processOpencodeServerPortReceived`（:1119-1140）：

```swift
private func processOpencodeServerPortReceived(sessionId: String, port: Int, version: String?, pid: Int?) {
    if let version, !version.isEmpty {
        opencodePluginVersion = version
        opencodePluginVersionSubject.send(version)
    }
    guard let pid else {
        // Legacy plugin (no pid) or "?" broadcast: global fallback
        applyOpencodeFallbackPort(port)
        return
    }
    // Precise instance binding
    opencodeServerPorts[pid] = port
    for (id, var session) in sessions where session.provider == .opencode && session.serverPort == nil {
        if session.pid == pid {
            session.serverPort = port
        } else if let sessionPid = session.pid, let known = opencodeServerPorts[sessionPid] {
            session.serverPort = known
        }
        sessions[id] = session
    }
    publishState()
}
```

**注意**：原 `:1127` 的 `"?"` 分支（`sessionId == "?" || !registeredSessionIds.contains(sessionId)`）在 pid 分支下被简化——新 plugin 永远带 pid，走精确绑定；无 pid 时（旧 plugin）统一走 fallback 广播，不再区分 `"?"` vs 具体 sessionId。若需保留原 `"?"` 精确分支行为，在 guard 前按 `sessionId` 分支处理（见风险点 3）。

`enrichOpencodeRuntimeMetadata`（:1459-1468）拿到 `process.pid` 后回填 port：

```swift
if let port = opencodeServerPorts[process.pid] {
    session.serverPort = port
}
```

- [ ] **Step 4: 运行测试确认通过 + 编译全量**

```bash
xcodebuild -project Nook.xcodeproj -scheme Nook -configuration Debug -destination 'platform=macOS' test -only-testing:NookTests/SessionStoreServerPortTests
xcodebuild -project Nook.xcodeproj -scheme Nook -configuration Debug -destination 'platform=macOS' build
```

- [ ] **Step 5: Commit**

```bash
git add Nook/Services/State/SessionStore.swift NookTests/SessionStoreServerPortTests.swift
git commit -m "feat(store): pid-scoped serverPort binding for multi-instance opencode"
```

---

### Task 5: OpencodeCommandSocket — 按 pid 连接对应 socket

**Files:**
- Modify: `Nook/Services/Hooks/OpencodeCommandSocket.swift:20,26,40`

**背景**：socket 路径从固定 `/tmp/nook-command.sock` 变为 `/tmp/nook-command-<pid>.sock`。`sendCommand` 增加 pid 参数，无 pid 时 fallback 到兼容路径（spec 决策 4）。

- [ ] **Step 1: 更新 sendCommand 签名**

```swift
final class OpencodeCommandSocket: @unchecked Sendable {
    static let shared = OpencodeCommandSocket()
    private init() {}

    /// Legacy socket path (no pid) — used only as fallback for old plugins.
    static let legacySocketPath = "/tmp/nook-command.sock"

    static func socketPath(forPid pid: Int?) -> String {
        guard let pid, pid > 0 else { return legacySocketPath }
        return "/tmp/nook-command-\(pid).sock"
    }

    func sendCommand(_ payload: [String: Any], pid: Int? = nil) {
        let path = Self.socketPath(forPid: pid)
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            self.connectAndWrite(data, to: path)
        }
    }

    private func connectAndWrite(_ data: Data, to path: String) {
        // 现有 connect/write 逻辑不变，仅路径改为参数
    }
}
```

- [ ] **Step 2: 编译验证 + Commit**

```bash
xcodebuild -project Nook.xcodeproj -scheme Nook -configuration Debug -destination 'platform=macOS' build
git add Nook/Services/Hooks/OpencodeCommandSocket.swift
git commit -m "feat(socket): route permission replies to pid-scoped socket"
```

---

### Task 6: SessionMonitor — permission reply 带 session.pid

**Files:**
- Modify: `Nook/Services/Session/SessionMonitor.swift`（`sendCommand` 调用点 :221, :263, :284）

**背景**：三个 permission 回复路径（approve / approve+always / deny）都需要把 session 的 opencode 进程 pid 传给 `OpencodeCommandSocket`，确保 reply 落到正确的实例。（`serverPortReceived` 转发的 pid 已在 Task 2 处理。）

- [ ] **Step 1: 更新三个调用点**

`approvePermission(sessionId:)`、`approvePermission(sessionId:always:)`、`denyPermission(sessionId:reason:)` 中所有 `OpencodeCommandSocket.shared.sendCommand([...])` 加第二个参数：

```swift
OpencodeCommandSocket.shared.sendCommand([
    "cmd": "permission.reply",
    "requestId": requestId,
    "reply": "...",  // "once" / "always" / "reject"
], pid: session.pid)
```

加日志：`... pid=\(session.pid ?? -1)`。

**前提**：`approvePermission` / `denyPermission` 已通过 `SessionStore.shared.session(for: sessionId)` 拿到 session，`session.pid` 在 opencode 会话正常生命周期中被 `enrichOpencodeRuntimeMetadata` 填充。

- [ ] **Step 2: 编译验证 + Commit**

```bash
xcodebuild -project Nook.xcodeproj -scheme Nook -configuration Debug -destination 'platform=macOS' build
git add Nook/Services/Session/SessionMonitor.swift
git commit -m "fix(session): send permission replies to the owning instance pid"
```

---

### Task 7: ChatView + SessionStore + Reducer — 本地 prompt 不参与字典序排序

**Files:**
- Modify: `Nook/Services/State/SessionStore.swift`（`processOpencodePromptSubmitted`）
- Modify: `Nook/Services/Shared/ChatItemUpdateReducer.swift:52-63`（dedup ordering 保留方向）
- Test: `NookTests/ChatItemUpdateReducerTests.swift`

**背景**：本地 prompt 用假 messageId `opencode-prompt-...` 参与 messageRelative 排序，字典序 `o...` > `m...` 恒沉底（spec 决策 3）。修复：本地 prompt 改用 `.appendOrder`；同时 reducer 的 dedup 分支只允许 messageRelative 覆盖 appendOrder，反向不降级。

- [ ] **Step 1: 写 failing 测试**

在 `ChatItemUpdateReducerTests.swift` 添加：

```swift
func testHookEchoUpgradesLocalPromptOrderingFromAppendToMessageRelative() {
    var items: [ChatHistoryItem] = []
    var orderings: [String: BlockOrdering] = [:]

    // 1. Hook echo arrives first (adapter path) with real messageId
    apply(
        id: "opencode-msg-abc-prompt-0",
        block: .userPrompt("Hello world"),
        ordering: .messageRelative(messageId: "msg-abc", typePriority: .reasoning, blockIndex: 0),
        items: &items, orderings: &orderings
    )
    // 2. Local fallback arrives later (SessionStore path) — must not override
    apply(
        id: "opencode-prompt-session-1234567890",
        block: .userPrompt("Hello world"),
        ordering: .appendOrder,
        items: &items, orderings: &orderings
    )

    XCTAssertEqual(items.count, 1)
    guard case .messageRelative(let messageId, _, _) = orderings[items[0].id] else {
        return XCTFail("Expected messageRelative ordering to be preserved")
    }
    XCTAssertEqual(messageId, "msg-abc")
}

func testLocalPromptFirstThenHookEchoUsesRealMessageId() {
    var items: [ChatHistoryItem] = []
    var orderings: [String: BlockOrdering] = [:]

    apply(
        id: "opencode-prompt-session-1234567890",
        block: .userPrompt("Hello world"),
        ordering: .appendOrder,
        items: &items, orderings: &orderings
    )
    apply(
        id: "opencode-msg-abc-prompt-0",
        block: .userPrompt("Hello world"),
        ordering: .messageRelative(messageId: "msg-abc", typePriority: .reasoning, blockIndex: 0),
        items: &items, orderings: &orderings
    )

    XCTAssertEqual(items.count, 1)
    guard case .messageRelative(let messageId, _, _) = orderings[items[0].id] else {
        return XCTFail("Expected messageRelative ordering")
    }
    XCTAssertEqual(messageId, "msg-abc")
}
```

- [ ] **Step 2: 运行测试确认失败**

```bash
xcodebuild -project Nook.xcodeproj -scheme Nook -configuration Debug -destination 'platform=macOS' test -only-testing:NookTests/ChatItemUpdateReducerTests/testHookEchoUpgradesLocalPromptOrderingFromAppendToMessageRelative
```

（期望失败：reducer 当前无条件 `orderings[existingId] = update.ordering`，第二条 appendOrder 会覆盖成 appendOrder。）

- [ ] **Step 3: 修改本地 prompt ordering 为 appendOrder**

`SessionStore.swift` `processOpencodePromptSubmitted`（`:1078-1083`）：

```swift
let id = "opencode-prompt-\(sessionId)-\(millis)"
let update = ChatItemUpdate(
    id: id, sessionId: sessionId,
    block: .userPrompt(trimmedPrompt),
    ordering: .appendOrder,        // 不再伪造 messageId 参与字典序
    mutation: .insert, provider: .opencode
)
```

**同步现有测试入参（Step 3 完成本地 prompt 改造后才做）**：`ChatItemUpdateReducerTests.swift:125` `testSameContentUserPromptDifferentIdIsDeduplicated` 当前用 `.messageRelative(messageId: "opencode-prompt-session-1234567890", ...)` 模拟本地 prompt，Step 3 后该入参已不反映真实行为（不会失败，但失去准确性），**同步改为**：

```swift
// 本地 prompt（SessionStore 路径）—— 已改为 appendOrder
apply(
    id: "opencode-prompt-session-1234567890",
    block: .userPrompt("Hello world"),
    ordering: .appendOrder,
    items: &items,
    orderings: &orderings
)

// Hook echo（OpencodeChatItemAdapter 路径）—— 真 id 保持 messageRelative
apply(
    id: "opencode-msg-abc-prompt-0",
    block: .userPrompt("Hello world"),
    ordering: .messageRelative(messageId: "msg-abc", typePriority: .reasoning, blockIndex: 0),
    items: &items,
    orderings: &orderings
)
```

（断言不变：count == 1、prompt 文本、id 保留本地 id。该测试不断言 ordering，Task 7 的两个新测试才覆盖 ordering 保留方向。）

- [ ] **Step 4: 修改 reducer dedup 保留 messageRelative**

`ChatItemUpdateReducer.swift:48-63` 的 dedup 分支。语义：**messageRelative 永远赢，appendOrder 只在无现有时写入**：

```swift
if case .userPrompt(let newText) = update.block,
   let existingIdx = items.firstIndex(where: {
       if case .user(let existingText) = $0.type {
           return existingText == newText
       }
       return false
   }) {
    let existingId = items[existingIdx].id
    // Preserve the strongest ordering: messageRelative (real msg_ id) must
    // never be downgraded to appendOrder by the local fallback. AppendOrder
    // is the local-fallback sentinel that does not participate in
    // lexicographic messageId comparison.
    if case .messageRelative = update.ordering {
        orderings[existingId] = update.ordering
    } else if orderings[existingId] == nil {
        orderings[existingId] = update.ordering
    }
    // 否则保留 existing（不降级）
    return
}
```

**语义验证**：
- existing=messageRelative, update=appendOrder → 不覆盖（保留真 id）✓
- existing=nil, update=appendOrder → 写入 appendOrder（本地兜底）✓
- existing=appendOrder 或 nil, update=messageRelative → 覆盖为真 id ✓
- existing=messageRelative, update=messageRelative → 覆盖（同值）✓

- [ ] **Step 5: 运行测试确认通过 + 编译全量**

```bash
xcodebuild -project Nook.xcodeproj -scheme Nook -configuration Debug -destination 'platform=macOS' test -only-testing:NookTests/ChatItemUpdateReducerTests/testHookEchoUpgradesLocalPromptOrderingFromAppendToMessageRelative -only-testing:NookTests/ChatItemUpdateReducerTests/testLocalPromptFirstThenHookEchoUsesRealMessageId
xcodebuild -project Nook.xcodeproj -scheme Nook -configuration Debug -destination 'platform=macOS' build
```

- [ ] **Step 6: Commit**

```bash
git add Nook/Services/State/SessionStore.swift Nook/Services/Shared/ChatItemUpdateReducer.swift NookTests/ChatItemUpdateReducerTests.swift
git commit -m "fix(chat): local prompt uses appendOrder, hook echo keeps messageRelative ordering"
```

---

### Task 8: 端到端验证（多实例）

**Files:** 无（验证脚本）

**背景**：所有改动落地后，用两个 opencode 实例验证三个问题全部修复。

- [ ] **Step 1: 重启 Nook**（终止当前实例，从 Xcode 重新 Run）
- [ ] **Step 2: 启动两个 opencode 实例**

```bash
# 终端 1（带 --port）
opencode --port -s <ses-a>
# 终端 2（带 --port）
opencode --port -s <ses-b>
```

- [ ] **Step 3: 验证 serverPort 各归其位**

```bash
grep -a "serverPort" /tmp/nook-debug.log | tail
# 期望：两行不同 pid，各 session.serverPort 为各自端口
```

- [ ] **Step 4: 验证 permission reply 落在正确实例**

```bash
tail -10 /tmp/nook-plugin-debug.log
# 期望：reply OK res={"data":true} 而非 PermissionNotFoundError
```

- [ ] **Step 5: 验证用户消息不再沉底**

在 Nook ChatView 发送消息，确认 user prompt 紧跟在上一条 assistant 之后，不固定沉底。

- [ ] **Step 6: 更新 spec 文档**

`docs/specs/2026-08-13-opencode-multi-instance-pid-isolation.md` 状态改为 ✅ 实现，补充实测记录。

---

## 兼容性 / 边界

| 场景 | 处理 |
|------|------|
| 旧 plugin（无 pid 上报） | `serverPort` 走全局 fallback（`opencodeServerPortFallback`） |
| 旧 plugin（固定 command socket） | `OpencodeCommandSocket` 无 pid 时连接 legacy 路径 |
| 单实例（最常见） | pid = 该实例，行为与之前一致 |
| 多实例同 cwd（edge case） | `bestMatchingOpencodeProcess` 取 pid 最大者，可能串；属已知限制 |
| permission 无 opencodeRequestId（Claude/Codex） | 不受影响，仍走 hook socket |
| 探测端口（probe） | 无法得知 pid，写入 fallback 并广播 |
| 升级场景：旧 plugin 先 fallback 设 port，新 plugin 上线带 pid 上报真实 port | pid 分支只回填 `serverPort == nil` 的 session，已有 port 不被更正。属可接受的 edge case（旧 plugin 会连 legacy socket，不混合使用） |

## 风险点

1. **SessionStore 测试注入**：已确认 `setSessionPidForTesting(sessionId:pid:)`（SessionStore.swift:2693）可用，Task 4 测试用它做端到端断言，无需依赖真实进程树。
2. **reducer 排序逻辑**：Task 7 的 dedup 已简化为「messageRelative 永远赢，appendOrder 仅在无现有时写入」，不含 Optional 模式匹配分支（见 Task 7 Step 4 语义验证表）。
3. **原 `"?"` 精确分支**：`processOpencodeServerPortReceived` 原实现区分 `sessionId == "?"` 与具体 sessionId（:1120-1138）。本 plan 的 pid 分支将其统一——新 plugin 带 pid 走精确绑定；旧 plugin 无 pid 一律广播。若需保留按 sessionId 的精确绑定行为，在 guard 前按 `sessionId` 分支处理（旧 plugin 场景一般无需，此行为属过度设计）。
4. **多 plugin debug log 互相覆盖**：所有 opencode 实例写同一 `/tmp/nook-plugin-debug.log`，`logDebug` 已前缀 pid（Task 1），按行区分，不阻塞。
5. **socket 文件残留**：插件退出不清理 pid socket，下次启动 unlink 自己的 pid 路径，无冲突（Task 1 已加 `process.on("exit")` 清理）。
