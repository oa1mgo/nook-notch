//
//  ClaudeStatusFileWatcher.swift
//  Nook
//
//  Watches Claude Code's per-process status file
//  (`~/.claude/sessions/{pid}.json`) for real-time `status` field
//  transitions. Used to detect ESC/cancel events that the hook path
//  misses (when the user interrupts before the model starts producing
//  output, no `Stop` hook fires and no JSONL content is written).
//
//  Lifecycle: started alongside JSONLInterruptWatcher (same trigger:
//  UserPromptSubmit phase transition). Fires the same
//  didDetectInterrupt delegate callback on `busy → idle` transitions.
//

import Foundation

/// Watcher for Claude Code's per-pid session status file. Owns its
/// own DispatchSource so changes to `status` are picked up within
/// milliseconds of Claude CLI writing the file.
final class ClaudeStatusFileWatcher {
    private let sessionId: String
    private let pid: Int
    private var source: DispatchSourceFileSystemObject?
    private var fileHandle: FileHandle?
    private var directorySource: DispatchSourceFileSystemObject?
    private var directoryHandle: FileHandle?
    private var lastKnownStatus: String?
    private let queue = DispatchQueue(label: "com.celestial.Nook.statuswatcher", qos: .userInteractive)

    weak var delegate: ClaudeStatusFileWatcherDelegate?

    init(sessionId: String, pid: Int) {
        self.sessionId = sessionId
        self.pid = pid
    }

    deinit {
        stopInternal()
    }

    func start() {
        queue.async { [weak self] in
            self?.startWatching()
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.stopInternal()
        }
    }

    private var filePath: String {
        "\(NSHomeDirectory())/.claude/sessions/\(pid).json"
    }

    private func startWatching() {
        stopInternal()

        // The status file is created by Claude CLI when the session
        // starts. If it doesn't exist yet, watch the parent directory
        // for the file's creation — when it appears, swap to watching
        // the file itself.
        let fm = FileManager.default
        if fm.fileExists(atPath: filePath) {
            attachToFile()
        } else {
            attachToDirectory()
        }
    }

    private func attachToFile() {
        stopInternal()
        guard let handle = FileHandle(forReadingAtPath: filePath) else {
            DebugLog.shared.write("[ClaudeStatusWatcher] cannot open status file pid=\(self.pid)")
            // Fall back to directory watch in case it gets recreated
            attachToDirectory()
            return
        }
        fileHandle = handle

        // Read initial status so we don't fire on startup if already idle
        lastKnownStatus = readStatus(from: handle)

        let fd = handle.fileDescriptor
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .delete, .rename],
            queue: queue
        )
        src.setEventHandler { [weak self] in
            self?.checkStatus()
        }
        src.setCancelHandler { [weak self] in
            try? self?.fileHandle?.close()
            self?.fileHandle = nil
        }
        source = src
        src.resume()
        DebugLog.shared.write("[ClaudeStatusWatcher] start pid=\(self.pid) initial=\(self.lastKnownStatus ?? "nil")")
    }

    private func attachToDirectory() {
        stopInternal()
        let dir = "\(NSHomeDirectory())/.claude/sessions"
        guard let handle = FileHandle(forReadingAtPath: dir) else {
            DebugLog.shared.write("[ClaudeStatusWatcher] cannot open sessions directory")
            return
        }
        directoryHandle = handle
        let fd = handle.fileDescriptor
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend],
            queue: queue
        )
        src.setEventHandler { [weak self] in
            guard let self else { return }
            // Directory changed — check if our file exists now
            if FileManager.default.fileExists(atPath: self.filePath) {
                DebugLog.shared.write("[ClaudeStatusWatcher] status file appeared pid=\(self.pid)")
                attachToFile()
            }
        }
        directorySource = src
        src.resume()
        DebugLog.shared.write("[ClaudeStatusWatcher] watching dir for pid=\(self.pid)")
    }

    private func checkStatus() {
        // Re-open the handle each check because DispatchSource on a
        // regular FileHandle can become stale across multiple events
        // (especially after the file is rewritten atomically by Claude).
        guard let handle = FileHandle(forReadingAtPath: filePath) else {
            // File gone (session ended) — treat as interrupt
            handleTransition(toStatus: nil)
            return
        }
        let newStatus = readStatus(from: handle)
        try? handle.close()
        handleTransition(toStatus: newStatus)
    }

    private func readStatus(from handle: FileHandle) -> String? {
        do {
            _ = try handle.seek(toOffset: 0)
            guard let data = try? handle.readToEnd(),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }
            return json["status"] as? String
        } catch {
            return nil
        }
    }

    private func handleTransition(toStatus newStatus: String?) {
        let oldStatus = lastKnownStatus
        lastKnownStatus = newStatus

        // Only fire on busy → idle transition (the ESC signal). Other
        // transitions (idle → busy for next turn, etc.) are normal
        // lifecycle events we don't need to react to here.
        guard oldStatus == "busy", newStatus == "idle" else { return }
        DebugLog.shared.write("[ClaudeStatusWatcher] BUSY→IDLE pid=\(self.pid) → interrupt")
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.didDetectInterrupt(sessionId: self.sessionId)
        }
    }

    private func stopInternal() {
        source?.cancel()
        source = nil
        directorySource?.cancel()
        directorySource = nil
        try? fileHandle?.close()
        fileHandle = nil
        try? directoryHandle?.close()
        directoryHandle = nil
    }
}

protocol ClaudeStatusFileWatcherDelegate: AnyObject {
    func didDetectInterrupt(sessionId: String)
}