//
//  CodexHookInstaller.swift
//  Nook
//
//  Installs Codex hooks that forward session lifecycle events
//  into Nook via the shared Unix socket.
//

import Foundation

struct CodexHookInstaller {
    private static let codexDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
    private static let hooksDir = codexDir.appendingPathComponent("hooks")
    private static let configFile = codexDir.appendingPathComponent("config.toml")
    private static let hooksFile = codexDir.appendingPathComponent("hooks.json")
    private static let bridgeScript = hooksDir.appendingPathComponent("nook-codex-hook.py")

    static func installIfNeeded() {
        try? FileManager.default.createDirectory(at: hooksDir, withIntermediateDirectories: true)
        installBridgeScript()
        enableHooksFeature()
        installHooksConfiguration()
    }

    private static func installBridgeScript() {
        let script = """
        #!/usr/bin/env python3
        import json
        import os
        import socket
        import sys

        SOCKET_PATH = "/tmp/nook.sock"

        def main():
            payload = sys.stdin.buffer.read()
            if not payload.strip():
                return

            try:
                event = json.loads(payload.decode("utf-8"))
                event.setdefault("origin", "codex")
                event.setdefault("cwd", os.getcwd())
                payload = (json.dumps(event, separators=(",", ":")) + "\\n").encode("utf-8")
            except Exception:
                pass

            try:
                sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                sock.settimeout(2)
                sock.connect(SOCKET_PATH)
                sock.sendall(payload)
                sock.close()
            except OSError:
                pass

        if __name__ == "__main__":
            main()
        """

        try? script.write(to: bridgeScript, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: bridgeScript.path
        )
    }

    private static func enableHooksFeature() {
        let existing = (try? String(contentsOf: configFile, encoding: .utf8)) ?? ""

        if rangeOfCanonicalHooksFlag(true, in: existing) != nil {
            return
        }

        let updated: String
        if let disabledFlagRange = rangeOfCanonicalHooksFlag(false, in: existing) {
            let disabledFlag = String(existing[disabledFlagRange])
            let enabledFlag = disabledFlag.replacingOccurrences(
                of: #"(?m)^(\s*)hooks\s*=\s*false(\s*(?:#.*)?)$"#,
                with: "$1hooks = true$2",
                options: .regularExpression
            )
            updated = existing.replacingCharacters(in: disabledFlagRange, with: enabledFlag)
        } else if let featureRange = existing.range(
            of: #"(?m)^\s*\[features\]\s*$"#,
            options: .regularExpression
        ) {
            let tail = existing[featureRange.upperBound...]
            if let nextSectionRange = tail.range(
                of: #"(?m)^\s*\[[^\n]+\]\s*$"#,
                options: .regularExpression
            ) {
                let insertionPoint = nextSectionRange.lowerBound
                let prefix = String(existing[..<insertionPoint])
                let separator = prefix.hasSuffix("\n") ? "" : "\n"
                updated = prefix + separator + "hooks = true\n" + String(existing[insertionPoint...])
            } else if existing.hasSuffix("\n") {
                updated = existing + "hooks = true\n"
            } else {
                updated = existing + "\nhooks = true\n"
            }
        } else if existing.isEmpty {
            updated = "[features]\nhooks = true\n"
        } else {
            let suffix = existing.hasSuffix("\n") ? "" : "\n"
            updated = existing + suffix + "\n[features]\nhooks = true\n"
        }

        try? updated.write(to: configFile, atomically: true, encoding: .utf8)
    }

    private static func rangeOfCanonicalHooksFlag(_ value: Bool, in text: String) -> Range<String.Index>? {
        guard let featuresSectionRange = featuresSectionBodyRange(in: text) else { return nil }
        let boolValue = value ? "true" : "false"
        let pattern = #"(?m)^\s*hooks\s*=\s*"# + boolValue + #"\s*(?:#.*)?$"#
        return text[featuresSectionRange].range(of: pattern, options: .regularExpression)
    }

    private static func featuresSectionBodyRange(in text: String) -> Range<String.Index>? {
        guard let featureRange = text.range(
            of: #"(?m)^\s*\[features\]\s*$"#,
            options: .regularExpression
        ) else {
            return nil
        }

        let bodyStart = featureRange.upperBound
        let tail = text[bodyStart...]
        let bodyEnd = tail.range(
            of: #"(?m)^\s*\[[^\n]+\]\s*$"#,
            options: .regularExpression
        )?.lowerBound ?? text.endIndex
        return bodyStart..<bodyEnd
    }

    private static func installHooksConfiguration() {
        var json: [String: Any] = [:]
        if let data = try? Data(contentsOf: hooksFile),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            json = existing
        }

        var hooks = json["hooks"] as? [String: Any] ?? [:]
        for (event, value) in Array(hooks) {
            guard var entries = value as? [[String: Any]] else { continue }
            entries = entries.compactMap { removingNookHooks(from: $0) }
            if entries.isEmpty {
                hooks.removeValue(forKey: event)
            } else {
                hooks[event] = entries
            }
        }

        let command = "\(detectPythonExecutable()) \(shellQuote(bridgeScript.path))"
        let handler: [String: Any] = ["type": "command", "command": command]
        let allEvents: [(String, [[String: Any]])] = [
            ("SessionStart", [["matcher": "startup|resume|clear|compact", "hooks": [handler]]]),
            ("UserPromptSubmit", [["hooks": [handler]]]),
            ("PreToolUse", [["hooks": [handler]]]),
            ("PermissionRequest", [["hooks": [handler]]]),
            ("PostToolUse", [["hooks": [handler]]]),
            ("PreCompact", [["hooks": [handler]]]),
            ("PostCompact", [["hooks": [handler]]]),
            ("SubagentStart", [["hooks": [handler]]]),
            ("SubagentStop", [["hooks": [handler]]]),
            ("Stop", [["hooks": [handler]]]),
        ]

        for (event, config) in allEvents {
            let existingEntries = hooks[event] as? [[String: Any]] ?? []
            let cleanedEntries = existingEntries.compactMap { removingNookHooks(from: $0) }
            hooks[event] = cleanedEntries + config
        }

        json["hooks"] = hooks

        if let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: hooksFile)
        }
    }

    /// Check if Codex hooks are currently installed
    static func isInstalled() -> Bool {
        guard FileManager.default.fileExists(atPath: bridgeScript.path) else { return false }

        guard let data = try? Data(contentsOf: hooksFile),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = json["hooks"] as? [String: Any] else {
            return false
        }

        for (_, value) in hooks {
            if let entries = value as? [[String: Any]] {
                for entry in entries {
                    if let entryHooks = entry["hooks"] as? [[String: Any]] {
                        for hook in entryHooks {
                            if let cmd = hook["command"] as? String,
                               cmd.contains("nook-codex-hook.py") {
                                return true
                            }
                        }
                    }
                }
            }
        }
        return false
    }

    /// Uninstall Codex hooks: remove bridge script, disable feature flag, clean hooks.json
    static func uninstall() {
        try? FileManager.default.removeItem(at: bridgeScript)

        guard let data = try? Data(contentsOf: hooksFile),
              var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var hooks = json["hooks"] as? [String: Any] else {
            return
        }

        for (event, value) in hooks {
            if var entries = value as? [[String: Any]] {
                entries = entries.compactMap { removingNookHooks(from: $0) }
                if entries.isEmpty {
                    hooks.removeValue(forKey: event)
                } else {
                    hooks[event] = entries
                }
            }
        }

        if hooks.isEmpty {
            json.removeValue(forKey: "hooks")
        } else {
            json["hooks"] = hooks
        }

        if let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: hooksFile)
        }
    }

    private nonisolated static func removingNookHooks(from entry: [String: Any]) -> [String: Any]? {
        guard var entryHooks = entry["hooks"] as? [[String: Any]] else {
            return entry
        }

        entryHooks.removeAll(where: isNookHook)
        guard !entryHooks.isEmpty else { return nil }

        var updatedEntry = entry
        updatedEntry["hooks"] = entryHooks
        return updatedEntry
    }

    private nonisolated static func isNookHook(_ hook: [String: Any]) -> Bool {
        let command = hook["command"] as? String ?? ""
        return command.contains("nook-codex-hook.py")
    }

    private static func detectPythonExecutable() -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = ["python3"]

        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus == 0,
               let path = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !path.isEmpty {
                return path
            }
        } catch {}

        return "python3"
    }

    private static func shellQuote(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
