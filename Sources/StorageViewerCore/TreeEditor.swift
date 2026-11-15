import Darwin
import Foundation

public enum TreeEditError: LocalizedError, Equatable {
    case emptyName
    case slashInName
    case missingItem
    case cannotPasteHere
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
        guard copied.parent != nil, let destination = receiver(for: target) else { return false }
        if copied.isDirectory && copied.contains(destination) { return false }
        return true
    }

    public static func rename(_ node: FileNode, to rawName: String, rootURL: URL) throws {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { throw TreeEditError.emptyName }
        if name.contains("/") { throw TreeEditError.slashInName }
        guard let parent = node.parent else { throw TreeEditError.missingItem }
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
        guard let parent = node.parent else { throw TreeEditError.missingItem }
        return try placeCopy(of: node, in: parent, rootURL: rootURL)
    }

    @discardableResult
    public static func paste(_ copied: FileNode, onto target: FileNode, rootURL: URL) throws -> FileNode {
        guard copied.parent != nil, let destination = receiver(for: target) else {
            throw TreeEditError.missingItem
        }
        if copied.isDirectory && copied.contains(destination) {
            throw TreeEditError.cannotPasteHere
        }
        return try placeCopy(of: copied, in: destination, rootURL: rootURL)
    }

    public static func trash(_ node: FileNode, rootURL: URL) throws {
        guard let parent = node.parent else { throw TreeEditError.missingItem }
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

    private static func placeCopy(of node: FileNode, in folder: FileNode, rootURL: URL) throws -> FileNode {
        let source = try requireSameFile(node, rootURL: rootURL)
        let directory = url(of: folder, rootURL: rootURL)
        let name = uniqueName(in: directory, preferred: node.name, isDirectory: node.isDirectory)
        let destination = directory.appendingPathComponent(name)
        do {
            try FileManager.default.copyItem(at: source.url, to: destination)
        } catch {
            throw TreeEditError.failed((error as NSError).localizedDescription)
        }

        let created: FileNode
        if node.isDirectory {
            let outcome = DirectoryScanner.scan(url: destination, displayName: name)
            guard let scanned = outcome.root else {
                try? FileManager.default.trashItem(at: destination, resultingItemURL: nil)
                throw TreeEditError.failed("The copy was made, but macOS wouldn’t let StorageViewer read it.")
            }
            created = scanned
        } else {
            var info = stat()
            guard lstat(destination.path, &info) == 0 else {
                throw TreeEditError.failed("The copy was made, but its size couldn’t be read.")
            }
            let file = FileNode(
                name: name,
                isDirectory: false,
                byteSize: Int64(info.st_size),
                category: FileCategory.classify(name: name),
                fileID: FileIdentity(info)
            )
            file.subtreeMix = [file.category: file.byteSize]
            created = file
        }

        folder.children.append(created)
        created.parent = folder
        propagate(created.subtreeMix, from: folder)
        return created
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

    static func uniqueName(in directory: URL, preferred: String, isDirectory: Bool) -> String {
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
