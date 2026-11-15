import CoreGraphics
import StorageViewerCore
import XCTest

final class BlockPatternTests: XCTestCase {
    func testAtLeastTwelveMasks() {
        XCTAssertGreaterThanOrEqual(BlockPattern.allCases.count, 12)
        let labels = Set(BlockPattern.allCases.map(\.label))
        XCTAssertEqual(labels.count, BlockPattern.allCases.count)
    }

    func testNamePicksAStableGrain() {
        let names = ["Documents", "Downloads", "node_modules", "写真", "A", ""]
        for name in names {
            XCTAssertEqual(BlockGrain.forName(name), BlockGrain.forName(name), name)
        }
        XCTAssertEqual(
            BlockGrain.forName("Library").pattern,
            BlockGrain.forName("Library").pattern
        )
    }

    func testSiblingNamesUsuallyDiffer() {
        let names = [
            "Applications", "Library", "System", "Users", "Projects", "Downloads",
            "Documents", "Desktop", "Pictures", "Movies", "Music", "node_modules",
            "Sources", "Packages", "Archive", "Caches", "Developer", "Mail",
            "Photos", "Backup", "Docker", "Volumes", "Public", "Shared"
        ]
        let patterns = Set(names.map { BlockGrain.forName($0).pattern })
        XCTAssertGreaterThanOrEqual(patterns.count, 12)
    }

    func testMasksStayDistinctOnASmallBlock() {
        let rect = CGRect(x: 0, y: 0, width: 34, height: 26)
        var seen: [String: String] = [:]
        for pattern in BlockPattern.allCases {
            let marks = pattern.primitives(in: rect, phaseX: 2, phaseY: 3)
            XCTAssertFalse(marks.isEmpty, pattern.label)
            XCTAssertTrue(marks.contains { intersects($0, rect) }, pattern.label)
            let signature = fingerprint(marks)
            if let other = seen[signature] {
                XCTFail("\(pattern.label) draws the same as \(other) on a small block")
            }
            seen[signature] = pattern.label
        }
    }

    func testTinyBlockStillShowsEveryMask() {
        let rect = CGRect(x: 4, y: 8, width: 20, height: 18)
        for pattern in BlockPattern.allCases {
            let marks = pattern.primitives(in: rect, phaseX: 0, phaseY: 0)
            XCTAssertFalse(marks.isEmpty, pattern.label)
        }
    }

    private func intersects(_ mark: PatternPrimitive, _ rect: CGRect) -> Bool {
        rect.intersects(bounds(of: mark).insetBy(dx: -0.5, dy: -0.5))
    }

    private func bounds(of mark: PatternPrimitive) -> CGRect {
        switch mark {
        case .fillEllipse(let rect), .strokeEllipse(let rect, _), .strokeRect(let rect, _):
            return rect
        case .stroke(let points, _, _):
            guard let first = points.first else { return .null }
            return points.dropFirst().reduce(CGRect(origin: first, size: .zero)) { partial, point in
                partial.union(CGRect(origin: point, size: .zero))
            }
        case .strokeArc(let center, let radius, _, _, _):
            return CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
        }
    }

    private func fingerprint(_ marks: [PatternPrimitive]) -> String {
        marks.map { mark -> String in
            switch mark {
            case .fillEllipse(let rect):
                return "fe\(q(rect.midX)),\(q(rect.midY)),\(q(rect.width))"
            case .strokeEllipse(let rect, let width):
                return "se\(q(rect.midX)),\(q(rect.midY)),\(q(rect.width)),\(q(width))"
            case .strokeRect(let rect, let width):
                return "sr\(q(rect.midX)),\(q(rect.midY)),\(q(rect.width)),\(q(width))"
            case .stroke(let points, let width, let closed):
                let body = points.map { "\(q($0.x)),\(q($0.y))" }.joined(separator: ";")
                return "ln\(closed ? 1 : 0),\(q(width)),\(body)"
            case .strokeArc(let center, let radius, let start, let end, let width):
                return "arc\(q(center.x)),\(q(center.y)),\(q(radius)),\(q(start)),\(q(end)),\(q(width))"
            }
        }.joined(separator: "|")
    }

    private func q(_ value: CGFloat) -> Int {
        Int((value * 2).rounded())
    }
}
