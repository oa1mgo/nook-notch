# Debug: App 重启后 chat 页只显示少量内容（历史丢失 + 事件断档）

- Date: 2026-09-30（症状发现于 2026-09-30 上午；触发事件在 2026-09-29 傍晚）
- Symptom: 本 session 的 chat 页只剩一条 Bash 工具行 + Working…；session 列表状态行摘要停留在旧工具调用。大量对话历史不可见。
- Not caused by: ⌃R target-resolution feature（`ea309a6..5e1e5d7` 只改键位目标解析，未触碰事件/历史管线）。

## 根因（两条叠加）

1. **chatItems 是纯内存事件驱动，无持久化、无回填。**
   代码检索 `persist/saveChat/restoreChat/backfill/history` 在 chat 管线零命中。
   App 于 2026-09-29 18:11:57 被 quit→open 重启（Task 5 手测的 build+重启步骤），
   重启前积累的全部对话内容随进程清零，且没有任何机制从 opencode server API 拉回。

2. **主 session 事件需 sessionStart 注册才路由进 chatItems；启动后断档直到 self-heal。**
   重启后的实例在 18:12–2026-09-30 09:13 期间对本 session
   **自身**的 `message.part.updated` 计数为 0（该窗口只有 subagent 冒泡的 routing HIT）。
   直到 `2026-09-30T01:13:00Z [opencode] → sessionStart (event-driven self-heal) session=ses_f1a4b8642…`
   触发后，本 session 事件才恢复进入（此后 ~1.2 万条）。
   即：断档期没有任何消息顶替，最后一条 item 永久停留在 18:12 冒泡的 Task 5 Bash 行。

## 证据（/tmp/nook-debug.log）

- L1-6: `pid: 98242 / app launched 2026-09-29T10:11:57Z`（Task 5 重启点）；二进制 mtime 18:11:53 > 最后源码 18:10:50 → 加载的是最新 build。
- `grep "2026-09-29T1[01]:" | grep <parent> | grep part.updated` → 0（断档证据）。
- `2026-09-30T01:13:00 / 01:14:29 sessionStart (event-driven self-heal)` → 恢复点。
- 状态（spinner / "Bash bash" 摘要）走实时 `session.status`/`part running` 事件，一直正常——**状态与历史是两条独立数据流**，故出现"状态 running 正确、正文残缺"的组合。

## 影响边界

- 仅在 **Nook app 重启**时触发（日常 app 常驻不受影响）；开发期频繁 quit→build→open 会反复遇到。
- 状态行/列表摘要不受影响（实时事件流）；丢的只是 chat 正文。

## 决策

- 方案 A（现状）: 不修——重启才丢，接受。
- 方案 B（未立项）: 打开 chat 页/启动时从 opencode server API 回填历史 + 启动时对已知 session 主动注册（消除对 self-heal 的依赖）。需走 brainstorming→spec。

Restart: 本文件 + `/tmp/nook-debug.log` grep `sessionStart (event-driven self-heal)` / `DIAG #79`。
