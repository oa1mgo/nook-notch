# Progress · managed by `progressing` skill

> Last updated: 2026-11-27

> 一条目一行；详情在各自 spec/plan/debug 文件（见 `Detail:`）。手动编辑会破坏格式契约 —— 改完请跑格式闸门。

## Open
- [2026-11-27] opencode session-end recovery — 分支 12 commits，207 测试全绿 + 真机 log 验证 turn-end / permission.replied / 静默兜底。Done when: PR 合入 upstream/main。Detail: docs/superpowers/plans/2026-10-23-opencode-session-end-recovery.md
- [2026-09-30] chat 历史回填决策 — 重启丢历史 + sessionStart 断档根因已确认。Done when: 用户拍板 A 不修（关闭本条）或 B 立项。Detail: docs/debug/2026-09-30-app-restart-chat-history-loss.md
- [2026-09-22] question Phase 1 e2e + pendingQuestionContext 清理 — 全链路未手测，context 在 phase 离开 .waitingForInput 时未清空。Done when: e2e 通过且 context 清空。Detail: docs/specs/2026-09-02-question-tool-notch-prompt-design.md
- [2026-09-22] permission/question 决策沉淀进 spec — Y/N/A 已进 09-23 spec；auto-expand 与 QuestionPanel NSEvent monitor 仍只在代码/commit。Done when: 07-10 与 09-02 spec 更新对应章节。Detail: docs/specs/2026-07-10-opencode-permission-handling.md
- [2026-09-22] createMinimalConfig JSON 备份 — 损坏时直接覆盖原文件。Done when: 覆盖前存在 backup 逻辑
- [2026-09-22] yabai 缺失 UX 提示 — fallback 可用但精度低且无提示。Done when: 设置页说明或失败一次性提示落地

## Verify
- [2026-09-30] session list ⌃R 单一 pending 直达 — 已随 PR #19 上送（95 测试全绿，双 review 通过）。Awaiting: Task 5 手测 6 项
- [2026-09-24] session list Y/N/A shortcuts — N 已确认可响应。Awaiting: Esc 不关 notch、2+ pending 高亮、通知不抢焦点
- [2026-09-22] Ctrl+R 打开 question panel — session list + chat view 双路径。Awaiting: 用户手测
- [2026-09-22] permission Y/N/A + auto-expand — log 证实 asked→expand→replied 全链路。Awaiting: 用户手感/视觉确认

## Paused
- question Phase 2 Claude/Codex/Cursor inline 回答 — 等 Claude Code 装机。Restart: docs/specs/2026-09-02-question-tool-notch-prompt-design.md
- #78 Bug H trailing-echo — Fix 2 已 commit 等自然复现。Restart: grep trailing-echo /tmp/nook-debug.log
- #79 Bug I subagent race — 诊断已部署未命中。Restart: grep "DIAG #79" /tmp/nook-debug.log
- customIcon type (AnyView→generic) — 2026-06-23 用户决议延后。Restart: AgentSettingsView.brandIcon(for:) 注释
- Bug J reasoning flush — 上游 bug 0 复现。Restart: docs/debug/2026-06-23-bug-j-reasoning-flush.md
- picker panel height 数据驱动根治 — 当前 16pt buffer 不触发。Restart: docs/specs/2026-07-01-picker-panel-height-redesign.md
- opencode review 待查 #6/#7/#10/#11 — SessionStore/HookSocketServer 未排查。Restart: docs/specs/2026-06-17-opencode-v1.17-compatibility-matrix.md
