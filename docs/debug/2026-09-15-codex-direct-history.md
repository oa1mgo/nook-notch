# Codex direct conversation recovery — 2026-09-15

## Symptom and reproduction

Codex sessions showed tools/assistant output but no direct user input. Long
conversations also lost earlier history and new text did not update while chat
stayed open. The September 1 compatibility change (`73cc583`) rejected all
`response_item/message` user rows and assumed `event_msg/user_message` existed.
The local Desktop recordings from September 1–15 instead use the typed
`event_msg/item_completed` boundary. This was already true on September 1;
it is not evidence of an overnight upstream change.

A read-only replay of the current long conversation initially found 64 direct
user events across three rollout fragments and zero parsed user updates. After
the user requested the fix, the same comparison contains 65 direct inputs.
Private transcripts are not copied into this repository or uploaded.

## Supported boundaries

| Source record | Handling |
| --- | --- |
| `event_msg/item_completed`, `item.type=UserMessage` | Read text blocks, validate thread ID when present, preserve native item ID. |
| `event_msg/user_message` | Retain legacy direct-input support. |
| `response_item/message`, `role=user` | Ignore: model input can contain memory, plugins, environment, or a duplicate prompt. |
| `response_item/message`, `role=assistant` | Preserve text and native message ID. |
| Tool calls/results | Retain existing adapters; fallback IDs are file/byte-position scoped. |

Do not add content-string filters to direct user events: the user may legitimately
type an environment tag or discuss memory. Likewise, do not accept every
user-role model input as a fallback. Desktop fixture fields are based on the
observed local records; legacy coverage is fixture-based, not a fresh CLI UI run.
Image-only prompts are not newly rendered by this text-history fix.

## Files, ordering, and synchronization

- Discover all rollout filenames matching the requested ID, then verify exact
  `session_meta.payload.id` before reading. Read the complete first metadata line
  (bounded at 4 MiB), not an 8 KiB prefix. Sort fragments by timestamped filename.
- A cursor owns each canonical path and file identity/byte offset. New files and
  atomic replacements start at zero; smaller files rewind. Partial trailing JSON
  is retried. Native IDs deduplicate copied overlap; a file/byte fallback stays
  stable for full versus incremental reads. Distinct repeated prompts remain
  distinct. This assumes append-only rollouts; arbitrary same-inode rewrites
  larger than the committed offset are not a supported transcript operation.
- A user-created fork is not a subagent merely because it has `forked_from_id`.
  Explicit subagent source/role/nickname metadata still hides agent sessions.
- Codex now has demonstrably non-append arrival: older fragments, live hooks,
  and delayed transcript text. Its adapter therefore uses source timestamp
  ordering throughout. Other providers keep their existing ordering policies.
- One debounced (100 ms) read runs per session. A hook during the read queues
  another pass rather than cancelling useful work or racing a cursor. The
  existing three-second status timer also syncs active turns and idle sessions
  within ten seconds of their last lifecycle activity, catching delayed final
  output. Explicit chat opens can refresh older idle sessions at any time.
- `/clear`, end, expiration, and test reset invalidate task tokens and cursors;
  a detached result cannot repopulate a cleared or recreated session. Clear's
  timestamp boundary applies to all files, including future incremental reads.
- Transcript updates remain content-only. They do not extend lifecycle activity,
  reactivate completed turns, or repeat completion notifications. Batch reduction
  sorts once at the end, avoiding a full history sort for every replayed row.

## Validation and diagnostics

The focused suite covers current/legacy messages, injected context exclusion,
repeated text, native-ID overlap, exact session matching, large metadata,
user forks/subagents, offset stability, new/replaced fragments, clear boundaries,
concurrent loads, live hook/tool order, text-only periodic updates, delayed final
replies, and end cancellation. Sanitized fixtures contain no real transcript text.

Read-only production-parser replay (with a diagnostic collector in place of the
UI adapter): three real fragments, 65/65 direct messages matching native IDs and
text exactly, no duplicates, 70 model-input user rows ignored. Initial read took
about 2.45 seconds; unchanged incremental read about 5 ms with zero updates on
this Mac. These are parser timings, not UI frame-rate or full-app memory claims.

Logs and the local-only replay harness are under ignored `build/CodexHistory143/`.
With the user's debug-log setting enabled, look for `[codex-transcript-sync]` in
`/tmp/nook-debug.log`: `updates=N files=M` means committed content arrived; no line
on an unchanged poll is normal. `[codex-lifecycle] userPromptSubmit` proves hook
receipt, not that a chat bubble was created. Missing rows should be investigated
by comparing native direct events with parser output, not by disabling context
filtering.

Local build prerequisite: Xcode 27 adds `SwiftUI.Document`; the renderer now
qualifies `Markdown.Document` explicitly. Stop an existing Nook instance before
hosted XCTest runs, otherwise the app's single-instance guard exits the test
runner before its connection is established. No single-instance policy changed.

Final local validation: 30 focused tests and all 116 app tests pass; 16 packaging
tests, Release build (deployment target 15.5, matching CI), and mounted DMG
checks pass. Debug build/run confirms version 1.4.3, build 3. The UI automation
could inspect the running collapsed notch but could not open its global-click
driven panel; an actual chat-bubble screenshot is therefore not claimed as
verified. No music appearance, capture permission, or signing policy changed.
