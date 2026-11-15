import Foundation

/// Browser-style history of folder places. Back is unavailable on the first
/// place. Forward is unavailable until the user goes back. A new place after
/// Back drops the places that were ahead.
public struct FolderHistory<Location: Equatable> {
    private var entries: [Location] = []
    private var index = 0

    public init() {}

    public var canGoBack: Bool { entries.indices.contains(index) && index > 0 }
    public var canGoForward: Bool { index + 1 < entries.count }

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
}
