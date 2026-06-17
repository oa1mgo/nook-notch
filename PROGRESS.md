# Progress

> Last updated: 2026-06-17

## 🎯 Current Focus
<!-- 中间层 + AskUserQuestion 完善（#84-#95）已完成。Terminal focus 流程重构（22aad3e）已落地。当前 OpenCode session 列表 phase 修复完成（bf09271）。 -->

## 📥 Next Phases
<!-- 下一步候选，按优先级 -->
1. **Critical #3** — `createMinimalConfig()` 在 JSON 损坏时会覆盖原文件，先备份再覆盖更安全
2. **yabai 缺失的 UX 提示**（来自 2026-06-17 用户反馈）— 没装 yabai 时 fallback 能工作但精度低。考虑设置页加说明或失败时一次性提示
3. **Bug J 长期监控**（见 Blockers）— 当前 0 复现但保留诊断 log

## ⏸️ Paused Tasks
| Task | 状态 | 阻塞点 / 入口 |
| --- | --- | --- |
| #78 Bug H | Fix 2 已 commit，等实战验证 | TrailingEchoDetector 覆盖 handleTextPart + handlePartDelta 两条路径。验证方法：等 bug 自然触发时检查日志是否有 `→ text part suppressed (trailing-echo)` 或 `→ text delta suppressed (trailing-echo accumulated)` |
| #79 Bug I | 诊断已就位，race 未被证实 | 3 条诊断 log 已部署。当前 opencode v1.15.13 下 `⚠ DIAG #79` 从未命中，`subagent routing HIT` 正常工作。保留诊断作为基线，暂不修复 |

## ✅ Recently Completed
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
### Bug J 调查关键事实
1. opencode reasoning 生命周期在 `packages/opencode/src/session/processor.ts:117-151`：
   - `reasoning-start` → `updatePart(text="")`
   - `reasoning-delta` → `updatePartDelta(field=text, delta=...)`
   - `reasoning-end` → `updatePart(text=<trimmed>)`（**唯一带完整 text 的 part.updated**）
   - `cleanup()` line 390-396：遍历 `ctx.reasoningMap` 残留 entry 兜底 fire `updatePart`
2. 事件流：`Session.updatePart` → `SyncEvent.run(PartUpdated)` → `sync/index.ts:142-158` 把 SyncEvent 同时 publish 到标准 Bus → 插件 `bus.subscribeAll()` 收到 → `event.type="message.part.updated"` → 我们 adapter `handlePartUpdated` 处理
3. 诊断 log 长期保留：`OpencodeHookAdapter.swift` line 581。复现 Bug J 时直接 grep `→ part arrived type=reasoning` 看目标 messageID 有没有出现，出现 → plugin 收到了但 handler 漏了（不太可能）；没出现 → opencode cleanup() 没 fire 这条的 updatePart

### opencode review 11 项核查结果
- ❌ **False positive**（AI 想象了 opencode 没有的事件名/状态）：#1 `session.status=ended`（opencode 只有 idle/retry/busy）、#2 `message.part.final`（不存在）、#9 `ask_user_question`（v1.15.x 改名为 `question.asked` — 2026-06-17 08:36 测试中 `question.asked` 确实在 v1.17.x 触发；早期观察缺失是启动时序问题，不是事件不存在，见 #83）
- ⚠️ **半真**：#3 `createMinimalConfig()` 仅在 JSON 损坏时覆盖，加个备份就好
- ✅ **真**：#4 内存泄漏（=#64）、#5 tool error 进 default、#8 subagent 预注册竞态（=#79）
- 🔍 **待查**：#6 / #7 / #10 / #11 在 SessionStore / HookSocketServer 里

### 设计原则
用户原话："opencode provider 是新加入的，像 claude provider 展示效果看起，这几个 bug 的修复都是这一个原则" —— opencode 行为要对齐 claude：子代理 reasoning/text 不下沉到 chat，tool calls promoted 到 Task 工具的 subagentTools 容器

### opencode v1.17.x 兼容性矩阵（2026-06-17 实战验证）
| 事件 | v1.15.13 | v1.17.x | 实际来源 |
|---|---|---|---|
| `session.created` / `session.updated` | ✅ | ✅ | Nook plugin |
| `session.status` (idle/busy/retry) | ✅ | ✅ | Nook plugin |
| `question.asked` | ✅ | ✅ | opencode Bus — 08:36 测试确认正常（早期 08:23 缺失是启动时序问题，socket 未绑定） |
| `message.part.updated` (type=tool, tool=question) | ✅ | ✅ | Nook plugin — handleToolPart 里 `tool=question` 检测作为 defensive fallback（idempotent） |
| `message.part.updated` (type=text/reasoning) | ✅ | ✅ | Nook plugin |
| `message.part.delta` (field=text) | ✅ | ✅ | Nook plugin |
| `file.watcher.updated` | ❌ | ✅ (高频) | opencode Bus — v1.17.x 才开始发，Nook plugin 不处理，无害 |

### ChatItem 中间层抽象（2026-06-17 落地）
- `BlockOrdering` 四种 case：`.filePosition`（全量 parse）、`.messageRelative`（OpenCode 事件流）、`.timestamp`（fallback）、`.appendOrder`（append-only + monotonic，Claude JSONL）
- `ChatItemSorter.sorted()` fast path：全 `.appendOrder` 或 missing → 返回原数组不排序
- `ChatItemUpdateReducer` 是纯 content mutation reducer；SessionStore 只负责 session auto-create、可选 realtime lifecycle、publish
- `chatItemBatch` 表示 transcript/history 内容同步；`realtimeChatItemBatch` 表示 live stream 内容更新并驱动 phase/toolTracker
- `SessionProvider.needsHookPlaceholders` 驱动 hook placeholder 创建（claude/codex=false, opencode=true）
- 接入新 provider：除非能证明数据源乱序，否则默认 `.appendOrder`

## ⚡ Quick Recovery
- **branch**: `feat/agent-hooks`
- **主战场文件**:
  - `Nook/Services/Hooks/OpencodeHookAdapter.swift`（核心事件路由 + v1.17.x 注释）
  - `Nook/Services/Hooks/ClaudeChatItemAdapter.swift`（Claude JSONL → ChatItemUpdate，新）
  - `Nook/Services/Hooks/CodexChatItemAdapter.swift`（Codex transcript/live hook → ChatItemUpdate，新）
  - `Nook/Services/Session/CodexTranscriptParser.swift`（Codex transcript → ChatItemUpdate）
  - `Nook/Models/ChatItemUpdate.swift`（中间层 + `BlockOrdering.appendOrder`）
  - `Nook/Services/Shared/ChatItemUpdateReducer.swift`（provider-agnostic content mutation）
  - `Nook/Services/Shared/ChatItemSorter.swift`（fast path）
  - `Nook/Models/SessionProvider.swift`（`needsHookPlaceholders`）
  - `Nook/Services/State/SessionStore.swift`（chatItems 状态机 + publishState）
  - `Nook/UI/Views/ChatView.swift`（`hasResult` / chevron / `focusTerminal()` / `focusErrorMessage`）
  - `Nook/UI/Views/ClaudeInstancesView.swift`（`stateIndicator` phase）
  - `Nook/UI/Views/ToolResultViews.swift`（`AskUserQuestionResultContent`）
  - `Nook/Utilities/MCPToolFormatter.swift`（OpenCode 小写 toolAliases）
  - `Nook/Resources/opencode-plugin/index.js`（opencode 端 forward）
  - `Nook/Services/Hooks/HookSocketServer.swift`（Unix socket 接收）
- **诊断日志**：`/tmp/nook-debug.log`（设置面板 toggle，#60 commit 加）
- **关键 commit 参考**:
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

## 🏛️ Archive Links
（暂无。完成 #78 / #79 后建议 archive 中间层系列。）
