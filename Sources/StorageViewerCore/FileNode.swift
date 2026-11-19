import Darwin
import Foundation

/// Device and inode of the file that was scanned.
/// Rename, copy, and Trash use this so a newer file that reused the name is left alone.
public struct FileIdentity: Equatable, Sendable {
    public var device: UInt64
    public var inode: UInt64

    public init(device: UInt64, inode: UInt64) {
        self.device = device
        self.inode = inode
    }

    public init(_ info: stat) {
        device = UInt64(UInt32(truncatingIfNeeded: info.st_dev))
        inode = UInt64(truncatingIfNeeded: info.st_ino)
    }
}

/// Fixed-size per-category byte counts, avoiding per-node heap dictionary allocations.
struct CategoryTotals: Equatable, Sendable {
    var code: Int64 = 0
    var images: Int64 = 0
    var video: Int64 = 0
    var audio: Int64 = 0
    var archives: Int64 = 0
    var documents: Int64 = 0
    var other: Int64 = 0

    init() {}

    init(category: FileCategory, bytes: Int64) {
        self[category] = bytes
    }

    init(dictionary: [FileCategory: Int64]) {
        for (kind, bytes) in dictionary {
            self[kind] = bytes
        }
    }

    subscript(_ category: FileCategory) -> Int64 {
        get {
            switch category {
            case .code: code
            case .images: images
            case .video: video
            case .audio: audio
            case .archives: archives
            case .documents: documents
            case .other: other
            }
        }
        set {
            switch category {
            case .code: code = newValue
            case .images: images = newValue
            case .video: video = newValue
            case .audio: audio = newValue
            case .archives: archives = newValue
            case .documents: documents = newValue
            case .other: other = newValue
            }
        }
    }

    mutating func add(_ other: CategoryTotals) {
        code = saturatingAdd(code, other.code)
        images = saturatingAdd(images, other.images)
        video = saturatingAdd(video, other.video)
        audio = saturatingAdd(audio, other.audio)
        archives = saturatingAdd(archives, other.archives)
        documents = saturatingAdd(documents, other.documents)
        self.other = saturatingAdd(self.other, other.other)
    }

    mutating func add(_ category: FileCategory, bytes: Int64) {
        self[category] = saturatingAdd(self[category], bytes)
    }

    mutating func applyDelta(_ delta: CategoryTotals) {
        code = max(0, saturatingAdd(code, delta.code))
        images = max(0, saturatingAdd(images, delta.images))
        video = max(0, saturatingAdd(video, delta.video))
        audio = max(0, saturatingAdd(audio, delta.audio))
        archives = max(0, saturatingAdd(archives, delta.archives))
        documents = max(0, saturatingAdd(documents, delta.documents))
        other = max(0, saturatingAdd(other, delta.other))
    }

    func negated() -> CategoryTotals {
        var copy = CategoryTotals()
        copy.code = code == .min ? .max : -code
        copy.images = images == .min ? .max : -images
        copy.video = video == .min ? .max : -video
        copy.audio = audio == .min ? .max : -audio
        copy.archives = archives == .min ? .max : -archives
        copy.documents = documents == .min ? .max : -documents
        copy.other = other == .min ? .max : -other
        return copy
    }

    var dominantCategory: FileCategory {
        var best = FileCategory.other
        var bestValue: Int64 = 0
        for kind in FileCategory.allCases {
            let value = self[kind]
            if value > bestValue {
                bestValue = value
                best = kind
            }
        }
        return bestValue > 0 ? best : .other
    }

    func toDictionary() -> [FileCategory: Int64] {
        var mix: [FileCategory: Int64] = [:]
        for kind in FileCategory.allCases {
            let value = self[kind]
            if value != 0 {
                mix[kind] = value
            }
        }
        return mix
    }
}

func saturatingAdd(_ lhs: Int64, _ rhs: Int64) -> Int64 {
    let (result, overflow) = lhs.addingReportingOverflow(rhs)
    if overflow {
        return rhs >= 0 ? Int64.max : Int64.min
    }
    return result
}

/// Compact heap box allocated only on directory nodes so leaf files stay small in cache.
final class DirectoryTotals: @unchecked Sendable {
    var totals: CategoryTotals

    init(_ totals: CategoryTotals = CategoryTotals()) {
        self.totals = totals
    }
}

/// A folder or file in the scanned tree.
/// Reference type so browsing a large disk does not copy the whole tree on every click.
public final class FileNode: Identifiable, @unchecked Sendable {
    public let id: UUID
    public var name: String
    public let isDirectory: Bool
    public var byteSize: Int64
    public var category: FileCategory
    public var children: [FileNode]
    /// Nil when the scan could not read an identity. Edits then still use the path.
    public var fileID: FileIdentity?
    public internal(set) weak var parent: FileNode?

    private var directoryTotals: DirectoryTotals?

    var categoryTotals: CategoryTotals {
        get { directoryTotals?.totals ?? CategoryTotals() }
        set {
            if let box = directoryTotals {
                box.totals = newValue
            } else {
                directoryTotals = DirectoryTotals(newValue)
            }
        }
    }

    func applyCategoryDelta(_ delta: CategoryTotals) {
        if let box = directoryTotals {
            box.totals.applyDelta(delta)
        } else {
            var totals = CategoryTotals()
            totals.applyDelta(delta)
            directoryTotals = DirectoryTotals(totals)
        }
    }

    /// Bytes of each file type inside this item. Kept in step when a file is renamed, copied, or trashed.
    public var subtreeMix: [FileCategory: Int64] {
        get {
            if isDirectory {
                return directoryTotals?.totals.toDictionary() ?? [:]
            }
            return [category: byteSize]
        }
        set {
            if isDirectory {
                categoryTotals = CategoryTotals(dictionary: newValue)
            }
        }
    }

    var effectiveTotals: CategoryTotals {
        isDirectory ? categoryTotals : CategoryTotals(category: category, bytes: byteSize)
    }

    public init(
        id: UUID = UUID(),
        name: String,
        isDirectory: Bool,
        byteSize: Int64,
        category: FileCategory,
        children: [FileNode] = [],
        fileID: FileIdentity? = nil
    ) {
        self.id = id
        self.name = name
        self.isDirectory = isDirectory
        self.byteSize = byteSize
        self.category = category
        self.children = children
        self.fileID = fileID
    }

    /// Parent links are weak, so they have to be wired after the root is retained.
    /// A weak reference formed inside `init` is dropped immediately.
    public func linkParents() {
        guard isDirectory else { return }
        var totals = CategoryTotals()
        for child in children {
            child.parent = self
            child.linkParents()
            totals.add(child.effectiveTotals)
        }
        categoryTotals = totals
        category = totals.dominantCategory
    }

    public func sortChildren() {
        children.sort { lhs, rhs in
            if lhs.byteSize != rhs.byteSize { return lhs.byteSize > rhs.byteSize }
            return lhs.name < rhs.name
        }
    }

    /// Counts non-directory file nodes in this subtree iteratively.
    public func fileCount() -> Int {
        if !isDirectory { return 1 }
        var total = 0
        var stack: [FileNode] = children
        while let node = stack.popLast() {
            if node.isDirectory {
                stack.append(contentsOf: node.children)
            } else {
                total += 1
            }
        }
        return total
    }

    public static func dominantCategory(_ mix: [FileCategory: Int64]) -> FileCategory {
        var best = FileCategory.other
        var bestValue: Int64 = 0
        for kind in FileCategory.allCases {
            let value = mix[kind] ?? 0
            if value > bestValue {
                bestValue = value
                best = kind
            }
        }
        return bestValue > 0 ? best : .other
    }

    public func contains(_ other: FileNode) -> Bool {
        var cursor: FileNode? = other
        while let node = cursor {
            if node === self || node.id == id { return true }
            cursor = node.parent
        }
        return false
    }

    /// Root first, this node last. Walks parent links, so it stays cheap on a large disk.
    public func pathFromRoot() -> [FileNode] {
        var nodes = [self]
        var current = self
        while let parent = current.parent {
            nodes.append(parent)
            current = parent
        }
        return nodes.reversed()
    }
}
