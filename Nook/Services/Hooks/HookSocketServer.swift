//
//  HookSocketServer.swift
//  Nook
//
//  Unix domain socket server for real-time hook events
//  Supports request/response for permission decisions
//

import Foundation
import os.log

/// Logger for hook socket server
private let logger = Logger(subsystem: "com.celestial.Nook", category: "Hooks")

/// Mirror to `/tmp/nook-debug.log` when the debug toggle is enabled.
/// Kept inline (not a member) because the server is a class, not a
/// static-singleton adapter; the shim just makes it clear at the
/// call site that this is dual-destination logging.
private func socketLog(_ message: String) {
    logger.notice("\(message)")
    DebugLog.shared.write("[socket] " + message)
}

/// Event received from Claude Code hooks
struct HookEvent: Codable, Sendable {
    let sessionId: String
    let cwd: String
    let event: String
    let status: String
    let pid: Int?
    let tty: String?
    let tool: String?
    let toolInput: [String: AnyCodable]?
    let toolUseId: String?
    let notificationType: String?
    let message: String?

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case cwd, event, status, pid, tty, tool
        case toolInput = "tool_input"
        case toolUseId = "tool_use_id"
        case notificationType = "notification_type"
        case message
    }

    /// Create a copy with updated toolUseId
    init(sessionId: String, cwd: String, event: String, status: String, pid: Int?, tty: String?, tool: String?, toolInput: [String: AnyCodable]?, toolUseId: String?, notificationType: String?, message: String?) {
        self.sessionId = sessionId
        self.cwd = cwd
        self.event = event
        self.status = status
        self.pid = pid
        self.tty = tty
        self.tool = tool
        self.toolInput = toolInput
        self.toolUseId = toolUseId
        self.notificationType = notificationType
        self.message = message
    }

    var sessionPhase: SessionPhase {
        if event == "PreCompact" {
            return .compacting
        }

        switch status {
        case "waiting_for_approval":
            // Note: Full PermissionContext is constructed by SessionStore, not here
            // This is just for quick phase checks
            return .waitingForApproval(PermissionContext(
                toolUseId: toolUseId ?? "",
                toolName: tool ?? "unknown",
                toolInput: toolInput,
                receivedAt: Date()
            ))
        case "waiting_for_input":
            return .waitingForInput
        case "running_tool", "processing", "starting":
            return .processing
        case "compacting":
            return .compacting
        default:
            return .idle
        }
    }

    /// Whether this event expects a response (permission request)
    nonisolated var expectsResponse: Bool {
        event == "PermissionRequest" && status == "waiting_for_approval"
    }
}

/// Response to send back to the hook
struct HookResponse: Codable {
    let decision: String // "allow", "deny", or "ask"
    let reason: String?
}

/// Pending permission request waiting for user decision
struct PendingPermission: Sendable {
    let sessionId: String
    let toolUseId: String
    let clientSocket: Int32
    let event: HookEvent
    let receivedAt: Date
}

/// Callback for hook events
typealias HookEventHandler = @Sendable (HookEvent) -> Void

/// Callback for Codex hook events
typealias CodexHookEventHandler = @Sendable (CodexSessionEvent) -> Void

/// A provider adaptation is delivered intact; the Runtime orders its content
/// and passthrough lifecycle events in one accepted batch.
nonisolated struct HookSocketCallbacks: Sendable {
    let onEvent: HookEventHandler
    var onPermissionFailure: PermissionFailureHandler? = nil
    var onCodexEvent: CodexHookEventHandler? = nil
    var onOpencodeBatch: (@Sendable (OpencodeChatItemAdapter.AdaptResult) -> Void)? = nil
    var onCursorBatch: (@Sendable (CursorChatItemAdapter.Result) -> Void)? = nil
    var onAntigravityBatch: (@Sendable (AntigravityChatItemAdapter.Result) -> Void)? = nil
}

/// Callback for permission response failures (socket died)
typealias PermissionFailureHandler = @Sendable (_ sessionId: String, _ toolUseId: String) -> Void

/// Unix domain socket server that receives events from Claude Code hooks
/// Uses GCD DispatchSource for non-blocking I/O
class HookSocketServer {
    static let shared = HookSocketServer()
    static let socketPath = "/tmp/nook.sock"

    private let boundSocketPath: String
    private var serverSocket: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var eventHandler: HookEventHandler?
    private var codexEventHandler: CodexHookEventHandler?
    private var opencodeBatchHandler: (@Sendable (OpencodeChatItemAdapter.AdaptResult) -> Void)?
    private var cursorBatchHandler: (@Sendable (CursorChatItemAdapter.Result) -> Void)?
    private var antigravityBatchHandler: (@Sendable (AntigravityChatItemAdapter.Result) -> Void)?
    private var permissionFailureHandler: PermissionFailureHandler?
    private let queue = DispatchQueue(label: "com.celestial.Nook.socket", qos: .userInitiated)

    /// Pending permission requests indexed by toolUseId
    private var pendingPermissions: [String: PendingPermission] = [:]
    private let permissionsLock = NSLock()

    /// Cache tool_use_id from PreToolUse to correlate with PermissionRequest
    /// Key: "sessionId:toolName:serializedInput" -> Queue of tool_use_ids (FIFO)
    /// PermissionRequest events don't include tool_use_id, so we cache from PreToolUse
    private var toolUseIdCache: [String: [String]] = [:]
    private let cacheLock = NSLock()

    init(socketPath: String = HookSocketServer.socketPath) {
        self.boundSocketPath = socketPath
    }

    /// Convenience entry for isolated socket tests and Claude-only clients.
    func start(onEvent: @escaping HookEventHandler) {
        start(callbacks: HookSocketCallbacks(onEvent: onEvent))
    }

    func start(callbacks: HookSocketCallbacks) {
        queue.async { [weak self] in
            self?.startServer(callbacks: callbacks)
        }
    }

    private func startServer(callbacks: HookSocketCallbacks) {
        guard serverSocket < 0 else { return }

        eventHandler = callbacks.onEvent
        codexEventHandler = callbacks.onCodexEvent
        opencodeBatchHandler = callbacks.onOpencodeBatch
        cursorBatchHandler = callbacks.onCursorBatch
        antigravityBatchHandler = callbacks.onAntigravityBatch
        permissionFailureHandler = callbacks.onPermissionFailure

        unlink(boundSocketPath)

        serverSocket = socket(AF_UNIX, SOCK_STREAM, 0)
        guard serverSocket >= 0 else {
            logger.error("Failed to create socket: \(errno)")
            return
        }

        let flags = fcntl(serverSocket, F_GETFL)
        _ = fcntl(serverSocket, F_SETFL, flags | O_NONBLOCK)

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        boundSocketPath.withCString { ptr in
            withUnsafeMutablePointer(to: &addr.sun_path) { pathPtr in
                let pathBufferPtr = UnsafeMutableRawPointer(pathPtr)
                    .assumingMemoryBound(to: CChar.self)
                strcpy(pathBufferPtr, ptr)
            }
        }

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                bind(serverSocket, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }

        guard bindResult == 0 else {
            logger.error("Failed to bind socket: \(errno)")
            close(serverSocket)
            serverSocket = -1
            return
        }

        chmod(boundSocketPath, 0o600)

        guard listen(serverSocket, 10) == 0 else {
            logger.error("Failed to listen: \(errno)")
            close(serverSocket)
            serverSocket = -1
            return
        }

        logger.notice("Listening on \(self.boundSocketPath)")

        acceptSource = DispatchSource.makeReadSource(fileDescriptor: serverSocket, queue: queue)
        acceptSource?.setEventHandler { [weak self] in
            self?.acceptConnection()
        }
        // The cancellation handler can run after a restart. It owns this
        // descriptor only, never the next generation's serverSocket.
        let listeningSocket = serverSocket
        acceptSource?.setCancelHandler {
            close(listeningSocket)
        }
        acceptSource?.resume()
    }

    /// Finish pending socket work before teardown, including an asynchronous
    /// start that has not run yet. Called by the app's MainActor runtime owner.
    func stop() {
        queue.sync {
            stopServer()
        }
    }

    /// Queue barrier for isolated socket lifecycle tests; never connects to the
    /// production listener or sends a provider event.
    func isListeningForTesting() async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                continuation.resume(returning: serverSocket >= 0)
            }
        }
    }

    private func stopServer() {
        acceptSource?.cancel()
        acceptSource = nil
        serverSocket = -1
        unlink(boundSocketPath)
        eventHandler = nil
        permissionFailureHandler = nil
        codexEventHandler = nil
        opencodeBatchHandler = nil
        cursorBatchHandler = nil
        antigravityBatchHandler = nil

        permissionsLock.lock()
        for (_, pending) in pendingPermissions {
            close(pending.clientSocket)
        }
        pendingPermissions.removeAll()
        permissionsLock.unlock()

        cacheLock.lock()
        toolUseIdCache.removeAll()
        cacheLock.unlock()
    }

    /// Respond to a pending permission request by toolUseId
    func respondToPermission(toolUseId: String, decision: String, reason: String? = nil) {
        queue.async { [weak self] in
            self?.sendPermissionResponse(toolUseId: toolUseId, decision: decision, reason: reason)
        }
    }

    /// Respond to permission by sessionId (finds the most recent pending for that session)
    func respondToPermissionBySession(sessionId: String, decision: String, reason: String? = nil) {
        queue.async { [weak self] in
            self?.sendPermissionResponseBySession(sessionId: sessionId, decision: decision, reason: reason)
        }
    }

    /// Cancel all pending permissions for a session (when Claude stops waiting)
    func cancelPendingPermissions(sessionId: String) {
        queue.async { [weak self] in
            self?.cleanupPendingPermissions(sessionId: sessionId)
        }
    }

    /// Check if there's a pending permission request for a session
    func hasPendingPermission(sessionId: String) -> Bool {
        permissionsLock.lock()
        defer { permissionsLock.unlock() }
        return pendingPermissions.values.contains { $0.sessionId == sessionId }
    }

    /// Get the pending permission details for a session (if any)
    func getPendingPermission(sessionId: String) -> (toolName: String?, toolId: String?, toolInput: [String: AnyCodable]?)? {
        permissionsLock.lock()
        defer { permissionsLock.unlock() }
        guard let pending = pendingPermissions.values.first(where: { $0.sessionId == sessionId }) else {
            return nil
        }
        return (pending.event.tool, pending.toolUseId, pending.event.toolInput)
    }

    /// Cancel a specific pending permission by toolUseId (when tool completes via terminal approval)
    func cancelPendingPermission(toolUseId: String) {
        queue.async { [weak self] in
            self?.cleanupSpecificPermission(toolUseId: toolUseId)
        }
    }

    private func cleanupSpecificPermission(toolUseId: String) {
        permissionsLock.lock()
        guard let pending = pendingPermissions.removeValue(forKey: toolUseId) else {
            permissionsLock.unlock()
            return
        }
        permissionsLock.unlock()

        logger.debug("Tool completed externally, closing socket for \(pending.sessionId.prefix(8)) tool:\(toolUseId.prefix(12))")
        close(pending.clientSocket)
    }

    private func cleanupPendingPermissions(sessionId: String) {
        permissionsLock.lock()
        let matching = pendingPermissions.filter { $0.value.sessionId == sessionId }
        for (toolUseId, pending) in matching {
            logger.debug("Cleaning up stale permission for \(sessionId.prefix(8)) tool:\(toolUseId.prefix(12))")
            close(pending.clientSocket)
            pendingPermissions.removeValue(forKey: toolUseId)
        }
        permissionsLock.unlock()
    }

    // MARK: - Tool Use ID Cache

    /// Encoder with sorted keys for deterministic cache keys
    private static let sortedEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return encoder
    }()

    /// Generate cache key from event properties
    private func cacheKey(sessionId: String, toolName: String?, toolInput: [String: AnyCodable]?) -> String {
        let inputStr: String
        if let input = toolInput,
           let data = try? Self.sortedEncoder.encode(input),
           let str = String(data: data, encoding: .utf8) {
            inputStr = str
        } else {
            inputStr = "{}"
        }
        return "\(sessionId):\(toolName ?? "unknown"):\(inputStr)"
    }

    /// Cache tool_use_id from PreToolUse event (FIFO queue per key)
    private func cacheToolUseId(event: HookEvent) {
        guard let toolUseId = event.toolUseId else { return }

        let key = cacheKey(sessionId: event.sessionId, toolName: event.tool, toolInput: event.toolInput)

        cacheLock.lock()
        if toolUseIdCache[key] == nil {
            toolUseIdCache[key] = []
        }
        toolUseIdCache[key]?.append(toolUseId)
        cacheLock.unlock()

        logger.debug("Cached tool_use_id for \(event.sessionId.prefix(8)) tool:\(event.tool ?? "?") id:\(toolUseId.prefix(12))")
    }

    /// Pop and return cached tool_use_id for PermissionRequest (FIFO)
    private func popCachedToolUseId(event: HookEvent) -> String? {
        let key = cacheKey(sessionId: event.sessionId, toolName: event.tool, toolInput: event.toolInput)

        cacheLock.lock()
        defer { cacheLock.unlock() }

        guard var queue = toolUseIdCache[key], !queue.isEmpty else {
            return nil
        }

        let toolUseId = queue.removeFirst()

        if queue.isEmpty {
            toolUseIdCache.removeValue(forKey: key)
        } else {
            toolUseIdCache[key] = queue
        }

        logger.debug("Retrieved cached tool_use_id for \(event.sessionId.prefix(8)) tool:\(event.tool ?? "?") id:\(toolUseId.prefix(12))")
        return toolUseId
    }

    /// Clean up cache entries for a session (on session end)
    private func cleanupCache(sessionId: String) {
        cacheLock.lock()
        let keysToRemove = toolUseIdCache.keys.filter { $0.hasPrefix("\(sessionId):") }
        for key in keysToRemove {
            toolUseIdCache.removeValue(forKey: key)
        }
        cacheLock.unlock()

        if !keysToRemove.isEmpty {
            logger.debug("Cleaned up \(keysToRemove.count) cache entries for session \(sessionId.prefix(8))")
        }
    }

    // MARK: - Private

    private func acceptConnection() {
        let clientSocket = accept(serverSocket, nil, nil)
        guard clientSocket >= 0 else { return }

        var nosigpipe: Int32 = 1
        setsockopt(clientSocket, SOL_SOCKET, SO_NOSIGPIPE, &nosigpipe, socklen_t(MemoryLayout<Int32>.size))

        handleClient(clientSocket)
    }

    private func handleClient(_ clientSocket: Int32) {
        let flags = fcntl(clientSocket, F_GETFL)
        _ = fcntl(clientSocket, F_SETFL, flags | O_NONBLOCK)

        var allData = Data()
        var buffer = [UInt8](repeating: 0, count: 131072)
        var pollFd = pollfd(fd: clientSocket, events: Int16(POLLIN), revents: 0)

        let startTime = Date()
        while Date().timeIntervalSince(startTime) < 0.5 {
            let pollResult = poll(&pollFd, 1, 50)

            if pollResult > 0 && (pollFd.revents & Int16(POLLIN)) != 0 {
                let bytesRead = read(clientSocket, &buffer, buffer.count)

                if bytesRead > 0 {
                    allData.append(contentsOf: buffer[0..<bytesRead])
                } else if bytesRead == 0 {
                    break
                } else if errno != EAGAIN && errno != EWOULDBLOCK {
                    break
                }
            } else if pollResult == 0 {
                if !allData.isEmpty {
                    break
                }
            } else {
                break
            }
        }

        guard !allData.isEmpty else {
            close(clientSocket)
            return
        }

        let data = allData

        switch decodeIncomingEvent(from: data) {
        case .claude(let event):
            handleClaudeEvent(event, clientSocket: clientSocket)

        case .codex(let event):
            close(clientSocket)
            socketLog("Received Codex event: \(event.socketLogSummary)")
            codexEventHandler?(event)

        case .unsupportedCodex(let eventName):
            close(clientSocket)
            socketLog("Ignoring unsupported Codex event: \(eventName)")

        case .opencodeChatItems(let batch):
            close(clientSocket)
            for event in batch.passthroughEvents {
                socketLog("Received OpenCode passthrough: \(String(describing: event))")
            }
            opencodeBatchHandler?(batch)

        case .opencodeSkipped(let type):
            close(clientSocket)
            // Normal: opencode envelope decoded, but adapter chose not to surface
            // this event (e.g. session.status busy, step-start, session.diff).
            logger.debug("OpenCode event skipped by adapter: type=\(type)")

        case .cursorChatItems(let batch):
            close(clientSocket)
            for event in batch.passthroughEvents {
                socketLog("Received Cursor passthrough: \(String(describing: event))")
            }
            cursorBatchHandler?(batch)

        case .cursorSkipped(let eventName):
            close(clientSocket)
            logger.debug("Cursor event skipped by adapter: event=\(eventName)")

        case .antigravityChatItems(let batch):
            close(clientSocket)
            for event in batch.passthroughEvents {
                socketLog("Received Antigravity passthrough: \(String(describing: event))")
            }
            antigravityBatchHandler?(batch)

        case .antigravitySkipped(let eventName):
            close(clientSocket)
            logger.debug("Antigravity event skipped by adapter: event=\(eventName)")

        case .unknown:
            let raw = String(data: data, encoding: .utf8) ?? "?"
            socketLog("Failed to parse event (raw=\(raw))")
            close(clientSocket)
        }
    }

    private enum DecodedHookPayload {
        case claude(HookEvent)
        case codex(CodexSessionEvent)
        case opencodeChatItems(OpencodeChatItemAdapter.AdaptResult)
        case opencodeSkipped(type: String)
        case cursorChatItems(CursorChatItemAdapter.Result)
        case cursorSkipped(eventName: String)
        case antigravityChatItems(AntigravityChatItemAdapter.Result)
        case antigravitySkipped(eventName: String)
        case unsupportedCodex(eventName: String)
        case unknown
    }

    private func decodeIncomingEvent(from data: Data) -> DecodedHookPayload {
        // Provider hook payloads can contain fields that are also accepted by
        // Claude's broad HookEvent decoder. Let provider-specific modules
        // classify their own payload shapes before trying the legacy shape.
        if let antigravityEnvelope = try? JSONDecoder().decode(AntigravityHookEnvelope.self, from: data),
           antigravityEnvelope.isAntigravityPayload {
            let result = AntigravityChatItemAdapter.shared.adaptAndConvert(antigravityEnvelope)
            if !result.chatItemUpdates.isEmpty || !result.passthroughEvents.isEmpty {
                return .antigravityChatItems(result)
            }
            return .antigravitySkipped(eventName: antigravityEnvelope.hookEventName)
        }

        if let cursorEnvelope = try? JSONDecoder().decode(CursorHookEnvelope.self, from: data),
           cursorEnvelope.isCursorPayload {
            let result = CursorChatItemAdapter.shared.adaptAndConvert(cursorEnvelope)
            if !result.chatItemUpdates.isEmpty || !result.passthroughEvents.isEmpty {
                return .cursorChatItems(result)
            }
            return .cursorSkipped(eventName: cursorEnvelope.hookEventName)
        }

        if let codexEnvelope = try? JSONDecoder().decode(CodexHookEnvelope.self, from: data),
           codexEnvelope.isCodexPayload {
            guard let codexEvent = CodexHookAdapter.adapt(codexEnvelope) else {
                return .unsupportedCodex(eventName: codexEnvelope.event)
            }
            return .codex(codexEvent)
        }

        if let opencodeEnvelope = try? JSONDecoder().decode(OpencodeHookEnvelope.self, from: data) {
            let result = OpencodeChatItemAdapter.shared.adaptAndConvert(opencodeEnvelope)
            if !result.chatItemUpdates.isEmpty || !result.passthroughEvents.isEmpty {
                return .opencodeChatItems(result)
            }
            // Envelope decoded fine; adapter just had nothing to surface.
            return .opencodeSkipped(type: opencodeEnvelope.type)
        }

        if let claudeEvent = try? JSONDecoder().decode(HookEvent.self, from: data) {
            return .claude(claudeEvent)
        }

        return .unknown
    }

    private func handleClaudeEvent(_ event: HookEvent, clientSocket: Int32) {
        logger.debug("Received: \(event.event) for \(event.sessionId.prefix(8))")

        if event.event == "PreToolUse" {
            cacheToolUseId(event: event)
        }

        if event.event == "SessionEnd" {
            cleanupCache(sessionId: event.sessionId)
        }

        if event.expectsResponse {
            let toolUseId: String
            if let eventToolUseId = event.toolUseId {
                toolUseId = eventToolUseId
            } else if let cachedToolUseId = popCachedToolUseId(event: event) {
                toolUseId = cachedToolUseId
            } else {
                logger.warning("Permission request missing tool_use_id for \(event.sessionId.prefix(8)) - no cache hit")
                close(clientSocket)
                eventHandler?(event)
                return
            }

            logger.debug("Permission request - keeping socket open for \(event.sessionId.prefix(8)) tool:\(toolUseId.prefix(12))")

            let updatedEvent = HookEvent(
                sessionId: event.sessionId,
                cwd: event.cwd,
                event: event.event,
                status: event.status,
                pid: event.pid,
                tty: event.tty,
                tool: event.tool,
                toolInput: event.toolInput,
                toolUseId: toolUseId,  // Use resolved toolUseId
                notificationType: event.notificationType,
                message: event.message
            )

            let pending = PendingPermission(
                sessionId: event.sessionId,
                toolUseId: toolUseId,
                clientSocket: clientSocket,
                event: updatedEvent,
                receivedAt: Date()
            )
            permissionsLock.lock()
            pendingPermissions[toolUseId] = pending
            permissionsLock.unlock()

            eventHandler?(updatedEvent)
            return
        } else {
            close(clientSocket)
        }

        // Permission descriptors belong to this receive queue. Complete the
        // cleanup before another envelope can register a new pending request.
        if event.event == "Stop" {
            cleanupPendingPermissions(sessionId: event.sessionId)
        }
        if event.event == "PostToolUse", let toolUseId = event.toolUseId {
            cleanupSpecificPermission(toolUseId: toolUseId)
        }

        DebugLog.shared.write("[claude-hook] event=\(event.event) status=\(event.status ?? "-") tool=\(event.tool ?? "-") session=\(event.sessionId.prefix(8))")
        eventHandler?(event)
    }

    private func sendPermissionResponse(toolUseId: String, decision: String, reason: String?) {
        permissionsLock.lock()
        guard let pending = pendingPermissions.removeValue(forKey: toolUseId) else {
            permissionsLock.unlock()
            logger.debug("No pending permission for toolUseId: \(toolUseId.prefix(12))")
            return
        }
        permissionsLock.unlock()

        let response = HookResponse(decision: decision, reason: reason)
        guard let data = try? JSONEncoder().encode(response) else {
            close(pending.clientSocket)
            return
        }

        let age = Date().timeIntervalSince(pending.receivedAt)
        logger.notice("Sending response: \(decision) for \(pending.sessionId.prefix(8)) tool:\(toolUseId.prefix(12)) (age: \(String(format: "%.1f", age))s)")

        data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else {
                logger.error("Failed to get data buffer address")
                return
            }
            let result = write(pending.clientSocket, baseAddress, data.count)
            if result < 0 {
                logger.error("Write failed with errno: \(errno)")
            } else {
                logger.debug("Write succeeded: \(result) bytes")
            }
        }

        close(pending.clientSocket)
    }

    private func sendPermissionResponseBySession(sessionId: String, decision: String, reason: String?) {
        permissionsLock.lock()
        let matchingPending = pendingPermissions.values
            .filter { $0.sessionId == sessionId }
            .sorted { $0.receivedAt > $1.receivedAt }
            .first

        guard let pending = matchingPending else {
            permissionsLock.unlock()
            logger.debug("No pending permission for session: \(sessionId.prefix(8))")
            return
        }

        pendingPermissions.removeValue(forKey: pending.toolUseId)
        permissionsLock.unlock()

        let response = HookResponse(decision: decision, reason: reason)
        guard let data = try? JSONEncoder().encode(response) else {
            close(pending.clientSocket)
            permissionFailureHandler?(sessionId, pending.toolUseId)
            return
        }

        let age = Date().timeIntervalSince(pending.receivedAt)
        logger.notice("Sending response: \(decision) for \(sessionId.prefix(8)) tool:\(pending.toolUseId.prefix(12)) (age: \(String(format: "%.1f", age))s)")

        var writeSuccess = false
        data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else {
                logger.error("Failed to get data buffer address")
                return
            }
            let result = write(pending.clientSocket, baseAddress, data.count)
            if result < 0 {
                logger.error("Write failed with errno: \(errno)")
            } else {
                logger.debug("Write succeeded: \(result) bytes")
                writeSuccess = true
            }
        }

        close(pending.clientSocket)

        if !writeSuccess {
            permissionFailureHandler?(sessionId, pending.toolUseId)
        }
    }
}

private extension CodexSessionEvent {
    var socketLogSummary: String {
        switch self {
        case .sessionStart(let sessionId, let cwd, let source):
            return "sessionStart session=\(short(sessionId)) source=\(source ?? "nil") cwd=\(cwd)"
        case .sessionEnd(let sessionId, let cwd, let reason):
            return "sessionEnd session=\(short(sessionId)) reason=\(reason ?? "nil") cwd=\(cwd)"
        case .userPromptSubmit(let sessionId, let cwd, let prompt):
            return "userPromptSubmit session=\(short(sessionId)) promptChars=\(prompt?.count ?? 0) cwd=\(cwd)"
        case .preTool(let sessionId, let cwd, let toolName, let toolUseId, let input, let inputSummary):
            return "preTool session=\(short(sessionId)) tool=\(toolName) toolUseId=\(toolUseId ?? "nil") inputKeys=\(input.keys.sorted().joined(separator: ",")) inputSummaryChars=\(inputSummary?.count ?? 0) cwd=\(cwd)"
        case .postTool(let sessionId, let cwd, let toolName, let toolUseId, let inputSummary, let output, let isError):
            return "postTool session=\(short(sessionId)) tool=\(toolName) toolUseId=\(toolUseId ?? "nil") inputSummaryChars=\(inputSummary?.count ?? 0) outputChars=\(output?.count ?? 0) isError=\(isError) cwd=\(cwd)"
        case .permissionRequest(let sessionId, let cwd, let toolName, let toolUseId, let input, let inputSummary):
            return "permissionRequest session=\(short(sessionId)) tool=\(toolName ?? "nil") toolUseId=\(toolUseId ?? "nil") inputKeys=\(input.keys.sorted().joined(separator: ",")) inputSummaryChars=\(inputSummary?.count ?? 0) cwd=\(cwd)"
        case .compactingStarted(let sessionId, let cwd):
            return "compactingStarted session=\(short(sessionId)) cwd=\(cwd)"
        case .compactingFinished(let sessionId, let cwd):
            return "compactingFinished session=\(short(sessionId)) cwd=\(cwd)"
        case .subagentStarted(let sessionId, let cwd):
            return "subagentStarted session=\(short(sessionId)) cwd=\(cwd)"
        case .subagentStopped(let sessionId, let cwd):
            return "subagentStopped session=\(short(sessionId)) cwd=\(cwd)"
        case .stop(let sessionId, let cwd):
            return "stop session=\(short(sessionId)) cwd=\(cwd)"
        }
    }

    private func short(_ sessionId: String) -> String {
        String(sessionId.prefix(8))
    }
}

// MARK: - AnyCodable for tool_input

/// Type-erasing codable wrapper for heterogeneous values
/// Used to decode JSON objects with mixed value types
struct AnyCodable: Codable, @unchecked Sendable {
    /// The underlying value (nonisolated(unsafe) because Any is not Sendable)
    nonisolated(unsafe) let value: Any

    /// Initialize with any value
    nonisolated init(_ value: Any) {
        self.value = value
    }

    /// Decode from JSON
    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if container.decodeNil() {
            value = NSNull()
        } else if let bool = try? container.decode(Bool.self) {
            value = bool
        } else if let int = try? container.decode(Int.self) {
            value = int
        } else if let double = try? container.decode(Double.self) {
            value = double
        } else if let string = try? container.decode(String.self) {
            value = string
        } else if let array = try? container.decode([AnyCodable].self) {
            value = array.map { $0.value }
        } else if let dict = try? container.decode([String: AnyCodable].self) {
            value = dict.mapValues { $0.value }
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Cannot decode value")
        }
    }

    /// Encode to JSON
    nonisolated func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()

        switch value {
        case is NSNull:
            try container.encodeNil()
        case let bool as Bool:
            try container.encode(bool)
        case let int as Int:
            try container.encode(int)
        case let double as Double:
            try container.encode(double)
        case let string as String:
            try container.encode(string)
        case let array as [Any]:
            try container.encode(array.map { AnyCodable($0) })
        case let dict as [String: Any]:
            try container.encode(dict.mapValues { AnyCodable($0) })
        default:
            throw EncodingError.invalidValue(value, EncodingError.Context(codingPath: [], debugDescription: "Cannot encode value"))
        }
    }
}
