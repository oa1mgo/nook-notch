//
//  OpencodeHookAdapter.swift
//  Nook
//
//  Translates raw OpenCode bus events (from the plugin socket) into the
//  normalised OpencodeSessionEvent surface that Nook's session store consumes.
//
//  Event model (reverse‑engineered from opencode v1.15.13 bus):
//    session.created        → sessionStart (legacy; current versions use session.updated)
//    session.updated        → sessionStart on first sighting; refreshes cwd afterwards
//    session.status         → processingStarted on busy;
//                            on idle, only flush pending text buffers
//                            (do NOT emit .stop — see handleSessionStatus)
//    session.idle           → stop (canonical session-end signal)
//    question.asked         → waitingForUserInput (verified 2026-06-17 to
//                              fire in v1.17.x; handleQuestionAsked is the
//                              primary path, handleToolPart has a
//                              defensive fallback below)
//    message.updated        → user/assistant message boundary
//    message.part.updated   → user text, assistant text (initial empty), bash tool
//    message.part.delta     → assistant text streaming chunks (field=text)
//
//  Assistant text arrives via a chain:
//    message.part.updated(type=text, text="")   → initialise buffer for messageID
//    message.part.delta(field=text, delta=...)  → append chunks
//    message.updated(role=assistant, finish=stop) → flush buffer as .assistantText
//
//  AskUserQuestion phase — two redundant detection paths converge on
//  the same `.waitingForUserInput` event:
//    1. handleQuestionAsked (line ~498) — primary path, listens for
//       opencode's `question.asked` bus event. Verified firing in
//       v1.17.x (2026-06-17, log shows [opencode] event type=question.asked).
//       Earlier during this session we observed runs where this event
//       was missing from the log — likely timing/connection issues
//       (e.g. opencode hadn't fully started, plugin socket hadn't
//       bound yet), NOT that the event doesn't exist.
//    2. handleToolPart (line ~1036) — defensive fallback, derives the
//       phase from the standard `message.part.updated(type=tool,
//       tool=question)` event. Kept because:
//         - The two paths are idempotent (both set .waitingForInput)
//         - If question.asked ever fails to reach us (transport loss,
//           version regression, plugin breakage), the list view still
//           gets the correct phase
//         - It's "evidence-driven" detection from events we KNOW fire
//

import Foundation
import os.log

final class OpencodeHookAdapter: @unchecked Sendable {

    // MARK: - Diagnostic logging (temporary)

    nonisolated private static let log = Logger(subsystem: "com.celestial.Nook", category: "OpencodeAdapter")

    /// Mirrors `log.notice` to the on-disk debug log (when enabled) so
    /// hook activity is reproducible from a single file. The os_log
    /// call is kept because Console.app is still the most convenient
    /// view during development; the file mirror exists for field
    /// reports and AI-assisted debugging.
    fileprivate static func logNotice(_ message: String) {
        log.notice("\(message, privacy: .public)")
        DebugLog.shared.write("[opencode] " + message)
    }

    // MARK: - State

    private static var lock = NSLock()

    // TODO(perf): All `private static var` state declared below is
    // session-scoped (or message-scoped within a session) and was
    // previously NEVER cleared when the corresponding session ends.
    // Cleanup is now implemented in `cleanupState(forSession:)`, called
    // from `handleSessionStatus(idle)` and `handleSessionIdle`.
    //
    // State that remains unbounded (cannot be cleaned per-session):
    //   - runningToolCallIds: keyed by callID, no session mapping;
    //     tracking `callID → sessionId` would be needed. Low risk
    //     because the set is bounded by active tool calls only
    //     (entries are removed on completed/error).

    /// sessionID → cwd from session.created / session.updated
    private static var sessionCwd: [String: String] = [:]
    /// sessionID → messageID of the most recent user message awaiting its text part
    private static var latestUserMsgID: [String: String] = [:]
    /// messageID → accumulating assistant text (from message.part.delta chunks,
    /// or seeded by a non-empty message.part.updated(type=text) for v1.15.12-style events)
    private static var pendingTextByMessage: [String: String] = [:]
    /// messageID → accumulating reasoning / thinking text (from message.part.delta
    /// chunks with field=reasoning, seeded by a non-empty message.part.updated(type=reasoning))
    private static var pendingReasoningByMessage: [String: String] = [:]
    /// messageID → sessionID, so the session-idle safety net can flush only
    /// buffers belonging to the session that's going idle.
    private static var messageSession: [String: String] = [:]
    /// messageIDs whose assistant text has already been emitted as .assistantText
    private static var emittedTextMessages: Set<String> = []
    /// messageIDs that were already consumed as user text via latestUserMsgID.
    /// Prevents a second `message.part.updated(type=text)` with the same
    /// messageID from falling through to the assistant text buffer.
    private static var consumedUserMessageIDs: Set<String> = []
    /// sessionID → the most recently consumed user prompt text. Used by
    /// `handleTextPart`'s trailing-echo detection (#71/#78): if a reasoning
    /// messageID receives a text part whose content matches the user prompt,
    /// it's the trailing-echo pattern (opencode re-emits the user prompt on
    /// the reasoning messageID after stop). Otherwise it's a legitimate
    /// post-reasoning assistant text and must be flushed normally.
    private static var consumedUserPromptBySession: [String: String] = [:]
    /// DIAGNOSTIC (#79): count of events that landed in the top-level
    /// per-session handlers for a given session BEFORE `session.created`
    /// registered it as a subagent. If non-zero at child-registration time,
    /// those events reached the parent as if they were parent output —
    /// confirming the race-condition hypothesis (child message.part events
    /// arriving before session.created populates `subagentToParent`). The
    /// counter increments on every event whose sessionId isn't yet in
    /// `subagentToParent`; cleared when the session is registered.
    private static var preRegistrationEventCount: [String: Int] = [:]
    /// messageIDs whose assistant text should NEVER be emitted — these are
    /// the opencode `question` tool's parent messages. The question text is
    /// the prompt the user already sees in the opencode TUI when answering,
    /// and is meta-content rather than conversation flow. We mark the
    /// messageID as suppressed when `question.asked` arrives carrying
    /// `tool.messageID` (in `handleQuestionAsked` below) so both the
    /// `finish=stop` flush path and the `flushPendingText` safety net skip
    /// it. Without this the safety net would emit the question text at the
    /// END of the next turn — visibly out of order in the chat.
    private static var suppressedTextMessages: Set<String> = []
    /// messageIDs that have a reasoning part — set as soon as we see
    /// `message.part.updated type=reasoning` (even when the initial text is empty).
    /// Used by `handlePartDelta` to route opencode's `field="text"` reasoning-delta
    /// events into the reasoning buffer (opencode v1.15.13 emits reasoning-delta
    /// with `field: "text"`, see opencode/src/session/processor.ts:131-141).
    /// MUST stay separate from `emittedReasoningMessages` — adding a messageID here
    /// is a routing decision, not an emission, and would otherwise cause reasoning
    /// to be dropped (flush paths would see "already emitted" and return []).
    private static var knownReasoningMessageIds: Set<String> = []
    /// messageIDs whose reasoning text has already been emitted as .assistantThinking.
    /// Only set when we actually emit the event (at part-final-text in
    /// `handleReasoningPart`, or at flush time as a fallback). Prevents the
    /// duplicate-thinking bug where stop-time flushes re-emit the same content.
    private static var emittedReasoningMessages: Set<String> = []
    /// messageIDs whose reasoning part has been finalized (i.e. the final
    /// `message.part.updated type=reasoning text=…` event has fired and the
    /// .assistantThinking emit has happened). After this, any subsequent
    /// `message.part.delta field=text` for the same messageID is a TEXT delta
    /// for the assistant response that follows the reasoning — NOT a
    /// reasoning delta. opencode v1.15.13 streams reasoning first, then text
    /// on the same messageID; both deltas carry `field=text` so we need this
    /// state to route them correctly. See #73 in the task list.
    private static var reasoningFinalizedMessageIds: Set<String> = []
    /// callIDs whose preTool has already been emitted (opencode fires
    /// status=running 2–3 times per tool; only the first should create a chat item).
    private static var runningToolCallIds: Set<String> = []
    /// child sessionID → parent sessionID. Populated when a `session.created` /
    /// `session.updated` event carries `info.parentID` — opencode creates a fresh
    /// session for every subagent (Task tool) and links it to the parent via this
    /// field (see opencode/src/tool/task.ts:75-76). We use it to keep the subagent
    /// out of the instance list and route its activity into the parent's chat view.
    private static var subagentToParent: [String: String] = [:]
    /// child sessionID → the parent session's `task` tool callID. Established when
    /// the parent's `preTool(tool=task)` arrives and the child session is already
    /// known; used to tag subsequent subagent tool events with the right task id.
    private static var subagentTaskToolId: [String: String] = [:]
    /// Reverse lookup: parent sessionID → child sessionID currently awaiting task id
    /// association. Lets the parent's `preTool(tool=task)` find the right child
    /// even when multiple subagents are spawned in quick succession.
    private static var parentAwaitingTask: [String: String] = [:]

    // MARK: - Public API

    /// Convert a raw envelope into zero or more tracked Nook events.
    /// Returns an empty array for events Nook does not care about.
    static func adapt(_ envelope: OpencodeHookEnvelope) -> [OpencodeSessionEvent] {
        guard envelope.origin == "opencode" else { return [] }
        let props = envelope.properties ?? [:]

        let sessionId = (props["sessionID"]?.value as? String) ?? "?"
        let role: String
        if let info = props["info"]?.value as? [String: Any] {
            role = (info["role"] as? String) ?? "?"
        } else {
            role = "-"
        }
        let partType: String
        let partText: String
        if let part = props["part"]?.value as? [String: Any] {
            partType = (part["type"] as? String) ?? "-"
            let t = (part["text"] as? String) ?? ""
            partText = String(t.prefix(40))
        } else {
            partType = "-"
            partText = ""
        }
        let partCallID: String
        if let part = props["part"]?.value as? [String: Any] {
            partCallID = (part["callID"] as? String) ?? "-"
        } else {
            partCallID = "-"
        }
        let partStatus: String
        if let part = props["part"]?.value as? [String: Any],
           let state = part["state"] as? [String: Any] {
            partStatus = (state["status"] as? String) ?? "-"
        } else {
            partStatus = "-"
        }
        let sessionStatus: String
        if let status = props["status"]?.value as? [String: Any],
           let t = status["type"] as? String {
            sessionStatus = t
        } else {
            sessionStatus = "-"
        }
        Self.logNotice("event type=\(envelope.type) session=\(sessionId) role=\(role) partType=\(partType) partStatus=\(partStatus) sessionStatus=\(sessionStatus) callID=\(partCallID) text=\(partText)")

        // Subagent routing: if this session is already registered as a child of
        // some parent, intercept here so we never let the child events reach the
        // per-session handlers (which would create a top-level SessionState).
        // The handlers below assume top-level sessions; subagent-specific
        // translation is done in `adaptSubagentEvent` and via direct
        // subagent-tool translation in `handleToolPart`.
        if let parentID = lookupParent(for: sessionId), parentID != sessionId {
            // DIAGNOSTIC (#79): confirm the routing actually catches this
            // subagent event. If a session's events are appearing as
            // top-level chatItems despite `subagentToParent` being populated,
            // this HIT log will be missing for those events — pointing at
            // either a routing miss (event arrives before session.created
            // registers the child) or a hit that's emitting wrong content.
            Self.logNotice("→ subagent routing HIT session=\(sessionId) parent=\(parentID) envelopeType=\(envelope.type)")
            return adaptSubagentEvent(envelope: envelope, props: props, childId: sessionId, parentId: parentID)
        }

        // DIAGNOSTIC (#79): events whose sessionId isn't yet in
        // `subagentToParent` fall through to the per-session handlers below.
        // For sessions that turn out to be subagents (registered later via
        // session.created), this counter records how many events leaked
        // through before the routing was set up. A non-zero count at child
        // registration time would confirm the race-condition hypothesis.
        // Don't count session.created/session.updated themselves — those are
        // what eventually populate the mapping.
        if envelope.type != "session.created" && envelope.type != "session.updated" {
            lock.lock()
            preRegistrationEventCount[sessionId, default: 0] += 1
            lock.unlock()
        }

        switch envelope.type {
        case "session.created", "session.updated":
            return handleSessionCreatedOrUpdated(props)
        case "session.status":
            return handleSessionStatus(props)
        case "session.idle":
            return handleSessionIdle(props)
        case "question.asked":
            return handleQuestionAsked(props)
        case "message.updated":
            return handleMessageUpdated(props)
        case "message.part.updated":
            return handlePartUpdated(props)
        case "message.part.delta":
            return handlePartDelta(props)
        default:
            return []
        }
    }

    /// Read-only lookup that does NOT insert. We need to distinguish "this
    /// sessionId is a known child" (early in adapt, to route) from "we just
    /// discovered this child via session.created" (in handleSessionCreatedOrUpdated,
    /// to record the mapping). `subagentToParent[sessionId] != nil` is the
    /// single source of truth.
    private static func lookupParent(for sessionId: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return subagentToParent[sessionId]
    }

    /// Translate a subagent session's raw envelope into parent-scoped Nook
    /// events. Everything except tool events is dropped — subagent text and
    /// reasoning are not user-visible (see opencode/src/tool/task.txt:20: "The
    /// result returned by the agent is not visible to the user"), and the
    /// subagent's own user prompt is the task tool's input which the parent
    /// already receives via `preTool(tool=task)`.
    private static func adaptSubagentEvent(envelope: OpencodeHookEnvelope, props: [String: AnyCodable], childId: String, parentId: String) -> [OpencodeSessionEvent] {
        switch envelope.type {
        case "message.part.updated":
            // Tool parts are handled here so we can translate them into
            // subagentToolExecuted / subagentToolCompleted on the parent. Text
            // and reasoning parts are dropped.
            guard let part = props["part"]?.value as? [String: Any],
                  let partType = part["type"] as? String,
                  partType == "tool" else {
                return []
            }
            return handleSubagentToolPart(childId: childId, parentId: parentId, part: part)

        case "session.status", "session.idle":
            // Subagent session is going idle — flush any text/reasoning buffers
            // that were accidentally accumulated for the child (shouldn't happen
            // now that we route early, but the safety net is cheap and prevents
            // stale buffers from bleeding into the parent on next start).
            let cwd: String = {
                lock.lock()
                let v = sessionCwd[childId] ?? ""
                lock.unlock()
                return v
            }()
            let flushed = flushPendingText(forSession: childId, cwd: cwd)
            cleanupState(forSession: childId)
            Self.logNotice("→ subagent stop routed to parent child=\(childId) parent=\(parentId) flushed=\(flushed.count)")
            return flushed

        default:
            return []
        }
    }

    /// Convert a subagent's tool part into a subagentToolExecuted /
    /// subagentToolCompleted event on the parent session. The tool's callID
    /// (scoped to the child's message stream) is preserved as the subagent
    /// tool id — SubagentToolCall has no cross-session id semantics.
    private static func handleSubagentToolPart(childId: String, parentId: String, part: [String: Any]) -> [OpencodeSessionEvent] {
        guard let toolName = part["tool"] as? String else { return [] }
        guard let state = part["state"] as? [String: Any] else { return [] }
        guard let status = state["status"] as? String else { return [] }

        let _ = part["messageID"] as? String
        // The Task tool itself is the parent-side event; the child never sees
        // its own task invocation, so this guard is just defensive.
        guard toolName != "task" else { return [] }

        let callId = part["callID"] as? String
        let input = state["input"] as? [String: Any]
        let inputSummary = buildInputSummary(toolName: toolName, input: input)

        switch status {
        case "running":
            Self.logNotice("→ subagentToolExecuted child=\(childId) parent=\(parentId) callID=\(callId ?? "-") tool=\(toolName) input=\(inputSummary)")
            // SubagentToolCall carries only what the chat UI needs; we keep the
            // callID so postTool status updates can be correlated. The
            // sessionId on the event is the parent's so SessionStore routes
            // through processSubagentToolExecuted's subagentState bookkeeping.
            return [.subagentToolExecuted(
                sessionId: parentId,
                tool: SubagentToolCall(
                    id: callId ?? "subagent-\(childId)-\(UUID().uuidString)",
                    name: toolName,
                    input: ["summary": inputSummary],
                    status: .running,
                    timestamp: Date()
                )
            )]
        case "completed":
            guard let callId else {
                Self.logNotice("→ subagent tool completed without callID, skipping child=\(childId) tool=\(toolName)")
                return []
            }
            Self.logNotice("→ subagentToolCompleted child=\(childId) parent=\(parentId) callID=\(callId) tool=\(toolName)")
            return [.subagentToolCompleted(sessionId: parentId, toolId: callId, status: .success)]
        default:
            return []
        }
    }

    // MARK: - Session Handlers

    private static func handleSessionCreatedOrUpdated(_ props: [String: AnyCodable]) -> [OpencodeSessionEvent] {
        guard let sessionId = props["sessionID"]?.value as? String else { return [] }
        let info = props["info"]?.value as? [String: Any]
        let cwd = info?["directory"] as? String ?? ""
        // opencode sets `parentID` on every session created via the Task tool
        // (see opencode/src/tool/task.ts:75-76). When present, this is a subagent
        // session — it must NOT be exposed as a top-level session in the instance
        // list, and its activity must be merged into the parent session's chat view.
        let parentID = info?["parentID"] as? String

        if let parentID, parentID != sessionId {
            lock.lock()
            let isFirstSighting = subagentToParent[sessionId] == nil
            subagentToParent[sessionId] = parentID
            // Track this child against the parent so the parent's subsequent
            // `preTool(tool=task)` can find the right child. The most recent
            // unscheduled child "wins" if multiple spawn in flight.
            parentAwaitingTask[parentID] = sessionId
            // DIAGNOSTIC (#79): if any events for this session landed in the
            // top-level handlers before session.created arrived, they were
            // treated as parent output (text → .assistant, reasoning →
            // .thinking). A non-zero count here is the smoking gun for the
            // race-condition hypothesis (child message.part events arriving
            // before session.created populates `subagentToParent`). When
            // investigating #79, search the log for this ⚠ line and check
            // the parent session's chatItems around the child's first
            // messageID.
            let preRegCount = preRegistrationEventCount.removeValue(forKey: sessionId) ?? 0
            lock.unlock()
            if preRegCount > 0 {
                Self.logNotice("⚠ DIAG #79 child registered with PRE-REGISTRATION EVENTS child=\(sessionId) parent=\(parentID) preRegCount=\(preRegCount) — events leaked to parent chatItems")
            }
            Self.logNotice("→ subagent child registered session=\(sessionId) parent=\(parentID) cwd=\(cwd) firstSighting=\(isFirstSighting)")
            // Do NOT emit .sessionStart for the child — that would create a
            // standalone SessionState and surface it in SessionListView.
            return []
        }

        lock.lock()
        let isNew = sessionCwd[sessionId] == nil
        sessionCwd[sessionId] = cwd
        lock.unlock()

        if isNew {
            Self.logNotice("→ sessionStart (first sighting) session=\(sessionId) cwd=\(cwd)")
            return [.sessionStart(sessionId: sessionId, cwd: cwd)]
        }
        Self.logNotice("→ session.updated (known) session=\(sessionId) cwd=\(cwd)")
        return []
    }

    private static func handleSessionStatus(_ props: [String: AnyCodable]) -> [OpencodeSessionEvent] {
        guard let sessionId = props["sessionID"]?.value as? String else { return [] }
        guard let status = props["status"]?.value as? [String: Any] else { return [] }
        let type = status["type"] as? String ?? ""
        let cwd: String = {
            lock.lock()
            let v = sessionCwd[sessionId] ?? ""
            lock.unlock()
            return v
        }()

        switch type {
        case "busy":
            Self.logNotice("→ processingStarted (session.status=busy) session=\(sessionId) cwd=\(cwd)")
            return [.processingStarted(sessionId: sessionId, cwd: cwd)]
        case "idle":
            // ⚠️ session.status=idle fires between tool calls (think → think → tool
            // → think) AND at the actual session end. We must NOT treat it as
            // session-end here — that would make the agent icon flash off
            // after every tool call (between operations the session is still
            // alive; the user can issue a new prompt).
            //
            // What we DO need to do: flush any assistant text buffers that
            // didn't get a finish=stop, otherwise accumulated text between
            // tool calls would be lost. The actual session end is handled
            // by `handleSessionIdle` (the legacy `session.idle` event fires
            // once when the session truly terminates).
            let events: [OpencodeSessionEvent] = flushPendingText(forSession: sessionId, cwd: cwd)
            Self.logNotice("→ idle (between ops) session=\(sessionId) flushed=\(events.count)")
            return events
        default:
            return []
        }
    }

    private static func handleSessionIdle(_ props: [String: AnyCodable]) -> [OpencodeSessionEvent] {
        guard let sessionId = props["sessionID"]?.value as? String else { return [] }
        let cwd: String = {
            lock.lock()
            let v = sessionCwd[sessionId] ?? ""
            lock.unlock()
            return v
        }()
        cleanupState(forSession: sessionId)
        Self.logNotice("→ stop (legacy session.idle) session=\(sessionId)")
        return [.stop(sessionId: sessionId, cwd: cwd)]
    }

    private static func cleanupState(forSession sessionId: String) {
        lock.lock()
        // Per-session dicts — direct removal
        sessionCwd.removeValue(forKey: sessionId)
        latestUserMsgID.removeValue(forKey: sessionId)
        consumedUserPromptBySession.removeValue(forKey: sessionId)
        preRegistrationEventCount.removeValue(forKey: sessionId)
        parentAwaitingTask.removeValue(forKey: sessionId)

        // Subagent dicts — sessionId may be a child or a parent
        subagentToParent.removeValue(forKey: sessionId)
        subagentTaskToolId.removeValue(forKey: sessionId)
        // Also remove child entries whose parent is this session
        subagentToParent = subagentToParent.filter { $0.value != sessionId }
        subagentTaskToolId = subagentTaskToolId.filter { $0.value != sessionId }

        // Message-scoped — collect messageIDs belonging to this session
        let messagesToRemove = messageSession.filter { $0.value == sessionId }.map(\.key)
        for messageId in messagesToRemove {
            pendingTextByMessage.removeValue(forKey: messageId)
            pendingReasoningByMessage.removeValue(forKey: messageId)
            messageSession.removeValue(forKey: messageId)
            emittedTextMessages.remove(messageId)
            suppressedTextMessages.remove(messageId)
            knownReasoningMessageIds.remove(messageId)
            emittedReasoningMessages.remove(messageId)
            reasoningFinalizedMessageIds.remove(messageId)
            consumedUserMessageIDs.remove(messageId)
        }
        lock.unlock()
        if !messagesToRemove.isEmpty {
            Self.logNotice("→ cleanup session=\(sessionId) messages=\(messagesToRemove.count)")
        }
    }

    private static func handleQuestionAsked(_ props: [String: AnyCodable]) -> [OpencodeSessionEvent] {
        guard let sessionId = props["sessionID"]?.value as? String else { return [] }
        let cwd: String = {
            lock.lock()
            let v = sessionCwd[sessionId] ?? ""
            lock.unlock()
            return v
        }()
        // opencode fires `question.asked` exactly when the
        // ask_user_question dialog appears. From opencode's perspective
        // the session is still "busy" (session.status stays busy until
        // the user answers), so without this explicit signal the notch
        // would keep showing the orange processing indicator while the
        // user is being asked to pick an option.
        //
        // Verified 2026-06-17: this event DOES fire in opencode v1.17.x
        // (log: [opencode] event type=question.asked). Earlier in this
        // session we observed runs where the event was absent — that
        // was likely a timing/connection issue (opencode hadn't fully
        // started, plugin socket hadn't bound), NOT a missing event.
        //
        // The event payload (opencode/src/question/index.ts:35-45, `Request`
        // schema) also carries `tool: { messageID, callID }` when the
        // question was invoked as a tool call — messageID is the parent
        // message whose text is the question prompt. We tag that messageID
        // as suppressed so its `assistantText` is dropped from the chat
        // history (the question prompt is meta-content the user already
        // sees in the opencode TUI; emitting it as chat text would show up
        // out-of-order at end of next turn). The opencode `question` tool
        // fires BOTH the standard preTool/postTool lifecycle (which creates
        // the visible chatItem via SessionStore, with kind=.askUserQuestion)
        // AND this separate `question.asked` event (the user-input signal).
        // The `question.asked` payload carries `tool.messageID` for the
        // parent — that's what we mark here so the parent's `assistantText`
        // is dropped before the safety-net flush has a chance to emit it.
        //
        // This handler is the PRIMARY detection path; handleToolPart has
        // a defensive fallback (line ~1036) that derives the phase from
        // `message.part.updated(type=tool, tool=question)` if this event
        // ever fails to arrive. The two paths are idempotent.
        if let tool = props["tool"]?.value as? [String: Any],
           let messageId = tool["messageID"] as? String,
           !messageId.isEmpty {
            lock.lock()
            suppressedTextMessages.insert(messageId)
            lock.unlock()
            Self.logNotice("→ suppressed question parent text session=\(sessionId) messageID=\(messageId)")
        }
        Self.logNotice("→ waitingForUserInput (question.asked) session=\(sessionId) cwd=\(cwd)")
        return [.waitingForUserInput(sessionId: sessionId, cwd: cwd)]
    }

    // MARK: - Message Handlers

    private static func handleMessageUpdated(_ props: [String: AnyCodable]) -> [OpencodeSessionEvent] {
        guard let sessionId = props["sessionID"]?.value as? String else { return [] }
        guard let info = props["info"]?.value as? [String: Any] else { return [] }
        let messageId = info["id"] as? String ?? ""
        guard !messageId.isEmpty else { return [] }
        let role = info["role"] as? String ?? ""
        let finish = info["finish"] as? String

        let cwd: String = {
            lock.lock()
            let v = sessionCwd[sessionId] ?? ""
            lock.unlock()
            return v
        }()

        if role == "user" {
            // If the text part arrived first, the buffer holds the prompt.
            lock.lock()
            let buffered = pendingTextByMessage.removeValue(forKey: messageId) ?? ""
            lock.unlock()
            if !buffered.isEmpty {
                // Capture for echo-detection in handleTextPart (#78).
                lock.lock()
                consumedUserPromptBySession[sessionId] = buffered
                lock.unlock()
                log.notice("→ userPromptSubmit (from buffer) session=\(sessionId) messageID=\(messageId) textChars=\(buffered.count)")
                return [.userPromptSubmitted(sessionId: sessionId, cwd: cwd, prompt: buffered, messageId: messageId)]
            }
            // Otherwise, wait for the text part.
            lock.lock()
            latestUserMsgID[sessionId] = messageId
            lock.unlock()
            Self.logNotice("→ user message — waiting for text part session=\(sessionId) messageID=\(messageId)")
            return []
        }

        if role == "assistant" && finish == "stop" {
            // Flush the accumulated reasoning and text for this messageID.
            // Reasoning comes first so the chat view shows thinking above
            // the final assistant text.
            var events: [OpencodeSessionEvent] = []
            events.append(contentsOf: flushOneMessageReasoning(messageId: messageId, sessionId: sessionId, cwd: cwd, trigger: "finish=stop"))
            events.append(contentsOf: flushOneMessageText(messageId: messageId, sessionId: sessionId, cwd: cwd, trigger: "finish=stop"))
            return events
        }

        return []
    }

    private static func handlePartUpdated(_ props: [String: AnyCodable]) -> [OpencodeSessionEvent] {
        guard let sessionId = props["sessionID"]?.value as? String else { return [] }
        guard let part = props["part"]?.value as? [String: Any] else { return [] }
        guard let partType = part["type"] as? String else { return [] }

        let cwd: String = {
            lock.lock()
            let v = sessionCwd[sessionId] ?? ""
            lock.unlock()
            return v
        }()

        switch partType {
        case "text":
            return handleTextPart(sessionId: sessionId, cwd: cwd, part: part)
        case "reasoning":
            // Tag the messageID as reasoning at part creation, even when the
            // initial `text` is empty — streaming deltas arrive between
            // creation and final-text, and they need to be routed into the
            // reasoning buffer from the first one. handleReasoningPart
            // returns [] for the empty-text case but still does the work
            // for the final-text case (full reasoning emit).
            let messageId = part["messageID"] as? String ?? ""
            let text = part["text"] as? String ?? ""
            // DIAGNOSTIC (#82): log every reasoning part arrival so we can
            // distinguish "opencode cleanup()'s updatePart never reached us"
            // (transport/bridge issue) from "updatePart reached us but our
            // handler dropped it" (handler issue). Without this log, a
            // missing `assistantThinking (final)` for a given messageID is
            // ambiguous between the two — we only know the emit didn't
            // happen, not whether the source event did or didn't arrive.
            //
            // TODO(#82): keep this log until Bug J's opencode-side root
            // cause is fully understood AND a regression test in
            // OpencodeHookAdapter prevents silent drops. The log is
            // cheap (1 line per reasoning part, no I/O cost beyond the
            // existing logNotice) and was the only way to confirm
            // plugin-side vs opencode-side responsibility in this round
            // of investigation. Future Bug-J-like symptoms: grep this
            // log for the missing messageID — if it's absent, the
            // event never reached us; if it's present with textChars=0
            // only, the opencode cleanup() didn't fire updatePart.
            Self.logNotice("→ part arrived type=reasoning session=\(sessionId) messageID=\(messageId) textChars=\(text.count)")
            if !messageId.isEmpty {
                markReasoningMessageId(messageId, sessionId: sessionId)
            }
            return handleReasoningPart(sessionId: sessionId, cwd: cwd, part: part)
        case "tool":
            return handleToolPart(sessionId: sessionId, cwd: cwd, part: part)
        case "file":
            // Opencode sends user-attached images as file parts with a
            // data URI in the `url` field: data:image/png;base64,xxxx
            // Extract the base64 payload and emit an image event.
            let messageId = part["messageID"] as? String  // nil preserves downstream fallback
            let fileUrl = part["url"] as? String ?? ""
            if let parsed = Self.parseImageDataURI(fileUrl) {
                Self.logNotice("→ file part → image session=\(sessionId) messageID=\(messageId ?? "-") mime=\(parsed.mediaType) dataLen=\(parsed.base64Data.count)")
                return [.image(sessionId: sessionId, cwd: cwd, mediaType: parsed.mediaType, base64Data: parsed.base64Data, messageId: messageId)]
            } else {
                Self.logNotice("→ file part skipped (not a valid image data URI) session=\(sessionId) url=\(String(fileUrl.prefix(60)))")
                return []
            }
        case "step-start":
            // Defensive backup: opencode v1.15.13 sometimes fires step-start
            // before any session.status=busy event (e.g. when the model is
            // thinking without a preceding tool). Emitting processingStarted
            // here ensures the notch shows "processing" during thinking.
            Self.logNotice("→ processingStarted (step-start) session=\(sessionId) cwd=\(cwd)")
            return [.processingStarted(sessionId: sessionId, cwd: cwd)]
        default:
            return []
        }
    }

    private static func handlePartDelta(_ props: [String: AnyCodable]) -> [OpencodeSessionEvent] {
        guard let messageId = props["messageID"]?.value as? String else { return [] }
        guard !messageId.isEmpty else { return [] }
        guard let sessionId = props["sessionID"]?.value as? String else { return [] }
        guard let field = props["field"]?.value as? String else { return [] }
        guard field == "text" || field == "reasoning" else { return [] }
        guard let delta = props["delta"]?.value as? String else { return [] }
        guard !delta.isEmpty else { return [] }

        lock.lock()
        // opencode v1.15.13 emits `reasoning-delta` events with `field: "text"`
        // (see opencode/src/session/processor.ts:131-141), so the `field` value
        // alone can't distinguish reasoning content from assistant text. We
        // fall back to the messageID's known type: once `handleReasoningPart`
        // has seen a `message.part.updated(type=reasoning)` for this messageID,
        // any later delta for the same messageID is reasoning, regardless of
        // what `field` says. `knownReasoningMessageIds` is the routing-only
        // set (distinct from `emittedReasoningMessages` which tracks actual
        // emit history for dedup at flush time).
        //
        // EXCEPTION (#73): once the reasoning part is FINALIZED (the final
        // `message.part.updated type=reasoning text=…` event has fired and
        // `handleReasoningPart` has emitted the .assistantThinking event), any
        // further deltas on the same messageID are TEXT deltas for the
        // assistant response that follows the reasoning — not more reasoning.
        // opencode streams reasoning first, then the actual response, both on
        // the same messageID. Without this carve-out, the final assistant text
        // gets misrouted to the reasoning buffer and dropped.
        let isReasoningFinalized = reasoningFinalizedMessageIds.contains(messageId)
        let isKnownReasoning = knownReasoningMessageIds.contains(messageId)
        if !isReasoningFinalized && (isKnownReasoning || field == "reasoning") {
            pendingReasoningByMessage[messageId, default: ""] += delta
            messageSession[messageId] = sessionId
            lock.unlock()
            return []
        }

        // Trailing-echo detection on the delta path (Bug H extension).
        // opencode v1.15.13 sometimes streams the user-prompt echo as a series
        // of `message.part.delta field=text` deltas on a reasoning messageID
        // after reasoning is finalized. These deltas never fire a final
        // `part.updated type=text` event, so `handleTextPart`'s check is
        // bypassed. Detect here by comparing the cumulative buffer against the
        // prompt after each delta. Once the buffer matches, drop everything
        // and clear.
        let isReasoningMessage = knownReasoningMessageIds.contains(messageId)
            || emittedReasoningMessages.contains(messageId)
        var echoCheck: (candidate: String, detector: TrailingEchoDetector)? = nil
        if isReasoningMessage {
            let prompt = consumedUserPromptBySession[sessionId] ?? ""
            let pTrim = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            if !pTrim.isEmpty {
                let currentBuffer = pendingTextByMessage[messageId] ?? ""
                if currentBuffer.count + delta.count <= max(pTrim.count + 10, pTrim.count * 2) {
                    let candidate = currentBuffer + delta
                    let reasoningContent = pendingReasoningByMessage[messageId]
                    echoCheck = (candidate, TrailingEchoDetector(userPrompt: prompt, reasoningContent: reasoningContent))
                }
            }
        }
        lock.unlock()

        if let check = echoCheck, check.detector.isEcho(check.candidate) {
            lock.lock()
            pendingTextByMessage.removeValue(forKey: messageId)
            messageSession[messageId] = sessionId
            lock.unlock()
            Self.logNotice("→ text delta suppressed (trailing-echo accumulated) session=\(sessionId) messageID=\(messageId) bufferChars=\(check.candidate.count)")
            return []
        }

        lock.lock()
        pendingTextByMessage[messageId, default: ""] += delta
        messageSession[messageId] = sessionId
        lock.unlock()
        return []
    }

    // MARK: - Text / Tool Part Handlers

    private static func handleTextPart(sessionId: String, cwd: String, part: [String: Any]) -> [OpencodeSessionEvent] {
        let messageId = part["messageID"] as? String ?? ""
        let text = part["text"] as? String ?? ""
        guard !messageId.isEmpty else { return [] }

        // User text — flush the pending user message we recorded in handleMessageUpdated
        lock.lock()
        let pendingMsgID = latestUserMsgID[sessionId]
        lock.unlock()
        if pendingMsgID == messageId, !text.isEmpty {
            lock.lock()
            latestUserMsgID.removeValue(forKey: sessionId)
            consumedUserMessageIDs.insert(messageId)
            // Capture for echo-detection in handleTextPart's trailing-echo
            // carve-out (#78): the reasoning messageID sometimes receives a
            // trailing text part that echoes the user prompt. Store the
            // canonical prompt text here so the carve-out can compare against
            // it later.
            consumedUserPromptBySession[sessionId] = text
            lock.unlock()
            Self.logNotice("→ userPromptSubmit (text part matched) session=\(sessionId) messageID=\(messageId) textChars=\(text.count)")
            return [.userPromptSubmitted(sessionId: sessionId, cwd: cwd, prompt: text, messageId: messageId)]
        }

        // Skip if this messageID was already consumed as a user message.
        // opencode sometimes emits a second `message.part.updated(type=text)`
        // on the same messageID after the first was already consumed above.
        // Without this guard the text falls through to the assistant buffer.
        //
        // EXCEPTION: opencode v1.15.13 occasionally sends a system-reminder
        // as the first text part (`<system-reminder>Note: The user opened...`)
        // and the real user prompt as the second. If the first was a
        // system-reminder and the second is the actual prompt, update the
        // stored prompt and re-emit.
        lock.lock()
        let wasConsumedUserMsg = consumedUserMessageIDs.contains(messageId)
        let existingPrompt = consumedUserPromptBySession[sessionId] ?? ""
        lock.unlock()
        if wasConsumedUserMsg {
            let isSystemReminder = existingPrompt.hasPrefix("<system-reminder>")
            let isRealPrompt = !text.hasPrefix("<system-reminder>") && text.count > existingPrompt.count
            if isSystemReminder && isRealPrompt {
                lock.lock()
                consumedUserPromptBySession[sessionId] = text
                lock.unlock()
                Self.logNotice("→ userPromptSubmit (corrected) session=\(sessionId) messageID=\(messageId) textChars=\(text.count) priorChars=\(existingPrompt.count)")
                return [.userPromptSubmitted(sessionId: sessionId, cwd: cwd, prompt: text, messageId: messageId)]
            }
            Self.logNotice("→ text part skipped (already consumed as user) session=\(sessionId) messageID=\(messageId)")
            return []
        }

        // Assistant text — seed the buffer with any non-empty initial text.
        // In v1.15.13 the initial part is empty and content arrives via deltas.
        // In v1.15.12 the full text is in this event and deltas don't fire.
        //
        // opencode v1.15.13 sometimes emits a trailing `message.part.updated
        // type=text` on the SAME messageID that already carried a reasoning
        // part. That trailing text typically echoes the user prompt or the
        // reasoning content and must be dropped (Bug H: the 3.1s thinking
        // was re-displayed as a bullet-point assistantText after the turn
        // ended).
        //
        // #78: the previous carve-out used `bufferAlreadySeeded` (delta
        // count) as the trigger, which over-suppressed legitimate post-
        // reasoning text when opencode v1.15.13 emitted final-text without
        // streaming deltas. The second attempt used substring matching
        // (`t == p || p.contains(t) || t.contains(p)`) which was too greedy
        // ("weather" + "The weather is sunny" false-positive). Now uses
        // TrailingEchoDetector: exact match + length-bounded Levenshtein,
        // no substring.
        lock.lock()
        let isReasoningMessage = knownReasoningMessageIds.contains(messageId)
            || emittedReasoningMessages.contains(messageId)
        let prompt = consumedUserPromptBySession[sessionId] ?? ""
        let reasoningContent = pendingReasoningByMessage[messageId]
        lock.unlock()
        let isEcho = isReasoningMessage && TrailingEchoDetector(userPrompt: prompt, reasoningContent: reasoningContent).isEcho(text)
        if isEcho {
            Self.logNotice("→ text part suppressed (trailing-echo) session=\(sessionId) messageID=\(messageId) textChars=\(text.count) promptChars=\(prompt.count)")
            return []
        }
        if !text.isEmpty {
            lock.lock()
            pendingTextByMessage[messageId] = text
            messageSession[messageId] = sessionId
            lock.unlock()
        }
        return []
    }

    private static func handleReasoningPart(sessionId: String, cwd: String, part: [String: Any]) -> [OpencodeSessionEvent] {
        let messageId = part["messageID"] as? String ?? ""
        let text = part["text"] as? String ?? ""
        guard !messageId.isEmpty else { return [] }

        // v1.15.13 reasoning part lifecycle:
        //   message.part.updated(type=reasoning, text="")  → creation
        //   message.part.delta(field=text, delta=…)        → streaming chunks
        //     (opencode emits `field: "text"` for reasoning deltas too; the
        //      only reliable signal is the partType seen at part creation)
        //   message.part.updated(type=reasoning, text=…)   → final full text
        //
        // Tagging the messageID as a "known reasoning" messageID at creation
        // (in `markReasoningMessageId`, called from handlePartUpdated) ensures
        // the deltas route to the reasoning buffer. The dedup set
        // `emittedReasoningMessages` is NOT touched here — see comment in
        // `markReasoningMessageId` for why early tagging there would drop the
        // emit at final-text and at stop-time flush.

        // The final-text event fires AFTER all deltas complete and BEFORE the
        // next step in the turn (tool pending, text part, etc.). Emitting
        // .assistantThinking here lands the thinking block at the right
        // position in chatItems — before any subsequent tool/text rather than
        // clustered at the end via finish=stop. The emittedReasoningMessages
        // dedup set prevents the finish=stop / safety-net flushes from
        // re-emitting the same content.
        guard !text.isEmpty else { return [] }

        lock.lock()
        let alreadyEmitted = emittedReasoningMessages.contains(messageId)
        pendingReasoningByMessage[messageId] = text
        messageSession[messageId] = sessionId
        if !alreadyEmitted {
            emittedReasoningMessages.insert(messageId)
        }
        // The reasoning part is now finalized — any subsequent deltas for the
        // same messageID are TEXT deltas (opencode streams reasoning first,
        // then the assistant text response, both on the same messageID and
        // both with `field=text`). Mark this so `handlePartDelta` routes
        // them to `pendingTextByMessage` instead of `pendingReasoningByMessage`.
        // See #73 in the task list — without this, the final assistant text
        // gets misrouted to the reasoning buffer and is dropped.
        reasoningFinalizedMessageIds.insert(messageId)
        lock.unlock()

        if alreadyEmitted { return [] }
        Self.logNotice("→ assistantThinking (final) session=\(sessionId) messageID=\(messageId) textChars=\(text.count)")
        return [.assistantThinking(sessionId: sessionId, cwd: cwd, text: text, messageId: messageId)]
    }

    /// Tag a messageID as a reasoning message as soon as the reasoning part
    /// is created (empty-text `message.part.updated type=reasoning`). This
    /// must happen BEFORE the first `message.part.delta` for the same
    /// messageID, otherwise the deltas — which all carry `field: "text"` in
    /// opencode v1.15.13 — are routed into `pendingTextByMessage` and
    /// re-emitted as assistantText on `session.idle` (the duplicate-thinking
    /// bug the user reported).
    ///
    /// IMPORTANT: This only adds to `knownReasoningMessageIds` (a routing
    /// signal). It does NOT mark the message as "already emitted" — that
    /// would cause the actual `.assistantThinking` emit at final-text time
    /// and the stop-time safety-net flush to both short-circuit, dropping
    /// the reasoning content entirely.
    private static func markReasoningMessageId(_ messageId: String, sessionId: String) {
        lock.lock()
        defer { lock.unlock() }
        if !knownReasoningMessageIds.contains(messageId) {
            knownReasoningMessageIds.insert(messageId)
            Self.logNotice("→ reasoning messageId tagged early session=\(sessionId) messageID=\(messageId)")
        }
    }

    private static func handleToolPart(sessionId: String, cwd: String, part: [String: Any]) -> [OpencodeSessionEvent] {
        guard let toolName = part["tool"] as? String else { return [] }
        guard let state = part["state"] as? [String: Any] else { return [] }
        guard let status = state["status"] as? String else { return [] }

        let messageId = part["messageID"] as? String

        // The opencode `question` tool IS rendered as a chatItem — the user
        // wants to see the question + answer between the surrounding thinking
        // blocks (matching opencode TUI behavior). The "red box" bug came
        // from the *parent message's assistant text* (the model says "OK let
        // me ask" → tool call → user answers → model continues), not from
        // the tool chatItem itself. The parent text is suppressed in
        // `handleQuestionAsked` via `suppressedTextMessages`, NOT here.
        //
        // Falling through to the standard preTool / postTool path below lets
        // SessionStore create a `ToolCallItem(kind: .askUserQuestion)` for
        // the question with its input (the questions list) and result
        // ("User has answered your questions: …") — the same shape the user
        // sees in opencode TUI's "# Questions" block.

        let callId = part["callID"] as? String
        let input = state["input"] as? [String: Any]
        let inputSummary = Self.buildInputSummary(toolName: toolName, input: input)
        // ToolStateCompleted always carries `output`; ToolStateError carries
        // `error` instead (see opencode/src/session/message-v2.ts:300-333).
        // Read both so we can show the user a result body on real throws.
        let rawOutput = state["output"] as? String
        // Task tools: opencode wraps the subagent's final text in
        //   <task id="…" state="…"><task_result>…</task_result></task>
        // (see the bundled `Yr` formatter in ~/.opencode/bin/opencode and the
        // matching `$t()` unwrapper opencode TUI uses to render it). Without
        // this unwrap, the raw XML leaks into TaskResult.content and the
        // Agent block in ChatView shows `<task id="…" state="completed">`
        // as user-visible text. Apply only to task — other tools' output
        // is opaque and may legitimately contain the literal substring.
        let output: String? = (toolName == "task")
            ? Self.unwrapTaskOutput(rawOutput)
            : rawOutput
        let error = state["error"] as? String

        // Task tool on the parent side — this is the bridge between a parent
        // session and the child subagent session it just spawned. At this
        // point the child is already registered in `subagentToParent` (the
        // child's session.created event arrived a few ms before this preTool;
        // see debug log around the first task invocation). We associate the
        // task call id with the child and emit a subagentStarted event so
        // SessionStore can wire up subagentState tracking. The preTool itself
        // is also emitted (in the return tuple below) so SessionStore's normal
        // task container path still runs — that path is what creates the
        // visible "task" chatItem and populates its description/input.
        if toolName == "task", let callId, status == "running" {
            let (childId, wasNewlyLinked) = associateTaskWithChild(parentId: sessionId, taskToolId: callId)
            Self.logNotice("→ task preTool session=\(sessionId) callID=\(callId) child=\(childId ?? "<none>") newlyLinked=\(wasNewlyLinked)")
            let pre: OpencodeSessionEvent = .preTool(
                sessionId: sessionId, cwd: cwd,
                toolName: toolName, toolUseId: callId, inputSummary: inputSummary,
                input: Self.stringifyInput(input ?? [:]),
                messageId: messageId
            )
            if let _ = childId, wasNewlyLinked {
                return [.subagentStarted(sessionId: sessionId, taskToolId: callId), pre]
            }
            return [pre]
        }
        if toolName == "task", let callId, status == "completed" || status == "error" {
            if let childId = disassociateTaskFromChild(parentId: sessionId, taskToolId: callId) {
                Self.logNotice("→ task postTool session=\(sessionId) callID=\(callId) child=\(childId) → subagentStopped")
                // The task postTool is the parent's signal that the subagent
                // is done. Emit both subagentStopped (so subagentState can
                // stop tracking) and postTool (so the visible task chatItem
                // transitions from running → success and gets the final result).
                // Note: even on the task container we pass output through;
                // SessionStore gates the result-stamping on toolKind != .task
                // so the container is not affected.
                return [
                    .subagentStopped(sessionId: sessionId, taskToolId: callId),
                    .postTool(
                        sessionId: sessionId, cwd: cwd,
                        toolName: toolName, toolUseId: callId, inputSummary: inputSummary,
                        output: output, error: error, messageId: messageId
                    )
                ]
            }
        }

        // Dedup keyed on callID. opencode fires status=running 2-3 times per tool
        // (once at start, then for metadata updates). Without this we create
        // 2-3 chatItems for the same call and one of them ends up "Interrupted"
        // at session.idle because only one postTool ever fires.
        if let callId {
            lock.lock()
            defer { lock.unlock() }
            switch status {
            case "running":
                if runningToolCallIds.contains(callId) {
                    // Second+ running event: opencode may now carry actual input
                    // (first event often has empty input for non-Bash tools).
                    // Emit preTool again so SessionStore can update the chat item.
                    log.notice("→ preTool (input update) session=\(sessionId) callID=\(callId) tool=\(toolName) input=\(inputSummary)")
                } else {
                    runningToolCallIds.insert(callId)
                    log.notice("→ preTool session=\(sessionId) callID=\(callId) tool=\(toolName) input=\(inputSummary)")
                }
            case "completed":
                guard runningToolCallIds.contains(callId) else {
                    log.notice("→ postTool for unknown callID, skipping session=\(sessionId) callID=\(callId)")
                    return []
                }
                runningToolCallIds.remove(callId)
                log.notice("→ postTool session=\(sessionId) callID=\(callId) tool=\(toolName) outputLen=\(output?.count ?? 0) errorLen=\(error?.count ?? 0)")
            case "error":
                guard runningToolCallIds.contains(callId) else {
                    log.notice("→ postTool (error) for unknown callID, skipping session=\(sessionId) callID=\(callId)")
                    return []
                }
                runningToolCallIds.remove(callId)
                log.notice("→ postTool (error) session=\(sessionId) callID=\(callId) tool=\(toolName) errorLen=\(error?.count ?? 0)")
            default:
                return []
            }
        } else {
            Self.logNotice("→ tool part with no callID, passing through session=\(sessionId) tool=\(toolName) status=\(status)")
        }

        switch status {
        case "running":
            let preToolEvent: OpencodeSessionEvent = .preTool(
                sessionId: sessionId, cwd: cwd,
                toolName: toolName, toolUseId: callId, inputSummary: inputSummary,
                input: Self.stringifyInput(input ?? [:]),
                messageId: messageId
            )
            // AskUserQuestion phase — DEFENSIVE FALLBACK (handleQuestionAsked
            // is the primary path; this catches cases where the
            // `question.asked` event is lost or not yet wired up).
            //
            // When opencode invokes its `question` tool, it sends a
            // `message.part.updated` event with `part.type=tool` and
            // `part.tool=question`. We detect that here and emit
            // `.waitingForUserInput` alongside the standard `.preTool` so
            // the list view shows the green flag icon even if the
            // dedicated `question.asked` event didn't reach us.
            //
            // Verified 2026-06-17: in normal operation `question.asked`
            // fires and this path is redundant (idempotent — both set
            // `.waitingForInput` which is a no-op if already in that
            // phase). Kept as defense in depth: if opencode ever changes
            // its event model, or the plugin socket drops the event, the
            // list view still gets the correct phase.
            if toolName.lowercased() == "question" || toolName.lowercased() == "askuserquestion" {
                return [preToolEvent, .waitingForUserInput(sessionId: sessionId, cwd: cwd)]
            }
            return [preToolEvent]
        case "completed":
            return [.postTool(
                sessionId: sessionId, cwd: cwd,
                toolName: toolName, toolUseId: callId, inputSummary: inputSummary,
                output: output, error: error, messageId: messageId
            )]
        case "error":
            return [.postTool(
                sessionId: sessionId, cwd: cwd,
                toolName: toolName, toolUseId: callId, inputSummary: inputSummary,
                output: nil, error: error, messageId: messageId
            )]
        default:
            return []
        }
    }

    /// Link a parent's `task` tool call to the most recently registered child
    /// session awaiting association. Returns the child id and whether the link
    /// was newly created (true) or already existed (false). When false, the
    /// caller should NOT re-emit subagentStarted — the subagent is already
    /// tracked, possibly from a prior preTool with the same callID.
    private static func associateTaskWithChild(parentId: String, taskToolId: String) -> (childId: String?, wasNewlyLinked: Bool) {
        lock.lock()
        defer { lock.unlock() }
        guard let childId = parentAwaitingTask[parentId] else {
            return (nil, false)
        }
        if subagentTaskToolId[childId] == taskToolId {
            return (childId, false)
        }
        subagentTaskToolId[childId] = taskToolId
        parentAwaitingTask.removeValue(forKey: parentId)
        return (childId, true)
    }

    /// Reverse of `associateTaskWithChild`. Returns the child id if it was
    /// still associated with this task, and clears the mapping so subsequent
    /// subagent events for the same child id can no longer be misrouted.
    private static func disassociateTaskFromChild(parentId: String, taskToolId: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        // Walk all known children of this parent. The number of concurrent
        // subagents is tiny (handful at most) so the linear scan is fine.
        for (childId, mappedTask) in subagentTaskToolId {
            guard mappedTask == taskToolId else { continue }
            guard subagentToParent[childId] == parentId else { continue }
            subagentTaskToolId.removeValue(forKey: childId)
            subagentToParent.removeValue(forKey: childId)
            parentAwaitingTask.removeValue(forKey: parentId)
            return childId
        }
        return nil
    }

    // MARK: - Helpers

    private static func buildInputSummary(toolName: String, input: [String: Any]?) -> String {
        guard let input, !input.isEmpty else { return toolName }
        let lower = toolName.lowercased()
        if lower == "bash", let cmd = input["command"] as? String { return cmd }
        if let filePath = input["file_path"] as? String ?? input["filePath"] as? String { return filePath }
        if let name = input["name"] as? String { return name }
        if let pattern = input["pattern"] as? String { return pattern }
        if let prompt = input["prompt"] as? String { return String(prompt.prefix(60)) }
        if let desc = input["description"] as? String { return String(desc.prefix(60)) }
        if let query = input["query"] as? String { return String(query.prefix(60)) }
        if let content = input["content"] as? String { return String(content.prefix(60)) }
        return toolName
    }

    /// Convert opencode's [String: Any] tool input to the [String: String]
    /// format that ChatItemToolCall.input expects (matching Claude's
    /// ToolUseBlock.input). Most values are strings; nested dicts/arrays
    /// are JSON-encoded so downstream consumers (MCPToolFormatter,
    /// EditInputDiffView) can parse them if needed.
    private static func stringifyInput(_ input: [String: Any]) -> [String: String] {
        var result: [String: String] = [:]
        for (key, value) in input {
            switch value {
            case let s as String:
                result[key] = s
            case let b as Bool:
                result[key] = String(b)
            case let n as NSNumber:
                result[key] = n.stringValue
            default:
                // Nested dict/array — JSON encode for downstream parsing
                if let data = try? JSONSerialization.data(withJSONObject: value),
                   let json = String(data: data, encoding: .utf8) {
                    result[key] = json
                } else {
                    result[key] = String(describing: value)
                }
            }
        }
        return result
    }

    /// Regex matching the `<task_result>…</task_result>` (or `<task_error>…
    /// </task_error>`) body that opencode wraps task-tool output in. Mirrors
    /// the `$t()` extractor opencode TUI uses (extracted from
    /// `~/.opencode/bin/opencode` strings: the formatter is `Yr`, the
    /// unwrapper uses `/<task_result>\s*([\s\S]*?)\s*<\/task_result>/`).
    /// Capture group 1 is the tag name; group 2 is the inner content.
    private static let taskOutputWrapRegex: NSRegularExpression = {
        let pattern = #"<(task_result|task_error)>([\s\S]*?)</\1>"#
        // swiftlint:disable:next force_try
        return try! NSRegularExpression(pattern: pattern)
    }()

    /// Strip opencode's `<task id=…><task_result>…</task_result></task>`
    /// wrapping from a task-tool output string. Returns the trimmed inner
    /// text on a successful match; otherwise returns the input unchanged
    /// (covers the no-wrap, malformed, and nil/empty cases, all of which
    /// must round-trip safely so this stays a no-op for non-wrapped
    /// outputs the user may eventually see).
    ///
    /// CALL ONLY for the `task` tool. Other tools' output is opaque and
    /// could legitimately contain the literal substring.
    static func unwrapTaskOutput(_ output: String?) -> String? {
        guard let output, !output.isEmpty else { return output }
        let nsRange = NSRange(output.startIndex..<output.endIndex, in: output)
        guard let match = taskOutputWrapRegex.firstMatch(in: output, options: [], range: nsRange),
              match.numberOfRanges >= 3,
              let innerRange = Range(match.range(at: 2), in: output) else {
            return output
        }
        return String(output[innerRange]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Parsed result of an image data URI.
    struct ImageDataURI {
        let mediaType: String   // e.g. "image/png"
        let base64Data: String
    }

    /// Parse a data URI and extract image data.
    /// Returns nil if:
    /// - Not a valid data URI format
    /// - Content type is not an image (rejects audio, video, etc.)
    /// - Base64 payload is empty or contains invalid characters
    private static func parseImageDataURI(_ uri: String) -> ImageDataURI? {
        guard uri.hasPrefix("data:") else { return nil }
        guard let commaIndex = uri.firstIndex(of: ",") else { return nil }

        // Parse header: "data:image/png;base64"
        let header = String(uri[uri.index(after: uri.startIndex)..<commaIndex])
        let parts = header.split(separator: ";")
        guard let contentType = parts.first, !contentType.isEmpty else { return nil }

        // Only accept image/* content types
        guard contentType.hasPrefix("image/") else { return nil }

        // Verify base64 encoding marker
        guard parts.dropFirst().contains("base64") else { return nil }

        // Extract and validate base64 payload
        let base64Start = uri.index(after: commaIndex)
        let base64 = String(uri[base64Start...])
        guard !base64.isEmpty else { return nil }

        // Basic validation: base64 should only contain valid characters
        // (alphanumeric, +, /, =, and whitespace which we strip)
        let stripped = base64.filter { !$0.isWhitespace }
        let validBase64Chars = CharacterSet.alphanumerics
            .union(CharacterSet(charactersIn: "+/="))
        guard stripped.unicodeScalars.allSatisfy({ validBase64Chars.contains($0) }) else { return nil }
        guard stripped.count % 4 == 0 else { return nil }  // base64 length must be multiple of 4

        return ImageDataURI(mediaType: String(contentType), base64Data: stripped)
    }

    /// Flush one message's text buffer as a single .assistantText event.
    /// Also flushes that message's reasoning first, ensuring thinking appears
    /// above the corresponding text in the chat view.
    /// Used when `message.updated role=assistant finish=stop` arrives.
    private static func flushOneMessageText(messageId: String, sessionId: String, cwd: String, trigger: String) -> [OpencodeSessionEvent] {
        var events: [OpencodeSessionEvent] = []

        // Flush this message's reasoning first so thinking appears above text
        lock.lock()
        let reasoning = pendingReasoningByMessage.removeValue(forKey: messageId) ?? ""
        let reasoningEmitted = emittedReasoningMessages.contains(messageId)
        if !reasoning.isEmpty && !reasoningEmitted {
            emittedReasoningMessages.insert(messageId)
        }
        lock.unlock()
        if !reasoning.isEmpty && !reasoningEmitted {
            Self.logNotice("→ assistantThinking (pre-text) session=\(sessionId) messageID=\(messageId) textChars=\(reasoning.count)")
            events.append(.assistantThinking(sessionId: sessionId, cwd: cwd, text: reasoning, messageId: messageId))
        }

        // Then flush the text
        lock.lock()
        let text = pendingTextByMessage.removeValue(forKey: messageId) ?? ""
        let alreadyEmitted = emittedTextMessages.contains(messageId)
        let isSuppressed = suppressedTextMessages.contains(messageId)
        if !text.isEmpty && !alreadyEmitted && !isSuppressed {
            emittedTextMessages.insert(messageId)
        }
        lock.unlock()

        guard !text.isEmpty, !alreadyEmitted else {
            Self.logNotice("→ assistant nothing-to-flush session=\(sessionId) messageID=\(messageId) trigger=\(trigger) textChars=\(text.count) alreadyEmitted=\(alreadyEmitted)")
            return events
        }
        if isSuppressed {
            // The opencode `question` tool's parent message — its text is the
            // question prompt the user already saw in the TUI. Drop it here
            // and let the chat history skip straight from prior content to
            // the next non-question turn, instead of having the question
            // appear out of order at the end of the next turn.
            Self.logNotice("→ assistant text suppressed (question tool parent) session=\(sessionId) messageID=\(messageId) textChars=\(text.count) trigger=\(trigger)")
            return events
        }
        Self.logNotice("→ assistantText session=\(sessionId) messageID=\(messageId) textChars=\(text.count) trigger=\(trigger)")
        events.append(.assistantText(sessionId: sessionId, cwd: cwd, text: text, messageId: messageId))
        return events
    }

    /// Flush one message's reasoning buffer as a single .assistantThinking event.
    /// Symmetric to flushOneMessageText but for the reasoning pipeline.
    private static func flushOneMessageReasoning(messageId: String, sessionId: String, cwd: String, trigger: String) -> [OpencodeSessionEvent] {
        lock.lock()
        let text = pendingReasoningByMessage.removeValue(forKey: messageId) ?? ""
        let alreadyEmitted = emittedReasoningMessages.contains(messageId)
        if !text.isEmpty && !alreadyEmitted {
            emittedReasoningMessages.insert(messageId)
        }
        lock.unlock()

        guard !text.isEmpty, !alreadyEmitted else {
            return []
        }
        Self.logNotice("→ assistantThinking session=\(sessionId) messageID=\(messageId) textChars=\(text.count) trigger=\(trigger)")
        return [.assistantThinking(sessionId: sessionId, cwd: cwd, text: text, messageId: messageId)]
    }

    /// Flush all pending assistant text and reasoning buffers for a session
    /// (safety net for missed finish=stop events, e.g. on session idle).
    ///
    /// Candidates are sorted by messageID before iteration. opencode
    /// messageIDs embed a creation-time prefix, so lexicographic order is
    /// monotonic and gives a stable, near-chronological ordering for late
    /// arrivals. Without the sort, the safety net would dump messages in
    /// arbitrary Dictionary iteration order, scrambling the chat view.
    private static func flushPendingText(forSession sessionId: String, cwd: String) -> [OpencodeSessionEvent] {
        lock.lock()
        let textKeys = Set(pendingTextByMessage.keys)
        let reasoningKeys = Set(pendingReasoningByMessage.keys)
        let allMessageIds = textKeys.union(reasoningKeys).filter { msgId in
            messageSession[msgId] == sessionId
        }.sorted()
        lock.unlock()

        var events: [OpencodeSessionEvent] = []

        // Interleave reasoning + text per message so thinking appears above its text
        for messageId in allMessageIds {
            lock.lock()
            let reasoning = pendingReasoningByMessage.removeValue(forKey: messageId) ?? ""
            let reasoningEmitted = emittedReasoningMessages.contains(messageId)
            // See #75: if the reasoning for this messageID was already
            // emitted in a *previous* turn, then this messageID is stale
            // (the parent turn ended in a tool call or finish=stop that
            // didn't fire a text-final on this ID). Any leftover text in
            // the buffer is from the previous turn and must not be
            // re-emitted on the current turn's safety net — that would
            // surface as a duplicate assistantText wedged between the new
            // user prompt and the new assistant reply. The reasoning is
            // already in the chat as a thinking block, so dropping the
            // text is the right move. The bookkeeping bookkeeping below
            // marks the messageID as handled so a duplicate flush can't
            // re-evaluate.
            let textStaleFromPriorTurn = reasoningEmitted
            if !reasoning.isEmpty && !reasoningEmitted {
                emittedReasoningMessages.insert(messageId)
            }
            let text = pendingTextByMessage.removeValue(forKey: messageId) ?? ""
            let textEmitted = emittedTextMessages.contains(messageId)
            let textSuppressed = suppressedTextMessages.contains(messageId)
            // Mark the messageID as handled even when we drop it, so a
            // duplicate safety-net pass can't re-emit it. Without this
            // bookkeeping the drop path is silently re-evaluated on every
            // future session.idle and the bookkeeping drifts.
            if !text.isEmpty && !textEmitted {
                emittedTextMessages.insert(messageId)
            }
            messageSession.removeValue(forKey: messageId)
            lock.unlock()

            if !reasoning.isEmpty && !reasoningEmitted {
                Self.logNotice("→ assistantThinking (safety net) session=\(sessionId) messageID=\(messageId) textChars=\(reasoning.count)")
                events.append(.assistantThinking(sessionId: sessionId, cwd: cwd, text: reasoning, messageId: messageId))
            }
            if !text.isEmpty && !textEmitted && !textSuppressed && !textStaleFromPriorTurn {
                Self.logNotice("→ assistantText (safety net) session=\(sessionId) messageID=\(messageId) textChars=\(text.count)")
                events.append(.assistantText(sessionId: sessionId, cwd: cwd, text: text, messageId: messageId))
            } else if !text.isEmpty && (textSuppressed || textStaleFromPriorTurn) {
                let reason = textSuppressed ? "question parent" : "stale from prior turn"
                Self.logNotice("→ assistantText suppressed (safety net, \(reason)) session=\(sessionId) messageID=\(messageId) textChars=\(text.count)")
            }
        }
        return events
    }
}
