import Foundation

/// Browser-style history of folder places. Back is unavailable on the first
/// place. Forward is unavailable until the user goes back. A new place after
/// Back drops the places that were ahead.
public struct FolderHistory<Location: Equatable> {
    private var entries: [Location] = []
    private var index = 0

    public init() {}

    public var canGoBack: Bool { entries.indices.contains(index) && index > 0 }
    public var canGoForward: Bool { entries.indices.contains(index) && index + 1 < entries.count }

    public var current: Location? {
        guard entries.indices.contains(index) else { return nil }
        return entries[index]
    }

    public mutating func clear() {
        entries = []
        index = 0
    }

    public mutating func reset(to location: Location) {
        entries = [location]
        index = 0
    }

    public mutating func push(_ location: Location) {
        if entries.isEmpty {
            entries = [location]
            index = 0
            return
        }
        if entries[index] == location { return }
        if index + 1 < entries.count {
            entries.removeSubrange((index + 1)...)
        }
        entries.append(location)
        index = entries.count - 1
    }

    @discardableResult
    public mutating func back() -> Location? {
        guard canGoBack else { return nil }
        index -= 1
        return entries[index]
    }

    @discardableResult
    public mutating func forward() -> Location? {
        guard canGoForward else { return nil }
        index += 1
        return entries[index]
    }

    /// Drops entries matching `shouldRemove` (e.g. after a folder is trashed),
    /// keeping the current index valid and collapsing any newly-adjacent duplicates.
    public mutating func removeAll(where shouldRemove: (Location) -> Bool) {
        guard !entries.isEmpty else { return }
        var kept: [Location] = []
        kept.reserveCapacity(entries.count)
        var newIndex = 0
        var assignedIndex = false

        for (i, entry) in entries.enumerated() {
            if shouldRemove(entry) {
                continue
            }
            if kept.last != entry {
                kept.append(entry)
            }
            if i <= index {
                newIndex = kept.count - 1
                assignedIndex = true
            }
        }

        entries = kept
        if entries.isEmpty {
            index = 0
        } else {
            index = assignedIndex ? newIndex : 0
        }
    }
}

extension FolderHistory: Sendable where Location: Sendable {}
