# Question 面板：单选"焦点即选择" + info 图标键位提示

- **日期**: 2026-09-28
- **状态**: 已确认（设计阶段完成，待实现）
- **关联**: `docs/specs/2026-09-02-question-tool-notch-prompt-design.md`（面板本体）、键盘路由修复 commit `30385dd`

## 背景

Question 面板当前的键盘交互是"焦点 + 选中"两状态模型：

- ⌃N/⌃P（及 ↑/↓）移动 `focusedOptionIndex` 焦点，**不改**选中
- Space toggle `selectedAnswers` 选中，Enter（canSend 门控）提交全部
- 单选、多选行为一致；鼠标点击 = toggle 选中但不发送
- 面板的键位提示只有零散的 `.help` tooltip：Send 按钮 / text field，以及选项行的 `Space to select · Enter to send`（后者在本变更后对单选失效——见 §3）

问题：单选题需要"⌃N 移到目标 → Space 选中 → Enter 提交"三步，Space 这一步在单选场景是冗余的（焦点已经落在目标上还要再确认一次）；且新用户不知道有键盘操作。

## 决策

**方案 1（焦点即选择）+ info 图标 tooltip 提示**。放弃了：

- Enter 逐题 wizard（Enter 语义随"是否最后一题"变化，且与 text field 的 `onSubmit` 直接全提交冲突）
- 字母键 A/B/C 直选（单选仍要两步没省；与 custom 打字冲突）
- 常驻文字提示（面板空间寸土寸金；info 图标 + hover 足够）

## 详细设计

### 1. 选中模型（QuestionPanelView）

**单选题（`!multiple`）——焦点即选择**：

- 焦点变化的所有路径同步选中。**必须覆盖以下全部入口**（缺一即出现"焦点在 B、选中在 A"的不一致）：
  - `moveFocusUp` / `moveFocusDown`（⌃N/⌃P、↑/↓）
  - `goNextQuestion` / `goPreviousQuestion`（⌃[、⌃] 键盘切题）
  - **pager chevron 点击**（`singleQuestionCard` 的两个 `‹ ›` 按钮 —— 实现上已改为调用 `goPreviousQuestion`/`goNextQuestion`，与 ⌃[/⌃] 统一入口，顺带统一了切题时的焦点重置；勿再留 `currentIndex ±= 1` 的裸赋值路径）
  - `onAppear` 的 focus 越界重置处（:165）—— 初始 `focusedOptionIndex = 0` 必须在 onAppear 同步，否则首帧 canSend=false 直到用户动一次
- 不变量：
  `selectedAnswers[i] == [options[focusedOptionIndex].label]`
- **Space 变为 no-op**（吞掉事件）：保留 toggle 会清空选中、破坏"焦点=选中"不变量
- **鼠标点击**：`focusedOptionIndex` 跟随点击项；**单选点击走同步（`syncSelectionToFocus`）而非 toggle** —— 点已选中项保持选中，点其他项切换选中，任何点击都不清空答案（toggle 的 remove 分支对单选不可达，`toggleOption` 仅限多选）
- **text field 聚焦时**（Tab 进入 custom 输入）：⌃N/⌃P 维持现状 —— 走 `isTextFieldFocused` 分支交给文本框原生光标移动，不移动选项焦点、不改选中

**多选题：完全不变**（焦点≠选中，Space/点击 toggle）。

**Enter / canSend / sendAnswers：完全不变**（Enter 始终 = 提交全部）。

### 2. custom 视觉同步（纯视觉，不动提交逻辑）

提交语义（现状，`sendAnswers`）：单选 + custom + 文字非空 → **文字替换选项**；多选 → 文字追加。

当 单选 + custom + 当前题文字非空时：选项的勾选/绿色高亮**隐藏**，只保留焦点高亮 —— 消除"勾着 A 又填了文字但实际只提交文字"的视觉不一致。数据层选中态不动（反正被覆盖）。判定抽纯函数（如 `showsSelectionHighlight(question:text:)`）。

### 3. 键位提示（info 图标 + tooltip）

- `backRow` **内部**（MenuRow 右侧的 Spacer 之间）放 `info.circle` SF Symbol（11pt，`white.opacity(0.4)`）。注意多题时 pager `‹ 1/2 ›` 以 `.trailing` 叠加在同一行（`singleQuestionCard` 的 ZStack），info 图标必须留在 backRow 内、pager 左侧，不能共用 trailing 位置
- 悬停显示 `.help` tooltip，文案按**当前题卡**动态生成：
  - 单选（非 custom）：`⌃N/⌃P 选择 · Enter 发送`
  - 多选（非 custom）：`⌃N/⌃P 移动 · Space 选中 · Enter 发送`
  - 单选 + custom：`⌃N/⌃P 选择 · Tab 输入 · Enter 发送`
  - 多选 + custom：`⌃N/⌃P 移动 · Space 选中 · Tab 输入 · Enter 发送`
- **不新增行 → 不改 `NotchViewModel.questionContentHeight` 高度公式**（`backRowHeight = 63` 已含 MenuRow + pager，11pt 图标在行内不改变行高）。硬约束：若实现时图标放不下必须新增行，则必须同步 NotchViewModel 的 `questionContentHeight`（SOI，见 `docs/specs/2026-07-07-picker-height-and-broadcast-pattern.md`）
- **选项行 `OptionRow` 的 `.help` 同步改动态**（Space 对单选失效后的 stale 提示）：keyHint 前缀按题型——单选 `⌃N/⌃P 选择`、多选 `Space 选中`，OptionRow 内拼 `· Enter 发送`，与 info tooltip 用词一致（中文）。前缀抽纯函数 `QuestionSelection.rowKeyHint(for:)`（SOI，字面量不得跨文件重复）
- 不做点击 popover（YAGNI）

### 4. 不做什么（YAGNI）

- 字母键直选、Enter 逐题跳转、常驻文字提示、点击弹 popover
- 多选题的任何交互改动
- 提交链路（canSend / sendAnswers / replyProvider）零改动

## 测试

- 抽三个纯函数并单测（`QuestionPanelSelectionTests`）：
  1. `syncSingleSelection`：互斥、越界/负数 focus 返回空、切题与初始选中第一项（由调用方接线）
  2. `showsSelectionHighlight`：custom+文字非空（trim 后）→ false，其余 → true；多选恒 true
  3. `tooltipText`：四种文案组合逐条锁定
- 手测清单：
  - 单选 ⌃N/⌃P 即改选中；Space 无反应；Enter 提交
  - 多选：焦点移动不改选中、Space toggle、点击 toggle —— 与改动前一致
  - custom 单选打字后勾选消失、清空文字后勾选恢复
  - info 图标 tooltip 四种文案随题卡切换；面板高度无跳变
  - ⌃[、⌃] 切题后新题卡自动选中第一项（单选）
