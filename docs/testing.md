# Testing

Nook uses an Xcode unit-test target named `NookTests`. The target is hosted by
`Nook.app` so tests can access internal app modules through `@testable import
Nook`, but the test suite should stay focused on deterministic domain logic.

Run the local suite with:

```bash
xcodebuild test -project Nook.xcodeproj -scheme Nook -configuration Debug -derivedDataPath build/TestDerivedData -destination 'platform=macOS'
```

If stale build products require a clean local run, reset the test DerivedData:

```bash
rm -rf build/TestDerivedData
xcodebuild test -project Nook.xcodeproj -scheme Nook -configuration Debug -derivedDataPath build/TestDerivedData -destination 'platform=macOS'
```

The XCTest host skips application bootstrap and shutdown effects: it does not
install hooks, create the notch window, start telemetry, or bind the production
socket. Tests can run while a normal Nook instance is open. The test target is
still intentionally not parallelizable in the shared scheme because legacy
tests share store and adapter singleton state.

New store tests should construct their own `SessionStore()` and inject it into
consumers such as `ChatHistoryManager(store:)`. Runtime lifecycle tests inject
only lifecycle effects, so they do not start production watchers or sockets.
Claude read tests inject `ClaudeConversationReading` and a zero debounce into
`SessionStore`; continuation gates control I/O completion, and bounded waits
observe specific requests or pending state. Parser fixtures inject a temporary
`projectsRoot` and never read the user's Claude history.
This isolates those boundaries; it does not make every legacy parser/process
lookup test independent of the local environment.

If `xcodebuild` reports that the active developer directory is Command Line
Tools, prefix the command with
`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.

The `Tests` GitHub Actions workflow runs the app suite and existing packaging
unit tests on pull requests and pushes to `main`. App test failures retain the
Xcode log and result bundle for seven days. This workflow does not configure
branch protection or publish releases.

## Current Coverage

- Provider adapters:
  - `ClaudeConversationReaderTests` covers candidate cursor replay, `/clear`,
    full-path isolation, result-only appends, and injected subagent paths.
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
  - `SessionStoreLifecycleTests` covers session resource ownership, ordering
    isolation, buffered content/lifecycle semantics, and complete test reset.
  - `SessionStoreClaudeReadTests` covers suspended reads across end/recreation,
    reset and clear, single-flight coalescing, content-only history, current hook
    and subagent state preservation, and result-only tool completion.
  - `ChatHistoryManagerTests` covers full-snapshot removal, reused session IDs,
    and subagent tool filtering without mutating the source store.
- Application runtime:
  - `AppRuntimeEnvironmentTests` covers XCTest detection and inert host bootstrap.
  - `SessionRuntimeTests` covers idempotent lifecycle effects, ordered polling
    transitions, and UI projection recreation without replacing watcher delegates.
  - `HookSocketServerLifecycleTests` exercises queued start/stop and listener
    restart using temporary socket paths, without touching `/tmp/nook.sock`.

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
