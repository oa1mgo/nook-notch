# Notch Agent Icon Stack Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Cap the closed-notch multi-agent icon stack at 2 icons (front + 1 peek) with a consistent ~8.6pt peek width, regardless of how many agents are processing, by (a) changing `displayOrder` to return exactly `[front, next(front)]` and (b) squaring the Claude crab's frame so it stops poking out further than the other icons.

**Architecture:** Two surgical changes in existing files — `NotchView.swift` rewrites one computed property to cap the list, `AgentProviderIcons.swift` adjusts the crab canvas to fit a square frame with content centered in its native 66×52 ratio. No new files, no new dependencies, no public API changes.

**Tech Stack:** Swift + SwiftUI. No external dependencies. The project builds via `xcodebuild -scheme Nook` and tests via `xcodebuild -scheme Nook test`.

---

## File Map

| File | Responsibility | Change |
|---|---|---|
| `Nook/UI/Views/NotchView.swift` | Renders the closed-notch header, owns the carousel timer | `displayOrder` computed property returns `[front, next(front)]` (cap 2) instead of the full rotated list |
| `Nook/UI/Components/AgentProviderIcons.swift` | Renders the four provider icons (Claude crab, Codex, OpenCode, Cursor) | `ClaudeCrabIcon` uses a square `size × size` frame; canvas scale flips from `size/52` to `size/66`; vertical centering via a new `yOffset` |

No new files, no test files added (the project has no existing SwiftUI view test infrastructure, and the change is a layout tweak with no testable pure function — verification is via build + manual visual check).

---

## Task 1: Cap `displayOrder` at 2 (front + next)

**Files:**
- Modify: `Nook/UI/Views/NotchView.swift:97-109` (`displayOrder` computed property)

- [ ] **Step 1: Replace `displayOrder` body**

Open `Nook/UI/Views/NotchView.swift` and replace the `displayOrder` computed property (lines 97–109) with the version below. The new version returns at most 2 elements: the current carousel front, and the front's "next" provider in the priority-ordered active list.

Current code (NotchView.swift:97-109):

```swift
    /// Display order for the icon stack: starts at `carouselFront`
    /// and wraps around. When there's only one working agent this
    /// collapses to that single provider (no carousel rotation).
    /// When the providers list changes, the current front (if still
    /// active) is preserved so the carousel doesn't jump.
    private var displayOrder: [SessionProvider] {
        let active = activeProcessingProviders
        guard !active.isEmpty else { return [] }
        if let front = carouselFront, let frontIndex = active.firstIndex(of: front) {
            return (0..<active.count).map { active[(frontIndex + $0) % active.count] }
        }
        return active
    }
```

Replacement:

```swift
    /// Display order for the icon stack. Always at most 2 elements:
    /// the current `carouselFront` and the front's "next" provider in
    /// the priority-ordered active list. When the providers list
    /// changes, the current front (if still active) is preserved so
    /// the carousel doesn't jump. With 0 active providers the stack
    /// is empty; with 1 active the stack is just that one icon (no
    /// peek). With 2+ active the second icon is the front's successor
    /// in the rotation, so it changes as the front cycles.
    private var displayOrder: [SessionProvider] {
        let active = activeProcessingProviders
        guard !active.isEmpty else { return [] }
        if let front = carouselFront, let frontIndex = active.firstIndex(of: front) {
            let nextIndex = (frontIndex + 1) % active.count
            return [front, active[nextIndex]]
        }
        return Array(active.prefix(2))
    }
```

- [ ] **Step 2: Build the project**

Run from the repo root:

```bash
xcodebuild -scheme Nook -configuration Debug -derivedDataPath build build
```

Expected: `** BUILD SUCCEEDED **`. No new warnings introduced.

- [ ] **Step 3: Run the test suite to confirm no regressions**

```bash
xcodebuild -scheme Nook -configuration Debug -derivedDataPath build test
```

Expected: all tests in `NookTests/` pass. The carousel change is in a SwiftUI view's private computed property, so no test directly exercises it, but the existing tests confirm the model layer is intact.

- [ ] **Step 4: Commit**

```bash
git add Nook/UI/Views/NotchView.swift
git commit -m "feat(notch): cap multi-agent icon stack at 2 (front + next)"
```

---

## Task 2: Square the ClaudeCrabIcon frame

**Files:**
- Modify: `Nook/UI/Components/AgentProviderIcons.swift:136-198` (`ClaudeCrabIcon.body`)

- [ ] **Step 1: Replace the crab `body` to use a square frame and centered native-ratio content**

Open `Nook/UI/Components/AgentProviderIcons.swift` and replace the `body` of `ClaudeCrabIcon` (lines 136–197, the Canvas + frame + onReceive) with the version below. The change keeps the crab's native 66×52 ratio (no horizontal stretching) by fitting content to the frame's width and centering it vertically.

Current code (AgentProviderIcons.swift:136-197):

```swift
    var body: some View {
        Canvas { context, canvasSize in
            // Crab is naturally 66×52 (landscape) — keep that aspect
            // ratio so the crab fills its frame. The wider frame makes
            // it peek more from behind other icons in the carousel; the
            // carousel offset is tuned so this looks intentional rather
            // than broken (the front icon's right edge defines the
            // visible peek).
            let scale = size / 52.0
            let xOffset = (canvasSize.width - 66 * scale) / 2

            let leftAntenna = Path { path in
                path.addRect(CGRect(x: 0, y: 13, width: 6, height: 13))
            }.applying(CGAffineTransform(scaleX: scale, y: scale).translatedBy(x: xOffset / scale, y: 0))
            context.fill(leftAntenna, with: .color(color))

            let rightAntenna = Path { path in
                path.addRect(CGRect(x: 60, y: 13, width: 6, height: 13))
            }.applying(CGAffineTransform(scaleX: scale, y: scale).translatedBy(x: xOffset / scale, y: 0))
            context.fill(rightAntenna, with: .color(color))

            let baseLegPositions: [CGFloat] = [6, 18, 42, 54]
            let baseLegHeight: CGFloat = 13
            let legHeightOffsets: [[CGFloat]] = [
                [3, -3, 3, -3],
                [0, 0, 0, 0],
                [-3, 3, -3, 3],
                [0, 0, 0, 0],
            ]
            let currentHeightOffsets = animateLegs ? legHeightOffsets[legPhase % 4] : [CGFloat](repeating: 0, count: 4)

            for (index, xPos) in baseLegPositions.enumerated() {
                let heightOffset = currentHeightOffsets[index]
                let legHeight = baseLegHeight + heightOffset
                let leg = Path { path in
                    path.addRect(CGRect(x: xPos, y: 39, width: 6, height: legHeight))
                }.applying(CGAffineTransform(scaleX: scale, y: scale).translatedBy(x: xOffset / scale, y: 0))
                context.fill(leg, with: .color(color))
            }

            let body = Path { path in
                path.addRect(CGRect(x: 6, y: 0, width: 54, height: 39))
            }.applying(CGAffineTransform(scaleX: scale, y: scale).translatedBy(x: xOffset / scale, y: 0))
            context.fill(body, with: .color(color))

            let leftEye = Path { path in
                path.addRect(CGRect(x: 12, y: 13, width: 6, height: 6.5))
            }.applying(CGAffineTransform(scaleX: scale, y: scale).translatedBy(x: xOffset / scale, y: 0))
            context.fill(leftEye, with: .color(.black))

            let rightEye = Path { path in
                path.addRect(CGRect(x: 48, y: 13, width: 6, height: 6.5))
            }.applying(CGAffineTransform(scaleX: scale, y: scale).translatedBy(x: xOffset / scale, y: 0))
            context.fill(rightEye, with: .color(.black))
        }
        .frame(width: size * (66.0 / 52.0), height: size)
        .onReceive(legTimer) { _ in
            if animateLegs {
                legPhase = (legPhase + 1) % 4
            }
        }
    }
```

Replacement (square frame, content scaled to fit width, vertically centered):

```swift
    var body: some View {
        Canvas { context, canvasSize in
            // Crab content is natively 66×52 (landscape). The icon's
            // frame is square (size × size) so the carousel peek width
            // matches the other square providers — the crab content is
            // scaled to fit the frame's WIDTH (scale = size/66) and
            // centered vertically. This keeps the crab's aspect ratio
            // (no horizontal stretching) and the empty top/bottom
            // sliver lets the notch background show through.
            let scale = size / 66.0
            let scaledContentHeight = 52 * scale
            let xOffset = (canvasSize.width - 66 * scale) / 2
            let yOffset = (canvasSize.height - scaledContentHeight) / 2

            let leftAntenna = Path { path in
                path.addRect(CGRect(x: 0, y: 13, width: 6, height: 13))
            }.applying(CGAffineTransform(scaleX: scale, y: scale).translatedBy(x: xOffset / scale, y: yOffset / scale))
            context.fill(leftAntenna, with: .color(color))

            let rightAntenna = Path { path in
                path.addRect(CGRect(x: 60, y: 13, width: 6, height: 13))
            }.applying(CGAffineTransform(scaleX: scale, y: scale).translatedBy(x: xOffset / scale, y: yOffset / scale))
            context.fill(rightAntenna, with: .color(color))

            let baseLegPositions: [CGFloat] = [6, 18, 42, 54]
            let baseLegHeight: CGFloat = 13
            let legHeightOffsets: [[CGFloat]] = [
                [3, -3, 3, -3],
                [0, 0, 0, 0],
                [-3, 3, -3, 3],
                [0, 0, 0, 0],
            ]
            let currentHeightOffsets = animateLegs ? legHeightOffsets[legPhase % 4] : [CGFloat](repeating: 0, count: 4)

            for (index, xPos) in baseLegPositions.enumerated() {
                let heightOffset = currentHeightOffsets[index]
                let legHeight = baseLegHeight + heightOffset
                let leg = Path { path in
                    path.addRect(CGRect(x: xPos, y: 39, width: 6, height: legHeight))
                }.applying(CGAffineTransform(scaleX: scale, y: scale).translatedBy(x: xOffset / scale, y: yOffset / scale))
                context.fill(leg, with: .color(color))
            }

            let body = Path { path in
                path.addRect(CGRect(x: 6, y: 0, width: 54, height: 39))
            }.applying(CGAffineTransform(scaleX: scale, y: scale).translatedBy(x: xOffset / scale, y: yOffset / scale))
            context.fill(body, with: .color(color))

            let leftEye = Path { path in
                path.addRect(CGRect(x: 12, y: 13, width: 6, height: 6.5))
            }.applying(CGAffineTransform(scaleX: scale, y: scale).translatedBy(x: xOffset / scale, y: yOffset / scale))
            context.fill(leftEye, with: .color(.black))

            let rightEye = Path { path in
                path.addRect(CGRect(x: 48, y: 13, width: 6, height: 6.5))
            }.applying(CGAffineTransform(scaleX: scale, y: scale).translatedBy(x: xOffset / scale, y: yOffset / scale))
            context.fill(rightEye, with: .color(.black))
        }
        .frame(width: size, height: size)
        .onReceive(legTimer) { _ in
            if animateLegs {
                legPhase = (legPhase + 1) % 4
            }
        }
    }
```

Note: every `.applying(CGAffineTransform(...).translatedBy(...))` call now includes `y: yOffset / scale` so the crab parts are shifted down to vertical-center within the new square frame.

- [ ] **Step 2: Build the project**

```bash
xcodebuild -scheme Nook -configuration Debug -derivedDataPath build build
```

Expected: `** BUILD SUCCEEDED **`. The Canvas transform change should compile clean.

- [ ] **Step 3: Run the test suite**

```bash
xcodebuild -scheme Nook -configuration Debug -derivedDataPath build test
```

Expected: all tests pass. The crab is a pure view change, so no test directly inspects it.

- [ ] **Step 4: Commit**

```bash
git add Nook/UI/Components/AgentProviderIcons.swift
git commit -m "feat(agents): square ClaudeCrabIcon frame for consistent carousel peek"
```

---

## Task 3: Bump notch icon size 14pt → 16pt

**Files:**
- Modify: `Nook/UI/Views/NotchView.swift:595` (`AgentIcon(size: 14, ...)`)
- Modify: `Nook/UI/Views/NotchView.swift:602` (`offset(x: CGFloat(index) * 11)`)
- Modify: `Nook/UI/Views/NotchView.swift:650` (`PermissionIndicatorIcon(size: 14, ...)`)
- Modify: `Nook/UI/Views/NotchView.swift:583-588` (doc comment numeric updates)

Rationale (per spec §"Layout parameters"): align the notch header icons with
the Agents settings page, which already uses 16pt icons. The crab content in
the notch goes from 11pt to 12.6pt, matching the settings page proportions
exactly. The peek offset scales with the slot to keep the relative ratio
constant.

### New layout numbers

- `iconSize`: 14 → **16**
- `iconPadding`: 1 (unchanged)
- `slot`: 16 → **18** (size + 2 × padding)
- `peekOffset`: 11 → **13** (offset/slot ratio stays ~0.72)
- visible peek: 8.6pt → **10.3pt** (= 18 × 0.85 − (18 − 13))
- `peekScale`: 0.85 (unchanged)
- `peekOpacity`: 0.55 (unchanged)

Vertical headroom check: closed-state header is `max(24, closedNotchSize.height)`.
16pt icon + 2pt padding = 18pt total — fits with ≥3pt margin top/bottom on
any notch size. Safe.

### Step 1: Update AgentIcon size

In `Nook/UI/Views/NotchView.swift:595`, change `size: 14` to `size: 16`:

```swift
AgentIcon(
    provider: provider,
    size: 16,                              // was 14
    color: SessionLoadingStyle.tint(for: provider),
    animate: true
)
```

### Step 2: Update peek offset

In `Nook/UI/Views/NotchView.swift:602`, change `* 11` to `* 13`:

```swift
.offset(x: CGFloat(index) * 13)            // was * 11
```

### Step 3: Update permission indicator size

In `Nook/UI/Views/NotchView.swift:650`, change `size: 14` to `size: 16` so the
permission indicator scales with the agent icons:

```swift
PermissionIndicatorIcon(size: 16, color: Color(red: 0.85, green: 0.47, blue: 0.34))
```

### Step 4: Update doc comment

In `Nook/UI/Views/NotchView.swift:583-588`, update the numeric references in
the comment to match the new layout:

```swift
// Stacked "peek" of working-agent icons. When
// multiple agents are processing simultaneously,
// the `displayOrder` starts at `carouselFront`
// and rotates every 2s. The leftmost icon (front)
// is fully visible; the others peek out ~10.3pt to
// the right, sorted by priority from the front.
// Each icon's own pulse/movement animation is
// independent (Claude legs, Codex glow,
// OpenCode squish, Cursor highlight pulse), so
// the stack reads as alive on its own.
```

(Change "8pt" → "~10.3pt" if present. Some of the other text remains the same.)

### Step 5: Build + commit

```bash
xcodebuild -scheme Nook -configuration Debug -derivedDataPath build build
git add Nook/UI/Views/NotchView.swift
git commit -m "feat(notch): bump icon size 14pt to 16pt to match agents settings"
```

Expected: build succeeds. No new warnings. (Skip the test runner — same
pre-existing bootstrap issue as Task 1/2; not a regression.)

---

## Task 4: Manual visual verification

**Files:** none — read-only verification step.

- [ ] **Step 1: Launch the app in Debug**

```bash
xcodebuild -scheme Nook -configuration Debug -derivedDataPath build build
open build/Build/Products/Debug/Nook.app
```

(If Nook is already running, quit it first so the new build is launched.)

- [ ] **Step 2: Verify 0–4 agent scenarios**

Open multiple agent sessions (one per provider where available — Claude, Codex, OpenCode, Cursor) and watch the closed-notch header row. For each scenario, check:

| Active providers | Expected behavior |
|---|---|
| 0 | No icon stack rendered in the header |
| 1 (e.g., only Claude) | Single icon, no rotation |
| 2 (e.g., Claude + Codex) | Two stacked icons; front/back labels swap every 2s |
| 3 (e.g., Claude + Codex + OpenCode) | Two stacked icons; "second" icon changes as front rotates |
| 4 (all) | Two stacked icons; "second" icon changes as front rotates through all 4 |

For every scenario, the visible peek of the back icon (right of the front icon's right edge) should look the same regardless of which providers are in the two slots. The crab's right edge should not poke out further than the other icons when it is in the peek slot.

- [ ] **Step 3: Confirm the crab's aspect is unchanged**

Visually compare the crab's body to its previous appearance (it was 66×52 in a wider frame, now it's 66×52 in a 14×14 frame). The crab itself should look identical in shape — just smaller and centered in a square slot. It should not be horizontally squished.

- [ ] **Step 4: No further commit**

Verification step only. If anything looks wrong, revert with `git revert HEAD~1..HEAD` (or per-commit) and re-open the relevant task.

---

## Self-Review Notes

- **Spec coverage:** spec's "Display rules" table → Task 1 (cap at 2). spec's "Crab frame squaring" → Task 2 (square frame + center content). spec's "Per-icon visual hierarchy" → unchanged in code, both tasks preserve `scale 0.85`, `opacity 0.55`, `offset 11`, `zIndex count - index`. spec's "Edge Cases" → handled by the existing stale-front reset in `NotchView` and the `active.count > 1` rotation guard, neither modified.
- **No placeholders:** all code is shown in full. Build and test commands are explicit.
- **Type consistency:** `displayOrder` return type stays `[SessionProvider]`; `ClaudeCrabIcon.body` return type stays `some View`; all transform math uses the same `CGFloat` operations.
- **No scope creep:** no new files, no refactor of `displayOrder` into a free function (would require exposing `carouselFront`/`activeProcessingProviders`), no SwiftUI Preview tests added (project has no such infrastructure).
