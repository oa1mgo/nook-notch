# Session 列表 ⌃R 单一 pending 直达 — 设计

> 状态：approved（design），待实现
> 关联：`docs/superpowers/specs/2026-09-23-session-list-permission-shortcuts-design.md`（目标解析规则的来源，spec §2）
> 修订（2026-09-29 review）：① `resolveTarget` 从 fileprivate 函数改为 internal `KeyboardTargetResolver.resolve(from:highlighted:)`——`@testable` 只能提升到 internal，fileprivate 单测不可见；② 命中判定由全字段 Equatable 改为 `sessionId` 比较——SessionState 深比较会遍历 chatItems/toolTracker（SessionState.swift:36/41），且"同一 session"只该看 id；③ §3.2 改为单次快照 `rows = sortedInstances`（computed 属性，两次访问可能不同快照）；④ §3.3 引用行号修正为 380-393；⑤ §5 修正：permission pending 实际落 `.waitingForApproval`（SessionEvent.swift:244、HookSocketServer.swift:71），不在 ⌃R 目标集内——原引用的 SessionListView.swift:593 注释已过时；⑥ §6 单测按新签名整理并补 `showsInlineApprovalButtons`（SessionListView.swift:23）谓词用例。设计结论（0/1/2+ 规则、§4 行为表、非目标）未变。
> 修订（2026-09-29 与实现 plan 对账）：§3.1 落点由 spec 原写的 `SessionListView.swift` 文件级改为新文件 `Nook/Core/KeyboardTargetResolver.swift`；§3.3 目标来源由 `approvalTargets` 改为 `rows.filter(\.showsInlineApprovalButtons)`。两处均以 plan 为准（plan 更优：独立可测 + 保持单快照）。

## 1. 问题

Session 页按 ⌃R（`replyToQuestion`）无法进入唯一一个等待回答的 session。根因：消费端 `SessionListView.onReceive($keyboardReplyTrigger)`（SessionListView.swift:275-284）要求 `keyboardSelectedIndex >= 0` 且该行 `phase == .waitingForInput`，而 `keyboardSelectedIndex` 初始为 **-1**（NotchViewModel.swift:118）——用户进入 session 页后未按过 ↑/↓ 时 ⌃R 静默失败。

现有 ⌃R 规则等价于 permission 的 "2+ 高亮规则"，缺 permission 已有的 0/1 宽松分支。

## 2. 目标 / 非目标

**目标**
- ⌃R 镜像 permission Y/N/A 的目标解析规则（permission shortcuts spec §2）：0 → 不动作；**1 → 无视高亮直接进入唯一 target**；≥2 → 高亮必须是 target，否则不动作。
- 同构代码抽共享纯函数（SOI，lessons 3），permission 与 question 两处同迁共用。

**非目标**
- chat 页 ⌃R（ChatView.swift:238-245 已有独立 handler 且工作正常；单 session 无高亮，helper 退化为一行 guard，不接入）。
- session 页无 provider guard 而 chat 页有 `provider == .opencode` guard 的既有不一致。
- 行内 Reply 气泡、`activateReplyToQuestion`、`keyboardReplyTrigger` 传输层均不改。

## 3. 设计

### 3.1 纯函数（新文件 `Nook/Core/KeyboardTargetResolver.swift`，**internal** 以便单测）

> 落点：`Nook/` 是 `PBXFileSystemSynchronizedRootGroup`（exception 仅 `Info.plist`），新增 .swift 无需改 `project.pbxproj`。

```swift
/// Keyboard target resolution shared by permission Y/N/A and question ⌃R
/// (mirrors permission-shortcuts spec §2): 0 → none; 1 → the single
/// target regardless of highlight; 2+ → highlighted must be a target.
enum KeyboardTargetResolver {
    /// `highlighted` is nil when there is no valid highlight
    /// (`keyboardSelectedIndex == -1` or out of range).
    static func resolve(from targets: [SessionState], highlighted: SessionState?) -> SessionState? {
        switch targets.count {
        case 0: return nil
        case 1: return targets[0]
        default:
            guard let highlighted,
                  targets.contains(where: { $0.sessionId == highlighted.sessionId })
            else { return nil }
            return highlighted
        }
    }
}
```

- **可见性必须是 internal，不能是 `private` / `fileprivate`**：§6 的单测走 `@testable import Nook`，只提升 `internal`；`private` / `fileprivate` 在测试目标里不可见（NookTests 现有文件均如此，见 `QuestionPanelKeyboardRoutingTests.swift:2`）。
- **不用泛型 `[T: Equatable]` + `contains(highlighted)`**：唯一实例化类型就是 `SessionState`；全字段 `Equatable` 在**命中**时会深比较整个 `chatItems` / `toolTracker`（`SessionState.swift:36/41`）——为回答"是不是同一行"去比对整段聊天历史。按 `sessionId` 比较既与文件既有写法一致（`SessionListView.swift:364` 的 `$0.sessionId == id`），也是"同一行"唯一有意义的语义（`sessionId` 是首字段且为 `let`，非同行在第一字段即短路）。

等价性（permission 迁移可证）：原 2+ 分支先 `guard idx >= 0, idx < count else { return event }` 再查 `highlighted.showsInlineApprovalButtons`；新写法 idx 无效 → `highlighted = nil` → resolve 返回 nil → 同样 `return event`。命中判定由"直接查 `highlighted.showsInlineApprovalButtons`"改为"`highlighted.sessionId ∈ targets`"，而 `targets` 正是 `showsInlineApprovalButtons` 过滤出的集合，二者等价。

### 3.2 question 侧（onReceive 改写）

```swift
.onReceive(viewModel.$keyboardReplyTrigger) { trigger in
    guard trigger != nil else { return }
    viewModel.keyboardReplyTrigger = nil          // 消费顺序保持现状
    guard viewModel.contentType == .instances else { return }
    // Single snapshot: `sortedInstances` re-sorts on every access, and
    // `highlighted` (by index) + `targets` (by filter) must come from the
    // same array, else index and membership can disagree.
    let rows = sortedInstances
    let idx = viewModel.keyboardSelectedIndex
    let highlighted = (idx >= 0 && idx < rows.count) ? rows[idx] : nil
    let targets = rows.filter { $0.phase == .waitingForInput }
    guard let target = KeyboardTargetResolver.resolve(from: targets, highlighted: highlighted) else { return }
    replyToQuestion(target)
}
```

- 判别 `phase == .waitingForInput`：与行内 Reply 气泡（SessionListView.swift:238/783）一致。该 phase 也覆盖 opencode 经权限通道到达的 askUserQuestion（SessionEvent.swift:241-242）——唯一 target 是它时 ⌃R 进 question 页是**正确**结果；进 question 页后落 fallback 的场景见 §5。
- 2+ 分支要求高亮是 waiting 行：高亮 -1/越界/非 waiting → 不动作。

### 3.3 permission 侧（handleKeyDown 改写）

`switch targets.count` 块（`SessionListView.swift:380-393`）替换为 idx 解析 + `KeyboardTargetResolver.resolve(from: rows.filter(\.showsInlineApprovalButtons), highlighted:)`（`rows = sortedInstances` 单快照；不用 `approvalTargets`——那是另一次 `sortedInstances` 求值，与 `highlighted` 不同快照；该属性仍由 `.onChange(of: approvalTargets)`（:155）使用，不会 unused），紧随其后的 `guard let target else { return event }`（`L394`）与 y-n-a 分发不动。行为逐分支等价（§3.1）。

## 4. 行为变化

| 场景 | 现状 | 变化 |
|---|---|---|
| 0 个 waiting，按 ⌃R | 不动作 | 不动作 |
| **1 个 waiting，index=-1/越界/高亮非 waiting，按 ⌃R** | **不动作** | **进入该 session 的 question 页** |
| 1 个 waiting，高亮即它，按 ⌃R | 进入 | 进入（不变） |
| ≥2 个 waiting，高亮是 waiting | 进入高亮的 | 不变 |
| ≥2 个 waiting，高亮 -1/非 waiting | 不动作 | 不动作 |
| permission Y/N/A 各分支 | — | 逐分支等价（回归项） |

## 5. 已知限制

- 唯一 waiting 行**没有加载到 question 上下文**时，进入 question 页会落 fallback：非 inline-answer provider → "Go to Terminal" card；inline-answer 但 questions 未加载 → loading placeholder（`QuestionPanelView.swift:62-68`）。与行内气泡点击行为一致，非本次引入。
  - 注：permission pending **不是**这个场景——它落 `.waitingForApproval`（`HookSocketServer.swift:71`、`SessionEvent.swift:244`），不在 ⌃R 目标集（`phase == .waitingForInput`）内；唯一经权限通道进 `.waitingForInput` 的是 opencode askUserQuestion（`SessionEvent.swift:241-242`），进 question 页是正确结果。
- chat 页 ⌃R 的 `provider == .opencode` guard 与 session 页无 provider guard 不一致（既有）。
- chat 页 ⌃R 走 ChatView 独立 handler，不共享 resolver（设计决策，见 §2）。

## 6. 测试

**单测**（纯函数 `KeyboardTargetResolver.resolve`，需 `internal` 可见性）：

- 0 target；
- 1 target + highlighted=nil（-1/越界）；
- 1 target + highlighted 非它；
- 2+ 高亮是 target；
- 2+ 高亮非 target；
- 2+ highlighted=nil。

permission 与 question 两处调用点共享同一组用例（参数化 targets/highlighted）。

**补充单测**（调用点谓词，弥补 view 层不可测）：`SessionState.showsInlineApprovalButtons` 是 internal 纯扩展、可直接单测 permission 侧目标集——`waitingForApproval` 且非 askUserQuestion → true；terminal-approval / askUserQuestion / 其他 phase → false。view 层本身无单测（`NotchViewModel` 在测试进程 deinit 崩溃，见 `QuestionPanelKeyboardRoutingTests.swift:13-18`）。

**手测**
1. session 页（不按 ↑↓）按 ⌃R → 进入唯一 waiting session 的 question 页。
2. 列表含 1 个 waiting + 若干 idle，高亮到 idle 行按 ⌃R → 仍进入该 waiting（1 规则）。
3. ≥2 个 waiting：高亮 waiting 行 → 进入；高亮 idle 行 → 不动作。
4. 0 个 waiting 按 ⌃R → 不动作。
5. **回归**：permission 待批时按 Y/N/A——0/1/2+ 三组行为与改前一致（permission shortcuts spec 测试清单）。
