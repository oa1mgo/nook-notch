# Nook — AI Contributor Guide

> Entry point for all AI coding agents (Claude / Codex / Cursor / OpenCode / etc.). **Pointers and hard constraints only — no spec duplication.** Read this to know which docs are mandatory and which pitfalls to avoid.

## 1. What Nook Is

Nook turns the MacBook notch into a compact desktop control layer. Agent sessions (Claude / Codex / OpenCode / Cursor) + music + system status. See [README.md](README.md) for features and screenshots.

## 2. Required Reading (by priority)

### 2.1 Cross-project SwiftUI / macOS architecture lessons (mandatory before any UI change)

**[`docs/architecture/swiftui-macos-lessons.md`](docs/architecture/swiftui-macos-lessons.md)** — 7 lessons distilled from Nook's real bugs.

**Top 3 (must know before touching UI code)**:
1. **Never use layout measurement to derive self-size** (GeometryReader feedback loop = flicker)
2. **Buffer is a platform behavior problem, not a geometry problem** (macOS NSScroller gutter is direction-sensitive)
3. **Extract helpers beats writing comments** (single source of truth — cross-file magic numbers must become functions)

### 2.2 Project-level specs (read on demand when touching the relevant module)

| Spec | When to read |
|---|---|
| [`docs/specs/2026-07-07-picker-height-and-broadcast-pattern.md`](docs/specs/2026-07-07-picker-height-and-broadcast-pattern.md) | Before changing any settings / agents / performance picker behavior |
| [`docs/specs/2026-07-01-picker-panel-height-redesign.md`](docs/specs/2026-07-01-picker-panel-height-redesign.md) | Before changing panel height / scrollbar code |
| [`docs/specs/2026-06-17-opencode-v1.17-compatibility-matrix.md`](docs/specs/2026-06-17-opencode-v1.17-compatibility-matrix.md) | Before changing opencode adapter / plugin (see §3.3 version caveat) |
| [`docs/specs/2026-06-11-unified-chatitem-middle-layer-design.md`](docs/specs/2026-06-11-unified-chatitem-middle-layer-design.md) | Before changing ChatItem middle layer / adding a provider |
| [`docs/specs/2026-07-10-opencode-permission-handling.md`](docs/specs/2026-07-10-opencode-permission-handling.md) | Before changing permission.asked/replied flow, approval bar, auto-expand |
| [`docs/specs/2026-09-02-question-tool-notch-prompt-design.md`](docs/specs/2026-09-02-question-tool-notch-prompt-design.md) | Before changing question panel / reply path / QuestionReplyProvider |
| [`docs/specs/2026-08-09-opencode-server-api-input.md`](docs/specs/2026-08-09-opencode-server-api-input.md) | Before changing user-input path (server API vs tmux send-keys) |
| [`docs/specs/2026-08-13-opencode-multi-instance-pid-isolation.md`](docs/specs/2026-08-13-opencode-multi-instance-pid-isolation.md) | Before touching multi-instance pid/port/command-socket mapping |
| Other specs | See `docs/specs/` directory, pick by topic |

### 2.3 Project-level debug docs (read when diagnosing specific bugs)

- [`docs/debug/2026-06-23-bug-j-reasoning-flush.md`](docs/debug/2026-06-23-bug-j-reasoning-flush.md) — intermittent "reasoning block at end of chat" investigation
- [`docs/debug/2026-07-23-subagent-cleanup-bug.md`](docs/debug/2026-07-23-subagent-cleanup-bug.md) — subagent child session incorrectly surfacing as new top-level session (fixed, 3-layer)
- More: `docs/debug/`

## 3. Hard Constraints (violating these regresses known bugs)

### 3.1 Picker Integration

When adding a picker, you **must**:
- Declare `PickerLayout` with compile-time `rowHeight` (must match the row's actual `verticalSublabel` flag)
- In `NotchMenuView` picker `onToggle`: **line 1** `markExplicitSet()` + **line 2** `viewModel.menuContentHeight = menuContentHeight`
- Same two lines in keyboard toggle handlers

You **must not**:
- Measure picker height with GeometryReader and write back to viewModel
- Adjust picker height anywhere outside the picker's `onToggle`
- Put picker state on viewModel without resetting it in the navigation API EXIT path

Full rules: [`docs/specs/2026-07-07-picker-height-and-broadcast-pattern.md`](docs/specs/2026-07-07-picker-height-and-broadcast-pattern.md) — "must do 3 + must not do 3".

### 3.2 Single Source of Truth (SOI)

Any **cross-file constant derived from data X** must be extracted as `func deriveFromX(_ x: X) -> CGFloat`. No inline magic numbers across files.

Example: header height = `settingsPageHeaderHeight(for: geometry)` (in `SettingsPageLayout.swift`). Do NOT inline `max(24, geometry.deviceNotchRect.height)` in `NotchViewModel` / `AgentSettingsView` / `NotchView` independently.

### 3.3 Cross-Process Event Compatibility

Before changing opencode adapter: read the v1.17 compatibility matrix. The PRIMARY vs DEFENSIVE detection paths have explicit design rationale (see `question.asked` dual-path) — do NOT casually merge them.

**Version caveat**: the matrix was verified on opencode v1.15.13 / v1.17.x only. Production now runs **v1.18+** — event names/payloads may have drifted; re-verify against the live log (`/tmp/nook-debug.log`) before trusting the matrix on newer versions.

## 4. Progress Tracking (Critical)

Single PROGRESS.md in the project root. Not a per-commit ritual. Use the `/progressing` skill (source: `wuruofan/agent-skills`, installed at `~/.agents/skills/progressing` — replaces the old `progress-*` suite). Pick the right action by context:

- New session / returning to a project / "接着干 / 继续 / 之前干到哪了" / switched machine → `/progressing` (load)
- Mid-session, an entry's `Done when:` was just satisfied → `/progressing` (close)
- Session interrupted mid-way (network drop, switching machines, explicit handoff, pre-compaction) → `/progressing` (save) or `/progressing save`

### 4.1 Git merge / rebase / cherry-pick touching PROGRESS.md

Resolve by **union** (progressing skill, Save step 1): strip conflict markers, keep BOTH sides' entries (drop exact duplicate lines only — never choose between versions), stamp `> Last updated`, `git add PROGRESS.md`. Never pick one side at merge time; ambiguous near-duplicates surface at the next load's verify pass.

### 4.2 PROGRESS.md Is a Rolling Log

[PROGRESS.md](PROGRESS.md) is a recent-work log. PROGRESS holds 1-2 line pointers only — **architecture decisions and bug investigations must be persisted to `docs/specs/` / `docs/debug/` / `docs/architecture/` or code comments**, not just PROGRESS (detail is lost when entries age out).

### 4.3 Anti-patterns (workflow)

- ❌ Choosing one side of a PROGRESS.md conflict — union only (progressing Save step 1). Manual single-side resolution loses entries.
- ❌ Per-commit save ritual — routine commits with no unfinished work: do nothing.
- ❌ Missing closure suffix (`Done when:` / `Awaiting:` / `Restart:`) — invalid entry; no closure → `## Paused`.

## 5. Diagnostic Logging

`/tmp/nook-debug.log` (10 MB rolling) is enabled when the user toggles "Debug log" in settings. Enable it before reproducing a bug.

### 5.1 Debugging Rules (enforced)

1. **Read the log before claiming a bug.** Grep the FULL relevant window of `/tmp/nook-debug.log` first. (History: "Always+Confirm broken" claim was false — the flow worked, the log was never checked.)
2. **Never trigger the target app via `curl` to its local server.** The agent's own tools trigger the same paths: e.g. `Read` on `/etc/hosts` fires opencode's `permission.asked` → Nook notch expansion. Do not invent curl/abort/TUI-prompt workarounds — they are noisy, destructive, and waste user time.
3. **Trigger with the minimal native action** (Read a denied file, edit a file, etc.), then grep the log.

## 6. Build & Run

```bash
xcodebuild -project Nook.xcodeproj -scheme Nook -configuration Debug -destination 'platform=macOS' build
open ~/Library/Developer/Xcode/DerivedData/Nook-*/Build/Products/Debug/Nook.app
```

Tests: see README "Build From Source" + [docs/testing.md](docs/testing.md):

```bash
xcodebuild test -project Nook.xcodeproj -scheme Nook -configuration Debug -derivedDataPath build/TestDerivedData -destination 'platform=macOS'
```

---

**Reminder for AI agents**: This file is an entry pointer, not a knowledge base. **For specific decisions, read the linked spec / debug doc** — the summaries here are too short to be reliable.
