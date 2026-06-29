# Nook

<p align="center">
  <img src="./readme/ic_launcher.png" alt="Nook app icon" width="128" />
</p>

<p align="center">
  <strong>A live notch surface for AI coding sessions, music, and Mac status.</strong>
</p>

<p align="center">
  <a href="./readme/README.zh-CN.md">Simplified Chinese</a> ·
  <a href="https://github.com/oa1mgo/nook-notch/releases/latest">Download latest release</a>
</p>

<p align="center">
  <img src="./readme/img_nook_collapse.png" alt="Nook collapsed notch view" width="720" />
</p>

<p align="center">
  <img src="./readme/img_nook_expand.png" alt="Nook expanded sessions and music view" width="720" />
</p>

Nook turns the MacBook notch into a compact, always-available workspace layer. It keeps AI agent activity, session details, music playback, and system health close to where you already glance while working.

## Highlights

| Area | What Nook Adds |
| --- | --- |
| AI agents | Live monitoring for Claude Code, Codex, OpenCode, and Cursor sessions. |
| Session detail | Prompt, thinking, tool calls, tool results, approvals, questions, and completion state in one notch panel. |
| Music | Now playing card with artwork, source app icon, progress, seek, play/pause, previous/next, and open-source-app control. |
| Performance | CPU, memory, battery, and network snapshots with configurable visible metrics and detail pages. |
| Appearance | Music-driven dynamic color, macOS 26+ Glass, and pure Black styles selectable from Settings. |
| Controls | Screen picker, notification sound picker, keyboard shortcuts, launch at login, accessibility entry, and per-agent hook toggles. |

## Agent Support

Nook receives local hook events and turns them into a provider-neutral session timeline.

- Claude Code: hook install, status tracking, transcript parsing, interrupt detection, and tmux-aware focus helpers.
- Codex: hook install, transcript parsing, terminal approval state, compacting/subagent events, and stable completed-session history.
- OpenCode: event-stream integration with live tool placeholders and idle/completion transitions.
- Cursor: event integration for processing, compacting, completion, and session-end cleanup.

The expanded view shows active and completed sessions, provider identity, current status, working directory, and a chat-style detail view when you drill into a session.

## Music And Performance

Nook can sit quietly when agents are idle, then switch to music or performance context without opening another app.

- Music card: artwork, title, artist, album, progress, keyboard controls, and transport buttons.
- Adaptive color: the Music appearance uses album artwork colors for the expanded notch background.
- Edge glow: a subtle music progress glow can be toggled independently.
- Performance row: quick CPU, memory, battery, and network status on the home page.
- Performance detail: deeper CPU, memory, battery, network, process, and interface views.

## Appearance

Settings exposes three notch styles:

- Glass: real Liquid Glass on macOS 26+ builds and systems.
- Music: dynamic artwork colors when music is available, black fallback when it is not.
- Black: a clean solid black notch surface.

The collapsed notch stays visually quiet. Glass is only applied to the expanded panel, so the small closed notch keeps the native black look.

## Install

1. Download the latest `Nook.dmg` from [Releases](https://github.com/oa1mgo/nook-notch/releases/latest).
2. Drag `Nook.app` into `Applications`.
3. Open `Nook` from `Applications`.

If macOS blocks the first launch, open `System Settings` -> `Privacy & Security`, allow Nook to run, then open it again.

## Requirements

- macOS 15.6 or later.
- macOS 26 or later for the Glass appearance option.
- Claude Code, Codex, OpenCode, or Cursor installed for the matching agent integration.
- Accessibility permission is recommended for global shortcuts and focus behavior.

## Build From Source

```bash
xcodebuild -project Nook.xcodeproj -scheme Nook -configuration Debug build
```

```bash
xcodebuild test -project Nook.xcodeproj -scheme Nook -configuration Debug -derivedDataPath build/TestDerivedData -destination 'platform=macOS'
```

See [docs/testing.md](./docs/testing.md) for the current unit-test coverage and provider-specific testing notes.

## Project Map

- `Nook/App`: app lifecycle, menu bar/window setup, screen observation, single-instance handling.
- `Nook/Core`: settings, geometry, shortcuts, activity coordination, and view model state.
- `Nook/Services/Hooks`: local hook installers and Unix socket ingress for agent events.
- `Nook/Services/Session`: transcript parsing, status watching, and session monitoring.
- `Nook/Services/State`: central session store and tool-event processing.
- `Nook/Services/Music`: now playing integration, media controls, artwork color extraction.
- `Nook/Services/System`: performance sampling.
- `Nook/UI`: notch chrome, session list, chat detail, music, performance, and settings views.

## Acknowledgements

Nook was shaped by ideas from:

- [farouqaldori/claude-island](https://github.com/farouqaldori/claude-island)
- [TheBoredTeam/boring.notch](https://github.com/TheBoredTeam/boring.notch)
