import SwiftUI

/// Bars following a level history, newest on the right.
struct WaveformView: View {
    let levels: [Float]
    var barWidth: CGFloat = 3
    var spacing: CGFloat = 2.5
    var maxHeight: CGFloat = 22
    var minHeight: CGFloat = 3

    var body: some View {
        HStack(alignment: .center, spacing: spacing) {
            ForEach(levels.indices, id: \.self) { index in
                Capsule()
                    .fill(.primary.opacity(0.35 + 0.65 * Double(levels[index])))
                    .frame(width: barWidth, height: height(for: index))
            }
        }
        .frame(height: maxHeight)
        .animation(.smooth(duration: 0.12), value: levels)
        .accessibilityHidden(true)
    }

    private func height(for index: Int) -> CGFloat {
        let position = Double(index) / Double(max(levels.count - 1, 1))
        let envelope = 0.55 + 0.45 * sin(position * .pi)
        return minHeight + (maxHeight - minHeight) * CGFloat(levels[index]) * CGFloat(envelope)
    }
}

/// Three dots that ripple while EchoPad works.
struct WorkingDots: View {
    var body: some View {
        TimelineView(.animation) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 5) {
                ForEach(0..<3, id: \.self) { index in
                    let phase = time * 5 - Double(index) * 0.7
                    Circle()
                        .fill(.primary)
                        .frame(width: 6, height: 6)
                        .opacity(0.35 + 0.65 * (sin(phase) + 1) / 2)
                        .offset(y: -3 * max(0, sin(phase)))
                }
            }
        }
        .accessibilityLabel("Working")
    }
}

/// A pulsing red dot.
struct RecordingDot: View {
    var size: CGFloat = 8

    var body: some View {
        Circle()
            .fill(.red)
            .frame(width: size, height: size)
            .phaseAnimator([1.0, 0.35]) { dot, opacity in dot.opacity(opacity) } animation: { _ in .easeInOut(duration: 0.7) }
    }
}

/// Elapsed time since `start`, updating every second.
struct ElapsedText: View {
    let start: Date

    var body: some View {
        TimelineView(.periodic(from: start, by: 1)) { context in
            Text(clockText(context.date.timeIntervalSince(start)))
                .monospacedDigit()
        }
    }
}
