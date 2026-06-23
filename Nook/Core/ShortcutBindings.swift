//
//  ShortcutBindings.swift
//  Nook
//
//  Data models for configurable keyboard shortcuts
//

import AppKit
import Carbon

struct KeyCombination: Codable, Hashable {
    var keyCode: UInt16
    var flags: ModifierFlagsWrapper

    static let relevantModifierMask: UInt =
        NSEvent.ModifierFlags.command.rawValue
        | NSEvent.ModifierFlags.option.rawValue
        | NSEvent.ModifierFlags.control.rawValue
        | NSEvent.ModifierFlags.shift.rawValue

    static func == (lhs: KeyCombination, rhs: KeyCombination) -> Bool {
        lhs.keyCode == rhs.keyCode
            && (lhs.flags.rawValue & Self.relevantModifierMask)
            == (rhs.flags.rawValue & Self.relevantModifierMask)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(keyCode)
        hasher.combine(flags.rawValue & Self.relevantModifierMask)
    }

    var displayString: String {
        var parts: [String] = []
        let flag = flags.rawValue
        if flag & NSEvent.ModifierFlags.control.rawValue != 0 { parts.append("⌃") }
        if flag & NSEvent.ModifierFlags.option.rawValue != 0 { parts.append("⌥") }
        if flag & NSEvent.ModifierFlags.shift.rawValue != 0 { parts.append("⇧") }
        if flag & NSEvent.ModifierFlags.command.rawValue != 0 { parts.append("⌘") }

        if let char = keyCodeToCharacter(keyCode) {
            parts.append(char)
        } else {
            parts.append(keyCodeToSymbol(keyCode))
        }
        return parts.joined()
    }

    var carbonKeyCode: UInt16 { keyCode }
    var carbonModifiers: UInt32 {
        var flags: UInt32 = 0
        let flag = self.flags.rawValue
        if flag & NSEvent.ModifierFlags.command.rawValue != 0 { flags |= UInt32(cmdKey) }
        if flag & NSEvent.ModifierFlags.option.rawValue != 0  { flags |= UInt32(optionKey) }
        if flag & NSEvent.ModifierFlags.control.rawValue != 0 { flags |= UInt32(controlKey) }
        if flag & NSEvent.ModifierFlags.shift.rawValue != 0   { flags |= UInt32(shiftKey) }
        return flags
    }

    static func from(event: NSEvent) -> KeyCombination {
        let masked = event.modifierFlags.rawValue & KeyCombination.relevantModifierMask
        return KeyCombination(keyCode: event.keyCode, flags: ModifierFlagsWrapper(rawValue: masked))
    }
}

struct ModifierFlagsWrapper: Codable, Equatable, Hashable {
    var rawValue: UInt
}

enum ShortcutAction: String, CaseIterable, Codable {
    case toggleNotch
    case closeNotch
    case selectPrevious
    case selectNext
    case enterSession
    case navigateBack
    case openSettings

    var displayName: String {
        switch self {
        case .toggleNotch:     return "Toggle Main Page"
        case .closeNotch:      return "Close Notch"
        case .selectPrevious:  return "Navigate Up"
        case .selectNext:      return "Navigate Down"
        case .enterSession:    return "Open"
        case .navigateBack:    return "Go Back"
        case .openSettings:    return "Open Settings"
        }
    }

    var sfSymbolName: String {
        switch self {
        case .toggleNotch:     return "rectangle.and.pencil.and.ellipsis"
        case .closeNotch:      return "xmark.circle"
        case .selectPrevious:  return "chevron.up"
        case .selectNext:      return "chevron.down"
        case .enterSession:    return "arrow.forward"
        case .navigateBack:    return "arrow.uturn.left"
        case .openSettings:    return "gearshape"
        }
    }

    var defaultCombinations: [KeyCombination] {
        switch self {
        case .toggleNotch:
            return [KeyCombination(keyCode: 37, flags: ModifierFlagsWrapper(rawValue: NSEvent.ModifierFlags.command.rawValue | NSEvent.ModifierFlags.control.rawValue))] // ⌃⌘L (keyCode 37 = L)
        case .closeNotch:
            return [KeyCombination(keyCode: 53, flags: ModifierFlagsWrapper(rawValue: 0))] // Esc (keyCode 53)
        case .selectPrevious:
            return [
                KeyCombination(keyCode: 35, flags: ModifierFlagsWrapper(rawValue: NSEvent.ModifierFlags.control.rawValue)), // ⌃P
                KeyCombination(keyCode: 126, flags: ModifierFlagsWrapper(rawValue: 0)), // ↑
                KeyCombination(keyCode: 40, flags: ModifierFlagsWrapper(rawValue: 0)) // K (vim up)
            ]
        case .selectNext:
            return [
                KeyCombination(keyCode: 45, flags: ModifierFlagsWrapper(rawValue: NSEvent.ModifierFlags.control.rawValue)), // ⌃N
                KeyCombination(keyCode: 125, flags: ModifierFlagsWrapper(rawValue: 0)), // ↓
                KeyCombination(keyCode: 38, flags: ModifierFlagsWrapper(rawValue: 0)) // J (vim down)
            ]
        case .enterSession:
            return [KeyCombination(keyCode: 36, flags: ModifierFlagsWrapper(rawValue: 0))] // Enter
        case .navigateBack:
            return [KeyCombination(keyCode: 4, flags: ModifierFlagsWrapper(rawValue: NSEvent.ModifierFlags.control.rawValue))] // ⌃H (keyCode 4 = H)
        case .openSettings:
            return [KeyCombination(keyCode: 43, flags: ModifierFlagsWrapper(rawValue: NSEvent.ModifierFlags.command.rawValue))] // ⌘, (keyCode 43 = ,)
        }
    }
}

struct ShortcutBindings: Codable {
    var action: ShortcutAction
    var combinations: [KeyCombination]
}

// MARK: - Key Code Helpers

/// Convert a key code to a printable character string (for alphanumeric keys).
/// Internal so `ShortcutManager` can detect "typing keys" to pass through
/// when an editable text field is focused.
func keyCodeToCharacter(_ keyCode: UInt16) -> String? {
    switch keyCode {
    case 0:   return "A"
    case 1:   return "S"
    case 2:   return "D"
    case 3:   return "F"
    case 4:   return "H"
    case 5:   return "G"
    case 6:   return "Z"
    case 7:   return "X"
    case 8:   return "C"
    case 9:   return "V"
    case 11:  return "B"
    case 12:  return "Q"
    case 13:  return "W"
    case 14:  return "E"
    case 15:  return "R"
    case 16:  return "Y"
    case 17:  return "T"
    case 18:  return "1"
    case 19:  return "2"
    case 20:  return "3"
    case 21:  return "4"
    case 22:  return "6"
    case 23:  return "5"
    case 24:  return "="
    case 25:  return "9"
    case 26:  return "7"
    case 27:  return "-"
    case 28:  return "8"
    case 29:  return "0"
    case 30:  return "]"
    case 31:  return "O"
    case 32:  return "U"
    case 33:  return "["
    case 34:  return "I"
    case 35:  return "P"
    case 37:  return "L"
    case 38:  return "J"
    case 39:  return "\""
    case 40:  return "K"
    case 41:  return ";"
    case 42:  return "\\"
    case 43:  return ","
    case 44:  return "/"
    case 45:  return "N"
    case 46:  return "M"
    case 47:  return "."
    case 48:  return "Tab"
    case 49:  return nil // Space — handled by keyCodeToSymbol
    case 50:  return "`"
    case 53:  return nil // Esc — handled by keyCodeToSymbol
    default:  return nil
    }
}

/// Convert a key code to a symbolic name for non-printable keys
private func keyCodeToSymbol(_ keyCode: UInt16) -> String {
    switch keyCode {
    case 53:  return "Esc"
    case 36:  return "⏎"
    case 48:  return "⇥"
    case 49:  return "Space"
    case 51:  return "⌫"
    case 117: return "⌦"
    case 123: return "←"
    case 124: return "→"
    case 125: return "↓"
    case 126: return "↑"
    case 116: return "PgUp"
    case 121: return "PgDn"
    case 115: return "Home"
    case 119: return "End"
    case 122: return "F1"
    case 120: return "F2"
    case 99:  return "F3"
    case 118: return "F4"
    case 96:  return "F5"
    case 97:  return "F6"
    case 98:  return "F7"
    case 100: return "F8"
    case 101: return "F9"
    case 109: return "F10"
    case 103: return "F11"
    case 111: return "F12"
    default:  return "Key\(keyCode)"
    }
}
