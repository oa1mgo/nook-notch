# Question Tool Notch Prompt — 实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 实现 AskUserQuestion 在 Nook notch 中的自动展开提示 + 点选回答功能，Phase 1 仅 OpenCode provider 真实实现，Claude/Codex/Cursor Phase 2 再补。

**Architecture:** `QuestionReplyProvider` 协议抽象回复通道（Phase 1: OpenCode plugin socket `question.reply` + `client.questions.reply()`，Claude/Codex/Cursor 走 TerminalFallback 占位）。UI 层：closed-state 三段式 chip（左问号 + 中信息 + 右音乐） + 展开态专用 `QuestionPanelView`（仿 permission 按钮风格但全新面板）。

**Tech Stack:** Swift (Nook App) + XCTest (NookTests target) + JavaScript (opencode plugin)

**Spec:** [`docs/specs/2026-09-02-question-tool-notch-prompt-design.md`](../specs/2026-09-02-question-tool-notch-prompt-design.md)

---

## 文件总览

### 新建文件（8 个）

| 文件 | 职责 |
|---|---|
| `Nook/Services/Question/QuestionReplyProvider.swift` | 协议 + `QuestionReplyError` |
| `Nook/Services/Question/QuestionReplyProviderRegistry.swift` | 注册中心 |
| `Nook/Services/Question/OpencodeQuestionReplyProvider.swift` | OpenCode 真实实现 |
| `Nook/Services/Question/TerminalFallbackProvider.swift` | Phase 1 占位 |
| `Nook/UI/Views/QuestionPanelView.swift` | 展开态 Question 面板 |
| `Nook/UI/Components/CompactQuestionActivityView.swift` | closed-state 三段式 chip |
| `Nook/UI/Components/TerminalFocusHelper.swift` | 从 ChatView 抽出的 tryFocusTerminal |
| `NookTests/QuestionReplyProviderTests.swift` | 协议 + Registry + Provider 单测 |

### 修改文件（~10 个）

| 文件 | 改动概要 |
|---|---|
| `Nook/Core/NotchViewModel.swift` | `NotchContentType` 加 `.question`；`openedSize` 加 `.question` case；新增 auto-expand helper |
| `Nook/UI/Views/NotchView.swift` | 主内容 switch 加 `.question`；`headerRow` 加 `showCompactQuestionChip` 优先级 |
| `Nook/Models/SessionEvent.swift` | `opencodeWaitingForUserInput` 加 `requestId: String?` |
| `Nook/Models/ToolResultData.swift` | 新增 `AskUserQuestionContext`、`PendingQuestion` |
| `Nook/Models/SessionState.swift` | 新增 `pendingQuestionContext: AskUserQuestionContext?` |
| `Nook/Services/State/SessionStore.swift` | 提取 `handleWaitingForUserInput(sessionId:)` helper；调 `notchOpen` + `pushTo(.question)` |
| `Nook/Services/Hooks/OpencodeHookAdapter.swift` | `handleQuestionAsked` 提取 `event.id` 作为 requestId |
| `Nook/UI/Views/ChatView.swift` | `tryFocusTerminal` 逻辑迁移到 `TerminalFocusHelper`，自身调用 `TerminalFocusHelper` |
| `Nook/Resources/opencode-plugin/index.js` | `handleCommand` 加 `question.reply` 分支 |
| `Nook/Resources/opencode-plugin/package.json` | 版本 bump |

---

## Task 1: QuestionReplyProvider 协议 + QuestionReplyError

**Files:**
- Create: `Nook/Services/Question/QuestionReplyProvider.swift`

- [ ] **Step 1: 创建目录 + 协议文件**

```swift
// Nook/Services/Question/QuestionReplyProvider.swift

import Foundation

enum QuestionReplyError: LocalizedError, Equatable {
    case missingRequestId
    case unsupportedProvider
    case transportError(String)

    var errorDescription: String? {
        switch self {
        case .missingRequestId:
            return "No request ID available to reply"
        case .unsupportedProvider:
            return "Provider does not support inline answer (use Terminal)"
        case .transportError(let msg):
            return "Transport error: \(msg)"
        }
    }
}

protocol QuestionReplyProvider {
    var provider: SessionProvider { get }
    var supportsInlineAnswer: Bool { get }

    func sendAnswer(
        sessionId: String,
        requestId: String?,
        questions: [QuestionItem],
        answers: [String]
    ) async throws
}
```

- [ ] **Step 2: 验证编译**

```bash
cd /Users/wuruofan/mine/rfw/nook && xcodebuild build -project Nook.xcodeproj -scheme Nook -destination 'platform=macOS' -quiet 2>&1 | tail -5
```

- [ ] **Step 3: Commit**

```bash
git add Nook/Services/Question/QuestionReplyProvider.swift
git commit -m "feat(question): add QuestionReplyProvider protocol and QuestionReplyError"
```

---

## Task 2: AskUserQuestionContext + PendingQuestion 模型

**Files:**
- Modify: `Nook/Models/ToolResultData.swift`

- [ ] **Step 1: 在 ToolResultData.swift 末尾添加新类型**

在文件末尾的 `// MARK: - AskUserQuestion` 区域，新增：

```swift
struct AskUserQuestionContext: Equatable, Sendable {
    let sessionId: String
    let toolUseId: String
    let questions: [QuestionItem]
    let requestId: String?
    let provider: SessionProvider
}

struct PendingQuestion: Identifiable {
    let id: String
    let questionText: String
    let header: String?
    let options: [QuestionOption]
}
```

- [ ] **Step 2: 在 SessionState.swift 添加 pendingQuestionContext 字段**

打开 `Nook/Models/SessionState.swift`，在 struct body 里加：

```swift
var pendingQuestionContext: AskUserQuestionContext?
```

- [ ] **Step 3: 编译验证**

```bash
cd /Users/wuruofan/mine/rfw/nook && xcodebuild build -project Nook.xcodeproj -scheme Nook -destination 'platform=macOS' -quiet 2>&1 | tail -5
```

- [ ] **Step 4: Commit**

```bash
git add Nook/Models/ToolResultData.swift Nook/Models/SessionState.swift
git commit -m "feat(question): add AskUserQuestionContext + PendingQuestion models"
```

---

## Task 3: OpencodeSessionEvent 加 requestId

**Files:**
- Modify: `Nook/Services/Hooks/OpencodeHookModels.swift`

- [ ] **Step 1: 打开文件找到 `opencodeWaitingForUserInput` case**

搜索 `case opencodeWaitingForUserInput`，加 requestId 参数：

```swift
// 旧:
case opencodeWaitingForUserInput(sessionId: String, cwd: String, toolUseId: String)
// 新:
case opencodeWaitingForUserInput(sessionId: String, cwd: String, toolUseId: String, requestId: String?)
```

- [ ] **Step 2: 编译验证**

```bash
cd /Users/wuruofan/mine/rfw/nook && xcodebuild build -project Nook.xcodeproj -scheme Nook -destination 'platform=macOS' -quiet 2>&1 | tail -5
```

- [ ] **Step 3: Commit**

```bash
git add Nook/Services/Hooks/OpencodeHookModels.swift
git commit -m "feat(question): add requestId to OpencodeSessionEvent.opencodeWaitingForUserInput"
```

---

## Task 4: QuestionReplyProviderRegistry

**Files:**
- Create: `Nook/Services/Question/QuestionReplyProviderRegistry.swift`

- [ ] **Step 1: 创建 Registry 文件**

```swift
// Nook/Services/Question/QuestionReplyProviderRegistry.swift

import Foundation

@MainActor
final class QuestionReplyProviderRegistry {
    static let shared = QuestionReplyProviderRegistry()
    private var providers: [SessionProvider: QuestionReplyProvider] = [:]

    func register(_ provider: QuestionReplyProvider) {
        providers[provider.provider] = provider
    }

    func provider(for session: SessionState) throws -> QuestionReplyProvider {
        guard let p = providers[session.provider] else {
            throw QuestionReplyError.unsupportedProvider
        }
        return p
    }
}
```

- [ ] **Step 2: 编译验证**

```bash
cd /Users/wuruofan/mine/rfw/nook && xcodebuild build -project Nook.xcodeproj -scheme Nook -destination 'platform=macOS' -quiet 2>&1 | tail -5
```

- [ ] **Step 3: Commit**

```bash
git add Nook/Services/Question/QuestionReplyProviderRegistry.swift
git commit -m "feat(question): add QuestionReplyProviderRegistry"
```

---

## Task 5: TerminalFocusHelper 抽取

**Files:**
- Create: `Nook/UI/Components/TerminalFocusHelper.swift`
- Modify: `Nook/UI/Views/ChatView.swift`

- [ ] **Step 1: 创建 TerminalFocusHelper.swift**

**原样复制** `ChatView.tryFocusTerminal()` (lines 584-632) + `focusTerminalApp(forChildPid:)` (lines 637-660) 的逻辑，只改签名：`session: SessionState` 作为入参（不依赖 `viewModel`）。三级回退全部保留：Yabai → process tree → bundle ID。

```swift
// Nook/UI/Components/TerminalFocusHelper.swift

import AppKit
import Foundation

enum TerminalFocusHelper {
    /// 原样复制 ChatView.tryFocusTerminal (lines 584-632) + focusTerminalApp (lines 637-660)。
    /// 不依赖 viewModel，只用 session.pid / session.cwd / session.isInTmux。
    /// 返回 true = 成功激活终端窗口，false = 所有路径失败。
    @MainActor
    static func tryFocusTerminal(for session: SessionState) async -> Bool {
        // tmux path (Claude's default)
        if session.isInTmux, let pid = session.pid {
            if await YabaiController.shared.focusWindow(forClaudePid: pid) {
                DebugLog.shared.write("[focus] tmux focusWindow(forClaudePid) succeeded")
                return true
            }
            DebugLog.shared.write("[focus] tmux focusWindow(forClaudePid) failed, trying forWorkingDirectory")
            if await YabaiController.shared.focusWindow(forWorkingDirectory: session.cwd) {
                DebugLog.shared.write("[focus] tmux focusWindow(forWorkingDirectory) succeeded")
                return true
            }
            DebugLog.shared.write("[focus] tmux path failed, falling through to non-tmux fallback")
        }
        // Non-tmux fallback (e.g. opencode running directly in Ghostty)
        if let pid = session.pid {
            if await focusTerminalApp(forChildPid: Int(pid)) {
                DebugLog.shared.write("[focus] non-tmux focusTerminalApp succeeded")
                return true
            }
            DebugLog.shared.write("[focus] non-tmux focusTerminalApp failed: could not find terminal app for pid=\(pid)")
            let terminalBundleIds = ["com.mitchellh.ghostty", "com.googlecode.iterm2", "com.apple.Terminal"]
            for bundleId in terminalBundleIds {
                if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first {
                    let ok = app.activate()
                    DebugLog.shared.write("[focus] last-resort activate bundleId=\(bundleId) success=\(ok)")
                    if ok { return true }
                }
            }
            DebugLog.shared.write("[focus] all focus methods failed")
        } else {
            DebugLog.shared.write("[focus] session.pid is nil, cannot focus terminal")
        }
        return false
    }

    /// Walk up the process tree from childPid until we hit a known terminal app.
    /// 原样复制 ChatView.focusTerminalApp(forChildPid:) (lines 637-660)。
    private static func focusTerminalApp(forChildPid childPid: Int) async -> Bool {
        let tree = ProcessTreeBuilder.shared.buildTree()
        guard let terminalPid = ProcessTreeBuilder.shared.findTerminalPid(
            forChildPid: childPid,
            tree: tree
        ) else {
            return false
        }
        guard let app = NSRunningApplication(processIdentifier: pid_t(terminalPid)) else {
            return false
        }
        return app.activate()
    }
}
```

**注意**：`ProcessTreeBuilder.shared.buildTree()` 和 `findTerminalPid(forChildPid:tree:)` 的确切签名需对照 `ProcessTreeBuilder.swift` 调整。plan 里保留了原始方法调用，如果签名不同以源码为准。

- [ ] **Step 2: 修改 ChatView.swift — tryFocusTerminal 改为调 TerminalFocusHelper**

找到 `ChatView.swift` 里的 `tryFocusTerminal()` 方法 (lines 584-632)，替换为：

```swift
private func tryFocusTerminal() async -> Bool {
    guard let session = viewModel.currentChatSession else { return false }
    let ok = await TerminalFocusHelper.tryFocusTerminal(for: session)
    if !ok {
        focusErrorMessage = "Failed to focus terminal"
    }
    return ok
}
```

同样，`focusTerminalApp(forChildPid:)` (lines 637-660) 可以删掉（已迁移到 helper），或者保留为 wrapper 调 helper。推荐删除重复代码。

- [ ] **Step 3: 编译验证**

```bash
cd /Users/wuruofan/mine/rfw/nook && xcodebuild build -project Nook.xcodeproj -scheme Nook -destination 'platform=macOS' -quiet 2>&1 | tail -5
```

- [ ] **Step 4: Commit**

```bash
git add Nook/UI/Components/TerminalFocusHelper.swift Nook/UI/Views/ChatView.swift
git commit -m "refactor(terminal): extract tryFocusTerminal to TerminalFocusHelper"
```

---

## Task 6: TerminalFallbackProvider（Phase 1 占位）

**Files:**
- Create: `Nook/Services/Question/TerminalFallbackProvider.swift`

- [ ] **Step 1: 创建文件**

```swift
// Nook/Services/Question/TerminalFallbackProvider.swift

import Foundation

struct TerminalFallbackProvider: QuestionReplyProvider {
    let provider: SessionProvider
    let supportsInlineAnswer: Bool = false

    func sendAnswer(
        sessionId: String,
        requestId: String?,
        questions: [QuestionItem],
        answers: [String]
    ) async throws {
        throw QuestionReplyError.unsupportedProvider
    }

    @MainActor
    func focusTerminalForAnswer(session: SessionState) {
        let vm = NotchViewModel.shared
        Task {
            let result = await TerminalFocusHelper.tryFocusTerminal(
                for: session,
                viewModel: vm
            )
            if result.success {
                vm.notchClose(restorePreviousApp: false)
            } else {
                // 不关闭 notch，让用户看到错误
                DebugLog.shared.write(
                    "[question] focusTerminal failed: \(result.error ?? "unknown")"
                )
            }
        }
    }
}
```

- [ ] **Step 2: 编译验证**

```bash
cd /Users/wuruofan/mine/rfw/nook && xcodebuild build -project Nook.xcodeproj -scheme Nook -destination 'platform=macOS' -quiet 2>&1 | tail -5
```

- [ ] **Step 3: Commit**

```bash
git add Nook/Services/Question/TerminalFallbackProvider.swift
git commit -m "feat(question): add TerminalFallbackProvider for Claude/Codex/Cursor"
```

---

## Task 7: OpencodeQuestionReplyProvider

**Files:**
- Create: `Nook/Services/Question/OpencodeQuestionReplyProvider.swift`

- [ ] **Step 1: 创建文件**

`OpencodeCommandSocket.sendCommand` 是同步、fire-and-forget、非 async 非 throws（`OpencodeCommandSocket.swift:36`）。`sendAnswer` 只对前置条件（缺 requestId）抛错；transport 视为乐观发送。notch 关闭由 `QuestionPanelView.onChange(sessionMonitor.changes)` 检测 `phase ≠ .waitingForInput` 自动触发（spec §2 已写，这是 SSOT）。

```swift
// Nook/Services/Question/OpencodeQuestionReplyProvider.swift

import Foundation

final class OpencodeQuestionReplyProvider: QuestionReplyProvider {
    let provider: SessionProvider = .opencode
    let supportsInlineAnswer: Bool = true

    func sendAnswer(
        sessionId: String,
        requestId: String?,
        questions: [QuestionItem],
        answers: [String]
    ) async throws {
        guard let requestId else {
            throw QuestionReplyError.missingRequestId
        }

        // OpencodeCommandSocket.sendCommand 是同步 fire-and-forget，
        // 不是 async/throws。仅对前置条件抛错；transport 乐观发送。
        // notch 关闭由 panel onChange(phase ≠ .waitingForInput) 驱动。
        let wireAnswers: [[String]] = answers.map { [$0] }
        let payload: [String: Any] = [
            "cmd": "question.reply",
            "sessionId": sessionId,
            "requestId": requestId,
            "answers": wireAnswers
        ]

        let pid = await MainActor.run {
            SessionStore.shared.sessions[sessionId]?.pid
        }
        OpencodeCommandSocket.shared.sendCommand(payload, pid: pid)
        // fire-and-forget: 不 await，不 throw
    }
}
```

同样，`QuestionPanelView.sendAnswers` 的 catch/errorMessage 分支也要简化（只有 `missingRequestId` 会 throw，transport 不会）：

```swift
// QuestionPanelView.sendAnswers 里：
private func sendAnswers(_ answers: [String]) {
    isSending = true
    Task {
        do {
            try await replyProvider.sendAnswer(
                sessionId: session.id,
                requestId: session.pendingQuestionContext?.requestId,
                questions: session.pendingQuestionContext?.questions ?? [],
                answers: answers
            )
            // sendAnswer 是 fire-and-forget，成功不 throw。
            // notch 关闭由 .onChange(phase ≠ .waitingForInput) 驱动。
        } catch {
            await MainActor.run {
                errorMessage = error.localizedDescription
                isSending = false
            }
        }
    }
}
```

- [ ] **Step 2: 编译验证**

```bash
cd /Users/wuruofan/mine/rfw/nook && xcodebuild build -project Nook.xcodeproj -scheme Nook -destination 'platform=macOS' -quiet 2>&1 | tail -5
```

- [ ] **Step 3: Commit**

```bash
git add Nook/Services/Question/OpencodeQuestionReplyProvider.swift
git commit -m "feat(question): add OpencodeQuestionReplyProvider (question.reply)"
```

---

## Task 8: ProviderRegistry 单测

**Files:**
- Create: `NookTests/QuestionReplyProviderTests.swift`

- [ ] **Step 1: 创建测试文件**

```swift
// NookTests/QuestionReplyProviderTests.swift

import XCTest
@testable import Nook

final class QuestionReplyProviderTests: XCTestCase {

    func testRegistryReturnsRegisteredProvider() throws {
        let reg = QuestionReplyProviderRegistry()
        let fallback = TerminalFallbackProvider(provider: .claude)
        reg.register(fallback)

        let session = SessionState(
            sessionId: "test", cwd: "/tmp", phase: .idle, provider: .claude
        )
        let result = reg.provider(for: session)
        XCTAssertTrue(result.supportsInlineAnswer == false)
        XCTAssertEqual(result.provider, .claude)
    }

    func testRegistryThrowsOnMissing() throws {
        let reg = QuestionReplyProviderRegistry()
        let session = SessionState(
            sessionId: "test", cwd: "/tmp", phase: .idle, provider: .opencode
        )

        XCTAssertThrowsError(try reg.provider(for: session)) { error in
            guard let qErr = error as? QuestionReplyError else {
                return XCTFail("Expected QuestionReplyError, got \(error)")
            }
            XCTAssertEqual(qErr, .unsupportedProvider)
        }
    }

    func testTerminalFallbackDoesNotSupportInline() throws {
        let fallback = TerminalFallbackProvider(provider: .codex)
        XCTAssertFalse(fallback.supportsInlineAnswer)
    }

    func testOpencodeSupportsInline() throws {
        let provider = OpencodeQuestionReplyProvider()
        XCTAssertTrue(provider.supportsInlineAnswer)
        XCTAssertEqual(provider.provider, .opencode)
    }
}
```

注意：`provider(for:)` 当前用 `fatalError`，测试里 `XCTAssertThrowsError` 可能不会完美捕获 fatal。如果编译时 `fatalError` 导致测试 crash，改用 `XCTExpectCrash` 或改 Registry 实现为 `throws` 返回。

- [ ] **Step 2: 运行测试**

```bash
cd /Users/wuruofan/mine/rfw/nook && xcodebuild test -project Nook.xcodeproj -scheme NookTests -destination 'platform=macOS' -only-testing NookTests/QuestionReplyProviderTests 2>&1 | tail -10
```

- [ ] **Step 3: 通过后 Commit**

```bash
git add NookTests/QuestionReplyProviderTests.swift
git commit -m "test(question): add QuestionReplyProviderRegistry + provider tests"
```

---

## Task 9: OpencodeHookAdapter 提取 requestID

**Files:**
- Modify: `Nook/Services/Hooks/OpencodeHookAdapter.swift`

- [ ] **Step 1: 打开 `handleQuestionAsked` 方法**

找到 `Nook/Services/Hooks/OpencodeHookAdapter.swift` 里 `handleQuestionAsked` 方法（~line 687-747）。在 emit `.waitingForUserInput` 的地方，把 requestId 传进去：

```swift
// 旧:
return [preToolEvent, .waitingForUserInput(sessionId: sessionId, cwd: cwd)]
// 新:
return [preToolEvent, .waitingForUserInput(sessionId: sessionId, cwd: cwd, toolUseId: toolCallId, requestId: requestId)]
```

在方法开头提取 requestId：

```swift
let requestId = envelope.id   // question.asked 事件的顶层 id（que_xxx）
```

- [ ] **Step 2: 同样修改 defensive fallback 路径（~line 1372-1391）**

找到 `handlePartUpdated` 里 `toolName.lowercased() == "question"` 的 defensive fallback，也加上 requestId：

```swift
// 旧:
return [preToolEvent, .waitingForUserInput(sessionId: sessionId, cwd: cwd)]
// 新:
return [preToolEvent, .waitingForUserInput(sessionId: sessionId, cwd: cwd, toolUseId: envelope.properties?.toolCallID ?? "", requestId: envelope.id)]
```

- [ ] **Step 3: 在 SessionStore 处理路径补 requestId**

找到 `SessionStore.processOpencodeWaitingForUserInput` 方法，把 requestId 从 event 里取出来存到 `AskUserQuestionContext`：

```swift
// 在 processOpencodeWaitingForUserInput 里:
let ctx = AskUserQuestionContext(
    sessionId: sessionId,
    toolUseId: toolUseId,
    questions: [],       // questions 会在 JSONL 回放时填充
    requestId: requestId,    // [NEW]
    provider: .opencode
)
session.pendingQuestionContext = ctx
```

- [ ] **Step 4: 编译验证**

```bash
cd /Users/wuruofan/mine/rfw/nook && xcodebuild build -project Nook.xcodeproj -scheme Nook -destination 'platform=macOS' -quiet 2>&1 | tail -5
```

- [ ] **Step 5: Commit**

```bash
git add Nook/Services/Hooks/OpencodeHookAdapter.swift Nook/Services/State/SessionStore.swift
git commit -m "feat(question): extract requestId from question.asked event and store in session"
```

---

## Task 10: SessionStore.handleWaitingForUserInput helper

**Files:**
- Modify: `Nook/Services/State/SessionStore.swift`

- [ ] **Step 1: 新增 helper 方法**

在 `SessionStore` 的 `// MARK: - Notch Auto-Expand` 区域（如果没有，新建）加：

```swift
/// 当 session 进入 .waitingForInput 时，自动展开 notch 并 pushTo(.question)。
/// 跨 session 多 question 时用 lastActivity 排序，取最新。
@MainActor
private func handleWaitingForUserInput(sessionId: String) {
    guard let session = sessions[sessionId] else { return }

    session.lastActivity = Date()

    let vm = NotchViewModel.shared
    // 如果 notch 正在显示另一个 waiting 面板（chat 在等 permission），不 yank
    if vm.status == .opened, case .chat(let s) = vm.contentType,
       s.phase.isWaitingForInput || s.phase.isWaitingForTerminalApproval {
        return
    }

    vm.notchOpen(reason: .notification)
    vm.pushTo(.question(session))
}
```

- [ ] **Step 2: 在所有 .waitingForInput 入口调用 helper**

**Phase 1 范围说明**：`SessionStore.swift:1010` 是当前唯一设置 `session.phase = .waitingForInput` 的地方（`processOpencodeWaitingForUserInput`）。`processClaudeWaitingForUserInput` 不存在 — Claude 的 question 走的是 `.waitingForTerminalApproval` 或直接跳终端，Phase 1 不触发 auto-expand。所以 Phase 1 只需在 `processOpencodeWaitingForUserInput` 里调 helper。

在 `processOpencodeWaitingForUserInput(sessionId:cwd:toolUseId:requestId:)` 里，设完 `session.phase` 后调：

```swift
await handleWaitingForUserInput(sessionId: sessionId)
```

如果 Phase 2 需要 Claude auto-expand，在 `processHookEvent` 里走到 `.waitingForInput` 的路径补调即可。

- [ ] **Step 3: 编译验证**

```bash
cd /Users/wuruofan/mine/rfw/nook && xcodebuild build -project Nook.xcodeproj -scheme Nook -destination 'platform=macOS' -quiet 2>&1 | tail -5
```

- [ ] **Step 4: Commit**

```bash
git add Nook/Services/State/SessionStore.swift
git commit -m "feat(question): add handleWaitingForUserInput auto-expand helper"
```

---

## Task 11: opencode plugin question.reply handler

**Files:**
- Modify: `Nook/Resources/opencode-plugin/index.js`
- Modify: `Nook/Resources/opencode-plugin/package.json`

- [ ] **Step 1: 打开 index.js，找到 handleCommand 函数**

在 `handleCommand` 的 switch/case 里加 `question.reply` 分支：

```js
async function handleCommand(cmd) {
    switch (cmd.cmd) {
        case "permission.reply":
            // 现有逻辑 (lines ~86-120)
            break;
        case "question.reply":          // [NEW]
            // 镜像 permission.reply 模式（index.js:95-114），
            // 使用 client._client (HeyApi Client) 的 post 方法，
            // 而不是 SDK 的 client.questions.reply（后者未验证在当前版本可用）。
            if (!cmd.requestId || !cmd.sessionId) {
                logDebug('question.reply missing requestId or sessionId');
                return;
            }
            const answers = cmd.answers;  // string[][] 协议形状
            try {
                const heyApiClient = input?.client?._client;
                if (!heyApiClient) {
                    logDebug('question.reply: heyApiClient not available, cannot send');
                    return;
                }
                await heyApiClient.post({
                    url: "/api/session/{sessionID}/question/{requestID}/reply",
                    path: { sessionID: cmd.sessionId, requestID: cmd.requestId },
                    body: { answers }
                });
                logDebug(`question.reply sent: requestId=${cmd.requestId} answers=${JSON.stringify(answers)}`);
            } catch (err) {
                logDebug(`question.reply failed: ${err.message}`);
            }
            break;
    }
}
```

- [ ] **Step 2: 在 package.json bump 版本**

```json
{
  "name": "nook-opencode-plugin",
  "version": "1.3.0"
}
```

- [ ] **Step 3: 重新构建 plugin**

```bash
cd /Users/wuruofan/mine/rfw/nook/Nook/Resources/opencode-plugin && npm install 2>&1 | tail -3
```

- [ ] **Step 4: 实测 heyApiClient.post 路径**

在 opencode 实例里触发一个 AskUserQuestion，看 `/tmp/nook-plugin-debug.log`：
- 有 `question.reply sent` → 通了
- 有 `heyApiClient not available` → 输入参数路径不对，需调试 `input?.client?._client`
- 有 `question.reply failed` → URL/path/body 格式需对照 opencode 源码调整

如果 `client._client.post` 走不通，回退到 `client.questions.reply()`（SDK 直接调用），此时加注释说明版本差异。

- [ ] **Step 5: Commit**

```bash
git add Nook/Resources/opencode-plugin/index.js Nook/Resources/opencode-plugin/package.json
git commit -m "feat(opencode-plugin): add question.reply handler (mirror permission pattern) + bump version"
```

---

## Task 12: NotchContentType.question + openedSize

**Files:**
- Modify: `Nook/Core/NotchViewModel.swift`

- [ ] **Step 1: NotchContentType 加 case**

在 `NotchContentType` enum 里加：

```swift
case question(SessionState)
```

- [ ] **Step 2: openedSize 加 .question case**

在 `NotchViewModel.openedSize` 的 switch 里，加 `.question` case（高度用 `panelHeightForPage`，宽度 `min(screenRect.width * 0.4, 480)` — 与 menu/agents/shortcuts 相同）：

```swift
case .question:
    // 仿 .agents 模式：固定 content 高度 + header + 12pt trailing gap。
    // Question 面板内容固定（1 question 标题 + 3-4 options + 输入框 ≈ 340pt），
    // 不需要动态测量。与 .menu/.agents 用同一套 maxHeight 公式。
            let headerHeight = settingsPageHeaderHeight(for: geometry)
            let contentHeight: CGFloat = 340  // question title + options + input
            let raw = contentHeight + headerHeight + 12
            let maxHeight = max(0, geometry.windowHeight - panelBottomMargin)
            return CGSize(
                width: min(screenRect.width * 0.4, 480),
                height: min(raw, maxHeight)
            )
```

- [ ] **Step 3: 编译验证**

```bash
cd /Users/wuruofan/mine/rfw/nook && xcodebuild build -project Nook.xcodeproj -scheme Nook -destination 'platform=macOS' -quiet 2>&1 | tail -5
```

- [ ] **Step 4: Commit**

```bash
git add Nook/Core/NotchViewModel.swift
git commit -m "feat(question): add .question case to NotchContentType + openedSize"
```

---

## Task 13: CompactQuestionActivityView（closed-state 三段式 chip）

**Files:**
- Create: `Nook/UI/Components/CompactQuestionActivityView.swift`

- [ ] **Step 1: 创建组件**

```swift
// Nook/UI/Components/CompactQuestionActivityView.swift

import SwiftUI

struct CompactQuestionActivityView: View {
    @ObservedObject var sessionMonitor: SessionMonitor
    @ObservedObject var musicManager: MusicManager
    let onTap: () -> Void

    private var primarySession: SessionState? {
        sessionMonitor.instances
            .filter { $0.phase.isWaitingForInput }
            .sorted { $0.lastActivity > $1.lastActivity }
            .first
    }

    private var pendingQuestions: [PendingQuestion] {
        primarySession?.pendingQuestionContext?.questions.map {
            PendingQuestion(
                id: $0.question,
                questionText: $0.question,
                header: $0.header,
                options: $0.options
            )
        } ?? []
    }

    private var providerLabel: String {
        primarySession?.provider.rawValue.uppercased() ?? ""
    }

    var body: some View {
        HStack(spacing: 12) {
            // 左：橘黄问号
            Circle()
                .fill(Color.orange)
                .frame(width: 22, height: 22)
                .overlay(
                    Text("?")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.black)
                )

            // 中：信息（被物理刘海遮挡时由 OS 处理）
            VStack(alignment: .leading, spacing: 2) {
                Text("\(providerLabel) · QUESTION")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.orange)
                Text(pendingQuestions.first?.questionText ?? "")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundColor(.white)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // 右：音乐波纹（如果有音乐在播放）
            if musicManager.isVisible {
                WaveIndicator(isPlaying: musicManager.playbackState.isPlaying)
                    .frame(width: 50, height: 16)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .onTapGesture { onTap() }
    }
}

/// 小型波纹条组件，仿 MusicCardView 波纹但简化。
struct WaveIndicator: View {
    let isPlaying: Bool
    private let barCount = 8

    var body: some View {
        HStack(spacing: 1.5) {
            ForEach(0..<barCount, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.white.opacity(0.6))
                    .frame(width: 2, height: barHeight(for: i))
            }
        }
    }

    private func barHeight(for index: Int) -> CGFloat {
        if !isPlaying { return 4 }
        let base: [CGFloat] = [6, 12, 8, 14, 5, 10, 7, 11]
        return base[index % base.count]
    }
}
```

- [ ] **Step 2: 编译验证**

```bash
cd /Users/wuruofan/mine/rfw/nook && xcodebuild build -project Nook.xcodeproj -scheme Nook -destination 'platform=macOS' -quiet 2>&1 | tail -5
```

- [ ] **Step 3: Commit**

```bash
git add Nook/UI/Components/CompactQuestionActivityView.swift
git commit -m "feat(question): add CompactQuestionActivityView (closed-state chip)"
```

---

## Task 14: NotchView headerRow 优先级 + 主内容 switch

**Files:**
- Modify: `Nook/UI/Views/NotchView.swift`

- [ ] **Step 1: headerRow 加 showCompactQuestionChip**

在 `NotchView` 的 computed properties 里加：

```swift
private var showCompactQuestionChip: Bool {
    viewModel.status != .opened &&
    sessionMonitor.instances.contains { $0.phase.isWaitingForInput }
}
```

在 `headerRow` 的 if-else 链中，**在 `showCompactMusicActivity` 之前**加：

```swift
if showCompactQuestionChip {
    CompactQuestionActivityView(
        sessionMonitor: sessionMonitor,
        musicManager: musicManager,
        onTap: {
            guard let session = sessionMonitor.instances
                .filter({ $0.phase.isWaitingForInput })
                .sorted({ $0.lastActivity > $1.lastActivity })
                .first else { return }
            viewModel.notchOpen(reason: .notification)
            viewModel.pushTo(.question(session))
        }
    )
} else if showCompactMusicActivity {
    // 现有逻辑...
```

- [ ] **Step 2: 主内容 switch 加 .question**

在 `NotchView` body 里，`switch viewModel.contentType` 分支加：

```swift
case .question(let session):
    QuestionPanelView(
        session: session,
        replyProvider: (try? QuestionReplyProviderRegistry.shared.provider(for: session))
            ?? TerminalFallbackProvider(provider: session.provider),
        onClose: { viewModel.navigateBack() }
    )
```

- [ ] **Step 3: 编译验证**

```bash
cd /Users/wuruofan/mine/rfw/nook && xcodebuild build -project Nook.xcodeproj -scheme Nook -destination 'platform=macOS' -quiet 2>&1 | tail -5
```

- [ ] **Step 4: Commit**

```bash
git add Nook/UI/Views/NotchView.swift
git commit -m "feat(question): wire headerRow priority + main content switch for .question"
```

---

## Task 15: QuestionPanelView 结构

**Files:**
- Create: `Nook/UI/Views/QuestionPanelView.swift`

- [ ] **Step 1: 创建 QuestionPanelView 文件**

先写骨架（headerBar + singleQuestionCard + multiQuestionSwiper），选项按钮和输入框在下一个 task 补：

```swift
// Nook/UI/Views/QuestionPanelView.swift

import SwiftUI

struct QuestionPanelView: View {
    let session: SessionState
    let replyProvider: QuestionReplyProvider
    let onClose: () -> Void

    @State private var pendingQuestions: [PendingQuestion] = []
    @State private var currentIndex: Int = 0
    @State private var freeText: String = ""
    @State private var isSending: Bool = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            if pendingQuestions.isEmpty {
                loadingPlaceholder
            } else if replyProvider.supportsInlineAnswer {
                if pendingQuestions.count == 1 {
                    singleQuestionCard
                } else {
                    multiQuestionSwiper
                }
            } else {
                terminalFallbackCard
            }
        }
        .onAppear { loadPendingQuestions() }
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack {
            HStack(spacing: 6) {
                Circle()
                    .fill(Color.orange)
                    .frame(width: 18, height: 18)
                    .overlay(Text("?").font(.system(size: 11, weight: .bold)).foregroundColor(.black))
                Text(session.provider.rawValue.uppercased() + " · QUESTION")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.orange)
            }
            Spacer()
            if pendingQuestions.count > 1 {
                HStack(spacing: 4) {
                    ForEach(0..<pendingQuestions.count, id: \.self) { i in
                        Circle()
                            .fill(i == currentIndex ? Color.orange : Color.white.opacity(0.18))
                            .frame(width: 8, height: 3)
                    }
                    Text("\(currentIndex + 1)/\(pendingQuestions.count)")
                        .font(.system(size: 9))
                        .foregroundColor(.white.opacity(0.5))
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    // MARK: - Single Question

    private var singleQuestionCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            // question 标题
            VStack(alignment: .leading, spacing: 3) {
                if let header = pendingQuestions.first?.header {
                    Text(header)
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundColor(.white.opacity(0.4))
                        .textCase(.uppercase)
                }
                Text(pendingQuestions.first?.questionText ?? "")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
            }

            // TODO: 选项按钮（Task 16）
            optionsList

            Divider().background(Color.white.opacity(0.08))

            // TODO: 自由输入框（Task 16）
            freeFormInput
        }
        .padding(16)
    }

    // MARK: - Multi-Question Swiper

    private var multiQuestionSwiper: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                Button { prev() } label: { Text("‹").font(.system(size: 20)) }
                    .disabled(currentIndex == 0)
                    .opacity(currentIndex == 0 ? 0.15 : 0.5)

                VStack(alignment: .leading, spacing: 12) {
                    let q = pendingQuestions[currentIndex]
                    if let header = q.header {
                        Text(header)
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundColor(.white.opacity(0.4))
                            .textCase(.uppercase)
                    }
                    Text(q.questionText)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white)

                    optionsListForQuestion(q)

                    Divider().background(Color.white.opacity(0.08))

                    freeFormInput
                }
                .padding(.horizontal, 12)

                Button { next() } label: { Text("›").font(.system(size: 20)) }
                    .disabled(currentIndex == pendingQuestions.count - 1)
                    .opacity(currentIndex == pendingQuestions.count - 1 ? 0.15 : 0.5)
            }
            .padding(.bottom, 14)
        }
    }

    // MARK: - Terminal Fallback

    private var terminalFallbackCard: some View {
        VStack(spacing: 14) {
            Text(pendingQuestions.first?.questionText ?? "Question pending")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.white)
                .multilineTextAlignment(.center)

            Button("Go to Terminal →") {
                if let fallback = replyProvider as? TerminalFallbackProvider {
                    fallback.focusTerminalForAnswer(session: session)
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
        }
        .padding(16)
    }

    // MARK: - Loading

    private var loadingPlaceholder: some View {
        VStack(spacing: 8) {
            ProgressView().tint(.white)
            Text("Loading question...")
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.5))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Helpers

    private func loadPendingQuestions() {
        pendingQuestions = session.pendingQuestionContext?.questions.map {
            PendingQuestion(id: $0.question, questionText: $0.question, header: $0.header, options: $0.options)
        } ?? []
    }

    private func prev() { if currentIndex > 0 { currentIndex -= 1 } }
    private func next() { if currentIndex < pendingQuestions.count - 1 { currentIndex += 1 } }
}
```

- [ ] **Step 2: 编译验证**

```bash
cd /Users/wuruofan/mine/rfw/nook && xcodebuild build -project Nook.xcodeproj -scheme Nook -destination 'platform=macOS' -quiet 2>&1 | tail -5
```

- [ ] **Step 3: Commit**

```bash
git add Nook/UI/Views/QuestionPanelView.swift
git commit -m "feat(question): add QuestionPanelView skeleton (header + single/multi/fallback)"
```

---

## Task 16: QuestionPanelView 选项按钮 + 自由输入框

**Files:**
- Modify: `Nook/UI/Views/QuestionPanelView.swift`

- [ ] **Step 1: 在 QuestionPanelView 里加 optionsList 和 freeFormInput**

在文件末尾（`}` 之前）加：

```swift
// MARK: - Options

private func optionsList() -> some View {
    optionsListForQuestion(pendingQuestions[currentIndex])
}

private func optionsListForQuestion(_ question: PendingQuestion) -> some View {
    VStack(spacing: 5) {
        ForEach(Array(question.options.enumerated()), id: \.offset) { idx, option in
            Button { pickOption(question: question, optionIndex: idx, label: option.label) } label: {
                HStack(spacing: 10) {
                    Text(letterLabel(for: idx))
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 22, height: 22)
                        .background(Color.white.opacity(0.12))
                        .clipShape(Circle())
                    VStack(alignment: .leading) {
                        Text(option.label)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.white)
                        if let desc = option.description, !desc.isEmpty {
                            Text(desc)
                                .font(.system(size: 10))
                                .foregroundColor(.white.opacity(0.5))
                        }
                    }
                    Spacer()
                }
                .padding(10)
                .background(Color.white.opacity(0.07))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .disabled(isSending)
        }
    }
}

// MARK: - Free-Form Input

private var freeFormInput: some View {
    HStack(spacing: 8) {
        TextField("自定义回答...", text: $freeText)
            .textFieldStyle(.plain)
            .padding(8)
            .background(Color.white.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .onSubmit { sendFreeForm() }

        Button { sendFreeForm() } label: {
            Text("Send ⏎")
                .font(.system(size: 10, weight: .semibold))
        }
        .buttonStyle(.borderedProminent)
        .tint(.orange)
        .disabled(isSending || freeText.isEmpty)
    }
}

// MARK: - Send Logic

private func pickOption(question: PendingQuestion, optionIndex: Int, label: String) {
    let allAnswers = pendingQuestions.map { q -> String in
        if q.id == question.id { return label }
        return ""  // 其他问题暂无答案
    }
    sendAnswers(allAnswers)
}

private func sendFreeForm() {
    let text = freeText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return }
    let allAnswers = pendingQuestions.map { _ in text }
    sendAnswers(allAnswers)
}

private func sendAnswers(_ answers: [String]) {
    isSending = true
    errorMessage = nil
    Task {
        do {
            try await replyProvider.sendAnswer(
                sessionId: session.id,
                requestId: session.pendingQuestionContext?.requestId,
                questions: session.pendingQuestionContext?.questions ?? [],
                answers: answers
            )
            await MainActor.run {
                NotchViewModel.shared.notchClose(restorePreviousApp: false)
            }
        } catch {
            await MainActor.run {
                errorMessage = error.localizedDescription
                isSending = false
            }
        }
    }
}

private func letterLabel(for index: Int) -> String {
    String(UnicodeScalar(65 + index)!)
}
```

注意：`pickOption` 目前只填当前问题答案，其他问题填空串。实际实现中需要跟踪每个问题的已选答案（@State dict）。这里先简化，多 question 场景由 Task 17 的 swiper 补全状态管理。

- [ ] **Step 2: 编译验证**

```bash
cd /Users/wuruofan/mine/rfw/nook && xcodebuild build -project Nook.xcodeproj -scheme Nook -destination 'platform=macOS' -quiet 2>&1 | tail -5
```

- [ ] **Step 3: Commit**

```bash
git add Nook/UI/Views/QuestionPanelView.swift
git commit -m "feat(question): add option buttons + free-form input to QuestionPanelView"
```

---

## Task 17: QuestionPanelView 多 question 状态管理

**Files:**
- Modify: `Nook/UI/Views/QuestionPanelView.swift`

- [ ] **Step 1: 加 @State per-question answers 字典**

在 `QuestionPanelView` 的 `@State` 区域加：

```swift
@State private var selectedAnswers: [Int: String] = [:]  // questionIndex → chosen label
```

- [ ] **Step 2: 修改 pickOption 用字典记录选择**

替换 `pickOption`：

```swift
private func pickOption(questionIndex: Int, label: String) {
    selectedAnswers[questionIndex] = label
    // 如果所有问题都有答案，自动发送
    if selectedAnswers.count == pendingQuestions.count {
        let answers = (0..<pendingQuestions.count).map { selectedAnswers[$0] ?? "" }
        sendAnswers(answers)
    }
}
```

- [ ] **Step 3: 修改 optionsListForQuestion 传 index**

```swift
// 在 optionsListForQuestion 里:
ForEach(Array(question.options.enumerated()), id: \.offset) { idx, option in
    Button { pickOption(questionIndex: questionGlobalIndex(for: question), label: option.label) } label: {
        // ... 同之前，但加 selected 高亮
        let isSelected = selectedAnswers[questionGlobalIndex(for: question)] == option.label
        // background 改为 isSelected ? Color.orange.opacity(0.2) : Color.white.opacity(0.07)
    }
}

private func questionGlobalIndex(for question: PendingQuestion) -> Int {
    pendingQuestions.firstIndex(where: { $0.id == question.id }) ?? 0
}
```

- [ ] **Step 4: 修改 sendFreeForm 也用字典**

```swift
private func sendFreeForm() {
    let text = freeText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return }
    let idx = currentIndex
    selectedAnswers[idx] = text
    if selectedAnswers.count == pendingQuestions.count {
        let answers = (0..<pendingQuestions.count).map { selectedAnswers[$0] ?? "" }
        sendAnswers(answers)
    }
}
```

- [ ] **Step 5: 编译验证**

```bash
cd /Users/wuruofan/mine/rfw/nook && xcodebuild build -project Nook.xcodeproj -scheme Nook -destination 'platform=macOS' -quiet 2>&1 | tail -5
```

- [ ] **Step 6: Commit**

```bash
git add Nook/UI/Views/QuestionPanelView.swift
git commit -m "feat(question): add per-question answer tracking for multi-question swiper"
```

---

## Task 18: AppDelegate 注册 Providers

**Files:**
- Modify: `Nook/App/AppDelegate.swift`（或等效启动入口）

- [ ] **Step 1: 在应用启动时注册所有 provider**

在 `applicationDidFinishLaunching` 或 `init()` 里加：

```swift
let reg = QuestionReplyProviderRegistry.shared
reg.register(OpencodeQuestionReplyProvider())
reg.register(TerminalFallbackProvider(provider: .claude))
reg.register(TerminalFallbackProvider(provider: .codex))
reg.register(TerminalFallbackProvider(provider: .cursor))
```

- [ ] **Step 2: 编译验证**

```bash
cd /Users/wuruofan/mine/rfw/nook && xcodebuild build -project Nook.xcodeproj -scheme Nook -destination 'platform=macOS' -quiet 2>&1 | tail -5
```

- [ ] **Step 3: Commit**

```bash
git add Nook/App/AppDelegate.swift
git commit -m "feat(question): register QuestionReplyProviders at app launch"
```

---

## Task 19: End-to-End 手动测试

**Files:**
- None (manual testing only)

- [ ] **Step 1: 构建 Debug 配置**

```bash
cd /Users/wuruofan/mine/rfw/nook && xcodebuild build -project Nook.xcodeproj -scheme Nook -configuration Debug -destination 'platform=macOS' 2>&1 | tail -3
```

- [ ] **Step 2: 重新部署 opencode plugin**

```bash
# 触发 HookInstaller.installIfNeeded
# 手动重启 Nook app
```

- [ ] **Step 3: 实跑 opencode session → 触发 AskUserQuestion**

在终端里：
```bash
cd /Users/wuruofan/mine/rfw/opencode && opencode
# 发一个会触发 question tool 的 prompt
```

验证：
- [ ] Notch 自动展开
- [ ] 显示 QuestionPanelView（question 文本 + A/B/C 选项 + 输入框）
- [ ] 选项按钮可点击
- [ ] 点击后 agent 收到 answer，notch 自动关闭
- [ ] closed-state chip 显示（关 notch 后看）

- [ ] **Step 4: 测试多 question 场景**

在 opencode 里让 agent 一次问多个问题：
- [ ] 左右箭头可切换
- [ ] 每张卡片都有选项按钮
- [ ] 进度点正确显示

- [ ] **Step 5: 测试 Terminal Fallback**

在 Claude 路径下（如果可测）：
- [ ] 选项按钮隐藏
- [ ] "Go to Terminal →" 按钮显示
- [ ] 点击后焦点切到终端

- [ ] **Step 6: 测试 Claude/Codex provider**

如果不可测，确认 TerminalFallbackProvider 注册正确（启动日志无 fatal）。

- [ ] **Step 7: Commit 记录测试结果**

```bash
git commit --allow-empty -m "test(question): e2e manual test passed - question panel + reply working"
```

---

## Task 20: PROGRESS.md + RELEASE_NOTES 更新

**Files:**
- Modify: `PROGRESS.md`
- Modify: `RELEASE_NOTES.md`

- [ ] **Step 1: PROGRESS.md — Recently Completed 新增**

在 `## ✅ Recently Completed` 顶部加：

```markdown
- **2026-09-02 question tool notch prompt + provider-layered reply** — 新增 `.question` NotchContentType + 专用 QuestionPanelView（选项按钮 + 自由输入 + 多 question swiper）。closed-state 三段式 chip（左问号 + 中信息 + 右音乐波纹）。SessionStore auto-expand: `.waitingForInput` 时自动 `notchOpen(.notification)` + `pushTo(.question)`。引入 `QuestionReplyProvider` 协议抽象，Phase 1: `OpencodeQuestionReplyProvider` 走 plugin `question.reply` → `client.questions.reply()`（string[][] payload）。Claude/Codex/Cursor 走 `TerminalFallbackProvider` 占位（点击跳终端）。spec: `docs/specs/2026-09-02-question-tool-notch-prompt-design.md`。plan: `docs/superpowers/plans/2026-09-02-question-tool-notch-prompt.md`。
```

- [ ] **Step 2: RELEASE_NOTES.md 新增 entry**

```markdown
## [Unreleased]

### Added
- Question tool notch prompt: AskUserQuestion now auto-expands notch with option buttons + free-form input
- Multi-session question swiper with left/right navigation
- Closed-state question chip (three-segment: question mark + info + music wave)
- OpenCode provider: click option sends answer via plugin question.reply
- Claude/Codex/Cursor: "Go to Terminal →" fallback (Phase 2: tmux sendKeys)
```

- [ ] **Step 3: Commit**

```bash
git add PROGRESS.md RELEASE_NOTES.md
git commit -m "docs: update PROGRESS.md + RELEASE_NOTES for question tool notch prompt"
```

---

## 实施顺序总结

```
Task 1 (protocol) → Task 2 (models) → Task 3 (event requestId)
                                          ↓
Task 4 (registry) → Task 5 (TerminalFocusHelper) → Task 6 (fallback) → Task 7 (opencode provider)
                                          ↓
Task 8 (tests) → Task 9 (hookAdapter requestId) → Task 10 (SessionStore helper) → Task 11 (plugin)
                                          ↓
Task 12 (NotchViewModel) → Task 13 (chip) → Task 14 (NotchView wiring)
                                          ↓
Task 15 (panel skeleton) → Task 16 (options + input) → Task 17 (multi-question state)
                                          ↓
Task 18 (AppDelegate) → Task 19 (manual e2e) → Task 20 (docs)
```

**预期工作量**：~6-8 小时（含手动测试），按任务并行化可压缩到 ~4 小时。
