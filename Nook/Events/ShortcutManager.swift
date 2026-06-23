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

    /// Supplies the current content type so chat-specific hardcoded keys
    /// (↑/↓/⌃F/⌃B/⌃G) can be dispatched before the configurable action loop.
    /// Set by `NotchWindowController` at init.
    var contentTypeProvider: (() -> NotchContentType)?

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
        let hotKeyID = EventHotKeyID(signature: 0x4E4F4F4B, id: hotKeyIDCounter)
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

            // Esc — close notch (skip if IME has marked text)
            if combo.keyCode == 53 {
                if let textView = NSApp.keyWindow?.firstResponder as? NSTextView,
                   textView.hasMarkedText() {
                    return event // pass through for IME composition
                }
                NotificationCenter.default.post(name: .shortcutAction, object: ShortcutAction.closeNotch)
                return nil
            }

            // Chat-only key handling. Hardcoded and not user-rebindable:
            //   - ↑/↓/⌃F/⌃B/⌃G trigger chat scroll (see `chatScrollDirection`)
            //   - plain j/k are ignored (don't navigate, don't scroll) so they
            //     don't interfere with chat viewing, except when an editable
            //     text field is focused — then they pass through for typing.
            // We handle these before the configurable action loop so ⌃N/P
            // (which are bound to "previous/next session" in settings) don't
            // scroll chat, and j/k (which are bound to navigate up/down in
            // settings) don't navigate from chat pages.
            if case .chat = contentTypeProvider?() {
                if let direction = Self.chatScrollDirection(for: combo) {
                    NotificationCenter.default.post(name: .chatScrollAction, object: direction)
                    return nil
                }
                let hasNoModifiers = (combo.flags.rawValue & KeyCombination.relevantModifierMask) == 0
                if hasNoModifiers, combo.keyCode == 38 || combo.keyCode == 40 { // J or K
                    if let textView = NSApp.keyWindow?.firstResponder as? NSTextView,
                       textView.isEditable {
                        return event // pass through for typing
                    }
                    return nil // ignore on chat page
                }
            }

            // Check all action bindings.
            // toggleNotch's Carbon-registered combo is skipped to avoid double-fire;
            // non-Carbon combos are handled here.
            for action in ShortcutAction.allCases {
                let combos = ShortcutStore.shared.combinations(for: action)
                guard combos.contains(combo) else { continue }

                // When an editable text field is first responder, let it
                // handle typing keys and cursor-movement keys instead of
                // consuming them. Ctrl+letter shortcuts (⌃P/N/G/H) always
                // scroll / navigate, never pass through — they're not
                // typing keys.
                if let textView = NSApp.keyWindow?.firstResponder as? NSTextView,
                   textView.isEditable {
                    let isArrowKey = combo.keyCode == 126 || combo.keyCode == 125
                                   || combo.keyCode == 123 || combo.keyCode == 124
                    let isEnter = combo.keyCode == 36
                    // Plain letters (no modifier): pass through so j/k/h/l
                    // and other typing keys reach the text field.
                    let hasNoModifiers = (combo.flags.rawValue & KeyCombination.relevantModifierMask) == 0
                    let isTypingKey = hasNoModifiers && keyCodeToCharacter(combo.keyCode) != nil
                    if isArrowKey || isEnter || isTypingKey {
                        return event
                    }
                }

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

    // MARK: - Chat Scroll Keys (hardcoded, not from ShortcutStore)

    /// Map a key combo to a chat scroll direction. Returns nil if the combo
    /// is not a chat scroll key. Called only when contentType == .chat.
    ///
    /// - ↑ / ↓ : line scroll
    /// - ⌃F    : vim-style page down (forward)
    /// - ⌃B    : vim-style page up   (backward)
    /// - ⌃G    : scroll to bottom
    private static func chatScrollDirection(for combo: KeyCombination) -> ChatScrollDirection? {
        let mods = combo.flags.rawValue
        let hasCtrl = mods & NSEvent.ModifierFlags.control.rawValue != 0
        let plain = !hasCtrl
                  && mods & NSEvent.ModifierFlags.command.rawValue == 0
                  && mods & NSEvent.ModifierFlags.option.rawValue == 0
                  && mods & NSEvent.ModifierFlags.shift.rawValue == 0
        switch combo.keyCode {
        case 126: return plain ? .up : nil          // ↑
        case 125: return plain ? .down : nil        // ↓
        case 11:  return hasCtrl ? .pageUp : nil    // ⌃B (keyCode 11 = B)
        case 3:   return hasCtrl ? .pageDown : nil  // ⌃F (keyCode 3 = F)
        case 5:   return hasCtrl ? .bottom : nil    // ⌃G (keyCode 5 = G)
        default:  return nil
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
    static let chatScrollAction = Notification.Name("com.nook.chatScrollAction")
}
