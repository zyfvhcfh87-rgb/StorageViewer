import Darwin
import Foundation

public enum TreeEditError: LocalizedError, Equatable, Sendable {
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
    /// Immutable snapshot of a copy operation so disk I/O and directory rescanning
    /// can execute safely off the main actor before attaching the result to the tree.
    public struct CopyPlan: Sendable {
        public let sourceURL: URL
        public let sourceFileID: FileIdentity?
        public let destinationDirectoryURL: URL
        public let destinationDirectoryFileID: FileIdentity?
        public let preferredName: String
        public let isDirectory: Bool
    }

    public static func validateName(_ rawName: String) -> TreeEditError? {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { return .emptyName }
        if name.contains("/") { return .slashInName }
        if name == "." || name == ".." || name.contains("\0") {
            return .failed("That name isn’t allowed.")
        }
        return nil
    }

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
        if let error = validateName(rawName) { throw error }
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parent = node.parent else { throw TreeEditError.missingItem }
        if name == node.name { return }

        let source = try requireSameFile(url: url(of: node, rootURL: rootURL), recordedID: node.fileID)
        let destination = parentURL(of: node, rootURL: rootURL).appendingPathComponent(name)
        var destInfo = stat()
        if lstat(destination.path, &destInfo) == 0 {
            let isCaseOnlyRename =
                FileIdentity(destInfo) == source.identity &&
                node.name.caseInsensitiveCompare(name) == .orderedSame
            if !isCaseOnlyRename {
                throw TreeEditError.failed("“\(name)” is already in this folder.")
            }
        }
        do {
            try FileManager.default.moveItem(at: source.url, to: destination)
        } catch {
            throw TreeEditError.failed((error as NSError).localizedDescription)
        }

        node.name = name
        if !node.isDirectory {
            let oldCategory = node.category
            let newCategory = FileCategory.classify(name: name)
            node.category = newCategory
            if oldCategory != newCategory, node.byteSize > 0 {
                var delta = CategoryTotals()
                delta[oldCategory] = -node.byteSize
                delta[newCategory] = node.byteSize
                propagate(delta, byteDelta: 0, from: parent)
            }
        }
        parent.sortChildren()
    }

    public static func prepareDuplicate(_ node: FileNode, rootURL: URL) throws -> (folder: FileNode, plan: CopyPlan) {
        guard let parent = node.parent else { throw TreeEditError.missingItem }
        return (parent, makeCopyPlan(of: node, into: parent, rootURL: rootURL))
    }

    public static func preparePaste(_ copied: FileNode, onto target: FileNode, rootURL: URL) throws -> (folder: FileNode, plan: CopyPlan) {
        guard copied.parent != nil, let destination = receiver(for: target) else {
            throw TreeEditError.missingItem
        }
        if copied.isDirectory && copied.contains(destination) {
            throw TreeEditError.cannotPasteHere
        }
        return (destination, makeCopyPlan(of: copied, into: destination, rootURL: rootURL))
    }

    /// Executes disk copy + scan for `plan` without touching any existing `FileNode`.
    public static func executeCopy(_ plan: CopyPlan) throws -> FileNode {
        let source = try requireSameFile(url: plan.sourceURL, recordedID: plan.sourceFileID)
        _ = try requireSameFile(url: plan.destinationDirectoryURL, recordedID: plan.destinationDirectoryFileID)

        let name = uniqueName(
            in: plan.destinationDirectoryURL,
            preferred: plan.preferredName,
            isDirectory: plan.isDirectory
        )
        let destination = plan.destinationDirectoryURL.appendingPathComponent(name)
        do {
            try FileManager.default.copyItem(at: source.url, to: destination)
        } catch {
            throw TreeEditError.failed((error as NSError).localizedDescription)
        }

        if plan.isDirectory {
            let outcome = DirectoryScanner.scan(url: destination, displayName: name)
            guard let scanned = outcome.root else {
                try? FileManager.default.trashItem(at: destination, resultingItemURL: nil)
                throw TreeEditError.failed("The copy was made, but macOS wouldn’t let StorageViewer read it.")
            }
            return scanned
        }

        var info = stat()
        guard lstat(destination.path, &info) == 0 else {
            throw TreeEditError.failed("The copy was made, but its size couldn’t be read.")
        }
        return FileNode(
            name: name,
            isDirectory: false,
            byteSize: max(0, Int64(info.st_size)),
            category: FileCategory.classify(name: name),
            fileID: FileIdentity(info)
        )
    }

    public static func attachCopy(_ created: FileNode, to folder: FileNode) {
        folder.children.append(created)
        created.parent = folder
        propagate(created.effectiveTotals, byteDelta: created.byteSize, from: folder)
        if created.byteSize == 0 {
            folder.sortChildren()
        }
    }

    @discardableResult
    public static func duplicate(_ node: FileNode, rootURL: URL) throws -> FileNode {
        let (folder, plan) = try prepareDuplicate(node, rootURL: rootURL)
        let created = try executeCopy(plan)
        attachCopy(created, to: folder)
        return created
    }

    @discardableResult
    public static func paste(_ copied: FileNode, onto target: FileNode, rootURL: URL) throws -> FileNode {
        let (folder, plan) = try preparePaste(copied, onto: target, rootURL: rootURL)
        let created = try executeCopy(plan)
        attachCopy(created, to: folder)
        return created
    }

    @discardableResult
    public static func trash(_ node: FileNode, rootURL: URL) throws -> URL? {
        guard let parent = node.parent else { throw TreeEditError.missingItem }
        let source = try requireSameFile(url: url(of: node, rootURL: rootURL), recordedID: node.fileID)
        var resultingURL: NSURL?
        do {
            try FileManager.default.trashItem(at: source.url, resultingItemURL: &resultingURL)
        } catch {
            throw TreeEditError.failed((error as NSError).localizedDescription)
        }
        let totals = node.effectiveTotals
        let removedBytes = node.byteSize
        parent.children.removeAll { $0 === node || $0.id == node.id }
        node.parent = nil
        propagate(totals.negated(), byteDelta: -removedBytes, from: parent)
        return resultingURL as URL?
    }

    private static func makeCopyPlan(of node: FileNode, into folder: FileNode, rootURL: URL) -> CopyPlan {
        CopyPlan(
            sourceURL: url(of: node, rootURL: rootURL),
            sourceFileID: node.fileID,
            destinationDirectoryURL: url(of: folder, rootURL: rootURL),
            destinationDirectoryFileID: folder.fileID,
            preferredName: node.name,
            isDirectory: node.isDirectory
        )
    }

    private struct LocatedFile {
        var url: URL
        var identity: FileIdentity
    }

    /// The path still has to be the file that was scanned.
    private static func requireSameFile(url source: URL, recordedID: FileIdentity?) throws -> LocatedFile {
        var info = stat()
        guard lstat(source.path, &info) == 0 else {
            throw TreeEditError.failed("That item changed on disk. Scan again.")
        }
        let identity = FileIdentity(info)
        if let recordedID, recordedID != identity {
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

    private static func propagate(_ delta: CategoryTotals, byteDelta: Int64, from folder: FileNode) {
        var current: FileNode? = folder
        while let node = current {
            if node.isDirectory {
                node.applyCategoryDelta(delta)
                node.category = node.categoryTotals.dominantCategory
                if byteDelta != 0 {
                    node.byteSize = max(0, saturatingAdd(node.byteSize, byteDelta))
                    node.sortChildren()
                }
            }
            current = node.parent
        }
    }

    static func uniqueName(in directory: URL, preferred: String, isDirectory: Bool) -> String {
        if !entryExists(atPath: directory.appendingPathComponent(preferred).path) {
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
            if !entryExists(atPath: directory.appendingPathComponent(candidate).path) {
                return candidate
            }
            number += 1
        }
    }

    /// Checks whether a directory entry exists without following symlinks (detects broken symlinks too).
    private static func entryExists(atPath path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0
    }
}
