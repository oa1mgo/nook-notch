# Question 面板焦点即选择 + info 图标键位提示 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 单选题改成"焦点即选择"（⌃N/⌃P 即改选中，省掉 Space），并用一个 info 图标的 tooltip 提示当前题卡的键位。

**Architecture:** 把三条纯逻辑抽到 `Nook/UI/Views/QuestionSelection.swift`（可单测、不依赖 view state）：焦点→选中同步、勾选视觉可见性判定、tooltip 文案生成。`QuestionPanelView` 只做状态接线：所有焦点变化入口调用同步函数，Space 单选时 no-op，info 图标放进 back-row 已有的 ZStack overlay HStack（pager 左侧）。提交链路（`canSend` / `sendAnswers` / replyProvider）零改动。

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
    /// `sendAnswers` trims before testing emptiness, so trim here too
    /// (otherwise a whitespace-only answer would hide the checkmark while
    /// the option is still what gets submitted).
    static func showsSelectionHighlight(_ question: PendingQuestion, text: String) -> Bool {
        if question.custom, !question.multiple,
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return false
        }
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

同 Step 2 的命令。Expected: `Executed 11 tests, with 0 failures` + `TEST SUCCEEDED`

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

> `goPreviousQuestion` / `goNextQuestion` 内部已有 `guard currentIndex > 0` / `< count - 1`，与 `disabled:` 条件一致，翻页守卫语义不变。
> **有意的行为变化**：pager 点击现在会同时 `focusedOptionIndex = 0`、`isTextFieldFocused = false`（原来只 `currentIndex ±= 1`、焦点保留）——pager 点击与 ⌃[/⌃] 键盘切题从此走同一条路径，单选同步才有保证（spec 切题节：焦点重置为 0 → 同步选中第一项）。

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

> 若 Nook.app 正在运行会占住单实例，test host 起不来（`BUG_IN_CLIENT_OF_LIBMALLOC` / bootstrap error）。先退出再跑：`osascript -e 'tell application "Nook" to quit' 2>/dev/null; sleep 1`

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
- Modify: `Nook/UI/Views/QuestionPanelView.swift`（`singleQuestionCard` 的 ZStack overlay :108-129 + OptionRow keyHint）
- Modify: `Nook/UI/Views/QuestionSelection.swift`（新增 `rowKeyHint(for:)`，SOI）
- Test: `NookTests/QuestionPanelSelectionTests.swift`（`rowKeyHint` 两个用例）

> ⚠️ **不能用 `MenuRow` 的 `trailingIcon` 槽位**——它渲染在 MenuRow 内部右侧（NotchMenuView.swift:852-853），而多题时 pager overlay 也以 `.trailing` 叠在同一位置，会互相盖住。info 图标必须进 **overlay 的 HStack**，放在 pager 左侧（spec §3："backRow 内、pager 左侧"）。

- [ ] **Step 1: 给 back-row 的 overlay 加 info 图标**

把 `singleQuestionCard` 开头的 ZStack（此时已是 Task 2 Step 4 改过 chevron 调用之后的状态）：

```swift
            ZStack(alignment: .trailing) {
                backRow
                if pendingQuestions.count > 1 {
                    HStack(spacing: 6) {
                        PagerChevronButton(systemImage: "chevron.left", disabled: currentIndex == 0) {
                            goPreviousQuestion()
                        }
                        .help("Ctrl+[ Previous question")

                        Text("\(currentIndex + 1)/\(pendingQuestions.count)")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.white.opacity(0.85))
                            .fixedSize()

                        PagerChevronButton(systemImage: "chevron.right", disabled: currentIndex == pendingQuestions.count - 1) {
                            goNextQuestion()
                        }
                        .help("Ctrl+] Next question")
                    }
                    .padding(.trailing, 12)
                }
            }
```

替换为：

```swift
            ZStack(alignment: .trailing) {
                backRow
                HStack(spacing: 6) {
                    if !pendingQuestions.isEmpty {
                        Image(systemName: "info.circle")
                            .font(.system(size: 11))
                            .foregroundColor(.white.opacity(0.4))
                            .fixedSize()
                            .help(QuestionSelection.tooltipText(for: pendingQuestions[currentIndex]))
                    }
                    if pendingQuestions.count > 1 {
                        PagerChevronButton(systemImage: "chevron.left", disabled: currentIndex == 0) {
                            goPreviousQuestion()
                        }
                        .help("Ctrl+[ Previous question")

                        Text("\(currentIndex + 1)/\(pendingQuestions.count)")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.white.opacity(0.85))
                            .fixedSize()

                        PagerChevronButton(systemImage: "chevron.right", disabled: currentIndex == pendingQuestions.count - 1) {
                            goNextQuestion()
                        }
                        .help("Ctrl+] Next question")
                    }
                }
                .padding(.trailing, 12)
            }
```

> 变化点：HStack 从"多题才渲染"改为无条件渲染（单题时只含 info 图标），`.padding(.trailing, 12)` 从多题分支挪到 HStack 上。`backRow` 本身（:89-99）**不动**。
> 高度影响：info 是 overlay 元素，位于已有 backRow 行内右侧，不改变行高，`NotchViewModel.questionContentHeight` 的 `backRowHeight = 63` 不改（spec §3 硬约束：只有必须新增行时才动公式）。

- [ ] **Step 2: `OptionRow` 的 `.help` 按题型动态（Space 对单选失效后的 stale 提示）**

`QuestionPanelView` 底部的 `private struct OptionRow` 目前硬编码 `.help("Space to select · Enter to send")`（:626），但单选下 Space 已是 no-op。

给 OptionRow 加参数（放在 `let isSending: Bool` 之后、`let action` 之前）：

```swift
    let isSending: Bool
    /// Key-hint for this row's hover tooltip; single-select differs from
    /// multi-select because Space is a no-op there (focus = selection).
    let keyHint: String
    let action: () -> Void
```

把 help 行：

```swift
        .help("Space to select · Enter to send")
```

替换为：

```swift
        .help("\(keyHint) · Enter 发送")
```

`optionsList` 里的调用点加参数（`isSending: isSending` 之后）—— keyHint 前缀走 Task 1 同文件的纯函数（SOI，字面量不得跨文件重复）：

```swift
                    isSending: isSending,
                    keyHint: QuestionSelection.rowKeyHint(for: q),
```

并在 `Nook/UI/Views/QuestionSelection.swift` 的 `enum QuestionSelection` 里新增（`tooltipText` 之前）：

```swift
    /// Per-row key hint prefix: single-select teaches the focus=select key,
    /// multi-select teaches the toggle key. The caller appends "· Enter 发送".
    static func rowKeyHint(for question: PendingQuestion) -> String {
        question.multiple ? "Space 选中" : "⌃N/⌃P 选择"
    }
```

（单选提示 ⌃N/⌃P、多选提示 Space；`· Enter 发送` 由 OptionRow 内拼接，两个题型共用，用词与 info tooltip 一致。）

- [ ] **Step 3: build 验证**

同 Task 2 Step 9。Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: 跑全部测试**

同 Task 2 Step 10。Expected: `TEST SUCCEEDED`

- [ ] **Step 5: 提交**

```bash
git add Nook/UI/Views/QuestionPanelView.swift
git commit -m "feat(question): key-hint info icon with per-card tooltip"
```

---

## Task 4: 切题焦点记忆（用户反馈修正）

**背景**: 用户确认"切走再切回把已选项重置为第一项"是错误行为。原实现 `goNext/PreviousQuestion` 无条件 `focusedOptionIndex = 0` → 同步覆盖选中。改为 per-question 焦点记忆：离开时保存、进入时恢复（无记忆才归 0）。spec §1 已同步更新。

**Files:**
- Modify: `Nook/UI/Views/QuestionPanelView.swift`（`@State` 声明区 + `goNextQuestion` / `goPreviousQuestion`）

- [ ] **Step 1: 加焦点记忆状态**（`focusedOptionIndex` 声明旁）:

```swift
    @State private var focusedOptionIndex: Int = 0
    /// Per-question focus memory: leaving a card saves its focus here,
    /// entering restores it (0 only for a card never visited).
    @State private var savedFocusByQuestion: [Int: Int] = [:]
```

- [ ] **Step 2: `goNextQuestion` / `goPreviousQuestion` 保存+恢复**

替换为:

```swift
    private func goNextQuestion() {
        guard currentIndex < pendingQuestions.count - 1 else { return }
        savedFocusByQuestion[currentIndex] = focusedOptionIndex
        currentIndex += 1
        focusedOptionIndex = savedFocusByQuestion[currentIndex] ?? 0
        isTextFieldFocused = false
        syncSelectionToFocus()
    }

    private func goPreviousQuestion() {
        guard currentIndex > 0 else { return }
        savedFocusByQuestion[currentIndex] = focusedOptionIndex
        currentIndex -= 1
        focusedOptionIndex = savedFocusByQuestion[currentIndex] ?? 0
        isTextFieldFocused = false
        syncSelectionToFocus()
    }
```

（首题卡从未访问过 → `?? 0` → 同步选中第一项；访问过 → 恢复焦点 → 同步恢复原选中。多选：sync 不写选中，仅焦点恢复。）

- [ ] **Step 3: build + 测试**

Build 预期 `** BUILD SUCCEEDED **`；测试预期 `TEST SUCCEEDED`、84 tests（命令同前，测试前先 quit Nook.app）。

- [ ] **Step 4: 提交**

```bash
git add Nook/UI/Views/QuestionPanelView.swift
git commit -m "fix(question): remember per-question focus across navigation"
```

---

## Task 5: 手测验证

**Files:** 无改动

- [ ] **Step 1: 启动 app**

> 路径必须精确：`Nook-*` 通配会匹配多份 DerivedData（用户 Xcode Run 的 + xcodebuild 默认的），而单实例守卫（`AppDelegate.ensureSingleInstance`）会让**后启动的实例直接退出**——旧 build 会挡住新 build。与测试命令统一用 `build/TestDerivedData`，再先退出旧实例。

```bash
xcodebuild -project Nook.xcodeproj -scheme Nook -configuration Debug -derivedDataPath build/TestDerivedData -destination 'platform=macOS' build \
  && osascript -e 'tell application "Nook" to quit' 2>/dev/null; sleep 1; \
  open build/TestDerivedData/Build/Products/Debug/Nook.app
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

- 多题时用 `‹ ›` 按钮和 ⌃[/⌃] 切题：**首次**进入的题（单选）自动选中第一项；**切走再切回，离开前的选中保留**，不被重置为第一项
- 切题后单选/多选/cust文案正确切换
- **面板高度全程无跳变**（info 图标未改变 backRow 行高）
- 旧行为回归：⌃H 回列表、Esc 关闭、⌃N/⌃P 焦点移动

- [ ] **Step 6: 记录结果**

用 `/progressing` 把本条工作记入 PROGRESS.md 的 Verify 段（`Awaiting: 用户手测确认`），再收工。
