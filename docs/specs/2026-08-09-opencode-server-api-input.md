# OpenCode Server API 输入 — 替代 tmux send-keys

> 日期: 2026-08-09
> 状态: 📋 Spec
> 适用: opencode provider 的用户输入路径
> 关联: [opencode Server API](https://opencode.ai/docs/server/) · [opencode SDK](https://opencode.ai/docs/sdk/)

## TL;DR

当前 Nook 通过 `tmux send-keys` 向 OpenCode 发送用户输入，仅在 tmux/CLI 模式下工作。本 spec 添加 OpenCode Server HTTP API 作为替代路径，使 Desktop 模式下 ChatView 输入框也能正常工作。

改动范围：~150 行，4 个文件，零新文件。

---

## 问题陈述

### 现象

OpenCode 以 Desktop 模式运行时，ChatView 输入框被禁用（`canSendMessages = false`），用户无法发送消息。

### 根因

```swift
// ChatView.swift:469-471
private var canSendMessages: Bool {
    session.isInTmux && session.tty != nil  // Desktop 模式下为 false
}
```

`sendToSession` 仅支持 `tmux send-keys`：

```swift
// ChatView.swift:759-766
private func sendToSession(_ text: String) async {
    guard session.isInTmux else { return }  // Desktop 模式直接 return
    guard let tty = session.tty else { return }
    if let target = await findTmuxTarget(tty: tty) {
        _ = await ToolApprovalHandler.shared.sendMessage(text, to: target)
    }
}
```

### 为什么 OpenCode 可以用 Server API

OpenCode 始终运行 HTTP server（即使 TUI 模式），暴露完整 API：

```
POST /session/{id}/message
Body: { parts: [{ type: "text", text: "..." }] }
```

SDK 示例：
```typescript
const result = await client.session.prompt({
  path: { id: sessionId },
  body: {
    parts: [{ type: "text", text: "Hello!" }],
  },
})
```

### Provider 限制

| Provider | 有 Server API？ | 输入方式 |
|----------|-----------------|----------|
| Claude | ❌ | tmux send-keys |
| Codex | ❌ | tmux send-keys |
| **OpenCode** | ✅ | **tmux send-keys + HTTP API** |
| Cursor | ❌ | IDE 集成 |

---

## 设计方案

### 核心思路

1. **SessionState** 添加 `serverPort` 属性，记录 OpenCode server 端口
2. **ChatView** 更新 `canSendMessages` 逻辑，支持 tmux OR server
3. **sendToSession** 添加 server API fallback
4. **UI** 根据连接方式显示不同状态

### 1. SessionState 扩展

```swift
// SessionState.swift
struct SessionState {
    var pid: Int?
    var tty: String?
    var isInTmux: Bool
    var serverPort: Int?  // 新增：OpenCode server 端口（仅 opencode provider）
}
```

**获取时机**：
- OpenCode 启动时，plugin 通过 `/tmp/nook.sock` 发送 server 端口信息
- 或 Nook 主动探测 `http://localhost:4096/global/health`

### 2. ChatView 判断逻辑

```swift
// ChatView.swift
private var canSendMessages: Bool {
    switch session.provider {
    case .opencode:
        // OpenCode: tmux 或 server 任一可用即可
        return (session.isInTmux && session.tty != nil) || session.serverPort != nil
    case .claude, .codex, .cursor:
        // 其他 provider: 仅 tmux
        return session.isInTmux && session.tty != nil
    }
}
```

### 3. sendToSession 双路径

```swift
// ChatView.swift
private func sendToSession(_ text: String) async {
    switch session.provider {
    case .opencode:
        await sendToOpenCode(text)
    case .claude, .codex, .cursor:
        await sendToTmux(text)
    }
}

private func sendToOpenCode(_ text: String) async {
    // 优先 tmux（低延迟）
    if session.isInTmux, let tty = session.tty,
       let target = await findTmuxTarget(tty: tty) {
        _ = await ToolApprovalHandler.shared.sendMessage(text, to: target)
        return
    }
    
    // fallback: server HTTP API
    guard let port = session.serverPort else { return }
    await sendViaServerAPI(text: text, port: port)
}

private func sendViaServerAPI(text: String, port: Int) async {
    let url = URL(string: "http://127.0.0.1:\(port)/session/\(session.sessionId)/message")!
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.addValue("application/json", forHTTPHeaderField: "Content-Type")
    
    let body: [String: Any] = [
        "parts": [["type": "text", "text": text]]
    ]
    request.httpBody = try? JSONSerialization.data(withJSONObject: body)
    
    _ = try? await URLSession.shared.data(for: request)
}

private func sendToTmux(_ text: String) async {
    guard session.isInTmux, let tty = session.tty else { return }
    if let target = await findTmuxTarget(tty: tty) {
        _ = await ToolApprovalHandler.shared.sendMessage(text, to: target)
    }
}
```

### 4. UI 状态提示

```swift
// ChatView.swift
private var chatInputPlaceholder: String {
    switch session.provider {
    case .opencode:
        if session.isInTmux {
            return "Send to tmux..."
        } else if session.serverPort != nil {
            return "Send to OpenCode..."
        } else {
            return "No connection"
        }
    case .claude, .codex, .cursor:
        return session.isInTmux ? "Type a message..." : "No tmux session"
    }
}
```

---

## 实现步骤

### Step 1: SessionState 添加 serverPort

**文件**: `Nook/Models/SessionState.swift`

- 添加 `var serverPort: Int?` 属性
- 更新 `init` 签名

### Step 2: Plugin 发送 server 端口

**文件**: `Nook/Resources/opencode-plugin/index.js`

- Plugin 启动时获取 server 端口
- 通过 `/tmp/nook.sock` 发送 `serverPort` 事件

**文件**: `Nook/Services/Hooks/OpencodeHookAdapter.swift`

- 处理 `serverPort` 事件，更新 SessionState

### Step 3: ChatView 支持双路径

**文件**: `Nook/UI/Views/ChatView.swift`

- 更新 `canSendMessages` 逻辑
- 添加 `sendToOpenCode` 和 `sendViaServerAPI`
- 更新 `chatInputPlaceholder`

### Step 4: Server 端口探测（可选 fallback）

**文件**: `Nook/Services/Hooks/OpencodeCommandSocket.swift`

- 添加 `probeServerPort()` 方法
- 尝试连接 `http://127.0.0.1:4096/global/health`
- 成功则设置 `serverPort`

---

## 边界条件

| 场景 | 处理 |
|------|------|
| Server 未启动 | `serverPort = nil`，输入框禁用 |
| Server 端口变化 | Plugin 重新发送端口事件 |
| 网络错误 | 静默失败，用户可重试 |
| 权限请求 | 仍通过 `/tmp/nook-command.sock` 处理 |
| 消息确认 | 依赖 plugin 转发的事件，非 API 响应 |

---

## 测试计划

1. **tmux 模式**: 验证原有 tmux send-keys 仍正常工作
2. **Desktop 模式**: 验证 server API 发送消息成功
3. **Fallback**: 验证 tmux 不可用时自动切换到 server API
4. **错误处理**: 验证 server 不可用时输入框禁用
5. **Provider 隔离**: 验证 Claude/Codex 不受影响
