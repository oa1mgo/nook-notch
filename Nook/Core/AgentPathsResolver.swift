import Foundation

struct AgentPathsResolver {

    static func directory(for provider: SessionProvider) -> URL {
        switch provider {
        case .claude:
            return ClaudePaths.claudeDir
        case .codex:
            return homeDir.appendingPathComponent(".codex")
        case .opencode:
            return homeDir.appendingPathComponent(".config/opencode")
        }
    }

    static func hooksDirectory(for provider: SessionProvider) -> URL {
        switch provider {
        case .claude:
            return ClaudePaths.hooksDir
        case .codex:
            return directory(for: .codex).appendingPathComponent("hooks")
        case .opencode:
            return directory(for: .opencode).appendingPathComponent("hooks")
        }
    }

    static func isInstalled(_ provider: SessionProvider) -> Bool {
        FileManager.default.fileExists(atPath: directory(for: provider).path)
    }

    static func displayPath(for provider: SessionProvider) -> String {
        let path = directory(for: provider).path
        let home = NSHomeDirectory()
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }

    private static var homeDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
    }
}
