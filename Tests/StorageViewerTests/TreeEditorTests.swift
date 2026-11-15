import Darwin
import Foundation
import StorageViewerCore
import XCTest

final class TreeEditorTests: XCTestCase {
    func testRenameCopyPasteDuplicateAndTrashMatchTheDisk() throws {
        let scratch = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("ScratchOps")
        if FileManager.default.fileExists(atPath: scratch.path) {
            try FileManager.default.removeItem(at: scratch)
        }
        try FileManager.default.createDirectory(at: scratch.appendingPathComponent("dest"), withIntermediateDirectories: true)
        try Data(repeating: 1, count: 20).write(to: scratch.appendingPathComponent("alpha.txt"))
        try Data(repeating: 2, count: 10).write(to: scratch.appendingPathComponent("beta.txt"))
        try Data(repeating: 3, count: 5).write(to: scratch.appendingPathComponent("dest/inside.txt"))

        let outcome = DirectoryScanner.scan(url: scratch, displayName: "ScratchOps")
        let root = try XCTUnwrap(outcome.root)
        root.linkParents()

        let alpha = try XCTUnwrap(root.children.first { $0.name == "alpha.txt" })
        XCTAssertThrowsError(try TreeEditor.rename(alpha, to: "   ", rootURL: scratch))
        XCTAssertThrowsError(try TreeEditor.rename(alpha, to: "bad/name", rootURL: scratch))
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
        try TreeEditor.trash(twin, rootURL: scratch)
        XCTAssertFalse(FileManager.default.fileExists(atPath: scratch.appendingPathComponent("beta copy.txt").path))
        XCTAssertNil(root.children.first { $0.name == "beta copy.txt" })
        XCTAssertEqual(root.byteSize, beforeTrash - 10)
        XCTAssertEqual(root.byteSize, root.children.reduce(0) { $0 + $1.byteSize })
        XCTAssertEqual(dest.byteSize, dest.children.reduce(0) { $0 + $1.byteSize })
        XCTAssertEqual(try diskBytes(scratch), root.byteSize)
        XCTAssertEqual(Set(try names(scratch)), Set(root.children.map(\.name)))
        XCTAssertEqual(Set(try names(scratch.appendingPathComponent("dest"))), Set(dest.children.map(\.name)))

        try restoreSample(scratch)
    }

    func testCaseOnlyRenameAndAReplacedFileIsLeftAlone() throws {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let report = scratch.appendingPathComponent("Report.pdf")
        try Data("old".utf8).write(to: report)
        try Data("keep".utf8).write(to: scratch.appendingPathComponent("other.txt"))

        let outcome = DirectoryScanner.scan(url: scratch, displayName: "case")
        let root = try XCTUnwrap(outcome.root)
        root.linkParents()
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

    private func restoreSample(_ scratch: URL) throws {
        if FileManager.default.fileExists(atPath: scratch.path) {
            try FileManager.default.removeItem(at: scratch)
        }
        try FileManager.default.createDirectory(at: scratch.appendingPathComponent("notes"), withIntermediateDirectories: true)
        try Data("Scratch folder for the item menu.\n".utf8).write(to: scratch.appendingPathComponent("readme.txt"))
        try Data("Hello from notes.\n".utf8).write(to: scratch.appendingPathComponent("notes/hello.txt"))
    }
}
