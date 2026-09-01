# Release Notes

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
