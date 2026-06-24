//
//  JSONLInterruptWatcher.swift
//  Nook
//
//  Watches JSONL files for interrupt patterns in real-time
//  Uses file system events to detect interrupts faster than hook polling
//

import Foundation
import os.log

/// Logger for interrupt watcher
private let logger = Logger(subsystem: "com.celestial.Nook", category: "Interrupt")

protocol JSONLInterruptWatcherDelegate: AnyObject {
    func didDetectInterrupt(sessionId: String)
}

/// Watches a session's JSONL file for interrupt patterns in real-time
/// Uses DispatchSource for immediate detection when new lines are written
class JSONLInterruptWatcher {
    private var fileHandle: FileHandle?
    private var source: DispatchSourceFileSystemObject?
    private var lastOffset: UInt64 = 0
    private let sessionId: String
    private let filePath: String
    private let queue = DispatchQueue(label: "com.celestial.Nook.interruptwatcher", qos: .userInteractive)

    weak var delegate: JSONLInterruptWatcherDelegate?

    /// Patterns that indicate an interrupt occurred
    /// We check for is_error:true combined with interrupt content
    private static let interruptContentPatterns = [
        "Interrupted by user",
        "interrupted by user",
        "user doesn't want to proceed",
        "[Request interrupted by user"
    ]

    init(sessionId: String, cwd: String) {
        self.sessionId = sessionId
        let projectDir = cwd.replacingOccurrences(of: "/", with: "-")
                            .replacingOccurrences(of: ".", with: "-")
        self.filePath = ClaudePaths.projectsDir.path + "/" + projectDir + "/" + sessionId + ".jsonl"
    }

    /// Start watching the JSONL file for interrupts
    func start() {
        queue.async { [weak self] in
            self?.startWatching()
        }
    }

    private func startWatching() {
        stopInternal()

        guard FileManager.default.fileExists(atPath: filePath),
              let handle = FileHandle(forReadingAtPath: filePath) else {
            logger.warning("Failed to open file: \(self.filePath, privacy: .public)")
            return
        }

        fileHandle = handle

        do {
            lastOffset = try handle.seekToEnd()
        } catch {
            logger.error("Failed to seek to end: \(error.localizedDescription, privacy: .public)")
            return
        }

        let fd = handle.fileDescriptor
        let newSource = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend],
            queue: queue
        )

        newSource.setEventHandler { [weak self] in
            self?.checkForInterrupt()
        }

        newSource.setCancelHandler { [weak self] in
            try? self?.fileHandle?.close()
            self?.fileHandle = nil
        }

        source = newSource
        newSource.resume()

        logger.debug("Started watching: \(self.sessionId.prefix(8), privacy: .public)...")
    }

    private func checkForInterrupt() {
        guard let handle = fileHandle else { return }

        let currentSize: UInt64
        do {
            currentSize = try handle.seekToEnd()
        } catch {
            return
        }

        guard currentSize > lastOffset else { return }

        do {
            try handle.seek(toOffset: lastOffset)
        } catch {
            return
        }

        guard let newData = try? handle.readToEnd(),
              let newContent = String(data: newData, encoding: .utf8) else {
            return
        }

        lastOffset = currentSize

        let lines = newContent.components(separatedBy: "\n")
        for line in lines where !line.isEmpty {
            if isInterruptLine(line) {
                logger.info("Detected interrupt in session: \(self.sessionId.prefix(8), privacy: .public)")
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    self.delegate?.didDetectInterrupt(sessionId: self.sessionId)
                }
                return
            }
        }
    }

    private func isInterruptLine(_ line: String) -> Bool {
        if line.contains("\"type\":\"user\"") {
            if line.contains("[Request interrupted by user]") ||
               line.contains("[Request interrupted by user for tool use]") {
                return true
            }
        }

        if line.contains("\"tool_result\"") && line.contains("\"is_error\":true") {
            for pattern in Self.interruptContentPatterns {
                if line.contains(pattern) {
                    return true
                }
            }
        }

        if line.contains("\"interrupted\":true") {
            return true
        }

        return false
    }

    /// Stop watching
    func stop() {
        queue.async { [weak self] in
            self?.stopInternal()
        }
    }

    private func stopInternal() {
        if source != nil {
            logger.debug("Stopped watching: \(self.sessionId.prefix(8), privacy: .public)...")
        }
        source?.cancel()
        source = nil
        // fileHandle closed by cancel handler
    }

    deinit {
        source?.cancel()
    }
}

// MARK: - Interrupt Watcher Manager

/// Manages interrupt watchers for all active sessions
@MainActor
class InterruptWatcherManager {
    static let shared = InterruptWatcherManager()

    private var watchers: [String: JSONLInterruptWatcher] = [:]
    private var statusWatchers: [String: ClaudeStatusFileWatcher] = [:]
    weak var delegate: JSONLInterruptWatcherDelegate?

    private init() {}

    func startWatching(sessionId: String, cwd: String, pid: Int? = nil) {
        if watchers[sessionId] == nil {
            let watcher = JSONLInterruptWatcher(sessionId: sessionId, cwd: cwd)
            watcher.delegate = delegate
            watcher.start()
            watchers[sessionId] = watcher
        }

        // Also start the status-file watcher when we have a pid. This
        // catches the ESC-before-output case (no JSONL content, no Stop
        // hook event) by detecting Claude CLI's `status: busy → idle`
        // transition in `~/.claude/sessions/{pid}.json` directly.
        if let pid, statusWatchers[sessionId] == nil {
            let statusWatcher = ClaudeStatusFileWatcher(sessionId: sessionId, pid: pid)
            statusWatcher.delegate = delegate as? ClaudeStatusFileWatcherDelegate
            statusWatcher.start()
            statusWatchers[sessionId] = statusWatcher
        }
    }

    /// Stop watching a specific session
    func stopWatching(sessionId: String) {
        watchers[sessionId]?.stop()
        watchers.removeValue(forKey: sessionId)
        statusWatchers[sessionId]?.stop()
        statusWatchers.removeValue(forKey: sessionId)
    }

    /// Stop all watchers
    func stopAll() {
        for (_, watcher) in watchers {
            watcher.stop()
        }
        for (_, watcher) in statusWatchers {
            watcher.stop()
        }
        watchers.removeAll()
        statusWatchers.removeAll()
    }

    /// Check if we're watching a session
    func isWatching(sessionId: String) -> Bool {
        watchers[sessionId] != nil
    }
}
