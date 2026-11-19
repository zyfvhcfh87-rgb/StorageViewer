import CoreGraphics
import Foundation

/// A single active inward-flowing wave at a moment in time.
public struct HoverWaveSample: Equatable, Sendable {
    /// Index of this wave in the staggered train (0..<waveCount).
    public var index: Int
    /// Normalized lifecycle progress in `0..<1` (0 = perimeter, 1 = center).
    public var progress: CGFloat
    /// Eased inward travel distance in `0...1`.
    public var travel: CGFloat
    /// Smooth fade-in / fade-out opacity envelope in `0...1`.
    public var envelope: CGFloat
    /// Superellipse exponent morphing from rectangular (`~11`) at the rim to elliptical (`2`) at the center.
    public var superellipseExponent: CGFloat
    /// Scale of the wavefront relative to the block's outer bounds (`~0.985` down to `~0.16`).
    public var scale: CGFloat
}

/// Geometry and timing for the treemap block inward-wave hover animation.
public enum HoverWaveField {
    /// Duration of one wave traveling from perimeter to center, in seconds.
    public static let cycleDuration: Double = 2.1
    /// Number of evenly staggered overlapping waves in the train.
    public static let waveCount: Int = 3
    /// Minimum block short dimension (in points) that renders traveling waves.
    public static let minimumWaveDimension: CGFloat = 18

    /// Returns all waves that have launched and are visible at `elapsed` seconds since hover began.
    public static func activeWaves(elapsed: Double) -> [HoverWaveSample] {
        guard elapsed.isFinite, elapsed >= 0 else { return [] }
        let step = cycleDuration / Double(waveCount)
        // Small lead-in so Wave 0 is immediately visible peeling off the rim on hover enter.
        let shifted = elapsed + 0.06
        var result: [HoverWaveSample] = []
        result.reserveCapacity(waveCount)
        for index in 0..<waveCount {
            let launchTime = Double(index) * step
            guard shifted >= launchTime else { continue }
            let age = shifted - launchTime
            let rawProgress = age.truncatingRemainder(dividingBy: cycleDuration) / cycleDuration
            let progress = CGFloat(min(1, max(0, rawProgress)))
            let sample = sampleForProgress(progress, index: index)
            if sample.envelope > 0.005 {
                result.append(sample)
            }
        }
        return result
    }

    /// Computes wave geometry parameters for a given normalized lifecycle progress `u` in `0...1`.
    public static func sampleForProgress(_ progress: CGFloat, index: Int) -> HoverWaveSample {
        let u = min(1, max(0, progress))
        // Confident launch from perimeter, gentle deceleration toward center.
        let travel = 1 - pow(1 - u, 1.55)
        let fadeIn = smoothstep(edge0: 0.0, edge1: 0.09, x: u)
        let fadeOut = 1 - smoothstep(edge0: 0.48, edge1: 0.96, x: u)
        let envelope = fadeIn * fadeOut
        // Rapidly softens from a rounded-perimeter contour (p ≈ 6.5) into a fluid ellipse (p = 2).
        let exponent = 2.0 + 4.5 * pow(1 - travel, 3.0)
        let scale = 0.985 - travel * 0.875
        return HoverWaveSample(
            index: index,
            progress: u,
            travel: travel,
            envelope: envelope,
            superellipseExponent: exponent,
            scale: scale
        )
    }

    /// Subtle breathing boost on the outer COSS rim (`0...1`) as each fresh wave launches.
    public static func rimPulse(elapsed: Double) -> CGFloat {
        guard elapsed.isFinite, elapsed >= 0 else { return 0 }
        let step = cycleDuration / Double(waveCount)
        let local = elapsed.truncatingRemainder(dividingBy: step) / step
        let window = 0.34
        guard local >= 0, local < window else { return 0 }
        return CGFloat(sin(.pi * local / window))
    }

    /// Samples a closed, organically undulating superellipse wavefront inside `rect`.
    /// Uses radial Lp-norm parameterization so vertices stay evenly distributed around the perimeter.
    public static func contourPoints(
        in rect: CGRect,
        sample: HoverWaveSample,
        elapsed: Double,
        segments: Int = 72,
        rippleMultiplier: CGFloat = 1.0
    ) -> [CGPoint] {
        guard rect.width >= minimumWaveDimension,
              rect.height >= minimumWaveDimension,
              segments >= 12,
              elapsed.isFinite
        else {
            return []
        }

        let cx = rect.midX
        let cy = rect.midY
        let halfW = rect.width * 0.5
        let halfH = rect.height * 0.5
        let rx = halfW * sample.scale
        let ry = halfH * sample.scale
        let minHalf = min(halfW, halfH)
        let p = Double(sample.superellipseExponent)
        let invP = 1.0 / p

        // Ripple tapers to zero at both the outer border and the center convergence.
        let rippleEnvelope = sin(CGFloat.pi * sample.travel)
        let maxAmp = min(minHalf * 0.062, 7.5) * rippleEnvelope * rippleMultiplier
        let seed = Double(sample.index) * 2.0943951024 // 2π / 3

        let minX = rect.minX + 0.5
        let maxX = rect.maxX - 0.5
        let minY = rect.minY + 0.5
        let maxY = rect.maxY - 0.5

        var points: [CGPoint] = []
        points.reserveCapacity(segments)

        let twoPi = 2.0 * Double.pi
        for i in 0..<segments {
            let phi = (Double(i) / Double(segments)) * twoPi
            let c = cos(phi)
            let s = sin(phi)
            let norm = pow(pow(abs(c), p) + pow(abs(s), p), invP)
            let rp = norm > 1e-9 ? CGFloat(1.0 / norm) : 1.0

            let h1 = sin(3.0 * phi + elapsed * 1.85 + seed)
            let h2 = sin(5.0 * phi - elapsed * 1.25 + seed * 1.6)
            let h3 = cos(2.0 * phi + elapsed * 0.90 - seed * 0.7)
            let signal = CGFloat(0.54 * h1 + 0.30 * h2 + 0.16 * h3)
            let offset = maxAmp * signal

            let ux = CGFloat(c)
            let uy = CGFloat(s)
            let rawX = cx + rx * ux * rp + ux * offset
            let rawY = cy + ry * uy * rp + uy * offset
            let clampedX = min(maxX, max(minX, rawX))
            let clampedY = min(maxY, max(minY, rawY))
            points.append(CGPoint(x: clampedX, y: clampedY))
        }
        return points
    }

    private static func smoothstep(edge0: CGFloat, edge1: CGFloat, x: CGFloat) -> CGFloat {
        guard edge1 > edge0 else { return x >= edge1 ? 1 : 0 }
        let t = min(1, max(0, (x - edge0) / (edge1 - edge0)))
        return t * t * (3 - 2 * t)
    }
}

/// Tracks smooth enter/exit hover intensity and per-block wave clocks across treemap blocks.
/// Moving from block A to block B lets A glide out smoothly while B blooms in from phase 0.
public struct HoverTrailState: Equatable, Sendable {
    public struct Entry: Equatable, Sendable {
        public var id: UUID
        /// Timestamp when this hover session started (drives the wave clock from 0).
        public var startTime: Double
        /// Smoothly interpolated intensity in `0...1`.
        public var intensity: CGFloat
        public var isHovered: Bool
    }

    public static let fadeInDuration: Double = 0.16
    public static let fadeOutDuration: Double = 0.24

    public private(set) var hoveredID: UUID?
    public private(set) var entries: [UUID: Entry] = [:]
    private var lastUpdateTime: Double?

    public init() {}

    /// True when nothing is hovered and all fade-out trails have settled to zero.
    public var isIdle: Bool {
        hoveredID == nil && entries.isEmpty
    }

    /// Updates which block is currently under the cursor.
    public mutating func setHovered(_ id: UUID?, at now: Double) {
        advance(to: now)
        guard hoveredID != id else { return }
        if let previous = hoveredID, var entry = entries[previous] {
            entry.isHovered = false
            entries[previous] = entry
        }
        hoveredID = id
        if let id {
            if var existing = entries[id] {
                existing.isHovered = true
                // If it had nearly faded out, restart its wave clock cleanly from the perimeter.
                if existing.intensity < 0.08 {
                    existing.startTime = now
                }
                entries[id] = existing
            } else {
                entries[id] = Entry(id: id, startTime: now, intensity: 0.08, isHovered: true)
            }
        }
        lastUpdateTime = now
    }

    /// Clears all hover trails immediately (e.g. when navigating to another folder).
    public mutating func reset() {
        hoveredID = nil
        entries.removeAll(keepingCapacity: true)
        lastUpdateTime = nil
    }

    /// Advances smooth fade-in and fade-out intensities to `now` and prunes finished trails.
    public mutating func advance(to now: Double) {
        guard now.isFinite else { return }
        let dt: Double
        if let last = lastUpdateTime {
            dt = min(0.1, max(0, now - last))
        } else {
            dt = 0
        }
        lastUpdateTime = now
        guard dt > 0 else { return }

        let upStep = CGFloat(dt / Self.fadeInDuration)
        let downStep = CGFloat(dt / Self.fadeOutDuration)
        var finished: [UUID] = []
        for (id, var entry) in entries {
            if entry.isHovered {
                entry.intensity = min(1, entry.intensity + upStep)
                entries[id] = entry
            } else {
                entry.intensity = max(0, entry.intensity - downStep)
                if entry.intensity <= 0.001 {
                    finished.append(id)
                } else {
                    entries[id] = entry
                }
            }
        }
        for id in finished {
            entries.removeValue(forKey: id)
        }
    }

    /// Returns a snapshot of `(intensity, elapsed)` for `id` at `now` without mutating state.
    public func state(for id: UUID, at now: Double) -> (intensity: CGFloat, elapsed: Double)? {
        guard let entry = entries[id] else { return nil }
        let dt = lastUpdateTime.map { min(0.1, max(0, now - $0)) } ?? 0
        let raw: CGFloat
        if entry.isHovered {
            raw = min(1, entry.intensity + CGFloat(dt / Self.fadeInDuration))
        } else {
            raw = max(0, entry.intensity - CGFloat(dt / Self.fadeOutDuration))
        }
        guard raw > 0.004 else { return nil }
        // Smooth ease-out curve for crisp, tactile COSS-style response.
        let eased = 1 - pow(1 - raw, 2.2)
        return (eased, max(0, now - entry.startTime))
    }
}
