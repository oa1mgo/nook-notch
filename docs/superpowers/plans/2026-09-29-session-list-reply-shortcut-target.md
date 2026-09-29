# Session 列表 ⌃R 单一 pending 直达 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** ⌃R 在 session 页镜像 permission Y/N/A 的 0/1/2+ 目标解析规则——列表里只有一个 waitingForInput session 时无视高亮直接进入，同时把两处同构 switch 收敛到共享的 `KeyboardTargetResolver`（SOI）。

**Architecture:** 新建 internal 纯逻辑枚举 `KeyboardTargetResolver.resolve(from:highlighted:)`（按 `sessionId` 命中判定，可 `@testable` 单测）；`SessionListView` 的 question `onReceive` 与 permission `handleKeyDown` 两处调用它。view 层本身不可单测（`NotchViewModel` 在 XCTest host deinit 崩溃，见 `QuestionPanelKeyboardRoutingTests.swift:13-18`），行为靠手测清单。

**Tech Stack:** Swift / SwiftUI / XCTest（`@testable import Nook`）。Xcode 工程为 fileSystemSynchronized —— **新文件不需要改 project.pbxproj**。

**Spec:** `docs/specs/2026-09-29-session-list-reply-shortcut-target-design.md`

---

## 背景速览（实现者零上下文必读）

- `keyboardReplyTrigger`（`NotchViewModel.swift:123`，`activateReplyToQuestion` 在 :795 置 UUID）由两处消费：`SessionListView.swift:275-284`（session 页，本次要改）与 `ChatView.swift:238-245`（chat 页，**不动**）。
- `keyboardSelectedIndex` 初始 **-1**（`NotchViewModel.swift:118`）；↑/↓ 在 -1 时分别落到最后一项/第一项（NotchViewModel:684/741）。
- `sortedInstances` 是 **computed**（每次访问重排序），单次快照 `let rows = sortedInstances` 后再取下标与 filter，避免 index 与 membership 来自不同数组。
- permission 现有目标解析：`SessionListView.swift:380-393` 的 `switch targets.count`（spec §2 规则：0 → nil；1 → 唯一；2+ → 高亮必须是 target），其后 `:394 guard let target else { return event }` 与 y/n/a 分发**不动**。
- `showsInlineApprovalButtons`：`SessionListView.swift:23-29`（`extension SessionState`，internal）——`isWaitingForApproval` 且非 askUserQuestion。
- 测试辅助：`NookTests/TestSupport.swift` 提供 `fixedDate(_:)`；现有构造先例见 `NookTests/SessionStateTests.swift:6-14`。

---

### Task 1: KeyboardTargetResolver 纯函数（TDD）

**Files:**
- Create: `Nook/Core/KeyboardTargetResolver.swift`
- Test: `NookTests/KeyboardTargetResolverTests.swift`

- [ ] **Step 1: 写失败测试**

创建 `NookTests/KeyboardTargetResolverTests.swift`：

```swift
//  KeyboardTargetResolverTests.swift
//  Nook
//
//  Spec: docs/specs/2026-09-29-session-list-reply-shortcut-target-design.md §6

import XCTest
@testable import Nook

private func makeSession(_ id: String) -> SessionState {
    SessionState(sessionId: id, cwd: "/tmp/\(id)")
}

final class KeyboardTargetResolverTests: XCTestCase {

    func testZeroTargetsReturnsNilEvenWithHighlight() {
        let highlighted = makeSession("a")
        XCTAssertNil(KeyboardTargetResolver.resolve(from: [], highlighted: highlighted))
    }

    func testSingleTargetReturnedWhenHighlightIsNil() {
        // -1 / out-of-range index → highlighted == nil; 1-rule ignores highlight
        let only = makeSession("a")
        XCTAssertEqual(KeyboardTargetResolver.resolve(from: [only], highlighted: nil)?.sessionId, "a")
    }

    func testSingleTargetReturnedWhenHighlightIsDifferentSession() {
        let only = makeSession("a")
        let other = makeSession("b")
        XCTAssertEqual(KeyboardTargetResolver.resolve(from: [only], highlighted: other)?.sessionId, "a")
    }

    func testMultipleTargetsReturnHighlightedWhenItIsATarget() {
        let a = makeSession("a"), b = makeSession("b")
        XCTAssertEqual(KeyboardTargetResolver.resolve(from: [a, b], highlighted: b)?.sessionId, "b")
    }

    func testMultipleTargetsReturnNilWhenHighlightIsNotATarget() {
        let a = makeSession("a"), b = makeSession("b"), outsider = makeSession("c")
        XCTAssertNil(KeyboardTargetResolver.resolve(from: [a, b], highlighted: outsider))
    }

    func testMultipleTargetsReturnNilWhenHighlightIsNil() {
        let a = makeSession("a"), b = makeSession("b")
        XCTAssertNil(KeyboardTargetResolver.resolve(from: [a, b], highlighted: nil))
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

```bash
xcodebuild test -project Nook.xcodeproj -scheme Nook -configuration Debug \
  -derivedDataPath build/TestDerivedData -destination 'platform=macOS' \
  -only-testing:NookTests/KeyboardTargetResolverTests
```

预期：**编译失败** `cannot find 'KeyboardTargetResolver' in scope`。

- [ ] **Step 3: 实现**

创建 `Nook/Core/KeyboardTargetResolver.swift`：

```swift
//  KeyboardTargetResolver.swift
//  Nook
//
//  Keyboard target resolution shared by permission Y/N/A and question ⌃R
//  (mirrors permission-shortcuts spec §2:
//  docs/superpowers/specs/2026-09-23-session-list-permission-shortcuts-design.md).
//  Spec: docs/specs/2026-09-29-session-list-reply-shortcut-target-design.md

import Foundation

enum KeyboardTargetResolver {
    /// 0 → none; 1 → the single target regardless of highlight; 2+ → the
    /// highlighted session must itself be a target, else none.
    /// `highlighted` is nil when there is no valid highlight
    /// (`keyboardSelectedIndex == -1` or out of range).
    /// Match by sessionId — SessionState's synthesized Equatable deep-compares
    /// chatItems/toolTracker etc., and "same session" is an id question.
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

- [ ] **Step 4: 跑测试确认通过**

同 Step 2 命令。预期：**6 tests PASS**。

- [ ] **Step 5: Commit**

```bash
git add Nook/Core/KeyboardTargetResolver.swift NookTests/KeyboardTargetResolverTests.swift
git commit -m "feat(keyboard): add KeyboardTargetResolver 0/1/2+ target rule (TDD)"
```

---

### Task 2: showsInlineApprovalButtons 谓词单测（spec §6）

**Files:**
- Test: `NookTests/KeyboardTargetResolverTests.swift`（追加第二个 test class）

- [ ] **Step 1: 补测试（characterization——谓词已存在，无红阶段，直接期待 PASS）**

在 `NookTests/KeyboardTargetResolverTests.swift` 末尾追加：

```swift
/// Permission-side target-set predicate (spec §6) — covers what the view
/// layer's handleKeyDown cannot: SessionListView.swift:23-29.
final class InlineApprovalPredicateTests: XCTestCase {

    private func session(phase: SessionPhase) -> SessionState {
        SessionState(sessionId: "ses_test", cwd: "/tmp/test", phase: phase)
    }

    private func approvalPhase(toolName: String) -> SessionPhase {
        .waitingForApproval(PermissionContext(
            toolUseId: "tool-1",
            toolName: toolName,
            toolInput: nil,
            receivedAt: fixedDate(10)
        ))
    }

    func testWaitingForApprovalWithBashShowsInlineButtons() {
        XCTAssertTrue(session(phase: approvalPhase(toolName: "Bash")).showsInlineApprovalButtons)
    }

    func testWaitingForApprovalWithAskUserQuestionHidesInlineButtons() {
        // AskUserQuestion routes to "Go to Terminal", not Y/N/A
        // (ToolKind.classify lowercases: "askuserquestion" → .askUserQuestion).
        XCTAssertFalse(session(phase: approvalPhase(toolName: "AskUserQuestion")).showsInlineApprovalButtons)
    }

    func testTerminalApprovalIsNotAnInlineTarget() {
        // isWaitingForApproval matches ONLY .waitingForApproval (SessionPhase.swift:266-269);
        // terminal-side approval must stay out of the keyboard target set.
        let phase = SessionPhase.waitingForTerminalApproval(PermissionContext(
            toolUseId: "tool-1", toolName: "Bash", toolInput: nil, receivedAt: fixedDate(10)
        ))
        XCTAssertFalse(session(phase: phase).showsInlineApprovalButtons)
    }

    func testNonApprovalPhasesAreNotInlineTargets() {
        XCTAssertFalse(session(phase: .waitingForInput).showsInlineApprovalButtons)
        XCTAssertFalse(session(phase: .idle).showsInlineApprovalButtons)
    }
}
```

- [ ] **Step 2: 跑测试确认通过（谓词已存在，纯补测试）**

```bash
xcodebuild test -project Nook.xcodeproj -scheme Nook -configuration Debug \
  -derivedDataPath build/TestDerivedData -destination 'platform=macOS' \
  -only-testing:NookTests/KeyboardTargetResolverTests \
  -only-testing:NookTests/InlineApprovalPredicateTests
```

**两个 `-only-testing` 都要写**：`-only-testing:<Target>/<Class>` 是**按类名过滤，不认文件名**。本文件里有两个 test class，只写 `KeyboardTargetResolverTests` 会把 `InlineApprovalPredicateTests` 整个排除掉（期望 10 个却只跑 6 个，且它的 FAIL 会被静默跳过）。多次 `-only-testing` 取并集。

预期：**10 tests PASS**（6 + 4）。若有 FAIL，先核对 `SessionPhase.waitingForTerminalApproval` 关联值签名与 `fixedDate` 可见性，不要改谓词实现。

- [ ] **Step 3: Commit**

```bash
git add NookTests/KeyboardTargetResolverTests.swift
git commit -m "test(session-list): cover showsInlineApprovalButtons target-set predicate"
```

---

### Task 3: question 侧 onReceive 迁移到 resolver

**Files:**
- Modify: `Nook/UI/Views/SessionListView.swift:275-284`

- [ ] **Step 1: 替换 onReceive 消费段**

当前代码（:275-284）：

```swift
            .onReceive(viewModel.$keyboardReplyTrigger) { trigger in
                guard trigger != nil else { return }
                viewModel.keyboardReplyTrigger = nil // consume (see above)
                guard viewModel.contentType == .instances,
                      viewModel.keyboardSelectedIndex >= 0,
                      viewModel.keyboardSelectedIndex < sortedInstances.count else { return }
                let session = sortedInstances[viewModel.keyboardSelectedIndex]
                guard session.phase == .waitingForInput else { return }
                replyToQuestion(session)
            }
```

替换为（spec §3.2）：

```swift
            .onReceive(viewModel.$keyboardReplyTrigger) { trigger in
                guard trigger != nil else { return }
                viewModel.keyboardReplyTrigger = nil // consume (see above)
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

行为对照（spec §4）：0 waiting → resolve nil → 不动作（同现状）；**1 waiting + 无效高亮 → 进入（新）**；≥2 → 高亮必须是 waiting 行（同现状）。

- [ ] **Step 2: 编译 + 全量测试**

```bash
xcodebuild test -project Nook.xcodeproj -scheme Nook -configuration Debug \
  -derivedDataPath build/TestDerivedData -destination 'platform=macOS'
```

预期：**BUILD SUCCEEDED，全部测试 PASS**（基线 84 + 新增 10）。

- [ ] **Step 3: Commit**

```bash
git add Nook/UI/Views/SessionListView.swift
git commit -m "feat(session-list): ⌃R resolves single waiting target via KeyboardTargetResolver"
```

---

### Task 4: permission 侧 handleKeyDown 迁移到 resolver

**Files:**
- Modify: `Nook/UI/Views/SessionListView.swift:380-393`

- [ ] **Step 1: 替换 switch 块**

当前代码（:380-393，其后 `:394 guard let target else { return event }` 与 y/n/a 分发不动）：

```swift
        // Resolve target (spec §2): 0 → none; 1 → ignore highlight; 2+ → highlight must be a target
        let targets = approvalTargets
        let target: SessionState?
        switch targets.count {
        case 0:
            target = nil
        case 1:
            target = targets[0]
        default:
            let idx = viewModel.keyboardSelectedIndex // -1 = no highlight (NotchViewModel L118)
            guard idx >= 0, idx < sortedInstances.count else { return event }
            let highlighted = sortedInstances[idx]
            target = highlighted.showsInlineApprovalButtons ? highlighted : nil
        }
```

替换为（spec §3.3；`targets` 从 `rows` 派生以保持单快照，`rows.filter(\.showsInlineApprovalButtons)` 与 `approvalTargets` 定义 :214-216 等价；**注意：替换块只算出可选值，紧随其后的 `:394 guard let target else { return event }` 原样保留负责收口**，不可把 guard 写进替换块——否则会与 :394 重复绑定）：

```swift
        // Resolve target (spec §2, shared with question ⌃R via
        // KeyboardTargetResolver): 0 → none; 1 → ignore highlight;
        // 2+ → highlight must be a target. Single snapshot for idx + membership.
        let rows = sortedInstances
        let idx = viewModel.keyboardSelectedIndex // -1 = no highlight (NotchViewModel L118)
        let highlighted = (idx >= 0 && idx < rows.count) ? rows[idx] : nil
        let target: SessionState? = KeyboardTargetResolver.resolve(
            from: rows.filter(\.showsInlineApprovalButtons), highlighted: highlighted
        )
```

等价性（spec §3.1）：原 `guard idx … else { return event }` ≡ 新 `highlighted = nil` → resolve 在 2+ 返回 nil → 同一 `return event`；原 `highlighted.showsInlineApprovalButtons` ≡ 新 `sessionId ∈ filter(showsInlineApprovalButtons)`（highlighted 与 rows 同快照）。

- [ ] **Step 2: 编译 + 全量测试**

同 Task 3 Step 2 命令。预期：**BUILD SUCCEEDED，全部测试 PASS**。

- [ ] **Step 3: Commit**

```bash
git add Nook/UI/Views/SessionListView.swift
git commit -m "refactor(session-list): permission Y/N/A target resolution via shared resolver"
```

---

### Task 5: 手测（build + 启动 + 清单）

**Files:** none（验证 only）

- [ ] **Step 1: build 并启动（精确路径，单实例守卫）**

```bash
osascript -e 'tell application "Nook" to quit' 2>/dev/null
xcodebuild -project Nook.xcodeproj -scheme Nook -configuration Debug \
  -derivedDataPath build/TestDerivedData -destination 'platform=macOS' build
open build/TestDerivedData/Build/Products/Debug/Nook.app
```

预期：BUILD SUCCEEDED；`pgrep -fl "Nook.app/Contents/MacOS/Nook"` 显示单一进程。

- [ ] **Step 2: 手测清单（spec §6）**

按序验证并记录结果（触发 permission 用最小原生动作：对被拒文件 `Read`，**禁止 curl 本地 server**）：

1. **单 waiting、无高亮**：进入 session 页后**不按 ↑/↓**，直接 ⌃R → 进入该 session 的 question 页。
2. **1 waiting + 高亮非 waiting**（≥2 行时）：↑/↓ 高亮到 idle 行 → ⌃R → 仍进入 waiting 那个。
3. **≥2 waiting**（环境允许时）：高亮 waiting 行 ⌃R → 进入；高亮 idle 行 ⌃R → 不动作。
4. **0 waiting**：无 pending 的列表按 ⌃R → 无反应。
5. **permission 回归**：触发一个 permission → 行内 Y/N/A——无高亮按 Y/A 进入 1-规则目标；高亮非目标行按 Y → 不动作（对照 permission shortcuts spec 测试清单）。
6. **回归**：question 面板内 ⌃H 返回列表后 ⌃R 不应反弹（trigger 生命周期，`QuestionPanelKeyboardRoutingTests.swift` 注释场景）。

- [ ] **Step 3: 验证失败项归档**

任何一项失败：回对应 Task 的文件修复 → 重跑本 Task Step 1 → 只再验失败项。全部通过后在 PROGRESS 记一行指针（如有未尽事项）。
