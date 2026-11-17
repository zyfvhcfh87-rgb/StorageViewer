@testable import StorageViewerCore
import Darwin
import Foundation
import XCTest

final class ScannerTests: XCTestCase {
    func testFolderSizeIsTheSumOfItsContents() throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }

        let outcome = DirectoryScanner.scan(url: root, displayName: "fixture")
        let node = try XCTUnwrap(outcome.root)
        XCTAssertFalse(outcome.cancelled)
        XCTAssertFalse(outcome.rootDenied)
        XCTAssertEqual(outcome.skippedCount, 0)
        assertConsistent(node)

        let readme = try XCTUnwrap(node.children.first { $0.name == "readme.md" })
        let images = try XCTUnwrap(node.children.first { $0.name == "images" })
        let photo = try XCTUnwrap(images.children.first { $0.name == "photo.png" })
        let source = try XCTUnwrap(node.children.first { $0.name == "main.swift" })
        let link = try XCTUnwrap(node.children.first { $0.name == "alias.swift" })

        XCTAssertEqual(readme.byteSize, 100)
        XCTAssertEqual(readme.category, .documents)
        XCTAssertEqual(photo.byteSize, 2_000)
        XCTAssertEqual(photo.category, .images)
        XCTAssertEqual(source.byteSize, 400)
        XCTAssertEqual(source.category, .code)
        XCTAssertFalse(link.isDirectory)
        XCTAssertLessThan(link.byteSize, 400)

        let expected = try independentTotal(root)
        XCTAssertEqual(node.byteSize, expected)
        XCTAssertEqual(outcome.bytesCounted, node.byteSize)
        XCTAssertEqual(images.byteSize, 2_000)
        XCTAssertEqual(node.byteSize, node.children.reduce(0) { $0 + $1.byteSize })

        var readmeInfo = stat()
        XCTAssertEqual(lstat(root.appendingPathComponent("readme.md").path, &readmeInfo), 0)
        XCTAssertEqual(readme.fileID, FileIdentity(readmeInfo))
        var imagesInfo = stat()
        XCTAssertEqual(lstat(root.appendingPathComponent("images").path, &imagesInfo), 0)
        XCTAssertEqual(images.fileID, FileIdentity(imagesInfo))
    }

    func testScanCountsEverySubfolderWhenTheOpenFileLimitIsLow() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let openNow = (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd"))?.count ?? 64
        var original = rlimit()
        XCTAssertEqual(getrlimit(RLIMIT_NOFILE, &original), 0)
        let cap = min(original.rlim_cur, rlim_t(openNow + 24))
        let subdirs = Int(cap) + 40
        for index in 0..<subdirs {
            let dir = root.appendingPathComponent("dir-\(index)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data(repeating: 9, count: 8).write(to: dir.appendingPathComponent("n.bin"))
        }

        defer { setrlimit(RLIMIT_NOFILE, &original) }
        var lowered = original
        lowered.rlim_cur = cap
        XCTAssertEqual(setrlimit(RLIMIT_NOFILE, &lowered), 0)
        XCTAssertLessThan(cap, rlim_t(subdirs))

        let outcome = DirectoryScanner.scan(url: root, displayName: "wide")
        let node = try XCTUnwrap(outcome.root)
        XCTAssertFalse(outcome.cancelled)
        XCTAssertEqual(outcome.skippedCount, 0)
        XCTAssertEqual(node.children.count, subdirs)
        XCTAssertEqual(node.byteSize, Int64(subdirs * 8))
        XCTAssertEqual(node.byteSize, try independentTotal(root))

        var raised = rlimit()
        XCTAssertEqual(getrlimit(RLIMIT_NOFILE, &raised), 0)
        XCTAssertGreaterThanOrEqual(raised.rlim_cur, rlim_t(subdirs))
    }

    func testSymlinkIsNotFollowed() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("movie.mp4")
        try Data(repeating: 7, count: 8_000).write(to: file)
        let link = root.appendingPathComponent("link.mp4")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)

        let outcome = DirectoryScanner.scan(url: root, displayName: "links")
        let node = try XCTUnwrap(outcome.root)
        let linked = try XCTUnwrap(node.children.first { $0.name == "link.mp4" })
        var info = stat()
        XCTAssertEqual(lstat(link.path, &info), 0)
        XCTAssertEqual(linked.byteSize, Int64(info.st_size))
        XCTAssertEqual(node.byteSize, 8_000 + linked.byteSize)
    }

    func testDeniedDirectoryIsSkippedAndCounted() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let secret = root.appendingPathComponent("secret", isDirectory: true)
        try FileManager.default.createDirectory(at: secret, withIntermediateDirectories: true)
        defer {
            chmod(secret.path, 0o755)
            try? FileManager.default.removeItem(at: root)
        }
        try Data("hidden".utf8).write(to: secret.appendingPathComponent("note.txt"))
        try Data(repeating: 1, count: 50).write(to: root.appendingPathComponent("visible.txt"))
        XCTAssertEqual(chmod(secret.path, 0), 0)

        let outcome = DirectoryScanner.scan(url: root, displayName: "parent")
        let node = try XCTUnwrap(outcome.root)
        XCTAssertGreaterThanOrEqual(outcome.skippedCount, 1)
        XCTAssertNil(node.children.first { $0.name == "secret" })
        XCTAssertEqual(node.byteSize, 50)
        XCTAssertEqual(outcome.bytesCounted, 50)

        let denied = DirectoryScanner.scan(url: secret, displayName: "secret")
        XCTAssertTrue(denied.rootDenied)
        XCTAssertNil(denied.root)
        XCTAssertFalse(denied.missing)
    }

    func testBulkEntryParsesADeviceWithTheTopBitSet() throws {
        // getattrlistbulk reports dev_t as a raw UInt32. devfs devices set bit 31,
        // and converting those to a signed dev_t used to trap while scanning "/".
        let nameBytes = Array("dev".utf8) + [0]
        let attributeBytes = 4 + MemoryLayout<attribute_set_t>.size + MemoryLayout<attrreference_t>.size
            + 4 + 4 + 8 + 4 + 8
        let length = attributeBytes + nameBytes.count
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: length, alignment: 16)
        defer { buffer.deallocate() }

        buffer.storeBytes(of: UInt32(length), toByteOffset: 0, as: UInt32.self)
        var returned = attribute_set_t()
        returned.commonattr = UInt32(ATTR_CMN_NAME) | UInt32(ATTR_CMN_DEVID) | UInt32(ATTR_CMN_OBJTYPE)
            | UInt32(ATTR_CMN_FILEID) | UInt32(ATTR_CMN_ERROR)
        returned.fileattr = UInt32(ATTR_FILE_DATALENGTH)
        buffer.storeBytes(of: returned, toByteOffset: 4, as: attribute_set_t.self)

        let referenceOrigin = 4 + MemoryLayout<attribute_set_t>.size
        var reference = attrreference_t()
        reference.attr_dataoffset = Int32(attributeBytes - referenceOrigin)
        reference.attr_length = UInt32(nameBytes.count)
        buffer.storeBytes(of: reference, toByteOffset: referenceOrigin, as: attrreference_t.self)

        var cursor = referenceOrigin + MemoryLayout<attrreference_t>.size
        buffer.storeBytes(of: UInt32(0xAAEB_20B1), toByteOffset: cursor, as: UInt32.self)
        cursor += 4
        buffer.storeBytes(of: UInt32(2), toByteOffset: cursor, as: UInt32.self)
        cursor += 4
        buffer.storeBytes(of: UInt64(42), toByteOffset: cursor, as: UInt64.self)
        cursor += 8
        buffer.storeBytes(of: UInt32(0), toByteOffset: cursor, as: UInt32.self)
        cursor += 4
        buffer.storeBytes(of: Int64(0), toByteOffset: cursor, as: Int64.self)
        cursor += 8
        nameBytes.withUnsafeBytes { raw in
            buffer.advanced(by: cursor).copyMemory(from: raw.baseAddress!, byteCount: raw.count)
        }

        let entry = try XCTUnwrap(parseBulkEntry(base: buffer, length: length))
        XCTAssertEqual(entry.name, "dev")
        XCTAssertEqual(entry.kind, .directory)
        XCTAssertEqual(entry.device, 0xAAEB_20B1)
        XCTAssertEqual(entry.inode, 42)
    }

    func testCancelBeforeWork() {
        let outcome = DirectoryScanner.scan(
            url: FileManager.default.temporaryDirectory,
            displayName: "tmp",
            isCancelled: { true }
        )
        XCTAssertTrue(outcome.cancelled)
        XCTAssertEqual(outcome.filesSeen, 0)
        XCTAssertNil(outcome.root)
    }

    func testHiddenFilesAreCounted() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(repeating: 3, count: 12).write(to: root.appendingPathComponent(".hidden"))
        let outcome = DirectoryScanner.scan(url: root, displayName: "hidden")
        let node = try XCTUnwrap(outcome.root)
        XCTAssertEqual(node.children.first { $0.name == ".hidden" }?.byteSize, 12)
    }

    func testBenchmarkWhenRequested() throws {
        guard ProcessInfo.processInfo.environment["SV_BENCH"] == "1" else { return }
        let path = ProcessInfo.processInfo.environment["SV_BENCH_PATH"] ?? NSHomeDirectory()
        let url = URL(fileURLWithPath: path)
        var samples: [Double] = []
        var files = 0
        var bytes: Int64 = 0
        for _ in 0..<3 {
            let start = ContinuousClock.now
            let outcome = DirectoryScanner.scan(url: url, displayName: "bench")
            let elapsed = start.duration(to: .now)
            let ms = Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
            samples.append(ms)
            files = outcome.filesSeen
            bytes = outcome.bytesCounted
            XCTAssertNotNil(outcome.root)
        }
        print("BENCH path=\(path) files=\(files) bytes=\(bytes) ms=\(samples.map { String(format: "%.1f", $0) }.joined(separator: ","))")
    }

    func testSourcesTreeAgreesWithAnIndependentWalk() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources")
        let outcome = DirectoryScanner.scan(url: sources, displayName: "Sources")
        let node = try XCTUnwrap(outcome.root)
        assertConsistent(node)
        let expected = try independentTotal(sources)
        XCTAssertEqual(node.byteSize, expected)
        XCTAssertEqual(outcome.bytesCounted, expected)
        XCTAssertGreaterThan(outcome.filesSeen, 0)
    }

    private func makeTree() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("images"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("empty"), withIntermediateDirectories: true)
        try Data(repeating: 1, count: 100).write(to: root.appendingPathComponent("readme.md"))
        try Data(repeating: 2, count: 400).write(to: root.appendingPathComponent("main.swift"))
        try Data(repeating: 3, count: 2_000).write(to: root.appendingPathComponent("images/photo.png"))
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("alias.swift"),
            withDestinationURL: root.appendingPathComponent("main.swift")
        )
        return root
    }

    private func assertConsistent(_ node: FileNode, file: StaticString = #filePath, line: UInt = #line) {
        let mixed = node.subtreeMix.values.reduce(Int64(0), +)
        XCTAssertEqual(mixed, node.byteSize, node.name, file: file, line: line)
        if node.isDirectory {
            XCTAssertEqual(node.children.reduce(0) { $0 + $1.byteSize }, node.byteSize, node.name, file: file, line: line)
            for child in node.children {
                XCTAssertTrue(child.parent === node, node.name, file: file, line: line)
                assertConsistent(child, file: file, line: line)
            }
        } else {
            XCTAssertTrue(node.children.isEmpty, file: file, line: line)
        }
    }

    private func independentTotal(_ url: URL) throws -> Int64 {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            XCTFail("lstat \(url.path)")
            return 0
        }
        return try walk(url, rootDevice: info.st_dev, isRoot: true)
    }

    private func walk(_ url: URL, rootDevice: dev_t, isRoot: Bool) throws -> Int64 {
        var info = stat()
        if lstat(url.path, &info) != 0 { return 0 }
        let mode = info.st_mode & S_IFMT
        if !isRoot && info.st_dev != rootDevice { return 0 }
        if mode == S_IFLNK { return Int64(info.st_size) }
        if mode != S_IFDIR { return Int64(info.st_size) }
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: url.path)
        } catch {
            return 0
        }
        var total: Int64 = 0
        for name in names {
            total += try walk(url.appendingPathComponent(name), rootDevice: rootDevice, isRoot: false)
        }
        return total
    }
}
