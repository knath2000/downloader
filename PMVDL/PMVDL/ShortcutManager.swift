import SwiftUI

/// Catalog of shortcut actions the user can rebind from the Settings pane.
enum ShortcutAction: String, CaseIterable, Identifiable {
    case homeTab
    case feedTab
    case watchlistTab
    case libraryTab
    case settingsTab
    case extractNew
    case search
    case submitURL
    case quit

    var id: String { rawValue }

    var title: String {
        switch self {
        case .homeTab:      return "Go to Home"
        case .feedTab:      return "Go to Feed"
        case .watchlistTab: return "Go to Watchlist"
        case .libraryTab:   return "Go to Library"
        case .settingsTab:  return "Open Settings"
        case .extractNew:   return "Extract New Video"
        case .search:       return "Focus Search"
        case .submitURL:    return "Submit URL"
        case .quit:         return "Quit LustreStudio"
        }
    }

    var defaultKey: KeyEquivalent {
        switch self {
        case .homeTab:      return "1"
        case .feedTab:      return "2"
        case .watchlistTab: return "3"
        case .libraryTab:   return "4"
        case .settingsTab:  return ","
        case .extractNew:   return "n"
        case .search:       return "f"
        case .submitURL:    return .return
        case .quit:         return "q"
        }
    }

    var defaultModifiers: EventModifiers {
        switch self {
        case .settingsTab, .quit:
            return .command
        default:
            return .command
        }
    }

    var storageKey: String { "shortcut." + rawValue }

    var isSystemReserved: Bool {
        switch self {
        case .quit: return true
        default:    return false
        }
    }
}

/// Persists and reads customized keyboard shortcuts via @AppStorage.
@MainActor
final class ShortcutManager: ObservableObject {
    static let shared = ShortcutManager()

    /// Stores shortcuts as "key|modifiers" where modifiers is the raw integer
    /// from `EventModifiers.rawValue`. Empty / unparseable values fall back to defaults.
    @Published var overrides: [ShortcutAction: String] = [:]

    private init() {
        load()
    }

    func load() {
        var snapshot: [ShortcutAction: String] = [:]
        for action in ShortcutAction.allCases {
            if let stored = UserDefaults.standard.string(forKey: action.storageKey),
               !stored.isEmpty {
                snapshot[action] = stored
            }
        }
        overrides = snapshot
    }

    func binding(for action: ShortcutAction) -> KeyEquivalent {
        guard let stored = overrides[action] else { return action.defaultKey }
        let parts = stored.split(separator: "|", maxSplits: 1).map(String.init)
        guard let keyString = parts.first, let firstChar = keyString.first else {
            return action.defaultKey
        }
        return KeyEquivalent(firstChar)
    }

    func modifiers(for action: ShortcutAction) -> EventModifiers {
        guard let stored = overrides[action], let raw = Int(stored.split(separator: "|").last ?? "0") else {
            return action.defaultModifiers
        }
        return EventModifiers(rawValue: raw)
    }

    func set(_ action: ShortcutAction, key: KeyEquivalent, modifiers: EventModifiers) {
        overrides[action] = "\(key.character.lowercased())|\(modifiers.rawValue)"
        UserDefaults.standard.set(overrides[action], forKey: action.storageKey)
    }

    func reset(_ action: ShortcutAction) {
        overrides.removeValue(forKey: action)
        UserDefaults.standard.removeObject(forKey: action.storageKey)
    }

    func resetAll() {
        for action in ShortcutAction.allCases {
            reset(action)
        }
    }

    func displayString(for action: ShortcutAction) -> String {
        let key = binding(for: action)
        let mods = modifiers(for: action)
        return Self.format(key: key, modifiers: mods)
    }

    static func format(key: KeyEquivalent, modifiers: EventModifiers) -> String {
        var parts: [String] = []
        if modifiers.contains(.control) { parts.append("⌃") }
        if modifiers.contains(.option)  { parts.append("⌥") }
        if modifiers.contains(.shift)   { parts.append("⇧") }
        if modifiers.contains(.command) { parts.append("⌘") }
        parts.append(String(key.character).uppercased())
        return parts.joined()
    }
}

extension ShortcutManager {
    /// AppStorage-backed binding for the `key|modifiers` string.
    /// Use from a settings row to let the user edit a shortcut.
    func appStorageString(for action: ShortcutAction) -> String {
        let key = binding(for: action)
        let mods = modifiers(for: action)
        return "\(key.character.lowercased())|\(mods.rawValue)"
    }
}
