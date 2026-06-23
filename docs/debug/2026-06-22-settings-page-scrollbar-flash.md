# Settings Page Scrollbar Flash on Picker Expand/Collapse

> Date: 2026-06-22
> Status: Resolved
> Symptom: Clicking a settings picker (Sound, Claude dir, Visible Metrics) briefly flashes the ScrollView's scrollbar during expand.
> Scope: Home page Sound/Screen pickers, Agents page Claude dir picker, Performance page Visible Metrics picker.

## Symptom

Clicking any of the three expandable pickers in Settings caused a quick flash of the ScrollView's scrollbar during the expand animation. Performance's Visible Metrics picker appeared not to flash — but that was a coincidence (explained below).

## Root Cause

**Two animations with different curves fighting over the same dimension.**

`NotchView`'s panel had:

```swift
.animation(openAnimation, value: notchSize)  // spring(response: 0.42, dampingFraction: 0.8) → ~0.45s
```

`openAnimation` is a spring curve (~0.45s). When a picker expanded, the `VStack`'s **ideal** height jumped immediately to e.g. 380, but the **panel's actual** height was animated on a 0.45s spring — lagging behind the VStack's growth.

During that mismatch window:
- VStack actual height < VStack ideal height (because panel is still catching up).
- ScrollView inside the VStack sees itself clipped by its parent.
- ScrollView briefly shows its scrollbar (it realizes it has content to scroll).
- Once panel finishes springing and catches up, VStack actual == VStack ideal again — scrollbar hides.

That 0.3-0.4s of "scrollbar visible" is the flash.

**Why Performance "didn't flash"**: its default `performanceSettingsContentHeight` was 260, but the collapsed-state content was only ~215pt — already overflowing. So the scrollbar was *permanently* visible in the collapsed state, and the expand animation didn't change its visibility. It looked calm because it was already broken; the other pages looked broken because their scrollbar was normally hidden.

## The Trap: Fix the Measurement, Not the Animation

**First instinct (wrong):** "The VStack must be measuring its ideal height incorrectly — add `.fixedSize` everywhere, measure the picker's expanded height in advance, pre-grow the panel, etc."

This led to a chain of patches:
- `baseAgentsContentHeight` + `claudeDirPickerContentHeight` as separate `@State`.
- A `onContentHeightChange` closure chain threading from `ExpandableContent` → `ExpandableSettingsRow` → `AgentSettingsView` → `NotchViewModel`.
- `.transaction { $0.disablesAnimations = true }` on the toggle.
- `onChange(of: claudeDirPickerExpanded)` sync.

Every patch addressed a *symptom* of the mismatch (VStack actual ≠ ideal) rather than the *cause* (the panel's animation curve didn't match the picker's).

The fix for the mismatch is one line:

```swift
.animation(.settingsExpand, value: notchSize)  // easeInOut 0.2s — same curve as the picker
```

## The Actual Fix

### 1. Shared animation constant

```swift
extension Animation {
    static let settingsExpand = Animation.easeInOut(duration: 0.2)
}
```

Used by **both** the picker's frame animation (`ExpandableContent`) **and** the panel's height animation (`NotchView`). Same curve, same duration — they stay in lock-step, so VStack actual == VStack ideal throughout the expand.

### 2. `ExpandableContent` — the right way to animate `if isExpanded`

Replace:

```swift
if isExpanded { VStack { content() } }
```

With a component that keeps content in the view tree always:

```swift
content
    .fixedSize(horizontal: false, vertical: true)  // ignore parent's height-0 proposal
    .background(GeometryReader { g in              // measure TRUE natural height
        Color.clear.preference(key: ..., value: g.size.height)
    })
    .frame(height: isExpanded ? contentHeight : 0, alignment: .top)
    .clipped()
    .animation(.settingsExpand, value: isExpanded)
```

The `.fixedSize(vertical: true)` is **not a workaround** — it's SwiftUI's standard mechanism for "use my ideal size, not what my parent asked for." Without it, a `ScrollView` (or any view that accepts parent proposals) given height 0 will report 0 back to the GeometryReader, so the measured `contentHeight` stays 0 forever, and the expand animates 0 → 0 (content never appears).

### 3. Default content heights

`agentsContentHeight` 260 → 380 (covers "3 providers installed, no picker").
`performanceSettingsContentHeight` 260 → 230 (covers "Visible Metrics collapsed").

This prevents the *first paint* from flashing a scrollbar while the live-measured height is still propagating.

## Reusable Insights

### 1. If a parent animates its size with curve A and a child animates the size-contributing property with curve B, the mismatch window will clip

The parent's animation curve must match the child's. Otherwise, during the transition, actual < ideal somewhere, and anything inside that depends on "being fully sized" (ScrollView scrollbar, clipping, text truncation) will flicker.

Reach for `Animation.settingsExpand` (or whichever shared curve) rather than the nearest local spring — especially when the parent is the thing whose size depends on the child.

### 2. `.fixedSize(vertical: true)` is the answer to "my GeometryReader reports 0 when collapsed"

When you need to measure a view's *natural* height independent of what its parent proposes (e.g., because the parent proposes 0 during a collapse animation), add `.fixedSize(horizontal: false, vertical: true)` **before** the GeometryReader. This is SwiftUI's intended mechanism, not a hack.

### 3. "Works on one page, broken on another" is often a measurement artifact, not a real difference

Performance didn't flash because its scrollbar was *always* visible (content overflowed the collapsed state). The other pages flashed because their scrollbar was *normally hidden*. Same bug, different visibility — when debugging, don't trust the "it works there" comparison without checking the baseline.

### 4. Patch chains are a signal you're fixing the wrong layer

This bug went through 4 patch iterations before the real fix (one `.animation(...)` change) surfaced. The signal was: every patch added state or plumbing that mirrored something already implicit in the framework. If you find yourself threading a closure chain to propagate a value the framework already knows, stop and ask "what is the framework *actually* doing, and why does it disagree with what I want?"

## Files Changed

- `Nook/Core/Animation+Settings.swift` — new shared `Animation.settingsExpand`.
- `Nook/Core/NotchViewModel.swift` — default `agentsContentHeight`/`performanceSettingsContentHeight`.
- `Nook/UI/Components/ExpandableContent.swift` — new component.
- `Nook/UI/Components/ExpandableSettingsRow.swift` — uses `ExpandableContent`.
- `Nook/UI/Views/AgentSettingsView.swift` — Claude picker uses `ExpandableSettingsRow`.
- `Nook/UI/Views/NotchView.swift` — panel uses `.animation(.settingsExpand, value: notchSize)`.
