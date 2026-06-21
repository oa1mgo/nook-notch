# Testing

Nook uses an Xcode unit-test target named `NookTests`. The target is hosted by
`Nook.app` so tests can access internal app modules through `@testable import
Nook`, but the test suite should stay focused on deterministic domain logic.

Run the local suite with:

```bash
xcodebuild test -project Nook.xcodeproj -scheme Nook -configuration Debug -derivedDataPath build/TestDerivedData -destination 'platform=macOS'
```

For a clean local run, quit any running `Nook.app`, then reset the test
DerivedData first:

```bash
rm -rf build/TestDerivedData
xcodebuild test -project Nook.xcodeproj -scheme Nook -configuration Debug -derivedDataPath build/TestDerivedData -destination 'platform=macOS'
```

The test target is intentionally not parallelizable in the shared scheme. The
app owns singleton state and local process resources such as `/tmp/nook.sock`,
so parallel host launches can make Xcode report an early test-runner exit even
when individual tests pass.

## Current Coverage

- Provider adapters:
  - `ClaudeChatItemAdapterTests` covers Claude JSONL/history conversion, tool
    status propagation, and rejected `AskUserQuestion` structured fallback.
  - `CodexHookAdapterTests` covers Codex hook alias decoding, provider error
    detection, and legacy payload detection.
  - `CodexTranscriptParserTests` covers transcript sync filtering, including
    `/clear` lower-bound behavior for missing or malformed timestamps.
  - `CursorSessionStateReducerTests` covers Cursor lifecycle transitions and
    dangling tool finalization.
  - `OpencodeChatItemAdapterTests` covers opencode raw bus envelopes through
    the chat-item adapter boundary, including message-relative ordering and
    bash metadata error detection.
- Shared state pipeline:
  - `ChatItemUpdateReducerTests` covers insert/update ordering, duplicate
    prompt preservation, and tool status updates.
  - `SessionStateTests` covers terminal approval state exposure.
  - `SessionStoreCodexLifecycleTests` covers Codex stop cleanup and completion
    notification behavior.

## Adding Tests

Keep provider-specific behavior in provider-specific test files. Shared tests
should only assert provider-agnostic contracts such as `ChatItemUpdateReducer`
ordering or `SessionState` phase behavior.

Prefer fixtures at the provider boundary:

- Claude: build `ChatMessage` values and call `ClaudeChatItemAdapter`.
- Codex: decode hook envelopes or feed JSONL rows into `CodexTranscriptParser`.
- Cursor: feed `CursorSessionEvent` into `CursorSessionStateReducer` unless the
  hook envelope shape itself is under test.
- opencode: build `OpencodeHookEnvelope` values and call
  `OpencodeChatItemAdapter.adaptAndConvert(_:)` so hook parsing and chat-item
  conversion stay covered together.

Avoid UI assertions in this target unless the view has first been split into a
small deterministic model or formatter. The goal of these tests is to catch
regressions in session state, provider parsing, and chat-item transformation
without requiring a live terminal, agent process, or music session.
