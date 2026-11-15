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

/// A folder or file in the scanned tree.
/// Reference type so browsing a large disk does not copy the whole tree on every click.
public final class FileNode: Identifiable, @unchecked Sendable {
    public let id: UUID
    public var name: String
    public let isDirectory: Bool
    public var byteSize: Int64
    public var category: FileCategory
    public var children: [FileNode]
    /// Bytes of each file type inside this item. Kept in step when a file is renamed, copied, or trashed.
    public var subtreeMix: [FileCategory: Int64] = [:]
    /// Nil when the scan could not read an identity. Edits then still use the path.
    public var fileID: FileIdentity?
    public internal(set) weak var parent: FileNode?

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
        var mix: [FileCategory: Int64] = [:]
        for child in children {
            child.parent = self
            child.linkParents()
            for (kind, bytes) in child.subtreeMix {
                mix[kind, default: 0] += bytes
            }
        }
        if isDirectory {
            subtreeMix = mix
            category = Self.dominantCategory(mix)
        } else {
            subtreeMix = [category: byteSize]
        }
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
            if node.id == id { return true }
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
