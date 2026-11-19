import StorageViewerCore
import SwiftUI

/// Indeterminate scan dial. The ring is a moving comet, not a percent.
/// The number in the middle is the size counted so far.
struct DialScanView: View {
    @Environment(ScanSession.self) private var session
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let countedText = ByteFormat.bytes(session.bytesCounted)
        VStack(spacing: 0) {
            ZStack {
                TickRing(animate: !reduceMotion)
                    .frame(width: 200, height: 200)
                Text(countedText)
                    .font(.system(size: 26, design: .monospaced))
                    .foregroundStyle(Theme.text)
                    .monospacedDigit()
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Counted \(countedText)")

            Text("\(ByteFormat.count(session.filesSeen)) files")
                .font(.system(size: 12))
                .foregroundStyle(Theme.text)
                .monospacedDigit()
                .padding(.top, 18)

            Text("\(ByteFormat.count(session.skippedCount)) unreadable")
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondary)
                .monospacedDigit()
                .padding(.top, 6)

            Button("Cancel") { session.cancel() }
                .buttonStyle(QuietButtonStyle(prominent: true))
                .padding(.top, 16)
                .accessibilityIdentifier("cancel-scan")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("scan-dial")
    }
}

private struct TickRing: View {
    var animate: Bool

    private static let inactiveColor = Color(red: 0x2c / 255, green: 0x2c / 255, blue: 0x2c / 255)
    private static let tailColor = Color(red: 0x1d / 255, green: 0x3d / 255, blue: 0x6e / 255)
    private static let midColor = Color(red: 0x2c / 255, green: 0x5e / 255, blue: 0xa8 / 255)
    private static let tickStyle = StrokeStyle(lineWidth: 2, lineCap: .round)

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !animate)) { timeline in
            let rawPhase = animate
                ? (0.36 + timeline.date.timeIntervalSinceReferenceDate / 1.6)
                    .truncatingRemainder(dividingBy: 1)
                : 0.36
            let phase = rawPhase < 0 ? rawPhase + 1 : rawPhase
            Canvas { context, size in
                let ticks = 72
                let span = 0.27
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                let radius = min(size.width, size.height) * 0.43
                let inner = radius - 6
                let outer = radius + 5
                let start = phase * Double(ticks)
                let count = Double(ticks) * span
                let denom = max(1, count - 1)

                var inactive = Path()
                var tail = Path()
                var mid = Path()
                var head = Path()

                for index in 0..<ticks {
                    let theta = -Double.pi / 2 + (Double(index) / Double(ticks)) * 2 * Double.pi
                    var along = Double(index) - start
                    along.formTruncatingRemainder(dividingBy: Double(ticks))
                    if along < 0 { along += Double(ticks) }

                    let dx = CGFloat(cos(theta))
                    let dy = CGFloat(sin(theta))
                    let p0 = CGPoint(x: center.x + dx * inner, y: center.y + dy * inner)
                    let p1 = CGPoint(x: center.x + dx * outer, y: center.y + dy * outer)

                    if along >= count {
                        inactive.move(to: p0)
                        inactive.addLine(to: p1)
                    } else {
                        let t = along / denom
                        if t < 0.45 {
                            tail.move(to: p0)
                            tail.addLine(to: p1)
                        } else if t < 0.75 {
                            mid.move(to: p0)
                            mid.addLine(to: p1)
                        } else {
                            head.move(to: p0)
                            head.addLine(to: p1)
                        }
                    }
                }

                context.stroke(inactive, with: .color(Self.inactiveColor), style: Self.tickStyle)
                context.stroke(tail, with: .color(Self.tailColor), style: Self.tickStyle)
                context.stroke(mid, with: .color(Self.midColor), style: Self.tickStyle)
                context.stroke(head, with: .color(Theme.accent), style: Self.tickStyle)
            }
        }
        .accessibilityHidden(true)
    }
}
