//
//  DebugLog.swift
//  Nook
//
//  Optional on-disk debug log that mirrors internal log output to
//  `/tmp/nook-debug.log`. Designed for diagnosing agent-hook and
//  socket-pipeline issues in the field: enable the toggle in
//  Agent settings, restart the app, reproduce the bug, then read
//  the single rolling log file.
//
//  Characteristics:
//   * File is recreated from scratch on every app launch, so it
//     always reflects the current run only.
//   * Capped at 10 MB. When the cap is exceeded the file is
//     truncated and a `--- log rotated ---` marker is written so
//     the operator can tell the rollover happened.
//   * All writes go through a serial queue, so the socket reader
//     and the main thread can call into it concurrently without
//     any extra synchronization at the call site.
//

import Foundation
import os.log

/// Filesystem-backed debug log mirror. Only active when
/// `AppSettings.debugLogEnabled` is true; otherwise all writes are
/// dropped before touching the disk and the file handle stays closed.
final class DebugLog {
    static let shared = DebugLog()

    /// Public, fixed location so it can be referenced in bug reports
    /// and from external scripts (e.g. `tail -F /tmp/nook-debug.log`).
    static let fileURL: URL = URL(fileURLWithPath: "/tmp/nook-debug.log")

    /// 10 MB cap, as requested. The check happens after every line
    /// is written, so the file may briefly exceed 10 MB by at most
    /// one line (always <4 KB).
    private let maxBytes: Int = 10 * 1024 * 1024

    private let queue = DispatchQueue(label: "com.celestial.Nook.debuglog", qos: .utility)
    private let oslog = Logger(subsystem: "com.celestial.Nook", category: "DebugLog")
    private var handle: FileHandle?
    private var isEnabled = false
    private var isStarting = false

    private init() {}

    // MARK: - Lifecycle

    /// Enable on-disk capture. Recreates the file from scratch so
    /// each app launch starts with an empty log. Safe to call
    /// multiple times; subsequent calls become a no-op.
    func enable() {
        queue.async { [weak self] in
            guard let self else { return }
            guard !self.isEnabled, !self.isStarting else { return }
            self.isStarting = true
            defer { self.isStarting = false }

            // Always start with a clean file: every launch gets a
            // fresh log so the operator (or the assistant) can
            // always grep across one coherent run.
            do {
                if FileManager.default.fileExists(atPath: Self.fileURL.path) {
                    try FileManager.default.removeItem(at: Self.fileURL)
                }
                FileManager.default.createFile(atPath: Self.fileURL.path, contents: nil)
                self.handle = try FileHandle(forWritingTo: Self.fileURL)
                self.isEnabled = true
                self.writeHeader()
            } catch {
                self.oslog.error("Failed to open debug log: \(error.localizedDescription, privacy: .public)")
                self.handle = nil
                self.isEnabled = false
            }
        }
    }

    /// Stop capture and close the file handle. Idempotent.
    func disable() {
        queue.async { [weak self] in
            guard let self else { return }
            self.isEnabled = false
            try? self.handle?.close()
            self.handle = nil
        }
    }

    // MARK: - Write API

    /// Append a single line to the log. The line is prefixed with
    /// an ISO-8601 timestamp; newlines in `message` are escaped so
    /// every call produces exactly one line and `grep`/filtering
    /// keep working. Safe to call from any thread.
    func write(_ message: String) {
        queue.async { [weak self] in
            guard let self, self.isEnabled, let handle = self.handle else { return }
            let line = self.formatLine(message)
            guard let data = line.data(using: .utf8) else { return }
            do {
                try handle.write(contentsOf: data)
                self.maybeRotate()
            } catch {
                self.oslog.error("Debug log write failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Convenience helper for the common "log + mirror" pattern at
    /// the call site. Logs through `os.Logger` (visible in
    /// Console.app) and, when enabled, also appends to the file.
    /// Use this anywhere a `log.notice(...)` would have been called
    /// but you also want the on-disk mirror.
    func log(_ logger: Logger, level: OSLogType = .default, _ message: String) {
        switch level {
        case .debug: logger.debug("\(message, privacy: .public)")
        case .info: logger.info("\(message, privacy: .public)")
        case .error: logger.error("\(message, privacy: .public)")
        case .fault: logger.fault("\(message, privacy: .public)")
        default: logger.log(level: level, "\(message, privacy: .public)")
        }
        write(message)
    }

    // MARK: - Internals

    private func formatLine(_ message: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let ts = formatter.string(from: Date())
        let escaped = message.replacingOccurrences(of: "\n", with: "\\n")
        return "[\(ts)] \(escaped)\n"
    }

    private func writeHeader() {
        let processInfo = Foundation.ProcessInfo.processInfo
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] ?? "unknown"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] ?? "unknown"
        let header = """
        --- nook-debug.log ---
        pid: \(processInfo.processIdentifier)
        app version: \(appVersion)
        build: \(build)
        --- session start ---

        """
        if let data = header.data(using: .utf8) {
            try? handle?.write(contentsOf: data)
        }
    }

    /// Truncate the file and reopen it when it exceeds the cap.
    /// Runs on the serial queue, so there is no race with
    /// concurrent `write` calls.
    private func maybeRotate() {
        guard let current = handle else { return }
        let size = (try? FileManager.default.attributesOfItem(atPath: Self.fileURL.path)[.size] as? Int) ?? 0
        guard size > maxBytes else { return }

        try? current.close()
        handle = nil
        do {
            try FileManager.default.removeItem(at: Self.fileURL)
            FileManager.default.createFile(atPath: Self.fileURL.path, contents: nil)
            let newHandle = try FileHandle(forWritingTo: Self.fileURL)
            handle = newHandle
            if let data = "--- log rotated ---\n".data(using: .utf8) {
                try newHandle.write(contentsOf: data)
            }
        } catch {
            oslog.error("Debug log rotation failed: \(error.localizedDescription, privacy: .public)")
            isEnabled = false
        }
    }
}
