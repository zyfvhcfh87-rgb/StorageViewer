import StorageViewerCore
import SwiftUI

/// Indeterminate scan dial. The ring is a moving comet, not a percent.
/// The number in the middle is the size counted so far.
struct DialScanView: View {
    @Environment(ScanSession.self) private var session
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                TickRing(animate: !reduceMotion)
                    .frame(width: 200, height: 200)
                Text(ByteFormat.bytes(session.bytesCounted))
                    .font(.system(size: 26, design: .monospaced))
                    .foregroundStyle(Theme.text)
                    .monospacedDigit()
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Counted \(ByteFormat.bytes(session.bytesCounted))")

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

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !animate)) { timeline in
            let phase = animate
                ? (0.36 + timeline.date.timeIntervalSinceReferenceDate / 1.6)
                    .truncatingRemainder(dividingBy: 1)
                : 0.36
            Canvas { context, size in
                let ticks = 72
                let span = 0.27
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                let radius = min(size.width, size.height) * 0.43
                let start = phase * Double(ticks)
                let count = Double(ticks) * span
                for index in 0..<ticks {
                    let theta = -Double.pi / 2 + (Double(index) / Double(ticks)) * 2 * Double.pi
                    var along = Double(index) - start
                    along.formTruncatingRemainder(dividingBy: Double(ticks))
                    if along < 0 { along += Double(ticks) }
                    let color = tickColor(along: along, count: count)
                    let dx = CGFloat(cos(theta))
                    let dy = CGFloat(sin(theta))
                    var path = Path()
                    path.move(to: CGPoint(x: center.x + dx * (radius - 6), y: center.y + dy * (radius - 6)))
                    path.addLine(to: CGPoint(x: center.x + dx * (radius + 5), y: center.y + dy * (radius + 5)))
                    context.stroke(
                        path,
                        with: .color(color),
                        style: StrokeStyle(lineWidth: 2, lineCap: .round)
                    )
                }
            }
        }
        .accessibilityHidden(true)
    }

    private func tickColor(along: Double, count: Double) -> Color {
        guard along < count else {
            return Color(red: 0x2c / 255, green: 0x2c / 255, blue: 0x2c / 255)
        }
        let t = along / max(1, count - 1)
        if t < 0.45 {
            return Color(red: 0x1d / 255, green: 0x3d / 255, blue: 0x6e / 255)
        }
        if t < 0.75 {
            return Color(red: 0x2c / 255, green: 0x5e / 255, blue: 0xa8 / 255)
        }
        return Theme.accent
    }
}
