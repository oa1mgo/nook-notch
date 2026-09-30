# Release Notes

## 1.5.0

What's New

  - Question Tool Notch Prompt — when an agent asks a question via `AskUserQuestion`, the notch now expands into a dedicated answer panel instead of silently showing a checkmark. The closed notch shows a three-segment chip (question mark · provider + question summary · music wave). Options render as tappable A/B/C cards; a free-text field accepts custom answers. Multiple concurrent questions use a left/right swiper. For OpenCode, tapping an option or sending free text replies over the plugin command socket (`question.reply` → opencode `/session/{id}/question/{requestID}/reply`). Claude / Codex / Cursor keep the existing "Go to Terminal" flow in this phase (Phase 2 will add tmux `sendKeys` inline replies). Introduces a `QuestionReplyProvider` protocol so the UI is provider-agnostic. See `docs/specs/2026-09-02-question-tool-notch-prompt-design.md`.

  - Session List Reply Shortcut Target — pressing ⌃R in the session list resolves its target through a shared 0/1/2+ rule: with no waiting session it does nothing, with exactly one it enters that session's question page regardless of the highlight (previously required a selected row), and with two or more the highlighted row must be a waiting one. The permission Y/N/A shortcuts use the same resolver, and stale keyboard-trigger replays across menu navigation are cleared so an old ⌃R cannot bounce you back into the question page.

  - Terminal Focus Extraction — `ChatView`'s three-tier terminal-focus logic (yabai/tmux → process tree → bundle-ID fallback) is extracted into a reusable `TerminalFocusHelper`, so the question panel and other callers can focus a terminal without a view dependency.

## 1.4.3

What's Fixed

  - Restored Codex User Messages — recognizes Desktop's direct UserMessage events alongside the legacy user_message format. Real user input appears again; injected memory, environment context, and duplicate model-input records remain excluded.
  - Complete Codex History — loads every matching rollout fragment, validates the actual session identity, and tracks each file independently. Stable message IDs prevent duplicate history on reload and overlapping fragments.
  - Live Conversation Updates — refreshes transcript content after hooks and while a turn is active, including text-only replies and a bounded final-response catch-up after Stop. History refresh does not reactivate completed sessions or replay completion notifications.
  - Safer Resets and Ordering — serializes concurrent reads, cancels stale results on clear/end, and orders transcript text and live tools by source timestamps.
  - Xcode Compatibility — explicitly qualifies Markdown.Document to avoid the new SwiftUI.Document name collision in Xcode 27; rendering behavior is unchanged.
  - Release Version — Nook 1.4.3 (build 3). Music Glow, audio permissions, native installer layout, and signing policy are unchanged.

## 1.4.2

What's New

  - Refined Music Accents (Beta) — evaluates frequency ranges independently so quieter pickups are less likely to block following heavy hits, and alternating low- and mid-frequency accents remain eligible.
  - Better Strong/Weak Separation — considers each attack's importance in the whole mix, reduces over-bright responses to minor accompaniment, and rejects tested smooth bass modulation and fading-tail artifacts.
  - Gentler Slow-Passage Tails — gradually lengthens visible falloff when repeated sparse accents support it, while keeping the 50ms rise, immediate decline, album-colored ambient base, and existing glow appearance. Dense music remains responsive; real-audio response stays opt-in.
  - Simple Native Installer — replaces the custom image-based installer with a compact 480 × 280 Finder window and real Nook / Applications icons. No background image, Retina bitmap selection, or scaled decorative text remains.
  - Stronger Regression Checks — 99 app tests and 16 packaging tests cover music timing, fast/slow transitions, pause/reset behavior, native Finder layout, and the Applications drop target. Packaged app signatures and disk images are verified before publication.
  - Republished 1.4.2 (Build 2) — replaces the earlier 1.4.2 installer and includes the latest Music Glow improvements. Download this DMG again if you have the original 1.4.2 package. The regular permission-free glow is unchanged; audio-reactive behavior remains experimental and Bluetooth output delay is not automatically compensated.

## 1.4.1

What's New

  - Redesigned Installer — introduces a compact drag-to-install window with Nook on the left, a working Applications shortcut on the right, clear instructions, and a Retina-ready background.
  - More Responsive Music Glow (Beta) — replaces tempo-lock and fixed-stride gating with multi-band audio transient detection and timestamped animations. Active audio analysis no longer adds periodic flashes unrelated to the music.
  - Ambient Music Light — keeps a low album-colored base beneath accents so the glow brightens and settles back naturally. Pausing fades the light out and stops capture; sustained silence also extinguishes it.
  - Existing Controls Preserved — regular Music Edge Glow keeps its permission-free breathing effect, while real-audio response remains behind the separate Beta Features opt-in. Glow size, colors, and maximum brightness are unchanged.
  - Safer Packaging — validates the Applications link, Finder layout, disk-image integrity, and packaged app signature before publishing. English and Chinese READMEs now include installation instructions and the new window screenshot.
  - Release Version — bumps Nook to version 1.4.1. Audio-reactive behavior remains experimental; Bluetooth output delay is not automatically compensated.

## 1.4.0

What's New

  - Audio-Reactive Music Glow (Beta) — adds an opt-in Beta Features control that follows system output audio with locally derived spectrum, tempo, and prominent accents.
  - Live Compact Music Bars — drives the small-notch four-bar visualization from real audio while analysis is active, while retaining the simulated animation when it is not.
  - Permission-Friendly Fallback — keeps the regular Music Edge Glow permission-free with its existing breathing effect, starts capture only when the Beta option is enabled, and falls back cleanly with actionable feedback if capture fails.
  - Refined Codex Activity Feedback — restores the animated Codex processing ring in session and chat rows, and uses the ChatGPT knot mark for activity in the small notch while preserving the Codex product icon in Agents settings.
  - Regression Coverage — adds presentation-policy and signal-processing tests for the new audio-reactive behavior; the full macOS suite passes 60 tests.
  - Release Version — bumps Nook to version 1.4.0.

## 1.3.3

What's New

  - Current Codex Hook Lifecycle — adds `SessionEnd` handling alongside the existing start, prompt, tool, compaction, subagent, and stop hooks so sessions are removed promptly when the main thread ends.
  - Direct User Conversation History — records user history from Codex's dedicated direct-interaction event and no longer treats injected memories, environment context, or plugin recommendations as user messages.
  - Updated Tool Payload Support — preserves current Codex string tool inputs and text results carried in array-based tool outputs.
  - Safer Hook Configuration — writes hook configuration atomically, preserves unrelated user and plugin hooks during uninstall, and uses Codex's three-second maximum specifically for `SessionEnd`.
  - Regression Coverage — adds tests for `SessionEnd`, direct-user filtering, and current tool input/output payload shapes.
  - Release Version — bumps Nook to version 1.3.3.

## 1.3.2

What's New

  - Picker Layout & Scrollbar Fixes — resolves four picker bugs, replaces the GeometryReader feedback loop with a compile-time `PickerLayout`, and lands a five-layer fix for scrollbar flicker on picker toggle. Panel height is now derived from layout instead of measured geometry. See `docs/specs/2026-07-07-picker-height-and-broadcast-pattern.md` for the must-do / must-not rules going forward.
  - Claude Provider Fixes — falls back to a per-pid status file when a session is stuck processing, and routes `ExitPlanMode` `PostToolUse` events to `waiting_for_input` so the UI no longer hangs on tool approval.
  - Performance Row Shortcut — ⌃M opens the Performance overview from the instances page. Vibe glow animation refresh rate is reduced for less CPU on long sessions.
  - Focus Restoration Fix — keyboard shortcut close (Esc / ⌃⌘L) still returns focus to the previously active app, but clicking another app no longer yanks focus back to the pre-notch app. The captured app reference is now cleared on every close so the next open captures fresh state. Side effect: the ChatView "focus terminal" path now keeps focus on the terminal after the notch closes.
  - ⌃O Closes Notch — pressing ⌃O (or tapping the music artwork) to open the music source app also collapses the notch so the user actually sees the app they just asked for.
  - AI Contributor Entry Points — adds `CLAUDE.md` and `AGENTS.md` at the project root so AI coding agents pick up Nook's hard constraints (picker integration, single-source-of-truth, cross-process event compatibility) without reading the full architecture lessons.
  - Settings Polish — suppresses the native Button pressed highlight on row click, and translates the leftover Chinese focus error message in `ChatView` to English to match the rest of the UI.
  - Release Version — bumps Nook to version 1.3.2.

## 1.3.1

What's New

  - Notch Appearance Styles — adds selectable Glass, Music, and Black styles in the settings design controls.
  - Liquid Glass Support — shows the Glass option on macOS 26+ only and tunes the expanded notch glass surface for a clearer, lighter translucent look.
  - Music Background Style — keeps the artwork-driven dynamic music background available as its own style.
  - Black Style — adds a solid black appearance option and keeps the collapsed notch free of glass treatment.
  - Release Version — bumps Nook to version 1.3.1.

## 1.3.0

What's New

  - Cursor Sessions — adds Cursor session monitoring, hook ingestion, and chat history support alongside Claude Code, Codex, and opencode.
  - Agent Transcript Reliability — improves Codex lifecycle routing, transcript synchronization, terminal approval state, and provider-specific chat item updates.
  - Codex Completion Feedback — restores completion sounds after Codex Stop and keeps completed Codex turns visible as idle history instead of flashing out of the session list.
  - Unit Test Coverage — adds a macOS `NookTests` target covering provider adapters, transcript parsing, session lifecycle reducers, and Codex completion cleanup to protect future refactors.
  - Agent UI Polish — refreshes provider icons and badges, keeps Vibe Glow focused on the glow effect, and hides header activity controls while Vibe Glow is enabled.
  - Opencode and Chat Rendering — improves AskUserQuestion handling, subagent output cleanup, image attachments, GFM table rendering, and tool result presentation.
  - Performance Settings — adds configurable performance metric detail settings with reusable settings rows.
  - Notification Sounds — adds built-in notification sound choices and louder completion feedback.
  - Release Version — bumps Nook to version 1.3.0.

## 1.2.3

What's New

  - Vibe Glow — adds a settings toggle for a soft surrounding glow while an agent is actively working.
  - Closed Notch Behavior — keeps normal music glow when no agent is running, and shows no glow when neither music nor agent activity is present.
  - Agent State Polish — suppresses the closed-state agent side animations while Vibe Glow is active and improves Codex turn completion handling.
  - Release Version — bumps Nook to version 1.2.3.

## 1.2.2

What's New

  - Performance Monitor — adds a compact home-page monitor for CPU, memory, battery, and network with a settings toggle.
  - Detailed System Pages — adds CPU, memory, battery, and network detail pages with richer stats, charts, axes, and hover values.
  - Memory Details — adds Activity Monitor-style memory pressure breakdown and app-grouped process list with icons.
  - Release Version — bumps Nook to version 1.2.2.

## 1.2.1

What's New

  - Ambient Music Background Startup — fixes first-run artwork/adaptive background initialization when music is already playing.
  - Panel Click Handling — prevents outside-panel clicks from being replayed as a second click behind Nook.
  - Agent Header Icons — removes the idle Claude icon in the expanded panel and only shows the active agent icon when an agent is running.
  - Release Version — bumps Nook to version 1.2.1.

## 1.2.0

What's New

  - Codex Hook Updates — adapts Codex lifecycle parsing for newer hook events and improves status transitions.
  - Music Playback Stability — keeps artwork, adaptive background, and progress state stable across pause/resume and stream restarts.
  - Opencode Session UI — adds plugin event forwarding, live tool output, subagent routing/progress, and question/approval handling.
  - Keyboard Controls — adds configurable shortcuts for navigation, scrolling, playback, and app actions.
  - New App Package Identity — bumps Nook to version 1.2.0 and ships under bundle identifier com.oaimgo.nook.

## 1.1.1

What's New

  - AI Session Status in Notch — Monitor Claude Code and Codex sessions directly from your MacBook notch. See approval requests, completions, and session state without switching to the terminal.
  - Music Now Playing — Displays currently playing music with album artwork-driven adaptive backgrounds and transport controls (play/pause, skip) directly from the expanded notch.
  - Approval Handling — Tool approval requests surface in the notch UI. Approve or dismiss directly from the notch menu.
  - Multi-Screen Support — Automatically detects and positions the notch window across connected displays.
  - Real-time Hook Integration — Communicates with Claude Code and Codex via Unix domain sockets for low-latency event updates.
  - Settings Panel — Configure screen selection, sound notifications, and Claude working directory directly from the notch menu.
