//
//  Settings.swift
//  Nook
//
//  App settings manager using UserDefaults
//

import Foundation

/// Available notification sounds
enum NotificationSound: String, CaseIterable {
    case none = "None"
    case pop = "Pop"
    case ping = "Ping"
    case tink = "Tink"
    case glass = "Glass"
    case blow = "Blow"
    case bottle = "Bottle"
    case frog = "Frog"
    case funk = "Funk"
    case hero = "Hero"
    case morse = "Morse"
    case purr = "Purr"
    case sosumi = "Sosumi"
    case submarine = "Submarine"
    case basso = "Basso"

    /// The system sound name to use with NSSound, or nil for no sound
    var soundName: String? {
        self == .none ? nil : rawValue
    }
}

enum AppSettings {
    private nonisolated(unsafe) static let defaults = UserDefaults.standard
    nonisolated static let artworkAdaptiveBackgroundEnabledKey = "artworkAdaptiveBackgroundEnabled"
    nonisolated static let musicEdgeGlowEnabledKey = "musicEdgeGlowEnabled"
    nonisolated static let vibeGlowEnabledKey = "vibeGlowEnabled"
    nonisolated static let performanceMonitorEnabledKey = "performanceMonitorEnabled"
    nonisolated static let musicAbovePerformanceKey = "musicAbovePerformance"
    nonisolated static let shortcutsKey = "nook_shortcut_bindings"

    // MARK: - Keys

    private enum Keys {
        nonisolated static let notificationSound = "notificationSound"
        nonisolated static let claudeDirectoryName = "claudeDirectoryName"
        nonisolated static let artworkAdaptiveBackgroundEnabled = AppSettings.artworkAdaptiveBackgroundEnabledKey
        nonisolated static let musicEdgeGlowEnabled = AppSettings.musicEdgeGlowEnabledKey
        nonisolated static let vibeGlowEnabled = AppSettings.vibeGlowEnabledKey
        nonisolated static let performanceMonitorEnabled = AppSettings.performanceMonitorEnabledKey
        nonisolated static let musicAbovePerformance = AppSettings.musicAbovePerformanceKey
        nonisolated static let autoInstallHooks = "autoInstallHooks"
        nonisolated static let claudeHooksEnabled = "claudeHooksEnabled"
        nonisolated static let codexHooksEnabled = "codexHooksEnabled"
        nonisolated static let opencodeHooksEnabled = "opencodeHooksEnabled"
        nonisolated static let debugLogEnabled = "debugLogEnabled"
    }

    nonisolated static func registerDefaults() {
        defaults.register(defaults: [
            Keys.artworkAdaptiveBackgroundEnabled: true,
            Keys.musicEdgeGlowEnabled: true,
            Keys.vibeGlowEnabled: false,
            Keys.performanceMonitorEnabled: true,
            Keys.musicAbovePerformance: false,
            Keys.autoInstallHooks: true,
            Keys.claudeHooksEnabled: true,
            Keys.codexHooksEnabled: true,
            Keys.opencodeHooksEnabled: false,
            Keys.debugLogEnabled: false,
        ])
    }

    // MARK: - Notification Sound

    /// The sound to play when Claude finishes and is ready for input
    nonisolated static var notificationSound: NotificationSound {
        get {
            guard let rawValue = defaults.string(forKey: Keys.notificationSound),
                  let sound = NotificationSound(rawValue: rawValue) else {
                return .pop // Default to Pop
            }
            return sound
        }
        set {
            defaults.set(newValue.rawValue, forKey: Keys.notificationSound)
        }
    }

    // MARK: - Claude Directory

    /// The name of the Claude config directory under the user's home folder.
    /// Defaults to ".claude" (standard Claude Code installation).
    /// Change to ".claude-internal" (or similar) for enterprise/custom distributions.
    nonisolated static var claudeDirectoryName: String {
        get {
            let value = defaults.string(forKey: Keys.claudeDirectoryName) ?? ""
            return value.isEmpty ? ".claude" : value
        }
        set {
            defaults.set(newValue.trimmingCharacters(in: .whitespaces), forKey: Keys.claudeDirectoryName)
        }
    }

    // MARK: - Artwork Adaptive Background

    /// Controls whether the notch artwork background adapts to the current artwork.
    /// Defaults to enabled.
    nonisolated static var artworkAdaptiveBackgroundEnabled: Bool {
        get {
            if defaults.object(forKey: Keys.artworkAdaptiveBackgroundEnabled) == nil {
                return true
            }
            return defaults.bool(forKey: Keys.artworkAdaptiveBackgroundEnabled)
        }
        set {
            defaults.set(newValue, forKey: Keys.artworkAdaptiveBackgroundEnabled)
        }
    }

    // MARK: - Music Edge Glow

    /// Controls whether the breathing edge glow is shown when music is playing.
    /// Defaults to enabled.
    nonisolated static var musicEdgeGlowEnabled: Bool {
        get {
            if defaults.object(forKey: Keys.musicEdgeGlowEnabled) == nil {
                return true
            }
            return defaults.bool(forKey: Keys.musicEdgeGlowEnabled)
        }
        set {
            defaults.set(newValue, forKey: Keys.musicEdgeGlowEnabled)
        }
    }

    // MARK: - Vibe Glow

    /// Controls whether the closed notch uses the continuous vibe glow.
    /// Defaults to disabled so the closed-state activity UI remains unchanged.
    nonisolated static var vibeGlowEnabled: Bool {
        get {
            if defaults.object(forKey: Keys.vibeGlowEnabled) == nil {
                return false
            }
            return defaults.bool(forKey: Keys.vibeGlowEnabled)
        }
        set {
            defaults.set(newValue, forKey: Keys.vibeGlowEnabled)
        }
    }

    // MARK: - Performance Monitor

    /// Controls whether the compact performance monitor row is shown on the home page.
    /// Defaults to enabled.
    nonisolated static var performanceMonitorEnabled: Bool {
        get {
            if defaults.object(forKey: Keys.performanceMonitorEnabled) == nil {
                return true
            }
            return defaults.bool(forKey: Keys.performanceMonitorEnabled)
        }
        set {
            defaults.set(newValue, forKey: Keys.performanceMonitorEnabled)
        }
    }

    // MARK: - Music Above Performance

    /// Controls whether the music card renders above the performance row on the
    /// instances page. Defaults to false (performance on top).
    nonisolated static var musicAbovePerformance: Bool {
        get {
            if defaults.object(forKey: Keys.musicAbovePerformance) == nil {
                return false
            }
            return defaults.bool(forKey: Keys.musicAbovePerformance)
        }
        set {
            defaults.set(newValue, forKey: Keys.musicAbovePerformance)
        }
    }

    // MARK: - Agent Hooks

    /// Whether to auto-install hooks at launch for agents with hooks enabled.
    nonisolated static var autoInstallHooks: Bool {
        get { defaults.bool(forKey: Keys.autoInstallHooks) }
        set { defaults.set(newValue, forKey: Keys.autoInstallHooks) }
    }

    nonisolated static var claudeHooksEnabled: Bool {
        get { defaults.bool(forKey: Keys.claudeHooksEnabled) }
        set { defaults.set(newValue, forKey: Keys.claudeHooksEnabled) }
    }

    nonisolated static var codexHooksEnabled: Bool {
        get { defaults.bool(forKey: Keys.codexHooksEnabled) }
        set { defaults.set(newValue, forKey: Keys.codexHooksEnabled) }
    }

    nonisolated static var opencodeHooksEnabled: Bool {
        get { defaults.bool(forKey: Keys.opencodeHooksEnabled) }
        set { defaults.set(newValue, forKey: Keys.opencodeHooksEnabled) }
    }

    /// When true, internal log output is mirrored to
    /// `/tmp/nook-debug.log` (single 10 MB rolling file, recreated
    /// on every app launch). Default off; intended as a
    /// diagnostic toggle for hook/socket issues.
    nonisolated static var debugLogEnabled: Bool {
        get { defaults.bool(forKey: Keys.debugLogEnabled) }
        set { defaults.set(newValue, forKey: Keys.debugLogEnabled) }
    }
}
