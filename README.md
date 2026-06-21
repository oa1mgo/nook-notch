# Nook

<p align="center">
  <img src="./readme/ic_launcher.png" alt="Nook app icon" width="128" />
</p>

[简体中文](./readme/README.zh-CN.md)

Nook turns your MacBook notch into a live ambient surface for coding sessions and music playback.

It watches Claude Code and Codex in the background, surfaces the moments that matter, and gives your machine a sense of presence while you work. When your agents are busy, the notch shows motion and status. When a session becomes active again, it brings that change forward. When music is playing, Nook brings the track, artwork, and atmosphere into the same space instead of treating it like a separate app.

## At A Glance

<p align="center">
  <img src="./readme/img_nook_collapse.png" alt="Nook collapsed notch view" width="720" />
</p>

The collapsed notch stays quiet most of the time, then lights up with live AI activity or music presence when something meaningful is happening.

<p align="center">
  <img src="./readme/img_nook_expand.png" alt="Nook expanded session list and music controls" width="720" />
</p>

The expanded view gives you a session list, rich status context, and music controls without forcing you back into a terminal tab or another app window.

## Why Nook

Most AI coding tools still live inside terminal tabs. Most music controls still live somewhere else entirely.

Nook pulls both into one lightweight layer:

- AI session status stays visible without keeping a terminal in focus
- important session changes surface where your eyes already are
- music playback becomes part of the same ambient workspace
- album art can tint the expanded notch background for a more alive desktop feel

The result is less context switching and a notch that feels useful instead of ornamental.

## Highlights

- Follows both Claude Code and Codex sessions through local hooks
- Shows compact live processing states directly in the notch
- Expands into a session list and chat detail view
- Makes active sessions and status changes easy to spot
- Blends music playback, artwork, and progress into the same UI layer
- Uses artwork-derived color to make the notch feel more alive

## Core Experience

### AI Sessions

- Tracks Claude Code sessions through installed hooks
- Tracks Codex sessions through installed hooks
- Shows compact live activity while agents are processing
- Expands into session list and chat detail views
- Plays completion feedback when work is ready for your input

### Music Presence

- Displays now playing track, artist, artwork, and playback progress
- Supports transport controls from the expanded notch
- Shows a compact music activity when no higher-priority AI state is active
- Extracts artwork-driven colors for a richer adaptive background

## How It Feels

Nook is not trying to become another chat app, another terminal, or a full media player.

It is closer to a status instrument:

- quiet when nothing important is happening
- animated when work is in flight
- direct when a decision is needed
- atmospheric when music is playing

## Quick Start

### Requirements

- macOS
- Xcode
- Claude Code installed for Claude session monitoring
- Codex installed for Codex session monitoring

### Install

1. Open the released `Nook.dmg`.
2. Drag `Nook.app` into `Applications`.
3. Open `Nook` from `Applications`.

Because the current build is not signed with a Developer ID certificate, macOS may block the first launch.

If that happens:

1. Try opening `Nook` once, then dismiss the warning.
2. Go to `System Settings` -> `Privacy & Security`.
3. In the Security section, allow `Nook` to run anyway.
4. Open the app again.

### Build

```bash
xcodebuild -project Nook.xcodeproj -scheme Nook -configuration Debug build
```

### Test

```bash
xcodebuild test -project Nook.xcodeproj -scheme Nook -configuration Debug -derivedDataPath build/TestDerivedData -destination 'platform=macOS'
```

See [docs/testing.md](docs/testing.md) for the current unit-test coverage and
guidelines for adding provider-specific tests.

### Run

Launch `Nook.app` from Xcode or from DerivedData. On startup, Nook will:

- ensure only one app instance is running
- install or refresh Claude hook integration
- install or refresh Codex hook integration
- start the local Unix socket server
- create the notch window UI

## Project Layout

- `Nook/App`: app lifecycle, window setup, screen handling
- `Nook/Services/Hooks`: Claude/Codex hook installation and socket ingress
- `Nook/Services/State`: central session state store
- `Nook/Services/Session`: transcript parsing and monitoring
- `Nook/Services/Music`: now playing integration, playback control, artwork color extraction
- `Nook/UI`: notch window, views, and shared UI components
- `Nook/Models`: session, playback, and tool result models

## Local Integration Notes

- Claude hook traffic is bridged through `~/.claude/hooks/nook-state.py`
- Codex hook traffic is bridged through `~/.codex/hooks/nook-codex-hook.py`
- The local socket path is `/tmp/nook.sock`

## Acknowledgements

Nook was shaped in conversation with ideas from these projects:

- [farouqaldori/claude-island](https://github.com/farouqaldori/claude-island)
- [TheBoredTeam/boring.notch](https://github.com/TheBoredTeam/boring.notch)

Thank you to both projects for helping establish the creative direction around notch-native tooling and ambient desktop interactions.
