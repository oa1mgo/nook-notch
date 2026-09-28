# Question 面板焦点即选择 + info 图标键位提示 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 单选题改成"焦点即选择"（⌃N/⌃P 即改选中，省掉 Space），并用一个 info 图标的 tooltip 提示当前题卡的键位。

**Architecture:** 把三条纯逻辑抽到 `Nook/UI/Views/QuestionSelection.swift`（可单测、无 SwiftUI 依赖）：焦点→选中同步、勾选视觉可见性判定、tooltip 文案生成。`QuestionPanelView` 只做状态接线：所有焦点变化入口调用同步函数，Space 单选时 no-op，info 图标走 `MenuRow` 已有的 `trailingIcon` 槽位。提交链路（`canSend` / `sendAnswers` / replyProvider）零改动。

**Tech Stack:** Swift 5 / SwiftUI (macOS) / XCTest（`@testable import Nook`）

**Spec:** `docs/specs/2026-09-28-question-focus-select-and-key-hints-design.md`

---

## File Structure

| 文件 | 责任 |
|---|---|
| `Nook/UI/Views/QuestionSelection.swift`（新建） | 三个纯函数：焦点同步、勾选可见性、tooltip 文案。无 SwiftUI import 之外的状态 |
| `Nook/UI/Views/QuestionPanelView.swift`（修改） | 接线：焦点入口调同步、Space 单选 no-op、点击跟随焦点、onAppear 初始同步、info 图标 |
| `NookTests/QuestionPanelSelectionTests.swift`（新建） | 三个纯函数的单测 |

---

## Task 1: 抽纯函数 + 单测（TDD）

**Files:**
- Create: `Nook/UI/Views/QuestionSelection.swift`
- Test: `NookTests/QuestionPanelSelectionTests.swift`
- Test: 参考现有测试写法 `NookTests/ToolCallItemVisibilityTests.swift`

- [ ] **Step 1: 写失败的测试**

创建 `NookTests/QuestionPanelSelectionTests.swift`：

```swift
import XCTest
@testable import Nook

/// Pure-function core of the question panel's "focus = selection" model for
/// single-select questions (spec 2026-09-28).
final class QuestionPanelSelectionTests: XCTestCase {

    private func question(multiple: Bool = false, custom: Bool = false) -> PendingQuestion {
        PendingQuestion(
            id: "q0",
            questionText: "Pick one",
            header: nil,
            options: [
                QuestionOption(label: "A", description: nil),
                QuestionOption(label: "B", description: nil),
                QuestionOption(label: "C", description: nil),
            ],
            multiple: multiple,
            custom: custom
        )
    }

    // MARK: - syncSingleSelection

    func testSyncReturnsFocusedLabelOnly() {
        let q = question()
        XCTAssertEqual(QuestionSelection.syncSingleSelection(q, focusedIndex: 1), ["B"])
    }

    func testSyncReturnsEmptyForMultiSelect() {
        let q = question(multiple: true)
        XCTAssertTrue(QuestionSelection.syncSingleSelection(q, focusedIndex: 1).isEmpty,
                      "multi-select keeps focus independent from selection")
    }

    func testSyncReturnsEmptyWhenFocusOutOfRange() {
        let q = question()
        XCTAssertTrue(QuestionSelection.syncSingleSelection(q, focusedIndex: 7).isEmpty,
                      "out-of-range focus must not invent a selection")
    }

    // MARK: - showsSelectionHighlight

    func testHighlightShownForPlainSingleSelect() {
        XCTAssertTrue(QuestionSelection.showsSelectionHighlight(question(), text: ""))
    }

    func testHighlightHiddenWhenCustomTextReplacesSelection() {
        XCTAssertFalse(
            QuestionSelection.showsSelectionHighlight(question(custom: true), text: "my answer"),
            "single-select + custom + text: text REPLACES the option (sendAnswers), so the checkmark would lie"
        )
    }

    func testHighlightShownForCustomWithEmptyText() {
        XCTAssertTrue(QuestionSelection.showsSelectionHighlight(question(custom: true), text: "   "))
    }

    func testHighlightShownForMultiSelectWithCustomText() {
        XCTAssertTrue(
            QuestionSelection.showsSelectionHighlight(question(multiple: true, custom: true), text: "extra"),
            "multi-select + custom: text is APPENDED to selections, both are sent"
        )
    }

    // MARK: - tooltipText

    func testTooltipForSingleSelect() {
        XCTAssertEqual(
            QuestionSelection.tooltipText(for: question()),
            "⌃N/⌃P 选择 · Enter 发送"
        )
    }

    func testTooltipForMultiSelect() {
        XCTAssertEqual(
            QuestionSelection.tooltipText(for: question(multiple: true)),
            "⌃N/⌃P 移动 · Space 选中 · Enter 发送"
        )
    }

    func testTooltipForSingleSelectCustom() {
        XCTAssertEqual(
            QuestionSelection.tooltipText(for: question(custom: true)),
            "⌃N/⌃P 选择 · Tab 输入 · Enter 发送"
        )
    }

    func testTooltipForMultiSelectCustom() {
        XCTAssertEqual(
            QuestionSelection.tooltipText(for: question(multiple: true, custom: true)),
            "⌃N/⌃P 移动 · Space 选中 · Tab 输入 · Enter 发送"
        )
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

```bash
xcodebuild test -project Nook.xcodeproj -scheme Nook -configuration Debug -derivedDataPath build/TestDerivedData -destination 'platform=macOS' -only-testing:NookTests/QuestionPanelSelectionTests 2>&1 | grep -E "error:|TEST (SUCCEEDED|FAILED)"
```

Expected: 编译失败 `cannot find 'QuestionSelection' in scope`

> 如果 Nook 正在运行导致 test runner 无法启动，先退出 Nook（单实例守卫 `AppDelegate.ensureSingleInstance`）。

- [ ] **Step 3: 实现纯函数**

创建 `Nook/UI/Views/QuestionSelection.swift`：

```swift
//  QuestionSelection.swift
//  Nook
//
//  Pure logic behind the question panel's selection model and key hints.
//  Kept free of view state so it can be unit tested (spec:
//  docs/specs/2026-09-28-question-focus-select-and-key-hints-design.md).
//
//  Single-select questions use "focus = selection": moving the focused
//  option IS the answer, so Space is a no-op there. Multi-select keeps
//  focus and selection independent (Space / click toggles).

import Foundation

enum QuestionSelection {

    /// The answer set a single-select question should hold while
    /// `focusedIndex` is focused. Empty for multi-select (no coupling) and
    /// for an out-of-range focus index (never invent a selection).
    static func syncSingleSelection(_ question: PendingQuestion, focusedIndex: Int) -> Set<String> {
        guard !question.multiple else { return [] }
        guard question.options.indices.contains(focusedIndex) else { return [] }
        return [question.options[focusedIndex].label]
    }

    /// Whether an option row should render its selected checkmark.
    /// Hides it for single-select + custom + non-empty text, because
    /// `sendAnswers` replaces the selection with the text — showing a
    /// checkmark next to the text would misrepresent what gets sent.
    static func showsSelectionHighlight(_ question: PendingQuestion, text: String) -> Bool {
        if question.custom, !question.multiple, !text.isEmpty { return false }
        return true
    }

    /// Key-hint tooltip for the current question card.
    static func tooltipText(for question: PendingQuestion) -> String {
        let move = question.multiple ? "⌃N/⌃P 移动" : "⌃N/⌃P 选择"
        var parts = [move]
        if question.multiple { parts.append("Space 选中") }
        if question.custom { parts.append("Tab 输入") }
        parts.append("Enter 发送")
        return parts.joined(separator: " · ")
    }
}
```

- [ ] **Step 4: 跑测试确认通过**

同 Step 2 的命令。Expected: `Executed 12 tests, with 0 failures` + `TEST SUCCEEDED`

- [ ] **Step 5: 提交**

```bash
git add Nook/UI/Views/QuestionSelection.swift NookTests/QuestionPanelSelectionTests.swift
git commit -m "refactor(question): extract selection + key-hint pure functions"
```

---

## Task 2: 接线"焦点即选择"

**Files:**
- Modify: `Nook/UI/Views/QuestionPanelView.swift`
  - `onAppear`（:156-168）—— 初始同步
  - `singleQuestionCard` 的 pager chevron（:112-125）—— 切题同步
  - `moveFocusUp` / `moveFocusDown`（:437-447）—— 焦点同步
  - `goNextQuestion` / `goPreviousQuestion`（:449-461）—— 切题同步
  - `handleKeyDown` 的 Space 分支（:412-417）—— 单选 no-op
  - `optionsList`（:199-217）—— 点击跟随焦点 + 勾选可见性
  - `toggleOption`（:466-480）—— 点击时同步焦点

- [ ] **Step 1: 加一个同步 helper（放在 `toggleOption` 之前）**

在 `QuestionPanelView` 里 `// MARK: - Actions` 段内、`toggleOption` 之前插入：

```swift
    /// Keep the single-select answer in lockstep with the focused option
    /// (spec 2026-09-28: single-select is "focus = selection"). No-op for
    /// multi-select — there focus and selection are independent.
    private func syncSelectionToFocus(questionIndex: Int) {
        guard pendingQuestions.indices.contains(questionIndex) else { return }
        let synced = QuestionSelection.syncSingleSelection(
            pendingQuestions[questionIndex],
            focusedIndex: focusedOptionIndex
        )
        if synced.isEmpty {
            // Multi-select: never clobber the user's explicit choices.
            return
        }
        selectedAnswers[questionIndex] = synced
    }
```

- [ ] **Step 2: `moveFocusUp` / `moveFocusDown` 调用同步**

把现有的：

```swift
    private func moveFocusUp() {
        let count = pendingQuestions[currentIndex].options.count
        guard count > 0 else { return }
        focusedOptionIndex = focusedOptionIndex > 0 ? focusedOptionIndex - 1 : count - 1
    }

    private func moveFocusDown() {
        let count = pendingQuestions[currentIndex].options.count
        guard count > 0 else { return }
        focusedOptionIndex = focusedOptionIndex < count - 1 ? focusedOptionIndex + 1 : 0
    }
```

替换为（各加一行同步调用）：

```swift
    private func moveFocusUp() {
        let count = pendingQuestions[currentIndex].options.count
        guard count > 0 else { return }
        focusedOptionIndex = focusedOptionIndex > 0 ? focusedOptionIndex - 1 : count - 1
        syncSelectionToFocus(questionIndex: currentIndex)
    }

    private func moveFocusDown() {
        let count = pendingQuestions[currentIndex].options.count
        guard count > 0 else { return }
        focusedOptionIndex = focusedOptionIndex < count - 1 ? focusedOptionIndex + 1 : 0
        syncSelectionToFocus(questionIndex: currentIndex)
    }
```

- [ ] **Step 3: `goNextQuestion` / `goPreviousQuestion` 调用同步**

```swift
    private func goNextQuestion() {
        guard currentIndex < pendingQuestions.count - 1 else { return }
        currentIndex += 1
        focusedOptionIndex = 0
        isTextFieldFocused = false
        syncSelectionToFocus(questionIndex: currentIndex)
    }

    private func goPreviousQuestion() {
        guard currentIndex > 0 else { return }
        currentIndex -= 1
        focusedOptionIndex = 0
        isTextFieldFocused = false
        syncSelectionToFocus(questionIndex: currentIndex)
    }
```

- [ ] **Step 4: pager chevron 点击同步（`currentIndex` 直接 ±1 的两条路径）**

在 `singleQuestionCard` 里把两个 `PagerChevronButton` 的 action 改为调用新的走位方法（避免 `currentIndex` 直接变动漏同步）：

```swift
                        PagerChevronButton(systemImage: "chevron.left", disabled: currentIndex == 0) {
                            goPreviousQuestion()
                        }
                        .help("Ctrl+[ Previous question")
```

```swift
                        PagerChevronButton(systemImage: "chevron.right", disabled: currentIndex == pendingQuestions.count - 1) {
                            goNextQuestion()
                        }
                        .help("Ctrl+] Next question")
```

> `goPreviousQuestion` / `goNextQuestion` 内部已有 `guard currentIndex > 0` / `< count - 1`，与 `disabled:` 条件一致，语义不变。

- [ ] **Step 5: `onAppear` 初始同步**

在 `onAppear` 现有的 focus 越界重置之后加一行：

```swift
            if focusedOptionIndex >= pendingQuestions[currentIndex].options.count {
                focusedOptionIndex = 0
            }
            syncSelectionToFocus(questionIndex: currentIndex)
```

- [ ] **Step 6: Space 在单选时 no-op**

把 `handleKeyDown` 的 Space 分支：

```swift
        // ── Space: toggle selection ──
        if event.keyCode == 49 && !hasCtrl && !hasShift { // Space
            let q = pendingQuestions[currentIndex]
            guard focusedOptionIndex < q.options.count else { return event }
            toggleOption(questionIndex: currentIndex, label: q.options[focusedOptionIndex].label)
            return nil
        }
```

替换为：

```swift
        // ── Space: toggle selection (multi-select only) ──
        if event.keyCode == 49 && !hasCtrl && !hasShift { // Space
            let q = pendingQuestions[currentIndex]
            guard focusedOptionIndex < q.options.count else { return event }
            // Single-select is "focus = selection" — toggling would clear the
            // answer while focus stays put, breaking the invariant.
            if !q.multiple { return nil }
            toggleOption(questionIndex: currentIndex, label: q.options[focusedOptionIndex].label)
            return nil
        }
```

- [ ] **Step 7: 点击时焦点跟随选择**

把 `optionsList` 里 OptionRow 的 action：

```swift
                ) {
                    toggleOption(questionIndex: questionIndex, label: option.label)
                }
```

替换为：

```swift
                ) {
                    focusedOptionIndex = optIndex
                    toggleOption(questionIndex: questionIndex, label: option.label)
                }
```

- [ ] **Step 8: `optionsList` 应用勾选可见性**

把 `optionsList` 的开头两行：

```swift
        let q = pendingQuestions[questionIndex]
        let selected = selectedAnswers[questionIndex] ?? []
```

替换为：

```swift
        let q = pendingQuestions[questionIndex]
        let selected = selectedAnswers[questionIndex] ?? []
        // Single-select + custom + text: the text REPLACES the selection on
        // send, so don't show a checkmark next to it.
        let showHighlight = QuestionSelection.showsSelectionHighlight(
            q,
            text: freeTexts[questionIndex] ?? ""
        )
```

再把 `isSelected` 的计算：

```swift
                let isSelected = selected.contains(option.label)
```

替换为：

```swift
                let isSelected = showHighlight && selected.contains(option.label)
```

- [ ] **Step 9: build 验证**

```bash
xcodebuild -project Nook.xcodeproj -scheme Nook -configuration Debug -destination 'platform=macOS' build 2>&1 | grep -E "error:|BUILD"
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 10: 跑全部测试**

```bash
xcodebuild test -project Nook.xcodeproj -scheme Nook -configuration Debug -derivedDataPath build/TestDerivedData -destination 'platform=macOS' 2>&1 | grep -E "Executed .* tests|TEST (SUCCEEDED|FAILED)"
```

Expected: `TEST SUCCEEDED`，0 failures

- [ ] **Step 11: 提交**

```bash
git add Nook/UI/Views/QuestionPanelView.swift
git commit -m "feat(question): single-select follows focus (Space is multi-select only)"
```

---

## Task 3: info 图标 + 动态 tooltip

**Files:**
- Modify: `Nook/UI/Views/QuestionPanelView.swift`（`backRow` :89-99）

- [ ] **Step 1: 给 backRow 加 info 图标**

把 `backRow`：

```swift
    private var backRow: some View {
        MenuRow(
            icon: "chevron.left",
            label: "Back",
            trailingIcon: nil,
            primaryTextColor: .white,
            isFocused: false,
            action: onClose
        )
        .padding(.bottom, 6)
    }
```

替换为（复用 `MenuRow` 已有的 `trailingIcon` 槽位，不改组件；tooltip 挂在 MenuRow 上以便 hover 整个 Back 行都触发）：

```swift
    private var backRow: some View {
        MenuRow(
            icon: "chevron.left",
            label: "Back",
            trailingIcon: pendingQuestions.isEmpty ? nil : "info.circle",
            primaryTextColor: .white,
            isFocused: false,
            action: onClose
        )
        .padding(.bottom, 6)
        .help(pendingQuestions.isEmpty ? "" : QuestionSelection.tooltipText(for: pendingQuestions[currentIndex]))
    }
```

> 高度影响：`info.circle` 复用 trailingIcon 槽位，10–11pt 符号低于 Back 行的 11pt 文字行高，`NotchViewModel.questionContentHeight` 的 `backRowHeight = 63` 不需要改（spec §3 硬约束：只有必须新增行时才动公式）。

- [ ] **Step 2: build 验证**

同 Task 2 Step 9。Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: 跑全部测试**

同 Task 2 Step 10。Expected: `TEST SUCCEEDED`

- [ ] **Step 4: 提交**

```bash
git add Nook/UI/Views/QuestionPanelView.swift
git commit -m "feat(question): key-hint info icon with per-card tooltip"
```

---

## Task 4: 手测验证

**Files:** 无改动

- [ ] **Step 1: 启动 app**

```bash
xcodebuild -project Nook.xcodeproj -scheme Nook -configuration Debug -destination 'platform=macOS' build && open ~/Library/Developer/Xcode/DerivedData/Nook-*/Build/Products/Debug/Nook.app
```

- [ ] **Step 2: 单选题验证**

触发一个 AskUserQuestion（agent 调 question 工具即可）→ 点标题确认是单选题（无"可多选"胶囊）：

- ⌃N/⌃P 移动时，被聚焦的选项**立即**出现勾选/绿色高亮
- Space 按下**无任何变化**（不取消选中）
- Enter 提交
- 面板打开瞬间（未按键）第一项已选中

- [ ] **Step 3: 多选题验证（不回归）**

- ⌃N/⌃P 移动焦点**不**改变选中
- Space 切换选中；点击选项切换选中
- Enter 提交

- [ ] **Step 4: custom 题验证**

- Tab 进输入框打字 → 选项的勾选/绿色高亮消失（单选）；清空文字 → 恢复
- 多选 + custom 打字 → 勾选保留（文字是追加）
- Tab 退出输入框后 ⌃N/⌃P 重新控制选项焦点

- [ ] **Step 5: 切题与 tooltip**

- 多题时用 `‹ ›` 按钮和 ⌃[/⌃] 切题，新题卡（单选）自动选中第一项
- 切题后单选/多选/cust文案正确切换
- **面板高度全程无跳变**（info 图标未改变 backRow 行高）
- 旧行为回归：⌃H 回列表、Esc 关闭、⌃N/⌃P 焦点移动

- [ ] **Step 6: 记录结果**

用 `/progressing` 把本条工作记入 PROGRESS.md 的 Verify 段（`Awaiting: 用户手测确认`），再收工。
