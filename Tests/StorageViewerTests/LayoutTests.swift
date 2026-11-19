import CoreGraphics
import Foundation
import StorageViewerCore
import XCTest

final class LayoutTests: XCTestCase {
    func testAreasMatchByteWeights() {
        let entries: [(id: UUID, size: Int64)] = [
            (UUID(), 500),
            (UUID(), 250),
            (UUID(), 125),
            (UUID(), 125),
            (UUID(), 0)
        ]
        let bounds = CGRect(x: 0, y: 0, width: 800, height: 500)
        let items = TreemapLayout.layout(entries: entries, in: bounds)
        XCTAssertEqual(items.count, 4)

        let totalBytes = entries.reduce(Int64(0)) { $0 + $1.size }
        let boundsArea = bounds.width * bounds.height
        var covered = 0.0
        for item in items {
            XCTAssertGreaterThanOrEqual(item.rect.minX, bounds.minX - 0.05)
            XCTAssertGreaterThanOrEqual(item.rect.minY, bounds.minY - 0.05)
            XCTAssertLessThanOrEqual(item.rect.maxX, bounds.maxX + 0.05)
            XCTAssertLessThanOrEqual(item.rect.maxY, bounds.maxY + 0.05)
            let size = entries.first { $0.id == item.id }!.size
            let actual = item.rect.width * item.rect.height
            let expected = Double(size) / Double(totalBytes) * boundsArea
            XCTAssertEqual(actual, expected, accuracy: max(0.5, expected * 0.002))
            covered += actual
        }
        XCTAssertEqual(covered, boundsArea, accuracy: 0.5)
    }

    func testSingleChildFillsTheBounds() {
        let id = UUID()
        let bounds = CGRect(x: 2, y: 4, width: 100, height: 40)
        let items = TreemapLayout.layout(entries: [(id, 10)], in: bounds)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].rect.width, bounds.width, accuracy: 0.001)
        XCTAssertEqual(items[0].rect.height, bounds.height, accuracy: 0.001)
    }

    func testTreemapHandlesLargeFoldersAndDegenerateBounds() {
        XCTAssertTrue(TreemapLayout.layout(entries: [(UUID(), 10)], in: .zero).isEmpty)
        XCTAssertTrue(TreemapLayout.layout(entries: [(UUID(), 10)], in: CGRect(x: 0, y: 0, width: -10, height: 10)).isEmpty)
        XCTAssertTrue(TreemapLayout.layout(entries: [(UUID(), 10)], in: CGRect(x: 0, y: 0, width: CGFloat.nan, height: 10)).isEmpty)

        let entries = (1...5_000).map { i in (UUID(), Int64(i * 17)) }
        let bounds = CGRect(x: 0, y: 0, width: 1_200, height: 800)
        let items = TreemapLayout.layout(entries: entries, in: bounds)
        XCTAssertEqual(items.count, entries.count)
        let covered = items.reduce(0.0) { $0 + Double($1.rect.width * $1.rect.height) }
        XCTAssertEqual(covered, Double(bounds.width * bounds.height), accuracy: 1.0)
        for item in items {
            XCTAssertGreaterThanOrEqual(item.rect.minX, bounds.minX - 0.05)
            XCTAssertGreaterThanOrEqual(item.rect.minY, bounds.minY - 0.05)
            XCTAssertLessThanOrEqual(item.rect.maxX, bounds.maxX + 0.05)
            XCTAssertLessThanOrEqual(item.rect.maxY, bounds.maxY + 0.05)
        }
    }

    func testByteFormatAndPercents() {
        XCTAssertEqual(ByteFormat.bytes(0), "0 B")
        XCTAssertEqual(ByteFormat.bytes(512), "512 B")
        XCTAssertEqual(ByteFormat.bytes(1023), "1,023 B")
        XCTAssertEqual(ByteFormat.bytes(1024), "1.00 KB")
        XCTAssertEqual(ByteFormat.bytes(1536), "1.50 KB")
        XCTAssertEqual(ByteFormat.bytes(10 * 1024), "10.0 KB")
        XCTAssertEqual(ByteFormat.bytes(100 * 1024), "100 KB")
        XCTAssertEqual(ByteFormat.bytes(1024 * 1024), "1.00 MB")
        XCTAssertEqual(ByteFormat.bytes(10_239), "10.0 KB")
        XCTAssertEqual(ByteFormat.bytes(1_048_575), "1.00 MB")
        XCTAssertEqual(ByteFormat.bytes(-1024), "-1.00 KB")
        XCTAssertFalse(ByteFormat.bytes(Int64.min).isEmpty)
        XCTAssertEqual(ByteFormat.percent(0, of: 10), "0%")
        XCTAssertEqual(ByteFormat.percent(50, of: 100), "50.0%")
        XCTAssertEqual(ByteFormat.percent(1, of: 10_000), "<0.1%")
        XCTAssertEqual(ByteFormat.count(0), "0")
        XCTAssertEqual(ByteFormat.count(8421), "8,421")
        XCTAssertEqual(ByteFormat.count(1_234_567), "1,234,567")
        XCTAssertEqual(ByteFormat.count(-4200), "-4,200")
    }

    func testByteFormatIsThreadSafe() {
        DispatchQueue.concurrentPerform(iterations: 8) { worker in
            for i in 0..<2_000 {
                let bytes = ByteFormat.bytes(Int64((worker * 10_000 + i) * 7))
                XCTAssertFalse(bytes.isEmpty)
                let count = ByteFormat.count(worker * 10_000 + i)
                XCTAssertFalse(count.isEmpty)
            }
        }
    }

    func testNameFilterAndCategories() {
        XCTAssertTrue(NameFilter.matches(name: "Photo.PNG", query: "photo"))
        XCTAssertTrue(NameFilter.matches(name: "Archive", query: "   "))
        XCTAssertFalse(NameFilter.matches(name: "Archive", query: "zip"))
        XCTAssertTrue(NameFilter.matches(name: "Café-Notes.txt", query: "cafe"))
        XCTAssertTrue(NameFilter.matches(name: "写真_01.png", query: "写真"))
        XCTAssertEqual(FileCategory.classify(name: "App.swift"), .code)
        XCTAssertEqual(FileCategory.classify(name: "shot.JPEG"), .images)
        XCTAssertEqual(FileCategory.classify(name: "clip.mov"), .video)
        XCTAssertEqual(FileCategory.classify(name: "song.flac"), .audio)
        XCTAssertEqual(FileCategory.classify(name: "backup.zip"), .archives)
        XCTAssertEqual(FileCategory.classify(name: "notes.pdf"), .documents)
        XCTAssertEqual(FileCategory.classify(name: "Makefile"), .code)
        XCTAssertEqual(FileCategory.classify(name: ".gitignore"), .code)
        XCTAssertEqual(FileCategory.classify(name: ".editorconfig"), .code)
        XCTAssertEqual(FileCategory.classify(name: "blob.bin"), .other)
        XCTAssertEqual(FileCategory.code.displayName, "Code")
    }

    func testFilterShowsAMatchInsideACollapsedFolder() {
        let photo = FileNode(name: "IMG_0001.jpg", isDirectory: false, byteSize: 10, category: .images)
        let notes = FileNode(name: "readme.txt", isDirectory: false, byteSize: 4, category: .documents)
        let vacation = FileNode(name: "Vacation", isDirectory: true, byteSize: 14, category: .images, children: [photo, notes])
        let song = FileNode(name: "song.mp3", isDirectory: false, byteSize: 3, category: .audio)
        let music = FileNode(name: "Music", isDirectory: true, byteSize: 3, category: .audio, children: [song])

        let rows = NameFilter.listedRows(children: [vacation, music], expanded: [], query: "IMG_0001", parentSize: 17)
        XCTAssertEqual(rows.map(\.node.name), ["Vacation", "IMG_0001.jpg"])
        XCTAssertEqual(rows.map(\.depth), [0, 1])

        let folderOnly = NameFilter.listedRows(children: [vacation, music], expanded: [], query: "vacation", parentSize: 17)
        XCTAssertEqual(folderOnly.map(\.node.name), ["Vacation"])

        let collapsed = NameFilter.listedRows(children: [vacation, music], expanded: [], query: "", parentSize: 17)
        XCTAssertEqual(collapsed.map(\.node.name), ["Vacation", "Music"])
    }

    func testPathFromRootSkipsLargeSiblings() {
        let bulky = (0..<40_000).map { index in
            FileNode(name: "file-\(index)", isDirectory: false, byteSize: 1, category: .other)
        }
        let users = FileNode(name: "Users", isDirectory: true, byteSize: 40_000, category: .other, children: bulky)
        let hit = FileNode(name: "Mail.app", isDirectory: false, byteSize: 10, category: .other)
        let apps = FileNode(name: "Applications", isDirectory: true, byteSize: 10, category: .other, children: [hit])
        let disk = FileNode(name: "Macintosh HD", isDirectory: true, byteSize: 40_010, category: .other, children: [users, apps])
        disk.linkParents()

        let start = ContinuousClock.now
        let path = hit.pathFromRoot().map(\.name)
        let elapsed = start.duration(to: .now)
        let milliseconds = Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
        XCTAssertEqual(path, ["Macintosh HD", "Applications", "Mail.app"])
        XCTAssertLessThan(milliseconds, 20)
    }

    func testListAndMapUseTheSameSizes() throws {
        let children = [
            FileNode(name: "a.swift", isDirectory: false, byteSize: 300, category: .code),
            FileNode(name: "b.png", isDirectory: false, byteSize: 100, category: .images),
            FileNode(name: "c", isDirectory: true, byteSize: 600, category: .video)
        ]
        let root = FileNode(name: "root", isDirectory: true, byteSize: 1_000, category: .video, children: children)
        XCTAssertEqual(root.children.reduce(0) { $0 + $1.byteSize }, root.byteSize)
        let items = TreemapLayout.layout(nodes: root.children, in: CGRect(x: 0, y: 0, width: 200, height: 100))
        XCTAssertEqual(Set(items.map(\.id)), Set(children.map(\.id)))
        for child in children {
            let item = try XCTUnwrap(items.first { $0.id == child.id })
            let area = item.rect.width * item.rect.height
            let expected = Double(child.byteSize) / 1_000 * 20_000
            XCTAssertEqual(area, expected, accuracy: max(0.5, expected * 0.002))
            let folderShare = ByteFormat.percent(child.byteSize, of: root.byteSize)
            XCTAssertFalse(folderShare.isEmpty)
        }
    }
}
