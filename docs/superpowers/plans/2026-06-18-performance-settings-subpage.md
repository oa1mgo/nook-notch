# Performance Settings Sub-page Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a dedicated "Performance" sub-page consolidating the Performance Monitor toggle and a new "Show Performance Below Music" ordering toggle, replacing the inline Music-section toggle with a navigating `Performance...` menu row.

**Architecture:** Settings layer (new `musicAbovePerformance` UserDefaults key) → ViewModel (new `.performanceSettings` content type + keyboard nav) → New SwiftUI sub-page (`PerformanceSettingsView`) → Menu rewiring (remove inline toggle, add nav row, renumber focused indices) → Consumer rewiring (`SessionListView` reorders cards by flag).

**Tech Stack:** Swift + SwiftUI + AppKit. No external dependencies. No new frameworks.

**Spec:** `docs/superpowers/specs/2026-06-18-performance-settings-subpage-design.md`

---

### Task 1: Add `musicAbovePerformance` Setting to AppSettings

**Files:**
- Modify: `Nook/Core/Settings.swift`

- [x] **Step 1: Add the key constant and private alias**

In `Nook/Core/Settings.swift`, inside `enum AppSettings`, add the public key constant next to the existing `performanceMonitorEnabledKey` (around line 38):

```swift
nonisolated static let musicAbovePerformanceKey = "musicAbovePerformance"
```

Inside the private `enum Keys` (around line 48), add the alias:

```swift
nonisolated static let musicAbovePerformance = AppSettings.musicAbovePerformanceKey
```

- [x] **Step 2: Register the default value**

In `registerDefaults()` (around line 63), add to the `defaults.register(defaults:)` dictionary:

```swift
Keys.musicAbovePerformance: false,
```

- [x] **Step 3: Add the static get/set property**

Add a new computed property next to the existing `performanceMonitorEnabled` accessor (around line 151), using the same explicit-nil pattern:

```swift
// MARK: - Music Above Performance
nonisolated static var musicAbovePerformance: Bool {
    get {
        if defaults.object(forKey: Keys.musicAbovePerformance) == nil {
            return false
        }
        return defaults.bool(forKey: Keys.musicAbovePerformance)
    }
    set {
        defaults.set(newValue, forKey: Keys.musicAbovePerformance)
    }
}
```

- [x] **Step 4: Verify build**

Run: `xcodebuild -project Nook.xcodeproj -scheme Nook build 2>&1 | tail -5`
Expected: Build succeeds with no errors.

---

### Task 2: Add `.performanceSettings` Content Type to NotchViewModel

**Files:**
- Modify: `Nook/Core/NotchViewModel.swift`

- [x] **Step 1: Add the enum case and id**

In `NotchContentType` (around line 44), add the new case after `case agents`:

```swift
case performanceSettings
```

In the `id` property switch (around line 52), add:

```swift
case .performanceSettings: return "performanceSettings"
```

- [x] **Step 2: Add the live-height published property**

Near the other content-height properties (around line 100, next to `agentsContentHeight`), add:

```swift
@Published var performanceSettingsContentHeight: CGFloat = 260
```

- [x] **Step 3: Add the item-count constant**

Near the other item-count constants (around line 568, next to `menuItemCount`), add:

```swift
let performanceSettingsItemCount: Int = 3
```

- [x] **Step 4: Add the `openedSize` case**

In the `openedSize` switch (around line 124), add a new case **before** `case .instances` (after `case .performance(let section)`). Mirror the `.menu` / `.agents` pattern exactly — same width formula, and `contentHeight + headerHeight + 12` for height:

```swift
case .performanceSettings:
    let headerHeight = max(24, geometry.deviceNotchRect.height)
    return CGSize(
        width: min(screenRect.width * 0.4, 480),
        height: performanceSettingsContentHeight + headerHeight + 12
    )
```

> **Critical:** The width must be `min(screenRect.width * 0.4, 480)` — the same cap every other panel uses. Do **not** use a literal like `360`. The height must add `headerHeight + 12` on top of the measured content height; the preference-key value is VStack content only and does not include the header row or bottom padding.

- [x] **Step 5: Add `selectPreviousItem` branch**

In `selectPreviousItem()` (around line 508, after `case .performance:`), add:

```swift
case .performanceSettings:
    if settingsFocusedIndex == -1 {
        settingsFocusedIndex = performanceSettingsItemCount - 1
    } else {
        settingsFocusedIndex = max(0, settingsFocusedIndex - 1)
    }
```

- [x] **Step 6: Add `selectNextItem` branch**

In `selectNextItem()` (around line 551, after `case .performance:`), add:

```swift
case .performanceSettings:
    if settingsFocusedIndex == -1 {
        settingsFocusedIndex = 0
    } else {
        settingsFocusedIndex = min(performanceSettingsItemCount - 1, settingsFocusedIndex + 1)
    }
```

> **Pitfall:** Use `performanceSettingsItemCount` (the new constant = 3), **not** `performanceItemCount` (the existing constant for performance detail pages). They are different values.

- [x] **Step 7: Verify build**

Run: `xcodebuild -project Nook.xcodeproj -scheme Nook build 2>&1 | tail -5`
Expected: Build succeeds. Swift's exhaustive switch will flag any missed switch — if it fails, add the missing case.

---

### Task 3: Create PerformanceSettingsView

**Files:**
- Create: `Nook/UI/Views/PerformanceSettingsView.swift`

- [x] **Step 1: Create the file with full content**

> The project uses Xcode 16 `PBXFileSystemSynchronizedRootGroup`, so a new file under `Nook/` is auto-included — no pbxproj edit needed.

```swift
//
//  PerformanceSettingsView.swift
//  Nook
//
//  Sub-page consolidating performance-related settings.
//

import SwiftUI
import Combine

struct PerformanceSettingsView: View {
    @ObservedObject var viewModel: NotchViewModel
    let primaryTextColor: Color
    let secondaryTextColor: Color
    let separatorColor: Color

    @AppStorage(AppSettings.performanceMonitorEnabledKey) private var performanceMonitorEnabled = true
    @AppStorage(AppSettings.musicAbovePerformanceKey) private var musicAbovePerformance = false

    @State private var didAppear = false

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(spacing: 4) {
                MenuRow(
                    icon: "chevron.left",
                    label: "Back",
                    primaryTextColor: primaryTextColor,
                    isFocused: viewModel.settingsFocusedIndex == 0
                ) {
                    viewModel.navigateBack()
                }

                Divider().background(separatorColor).padding(.vertical, 4)

                MenuToggleRow(
                    icon: "gauge.with.dots.needle.33percent",
                    label: "Performance Monitor",
                    isOn: performanceMonitorEnabled,
                    primaryTextColor: primaryTextColor,
                    secondaryTextColor: secondaryTextColor,
                    isFocused: viewModel.settingsFocusedIndex == 1
                ) {
                    performanceMonitorEnabled.toggle()
                }

                MenuToggleRow(
                    icon: "arrow.up.arrow.down",
                    label: "Show Performance Below Music",
                    isOn: musicAbovePerformance,
                    primaryTextColor: primaryTextColor,
                    secondaryTextColor: secondaryTextColor,
                    isFocused: viewModel.settingsFocusedIndex == 2
                ) {
                    musicAbovePerformance.toggle()
                }

                GeometryReader { proxy in
                    Color.clear.preference(
                        key: PerformanceSettingsContentHeightKey.self,
                        value: proxy.size.height
                    )
                }
                .frame(height: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onPreferenceChange(PerformanceSettingsContentHeightKey.self) { height in
            viewModel.performanceSettingsContentHeight = height
        }
        .onAppear {
            didAppear = true
        }
        .onReceive(viewModel.$keyboardActivateTrigger) { trigger in
            guard trigger != nil, didAppear else { return }
            switch viewModel.settingsFocusedIndex {
            case 0: viewModel.navigateBack()
            case 1: performanceMonitorEnabled.toggle()
            case 2: musicAbovePerformance.toggle()
            default: break
            }
        }
    }
}

private struct PerformanceSettingsContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
```

> **Notes on deliberate divergences from AgentSettingsView:**
> - **No `onChange(of: viewModel.contentType)` re-sync.** AgentSettingsView needs it to re-copy `AppSettings.*` into `@State` vars. This view uses `@AppStorage` directly, which is always live — there is nothing to re-sync.
> - **`onReceive` dispatches all three indices (0/1/2).** AgentSettingsView's `onReceive` only handles index 0 (Back). This view must handle 0, 1, and 2 because the two toggles need keyboard activation.
> - **`isFocused` is passed to every row.** `MenuToggleRow` defaults `isFocused` to `false`; omitting it silently breaks keyboard focus highlighting.

- [x] **Step 2: Verify build**

Run: `xcodebuild -project Nook.xcodeproj -scheme Nook build 2>&1 | tail -5`
Expected: Build succeeds.

---

### Task 4: Rewire NotchMenuView — Remove Inline Toggle, Add Nav Row, Renumber

**Files:**
- Modify: `Nook/UI/Views/NotchMenuView.swift`

- [x] **Step 1: Insert the `Performance...` navigation row**

Between the `Agents...` row (focused-index 3, around line 72) and the `Keyboard Shortcuts...` row (currently focused-index 4, around line 82), insert:

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

- [x] **Step 2: Delete the inline Performance Monitor toggle**

Delete the `MenuToggleRow` for "Performance Monitor" in the Music section (the one with `isFocused: viewModel.settingsFocusedIndex == 8` and `icon: "gauge.with.dots.needle.33percent"`). This is the entire `MenuToggleRow(...)` block — approximately 10 lines.

- [x] **Step 3: Renumber focused indices in the Music section**

The three remaining Music-section toggles shift up by 1 (because the new `Performance...` row was inserted at index 4, above them):

- Artwork Adaptive Background: `== 5` → `== 6`
- Music Edge Glow: `== 6` → `== 7`
- Vibe Glow: `== 7` → `== 8`

- [x] **Step 4: Renumber the Keyboard Shortcuts row**

Change `Keyboard Shortcuts...` from `== 4` to `== 5`.

- [x] **Step 5: Verify Launch at Login / Accessibility / Star / Quit are unchanged**

Confirm these rows still use indices 9, 10, 11, 12. They should **not** change: the +1 shift from the insertion (at index 4) is cancelled by the −1 shift from the removal (old index 8), so everything at index 9 and below the removal point returns to its original number.

Final index map:
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

- [x] **Step 6: Renumber `performFocusedAction` case arms**

In `performFocusedAction()` (around line 229), update the switch. The old `case 8: performanceMonitorEnabled.toggle()` is **deleted**. The renumbered arms:

```swift
case 3: viewModel.pushTo(.agents)
case 4: viewModel.pushTo(.performanceSettings)
case 5: viewModel.pushTo(.shortcuts)
case 6: artworkAdaptiveBackgroundEnabled.toggle()
case 7: musicEdgeGlowEnabled.toggle()
case 8: vibeGlowEnabled.toggle()
```

> **Pitfall:** There must be exactly **one** `case 8` — `vibeGlowEnabled.toggle()`. The old `case 8: performanceMonitorEnabled.toggle()` is gone. Do not leave two `case 8` labels.

Cases 0, 1, 2, 9, 10, 11, 12 are unchanged.

- [x] **Step 7: Verify `menuItemCount` is still 13**

In `Nook/Core/NotchViewModel.swift` (around line 568), confirm `menuItemCount: Int = 13` is unchanged. Net row count is zero (+1 Performance..., −1 inline Performance Monitor).

- [x] **Step 8: Verify build**

Run: `xcodebuild -project Nook.xcodeproj -scheme Nook build 2>&1 | tail -5`
Expected: Build succeeds.

---

### Task 5: Wire NotchView — Render Case + @AppStorage Mirror + Pass Flag

**Files:**
- Modify: `Nook/UI/Views/NotchView.swift`

- [x] **Step 1: Add the `@AppStorage` mirror**

Next to the existing `performanceMonitorEnabled` mirror (around line 44), add:

```swift
@AppStorage(AppSettings.musicAbovePerformanceKey) private var musicAbovePerformance = false
```

- [x] **Step 2: Add the `contentView` switch case**

In the `contentView` switch (around line 590), add a new case (e.g., after `case .agents:`):

```swift
case .performanceSettings:
    PerformanceSettingsView(
        viewModel: viewModel,
        primaryTextColor: expandedPrimaryTextColor,
        secondaryTextColor: expandedSecondaryTextColor,
        separatorColor: expandedSeparatorColor
    )
```

> **Pitfall:** Use `expandedPrimaryTextColor` / `expandedSecondaryTextColor` / `expandedSeparatorColor` (the expanded-mode color tokens already used by the `.agents` and `.shortcuts` cases), **not** the raw `primaryTextColor` / `secondaryTextColor` / `separatorColor` parameter names from the spec. Check how the neighboring `.agents` case passes them and match exactly.

- [x] **Step 3: Pass `musicAbovePerformance` to SessionListView**

In the `case .instances:` branch of `contentView` (around line 593), add the new parameter to the `SessionListView` initializer:

```swift
case .instances:
    SessionListView(
        sessionMonitor: sessionMonitor,
        viewModel: viewModel,
        musicManager: musicManager,
        performanceMonitor: performanceMonitor,
        isPerformanceMonitorEnabled: performanceMonitorEnabled,
        musicAbovePerformance: musicAbovePerformance
    )
```

- [x] **Step 4: Verify build**

Run: `xcodebuild -project Nook.xcodeproj -scheme Nook build 2>&1 | tail -5`
Expected: Build will fail with "Extra argument 'musicAbovePerformance' in call" until Task 6 Step 1 is done. That is expected — proceed to Task 6.

---

### Task 6: Add `musicAbovePerformance` Parameter to SessionListView

**Files:**
- Modify: `Nook/UI/Views/SessionListView.swift`

- [x] **Step 1: Add the stored property**

In `SessionListView` (around line 15, next to `isPerformanceMonitorEnabled`), add:

```swift
let musicAbovePerformance: Bool
```

- [x] **Step 2: Reorder the card blocks in `body`**

Replace the existing music-card + performance-row block in `body` (around lines 53–64) with a conditional that swaps their order based on the flag:

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

The `if sessionMonitor.instances.isEmpty { ... } else { instancesList }` block below stays unchanged.

> **Note:** `measureHeight` / `syncLayoutMetrics` logic is unchanged. Both cards report their own measured height regardless of position. `instancesPageOpenedHeight` in the ViewModel sums `performanceBlockHeight + musicBlockHeight` — addition is commutative, so the total height is order-independent.

- [x] **Step 3: Verify build**

Run: `xcodebuild -project Nook.xcodeproj -scheme Nook build 2>&1 | tail -5`
Expected: Build succeeds. The "Extra argument" error from Task 5 Step 4 is now resolved.

---

### Task 7: Manual Verification

- [x] **Step 1: Build and run the app**

Run: `xcodebuild -project Nook.xcodeproj -scheme Nook build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [x] **Step 2: Verify menu structure**

Open the notch → click the gear (menu). Confirm:
- "Performance..." appears between "Agents..." and "Keyboard Shortcuts...", with a `chevron.right` trailing icon.
- The inline "Performance Monitor" toggle is gone from the Music section.
- The Music section still has: Artwork Adaptive Background, Music Edge Glow, Vibe Glow.

- [x] **Step 3: Verify Performance sub-page**

Click "Performance...". Confirm:
- A Back row appears at the top.
- "Performance Monitor" toggle is present and reflects the current on/off state.
- "Show Performance Below Music" toggle is present, default OFF.
- Toggling either persists across app restart.

- [x] **Step 4: Verify card ordering on the instances page**

With both music playing and performance monitor on:
- Default (`musicAbovePerformance = false`): Performance row is above the Music card.
- Toggle "Show Performance Below Music" ON: Music card moves above the Performance row.
- The notch window height does not change when swapping (order-independent height).

- [x] **Step 5: Verify keyboard navigation**

In the menu, use ↑/↓ to navigate:
- Focus moves through all 13 rows in the correct order (indices 0–12).
- Press Enter on "Performance..." (index 4) → navigates to the sub-page.
- In the sub-page, ↑/↓ moves focus among Back / Performance Monitor / Show Performance Below Music.
- Enter on Back (index 0) → returns to menu.
- Enter on either toggle (index 1 or 2) → toggles it.

- [x] **Step 6: Verify no regressions**

- Navigate to Agents... and back — works.
- Navigate to Keyboard Shortcuts... and back — works.
- Navigate to a Performance detail page and back — works.
- Launch at Login, Accessibility, Star on GitHub, Quit all still fire from their indices (9–12).
