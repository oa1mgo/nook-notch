# Session List Permission Y/N/A Shortcuts Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add Y/N/A + C/Esc keyboard shortcuts to inline permission approval buttons on the instances page (`SessionListView`), matching chat-page `ChatApprovalBar` keybindings.

**Architecture:** Extract a single-source `SessionState.showsInlineApprovalButtons` predicate (render + keyboard share it); hoist Always-confirm state from `InstanceRow` to `SessionListView` as `confirmingSessionId: String?`; install a local `NSEvent` key monitor on list appear (LIFO ⇒ list monitor beats `ShortcutManager`, so confirm-state Esc cancels without closing the notch). Zero changes to `ShortcutManager` / `ShortcutBindings` / `NotchViewModel` triggers.

**Tech Stack:** SwiftUI + AppKit `NSEvent.addLocalMonitorForEvents`. No automated tests for key monitors (project precedent: `docs/superpowers/specs/2026-05-26-keyboard-shortcuts-design.md`); each task verifies with `xcodebuild` + the manual checklist in Task 6.

**Spec:** `docs/superpowers/specs/2026-09-23-session-list-permission-shortcuts-design.md` (approved, including review rounds).

---

### Task 1: SOI predicate + InstanceRow branch switch

**Files:**
- Modify: `Nook/UI/Views/SessionListView.swift` (top-of-file extension; InstanceRow action-area branch ~L608)

- [ ] **Step 1: Add the SOI extension**

Insert immediately after `import Combine` / `import SwiftUI` (before `struct SessionListView`):

```swift
extension SessionState {
    /// SOI: row renders InlineApprovalButtons — keyboard Y/N/A target.
    /// Mirrors InstanceRow action-area branch (SessionListView.swift
    /// `isWaitingForTerminalApproval || (... && isInteractiveTool)` first,
    /// then approval buttons). Keep both in sync when either changes.
    ///
    /// Premise: `phase.isWaitingForApproval` matches ONLY
    /// `.waitingForApproval` (SessionPhase.swift L266-269) — terminal-side
    /// `.waitingForTerminalApproval` is a different case and is NOT
    /// included. Targets do not pass through InstanceRow's else-if chain,
    /// so this exclusivity is what keeps terminal-approval rows out of the
    /// keyboard target set. Do not "merge" the two phase helpers.
    var showsInlineApprovalButtons: Bool {
        guard phase.isWaitingForApproval else { return false }
        if let tool = pendingToolName, ToolCallItem.kind(of: tool) == .askUserQuestion {
            return false // branch 1: Go to Terminal, not Y/N/A
        }
        return true
    }

    /// Always button exists only for OpenCode (mirrors onApproveAlways wiring at call site L195).
    var canApproveAlways: Bool { showsInlineApprovalButtons && provider == .opencode }
}
```

- [ ] **Step 2: Switch InstanceRow branch 2 to the SOI**

In `InstanceRow.body` (~L608), change:

```swift
// BEFORE
} else if isWaitingForApproval {
```

to:

```swift
} else if session.showsInlineApprovalButtons {
```

Leave branch 1 (`isWaitingForTerminalApproval || ((isWaitingForApproval || isWaitingForUserInput) && isInteractiveTool)`) untouched.

- [ ] **Step 3: Build**

Run: `xcodebuild -project Nook.xcodeproj -scheme Nook -configuration Debug -destination 'platform=macOS' build`
Expected: `BUILD SUCCEEDED`

- [ ] **Step 4: Commit**

```bash
git add Nook/UI/Views/SessionListView.swift
git commit -m "refactor(session-list): extract InlineApprovalButtons SOI predicate"
```

---

### Task 2: Hoist Always-confirm state to SessionListView

**Files:**
- Modify: `Nook/UI/Views/SessionListView.swift`
  - `SessionListView` state block (~L19-21)
  - `InstanceRow` declaration (~L396-400)
  - `instancesList` ForEach call site (~L187-197)
  - `SessionListView.body` lifecycle (~L103-124)

- [ ] **Step 1: Add parent state**

Next to the existing `@State` vars in `SessionListView` (~L19-21), add:

```swift
    /// The session currently in Always-confirm mode (Patterns + Cancel/Confirm).
    /// Parent-scoped so only one row can be in confirm mode at a time and the
    /// keyboard path can drive it (spec §5).
    @State private var confirmingSessionId: String?
```

- [ ] **Step 2: Convert InstanceRow's @State to a Binding**

In `InstanceRow` (~L400), replace:

```swift
    @State private var isConfirmingAlways = false
```

with (place it with the other `let` properties, after `isKeyboardSelected`):

```swift
    /// Parent-owned Always-confirm mode (was per-row @State — allowed two rows
    /// to confirm simultaneously; hoisted per spec §5).
    @Binding var isConfirmingAlways: Bool
```

Delete the old `@State` line. `InstanceRow.body` references (`isConfirmingAlways` at ~L482, ~L613 `$isConfirmingAlways`) stay unchanged — `@Binding` supports both read and `$` projection.

- [ ] **Step 3: Wire the call site Binding**

In `instancesList` ForEach (~L187-197), add the parameter after `isKeyboardSelected:`:

```swift
                            isKeyboardSelected: index == viewModel.keyboardSelectedIndex,
                            isConfirmingAlways: Binding(
                                get: { confirmingSessionId == session.sessionId },
                                set: { confirmingSessionId = $0 ? session.sessionId : nil }
                            )
```

- [ ] **Step 4: EXIT resets (picker spec ❌3) + targets computed property**

Append to `SessionListView.body` modifier chain (after existing `.onChange` modifiers, ~L121-123):

```swift
        .onChange(of: approvalTargets) { _, newTargets in
            if let id = confirmingSessionId,
               !newTargets.contains(where: { $0.sessionId == id }) {
                confirmingSessionId = nil
            }
        }
```

Also add `approvalTargets` now (final location — Task 4's `handleKeyDown` consumes it; without it this task's build fails). Place next to `sortedInstances` (~L157):

```swift
    /// Rows that render InlineApprovalButtons — keyboard Y/N/A targets (spec §1).
    private var approvalTargets: [SessionState] {
        sortedInstances.filter(\.showsInlineApprovalButtons)
    }
```

- [ ] **Step 5: Build**

Run: `xcodebuild -project Nook.xcodeproj -scheme Nook -configuration Debug -destination 'platform=macOS' build`
Expected: `BUILD SUCCEEDED`

- [ ] **Step 6: Manual smoke — confirm mode still works via mouse**

Run: `open ~/Library/Developer/Xcode/DerivedData/Nook-*/Build/Products/Debug/Nook.app` (or rebuild-and-run from Xcode)
Trigger an opencode permission → click **Always** on a list row → row shows Patterns + Cancel/Confirm; click another row's Always → first row exits confirm (new single-slot behavior).
Expected: no visual regression; two rows can no longer confirm simultaneously.

- [ ] **Step 7: Commit**

```bash
git add Nook/UI/Views/SessionListView.swift
git commit -m "refactor(session-list): hoist Always-confirm state to list view" -m "Behavior change hidden in the refactor: confirm mode is now a single slot owned by the list — two rows can no longer enter Always-confirm simultaneously (was per-row @State)."
```

---

### Task 3: Keycap hints on InlineApprovalButtons

**Files:**
- Modify: `Nook/UI/Views/SessionListView.swift` (`InlineApprovalButtons`, ~L696-818)

- [ ] **Step 1: Change the five Text labels**

Exact replacements inside `InlineApprovalButtons.body` (styles/paddings unchanged — only the `Text(...)` string):

| ~Line | BEFORE | AFTER |
|---|---|---|
| ~725 | `Text("Cancel")` | `Text("Cancel (Esc)")` |
| ~741 | `Text("Confirm")` | `Text("Confirm (C)")` |
| ~755 | `Text("Deny")` | `Text("Deny (N)")` |
| ~771 | `Text("Allow")` | `Text("Allow (Y)")` |
| ~789 | `Text("Always")` | `Text("Always (A)")` |

Match chat-page wording exactly (`ChatView.swift` L1811/L1827/L1863/L1881/L1900).

- [ ] **Step 2: Build**

Run: `xcodebuild -project Nook.xcodeproj -scheme Nook -configuration Debug -destination 'platform=macOS' build`
Expected: `BUILD SUCCEEDED`

- [ ] **Step 3: Visual check**

Run: `open ~/Library/Developer/Xcode/DerivedData/Nook-*/Build/Products/Debug/Nook.app`
Open instances page with a pending permission → three capsules read `Deny (N)` / `Allow (Y)` / `Always (A)`; click Always → `Cancel (Esc)` / `Confirm (C)`.
Expected: no text truncation (buttons use `.fixedSize`; `layoutPriority(1)` already reserves width — spec risk table).

- [ ] **Step 4: Commit**

```bash
git add Nook/UI/Views/SessionListView.swift
git commit -m "feat(session-list): add keycap hints to inline approval buttons"
```

---

### Task 4: Keyboard monitor — Y/N/A/C/Esc with 0/1/2+ target rules

**Files:**
- Modify: `Nook/UI/Views/SessionListView.swift`
  - `@State` block (~L19-21)
  - `body` onAppear/onDisappear (~L103-124)
  - new MARK section after `// MARK: - Actions` handlers (~L262)

- [ ] **Step 1: Add monitor handle state**

Extend the `@State` block (Task 2 already added `confirmingSessionId`):

```swift
    /// Local keyDown monitor for Y/N/A/C/Esc (installed on appear — spec §4).
    @State private var keyMonitor: Any?
```

- [ ] **Step 2: Install/remove + handleKeyDown**

Insert a new section after `rejectSession` (~L262), before `archiveSession`:

```swift
    // MARK: - Keyboard (AppKit local monitor — Y/N/A on instances page)

    private func installKeyboardMonitor() {
        guard keyMonitor == nil else { return }
        // Deliberately NO NSApp.activate / makeKey here: NotchWindowController
        // L75-77 skips activate only for .notification opens (task-finished
        // notifications mount THIS page while the user types elsewhere —
        // activating would route subsequent keystrokes into Nook and a stray
        // `y` could approve a permission). User-initiated opens (click/hover/
        // hotkey) are already key via the window controller.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            self.handleKeyDown(event)
        }
    }

    private func removeKeyboardMonitor() {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
    }

    private func handleKeyDown(_ event: NSEvent) -> NSEvent? {
        // Skip when an editable text field is focused (mirrors ChatApprovalBar)
        if let responder = NSApp.keyWindow?.firstResponder,
           (responder.isKind(of: NSTextView.self) || responder.isKind(of: NSTextField.self)) {
            return event
        }

        let mods = event.modifierFlags
        guard !mods.contains(.command), !mods.contains(.control) else { return event }

        let chars = event.charactersIgnoringModifiers?.lowercased() ?? ""

        // Confirm step: scoped to confirmingSessionId's row (may differ from highlight)
        if confirmingSessionId != nil {
            if chars == "c" {
                if let id = confirmingSessionId,
                   let session = sortedInstances.first(where: { $0.sessionId == id }) {
                    approveAlwaysSession(session)
                }
                confirmingSessionId = nil
                return nil
            }
            if event.keyCode == 53 { // Esc — cancel confirm only; NOT closeNotch
                                     // (list monitor is LIFO-later ⇒ receives first)
                confirmingSessionId = nil
                return nil
            }
            return event
        }

        guard chars == "y" || chars == "n" || chars == "a" else { return event }

        // Resolve target (spec §2): 0 → none; 1 → ignore highlight; 2+ → highlight must be a target
        let targets = approvalTargets
        let target: SessionState?
        switch targets.count {
        case 0:
            target = nil
        case 1:
            target = targets[0]
        default:
            let idx = viewModel.keyboardSelectedIndex // -1 = no highlight (NotchViewModel L118)
            guard idx >= 0, idx < sortedInstances.count else { return event }
            let highlighted = sortedInstances[idx]
            target = highlighted.showsInlineApprovalButtons ? highlighted : nil
        }
        guard let target else { return event }

        switch chars {
        case "y":
            approveSession(target)
            return nil
        case "n":
            rejectSession(target)
            return nil
        case "a":
            guard target.canApproveAlways else { return event } // non-OpenCode: pass through
            confirmingSessionId = target.sessionId
            return nil
        default:
            return event
        }
    }
```

- [ ] **Step 3: Lifecycle hooks in body**

Change existing `onAppear` (~L103-105):

```swift
        .onAppear {
            syncLayoutMetrics()
            installKeyboardMonitor()
        }
```

Append after the last `.onChange` (after Task 2's `approvalTargets` onChange):

```swift
        .onDisappear {
            removeKeyboardMonitor()
            confirmingSessionId = nil
        }
```

- [ ] **Step 4: Build**

Run: `xcodebuild -project Nook.xcodeproj -scheme Nook -configuration Debug -destination 'platform=macOS' build`
Expected: `BUILD SUCCEEDED`

- [ ] **Step 5: Commit**

```bash
git add Nook/UI/Views/SessionListView.swift
git commit -m "feat(session-list): Y/N/A/C/Esc permission shortcuts on instances page"
```

---

### Task 5: Supersede ⌘↩/⌘⌫ row in permission spec

**Files:**
- Modify: `docs/specs/2026-07-10-opencode-permission-handling.md:536`

- [ ] **Step 1: Replace the out-of-scope row**

Exact replacement (line 536 of the `不在本 spec 范围` table):

```markdown
| 键盘快捷键 | ~~⌘↩ / ⌘⌫~~ 改为 Y/N/A（与 ChatApprovalBar 一致）；chat 页已上线，instances 页由 `docs/superpowers/specs/2026-09-23-session-list-permission-shortcuts-design.md` 实现 | 已取代 |
```

- [ ] **Step 2: Commit**

```bash
git add docs/specs/2026-07-10-opencode-permission-handling.md
git commit -m "docs(specs): supersede ⌘↩/⌘⌫ permission shortcut plan with Y/N/A"
```

---

### Task 6: Manual verification checklist (spec §Testing)

**Files:** none (verification only)

- [ ] **Step 1: Full build**

Run: `xcodebuild -project Nook.xcodeproj -scheme Nook -configuration Debug -destination 'platform=macOS' build`
Expected: `BUILD SUCCEEDED`

- [ ] **Step 2: Run the app**

Run: `open ~/Library/Developer/Xcode/DerivedData/Nook-*/Build/Products/Debug/Nook.app`

- [ ] **Step 3: Execute checklist 1-9 from the spec**

From `docs/superpowers/specs/2026-09-23-session-list-permission-shortcuts-design.md` Testing section — every item must pass:

1. **No focus steal:** task-finished notification opens instances page while typing in another app → keystrokes stay in that app; no stray Y approval
2. **Single target:** 1 opencode pending, no highlight → Y approves; A → confirm mode; C approves; Esc cancels **and notch stays open** (LIFO Esc routing)
3. **Two targets:** 2 pendings → Y with no highlight does nothing; ⌃N to one row → Y hits that row
4. **Highlight non-target:** highlight idle row with 2 pendings → Y passes through; also with `keyboardSelectedIndex == -1`
5. **Non-opencode:** claude pending → A passes through (no Always keycap)
6. **Question row:** Y does not approve; ⌃R still opens question panel
7. **Chat regression:** chat-page bar Y/N/A unchanged
8. **Confirm resets:** leave page/close notch during confirm → no residue on reopen; row A confirm + click row B Always → A exits
9. **Log:** `/tmp/nook-debug.log` shows approve/deny with correct `directory` (stacks on plugin 1.5.1 fix)

- [ ] **Step 4: Record verification**

If all 9 pass: no code commit. Note the result when closing the PROGRESS Verify entry for this feature (use the `/progressing` skill's close flow — do not hand-edit PROGRESS format).

If any fail: fix in the owning task's file, re-run Step 1, and only then re-check the failed item.
