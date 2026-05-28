//
//  ShortcutManager.swift
//  Nook
//
//  Manages global (Carbon) and local (NSApp) keyboard shortcut routing
//

import AppKit
import Carbon
import Combine

@MainActor
class ShortcutManager {
    static let shared = ShortcutManager()

    private var hotKeyRefs: [EventHotKeyRef] = []
    private var hotKeyIDCounter: UInt32 = 0
    private var localMonitor: Any?
    private var cancellables = Set<AnyCancellable>()

    /// Set by ShortcutSettingsView to prevent Esc from closing notch during recording
    var isRecording: Bool = false

    private init() {
        installCarbonEventHandler()
        subscribeToStoreChanges()
    }

    // MARK: - Global Hotkeys (Carbon)

    private var toggleNotchCombo: KeyCombination? {
        ShortcutStore.shared.combinations(for: .toggleNotch).first
    }

    private func installCarbonEventHandler() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: OSType(kEventHotKeyPressed)
        )
        InstallEventHandler(
            GetEventDispatcherTarget(),
            { (_, event, _) -> OSStatus in
                guard let event = event else { return noErr }
                var hotKeyID = EventHotKeyID()
                GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                if hotKeyID.signature == 0x4E4F4F4B { // "NOOK"
                    Task { @MainActor in
                        NotificationCenter.default.post(name: .globalToggleNotch, object: nil)
                    }
                }
                return noErr
            },
            1,
            &eventType,
            nil,
            nil
        )
    }

    func registerGlobalHotkey() {
        unregisterAllHotkeys()
        guard let combo = toggleNotchCombo else { return }

        hotKeyIDCounter += 1
        var hotKeyID = EventHotKeyID(signature: 0x4E4F4F4B, id: hotKeyIDCounter)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(combo.keyCode),
            combo.carbonModifiers,
            hotKeyID,
            GetEventDispatcherTarget(),
            0,
            &ref
        )
        if status == noErr, let ref = ref {
            hotKeyRefs.append(ref)
        }
    }

    private func unregisterAllHotkeys() {
        for ref in hotKeyRefs {
            UnregisterEventHotKey(ref)
        }
        hotKeyRefs.removeAll()
    }

    // MARK: - Local Monitor (Notch Open)

    func startLocalMonitor() {
        stopLocalMonitor()
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return event }

            // During recording, pass event to be handled by ShortcutSettingsView
            if self.isRecording {
                NotificationCenter.default.post(name: .shortcutKeyDown, object: event)
                return nil // swallow the event during recording
            }

            let combo = KeyCombination.from(event: event)

            // Esc — close notch (only consume if we handle it)
            if combo.keyCode == 53 {
                NotificationCenter.default.post(name: .shortcutAction, object: ShortcutAction.closeNotch)
                return nil
            }

            // Check all action bindings.
            // toggleNotch's Carbon-registered combo is skipped to avoid double-fire;
            // non-Carbon combos are handled here.
            for action in ShortcutAction.allCases {
                let combos = ShortcutStore.shared.combinations(for: action)
                guard combos.contains(combo) else { continue }
                // Skip the first (Carbon-registered) combo for toggleNotch
                if action == .toggleNotch, combo == combos.first {
                    continue
                }
                NotificationCenter.default.post(name: .shortcutAction, object: action)
                return nil // consumed
            }

            return event // not consumed, pass through
        }
    }

    func stopLocalMonitor() {
        if let monitor = localMonitor {
            NSEvent.removeMonitor(monitor)
            localMonitor = nil
        }
    }

    // MARK: - Store Subscriptions

    private func subscribeToStoreChanges() {
        ShortcutStore.shared.$bindings
            .sink { [weak self] _ in
                self?.registerGlobalHotkey()
            }
            .store(in: &cancellables)
    }
}

// MARK: - Notification Extensions

extension Notification.Name {
    static let globalToggleNotch = Notification.Name("com.nook.globalToggleNotch")
    static let shortcutAction = Notification.Name("com.nook.shortcutAction")
    static let shortcutKeyDown = Notification.Name("com.nook.shortcutKeyDown")
}
