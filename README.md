# Nook

<p align="center">
  <img src="./readme/ic_launcher.png" alt="Nook app icon" width="112" />
</p>

<p align="center">
  <strong>A live MacBook notch surface for agents, music, and system status.</strong>
</p>

<p align="center">
  <a href="./readme/README.zh-CN.md">Simplified Chinese</a> ·
  <a href="https://github.com/oa1mgo/nook-notch/releases/latest">Download latest release</a>
</p>

<p align="center">
  <img src="./readme/img_nook_home.png" alt="Nook home view with performance, music, and agent sessions" width="720" />
</p>

<p align="center">
  <img src="./readme/img_nook_settings.png" alt="Nook settings view" width="720" />
</p>

<p align="center">
  <img src="./readme/img_nook_compact_music.png" alt="Nook compact music notch" width="225" />
  <img src="./readme/img_nook_compact_music_artwork.png" alt="Nook compact music notch with artwork" width="225" />
  <img src="./readme/img_nook_compact_music_glow.png" alt="Nook compact music notch with glow" width="225" />
</p>

Nook turns the MacBook notch into a compact desktop control layer. The home view keeps high-signal context in one place: Mac performance, now playing controls, and live AI coding sessions.

## What It Does

| Area | Features |
| --- | --- |
| Agent sessions | Monitor Claude Code, Codex, OpenCode, and Cursor from local hook events. |
| Session detail | Show prompts, thinking, tool calls, tool results, approvals, user questions, completion state, and token usage. |
| Music | Display artwork, source app, track metadata, progress, playback controls, and artwork-colored glow with optional audio-reactive effects. |
| System status | Surface CPU, memory, battery, and network status with configurable performance detail pages. |
| Settings | Configure screen selection, notification sound, agent hooks, shortcuts, glow effects, launch at login, accessibility, and opt-in Beta features. |
| Appearance | Switch between Music dynamic color, macOS 26+ Glass, and pure Black notch styles. |

## Agent Support

Nook normalizes local agent events into a shared session timeline.

- Claude Code: hooks, transcript parsing, status tracking, interrupt detection, permission handling, and tmux-aware terminal focus.
- Codex: hooks, transcript parsing, terminal approval state, compacting and subagent events, and stable completed-session history.
- OpenCode: event-stream integration with live tool placeholders, user-input state, subagent tracking, and idle/completion transitions.
- Cursor: session lifecycle, processing/compacting state, thought and response updates, tool calls, and session cleanup.

## Appearance

The settings page exposes three notch styles:

- `Music`: uses artwork-derived colors for the expanded notch when music is playing.
- `Glass`: uses Liquid Glass on macOS 26+ and only appears when supported.
- `Black`: keeps the expanded notch clean and solid black.

The collapsed notch stays visually quiet; the glass treatment is limited to the expanded panel.

## Music Glow

Turn on `Settings` → `Music Edge Glow` for artwork-colored light around the collapsed notch. By itself, this uses a fixed breathing rhythm and requires no audio-capture permission.

For real audio response, also open `Settings` → `Beta Features...` (below Accessibility) and enable `Audio-Reactive Music Glow`. This Beta option is off by default; enabling it requests macOS system-audio recording permission.

- Audible attacks brighten the glow above a low, persistent album-colored base, then settle back to that base. There is no fixed-frequency fallback while audio analysis is active.
- Music without strong attacks keeps the base light. Pausing fades the glow out and stops capture; sustained silence also extinguishes it.
- The compact notch's four music bars show analyzed audio levels while Beta capture is running; otherwise, they retain their simulated animation.
- Audio is analyzed locally in memory, not saved to recordings or uploaded. This uses system playback audio, not microphone input.

Turning off Beta restores the regular permission-free breathing effect. Beat response remains experimental, and Bluetooth output delay is not automatically compensated.

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
- System-audio recording permission is only needed for Audio-Reactive Music Glow Beta.

## Build From Source

```bash
xcodebuild -project Nook.xcodeproj -scheme Nook -configuration Debug build
```

```bash
xcodebuild test -project Nook.xcodeproj -scheme Nook -configuration Debug -derivedDataPath build/TestDerivedData -destination 'platform=macOS'
```

See [docs/testing.md](./docs/testing.md) for testing notes.
For the Music Glow design, regression coverage, and a reproducible five-style audio comparison, see the [Music Glow technical notes](./docs/specs/2026-09-11-music-glow-transients.md).

## Project Map

- `Nook/Core`: settings, geometry, shortcuts, activity coordination, and view model state.
- `Nook/Services/Hooks`: hook installers and Unix socket ingress for agent events.
- `Nook/Services/Session`: transcript parsing, status watching, and session monitoring.
- `Nook/Services/State`: central session store and tool-event processing.
- `Nook/Services/Music`: now playing integration, media controls, artwork colors, and opt-in system-audio analysis for reactive glow and music bars.
- `Nook/Services/System`: performance sampling.
- `Nook/UI`: notch shell, session list, chat detail, music, performance, and settings views.

## Acknowledgements

Nook was shaped by ideas from:

- [farouqaldori/claude-island](https://github.com/farouqaldori/claude-island)
- [TheBoredTeam/boring.notch](https://github.com/TheBoredTeam/boring.notch)
