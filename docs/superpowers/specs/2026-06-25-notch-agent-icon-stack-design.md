# Notch Agent Icon Stack — Design Spec

## Overview

Refine the multi-agent icon carousel in the closed-state notch header so it shows
**at most two stacked icons** with a **consistent peek-out width**, regardless of
which providers are active. The Claude crab is currently landscape (66×52) and
pokes out further than the other square icons, breaking visual rhythm; this spec
also squares the crab's frame (content kept at the original 66×52 ratio) so the
peek width is uniform across all providers.

## Goals

- Cap the visible stack at 2 icons (front + 1 peek).
- The peek-out width to the right of the front icon is consistent for every
  provider.
- Front still rotates through all active providers every 2s; the second icon
  reflects the current front's "next" in the priority list.
- Crab content is **not** distorted — it stays in the original 66×52 ratio,
  centered in a square frame.

## Non-Goals

- Changing the rotation interval, animation duration, or animation curve.
- Changing the priority order (`claude > codex > opencode > cursor`).
- Changing the per-provider icon designs (Codex, OpenCode, Cursor geometry).
- Changing the icons' own animations (Claude legs, Codex glow, etc.).
- Adding hover, click, or any interaction on the stack.

## Current Behavior (baseline)

Source: `Nook/UI/Views/NotchView.swift:583-602`, `Nook/UI/Components/AgentProviderIcons.swift:121-198`.

- `displayOrder` rotates the **entire** active list by `carouselFront`; all
  active providers render in the `ZStack`.
- Per-icon: `AgentIcon(size: 14).padding(1)` (16pt slot), `scaleEffect` 1.0/0.85,
  `opacity` 1.0/0.55, `offset(x: index * 11)`, `zIndex(count - index)`.
- `ClaudeCrabIcon` frame is `size * (66/52) × size` (≈ 17.8×14 at size 14); its
  66×52 content is scaled to `size / 52` and centered horizontally. This makes
  the crab ~1.27× wider than the other square icons, so its peek sticks out
  ≈ 6pt further than other icons when it occupies the peek slot.

## Design

### Display rules

| Active count | Visible stack | Rotation |
|---|---|---|
| 0 | (none rendered) | n/a |
| 1 | `[provider]` | no rotation |
| 2 | `[front, next(front)]` | front swaps every 2s; the pair flips (front ↔ peek) |
| 3 | `[front, next(front)]` | front cycles through all 3; the "next" changes with the front |
| 4 | `[front, next(front)]` | front cycles through all 4; the "next" changes with the front |

`next(front)` is `active[(frontIndex + 1) % active.count]`, where `active` is
the priority-sorted list of processing providers. When the cached `carouselFront`
is not in `active` (provider just stopped), reset it to `active.first` and treat
that as the new front (existing stale-front logic is preserved).

### Layout parameters

| Constant | Value | Notes |
|---|---|---|
| `iconSize` | **16** | bumped from 14 to match the Agents settings page (16pt). Crabs in the settings use 12.6 content in 16×16; bumping notch to 16 keeps the proportions consistent across contexts. |
| `iconPadding` | 1 | unchanged |
| `slot` | 18 (= size + 2 × padding) | derived from `iconSize` |
| `peekOffset` | **13** | bumped from 11 to keep the relative offset-to-slot ratio (~0.72). Gives ≈ 10.3pt visible peek. |
| `peekScale` | 0.85 | unchanged |
| `peekOpacity` | 0.55 | unchanged |
| `rotationInterval` | 2.0s | unchanged |
| `animation` | `.smooth(duration: 0.5)` | unchanged for both per-icon and whole-stack |

These constants are extracted as `private let` at the top of `NotchView` (or
kept inline with a clarifying comment) so the relationship between `slot`,
`peekOffset`, and the resulting visible peek is obvious from the code.

Vertical headroom in the closed-state header row: `max(24, closedNotchSize.height)`.
Modern MacBook notch height is ~32-38pt; 16pt icon + 2pt padding = 18pt total,
fits with 3pt+ of margin top/bottom. Safe at any notch size.

### Crab frame squaring

`ClaudeCrabIcon` (in `AgentProviderIcons.swift`) currently uses
`size * (66/52) × size` as its frame. Change it to `size × size` and adapt the
canvas transform:

- Replace `scale = size / 52.0` (fit height) with `scale = size / 66.0` (fit
  width).
- Compute `yOffset = (canvasSize.height - 52 * scale) / 2` to center the
  content vertically in the new square frame.
- Apply `yOffset` alongside the existing `xOffset` in the
  `CGAffineTransform.translatedBy(...)` calls on each crab part.

Result: the crab still renders in its native 66×52 aspect ratio (no
horizontal stretching), centered in a 14×14 square frame. The empty ~1.5pt
top/bottom sliver lets the notch background show through, which is fine
because the notch header is a solid color in closed state.

### Per-icon visual hierarchy

| Index | role | scale | opacity | zIndex | offset.x |
|---|---|---|---|---|---|
| 0 | front | 1.0 | 1.0 | count | 0 |
| 1 | peek | 0.85 | 0.55 | count - 1 | 11 |

Front draws on top of peek. The peek's reduced scale and opacity make the
hierarchy readable while still showing a clear, consistent ~8.6pt sliver.

## Files Changed

| File | Change |
|---|---|
| `Nook/UI/Views/NotchView.swift` | (1) `displayOrder` returns exactly `[front, next(front)]` (cap at 2) instead of the full rotated list. (2) `offset(x:)` is the existing `CGFloat(index) * 11`. (3) Optional: extract `iconSize`, `peekOffset`, `peekScale`, `peekOpacity`, `rotationInterval` as named constants. |
| `Nook/UI/Components/AgentProviderIcons.swift` | (1) `ClaudeCrabIcon` body: square frame `size × size`, scale `size/66`, vertical centering via `yOffset`, `translatedBy(x: xOffset/scale, y: yOffset/scale)` for every crab part. |

## Edge Cases & Behavior

- **Provider stops mid-tick**: stale-front reset still works — `carouselFront`
  is reset to `active.first`, and the stack renders `[active.first,
  active[1 % count]]`.
- **Provider joins mid-tick**: when a new provider enters `active`, the
  rotation continues from the current `carouselFront` (or resets to
  `active.first` if the current front is no longer in `active`).
- **N=1 transition**: when count drops to 1, the rotation guard
  `active.count > 1` (existing) returns early; the single icon stays put.
- **N=0**: existing `if !activeProcessingProviders.isEmpty` guard skips
  rendering the ZStack entirely.

## Verification

- **Manual build**: `xcodebuild` the Nook scheme for macOS; open the running
  app, ensure the notch shows the icon stack as expected.
- **Visual checks**:
  1. 1 agent processing: single icon, no rotation.
  2. 2 agents: two icons stacked, front/back labels swap every 2s.
  3. 3+ agents: two icons stacked, "second" icon changes as front rotates.
  4. Crab as front or peek: peek width matches the other icons (no extra
     poke-out from the crab's prior landscape frame).
- **Regression**: prior `cd53dfb fix(opencode-phase)`, `732c998 feat(agents)`,
  and `7ad521e feat(notch): multi-agent icon carousel` commits should not be
  undone.

## Out of Scope

- Refactoring the carousel into a reusable component (the inline ZStack in
  `headerRow` is fine; this spec touches the minimum to achieve consistency).
- Adding tooltips or accessibility labels for the stack.
- Animating the peek-out width itself (e.g., a subtle pulse). The 0.5s
  `.smooth` already covers the front/back swap.
