# Release Notes

## 1.3.0

What's New

  - Cursor Sessions — adds Cursor session monitoring, hook ingestion, and chat history support alongside Claude Code, Codex, and opencode.
  - Agent Transcript Reliability — improves Codex lifecycle routing, transcript synchronization, terminal approval state, and provider-specific chat item updates.
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
