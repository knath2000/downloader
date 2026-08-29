import SwiftUI
import Combine

/// Centralized selection management for multi-select across views
/// Each view type gets its own isolated selection set identified by SelectionContext
@MainActor
final class SelectionManager: ObservableObject {
    static let shared = SelectionManager()

    // Each context has its own independent selection set
    @Published private var selections: [SelectionContext: Set<String>] = [:]
    @Published private var lastSelectedID: [SelectionContext: String] = [:]  // For range selection

    // Undo buffer for bulk deletions
    @Published private var undoBuffer: [UndoEntry] = []
    private let maxUndoEntries = 5
    private let undoEntryLifetime: TimeInterval = 10.0  // seconds

    private init() {}

    /// Represents a batch of deleted items that can be restored
    struct UndoEntry {
        let id = UUID()
        let context: SelectionContext
        let itemIDs: [String]
        let restoreAction: @MainActor () -> Void
        let createdAt: Date
    }

    // MARK: - Public API

    func selection(for context: SelectionContext) -> Set<String> {
        selections[context] ?? []
    }

    func selectedCount(for context: SelectionContext) -> Int {
        selections[context]?.count ?? 0
    }

    func isSelected(_ id: String, in context: SelectionContext) -> Bool {
        selections[context]?.contains(id) ?? false
    }

    func select(_ id: String, in context: SelectionContext) {
        var set = selections[context] ?? []
        set.insert(id)
        selections[context] = set
        lastSelectedID[context] = id
    }

    // For range selection, we need ordered access - convert to array for .last
    private func orderedSelection(for context: SelectionContext) -> [String] {
        Array(selections[context] ?? [])
    }

    func deselect(_ id: String, in context: SelectionContext) {
        var set = selections[context] ?? []
        set.remove(id)
        selections[context] = set
        if lastSelectedID[context] == id {
            lastSelectedID[context] = orderedSelection(for: context).last
        }
    }

    func toggle(_ id: String, in context: SelectionContext) {
        if isSelected(id, in: context) {
            deselect(id, in: context)
        } else {
            select(id, in: context)
        }
    }

    func selectAll(_ ids: [String], in context: SelectionContext) {
        selections[context] = Set(ids)
        lastSelectedID[context] = ids.last ?? nil
    }

    func deselectAll(in context: SelectionContext) {
        selections[context] = []
        lastSelectedID[context] = nil
    }

    func selectRange(from startID: String, to endID: String, in allIDs: [String], context: SelectionContext) {
        guard let startIndex = allIDs.firstIndex(of: startID),
              let endIndex = allIDs.firstIndex(of: endID) else { return }

        let range = (min(startIndex, endIndex)...max(startIndex, endIndex))
        var set = selections[context] ?? []
        set.formUnion(allIDs[range])
        selections[context] = set
        lastSelectedID[context] = endID
    }

    func handleClick(id: String, in allIDs: [String], context: SelectionContext, modifierFlags: NSEvent.ModifierFlags) {
        let isCmd = modifierFlags.contains(.command)
        let isShift = modifierFlags.contains(.shift)

        if isShift, let lastID = lastSelectedID[context] {
            selectRange(from: lastID, to: id, in: allIDs, context: context)
        } else if isCmd {
            toggle(id, in: context)
        } else {
            // Single selection - replace all
            select(id, in: context)
        }
    }

    func clear(context: SelectionContext) {
        selections.removeValue(forKey: context)
        lastSelectedID.removeValue(forKey: context)
    }

    // MARK: - Undo Support

    /// Registers a batch of deleted items for potential undo
    /// - Parameters:
    ///   - itemIDs: The IDs of deleted items
    ///   - context: The selection context
    ///   - restoreAction: Closure that restores the deleted items
    func registerUndo(itemIDs: [String], context: SelectionContext, restoreAction: @escaping @MainActor () -> Void) {
        let entry = UndoEntry(
            context: context,
            itemIDs: itemIDs,
            restoreAction: restoreAction,
            createdAt: Date()
        )
        undoBuffer.append(entry)

        // Limit buffer size
        if undoBuffer.count > maxUndoEntries {
            undoBuffer.removeFirst(undoBuffer.count - maxUndoEntries)
        }

        // Auto-cleanup expired entries
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(undoEntryLifetime * 1_000_000_000))
            cleanupExpiredEntries()
        }
    }

    /// Cleans up expired undo entries
    private func cleanupExpiredEntries() {
        let now = Date()
        undoBuffer.removeAll { now.timeIntervalSince($0.createdAt) > undoEntryLifetime }
    }

    /// Returns the most recent undo entry for a context, if available and not expired
    func peekUndo(for context: SelectionContext) -> UndoEntry? {
        cleanupExpiredEntries()
        return undoBuffer.last { $0.context == context }
    }

    /// Performs undo for the most recent deletion in the given context
    /// Returns true if undo was performed
    @discardableResult
    func undoLastDelete(in context: SelectionContext) -> Bool {
        cleanupExpiredEntries()
        guard let index = undoBuffer.lastIndex(where: { $0.context == context }) else { return false }
        let entry = undoBuffer.remove(at: index)
        entry.restoreAction()
        return true
    }

    /// Clears all undo entries for a specific context
    func clearUndo(for context: SelectionContext) {
        undoBuffer.removeAll { $0.context == context }
    }

    /// Clears all undo entries
    func clearAllUndo() {
        undoBuffer.removeAll()
    }

    // MARK: - Binding Helpers

    /// Returns a Binding<Bool> for use with Toggle/Checkbox
    func binding(for id: String, in context: SelectionContext) -> Binding<Bool> {
        Binding(
            get: { self.isSelected(id, in: context) },
            set: { newValue in
                if newValue { self.select(id, in: context) }
                else { self.deselect(id, in: context) }
            }
        )
    }
}

/// Identifies which view/section the selection belongs to
enum SelectionContext: String, CaseIterable, Hashable {
    case library
    case watchlist
    case favorites
    case downloads
    case history
    case feed

    var displayName: String {
        switch self {
        case .library: return "Library"
        case .watchlist: return "Watchlist"
        case .favorites: return "Favorites"
        case .downloads: return "Downloads"
        case .history: return "History"
        case .feed: return "Feed"
        }
    }
}

/// Convenience view modifier to inject SelectionManager
struct SelectionEnvironmentKey: EnvironmentKey {
    @MainActor static let defaultValue: SelectionManager = SelectionManager.shared
}

extension EnvironmentValues {
    var selectionManager: SelectionManager {
        get { self[SelectionEnvironmentKey.self] }
        set { self[SelectionEnvironmentKey.self] = newValue }
    }
}