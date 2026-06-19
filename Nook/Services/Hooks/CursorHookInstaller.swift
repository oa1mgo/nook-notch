//
//  CursorHookInstaller.swift
//  Nook
//
//  Installs Cursor user hooks that forward agent lifecycle events
//  into Nook via the shared Unix socket.
//

import Foundation

struct CursorHookInstaller {
    private static var cursorDir: URL {
        AgentPathsResolver.directory(for: .cursor)
    }

    private static var hooksDir: URL {
        AgentPathsResolver.hooksDirectory(for: .cursor)
    }

    private static var hooksFile: URL {
        cursorDir.appendingPathComponent("hooks.json")
    }

    private static var bridgeScript: URL {
        hooksDir.appendingPathComponent("nook-cursor-hook.py")
    }

    static func installIfNeeded() {
        guard AgentPathsResolver.isInstalled(.cursor) else { return }
        try? FileManager.default.createDirectory(at: hooksDir, withIntermediateDirectories: true)
        installBridgeScript()
        installHooksConfiguration()
    }

    static func uninstall() {
        try? FileManager.default.removeItem(at: bridgeScript)

        guard let data = try? Data(contentsOf: hooksFile),
              var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var hooks = json["hooks"] as? [String: Any] else {
            return
        }

        for (event, value) in hooks {
            guard var entries = value as? [[String: Any]] else { continue }
            entries.removeAll(where: isNookHook)
            if entries.isEmpty {
                hooks.removeValue(forKey: event)
            } else {
                hooks[event] = entries
            }
        }

        if hooks.isEmpty {
            json.removeValue(forKey: "hooks")
        } else {
            json["hooks"] = hooks
        }

        writeHooksJSON(json)
    }

    static func isInstalled() -> Bool {
        guard FileManager.default.fileExists(atPath: bridgeScript.path),
              let data = try? Data(contentsOf: hooksFile),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = json["hooks"] as? [String: Any] else {
            return false
        }

        for (_, value) in hooks {
            guard let entries = value as? [[String: Any]] else { continue }
            if entries.contains(where: isNookHook) {
                return true
            }
        }

        return false
    }

    private static func installBridgeScript() {
        let script = """
        #!/usr/bin/env python3
        import json
        import os
        import socket
        import sys

        SOCKET_PATH = "/tmp/nook.sock"

        def hook_response(event_name):
            normalized = (event_name or "").replace("_", "").replace("-", "").lower()
            if normalized in {
                "pretooluse",
                "beforeshellexecution",
                "beforemcpexecution",
                "beforereadfile",
                "beforetabfileread",
                "subagentstart",
            }:
                return {"permission": "allow"}
            if normalized == "beforesubmitprompt":
                return {"continue": True}
            return {}

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
            event_name = ""
            payload = raw

            if raw.strip():
                try:
                    event = json.loads(raw.decode("utf-8"))
                    event_name = event.get("hook_event_name") or event.get("event") or ""
                    event["origin"] = "cursor"
                    payload = (json.dumps(event, separators=(",", ":")) + "\\n").encode("utf-8")
                except Exception:
                    pass

                forward(payload)

            sys.stdout.write(json.dumps(hook_response(event_name), separators=(",", ":")))
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

    private static func installHooksConfiguration() {
        var json: [String: Any] = [:]
        if let data = try? Data(contentsOf: hooksFile),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            json = existing
        }

        json["version"] = json["version"] ?? 1

        var hooks = json["hooks"] as? [String: Any] ?? [:]
        for (event, value) in hooks {
            guard var entries = value as? [[String: Any]] else { continue }
            entries.removeAll(where: isNookHook)
            if entries.isEmpty {
                hooks.removeValue(forKey: event)
            } else {
                hooks[event] = entries
            }
        }

        let command = "\(detectPythonExecutable()) \(shellQuote(bridgeScript.path))"
        let handler: [String: Any] = [
            "type": "command",
            "command": command,
            "timeout": 5
        ]

        let events = [
            "sessionStart",
            "beforeSubmitPrompt",
            "preToolUse",
            "postToolUse",
            "postToolUseFailure",
            "afterAgentResponse",
            "afterAgentThought",
            "preCompact",
            "subagentStart",
            "subagentStop",
            "stop",
            "sessionEnd",
        ]

        for event in events {
            let existingEntries = hooks[event] as? [[String: Any]] ?? []
            hooks[event] = existingEntries.filter { !isNookHook($0) } + [handler]
        }

        json["hooks"] = hooks
        writeHooksJSON(json)
    }

    private static func writeHooksJSON(_ json: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(json),
              let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) else {
            return
        }
        try? data.write(to: hooksFile)
    }

    private nonisolated static func isNookHook(_ hook: [String: Any]) -> Bool {
        let command = hook["command"] as? String ?? ""
        return command.contains("nook-cursor-hook.py")
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
