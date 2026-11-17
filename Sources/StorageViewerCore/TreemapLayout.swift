import CoreGraphics
import Foundation

public struct TreemapItem: Identifiable, Equatable, Sendable {
    public var id: UUID
    public var rect: CGRect

    public init(id: UUID, rect: CGRect) {
        self.id = id
        self.rect = rect
    }
}

public enum TreemapLayout {
    /// Squarified treemap. Rectangle area is proportional to `size`.
    /// Zero-size entries are omitted. The layout fills `bounds`.
    public static func layout(entries: [(id: UUID, size: Int64)], in bounds: CGRect) -> [TreemapItem] {
        guard bounds.width > 0, bounds.height > 0 else { return [] }
        let usable = entries.filter { $0.size > 0 }
        guard !usable.isEmpty else { return [] }
        let total = usable.reduce(Int64(0)) { $0 + $1.size }
        guard total > 0 else { return [] }

        let sorted = usable.sorted { lhs, rhs in
            if lhs.size == rhs.size { return lhs.id.uuidString < rhs.id.uuidString }
            return lhs.size > rhs.size
        }
        let area = Double(bounds.width) * Double(bounds.height)
        let weights = sorted.map { Double($0.size) / Double(total) * area }
        let rects = squarify(
            weights,
            x: Double(bounds.minX),
            y: Double(bounds.minY),
            dx: Double(bounds.width),
            dy: Double(bounds.height)
        )
        return zip(sorted, rects).map { entry, rect in
            TreemapItem(
                id: entry.id,
                rect: CGRect(x: rect.x, y: rect.y, width: max(0, rect.w), height: max(0, rect.h))
            )
        }
    }

    public static func layout(nodes: [FileNode], in bounds: CGRect) -> [TreemapItem] {
        layout(entries: nodes.map { ($0.id, $0.byteSize) }, in: bounds)
    }

    private struct RectD {
        var x: Double
        var y: Double
        var w: Double
        var h: Double
    }

    private static func squarify(_ sizes: [Double], x: Double, y: Double, dx: Double, dy: Double) -> [RectD] {
        var result: [RectD] = []
        var x = x
        var y = y
        var dx = dx
        var dy = dy
        var start = 0

        while start < sizes.count {
            if sizes.count - start == 1 || dx <= 0.000_001 || dy <= 0.000_001 {
                result.append(contentsOf: place(sizes[start...], x: x, y: y, dx: max(dx, 0), dy: max(dy, 0)))
                break
            }
            var rowCount = 1
            var sum = sizes[start]
            var smallest = sizes[start]
            var largest = sizes[start]
            var best = worstRatio(sum: sum, smallest: smallest, largest: largest, dx: dx, dy: dy)
            while start + rowCount < sizes.count {
                let size = sizes[start + rowCount]
                let nextSum = sum + size
                let nextSmallest = min(smallest, size)
                let nextLargest = max(largest, size)
                let candidate = worstRatio(
                    sum: nextSum,
                    smallest: nextSmallest,
                    largest: nextLargest,
                    dx: dx,
                    dy: dy
                )
                guard candidate <= best else { break }
                best = candidate
                sum = nextSum
                smallest = nextSmallest
                largest = nextLargest
                rowCount += 1
            }
            let row = sizes[start..<(start + rowCount)]
            result.append(contentsOf: place(row, x: x, y: y, dx: dx, dy: dy))
            let rest = leftover(row, x: x, y: y, dx: dx, dy: dy)
            x = rest.x
            y = rest.y
            dx = rest.w
            dy = rest.h
            start += rowCount
        }
        return result
    }

    /// Worst width-to-height ratio of a row, without placing it.
    /// The row runs along the longer edge, so every rect shares one side length:
    /// `sum / shorterEdge`. Ratio `i` is `max(edge² / sizeᵢ, sizeᵢ / edge²)`.
    private static func worstRatio(
        sum: Double,
        smallest: Double,
        largest: Double,
        dx: Double,
        dy: Double
    ) -> Double {
        guard sum > 0, smallest > 0, dx > 0, dy > 0 else { return .infinity }
        let edge = dx >= dy ? sum / dy : sum / dx
        let squared = edge * edge
        return max(squared / smallest, largest / squared)
    }

    private static func place(_ sizes: ArraySlice<Double>, x: Double, y: Double, dx: Double, dy: Double) -> [RectD] {
        let sum = sizes.reduce(0, +)
        guard sum > 0, dx > 0, dy > 0 else { return [] }
        if dx >= dy {
            let width = sum / dy
            var rects: [RectD] = []
            var cursorY = y
            for size in sizes {
                let height = width > 0 ? size / width : 0
                rects.append(RectD(x: x, y: cursorY, w: width, h: height))
                cursorY += height
            }
            return rects
        }
        let height = sum / dx
        var rects: [RectD] = []
        var cursorX = x
        for size in sizes {
            let width = height > 0 ? size / height : 0
            rects.append(RectD(x: cursorX, y: y, w: width, h: height))
            cursorX += width
        }
        return rects
    }

    private static func leftover(_ sizes: ArraySlice<Double>, x: Double, y: Double, dx: Double, dy: Double) -> RectD {
        let sum = sizes.reduce(0, +)
        if dx >= dy {
            let width = dy > 0 ? sum / dy : 0
            return RectD(x: x + width, y: y, w: dx - width, h: dy)
        }
        let height = dx > 0 ? sum / dx : 0
        return RectD(x: x, y: y + height, w: dx, h: dy - height)
    }
}
