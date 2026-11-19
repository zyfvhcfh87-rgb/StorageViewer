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
        guard !bounds.isNull,
              bounds.size.width > 0, bounds.size.height > 0,
              bounds.origin.x.isFinite, bounds.origin.y.isFinite,
              bounds.size.width.isFinite, bounds.size.height.isFinite else {
            return []
        }

        var usable: [(id: UUID, size: Int64)] = []
        usable.reserveCapacity(entries.count)
        var total = 0.0
        for entry in entries where entry.size > 0 {
            usable.append(entry)
            total += Double(entry.size)
        }
        guard !usable.isEmpty, total > 0 else { return [] }

        usable.sort { lhs, rhs in
            if lhs.size != rhs.size { return lhs.size > rhs.size }
            return uuidLessThan(lhs.id, rhs.id)
        }

        let area = Double(bounds.width) * Double(bounds.height)
        let scale = area / total
        let weights = usable.map { Double($0.size) * scale }
        let rects = squarify(
            weights,
            x: Double(bounds.minX),
            y: Double(bounds.minY),
            dx: Double(bounds.width),
            dy: Double(bounds.height)
        )

        var items: [TreemapItem] = []
        items.reserveCapacity(usable.count)
        for index in 0..<min(usable.count, rects.count) {
            let rect = rects[index]
            items.append(TreemapItem(
                id: usable[index].id,
                rect: CGRect(x: rect.x, y: rect.y, width: max(0, rect.w), height: max(0, rect.h))
            ))
        }
        return items
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

    /// O(N) Bruls-Huizing-van Wijk squarified layout with index slicing and O(1) aspect-ratio checks.
    private static func squarify(_ weights: [Double], x: Double, y: Double, dx: Double, dy: Double) -> [RectD] {
        let count = weights.count
        var result: [RectD] = []
        result.reserveCapacity(count)

        var start = 0
        var x = x
        var y = y
        var dx = dx
        var dy = dy

        while start < count {
            let remainingCount = count - start
            if remainingCount == 1 {
                result.append(RectD(x: x, y: y, w: max(0, dx), h: max(0, dy)))
                break
            }
            if dx <= 0.000_001 || dy <= 0.000_001 {
                var restSum = 0.0
                for i in start..<count { restSum += weights[i] }
                place(weights, start: start, count: remainingCount, sum: restSum, x: x, y: y, dx: max(dx, 0), dy: max(dy, 0), into: &result)
                break
            }

            let side = min(dx, dy)
            let sideSq = side * side
            let rowMax = weights[start]
            var rowCount = 1
            var rowSum = rowMax
            var best = worstRatio(rowSum: rowSum, rowMax: rowMax, rowMin: rowMax, sideSq: sideSq)

            while start + rowCount < count {
                let nextVal = weights[start + rowCount]
                let nextSum = rowSum + nextVal
                let candidate = worstRatio(rowSum: nextSum, rowMax: rowMax, rowMin: nextVal, sideSq: sideSq)
                if candidate <= best {
                    best = candidate
                    rowSum = nextSum
                    rowCount += 1
                } else {
                    break
                }
            }

            place(weights, start: start, count: rowCount, sum: rowSum, x: x, y: y, dx: dx, dy: dy, into: &result)

            if dx >= dy {
                let width = min(dx, dy > 0 ? rowSum / dy : 0)
                x += width
                dx = max(0, dx - width)
            } else {
                let height = min(dy, dx > 0 ? rowSum / dx : 0)
                y += height
                dy = max(0, dy - height)
            }
            start += rowCount
        }
        return result
    }

    /// For descending weights in a strip along `side`, the worst aspect ratio is always
    /// attained by either the largest (`rowMax`) or smallest (`rowMin`) item in the strip.
    private static func worstRatio(rowSum: Double, rowMax: Double, rowMin: Double, sideSq: Double) -> Double {
        guard rowMin > 0, rowSum > 0, sideSq > 0 else { return .infinity }
        let sumSq = rowSum * rowSum
        return max((sideSq * rowMax) / sumSq, sumSq / (sideSq * rowMin))
    }

    private static func place(
        _ weights: [Double],
        start: Int,
        count: Int,
        sum: Double,
        x: Double,
        y: Double,
        dx: Double,
        dy: Double,
        into result: inout [RectD]
    ) {
        guard sum > 0, dx > 0, dy > 0 else {
            for _ in 0..<count {
                result.append(RectD(x: x, y: y, w: 0, h: 0))
            }
            return
        }
        if dx >= dy {
            let width = min(dx, sum / dy)
            let invWidth = width > 0 ? (dy / sum) : 0
            var cursorY = y
            let maxY = y + dy
            for i in start..<(start + count) {
                let height = min(maxY - cursorY, weights[i] * invWidth)
                result.append(RectD(x: x, y: cursorY, w: width, h: max(0, height)))
                cursorY += max(0, height)
            }
        } else {
            let height = min(dy, sum / dx)
            let invHeight = height > 0 ? (dx / sum) : 0
            var cursorX = x
            let maxX = x + dx
            for i in start..<(start + count) {
                let width = min(maxX - cursorX, weights[i] * invHeight)
                result.append(RectD(x: cursorX, y: y, w: max(0, width), h: height))
                cursorX += max(0, width)
            }
        }
    }

    /// Byte-order comparison matching `uuidString` lexicographical order without allocating Strings.
    private static func uuidLessThan(_ lhs: UUID, _ rhs: UUID) -> Bool {
        withUnsafeBytes(of: lhs.uuid) { lBytes in
            withUnsafeBytes(of: rhs.uuid) { rBytes in
                for i in 0..<16 {
                    let a = lBytes[i]
                    let b = rBytes[i]
                    if a != b { return a < b }
                }
                return false
            }
        }
    }
}
