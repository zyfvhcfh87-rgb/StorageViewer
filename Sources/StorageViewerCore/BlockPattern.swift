import CoreGraphics
import Foundation

/// Quiet mask painted over a treemap block.
/// The type color stays visible; the mask only keeps same-color neighbors from matching.
public enum BlockPattern: Int, CaseIterable, Sendable {
    case dots
    case obliqueDashes
    case horizontalDashes
    case verticalDashes
    case waves
    case squares
    case bubbles
    case crosshatch
    case rings
    case diagonalGrid
    case stipple
    case chevrons
    case triangles
    case plusSigns
    case brokenRings

    public var label: String {
        switch self {
        case .dots: "Dots"
        case .obliqueDashes: "Oblique dashes"
        case .horizontalDashes: "Horizontal dashes"
        case .verticalDashes: "Vertical dashes"
        case .waves: "Waves"
        case .squares: "Squares"
        case .bubbles: "Bubbles"
        case .crosshatch: "Crosshatch"
        case .rings: "Rings"
        case .diagonalGrid: "Diagonal grid"
        case .stipple: "Stipple"
        case .chevrons: "Chevrons"
        case .triangles: "Triangles"
        case .plusSigns: "Plus signs"
        case .brokenRings: "Broken rings"
        }
    }

    /// Strength of the mask over the type color. Marks are sparse, so this can sit
    /// a little above a full hatch and still leave the color in charge.
    public static let markOpacity: Double = 0.36

    public func primitives(in rect: CGRect, phaseX: CGFloat, phaseY: CGFloat) -> [PatternPrimitive] {
        switch self {
        case .dots:
            return cells(in: rect, stepX: 8, stepY: 8, phaseX: phaseX, phaseY: phaseY) { center in
                [disk(center, diameter: 2.4)]
            }
        case .obliqueDashes:
            return cells(in: rect, stepX: 11, stepY: 11, phaseX: phaseX, phaseY: phaseY) { center in
                [dash(center, dx: 3.1, dy: 3.1)]
            }
        case .horizontalDashes:
            return cells(in: rect, stepX: 11, stepY: 7.5, phaseX: phaseX, phaseY: phaseY) { center in
                [dash(center, dx: 3.3, dy: 0)]
            }
        case .verticalDashes:
            return cells(in: rect, stepX: 7.5, stepY: 11, phaseX: phaseX, phaseY: phaseY) { center in
                [dash(center, dx: 0, dy: 3.3)]
            }
        case .waves:
            return waveMarks(in: rect, phaseX: phaseX, phaseY: phaseY)
        case .squares:
            return cells(in: rect, stepX: 10, stepY: 10, phaseX: phaseX, phaseY: phaseY) { center in
                let side: CGFloat = 5.4
                return [.strokeRect(
                    CGRect(x: center.x - side / 2, y: center.y - side / 2, width: side, height: side),
                    width: 1.1
                )]
            }
        case .bubbles:
            return cells(in: rect, stepX: 14, stepY: 14, phaseX: phaseX, phaseY: phaseY) { center in
                [ring(center, diameter: 8.2, width: 1.15)]
            }
        case .crosshatch:
            return crosshatchMarks(in: rect, phaseX: phaseX, phaseY: phaseY)
        case .rings:
            return cells(in: rect, stepX: 13, stepY: 13, phaseX: phaseX, phaseY: phaseY) { center in
                [ring(center, diameter: 7.2, width: 1.05), ring(center, diameter: 2.8, width: 0.95)]
            }
        case .diagonalGrid:
            return cells(in: rect, stepX: 13, stepY: 13, phaseX: phaseX, phaseY: phaseY) { center in
                let reach: CGFloat = 3.7
                return [.stroke(
                    points: [
                        CGPoint(x: center.x, y: center.y - reach),
                        CGPoint(x: center.x + reach, y: center.y),
                        CGPoint(x: center.x, y: center.y + reach),
                        CGPoint(x: center.x - reach, y: center.y)
                    ],
                    width: 1.1,
                    closed: true
                )]
            }
        case .stipple:
            return stippleMarks(in: rect, phaseX: phaseX, phaseY: phaseY)
        case .chevrons:
            return cells(in: rect, stepX: 11, stepY: 11, phaseX: phaseX, phaseY: phaseY) { center in
                let arm: CGFloat = 3.3
                return [.stroke(
                    points: [
                        CGPoint(x: center.x - arm * 0.45, y: center.y - arm),
                        CGPoint(x: center.x + arm * 0.72, y: center.y),
                        CGPoint(x: center.x - arm * 0.45, y: center.y + arm)
                    ],
                    width: 1.2,
                    closed: false
                )]
            }
        case .triangles:
            return cells(in: rect, stepX: 12, stepY: 12, phaseX: phaseX, phaseY: phaseY) { center in
                let height: CGFloat = 4.2
                return [.stroke(
                    points: [
                        CGPoint(x: center.x, y: center.y - height * 0.72),
                        CGPoint(x: center.x + height * 0.9, y: center.y + height * 0.58),
                        CGPoint(x: center.x - height * 0.9, y: center.y + height * 0.58)
                    ],
                    width: 1.1,
                    closed: true
                )]
            }
        case .plusSigns:
            return cells(in: rect, stepX: 11, stepY: 11, phaseX: phaseX, phaseY: phaseY) { center in
                let arm: CGFloat = 2.8
                return [
                    dash(center, dx: arm, dy: 0),
                    dash(center, dx: 0, dy: arm)
                ]
            }
        case .brokenRings:
            return cells(in: rect, stepX: 12, stepY: 12, phaseX: phaseX, phaseY: phaseY) { center in
                [.strokeArc(center: center, radius: 3.4, start: .pi * 0.35, end: .pi * 1.7, width: 1.2)]
            }
        }
    }
}

/// Pattern plus a stable phase, both derived from the item name.
/// Calling this again for the same name returns the same grain. Nothing here is random.
public struct BlockGrain: Equatable, Sendable {
    public var pattern: BlockPattern
    public var phaseX: CGFloat
    public var phaseY: CGFloat

    public static func forName(_ name: String) -> BlockGrain {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in name.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1_099_511_628_211
        }
        hash = mix(hash)
        let patterns = BlockPattern.allCases
        let pattern = patterns[Int(hash % UInt64(patterns.count))]
        return BlockGrain(
            pattern: pattern,
            phaseX: CGFloat((hash >> 17) % 8),
            phaseY: CGFloat((hash >> 29) % 8)
        )
    }

    /// SplitMix finalizer. Short folder names need it, or the low bits clump.
    private static func mix(_ value: UInt64) -> UInt64 {
        var z = value
        z = (z ^ (z >> 30)) &* 0xbf58_476d_1ce4_e5b9
        z = (z ^ (z >> 27)) &* 0x94d0_49bb_1331_11eb
        return z ^ (z >> 31)
    }
}

public enum PatternPrimitive: Equatable, Sendable {
    case fillEllipse(CGRect)
    case strokeEllipse(CGRect, width: CGFloat)
    case strokeRect(CGRect, width: CGFloat)
    case stroke(points: [CGPoint], width: CGFloat, closed: Bool)
    case strokeArc(center: CGPoint, radius: CGFloat, start: CGFloat, end: CGFloat, width: CGFloat)
}

private func disk(_ center: CGPoint, diameter: CGFloat) -> PatternPrimitive {
    .fillEllipse(CGRect(
        x: center.x - diameter / 2,
        y: center.y - diameter / 2,
        width: diameter,
        height: diameter
    ))
}

private func ring(_ center: CGPoint, diameter: CGFloat, width: CGFloat) -> PatternPrimitive {
    .strokeEllipse(CGRect(
        x: center.x - diameter / 2,
        y: center.y - diameter / 2,
        width: diameter,
        height: diameter
    ), width: width)
}

private func dash(_ center: CGPoint, dx: CGFloat, dy: CGFloat) -> PatternPrimitive {
    .stroke(
        points: [
            CGPoint(x: center.x - dx, y: center.y - dy),
            CGPoint(x: center.x + dx, y: center.y + dy)
        ],
        width: 1.2,
        closed: false
    )
}

private func cells(
    in rect: CGRect,
    stepX: CGFloat,
    stepY: CGFloat,
    phaseX: CGFloat,
    phaseY: CGFloat,
    mark: (CGPoint) -> [PatternPrimitive]
) -> [PatternPrimitive] {
    origins(in: rect, stepX: stepX, stepY: stepY, phaseX: phaseX, phaseY: phaseY).flatMap(mark)
}

private func origins(
    in rect: CGRect,
    stepX: CGFloat,
    stepY: CGFloat,
    phaseX: CGFloat,
    phaseY: CGFloat
) -> [CGPoint] {
    guard rect.width > 1, rect.height > 1, stepX > 0, stepY > 0 else { return [] }
    let x0 = rect.minX + positiveMod(phaseX, stepX)
    let y0 = rect.minY + positiveMod(phaseY, stepY)
    var points: [CGPoint] = []
    var y = y0
    while y < rect.maxY {
        var x = x0
        while x < rect.maxX {
            points.append(CGPoint(x: x, y: y))
            x += stepX
        }
        y += stepY
    }
    if points.isEmpty {
        points.append(CGPoint(x: rect.midX, y: rect.midY))
    }
    return points
}

private func waveMarks(in rect: CGRect, phaseX: CGFloat, phaseY: CGFloat) -> [PatternPrimitive] {
    let row: CGFloat = 8
    let wavelength: CGFloat = 13
    let amplitude: CGFloat = 2.2
    let shift = positiveMod(phaseX, wavelength)
    var marks: [PatternPrimitive] = []
    var y = rect.minY + 2 + positiveMod(phaseY, row)
    while y < rect.maxY - 1 {
        var points: [CGPoint] = []
        var x = rect.minX
        while x <= rect.maxX + 0.01 {
            let theta = ((x + shift) / wavelength) * (2 * .pi)
            points.append(CGPoint(x: x, y: y + sin(theta) * amplitude))
            x += 2
        }
        if points.count >= 2 {
            marks.append(.stroke(points: points, width: 1.05, closed: false))
        }
        y += row
    }
    if marks.isEmpty {
        marks.append(.stroke(
            points: [CGPoint(x: rect.minX, y: rect.midY), CGPoint(x: rect.maxX, y: rect.midY - 1.4), CGPoint(x: rect.maxX, y: rect.midY)],
            width: 1.05,
            closed: false
        ))
    }
    return marks
}

private func crosshatchMarks(in rect: CGRect, phaseX: CGFloat, phaseY: CGFloat) -> [PatternPrimitive] {
    let step: CGFloat = 8
    let shift = positiveMod(phaseX + phaseY, step)
    var marks: [PatternPrimitive] = []
    var downRight = rect.minX - rect.height + shift
    while downRight < rect.maxX {
        marks.append(.stroke(
            points: [
                CGPoint(x: downRight, y: rect.minY),
                CGPoint(x: downRight + rect.height, y: rect.maxY)
            ],
            width: 0.8,
            closed: false
        ))
        downRight += step
    }
    var downLeft = rect.minX + shift
    while downLeft < rect.maxX + rect.height {
        marks.append(.stroke(
            points: [
                CGPoint(x: downLeft, y: rect.minY),
                CGPoint(x: downLeft - rect.height, y: rect.maxY)
            ],
            width: 0.8,
            closed: false
        ))
        downLeft += step
    }
    return marks
}

private func stippleMarks(in rect: CGRect, phaseX: CGFloat, phaseY: CGFloat) -> [PatternPrimitive] {
    let step: CGFloat = 4.7
    let points = origins(in: rect, stepX: step, stepY: step, phaseX: phaseX, phaseY: phaseY)
    var marks: [PatternPrimitive] = []
    for center in points {
        let column = Int((center.x / step).rounded())
        let row = Int((center.y / step).rounded())
        var mix = UInt32(bitPattern: Int32(truncatingIfNeeded: column &* 1_664_525 &+ row &* 2_265_843 &+ 1_013_904_223))
        mix ^= mix >> 16
        mix = mix &* 2_246_822_519
        if mix % 5 == 0 { continue }
        let jx = CGFloat(Int(mix % 5)) - 2
        let jy = CGFloat(Int((mix >> 8) % 5)) - 2
        let diameter: CGFloat = mix % 3 == 0 ? 0.95 : 1.35
        marks.append(disk(CGPoint(x: center.x + jx * 0.55, y: center.y + jy * 0.55), diameter: diameter))
    }
    if marks.isEmpty {
        marks.append(disk(CGPoint(x: rect.midX, y: rect.midY), diameter: 1.2))
    }
    return marks
}

private func positiveMod(_ value: CGFloat, _ modulus: CGFloat) -> CGFloat {
    guard modulus > 0.001 else { return 0 }
    let raw = value.truncatingRemainder(dividingBy: modulus)
    return raw >= 0 ? raw : raw + modulus
}
