# Progress

> Last updated: 2026-09-30

## Open
- [2026-09-30] chat 历史回填决策 — app 重启丢历史 + sessionStart 断档根因已确认（docs/debug/2026-09-30-app-restart-chat-history-loss.md）。Done when: 用户拍板 A 不修（关闭本条）或 B 立项走 spec
- [2026-09-22] question Phase 1 e2e + pendingQuestionContext 清理 — Task 19 全链路（触发→panel→回复→续跑）未手测。Done when: e2e 通过且 phase 离开 .waitingForInput 时 context 清空
- [2026-09-22] permission/question 决策沉淀进 spec — Y/N/A 已进 09-23 spec；auto-expand 绕过 TerminalVisibilityDetector、QuestionPanel NSEvent monitor 仍仅存代码/commit。Done when: 07-10 permission spec + 09-02 question spec 更新对应章节
- [2026-09-22] createMinimalConfig JSON 备份 — 损坏时直接覆盖原文件。Done when: 覆盖前存在 backup 逻辑
- [2026-09-22] yabai 缺失 UX 提示 — fallback 可用但精度低无提示。Done when: 设置页说明或失败一次性提示落地

## Verify
- [2026-09-30] session list ⌃R 单一 pending 直达 — ea309a6..5e1e5d7（resolver+11 新测试，95 全绿，双 review 通过）。Awaiting: Task 5 手测 6 项（清单见 plan §Task 5）
- [2026-09-24] session list Y/N/A shortcuts — c1d7d25..1cd5e3b，用户确认 N 可响应（重启 Nook 后）。Awaiting: Esc 不关 notch、2+ pending 需高亮、通知不抢焦点
- [2026-09-22] Ctrl+R 打开 question panel — bc3d053/0ed93de，session list + chat view 双路径。Awaiting: 用户手测
- [2026-09-22] permission Y/N/A + auto-expand — 0ed93de，log 证实 08:07 Y、08:15 A→C 全链路（permission.asked→expand→replied）。Awaiting: 用户手感/视觉确认

## Paused
- question Phase 2 Claude/Codex/Cursor inline 回答 — 等 Claude Code 装机。Restart: docs/specs/2026-09-02-question-tool-notch-prompt-design.md + ToolApprovalHandler sendKeys 改 public
- #78 Bug H trailing-echo — Fix 2 已 commit 等自然复现。Restart: grep `trailing-echo` /tmp/nook-debug.log
- #79 Bug I subagent race — 诊断已部署未命中。Restart: grep `DIAG #79` /tmp/nook-debug.log
- customIcon type (AnyView→generic) — 2026-06-23 用户决议延后。Restart: `AgentSettingsView.brandIcon(for:)` 注释
- Bug J reasoning flush — 上游 bug 0 复现。Restart: docs/debug/2026-06-23-bug-j-reasoning-flush.md
- picker panel height 数据驱动根治 — 当前 16pt buffer 不触发。Restart: docs/specs/2026-07-01-picker-panel-height-redesign.md
- opencode review 待查 #6/#7/#10/#11 — SessionStore/HookSocketServer 未排查。Restart: docs/specs/2026-06-17-opencode-v1.17-compatibility-matrix.md
