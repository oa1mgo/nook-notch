# OpenCode Server API 输入 — 实现计划

> 日期: 2026-08-09
> Spec: [2026-08-09-opencode-server-api-input.md](../specs/2026-08-09-opencode-server-api-input.md)

## 概述

为 OpenCode provider 添加 Server HTTP API 输入路径，使 Desktop 模式下 ChatView 输入框能正常工作。

## 改动范围

~150 行，4 个文件。

---

## Step 1: SessionState 添加 serverPort

**文件**: `Nook/Models/SessionState.swift`

**改动**:
- 添加 `var serverPort: Int?` 属性（在 `isInTmux` 之后）
- 更新 `init` 签名，添加 `serverPort: Int? = nil` 参数
- 在 `init` 中赋值 `self.serverPort = serverPort`

**验证**: 编译通过

---

## Step 2: Plugin 发送 server 端口

### 2a. Plugin 获取并发送端口

**文件**: `Nook/Resources/opencode-plugin/index.js`

**改动**:
- 在 `server(input)` 函数中，从 `input` 获取 server 端口信息
- 通过 `send()` 发送 `serverPort` 事件：

```javascript
// 在 server(input) 函数开头
send({
  type: "serverPort",
  port: input?.port || 4096  // 默认端口
});
```

**注意**: 需要确认 `input` 对象是否包含端口信息。如果不包含，使用默认端口 4096。

### 2b. Adapter 处理端口事件

**文件**: `Nook/Services/Hooks/OpencodeHookAdapter.swift`

**改动**:
- 在 `adapt(_:)` 方法中，添加 `case "serverPort"` 处理：
- 解析 `port` 字段
- 返回新的事件类型 `serverPortReceived(port: Int)`

**文件**: `Nook/Models/SessionEvent.swift`

**改动**:
- 添加 `case opencodeServerPortReceived(sessionId: String, port: Int)`

### 2c. SessionStore 处理端口事件

**文件**: `Nook/Services/State/SessionStore.swift`

**改动**:
- 在 `process(_:)` 中处理 `.opencodeServerPortReceived`
- 更新对应 session 的 `serverPort`

---

## Step 3: ChatView 支持双路径

**文件**: `Nook/UI/Views/ChatView.swift`

### 3a. 更新 canSendMessages

```swift
private var canSendMessages: Bool {
    switch session.provider {
    case .opencode:
        return (session.isInTmux && session.tty != nil) || session.serverPort != nil
    case .claude, .codex, .cursor:
        return session.isInTmux && session.tty != nil
    }
}
```

### 3b. 更新 sendToSession

```swift
private func sendToSession(_ text: String) async {
    switch session.provider {
    case .opencode:
        await sendToOpenCode(text)
    case .claude, .codex, .cursor:
        await sendToTmux(text)
    }
}
```

### 3c. 添加 sendToOpenCode

```swift
private func sendToOpenCode(_ text: String) async {
    // 优先 tmux
    if session.isInTmux, let tty = session.tty,
       let target = await findTmuxTarget(tty: tty) {
        _ = await ToolApprovalHandler.shared.sendMessage(text, to: target)
        return
    }
    
    // fallback: server API
    guard let port = session.serverPort else { return }
    await sendViaServerAPI(text: text, port: port)
}
```

### 3d. 添加 sendViaServerAPI

```swift
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
```

### 3e. 重命名 sendToTmux

将现有的 `sendToSession` 重命名为 `sendToTmux`，保持逻辑不变。

### 3f. 更新 chatInputPlaceholder

```swift
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

## Step 4: 编译验证

**命令**: `xcodebuild -project Nook.xcodeproj -scheme Nook build`

**验证点**:
- 编译无错误
- 无新增警告

---

## 文件清单

| 文件 | 改动类型 |
|------|----------|
| `Nook/Models/SessionState.swift` | 修改 |
| `Nook/Resources/opencode-plugin/index.js` | 修改 |
| `Nook/Services/Hooks/OpencodeHookAdapter.swift` | 修改 |
| `Nook/Models/SessionEvent.swift` | 修改 |
| `Nook/Services/State/SessionStore.swift` | 修改 |
| `Nook/UI/Views/ChatView.swift` | 修改 |

---

## 风险点

1. **Plugin 端口信息**: `input` 对象可能不包含端口，需要确认
2. **Server 响应格式**: 需要确认 API 响应是否包含消息 ID
3. **异步确认**: Server API 是异步的，消息确认仍依赖 plugin 事件

---

## 执行顺序

1. Step 1 → 编译验证
2. Step 2a → Step 2b → Step 2c → 编译验证
3. Step 3a → Step 3b → Step 3c → Step 3d → Step 3e → Step 3f → 编译验证
4. 完整测试
