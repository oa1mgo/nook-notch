# Question Tool — Notch 提示 + 点选回答

> 日期: 2026-09-02
> 状态: 📝 设计阶段，等待实施
> 适用: Claude / Codex / OpenCode provider 的 `AskUserQuestion` 工具在 Nook notch 中的提示 + 点选回答
> 关联: [opencode v1.17 Event Compatibility Matrix](../specs/2026-06-17-opencode-v1.17-compatibility-matrix.md) · [opencode Permission Handling](../specs/2026-07-10-opencode-permission-handling.md) · [PROGRESS.md](../../PROGRESS.md)
> 范围: **Phase 1 = OpenCode reply 真实实现 + Claude/Codex/Cursor 占位（点击跳终端）**。Phase 2 = Claude/Codex tmux sendKeys 真实实现（用户装机后再做）。

## TL;DR

AskUserQuestion 当前 Nook 没有任何形式的 notch 提示，仅在 chat view 的 tool call 处渲染静态内容，user 必须去终端手敲字母回答。本 spec：

1. 给 notch 加一个**全新的 `.question` 内容类型**，question pending 时自动展开一个专用面板（仿 permission 的 3-button 结构）
2. closed-state 加一个**三段式 chip**（左问号 + 中信息 + 右音乐），物理刘海遮挡中间时由 OS 处理
3. 引入 **`QuestionReplyProvider` 抽象**，Phase 1 实现 `OpencodeQuestionReplyProvider`（走 plugin command socket 新增的 `question.reply`），Claude/Codex/Cursor 在 Phase 1 阶段是占位（点击跳终端）
4. `SessionStore` 检测到 `.waitingForInput` **自动 `notchOpen(.notification)` + `pushTo(.question)`**，与现有 permission 行为对齐
5. Phase 2：Claude/Codex/Cursor 替换占位为 tmux sendKeys（按字母选项逐题发送）

## 问题陈述

### 现象

- Agent 调 `AskUserQuestion` → Session 进入 `.waitingForInput`，但 notch 完全无视觉提示（closed 仅有 `ReadyForInputIndicatorIcon` 小对勾，opened 仍是 `SessionListView`）
- 唯一回答入口是 `ChatView` 里的 `Terminal` 按钮 → 焦点切到终端 → 用户手敲 `A`/`B`/.../Enter
- 物理刘海设备上 closed-state chip 即使扩展宽度也只占 `closedNotchSize`，信息露不出来

### 根因

```
opencode/Claude → plugin/hook → HookSocketServer → SessionStore.handleWaitingForUserInput
                                                                  ↓
                                                    session.phase = .waitingForInput
                                                                  ↓
                                                    ChatInteractivePromptBar 显示 Terminal 按钮
                                                    （no panel-level UI, no chip indicator）
```

`OpencodeHookAdapter.handleQuestionAsked` (`Nook/Services/Hooks/OpencodeHookAdapter.swift:687-747`) 缺失 `requestID` 捕获，导致即便后续想用 plugin command socket 也没法 reply。

### Codex / Claude 对照

- **Permission** 有完整链路：`InlineApprovalButtons`（在 `SessionListView` 实例行 / `ChatView` 里） → `SessionMonitor.approvePermission/denyPermission` → 分 provider 走 socket 或 tmux sendKeys → agent 收到决定。**但这不是 notch 面板** — 它在 chat view 行内 + 关闭态 `PermissionIndicatorIcon`。
- **Question** 缺两步：(a) UI 面板（**这是第一个 notch 内的"等待回答面板"** — 从零新增），(b) 回复通道（OpenCode plugin `question.reply` 未实现）。

---

## 设计

### 1. 架构分层（核心新增）

新增 `QuestionReplyProvider` 协议，UI 只跟 protocol 交互：

```swift
// Nook/Services/Question/QuestionReplyProvider.swift (NEW)
protocol QuestionReplyProvider {
    var provider: SessionProvider { get }
    /// 发送答案。answers 数组与 questions 一一对应（同长度、同 index）。
    /// 返回 success/failure；UI 根据结果决定关 notch 还是显示错误。
    func sendAnswer(
        sessionId: String,
        requestId: String?,           // opencode 才有，Claude/Codex nil
        questions: [QuestionItem],
        answers: [String]             // index → chosen label 或自由文本
    ) async throws

    /// 能力探测：能否在 notch 里 1-click 回答。
    /// false = UI 降级为「跳到终端」按钮（点击 → focusTerminal）
    var supportsInlineAnswer: Bool { get }
}
```

四个 provider 实现：

| Class | Phase 1 | Phase 2 |
|---|---|---|
| `OpencodeQuestionReplyProvider` (NEW) | **真实**：plugin command socket `question.reply` → `client.questions.reply()` | 保持不变 |
| `TerminalFallbackProvider(provider: .claude)` (NEW) | **占位**：`supportsInlineAnswer=false`，按钮跳终端 | 替换为 `ClaudeQuestionReplyProvider` (NEW)：tmux sendKeys 合成选项字母 |
| `TerminalFallbackProvider(provider: .codex)` (NEW) | **占位**：跳终端 | 替换为 `CodexQuestionReplyProvider` (NEW)：tmux sendKeys |
| `TerminalFallbackProvider(provider: .cursor)` (NEW) | **占位**：跳终端 | 替换为 `CursorQuestionReplyProvider` (NEW)：tmux sendKeys |

注册中心：

```swift
// Nook/Services/Question/QuestionReplyProviderRegistry.swift (NEW)
@MainActor
final class QuestionReplyProviderRegistry {
    static let shared = QuestionReplyProviderRegistry()
    private var providers: [SessionProvider: QuestionReplyProvider] = [:]

    func register(_ provider: QuestionReplyProvider) {
        providers[provider.provider] = provider
    }

    func provider(for session: SessionState) -> QuestionReplyProvider {
        guard let p = providers[session.provider] else {
            fatalError("QuestionReplyProvider for \(session.provider) not registered. Did AppDelegate register all four providers?")
        }
        return p
    }
}
```

注册时机：`AppDelegate` 启动时注册全部四个实例：

```swift
let reg = QuestionReplyProviderRegistry.shared
reg.register(OpencodeQuestionReplyProvider())
reg.register(TerminalFallbackProvider(provider: .claude))
reg.register(TerminalFallbackProvider(provider: .codex))
reg.register(TerminalFallbackProvider(provider: .cursor))
```

`provider(for:)` 用 `fatalError` 而不是 fallback — 启动期注册失败应该早暴露（一个 provider 没注册意味着 AppDelegate 配置错误，默默回退到 `.claude` 的 TerminalFallback 会掩盖 bug）。

### 2. UI 内容类型扩展

**`Nook/Core/NotchViewModel.swift`** — `NotchContentType` 新增 case（**这是 Nook 第一个"等待回答面板"** — 当前 `NotchContentType` 只有 `instances/menu/shortcuts/agents/performanceSettings/performance/chat` 七个 case，没有 `.permission`；permission 走的是 closed-state `PermissionIndicatorIcon` + `ChatView` 里的 `InlineApprovalButtons`，**不是 notch 面板**。本 spec 是从零新增的第一个 notch 等待面板，UI 借鉴 `InlineApprovalButtons` 的按钮风格但不沿用其架构）：

```swift
case question(SessionState)
```

**`Nook/UI/Views/NotchView.swift`** — 主内容 switch 新增：

```swift
case .question(let session):
    QuestionPanelView(
        session: session,
        replyProvider: QuestionReplyProviderRegistry.shared.provider(for: session),
        onClose: { viewModel.navigateBack() }
    )
```

**`Nook/UI/Views/QuestionPanelView.swift` (NEW)** — 顶层组件：

```swift
struct QuestionPanelView: View {
    let session: SessionState
    let replyProvider: QuestionReplyProvider
    let onClose: () -> Void

    @ObservedObject private var sessionMonitor: SessionMonitor
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
            } else if pendingQuestions.count == 1 {
                singleQuestionCard
            } else {
                multiQuestionSwiper
            }
        }
        .onAppear { loadPendingQuestions() }
        .onChange(of: sessionMonitor.changes(for: session.id)) { _, _ in
            // 答案回来后自动关闭（phase 转 .processing）
            if session.phase != .waitingForInput { onClose() }
        }
    }
}
```

**单/多 session 布局差异**：

```swift
// 单 session（pendingQuestions.count == 1）
private var singleQuestionCard: some View {
    VStack(alignment: .leading, spacing: 14) {
        Text(questionText).font(.system(size: 14, weight: .semibold))
        Text(questionHeader).font(.system(size: 9.5)).opacity(0.4).textCase(.uppercase)
        optionsList
        Divider()
        freeFormInput
    }
    .padding(16)
}

// 多 session（pendingQuestions.count > 1）
private var multiQuestionSwiper: some View {
    VStack(spacing: 0) {
        // 顶部 padding 与单 session 一致
        HStack {
            Text("CLAUDE · QUESTION").font(.system(size: 10, weight: .semibold)).foregroundColor(.orange)
            Spacer()
            // 进度点 + 计数
            ForEach(0..<pendingQuestions.count, id: \.self) { i in
                Circle().fill(i == currentIndex ? .orange : .gray.opacity(0.2))
                    .frame(width: 8, height: 3)
            }
            Text("\(currentIndex+1)/\(pendingQuestions.count)").font(.system(size: 9))
        }
        .padding(.horizontal, 18) // 与单 session 顶部 padding 一致
        .padding(.top, 14)

        // 下方内容缩进留 < > 空间
        HStack(spacing: 4) {
            Button { prev() } label: { Text("‹") }
                .disabled(currentIndex == 0)
                .opacity(currentIndex == 0 ? 0.15 : 0.5)
            VStack(alignment: .leading, spacing: 12) {
                Text(pendingQuestions[currentIndex].questionText)
                    .font(.system(size: 13, weight: .semibold))
                optionsList
                Divider()
                freeFormInput
            }
            .padding(.horizontal, 12)
            Button { next() } label: { Text("›") }
                .disabled(currentIndex == pendingQuestions.count - 1)
        }
        .padding(.bottom, 14)
    }
}
```

**选项按钮**（仿 permission 的 InlineApprovalButtons 结构）：

```swift
private var optionsList: some View {
    VStack(spacing: 5) {
        ForEach(Array(pendingQuestions[currentIndex].options.enumerated()), id: \.offset) { idx, option in
            Button { pickOption(idx) } label: {
                HStack(spacing: 10) {
                    Text(letterLabel(for: idx))
                        .frame(width: 22, height: 22)
                        .background(Color.white.opacity(0.12))
                        .clipShape(Circle())
                    VStack(alignment: .leading) {
                        Text(option.label).font(.system(size: 12, weight: .medium))
                        if let desc = option.description {
                            Text(desc).font(.system(size: 10)).opacity(0.5)
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

private var freeFormInput: some View {
    HStack(spacing: 8) {
        TextField("自定义回答...", text: $freeText)
            .textFieldStyle(.plain)
            .padding(8)
            .background(Color.white.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        Button { sendFreeForm() } label: {
            Text("Send ⏎").font(.system(size: 10, weight: .semibold))
        }
        .buttonStyle(.borderedProminent)
        .tint(.orange)
        .disabled(isSending || freeText.isEmpty)
    }
}
```

### 3. Closed-state chip（关闭态三段式）

**`Nook/UI/Views/NotchView.swift`** — `headerRow` 新增 `showQuestionActivity` 判断（在 `showCompactMusicActivity` 之前）：

```swift
private var showQuestionActivity: Bool {
    viewModel.status != .opened &&
    sessionMonitor.instances.contains { $0.phase.isWaitingForInput &&
        ToolCallItem.kind(of: lastInteractiveTool(for: $0)) == .askUserQuestion }
}

private var showCompactQuestionChip: Bool {
    showQuestionActivity
}
```

新的 `CompactQuestionActivityView`（独立组件，仿 `CompactMusicActivityView` 结构但简化）：

```swift
// Nook/UI/Components/CompactQuestionActivityView.swift (NEW)
struct CompactQuestionActivityView: View {
    @ObservedObject var sessionMonitor: SessionMonitor

    private var primarySession: SessionState? {
        sessionMonitor.instances
            .first { $0.phase.isWaitingForInput }
    }

    private var pendingQuestions: [PendingQuestion] {
        primarySession?.pendingQuestions ?? []
    }

    var body: some View {
        HStack(spacing: 12) {
            // 左：橘黄问号
            Circle()
                .fill(Color.orange)
                .frame(width: 22, height: 22)
                .overlay(Text("?").font(.system(size: 14, weight: .bold)).foregroundColor(.black))

            // 中：信息（被物理刘海遮挡时由 OS 处理）
            VStack(alignment: .leading, spacing: 2) {
                Text("\(primarySession?.provider.rawValue.uppercased() ?? "") · QUESTION")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.orange)
                Text(pendingQuestions.first?.questionText ?? "")
                    .font(.system(size: 11.5, weight: .medium))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // 右：音乐波纹（如果有）
            if musicManager.isVisible {
                WaveIndicator(musicManager: musicManager)
                    .frame(width: 50, height: 16)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .onTapGesture { viewModel.notchOpen(reason: .notification); viewModel.pushTo(.question(primarySession!)) }
    }
}
```

**优先级**（多 activity 共存时）：
```
showCompactQuestionChip > showCompactMusicActivity > showHeaderAgentActivity
```

在 `headerRow` 里：

```swift
if showCompactQuestionChip {
    CompactQuestionActivityView(...)
} else if showCompactMusicActivity {
    CompactMusicActivityView(...)
} else if showHeaderAgentActivity {
    // 现有 agent icon carousel
}
```

**物理刘海**：`Nook/UI/Components/NotchShape.swift` 已有 `closedNotchSize` 适配 `deviceNotchRect.height`。中间信息被物理摄像头区域遮挡是 OS 层的事，Nook 不感知 — `safeAreaInsets.top` 已处理。chip 的水平 padding 与现有 `CompactMusicActivityView` 对齐（`padding(.horizontal, 14)`）。

### 4. SessionStore 自动展开触发

**`Nook/Services/State/SessionStore.swift`** — 在所有 phase 转 `.waitingForInput` 的入口加：

```swift
private func handleWaitingForUserInput(sessionId: String) {
    guard let session = sessions[sessionId] else { return }
    session.phase = .waitingForInput

    // [NEW] 触发 notch 自动展开 + 跳到 question 面板
    Task { @MainActor in
        let viewModel = NotchViewModel.shared
        // Permission 时不抢焦点（permission 会自动展开并已处理）
        guard !viewModel.contentType.isPermissionLike else { return }
        viewModel.notchOpen(reason: .notification)
        viewModel.pushTo(.question(session))
    }
}
```

入口点（当前已有，需要 hook）：
- `processOpencodeWaitingForUserInput` (`SessionStore.swift:995-1017`)
- `processClaudeWaitingForUserInput`（在 `processHookEvent` `SessionStore.swift:346-413` 走的 `SessionEvent.determinePhase()` 路径）

提取公共 helper `handleWaitingForUserInput(sessionId:)`，所有路径调用它。

**Permission 同理**（如果 Phase 1 还没做）：`.waitingForApproval` 入口也走相同 helper，push 到 `.permission` 面板。但 permission 已经在做（commit `b180a59` 等），先看现有实现是否完整。

### 5. OpenCode plugin reply 协议（Phase 1 核心新增）

**`Nook/Services/Hooks/OpencodeHookAdapter.swift`** — `handleQuestionAsked` 捕获 `requestID`：

```swift
private func handleQuestionAsked(_ event: OpencodeQuestionAskedEvent) -> [SessionEvent] {
    // 当前 OpencodeHookAdapter.swift:687-747 只用 tool.messageID 抑制文本
    // 新增：提取 requestID 用于后续 reply
    let requestID = event.id   // question.asked 事件的顶层 id（que_xxx），不在 properties
    // ... 现有逻辑 + 把 requestID 存到 session metadata
    return [
        .waitingForUserInput(
            sessionId: event.sessionID,
            cwd: event.cwd,
            toolUseId: event.toolCallID,
            requestId: requestID       // [NEW]
        )
    ]
}
```

**`Nook/Models/SessionEvent.swift`** — `OpencodeSessionEvent` 新增字段：

```swift
case opencodeWaitingForUserInput(
    sessionId: String,
    cwd: String,
    toolUseId: String,
    requestId: String?            // [NEW]
)
```

**`Nook/Models/ToolResultData.swift`** — `AskUserQuestionContext`：

```swift
struct AskUserQuestionContext: Equatable, Sendable {
    let sessionId: String
    let toolUseId: String
    let questions: [QuestionItem]
    let requestId: String?          // opencode 才有
    let provider: SessionProvider
}
```

`SessionState` 加 `pendingQuestionContext: AskUserQuestionContext?`。

**`Nook/Resources/opencode-plugin/index.js`** — `handleCommand` 新增分支：

```js
async function handleCommand(cmd) {
    switch (cmd.cmd) {
        case "permission.reply":
            // 现有逻辑
            break
        case "question.reply":          // [NEW]
            if (!cmd.requestId) { console.error('question.reply missing requestId'); return }
            // answers 是 string[][]：每题一元素，元素是该题选中 label 的列表
            // SDK 类型 client.questions.reply({ sessionID, requestID, answers }) → 204
            await client.questions.reply({
                sessionID: cmd.sessionId,
                requestID: cmd.requestId,
                answers: cmd.answers
            })
            break
    }
}
```

**`Nook/Services/Hooks/OpencodeCommandSocket.swift`** — `sendCommand` 已经接受任意 payload，不改方法签名。调用方在 `OpencodeQuestionReplyProvider.sendAnswer` 里发：

```swift
// answers: [String] 是按 question 顺序的"每题最终答案"列表（每个元素是单选 label 或自由文本）
// 协议要 string[][]（每题 = [选中的 label 列表]），所以每个元素包一层数组：
let wireAnswers: [[String]] = answers.map { [$0] }
let payload: [String: Any] = [
    "cmd": "question.reply",
    "sessionId": sessionId,
    "requestId": requestId,
    "answers": wireAnswers
]
try await OpencodeCommandSocket.shared.sendCommand(payload, pid: session.pid)
```

`OpencodeQuestionReplyProvider` 的 `sendAnswer` 入参 `answers: [String]` 已是按 question index 一一对应的扁平列表（上层 `QuestionPanelView` 维护），由 provider 包成 `string[][]` 发出去。

**`Nook/Services/Question/OpencodeQuestionReplyProvider.swift` (NEW)**：

```swift
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
        let wireAnswers: [[String]] = answers.map { [$0] }   // string[][] 协议形状
        let payload: [String: Any] = [
            "cmd": "question.reply",
            "sessionId": sessionId,
            "requestId": requestId,
            "answers": wireAnswers
        ]
        try await OpencodeCommandSocket.shared.sendCommand(
            payload,
            pid: SessionStore.shared.sessions[sessionId]?.pid
        )
    }
}
```

### 6. Claude/Codex/Cursor 占位（Phase 1）

**`Nook/Services/Question/TerminalFallbackProvider.swift` (NEW)** — 一个简单 struct，按 provider 实例化：

```swift
struct TerminalFallbackProvider: QuestionReplyProvider {
    let provider: SessionProvider
    let supportsInlineAnswer: Bool = false

    init(provider: SessionProvider) {
        self.provider = provider
    }

    func sendAnswer(
        sessionId: String,
        requestId: String?,
        questions: [QuestionItem],
        answers: [String]
    ) async throws {
        throw QuestionReplyError.unsupportedProvider    // 永远不调
    }

    /// UI 不调 sendAnswer，而是直接调用这个：跳到终端。
    @MainActor
    func focusTerminalForAnswer(session: SessionState) {
        // 复用 ChatView.tryFocusTerminal() 的逻辑（提取到 helper）
        // ChatView.swift:584-632 → TerminalFocusHelper.tryFocusTerminal(session:)
        TerminalFocusHelper.tryFocusTerminal(for: session)
    }
}
```

**Phase 1 不创建 ClaudeQuestionReplyProvider / CodexQuestionReplyProvider / CursorQuestionReplyProvider** — `AppDelegate` 直接注册 3 个 `TerminalFallbackProvider` 实例：

```swift
QuestionReplyProviderRegistry.shared.register(TerminalFallbackProvider(provider: .claude))
QuestionReplyProviderRegistry.shared.register(TerminalFallbackProvider(provider: .codex))
QuestionReplyProviderRegistry.shared.register(TerminalFallbackProvider(provider: .cursor))
```

Registry 的 `provider(for:)` 不需要 fallback（如果 miss 就是 bug，直接 crash 在 dev 期早暴露）。

`QuestionPanelView` 根据 `replyProvider.supportsInlineAnswer` 切换 UI：
- `true`（opencode）：显示选项按钮 + 输入框
- `false`（claude/codex/cursor）：隐藏选项按钮，显示大字「Go to Terminal →」按钮，点击 → `replyProvider.focusTerminalForAnswer(session:)`

### 7. Phase 2 范围（不在本 spec 实施）

**Claude tmux sendKeys**：
- 抽 `ToolApprovalHandler.sendKeys(to:keys:)` 为 public（`Nook/Services/Tmux/ToolApprovalHandler.swift:53-78` 当前 private）
- `ClaudeQuestionReplyProvider` 替换：选项点击 → `sendKeys("A")` + `sendKeys("Enter")`
- 多 question 情况：依次 sendKeys（每个 question 一对字母 + Enter）；失败回退到 `focusTerminalForAnswer`
- 风险：tmux sendKeys 时机可能与 Claude TUI 内部状态机竞争 → 需要实测验证

---

## 文件清单

### Phase 1 新增文件

| 文件 | 行数估计 |
|---|---|
| `Nook/Services/Question/QuestionReplyProvider.swift` | 30 |
| `Nook/Services/Question/QuestionReplyProviderRegistry.swift` | 25 |
| `Nook/Services/Question/OpencodeQuestionReplyProvider.swift` | 50 |
| `Nook/Services/Question/TerminalFallbackProvider.swift` | 35 |
| `Nook/UI/Views/QuestionPanelView.swift` | 220 |
| `Nook/UI/Components/CompactQuestionActivityView.swift` | 80 |

### Phase 1 修改文件

| 文件 | 改动 |
|---|---|
| `Nook/Core/NotchViewModel.swift` | `NotchContentType` 加 `.question`；`openedSize` 加 `.question` case；新增 `shouldAutoExpandOnWaitingForInput` |
| `Nook/UI/Views/NotchView.swift` | 主内容 switch 加 `.question` 分支；`headerRow` 加 `showCompactQuestionChip` 优先级 |
| `Nook/UI/Components/NotchShape.swift` | （可能不需要改，复用现有） |
| `Nook/Models/SessionEvent.swift` | `opencodeWaitingForUserInput` 加 `requestId: String?` |
| `Nook/Models/ToolResultData.swift` | 新增 `AskUserQuestionContext`、`PendingQuestion` |
| `Nook/Models/SessionPhase.swift` | 加 `AskUserQuestionContext` 关联 |
| `Nook/Services/State/SessionStore.swift` | 提取 `handleWaitingForUserInput(sessionId:)` helper；`SessionState.pendingQuestionContext` |
| `Nook/Services/Hooks/OpencodeHookAdapter.swift` | `handleQuestionAsked` 提取 requestID；emit `OpencodeSessionEvent.waitingForUserInput(..., requestId:)` |
| `Nook/Services/Hooks/HookSocketServer.swift` | (可能不需要，permission 链路不变) |
| `Nook/Resources/opencode-plugin/index.js` | `handleCommand` 加 `case "question.reply"`；捕获 `requestID` 在 `question.asked` |
| `Nook/Resources/opencode-plugin/package.json` | （如需要 bump version） |
| `Nook/App/AppDelegate.swift`（或启动入口） | 注册 4 个 `QuestionReplyProvider` |
| `Nook/UI/Views/ChatView.swift` | `tryFocusTerminal` 抽到 `TerminalFocusHelper` |
| `Nook/UI/Window/...` | （无改动） |

合计：**6 新 + 10~13 改 = ~440 行净增，跨 16~19 文件**（具体取决于 plugin 是否需要 bump version、`HookSocketServer` 是否需要改、`NotchShape` 是否需要改）。

### Phase 2 新增/修改（不在本 spec 实施）

| 文件 | 改动 |
|---|---|
| `Nook/Services/Tmux/ToolApprovalHandler.swift` | `sendKeys` 改 public |
| `Nook/Services/Question/ClaudeQuestionReplyProvider.swift` (NEW) | tmux sendKeys 实现 |
| `Nook/Services/Question/CodexQuestionReplyProvider.swift` (NEW) | tmux sendKeys 实现 |
| `Nook/Services/Question/CursorQuestionReplyProvider.swift` (NEW) | tmux sendKeys 实现 |
| `Nook/Services/Question/TerminalFallbackProvider.swift` | 删除或仅保留 fallback |

---

## 风险与边界

1. **plugin `question.reply` 协议**：**已确认** — opencode SDK `client.ts` 暴露 `client.questions.reply({ sessionID, requestID, answers }) → 204`（HTTP `POST /api/session/:sessionID/question/:requestID/reply`）。**payload 形状（来自 `question-v1.ts`）**：`Reply = { answers: Array<Answer> }` 其中 `Answer = Array<String>`，即 `string[][]` — 每个问题一组"已选中 label"的字符串数组。单选 = `["选项A"]`，多选 = `["选项A", "选项B"]`，自由文本 = `["自由文本"]`。**无需调研，无需降级路径，直接用 SDK**。同时：`question.asked` 事件的 requestID 在顶层 `id` 字段（schema `Request.id`，形如 `que_xxx`），不在 `properties.requestID` — 主路径直接 `event.id` 即可。

⚠️ **本 spec 之前误把 payload 写成 `{label, value}` 对象数组 — 已修正为 `string[][]`**。plugin → SDK 的 `answers` 字段是 `[ [option_label_or_text], [option_label_or_text], ... ]`，按 question index 一一对应。

2. **多 question 顺序**：opencode `AskUserQuestion` 一次可包含 1-4 个 questions。本 spec Phase 1 假设 plugin `question.reply` 一次性收 answers 数组（与现有 `client.question.reply` SDK 行为对齐）。如果实际是逐题 API，需要在 plugin 里循环。

4. **物理刘海遮挡**：Nook 不主动让出刘海宽度。中间信息被遮挡由 OS 物理遮挡完成（用户视觉上看到的是左问号 + 右音乐，中间空）。这与 `MusicCardView` 当前行为一致。

5. **Question + Permission 同时发生**：
   - **同 session**：`.waitingForInput` 和 `.waitingForApproval` 通过 `SessionPhase.canTransition(to:)` 互斥 — 天然安全，不会有同 session 同时等两件事。
   - **跨 session**：A 等 question + B 等 permission 都发生。Phase 进入时会刷新 `session.lastActivity`（见 `SessionStore.processOpencodeWaitingForUserInput` 等），直接用 `lastActivity` 排序取最新。不新增字段。
   - **抢焦点判定**：本 spec **不**做 `isPermissionLike` guard（理由：`.permission(SessionState)` case 当前不存在，permission 也不自动展开 notch — 见风险 #10）。简单策略：notch 关闭态 → 展开并 pushTo 最新 question；如果 notch 已经开着且用户在 chat view 看另一 session → 不 yank（用户在做事别打断）。未来 permission 若做成 notch 面板，再补 `.permission` case + 抢焦点规则，**不要在本 spec 提前承担这个依赖**。

6. **Auto-expand 干扰用户**：用户可能在看其他 app，突然 notch 自动展开会打断。考虑加 `@AppStorage` 设置：`autoExpandOnQuestion` 默认 true，用户可关。

7. **已开 chat view 时**：用户在 chat view 时如果同时 question pending，`NotchViewModel.shouldAutoExpandOnWaitingForInput` 返回 false（已经在看），避免抢焦点。

8. **tool call ID 过期**：opencode plugin 拿到的 `toolUseId` 可能跟 SwiftUI 端 track 的不对应（race）。需要在 `OpencodeHookAdapter` 端持久化 `(sessionId, toolUseId) → requestId` 映射。

9. **WaveIndicator 组件**：`CompactQuestionActivityView` 引用的 `WaveIndicator` 是仿 MusicCardView 波纹条的小型组件，封装 `musicManager.playbackState.isPlaying` 状态。Phase 1 实现保持简单（8 个静态柱形 + isPlaying 时缓慢上下浮动即可，不复用 MusicCardView 的 TimelineView 复杂度）。

10. ~~`NotchContentType.isPermissionLike` 判定~~：**已删**。原本想用来防止 question 面板抢正在显示 permission 的 notch 焦点，但 (a) `.permission` case 当前不存在，(b) SessionStore 现在根本不自动展开 permission notch（permission 只通过 closed-state chip + chat view 按钮交互）。不需要这个 guard — 跨 session 多 question 时直接用 `session.lastActivity` 排序取最新（见风险 #5 重写）。

---

## 测试

### Phase 1 测试范围

**单元测试**：
- `OpencodeQuestionReplyProvider.sendAnswer` 构造 payload 正确（mock `OpencodeCommandSocket`）
- `QuestionReplyProviderRegistry.provider(for:)` 按 provider 分发
- `TerminalFallbackProvider.focusTerminalForAnswer` 调用 `TerminalFocusHelper.tryFocusTerminal`

**集成测试**：
- `OpencodeHookAdapter` 测试：模拟 `question.asked` event → 验证 emit `waitingForUserInput(..., requestId: "xxx")`
- `SessionStore.handleWaitingForUserInput` 测试：mock session → phase 转 `.waitingForInput` → 验证调 `NotchViewModel.notchOpen` + `pushTo(.question)`

**UI 测试**：
- `QuestionPanelView` 单 session 渲染（mock 数据）
- `QuestionPanelView` 多 session 渲染（mock 3 个 PendingQuestion，验证箭头启用/禁用状态）
- `CompactQuestionActivityView` 渲染
- `NotchView` `.question` 分支渲染（集成）

**手动测试**：
- opencode 实跑触发 AskUserQuestion → notch 自动展开 → 选项点击 → 验证 answer 到达 plugin → agent 继续处理
- 物理刘海 MacBook 验证中间信息被遮挡效果
- 多 session 同时 question → swiper 切换 + 答题

### Phase 2 测试范围（不在本 spec）

- Claude tmux sendKeys 路径实测
- 多 question 顺序发送 + Claude TUI 状态机兼容

---

## 验证清单（实施完成前）

- [ ] `xcodebuild` Debug 通过（零警告）
- [ ] 所有新增 .swift 文件在 `project.pbxproj` 加入
- [ ] `AskUserQuestionContext` / `PendingQuestion` / `QuestionReplyProvider` 类型完整 + Equatable/Sendable
- [ ] `OpencodeHookAdapter.handleQuestionAsked` 提取 requestID 不破坏现有 suppression 逻辑
- [ ] `SessionStore.handleWaitingForUserInput` 不与现有 permission 自动展开冲突
- [ ] `NotchViewModel.openedSize.question` case 计算正确（高度 = `panelHeightForPage` 或近似）
- [ ] `CompactQuestionActivityView` 不破坏现有 `headerRow` 优先级链
- [ ] plugin `package.json` version bump
- [ ] opencode plugin 部署（`HookInstaller.installIfNeeded`）
- [ ] xcodebuild 后手动跑一次 opencode AskUserQuestion
- [ ] CLAUDE.md / PROGRESS.md 更新（设计原则 + 已完成 + 关键 commit）
- [ ] RELEASE_NOTES.md 新增 entry

---

## 决策档案

- **2026-09-02 user：分层 + Phase 1 = OpenCode reply + 占位**：用户明确表示本地无 Claude Code，全套设计但只测 OpenCode。Phase 2 = 用户装机后做 Claude tmux。
- **2026-09-02 user：自由输入在 notch 里**：用户明确不要"跳到终端输入"。Phase 1 OpenCode 直接把自由文本当 `answers` 数组元素发给 plugin。
- **2026-09-02 user：多 session swiper 顶部 padding 与单 session 一致，下方内容缩进留 <> 空间**。
- **2026-09-02 user：物理刘海** — Nook 不感知，中间信息被遮挡由 OS 处理。
- **2026-09-02 user：右侧统一用波纹条**（不再用 album art）。
- **2026-09-02 user：closed-state 三段式**（左问号 + 中信息 + 右波纹），仅在 question pending + music playing 时三段都有。

---

## 关联档案

- `docs/specs/2026-06-17-opencode-v1.17-compatibility-matrix.md` — `question.asked` 事件 schema + 历史决策
- `docs/specs/2026-07-10-opencode-permission-handling.md` — permission.reply 完整实现，本 spec 镜像其 plugin command socket 模式
- `PROGRESS.md` — 项目当前焦点