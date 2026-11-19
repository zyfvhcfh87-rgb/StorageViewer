import CoreGraphics
import Foundation
import StorageViewerCore
import XCTest

final class HoverWaveTests: XCTestCase {
    func testWavesLaunchStaggeredFromPerimeterAndLoopContinuously() {
        let early = HoverWaveField.activeWaves(elapsed: 0.2)
        XCTAssertEqual(early.count, 1)
        XCTAssertEqual(early[0].index, 0)
        XCTAssertLessThan(early[0].progress, 0.2)

        let secondWaveTime = HoverWaveField.cycleDuration / Double(HoverWaveField.waveCount) + 0.2
        let mid = HoverWaveField.activeWaves(elapsed: secondWaveTime)
        XCTAssertEqual(mid.count, 2)
        XCTAssertGreaterThan(mid[0].progress, mid[1].progress)

        let steady = HoverWaveField.activeWaves(elapsed: HoverWaveField.cycleDuration + 0.35)
        XCTAssertGreaterThanOrEqual(steady.count, 2)
        XCTAssertLessThanOrEqual(steady.count, HoverWaveField.waveCount)
    }

    func testWaveConvergesInwardAndSoftensFromPerimeterToEllipse() {
        let nearEdge = HoverWaveField.sampleForProgress(0.05, index: 0)
        let midFlight = HoverWaveField.sampleForProgress(0.45, index: 0)
        let nearCenter = HoverWaveField.sampleForProgress(0.85, index: 0)

        XCTAssertGreaterThan(nearEdge.scale, midFlight.scale)
        XCTAssertGreaterThan(midFlight.scale, nearCenter.scale)
        XCTAssertGreaterThan(nearEdge.superellipseExponent, midFlight.superellipseExponent)
        XCTAssertGreaterThan(midFlight.superellipseExponent, nearCenter.superellipseExponent)
        XCTAssertEqual(HoverWaveField.sampleForProgress(1.0, index: 0).superellipseExponent, 2.0, accuracy: 0.001)
    }

    func testContourPointsStayWithinBlockBoundsAcrossAspectRatios() {
        let rects = [
            CGRect(x: 10, y: 20, width: 220, height: 220),
            CGRect(x: 0, y: 0, width: 480, height: 72),
            CGRect(x: 12, y: 8, width: 64, height: 340),
            CGRect(x: 4, y: 4, width: 24, height: 20),
        ]
        for rect in rects {
            let sample = HoverWaveField.sampleForProgress(0.4, index: 1)
            let points = HoverWaveField.contourPoints(in: rect, sample: sample, elapsed: 1.5, segments: 64)
            XCTAssertEqual(points.count, 64)
            for point in points {
                XCTAssertTrue(point.x.isFinite && point.y.isFinite)
                XCTAssertGreaterThanOrEqual(point.x, rect.minX)
                XCTAssertLessThanOrEqual(point.x, rect.maxX)
                XCTAssertGreaterThanOrEqual(point.y, rect.minY)
                XCTAssertLessThanOrEqual(point.y, rect.maxY)
            }
        }
    }

    func testTinyOrDegenerateRectsSkipWaveContours() {
        let sample = HoverWaveField.sampleForProgress(0.3, index: 0)
        XCTAssertTrue(HoverWaveField.contourPoints(in: .zero, sample: sample, elapsed: 0.5).isEmpty)
        XCTAssertTrue(HoverWaveField.contourPoints(in: CGRect(x: 0, y: 0, width: 120, height: 10), sample: sample, elapsed: 0.5).isEmpty)
        XCTAssertTrue(HoverWaveField.contourPoints(in: CGRect(x: 0, y: 0, width: 12, height: 120), sample: sample, elapsed: 0.5).isEmpty)
        XCTAssertTrue(HoverWaveField.activeWaves(elapsed: -1).isEmpty)
        XCTAssertTrue(HoverWaveField.activeWaves(elapsed: .nan).isEmpty)
    }

    func testTrailStateSmoothlyEntersSwitchesAndDecaysToIdle() {
        let blockA = UUID()
        let blockB = UUID()
        var trail = HoverTrailState()
        XCTAssertTrue(trail.isIdle)

        // Enter block A
        trail.setHovered(blockA, at: 10.0)
        XCTAssertFalse(trail.isIdle)
        trail.advance(to: 10.08)
        let midA = trail.state(for: blockA, at: 10.08)
        XCTAssertNotNil(midA)
        XCTAssertGreaterThan(midA!.intensity, 0.4)
        XCTAssertLessThan(midA!.intensity, 1.0)
        XCTAssertEqual(midA!.elapsed, 0.08, accuracy: 0.001)

        // Reach full hover intensity
        trail.advance(to: 10.20)
        let fullA = trail.state(for: blockA, at: 10.20)
        XCTAssertEqual(fullA?.intensity ?? 0, 1.0, accuracy: 0.001)

        // Switch to block B: A begins fading out while B starts fresh from elapsed 0
        trail.setHovered(blockB, at: 10.50)
        trail.advance(to: 10.58)
        let fadingA = trail.state(for: blockA, at: 10.58)
        let enteringB = trail.state(for: blockB, at: 10.58)
        XCTAssertNotNil(fadingA)
        XCTAssertNotNil(enteringB)
        XCTAssertLessThan(fadingA!.intensity, 1.0)
        XCTAssertEqual(enteringB!.elapsed, 0.08, accuracy: 0.001)

        // Leave all blocks and advance past fadeOutDuration (in realistic frame steps)
        trail.setHovered(nil, at: 11.00)
        var t = 11.00
        while t < 11.40 {
            t += 1.0 / 60.0
            trail.advance(to: t)
        }
        XCTAssertTrue(trail.isIdle)
        XCTAssertNil(trail.state(for: blockA, at: t))
        XCTAssertNil(trail.state(for: blockB, at: t))
    }
}
