import Darwin
import Foundation

public enum TreeEditError: LocalizedError, Equatable, Sendable {
    case emptyName
    case slashInName
    case missingItem
    case cannotPasteHere
    case mountPoint
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .emptyName:
            return "The name can’t be empty."
        case .slashInName:
            return "The name can’t contain /."
        case .missingItem:
            return "That item is no longer in this scan."
        case .cannotPasteHere:
            return "A folder can’t be pasted into itself."
        case .mountPoint:
            return "That folder is another volume. StorageViewer doesn’t change it."
        case .failed(let message):
            return message
        }
    }
}

public enum TreeEditor {
    public static func url(of node: FileNode, rootURL: URL) -> URL {
        var names: [String] = []
        var current: FileNode? = node
        while let item = current, item.parent != nil {
            names.append(item.name)
            current = item.parent
        }
        return names.reversed().reduce(rootURL) { $0.appendingPathComponent($1) }
    }

    public static func canPaste(_ copied: FileNode, onto target: FileNode) -> Bool {
        guard copied.parent != nil, !copied.isMount, let destination = receiver(for: target) else { return false }
        if destination.isMount { return false }
        if copied.isDirectory && copied.contains(destination) { return false }
        return true
    }

    public static func rename(_ node: FileNode, to rawName: String, rootURL: URL) throws {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { throw TreeEditError.emptyName }
        if name.contains("/") { throw TreeEditError.slashInName }
        guard let parent = node.parent else { throw TreeEditError.missingItem }
        if node.isMount { throw TreeEditError.mountPoint }
        if name == node.name { return }

        let source = try requireSameFile(node, rootURL: rootURL)
        let destination = parentURL(of: node, rootURL: rootURL).appendingPathComponent(name)
        var destInfo = stat()
        if lstat(destination.path, &destInfo) == 0, FileIdentity(destInfo) != source.identity {
            throw TreeEditError.failed("“\(name)” is already in this folder.")
        }
        do {
            try FileManager.default.moveItem(at: source.url, to: destination)
        } catch {
            throw TreeEditError.failed((error as NSError).localizedDescription)
        }

        let previous = node.subtreeMix
        node.name = name
        if !node.isDirectory {
            node.category = FileCategory.classify(name: name)
            node.subtreeMix = [node.category: node.byteSize]
            var delta = node.subtreeMix
            for (kind, bytes) in previous {
                delta[kind, default: 0] -= bytes
            }
            propagate(delta, from: parent)
        } else {
            sort(parent)
        }
    }

    @discardableResult
    public static func duplicate(_ node: FileNode, rootURL: URL) throws -> FileNode {
        let work = try prepareDuplicate(node, rootURL: rootURL)
        return try finishCopy(work)
    }

    @discardableResult
    public static func paste(_ copied: FileNode, onto target: FileNode, rootURL: URL) throws -> FileNode {
        let work = try preparePaste(copied, onto: target, rootURL: rootURL)
        return try finishCopy(work)
    }

    /// Disk work for one copy. `prepare` touches only the tree and cheap `stat` calls;
    /// `performCopy` does the slow copy and scan and may run on any thread;
    /// `attachCopy` puts the result into the tree and must run where the tree is owned.
    public struct CopyWork: Sendable {
        public var sourceURL: URL
        public var directoryURL: URL
        public var destinationURL: URL
        public var name: String
        public var isDirectory: Bool
        public var folder: FileNode
    }

    public static func prepareDuplicate(_ node: FileNode, rootURL: URL) throws -> CopyWork {
        guard let parent = node.parent else { throw TreeEditError.missingItem }
        if node.isMount { throw TreeEditError.mountPoint }
        return try makeCopyWork(of: node, in: parent, rootURL: rootURL)
    }

    public static func preparePaste(_ copied: FileNode, onto target: FileNode, rootURL: URL) throws -> CopyWork {
        guard copied.parent != nil, let destination = receiver(for: target) else {
            throw TreeEditError.missingItem
        }
        if copied.isMount || destination.isMount { throw TreeEditError.mountPoint }
        if copied.isDirectory && copied.contains(destination) {
            throw TreeEditError.cannotPasteHere
        }
        return try makeCopyWork(of: copied, in: destination, rootURL: rootURL)
    }

    /// Copies on disk and returns the new node, not yet linked into the tree.
    public static func performCopy(_ work: CopyWork) throws -> FileNode {
        do {
            try FileManager.default.copyItem(at: work.sourceURL, to: work.destinationURL)
        } catch {
            throw TreeEditError.failed((error as NSError).localizedDescription)
        }

        if work.isDirectory {
            let outcome = DirectoryScanner.scan(url: work.destinationURL, displayName: work.name)
            guard let scanned = outcome.root else {
                try? FileManager.default.trashItem(at: work.destinationURL, resultingItemURL: nil)
                throw TreeEditError.failed("The copy was made, but macOS wouldn’t let StorageViewer read it.")
            }
            return scanned
        }
        var info = stat()
        guard lstat(work.destinationURL.path, &info) == 0 else {
            throw TreeEditError.failed("The copy was made, but its size couldn’t be read.")
        }
        let file = FileNode(
            name: work.name,
            isDirectory: false,
            byteSize: Int64(info.st_size),
            category: FileCategory.classify(name: work.name),
            fileID: FileIdentity(info)
        )
        file.subtreeMix = [file.category: file.byteSize]
        return file
    }

    public static func attachCopy(_ created: FileNode, to work: CopyWork) {
        let folder = work.folder
        folder.children.append(created)
        created.parent = folder
        propagate(created.subtreeMix, from: folder)
    }

    private static func finishCopy(_ work: CopyWork) throws -> FileNode {
        let created = try performCopy(work)
        attachCopy(created, to: work)
        return created
    }

    public static func trash(_ node: FileNode, rootURL: URL) throws {
        guard let parent = node.parent else { throw TreeEditError.missingItem }
        if node.isMount { throw TreeEditError.mountPoint }
        let source = try requireSameFile(node, rootURL: rootURL)
        do {
            try FileManager.default.trashItem(at: source.url, resultingItemURL: nil)
        } catch {
            throw TreeEditError.failed((error as NSError).localizedDescription)
        }
        let mix = node.subtreeMix
        parent.children.removeAll { $0.id == node.id }
        node.parent = nil
        var delta: [FileCategory: Int64] = [:]
        for (kind, bytes) in mix { delta[kind] = -bytes }
        propagate(delta, from: parent)
    }

    private static func makeCopyWork(of node: FileNode, in folder: FileNode, rootURL: URL) throws -> CopyWork {
        let source = try requireSameFile(node, rootURL: rootURL)
        let directory = url(of: folder, rootURL: rootURL)
        let name = uniqueName(in: directory, preferred: node.name, isDirectory: node.isDirectory)
        return CopyWork(
            sourceURL: source.url,
            directoryURL: directory,
            destinationURL: directory.appendingPathComponent(name),
            name: name,
            isDirectory: node.isDirectory,
            folder: folder
        )
    }

    private struct LocatedFile {
        var url: URL
        var identity: FileIdentity
    }

    /// The path still has to be the file that was scanned.
    private static func requireSameFile(_ node: FileNode, rootURL: URL) throws -> LocatedFile {
        let source = url(of: node, rootURL: rootURL)
        var info = stat()
        guard lstat(source.path, &info) == 0 else {
            throw TreeEditError.failed("That item changed on disk. Scan again.")
        }
        let identity = FileIdentity(info)
        if let recorded = node.fileID, recorded != identity {
            throw TreeEditError.failed("That item changed on disk. Scan again.")
        }
        return LocatedFile(url: source, identity: identity)
    }

    private static func receiver(for target: FileNode) -> FileNode? {
        target.isDirectory ? target : target.parent
    }

    private static func parentURL(of node: FileNode, rootURL: URL) -> URL {
        guard let parent = node.parent else { return rootURL }
        return url(of: parent, rootURL: rootURL)
    }

    private static func propagate(_ delta: [FileCategory: Int64], from folder: FileNode) {
        var current: FileNode? = folder
        while let node = current {
            for (kind, bytes) in delta where bytes != 0 {
                let next = (node.subtreeMix[kind] ?? 0) + bytes
                if next <= 0 {
                    node.subtreeMix.removeValue(forKey: kind)
                } else {
                    node.subtreeMix[kind] = next
                }
            }
            if node.isDirectory {
                node.byteSize = node.children.reduce(0) { $0 + $1.byteSize }
                node.category = FileNode.dominantCategory(node.subtreeMix)
                sort(node)
            }
            current = node.parent
        }
    }

    private static func sort(_ folder: FileNode) {
        folder.children.sort { lhs, rhs in
            if lhs.byteSize != rhs.byteSize { return lhs.byteSize > rhs.byteSize }
            return lhs.name < rhs.name
        }
    }

    private static func uniqueName(in directory: URL, preferred: String, isDirectory: Bool) -> String {
        if !FileManager.default.fileExists(atPath: directory.appendingPathComponent(preferred).path) {
            return preferred
        }
        let ext = (preferred as NSString).pathExtension
        let stem = (!isDirectory && !ext.isEmpty) ? (preferred as NSString).deletingPathExtension : preferred
        func joined(_ stem: String) -> String {
            (!isDirectory && !ext.isEmpty) ? "\(stem).\(ext)" : stem
        }
        var number = 1
        while true {
            let candidate = joined(number == 1 ? "\(stem) copy" : "\(stem) copy \(number)")
            if !FileManager.default.fileExists(atPath: directory.appendingPathComponent(candidate).path) {
                return candidate
            }
            number += 1
        }
    }
}
