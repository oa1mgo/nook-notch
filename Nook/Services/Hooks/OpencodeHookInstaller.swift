//
//  OpencodeHookInstaller.swift
//  Nook
//
//  Installs the bundled Nook OpenCode plugin so session lifecycle
//  events are forwarded into Nook via the shared Unix socket.
//
//  Architecture
//  ============
//  • Plugin files (package.json + index.js) live in Resources/opencode-plugin/
//    and are copied to ~/.config/opencode/plugins/nook/ at install time.
//
//  • The plugin is registered by adding its path to the `"plugin"`
//    array in opencode.json(c).  We try the official `opencode plugin --global`
//    CLI first (preserves JSONC comments); if the binary isn't available we
//    fall back to a direct JSON edit that may lose comments.
//
//  • Uninstall always uses string-level removal: we strip the plugin path
//    from the array and then remove any leftover empty `"plugin": []` key.
//

import Foundation

struct OpencodeHookInstaller {
    // MARK: - Paths

    private static var configDir: URL {
        AgentPathsResolver.directory(for: .opencode)
    }

    /// Where the bundled plugin files are copied at install time.
    private static var pluginDir: URL {
        configDir.appendingPathComponent("plugins/nook")
    }

    private static var pluginPackageJson: URL {
        pluginDir.appendingPathComponent("package.json")
    }

    private static var pluginIndex: URL {
        pluginDir.appendingPathComponent("index.js")
    }

    /// OpenCode config file — prefers .jsonc over .json.
    private static var configFile: URL {
        let jsonc = configDir.appendingPathComponent("opencode.jsonc")
        let json = configDir.appendingPathComponent("opencode.json")
        return FileManager.default.fileExists(atPath: jsonc.path) ? jsonc : json
    }

    // MARK: - Public API

    /// Install the plugin when all conditions are met:
    ///   • OpenCode is installed (config dir exists)
    ///   • Plugin isn't already installed
    static func installIfNeeded() {
        guard AgentPathsResolver.isInstalled(.opencode) else { return }
        guard !isInstalled() else { return }

        copyPluginFiles()

        // After copying plugin files, re-check.  If the config already has
        // the entry (from a prior fallback edit), we're done — no need to
        // run the CLI (which would add a duplicate) or the fallback.
        guard !isInstalled() else { return }

        // Primary path: use opencode CLI which handles JSONC perfectly.
        if runOpenCodePluginInstall() { return }

        // Fallback: direct config edit (may lose JSONC comments).
        installViaConfigEdit()
    }

    /// Remove the plugin files and clean up the config.
    static func uninstall() {
        try? FileManager.default.removeItem(at: pluginDir)

        guard var config = try? String(contentsOf: configFile, encoding: .utf8) else { return }
        let original = config

        config = removePluginEntry(config, entry: pluginDir.path)
        config = removeEmptyPluginArray(config)

        guard config != original else { return }
        try? config.write(to: configFile, atomically: true, encoding: .utf8)
    }

    /// Returns true when the plugin is fully installed.
    static func isInstalled() -> Bool {
        guard FileManager.default.fileExists(atPath: pluginPackageJson.path),
              FileManager.default.fileExists(atPath: pluginIndex.path) else {
            return false
        }
        guard let config = try? String(contentsOf: configFile, encoding: .utf8) else {
            return false
        }
        return config.contains(pluginDir.path)
    }

    // MARK: - Plugin File Copy

    /// Copy the bundled plugin files into the per-user plugin directory.
    ///
    /// Xcode may flatten the `Resources/opencode-plugin/` folder into flat
    /// Resources, so we try the subdirectory first, then the flat bundle root.
    /// In both cases we verify the `package.json` is ours by checking for `"nook"`.
    private static func copyPluginFiles() {
        guard let res = Bundle.main.resourceURL else { return }

        let candidates = [
            res.appendingPathComponent("opencode-plugin"),
            res,
        ]

        for base in candidates {
            let pkg = base.appendingPathComponent("package.json")
            let idx = base.appendingPathComponent("index.js")

            guard FileManager.default.fileExists(atPath: pkg.path),
                  FileManager.default.fileExists(atPath: idx.path),
                  let content = try? String(contentsOf: pkg),
                  content.contains("\"nook\"")
            else { continue }

            try? FileManager.default.createDirectory(at: pluginDir, withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: pluginPackageJson)
            try? FileManager.default.removeItem(at: pluginIndex)
            try? FileManager.default.copyItem(at: pkg, to: pluginPackageJson)
            try? FileManager.default.copyItem(at: idx, to: pluginIndex)
            return
        }
    }

    // MARK: - CLI Install

    /// Run `opencode plugin --global <plugin-dir>`.
    /// Returns true when the CLI exits successfully.
    private static func runOpenCodePluginInstall() -> Bool {
        guard let binary = findOpenCodeBinary() else { return false }

        let process = Process()
        process.executableURL = binary
        process.arguments = ["plugin", "--global", pluginDir.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    /// Locate the opencode binary, searching well-known paths first.
    private static func findOpenCodeBinary() -> URL? {
        let home = NSHomeDirectory()
        let knownPaths = [
            "/opt/homebrew/bin/opencode",
            "/usr/local/bin/opencode",
            "\(home)/.bun/bin/opencode",
            "\(home)/.opencode/bin/opencode",
            "\(home)/.nvm/versions/node/*/bin/opencode",
        ]
        for pattern in knownPaths {
            let resolved = (pattern as NSString).expandingTildeInPath
            if FileManager.default.fileExists(atPath: resolved) {
                // Handle glob patterns like .nvm/versions/node/*/bin
                if resolved.contains("*") {
                    let baseDir = (resolved as NSString)
                        .deletingLastPathComponent  // .../node/*/bin
                        .replacingOccurrences(of: "/*/", with: "/") // not great
                    // Skip glob for now; rely on `which` fallback.
                    continue
                }
                return URL(fileURLWithPath: resolved)
            }
        }

        // Fallback: use `which opencode` via the shell.
        return resolveFromPath("opencode")
    }

    private static func resolveFromPath(_ name: String) -> URL? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = [name]

        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let path = String(data: output.fileHandleForReading.readDataToEndOfFile(),
                              encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return path.isEmpty ? nil : URL(fileURLWithPath: path)
        } catch {
            return nil
        }
    }

    // MARK: - Fallback Config Edit

    /// Directly insert our plugin path into opencode.json(c).
    /// Used when the `opencode` CLI is not on PATH.
    ///
    /// Note: this approach may lose any existing comments in the JSONC file.
    private static func installViaConfigEdit() {
        guard var config = try? String(contentsOf: configFile, encoding: .utf8) else {
            createMinimalConfig()
            return
        }

        let entry = pluginDir.path
        let quotedEntry = "\"\(entry)\""

        // Dedup — skip if entry already exists.
        if config.contains(quotedEntry) { return }

        // If a "plugin" array already exists, append to it.
        if let range = config.range(of: #""plugin"\s*:\s*\["#, options: .regularExpression) {
            let searchStart = config[range.upperBound...]
            guard let closingBracket = findMatchingBracket(searchStart) else {
                createMinimalConfig()
                return
            }

            let arrayContent = config[range.upperBound..<closingBracket]
            let trimmed = arrayContent.trimmingCharacters(in: .whitespacesAndNewlines)

            var result = String(config[..<closingBracket])
            if trimmed.isEmpty {
                // Array was empty, no comma needed.
                result += "\n    \(quotedEntry)"
            } else {
                result += ",\n    \(quotedEntry)"
            }
            result += String(config[closingBracket...])
            try? result.write(to: configFile, atomically: true, encoding: .utf8)
        } else {
            // No "plugin" key yet — add one before the last closing brace.
            guard let lastBrace = config.lastIndex(of: "}") else {
                createMinimalConfig()
                return
            }
            let rest = String(config[lastBrace...])
            var result = String(config[..<lastBrace])
            result += ",\n  \"plugin\": [\n    \(quotedEntry)\n  ]\n"
            result += rest
            try? result.write(to: configFile, atomically: true, encoding: .utf8)
        }
    }

    /// Create a minimal opencode.json(c) with just our plugin entry.
    private static func createMinimalConfig() {
        let entry = pluginDir.path
        let content = "{\n  \"plugin\": [\n    \"\(entry)\"\n  ]\n}\n"
        try? FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        try? content.write(to: configFile, atomically: true, encoding: .utf8)
    }

    /// Walk forward from an opening `[` to find its matching `]`,
    /// handling simple nesting.  Returns nil on malformed input.
    private static func findMatchingBracket(_ text: Substring) -> String.Index? {
        var depth = 1
        var i = text.startIndex
        while i < text.endIndex {
            let ch = text[i]
            if ch == "[" { depth += 1 }
            else if ch == "]" {
                depth -= 1
                if depth == 0 { return i }
            }
            i = text.index(after: i)
        }
        return nil
    }

    // MARK: - Uninstall Helpers

    /// Remove every occurrence of `entry` (as a JSON string) from `config`,
    /// cleaning up any surrounding comma/whitespace.
    private static func removePluginEntry(_ config: String, entry: String) -> String {
        let escaped = NSRegularExpression.escapedPattern(for: entry)
        // Match optional comma+whitespace before, optional whitespace+comma after.
        guard let regex = try? NSRegularExpression(
            pattern: #"(?:\s*,\s*)?"# + "\"\(escaped)\"" + #"(?:\s*,\s*)?"#
        ) else { return config }
        let range = NSRange(config.startIndex..<config.endIndex, in: config)
        return regex.stringByReplacingMatches(in: config, range: range, withTemplate: "")
    }

    /// Remove a top-level `"plugin": []` key (with optional trailing comma).
    private static func removeEmptyPluginArray(_ config: String) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: #""plugin"\s*:\s*\[\s*\]\s*,?\s*"#
        ) else { return config }
        let range = NSRange(config.startIndex..<config.endIndex, in: config)
        return regex.stringByReplacingMatches(in: config, range: range, withTemplate: "")
    }
}
