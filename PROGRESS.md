# Progress

> Last updated: 2026-07-08 (picker sub-row per-row heights)

## 🎯 Current Focus
<!-- 2026-07-08 **picker 子项无 sub desc 时高度/垂直对齐修复**：
  - **症状**：Screen picker 展开时非 built-in / 非 main 的屏幕行 + Claude dir picker 中 "Choose folder…" 行（未选自定义路径时），`sublabel == nil` 但 `verticalSublabel: true` 强制 `SettingsSubPickerRow` 渲染 41pt 高 + 13pt `Color.clear` 占位 → 标题"上浮"，底部留空白。
  - **根因**：编译期 `pickerLayout.rowHeight` 是单一常量 `settingsSubPickerRowVerticalSublabelHeight`，但运行时不同行的 sublabel 实际有/无是数据驱动的，无法对齐。
  - **修复**（4 文件，纯逻辑改动）：
    1. `SettingsSubPickerRow` 引入 `showsVerticalSublabel = verticalSublabel && sublabel != nil`，无 sublabel 时自动回落小尺寸 (~27pt) + 标题垂直居中（删除原 Color.clear 占位）。
    2. `PickerLayout` 支持每行独立高度 `init(rowHeights: [CGFloat])`，保留原 `init(rowCount:rowHeight:)` 作为同构 picker 的便捷 init。`rowCount` 派生自 `rowHeights.count`，`expandedHeight` = `reduce(+) + (n-1)*spacing + topPadding`。
    3. `ScreenPickerRow.pickerLayout` 把 `screenSublabel(for:)` 提升为 `static` 调用，按屏 sublabel 是否非 nil 决定该行高度（`[auto, screen1, screen2, ...]`）；automatic 行永远 sublabel 非 nil → 高列。
    4. `AgentSettingsView.claudeDirPickerLayout` 从 `static` 转 `private var`，读 `isCustomClaudeDir` 决定 "Choose folder…" 行高度；`agentsContentHeight` 从增量 `+=`/`-=` 改成派生 `viewModel.agentsBaseHeight + (expanded ? layout : 0)` 全量重算，同步新增 `.onChange(of: currentClaudeDir)` 兜底用户在 picker 打开状态下切换路径的高度漂移。
  - **panel 高度不变**(行高之和相同或更小,不会 overshoot);scrollbar flicker 保护不变(`baseHeightRecorded` 仍只接受首次 GeometryReader 报告)。
  - **未来 picker 集成**：当调用方传的 sublabel 表达式含条件/可选数据时,直接用 `PickerLayout(rowHeights:)` 而不是同构 init。详见 spec `docs/specs/2026-07-07-picker-height-and-broadcast-pattern.md` 的 "rowHeight 必须匹配"`+ 新增的内部 `showsVerticalSublabel` 注释。
  - **build 验证**：`xcodebuild -project Nook.xcodeproj -scheme Nook -configuration Debug build` 通过。-->

## 📥 Next Phases
<!-- 下一步候选，按优先级 -->
1. **customIcon 类型优化**（2026-06-23 用户决议）— 当前 `AnyView?` 的 type-erase 成本可忽略，但 `some View` 或 generic 形式更优雅。备选方向见 2026-06-23 Context Notes。
2. **Critical #3** — `createMinimalConfig()` 在 JSON 损坏时会覆盖原文件，先备份再覆盖更安全
3. **yabai 缺失的 UX 提示**（来自 2026-06-17 用户反馈）— 没装 yabai 时 fallback 能工作但精度低。考虑设置页加说明或失败时一次性提示
4. **Bug J 长期监控**（见 Blockers）— 当前 0 复现但保留诊断 log
5. **(长期) picker-panel-height redesign**（2026-07-01 spec）— 取消 GeometryReader 反馈回路 + visualIsExpanded + Task cancellation 复杂方案。**当前不触发**(flicker 在 16pt buffer 下是偶发,不是必闪),但如果用户重新对 14pt 空白有强烈抱怨,或 macOS 更新让 NSScroller gutter 行为变化,需重新评估。Spec 已存档决策档案。

## ⏸️ Paused Tasks
| Task | 状态 | 阻塞点 / 入口 |
| --- | --- | --- |
| #78 Bug H | Fix 2 已 commit，等实战验证 | TrailingEchoDetector 覆盖 handleTextPart + handlePartDelta 两条路径。验证方法：等 bug 自然触发时检查日志是否有 `→ text part suppressed (trailing-echo)` 或 `→ text delta suppressed (trailing-echo accumulated)` |
| #79 Bug I | 诊断已就位，race 未被证实 | 3 条诊断 log 已部署。当前 opencode v1.15.13 下 `⚠ DIAG #79` 从未命中，`subagent routing HIT` 正常工作。保留诊断作为基线，暂不修复 |
| customIcon type | 2026-06-23 用户决议延后 | AnyView? → `some View` 或 generic MenuRow<Icon: View>。brandIcon 的 switch-case 需要 type-erase 仍然是最大阻力。详见 Context Notes |

## ✅ Recently Completed
- **2026-07-08 focus 修复 + ⌃O 关 notch + ChatView 日志/文案清理 (1.3.2)** — 三个改动一起:
  - **focus 修复（核心）**：`NotchViewModel.notchClose(restorePreviousApp: Bool = false)`。默认 `false`（安全），快捷键路径（`handleShortcutAction` 的 `.toggleNotch`/`.closeNotch` 分支）显式传 `true`。**关键细节：`previousActiveApp` 在每次 close 时无条件清空**，否则鼠标关闭会留下陈旧引用 → 下次快捷键关闭恢复到错的 app。`restoreFocus()` 私有方法删除（内联到 notchClose 末尾）。
  - **副作用：ChatView 隐藏 bug 顺手修了**：`focusTerminal()` 成功后 `notchClose()` 默认不再恢复焦点 → 终端保持焦点（之前 `restoreFocus()` 会撤销 tryFocusTerminal 的成果，把焦点拽回 Nook 之前的 app）。日志从 `"closing notch and restoring focus"` 改成 `"closing notch (terminal keeps focus)"`，注释里说明依赖 `notchClose` 默认 `false`。
  - **⌃O 关 notch**：`MusicCardView` 增加 `onOpenSourceApp: () -> Void` 闭包参数（不传 viewModel，避免耦合），`SessionListView.handleOpenMusicSource()` 内部做 `openSourceApp() + notchClose()`。artwork 点击和 ⌃O 两条路径都走闭包，行为一致。顺序：先 `openSourceApp()`（用户意图），后 `notchClose()`（默认 `restorePreviousApp: false`，不抢焦点）。
  - **ChatView 中英混排清理**：`focusErrorMessage = "无法聚焦终端..."` 翻成 `"Couldn't focus terminal. Switch to it manually (session.pid missing or terminal app not in the known list)."`。文件内其他中文用户文案未触及（本次范围外）。
  - **版本**：1.3.1 → 1.3.2（patch，纯 bug fix / UX polish），`project.pbxproj` 2 处 + `RELEASE_NOTES.md` 新增 `## 1.3.2` 段。
  - **build 验证**：xcodebuild Debug 通过。
- **2026-07-07 picker-pattern spec + 清理诊断 print（防止下一个人再踩坑）** — 把这一轮 4 个 bug(A panel 收缩了底部空白 / B claude dir picker 展开后空白 / C menu 页 picker 状态跨页保留 / D agents 页 claude dir picker 再进入高度错)沉淀为新增 picker 的强制规则。**新增 spec** `docs/specs/2026-07-07-picker-height-and-broadcast-pattern.md` 列出"必须做 3 件 + 绝不能做 3 件"清单 + 调试 checklist,**所有改动只动注释和新增文件,不动现有 picker 逻辑**(确保用户已经确认工作的方案不被回滚)。
  - **必须做 ✅**：(1) `PickerLayout` 编译期公式声明展开高度,`rowHeight` 必须和 row 实际 `verticalSublabel` 严格匹配(否则 overshoot 28pt);(2) picker 的 `frame(height:)` 走 `ExpandableSettingsRow` 内部 `withTransaction(\.disablesAnimations)` 瞬时设置,**不要**重新发明;(3) `NotchMenuView` 上的 picker `onToggle` 必须**第一行 `markExplicitSet()` + 第二行 `viewModel.menuContentHeight = menuContentHeight`**,键盘路径同理。
  - **绝不能做 ❌**：(1) **不要**用 GeometryReader 测量 picker 高度后写回 viewModel(9 次 flicker 修复的根源);(2) **不要**在 picker `onToggle` 之外的地方调高度(绕过 markExplicitSet);(3) **不要**把 picker 状态放在 viewModel 但不在 navigation API EXIT 路径重置(跨页带过去导致 panel 高度 = 展开 + picker 状态 = 折叠 → 底部空白)。
  - **两层防御不可互换**:menu 页用时间门控(markExplicitSet + handleMeasuredContentHeight),agents 页用导航 API 重置(pushTo/navigateBack/toggleMenu),各自有清晰的设计理由。spec 里完整说明。
  - **清理诊断 print**:`NotchMenuView` 的 `[onToggle]` × 3 + `[broadcast]` × 2 全部删除(共 5 处);保留 `AgentSettingsView` 的 `[agents-pref]`(有意保留做 scrollbar 可见性长期监控)。launch-at-login 错误日志无关,未动。
  - **验证**:xcodebuild 通过(代码逻辑零改动,只是移除 print 和加注释)。
- **2026-07-07 picker 末尾 hover 圆角矩形被裁 + SwiftUI Text 渲染高度修正** — 三层根因串行修：
  1. header 1pt：`NotchViewModel.openedSize.menu` 用 `max(24, deviceNotchRect.height)` 替代硬编码 `settingsPageHeaderHeight=24`（commit `9f4cd61`）
  2. padding 8pt：`SettingsPageLayout.swift` `settingsSubPickerRowHeight` / `settingsSubPickerRowVerticalSublabelHeight` 从 `+ 20` 改 `+ 12`（commit 之前）
  3. **本次** SwiftUI Text 渲染高度 ≠ fontLineHeight：引入 `textRenderHeight(size, weight) = round(fontLineHeight) + 1` 替换所有 picker 行高公式。`SettingsSubPickerRow` 占位符（`Color.clear.frame(height:)`）也改用 `textRenderHeight`，保证 `verticalSublabel=true` 行无论有没有 sublabel 都精确 41pt。`SettingsPageLayout.swift` / `ExpandableSettingsRow.swift` 两个文件改动，build 通过。
  - **清理**：`ScrollViewOverlayStyle` NSViewRepresentable 删除（保留 `ScrollViewOverlayHelper` 直接遍历 window tree），8 类诊断 log 全部删除（`[OverlayStyle]` / `[OverlayHelper]` / `[openedSize.menu]` / `[PageLayout]` / `[RowHeight]` / `[SubPickerRow]` / `[Measure]` / `[handleMeasuredContent]`），`measure(_:)` helper 删，`GeometryReader` per-row 测量删。`handleMeasuredContentHeight` 收敛逻辑保留作为 defense-in-depth（公式现在精确等于 SwiftUI 实际分配，理论上永不 fire）。
  - **panelContentBuffer=16pt 保留**：本修复只对齐 picker 行高，panel 整体高度 = 静态行（公式精确）+ picker 行（公式精确）+ 16pt buffer。如果验证 OK 后续可尝试减小 buffer。
  - **关键学习**：NSFont 的 `fontLineHeight` 是 typographic 指标（asc - desc + leading），但 SwiftUI Text 不直接用它——它 round 到最近整数再加 1pt descender safety margin。`menuRowHeightDefault`（图标驱动，`.frame(width: 16)`）不受影响，因为 SwiftUI 对固定 frame 子节点使用精确值。
- **2026-07-01 scrollbar flicker 9 次修复链路** — 5 层 stack 全部保留（panelContentBuffer 16pt 兜底，windowHeight cap 防 clip）。完整时序：**(1) PanelAnimationContract** 曲线集中管理避免 picker/panel 曲线不匹配；**(2) onToggle 同步预测** 在 `withAnimation` 块内报告 `measuredContentHeight` 让 panel 高度立刻跟上；**(3) onPreferenceChange disablesAnimations** 防止 preference 覆写打断 panel 动画；**(4) keyboard/collapse 同步** `@State` pickerMeasuredHeight 让 keyboard handler / `collapseAfterDelay()` 也能同步预测；**(5) panelContentBuffer + windowHeight cap** GeometryReader 报告值与 panel 内容区在边界上留 16pt slack + 防止 panel 被屏幕 clip。**关键学习：4 层内是布局时序的 hack，第 5 层是 layout 不可靠性的兜底**——用 16pt 物理 slack 顶住 macOS NSScroller 在 grow 方向保留 gutter 的行为。**架构问题**：`panel maxHeight` 依赖 `GeometryReader → onPreferenceChange → viewModel → 重新计算 openedSize` 这条反馈回路，本质是"用 layout 测量反推自身尺寸"。SwiftUI 不保证 measurement 时机、不保证 preference 在哪一帧 fire。picker 的 frame 写在 OUTER VStack 里，picker 一动 VStack contentSize 跟着动，macOS 在 grow 方向保留 gutter 引发宽度占位闪烁。**根治方向**：取消反馈回路，每个 picker 自己暴露 `targetHeight`（@State，ExpandableContent 测量时存），panel 直接 `sum(picker.targetHeights) + 静态行高度` 算出来——完全跳过 layout 测量，panel 永远先到位。当前用户对 16pt buffer 视觉距离不满意，根治方案待评估。完整诊断链路 / 6 条诊断 log / `panelContentBuffer` 2pt → 16pt 演进 / `windowHeight` cap 引入 → 详见 `docs/debug/2026-06-30-appearance-style-scrollbar-regression.md`（待更新 9 次修复全链路）。
- **2026-06-30 scrollbar flicker 四层修复（v1，已被 9 次链路取代）** — 第一轮四层修复同步落地。**层 1**（PanelAnimationContract 曲线合约）确保 panel 和 picker 永远使用 `.settingsExpand` 曲线，Release 1.3.1 (`01420a1`) 加的 `.animation(.smooth)` 引入曲线冲突，新建 `PanelAnimationContract.swift` 集中管理 → 改回 `.settingsExpand`。清理 3 个 selector 的 `expandedPickerHeight` 死代码 + `NotchViewModel` 冗余引用。**层 2**（onToggle 同步 panel 高度预测）解决 picker/panel 动画 1-2 帧异步 lag。**层 3**（onPreferenceChange disablesAnimations）所有 3 个 settings 页面的 preference handler 用 `Transaction.disablesAnimations = true` 包裹 overwrite → snap 而非 animate。**层 4**（keyboard/collapse 高度同步）键盘触发的 picker toggle 和 ScreenPickerRow 自动折叠路径同步 contentHeight。用户明确要求 `showsIndicators: true`（不接受隐藏 scrollbar 作为 workaround）。5 个 `[flicker-debug]` 诊断 log 已清理。xcodebuild 通过。`docs/debug/2026-06-30-appearance-style-scrollbar-regression.md` 记录完整链路。
- **#51802fa ExitPlanMode PostToolUse → waiting_for_input** — `Nook/Resources/nook-state.py` `PostToolUse` 分支新增 ExitPlanMode 特判：status 从 `processing` 改为 `waiting_for_input`。语义对齐 Claude TUI 的实际状态——Claude 调完 ExitPlanMode 就停下等用户批 plan,UI 不应继续转 spinner 直到 Stop。注释照搬 PreToolUse AskUserQuestion 的 "turn 边界" 写法。Claude 专属:`nook-state.py` 只被 `HookInstaller` 部署到 `~/.claude/hooks/`,codex/opencode/cursor 走各自 hook 脚本。**部署注意**:`nook-state.py` 是 bundled 资源,源码改动后需要重新 build app 才会被 `HookInstaller.installIfNeeded()` 复制到 `~/.claude/hooks/` 覆盖旧版。
- **#1da72a0 ⌃M 进入 performance 页面** — `PerformanceSummaryRow` 加本地 `NSEvent.addLocalMonitorForEvents` 监听 ⌃M → 调用现有的 `action` 闭包（即 `viewModel.pushTo(.performance(.overview))`）。卡片 hover 时显示 `⌃M` tooltip（复制 `shortcutTooltip` modifier 到本文件 `private` 命名空间；**第三个调用方出现时记得把 modifier 提到 `UI/Components/ShortcutTooltip.swift` 共用**）。完全模仿 `MusicCardView` 的 ⌃O 模式：不进 `ShortcutAction` / `ShortcutSettingsView`、不可定制。性能监视器关闭时行不渲染 → monitor 不安装 → ⌃M 自然不响应，无需额外守卫。NSTextView/NSTextField 聚焦时透传不抢键。spec `2026-06-29-performance-row-ctrl-m-shortcut-design` / plan `2026-06-29-performance-row-ctrl-m-shortcut`。
- **#1ea6fe0 agents 页面 brand icon + 样式对齐** — 新增 `OpenCodeLogoIcon`（官方 SVG 24×24 viewBox → SwiftUI Canvas，even-odd fill 画 16×20 ring - 8×12 hole，fit-to-box 缩放到 16×16）。`AgentSettingsView` 删除 `agentMainRow` / `settingsProviderIcon`，改用 `MenuRow` 直接渲染静态行（样式 100% 来自共享组件）。新增 `brandIcon(for:)` helper 给 4 个 provider 配 brand icon，外层 16×16 frame 统一槽宽：Claude `size: 12.6`（66/52 自然宽高比，居中保螃蟹完整），其他 `size: 16`（撑满）。debug log 行顺手对齐 MenuToggleRow baseline（padding 12/10、clear→0.08 hover→0.12 focus、hover 文字增亮）。
- **#a1a8b1d 共享 row 支持 customIcon + trailingLabel 样式** — `MenuRow` / `ExpandableSettingsRow` 加 `customIcon: AnyView?` 参数（覆盖 SF Symbol）。`MenuRow` 加 `trailingLabelDesign`（默认/`.monospaced`）和 `trailingLabelDimmed`（0.35 vs 0.55 透明度）两个样式参数。`trailingLabel` 默认加 `lineLimit(1) + truncationMode(.middle)`。trade-off：AnyView 而非 generic，agents 是目前唯一非 nil 调用点，type-erase 成本付在唯一一处。
- **Codex ChatItem adapter 迁移** — 新增 `CodexChatItemAdapter`，`CodexTranscriptParser` 输出 `[ChatItemUpdate]`，`SessionStore` 通过 debounce transcript sync 应用 Codex transcript。`ChatItemUpdateReducer` 统一处理 content mutation；live stream lifecycle 由 `realtimeChatItemBatch` 显式选择，避免在中间层写 provider 特判。Codex live hook 保留 phase/toolTracker/通知生命周期，只有稳定 `toolUseId` 的 tool row 走 adapter live update。`ChatView` 删除 `codexTranscriptHistory` / `mergedCodexHistory()` / `refreshCodexHistory()`，Codex 和其他 provider 一样从 `ChatHistoryManager` 订阅 `session.chatItems`。
- **#22aad3e Terminal focus 鲁棒性** — `focusTerminal()` 重构：先尝试所有 focus 方法，**成功才关 notch + restore focus**；失败保留 notch + 红色错误提示（`focusErrorMessage`，自动在 `ChatInteractivePromptBar` 左侧显示）。`tryFocusTerminal()` 抽出独立 helper。修复 22aad3e 之前 beb9b06 太激进的"先关 notch 再 focus"行为（失败时用户两边都看不到）。
- **#74eb2d0 Terminal 按钮 adaptive theme 不可见** — `ChatInteractivePromptBar` 的 Terminal 按钮背景用 `primaryTextColor.opacity(0.92)` + 黑色前景。Adaptive background 模式下 `primaryTextColor = expandedNotchTheme.primaryText`（可能是黑色），导致黑底黑字完全看不见。修复：用固定 `Color.black.opacity(0.85)` 背景 + 白字，与主题无关。
- **#a2baf94 修正 `question.asked` 错误判断** — `OpencodeHookAdapter.swift` 注释 + PROGRESS.md #83 修正：原 2026-06-17 早期"v1.17.x 不发 question.asked"是错误判断，同一天 08:36 测试中 `[opencode] event type=question.asked` 正常到达。早期缺失是 opencode/plugin socket 启动时序问题（socket 没绑定），不是事件不存在。`handleQuestionAsked` 恢复 PRIMARY path。
- **#bf09271 OpenCode question tool phase + publishState 缺失** — `handleToolPart` 里 `toolName == "question"` 时额外 emit `.waitingForUserInput`（idempotent）。`processOpencodeSessionStart/ProcessingStarted/WaitingForUserInput/Stop` 都补上 `publishState()` 调用 — 之前 UI 不更新。
- **#58202f5 统一 AskUserQuestion phase** — `SessionEvent.determinePhase()` 里 `ToolKind.classify(tool) == .askUserQuestion` 时返回 `.waitingForInput` 而非 `.waitingForApproval`。`SessionPhase` 新增 `isWaitingForInput`。`InstanceRow` 对 `.waitingForInput` + interactive tool 显示 chat + terminal 按钮（和 `.waitingForApproval` 路径一致）。
- **#dadcfa3 AskUserQuestion hasResult + tool name alias** — `hasResult` 对 `.askUserQuestion` 永远 `true`（选项是静态内容）。`MCPToolFormatter.toolAliases` 加 OpenCode 小写映射（`question` → `Question` 等），OpenCode "question" 不再小写显示。
- **#334911d AskUserQuestion 选项展示 + preview + status** — `AskUserQuestionResultContent` 重写：header + question + A/B/C/D option list + 描述 + 选中高亮（绿色 + checkmark）。`ToolCallView` 对 AskUserQuestion 豁免 `.running` / `.waitingForApproval` 守卫（chevron 和内容）。`inputPreview` 显示 "请选择...(N 个选项)" 而非 raw JSON。`ToolStatusDisplay` 加 `.askUserQuestion` → "Waiting for answer..."。新增 `docs/specs/2026-06-16-claude-adapter-completeness-fix.md`。
- **#650ac68 Claude adapter 迁移 + .appendOrder + hook gating** — `BlockOrdering` 加 `.appendOrder` case。`ChatItemSorter` 加 fast path。`SessionProvider.needsHookPlaceholders` 替换 `provider == .claude` 打补丁。`SessionStore` 删 `upsertBlocks()`，走 `ClaudeChatItemAdapter`。structuredResult 合并改成 `existing ?? new`。新增 `docs/specs/2026-06-16-clause-chatitem-adapter-design.md`。
- **#83 opencode `question.asked` 行为澄清** — `OpencodeHookAdapter.swift` 注释更新：原 2026-06-17 早期观察 "v1.17.x 不发 `question.asked`" 是错误判断 — 后续同一天 08:36 测试时日志清晰显示 `[opencode] event type=question.asked` 正常到达。`handleQuestionAsked` 恢复为 PRIMARY path，`handleToolPart` 里 `tool=question` 检测保留为 defensive fallback（idempotent）。代码无逻辑改动。
- **#64 清理 unbounded session-scoped state** — 新增 `cleanupState(forSession:)` 函数，在 `handleSessionStatus(idle)`、`handleSessionIdle`、子代理 `session.idle` 三处调用。清理 per-session dicts（sessionCwd/latestUserMsgID/consumedUserPromptBySession 等）、subagent dicts（subagentToParent/subagentTaskToolId 双向清理）、message-scoped dicts（通过 messageSession 反查过滤）。`runningToolCallIds` 保留不清理（keyed by callID，无 session 映射，但 bounded by active calls）。
- **handleToolPart error status** — `handleToolPart` 的 status switch 新增 `case "error"`：去重 switch 中移除 callID 并记录日志；事件产出 switch 中 emit `.postTool(output: nil, error: error)`；task tool 的 error 状态也触发 `subagentStopped`。
- **#78 Bug H Fix 2** — TrailingEchoDetector 重构：抽出 pure value type，exact match + length-bounded Levenshtein 替代 substring 匹配；覆盖 handlePartDelta 的 delta 路径（Fix 1 只覆盖 handleTextPart）；system-reminder 修正（第一个 text part 是 `<system-reminder>` 时允许第二个 text part 覆盖）；Levenshtein 计算移到 lock 外避免阻塞事件循环；`min(a,b,c)` 改为嵌套 `min(min(a,b),c)`；delta 路径长度上限改为 `max(pTrim.count + 10, pTrim.count * 2)`
- **#76 opencode tool result 渲染对齐 claude** — 3 个 commit：d36b782（unwrap `<task_result>`）+ 537f725（结构化 input 透传）+ a29076a（删除 5 个被 ChatItemUpdate 取代的旧 handler）
- **#82 Bug J** — 推理块出现在 chat 末尾（bullet-pointed text）。根因调查：opencode v1.15.13 偶发漏发 `reasoning-end` 事件，但 `cleanup()`（`processor.ts:390-396`）会兜底 fire `updatePart` 触发 `message.part.updated` 走 plugin → 我们 handler 正常 emit。Bug J 间歇性，本轮跑 2 个 task 9 段 reasoning 全部正常内联 emit。本地验证方法：诊断 log 保留长期。
- **f139350** — `chore(opencode): document unbounded session-scoped state`（已 commit）
- **6c56af0** — `feat(opencode): full event stream + subagent routing`（已 commit）
- **Bug A–F 全部修复完成**（#70–#75）

## 🧱 Blockers & Issues
- **Bug J 是 opencode 上游 bug**，不是我们 plugin。opencode v1.15.13 在某些边界条件（cancel/retry/异常 step 切换）下 `reasoningMap` 中的 entry 可能在 cleanup() fire `updatePart` 之前就被移除（具体路径未深挖）。我们这边处理没问题，但若以后高频复现，需要在 handler 加 "新 reasoning-start 触发老 reasoning flush" 的兜底。当前不实现——没复现场景。
- **yabai 缺失**：用户当前没装 yabai。fallback 路径（`focusTerminalApp` + last-resort bundle ID activate）能工作但精度低。考虑加 UI 提示（未实现）。
- **SourceKit false positives**：`DebugLog` / `OpencodeHookEnvelope` / `AnyCodable` / `OpencodeSessionEvent` 等类型 SourceKit 报 "Cannot find ... in scope"。xcodebuild 实际通过。是跨文件引用的已知问题，忽略。
- **task 列表历史**：会话中已 working through 17+ 个 bug/task（#60-#95），#78 / #79 / #64 / #76 还活着。

## 🧠 Context Notes

> **本节是 PROGRESS 专属"指针索引"** —— 具体内容已沉淀到 `docs/specs/` / `docs/debug/` / `docs/architecture/` 或代码注释,只保留 1-2 行概要 + 链接。**完整入口** 看 [CLAUDE.md](CLAUDE.md)。

### Brand icon 设计（2026-06-23 落地）
详见 `AgentSettingsView.brandIcon(for:)` 和 `AgentProviderIcons.swift` 顶部注释。槽宽统一 16×16,size 差异由自然宽高比决定(Claude 12.6 / 其他 16)。**customIcon type 优化方向**(AnyView → generic / some View) — 2026-06-23 用户决议延后,实测成本不可见。

### Bug J 调查
完整调查 + 诊断 log 用法 → **`docs/debug/2026-06-23-bug-j-reasoning-flush.md`**(`OpencodeHookAdapter.swift` line 630 的 TODO 注释有指针)。间歇性,本地未复现高频,根因可能在 opencode 上游,handler 当前不做特殊处理,长期保留 `→ part arrived type=reasoning` 诊断 log。

### opencode review 11 项核查结果（历史档案）
- ❌ False positive: #1 `session.status=ended` / #2 `message.part.final` / #9 `ask_user_question`(详见 v1.17 矩阵 spec)
- ⚠️ 半真: #3 `createMinimalConfig()` 备份 — 待办
- ✅ 真: #4(=#64)、#5 tool error 进 default、#8(=#79) — 已 commit
- 🔍 待查: #6 / #7 / #10 / #11 — 在 SessionStore / HookSocketServer 里

### 设计原则
opencode 行为要对齐 claude:子代理 reasoning/text 不下沉到 chat,tool calls promoted 到 Task 工具的 subagentTools 容器。这是 2026-06-17 后所有跨 provider bug 修复的总原则。

### Scrollbar flicker 9 次修复 + 架构教训
**完整时间线 + 5 个失败路径根因 + 3 个结构性教训 + buffer 探测数据** → **`docs/architecture/swiftui-macos-lessons.md` 教训 1/2/3** + **`docs/specs/2026-07-01-picker-panel-height-redesign.md`**。根治方案(取消 GeometryReader 反馈回路 + targetHeight 数据驱动)在 spec 里。当前 16pt buffer 兜底是 macOS NSScroller gutter 方向敏感行为下的 trade-off。

### opencode v1.17.x 兼容性矩阵
**完整矩阵 + 3 个关键陷阱 + 决策档案** → **`docs/specs/2026-06-17-opencode-v1.17-compatibility-matrix.md`**(`OpencodeHookAdapter.swift` 顶部注释有指针)。PROGRESS 这块只剩指针,不再重复内容。

### ChatItem 中间层抽象
**4 个 ordering case + 接入新 provider 指南 + BlockTypePriority 因果链** 全部在 **`Nook/Models/ChatItemUpdate.swift` 顶部 + `BlockOrdering` enum 注释**。设计 spec: `docs/specs/2026-06-11-unified-chatitem-middle-layer-design.md`。PROGRESS 这块只剩指针。

## ⚡ Quick Recovery
- **branch**: `main`（upstream 同步已完成，merge commit 7614dad）
- **主战场文件**:
  - `Nook/UI/Views/AgentSettingsView.swift`（agents 设置页：keyboard nav + brand icon + brandIcon helper）
  - `Nook/UI/Views/NotchMenuView.swift`（`MenuRow` 共享组件 + customIcon + trailingLabel 样式）
  - `Nook/UI/Components/ExpandableSettingsRow.swift`（expandable row + customIcon 支持）
  - `Nook/UI/Components/AgentProviderIcons.swift`（`ClaudeCrabIcon` / `CodexLogoIcon` / `CursorLogoIcon` / `OpenCodeLogoIcon`）
  - `Nook/Models/SessionProvider.swift`（`displayName` / `systemImage` / `defaultDirectoryName`）
  - `Nook/Services/Hooks/OpencodeHookAdapter.swift`（核心事件路由 + v1.17.x 注释）
  - `Nook/Services/Hooks/ClaudeChatItemAdapter.swift`（Claude JSONL → ChatItemUpdate）
  - `Nook/Services/Hooks/CodexChatItemAdapter.swift`（Codex transcript/live hook → ChatItemUpdate）
  - `Nook/Services/Session/CodexTranscriptParser.swift`（Codex transcript → ChatItemUpdate）
  - `Nook/Models/ChatItemUpdate.swift`（中间层 + `BlockOrdering.appendOrder`）
  - `Nook/Services/Shared/ChatItemUpdateReducer.swift`（provider-agnostic content mutation）
  - `Nook/Services/Shared/ChatItemSorter.swift`（fast path）
  - `Nook/Services/State/SessionStore.swift`（chatItems 状态机 + publishState）
  - `Nook/UI/Views/ChatView.swift`（`hasResult` / chevron / `focusTerminal()` / `focusErrorMessage`）
  - `Nook/Resources/nook-state.py`（Claude Code 钩子脚本,被 `HookInstaller` 自动部署到 `~/.claude/hooks/`;改完需重新 build app）
  - `Nook/UI/Views/ClaudeInstancesView.swift`（`stateIndicator` phase）
  - `Nook/UI/Views/ToolResultViews.swift`（`AskUserQuestionResultContent`）
  - `Nook/Utilities/MCPToolFormatter.swift`（OpenCode 小写 toolAliases）
  - `Nook/Resources/opencode-plugin/index.js`（opencode 端 forward）
  - `Nook/Services/Hooks/HookSocketServer.swift`（Unix socket 接收）
- **诊断日志**：`/tmp/nook-debug.log`（设置面板 toggle，#60 commit 加）
- **关键 commit 参考**:
  - `1ea6fe0` — feat(agents): brand icons for all providers + agents page styling
  - `a1a8b1d` — refactor(settings): customIcon + trailingLabel styling in shared rows
  - `7614dad` — Merge upstream/main: agents refinement, Cursor hook, codex fixes
  - `ec7a1d4` — fix(agents): Cursor keyboard navigation after upstream merge
  - `a1ded5d` — fix(perf-settings): reset Visible Metrics picker on page entry
  - `8802578` — fix(agents): reset Claude dir picker on page entry
  - `9ebbe04` — fix(agents): correct claudeHooksIndex to follow picker expansion
  - `5450fe5` — feat(agents): add keyboard navigation to Agents settings page
  - `295be9d` — refactor: remove scrollToBottom shortcut, chat-only via ⌃G hardcode
  - `e65ef6b` — feat: add j/k as default bindings for Navigate Up/Down, ignore on chat
  - `22aad3e` — Terminal focus 鲁棒性（keep notch open on failure）
  - `74eb2d0` — Terminal 按钮 adaptive theme 可见性
  - `a2baf94` — 修正 question.asked 错误判断
  - `bf09271` — OpenCode question tool phase + publishState
  - `58202f5` — 统一 AskUserQuestion phase
  - `dadcfa3` — AskUserQuestion hasResult + tool name alias
  - `334911d` — AskUserQuestion 选项展示 + preview
  - `650ac68` — Claude adapter 迁移 + .appendOrder + hook gating
  - `a29076a` — `chore(opencode): remove dead processOpencode* code`
  - `537f725` — `refactor(opencode): pass structured tool input`
  - `d36b782` — `fix(opencode): strip task_result XML wrapping`
  - `f139350` — 状态泄漏文档
  - `6c56af0` — 完整事件流 + subagent routing
  - `c51f607` — suppress question tool parent text
- **opencode 本地源码**: `/Users/wuruofan/mine/rfw/opencode/`（v1.15.13 文档参考，v1.17.x 实战验证）
- **关键 spec**:
  - `docs/specs/2026-06-11-unified-chatitem-middle-layer-design.md`（含 Revision 2026-06-16 + 2026-06-17）
  - `docs/specs/2026-06-16-clause-chatitem-adapter-design.md`（Claude adapter 实施记录）
  - `docs/specs/2026-06-16-claude-adapter-completeness-fix.md`（AskUserQuestion + error status）
  - `docs/specs/2026-07-01-picker-panel-height-redesign.md`（picker panel 高度数据驱动改造,9 次 flicker 修复背景）
  - `docs/specs/2026-07-07-picker-height-and-broadcast-pattern.md`（**新增 picker 必须做 3 件 + 绝不能做 3 件**,防止下一个人再踩坑）

## 🏛️ Archive Links
（暂无。完成 #78 / #79 后建议 archive 中间层系列。）
