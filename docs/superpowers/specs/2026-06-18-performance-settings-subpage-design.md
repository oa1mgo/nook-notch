# Performance Settings Sub-page

**Date:** 2026-06-18
**Status:** Approved (pending review)

## Summary

Add a dedicated "Performance" sub-page in the dynamic-island menu that consolidates
performance-related settings. The sub-page contains two toggles:

1. **Performance Monitor** — on/off (existing setting, moved from the inline Music section)
2. **Show Performance Below Music** — controls the relative order of the music card
   and the performance row in the instance page (new setting, default OFF)

The current inline "Performance Monitor" toggle in the Music section is removed and
replaced by a `Performance...` menu row (with a `chevron.right` trailing icon) that
navigates to the new sub-page.

This follows the established sub-page pattern (`AgentSettingsView`, `ShortcutSettingsView`)
exactly.

## Goals

- One place for all performance-related settings
- User can swap the order of the music card and the performance row, with the choice
  persisted across launches
- The default ordering is **performance on top** (matches the original design before
  the music-swap adjustment)

## Non-Goals

- Size variants for the performance row (normal / shrink / mini) — future work
- Animations when toggling — settings apply immediately via simple re-render
- Keyboard shortcut for the order toggle — menu navigation is sufficient
- Per-card customization beyond on/off and order

## Settings Storage

File: `Nook/Core/Settings.swift`

Add a new key (mirroring the `performanceMonitorEnabled` pattern at lines 39, 50,
63, 155–165):

- Public key constant: `musicAbovePerformanceKey = "musicAbovePerformance"`
- Private alias: `Keys.musicAbovePerformance`
- `registerDefaults()`: `Keys.musicAbovePerformance: false`
- Static `get`/`set` property using the explicit-nil pattern (default `false`)

`performanceMonitorEnabled` (existing) is reused — no changes to that key.

## New Sub-page

New file: `Nook/UI/Views/PerformanceSettingsView.swift`

Mirrors `AgentSettingsView` structure (lines 1–74 + 440–445) and
`ShortcutSettingsView` (lines 11–34):

### Signature

```swift
struct PerformanceSettingsView: View {
    @ObservedObject var viewModel: NotchViewModel
    let primaryTextColor: Color
    let secondaryTextColor: Color
    let separatorColor: Color
    // ... @State, @AppStorage
}
```

### Body structure

- `ScrollView` + `VStack(spacing: 4)` with `.padding(.horizontal, 8).padding(.vertical, 8)`
- Row 0 — `MenuRow(icon: "chevron.left", label: "Back", primaryTextColor: primaryTextColor, isFocused: viewModel.settingsFocusedIndex == 0) { viewModel.navigateBack() }`
- `Divider().background(separatorColor).padding(.vertical, 4)`
- Row 1 — `MenuToggleRow(icon: "gauge.with.dots.needle.33percent", label: "Performance Monitor", isOn: performanceMonitorEnabled, primaryTextColor: primaryTextColor, secondaryTextColor: secondaryTextColor, isFocused: viewModel.settingsFocusedIndex == 1) { performanceMonitorEnabled.toggle() }` — focused-index 1
- Row 2 — `MenuToggleRow(icon: "arrow.up.arrow.down", label: "Show Performance Below Music", isOn: musicAbovePerformance, primaryTextColor: primaryTextColor, secondaryTextColor: secondaryTextColor, isFocused: viewModel.settingsFocusedIndex == 2) { musicAbovePerformance.toggle() }` — focused-index 2

> **Pitfall:** `MenuToggleRow` defaults `isFocused` to `false`. Omitting
> `isFocused` (and the two color params) silently breaks keyboard focus
> highlighting. Always pass all three.

- GeometryReader + `PerformanceSettingsContentHeightKey` to measure live content height
- `.onPreferenceChange { viewModel.performanceSettingsContentHeight = $0 }`
- `.onAppear { didAppear = true }`
- **No `.onChange(of: viewModel.contentType)` re-sync.** AgentSettingsView needs
  it to re-copy `AppSettings.*` into `@State` vars; this view uses `@AppStorage`
  directly (always live), so there is nothing to re-sync.
- `.onReceive(viewModel.$keyboardActivateTrigger)` to dispatch Enter key by
  `settingsFocusedIndex` — **this diverges from AgentSettingsView**, whose
  `onReceive` only handles index 0 (Back). This view must handle 0, 1, and 2
  because the two toggles need keyboard activation:
  - `0` → `viewModel.navigateBack()`
  - `1` → `performanceMonitorEnabled.toggle()`
  - `2` → `musicAbovePerformance.toggle()`

### Toggles use @AppStorage

Following the simpler `NotchMenuView` pattern (lines 34–37) rather than the
copy-into-@State pattern from `AgentSettingsView`:

```swift
@AppStorage(AppSettings.performanceMonitorEnabledKey) private var performanceMonitorEnabled = true
@AppStorage(AppSettings.musicAbovePerformanceKey) private var musicAbovePerformance = false
```

### Content height

`private struct PerformanceSettingsContentHeightKey: PreferenceKey` with `defaultValue: 0`
and `reduce` that takes `max(value, nextValue())`.

## Navigation Wiring

File: `Nook/Core/NotchViewModel.swift`

### NotchContentType (lines 44–62)

Add new case:

```swift
case performanceSettings
```

Add a corresponding `id` string in the `id` property (lines 52–61).

### openedSize (lines 124–164)

Add `case .performanceSettings:` mirroring the `.menu` / `.agents` pattern
exactly — same width formula and the `contentHeight + headerHeight + 12`
height formula:

```swift
case .performanceSettings:
    let headerHeight = max(24, geometry.deviceNotchRect.height)
    return CGSize(
        width: min(screenRect.width * 0.4, 480),
        height: performanceSettingsContentHeight + headerHeight + 12
    )
```

The width must be `min(screenRect.width * 0.4, 480)` — the same cap every
other panel uses (menu / shortcuts / agents / performance / instances). Do
**not** use a literal like `360`; that would make this panel narrower than
its siblings.

The height must add `headerHeight + 12` on top of the measured content
height. `performanceSettingsContentHeight` (from the preference key) is the
VStack content only; it does **not** include the header row (device-notch
height, min 24pt) or the 12pt bottom padding. Omitting them clips the Back
row under the header. The initial placeholder value `260` only applies until
the preference key fires.

### Live height property

Add `@Published var performanceSettingsContentHeight: CGFloat = 260`.

### Item count for keyboard navigation

Add `let performanceSettingsItemCount: Int = 3` (Back + 2 toggles).

Add `case .performanceSettings:` branches in `selectPreviousItem()` /
`selectNextItem()` (lines 477–560), mirroring the existing `case .performance:`
pattern. **Use `performanceSettingsItemCount` (the new constant), not
`performanceItemCount`** (the existing constant for performance detail pages) —
they are different values.

### Existing `pushTo` / `navigateBack` / `notchClose`

No changes — these are content-type-agnostic.

## Menu Updates

File: `Nook/UI/Views/NotchMenuView.swift`

### Remove inline Performance Monitor toggle

Delete the `MenuToggleRow` at lines 130–139 (focused-index 8, in the Music section).

### Add new sub-page entry

Insert a new `MenuRow` between `Agents...` (line 72) and `Keyboard Shortcuts...`
(line 80):

```swift
MenuRow(
    icon: "gauge.with.dots.needle.33percent",
    label: "Performance...",
    trailingIcon: "chevron.right",
    primaryTextColor: primaryTextColor,
    isFocused: viewModel.settingsFocusedIndex == 4
) {
    viewModel.pushTo(.performanceSettings)
}
```

### Focused-index renumbering

After the changes, the indices become:

- 0 — Back
- 1 — Screen picker
- 2 — Sound picker
- 3 — Agents...
- 4 — **Performance...** (new)
- 5 — Keyboard Shortcuts...
- 6 — Artwork Adaptive Background
- 7 — Music Edge Glow
- 8 — Vibe Glow
- 9 — Launch at Login
- 10 — Accessibility
- 11 — Star on GitHub
- 12 — Quit

Update each `isFocused: viewModel.settingsFocusedIndex == N` accordingly. The
indices in the Music section (Artwork / Edge Glow / Vibe Glow) shift up by 1
(5→6, 6→7, 7→8) because of the new `Performance...` row inserted at index 4.
Indices for `Launch at Login`, `Accessibility`, `Star on GitHub`, and `Quit`
remain at 9, 10, 11, 12 because the row removed (old `Performance Monitor` at
index 8) was below the insertion point, so the net shift cancels out.

### performFocusedAction (lines 229–264)

Renumber the case arms to match the new focused-index scheme:

- `case 3: viewModel.pushTo(.agents)` — unchanged
- `case 4: viewModel.pushTo(.performanceSettings)` — **new**
- `case 5: viewModel.pushTo(.shortcuts)` — was `case 4`
- `case 6: artworkAdaptiveBackgroundEnabled.toggle()` — was `case 5`
- `case 7: musicEdgeGlowEnabled.toggle()` — was `case 6`
- `case 8: vibeGlowEnabled.toggle()` — was `case 7`
- `case 8: performanceMonitorEnabled.toggle()` — **removed**
- `case 9..12` (Launch at Login, Accessibility, Star on GitHub, Quit) — unchanged

### menuItemCount

In `Nook/Core/NotchViewModel.swift` line 568, `menuItemCount: Int = 13` is unchanged
(added one row, removed one row, net zero). The indices 0–12 cover all 13 focusable
rows.

## Render Wiring

File: `Nook/UI/Views/NotchView.swift`

In the `contentView` switch (lines 590–640), add:

```swift
case .performanceSettings:
    PerformanceSettingsView(
        viewModel: viewModel,
        primaryTextColor: primaryTextColor,
        secondaryTextColor: secondaryTextColor,
        separatorColor: separatorColor
    )
```

The `@AppStorage` mirror for `musicAbovePerformance` is also added to `NotchView`
(alongside the existing `performanceMonitorEnabled` mirror at line 44), so the open
notch UI updates live when the setting changes.

## Consumer

File: `Nook/UI/Views/SessionListView.swift`

### New parameter

```swift
let musicAbovePerformance: Bool
```

### Card ordering

The VStack in `body` (lines 52–72) becomes:

```swift
if musicAbovePerformance {
    if showsMusicCard {
        MusicCardView(musicManager: musicManager)
            .measureHeight(using: MusicCardHeightKey.self) { musicCardHeight = $0 }
    }
    if showsPerformanceRow {
        PerformanceSummaryRow(monitor: performanceMonitor) {
            viewModel.pushTo(.performance(.overview))
        }
        .measureHeight(using: PerformanceRowHeightKey.self) { performanceRowHeight = $0 }
    }
} else {
    if showsPerformanceRow {
        PerformanceSummaryRow(monitor: performanceMonitor) {
            viewModel.pushTo(.performance(.overview))
        }
        .measureHeight(using: PerformanceRowHeightKey.self) { performanceRowHeight = $0 }
    }
    if showsMusicCard {
        MusicCardView(musicManager: musicManager)
            .measureHeight(using: MusicCardHeightKey.self) { musicCardHeight = $0 }
    }
}
```

`measureHeight` / `syncLayoutMetrics` logic is unchanged — both cards report their
own measured height regardless of position.

### Pass from NotchView

In `Nook/UI/Views/NotchView.swift`, pass the new flag to the `SessionListView`
constructor at the existing call site (around line 599), using the `@AppStorage`
mirror.

## Default Behavior

- New install / unset: `musicAbovePerformance = false` → performance on top
- After toggling: setting persists via `UserDefaults`; survives restarts
- When only one of (music, performance) is visible, ordering doesn't matter — only
  the visible one is rendered

## Risks

- **Layout shift on toggle**: the cards re-render in the new order. SwiftUI does
  not animate order changes by default; we accept the lack of animation as out of
  scope.
- **Index renumbering bugs**: the focused-index renumbering is a string of mechanical
  edits. Mitigation: use `replace_all: true` for the simple cases; verify by
  running the app and using keyboard navigation.
- **Window sizing for new content type**: if `openedSize` is set too small, content
  may clip. Mitigation: size it generously (e.g. 320×260) and let `GeometryReader`
  drive the actual height via the preference key.

## Out of Scope

- Size variants (normal / shrink / mini) for the performance row
- Animations on toggle
- Keyboard shortcut for order swap
- Localized labels
