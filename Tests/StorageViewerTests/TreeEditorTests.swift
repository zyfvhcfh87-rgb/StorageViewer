import Darwin
import Foundation
import StorageViewerCore
import XCTest

final class TreeEditorTests: XCTestCase {
    func testRenameCopyPasteDuplicateAndTrashMatchTheDisk() throws {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("StorageViewer-TreeEditor-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch.appendingPathComponent("dest"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        try Data(repeating: 1, count: 20).write(to: scratch.appendingPathComponent("alpha.txt"))
        try Data(repeating: 2, count: 10).write(to: scratch.appendingPathComponent("beta.txt"))
        try Data(repeating: 3, count: 5).write(to: scratch.appendingPathComponent("dest/inside.txt"))

        let outcome = DirectoryScanner.scan(url: scratch, displayName: "ScratchOps")
        let root = try XCTUnwrap(outcome.root)

        let alpha = try XCTUnwrap(root.children.first { $0.name == "alpha.txt" })
        XCTAssertThrowsError(try TreeEditor.rename(alpha, to: "   ", rootURL: scratch))
        XCTAssertThrowsError(try TreeEditor.rename(alpha, to: "bad/name", rootURL: scratch))
        XCTAssertThrowsError(try TreeEditor.rename(alpha, to: ".", rootURL: scratch))
        XCTAssertThrowsError(try TreeEditor.rename(alpha, to: "..", rootURL: scratch))
        XCTAssertThrowsError(try TreeEditor.rename(alpha, to: "bad\0name", rootURL: scratch))
        XCTAssertTrue(FileManager.default.fileExists(atPath: scratch.appendingPathComponent("alpha.txt").path))

        try TreeEditor.rename(alpha, to: "renamed.txt", rootURL: scratch)
        XCTAssertEqual(alpha.name, "renamed.txt")
        XCTAssertFalse(FileManager.default.fileExists(atPath: scratch.appendingPathComponent("alpha.txt").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: scratch.appendingPathComponent("renamed.txt").path))

        let dest = try XCTUnwrap(root.children.first { $0.name == "dest" })
        let pasted = try TreeEditor.paste(alpha, onto: dest, rootURL: scratch)
        XCTAssertEqual(pasted.name, "renamed.txt")
        XCTAssertEqual(pasted.parent?.id, dest.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: scratch.appendingPathComponent("dest/renamed.txt").path))

        let again = try TreeEditor.paste(alpha, onto: dest, rootURL: scratch)
        XCTAssertEqual(again.name, "renamed copy.txt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: scratch.appendingPathComponent("dest/renamed copy.txt").path))

        let beta = try XCTUnwrap(root.children.first { $0.name == "beta.txt" })
        let twin = try TreeEditor.duplicate(beta, rootURL: scratch)
        XCTAssertEqual(twin.name, "beta copy.txt")
        XCTAssertEqual(twin.parent?.id, root.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: scratch.appendingPathComponent("beta copy.txt").path))

        let beforeTrash = root.byteSize
        let trashedURL = try TreeEditor.trash(twin, rootURL: scratch)
        defer {
            if let trashedURL { try? FileManager.default.removeItem(at: trashedURL) }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: scratch.appendingPathComponent("beta copy.txt").path))
        XCTAssertNil(root.children.first { $0.name == "beta copy.txt" })
        XCTAssertEqual(root.byteSize, beforeTrash - 10)
        XCTAssertEqual(root.byteSize, root.children.reduce(0) { $0 + $1.byteSize })
        XCTAssertEqual(dest.byteSize, dest.children.reduce(0) { $0 + $1.byteSize })
        XCTAssertEqual(try diskBytes(scratch), root.byteSize)
        XCTAssertEqual(Set(try names(scratch)), Set(root.children.map(\.name)))
        XCTAssertEqual(Set(try names(scratch.appendingPathComponent("dest"))), Set(dest.children.map(\.name)))
    }

    func testCaseOnlyRenameAndAReplacedFileIsLeftAlone() throws {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("StorageViewer-Case-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let report = scratch.appendingPathComponent("Report.pdf")
        try Data("old".utf8).write(to: report)
        try Data("keep".utf8).write(to: scratch.appendingPathComponent("other.txt"))

        let outcome = DirectoryScanner.scan(url: scratch, displayName: "case")
        let root = try XCTUnwrap(outcome.root)
        let node = try XCTUnwrap(root.children.first { $0.name == "Report.pdf" })
        let other = try XCTUnwrap(root.children.first { $0.name == "other.txt" })

        XCTAssertThrowsError(try TreeEditor.rename(node, to: "other.txt", rootURL: scratch))
        XCTAssertTrue(FileManager.default.fileExists(atPath: report.path))

        try TreeEditor.rename(node, to: "report.pdf", rootURL: scratch)
        XCTAssertEqual(node.name, "report.pdf")
        let renamed = scratch.appendingPathComponent("report.pdf")
        XCTAssertEqual(try Data(contentsOf: renamed), Data("old".utf8))

        try FileManager.default.removeItem(at: renamed)
        try Data("new".utf8).write(to: renamed)
        XCTAssertThrowsError(try TreeEditor.trash(node, rootURL: scratch)) {
            XCTAssertEqual($0.localizedDescription, "That item changed on disk. Scan again.")
        }
        XCTAssertEqual(try Data(contentsOf: renamed), Data("new".utf8))

        XCTAssertThrowsError(try TreeEditor.duplicate(node, rootURL: scratch))
        XCTAssertNil(root.children.first { $0.name == "report copy.pdf" })
        XCTAssertFalse(FileManager.default.fileExists(atPath: scratch.appendingPathComponent("report copy.pdf").path))
        XCTAssertEqual(other.name, "other.txt")
    }

    func testDuplicatingDirectoryProducesUniqueNodeIdentifiers() throws {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("StorageViewer-DupDir-\(UUID().uuidString)", isDirectory: true)
        let folderURL = scratch.appendingPathComponent("album", isDirectory: true)
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        try Data(repeating: 4, count: 120).write(to: folderURL.appendingPathComponent("cover.png"))

        let outcome = DirectoryScanner.scan(url: scratch, displayName: "dup")
        let root = try XCTUnwrap(outcome.root)
        let album = try XCTUnwrap(root.children.first { $0.name == "album" })
        let originalIDs = collectIDs(root)

        let copy = try TreeEditor.duplicate(album, rootURL: scratch)
        let copyIDs = collectIDs(copy)
        XCTAssertEqual(copy.name, "album copy")
        XCTAssertTrue(originalIDs.isDisjoint(with: copyIDs), "Copied directory must not reuse UUIDs from the original scan")
        XCTAssertEqual(root.children.count, 2)
        XCTAssertEqual(Set(root.children.map(\.id)).count, 2)
        XCTAssertEqual(root.byteSize, 240)
        XCTAssertEqual(root.fileCount(), 2)
    }

    func testRenameUpdatesCategoryMixAndRejectsHardLinkClobber() throws {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("StorageViewer-Cat-\(UUID().uuidString)", isDirectory: true)
        let sub = scratch.appendingPathComponent("sub", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let file = sub.appendingPathComponent("notes.txt")
        let hardlink = sub.appendingPathComponent("alias.txt")
        try Data(repeating: 1, count: 100).write(to: file)
        XCTAssertEqual(link(file.path, hardlink.path), 0)

        let root = try XCTUnwrap(DirectoryScanner.scan(url: scratch, displayName: "cat").root)
        let subNode = try XCTUnwrap(root.children.first { $0.name == "sub" })
        let notesNode = try XCTUnwrap(subNode.children.first { $0.name == "notes.txt" })
        XCTAssertEqual(subNode.category, .documents)
        XCTAssertEqual(root.category, .documents)

        // Hard-linked sibling shares inode, but has a different name and must not be overwritten.
        XCTAssertThrowsError(try TreeEditor.rename(notesNode, to: "alias.txt", rootURL: scratch))

        // Renaming notes.txt -> main.swift flips category to .code; tie-breaking prefers .code over .documents.
        try TreeEditor.rename(notesNode, to: "main.swift", rootURL: scratch)
        XCTAssertEqual(notesNode.category, .code)
        XCTAssertEqual(subNode.subtreeMix[.code], 100)
        XCTAssertEqual(subNode.subtreeMix[.documents], 100)
        XCTAssertEqual(subNode.category, .code)
        XCTAssertEqual(root.category, .code)
        XCTAssertEqual(root.byteSize, 200)
    }

    func testCopyAvoidsCollidingWithBrokenSymlink() throws {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("StorageViewer-BrokenLink-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        try Data("hello".utf8).write(to: scratch.appendingPathComponent("item.txt"))
        try FileManager.default.createSymbolicLink(
            atPath: scratch.appendingPathComponent("item copy.txt").path,
            withDestinationPath: "/nonexistent/target/path"
        )

        let root = try XCTUnwrap(DirectoryScanner.scan(url: scratch, displayName: "broken").root)
        let item = try XCTUnwrap(root.children.first { $0.name == "item.txt" })
        let twin = try TreeEditor.duplicate(item, rootURL: scratch)
        XCTAssertEqual(twin.name, "item copy 2.txt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: scratch.appendingPathComponent("item copy 2.txt").path))
    }

    private func collectIDs(_ node: FileNode) -> Set<UUID> {
        var ids: Set<UUID> = [node.id]
        for child in node.children {
            ids.formUnion(collectIDs(child))
        }
        return ids
    }

    func testMountNodesAreNotEdited() throws {
        let mount = FileNode(name: "Other", isDirectory: true, byteSize: 0, category: .other, isMount: true)
        let file = FileNode(name: "a.txt", isDirectory: false, byteSize: 1, category: .documents)
        let root = FileNode(name: "root", isDirectory: true, byteSize: 1, category: .documents, children: [mount, file])
        root.linkParents()
        let rootURL = FileManager.default.temporaryDirectory

        XCTAssertThrowsError(try TreeEditor.rename(mount, to: "renamed", rootURL: rootURL)) {
            XCTAssertEqual($0 as? TreeEditError, .mountPoint)
        }
        XCTAssertThrowsError(try TreeEditor.trash(mount, rootURL: rootURL)) {
            XCTAssertEqual($0 as? TreeEditError, .mountPoint)
        }
        XCTAssertThrowsError(try TreeEditor.duplicate(mount, rootURL: rootURL)) {
            XCTAssertEqual($0 as? TreeEditError, .mountPoint)
        }
        XCTAssertFalse(TreeEditor.canPaste(file, onto: mount))
        XCTAssertFalse(TreeEditor.canPaste(mount, onto: root))
    }

    private func names(_ url: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: url.path)
    }

    private func diskBytes(_ url: URL) throws -> Int64 {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: url.path) else { return 0 }
        var total: Int64 = 0
        for name in names {
            let child = url.appendingPathComponent(name)
            var info = stat()
            guard lstat(child.path, &info) == 0 else { continue }
            if (info.st_mode & S_IFMT) == S_IFDIR {
                total += try diskBytes(child)
            } else {
                total += Int64(info.st_size)
            }
        }
        return total
    }
}
