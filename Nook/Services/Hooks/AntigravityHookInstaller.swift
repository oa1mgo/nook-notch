//
//  AntigravityHookInstaller.swift
//  Nook
//
//  Installs Antigravity global lifecycle hooks in ~/.gemini/config/hooks.json
//  that forward agent lifecycle events into Nook via the shared Unix socket.
//

import Foundation

struct AntigravityHookInstaller {
    private static let hookGroupKey = "nook"
    private static let bridgeScriptName = "nook-antigravity-hook.py"

    static func installIfNeeded(configDir: URL = AgentPathsResolver.directory(for: .antigravity)) {
        guard FileManager.default.fileExists(atPath: configDir.path) else { return }
        let hooksDir = configDir.appendingPathComponent("hooks")
        let bridgeScript = hooksDir.appendingPathComponent(bridgeScriptName)
        let hooksFile = configDir.appendingPathComponent("hooks.json")

        try? FileManager.default.createDirectory(at: hooksDir, withIntermediateDirectories: true)
        installBridgeScript(at: bridgeScript)
        installHooksConfiguration(hooksFile: hooksFile, bridgeScript: bridgeScript)
    }

    static func uninstall(configDir: URL = AgentPathsResolver.directory(for: .antigravity)) {
        let hooksDir = configDir.appendingPathComponent("hooks")
        let bridgeScript = hooksDir.appendingPathComponent(bridgeScriptName)
        let hooksFile = configDir.appendingPathComponent("hooks.json")

        try? FileManager.default.removeItem(at: bridgeScript)

        guard let data = try? Data(contentsOf: hooksFile),
              var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }

        removeNookEntries(from: &json)
        writeHooksJSON(json, to: hooksFile)
    }

    static func isInstalled(configDir: URL = AgentPathsResolver.directory(for: .antigravity)) -> Bool {
        let hooksDir = configDir.appendingPathComponent("hooks")
        let bridgeScript = hooksDir.appendingPathComponent(bridgeScriptName)
        let hooksFile = configDir.appendingPathComponent("hooks.json")

        guard FileManager.default.fileExists(atPath: bridgeScript.path),
              let data = try? Data(contentsOf: hooksFile),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }

        for (_, value) in json {
            guard let group = value as? [String: Any] else { continue }
            if let enabled = group["enabled"] as? Bool, !enabled {
                continue
            }
            if groupContainsNookHook(group) {
                return true
            }
        }

        return false
    }

    private static func installBridgeScript(at bridgeScript: URL) {
        let script = """
        #!/usr/bin/env python3
        import json
        import os
        import socket
        import sys

        SOCKET_PATH = "/tmp/nook.sock"

        def forward(payload):
            try:
                sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                sock.settimeout(2)
                sock.connect(SOCKET_PATH)
                sock.sendall(payload)
                sock.close()
            except OSError:
                pass

        def main():
            raw = sys.stdin.buffer.read()

            if raw.strip():
                payload = raw
                try:
                    event = json.loads(raw.decode("utf-8"))
                    if isinstance(event, dict):
                        event["origin"] = "antigravity"
                        payload = (json.dumps(event, separators=(",", ":")) + "\\n").encode("utf-8")
                except Exception:
                    pass

                forward(payload)

            # Pass-through response: never block tool execution or force-continue Stop.
            sys.stdout.write("{}")
            sys.stdout.flush()

        if __name__ == "__main__":
            main()
        """

        try? script.write(to: bridgeScript, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: bridgeScript.path
        )
    }

    /// Antigravity `hooks.json` maps top-level named hook groups to event arrays:
    /// - Flat events (`SessionStart`, `PreInvocation`, `PostInvocation`, `Stop`): `[handler]`
    /// - Grouped tool events (`PostToolUse`): `[{"matcher": "*", "hooks": [handler]}]`
    ///
    /// `PreToolUse` is intentionally omitted so Nook never overrides or interferes
    /// with Antigravity's built-in tool permission prompts.
    private static func installHooksConfiguration(hooksFile: URL, bridgeScript: URL) {
        var json: [String: Any] = [:]
        if let data = try? Data(contentsOf: hooksFile),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            json = existing
        }

        removeNookEntries(from: &json)

        let command = "\(detectPythonExecutable()) \(shellQuote(bridgeScript.path))"
        let handler: [String: Any] = [
            "type": "command",
            "command": command,
            "timeout": 5
        ]
        let toolGroup: [String: Any] = [
            "matcher": "*",
            "hooks": [handler]
        ]

        let nookGroup: [String: Any] = [
            "enabled": true,
            "SessionStart": [handler],
            "PreInvocation": [handler],
            "PostInvocation": [handler],
            "PostToolUse": [toolGroup],
            "Stop": [handler]
        ]

        json[hookGroupKey] = nookGroup
        writeHooksJSON(json, to: hooksFile)
    }

    private static func removeNookEntries(from json: inout [String: Any]) {
        json.removeValue(forKey: hookGroupKey)

        for (key, value) in json {
            guard var group = value as? [String: Any] else { continue }
            var modified = false

            for (eventName, eventValue) in group {
                guard let entries = eventValue as? [[String: Any]] else { continue }
                var cleaned: [[String: Any]] = []
                for entry in entries {
                    if isNookHook(entry) {
                        modified = true
                        continue
                    }
                    if var nestedHooks = entry["hooks"] as? [[String: Any]] {
                        let beforeCount = nestedHooks.count
                        nestedHooks.removeAll(where: isNookHook)
                        if nestedHooks.count != beforeCount {
                            modified = true
                            if nestedHooks.isEmpty {
                                continue
                            }
                            var updatedEntry = entry
                            updatedEntry["hooks"] = nestedHooks
                            cleaned.append(updatedEntry)
                            continue
                        }
                    }
                    cleaned.append(entry)
                }

                if cleaned.isEmpty {
                    group.removeValue(forKey: eventName)
                } else {
                    group[eventName] = cleaned
                }
            }

            if modified {
                let remainingEvents = group.keys.filter { $0 != "enabled" }
                if remainingEvents.isEmpty {
                    json.removeValue(forKey: key)
                } else {
                    json[key] = group
                }
            }
        }
    }

    private static func groupContainsNookHook(_ group: [String: Any]) -> Bool {
        for (_, value) in group {
            guard let entries = value as? [[String: Any]] else { continue }
            for entry in entries {
                if isNookHook(entry) {
                    return true
                }
                if let nestedHooks = entry["hooks"] as? [[String: Any]],
                   nestedHooks.contains(where: isNookHook) {
                    return true
                }
            }
        }
        return false
    }

    private static func writeHooksJSON(_ json: [String: Any], to hooksFile: URL) {
        guard JSONSerialization.isValidJSONObject(json),
              let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) else {
            return
        }
        try? data.write(to: hooksFile, options: .atomic)
    }

    private nonisolated static func isNookHook(_ hook: [String: Any]) -> Bool {
        let command = hook["command"] as? String ?? ""
        return command.contains(bridgeScriptName)
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
