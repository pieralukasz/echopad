import AppKit

/// Menu bar icons, drawn in code as templates so they follow the menu bar's appearance.
/// The idle icon is the app icon's two speech bubbles.
@MainActor
enum StatusBarIcons {
    static let SIZE = NSSize(width: 20, height: 16)

    static func logo() -> NSImage {
        draw { _ in
            let front = NSBezierPath()
            // Front bubble with tail, bottom-left.
            front.appendRoundedRect(NSRect(x: 1.5, y: 5.5, width: 11, height: 8), xRadius: 2.6, yRadius: 2.6)
            front.move(to: NSPoint(x: 4, y: 6))
            front.line(to: NSPoint(x: 3.2, y: 2.8))
            front.line(to: NSPoint(x: 7, y: 5.6))
            front.lineWidth = 1.5
            front.lineJoinStyle = .round
            front.stroke()
            // Back bubble, peeking out on the right.
            let back = NSBezierPath()
            back.move(to: NSPoint(x: 14.2, y: 10.5))
            back.line(to: NSPoint(x: 16.3, y: 10.5))
            back.curve(to: NSPoint(x: 18.5, y: 8.3), controlPoint1: NSPoint(x: 17.5, y: 10.5), controlPoint2: NSPoint(x: 18.5, y: 9.5))
            back.line(to: NSPoint(x: 18.5, y: 5))
            back.curve(to: NSPoint(x: 17, y: 3.1), controlPoint1: NSPoint(x: 18.5, y: 4), controlPoint2: NSPoint(x: 17.9, y: 3.3))
            back.line(to: NSPoint(x: 17, y: 1))
            back.line(to: NSPoint(x: 14.3, y: 3))
            back.line(to: NSPoint(x: 10, y: 3))
            back.curve(to: NSPoint(x: 8.6, y: 4.2), controlPoint1: NSPoint(x: 9.2, y: 3), controlPoint2: NSPoint(x: 8.6, y: 3.5))
            back.lineWidth = 1.5
            back.lineCapStyle = .round
            back.lineJoinStyle = .round
            back.stroke()
            // Waveform inside the front bubble.
            for (index, height) in [2.0, 4.0, 3.0].enumerated() {
                let x = 4.6 + Double(index) * 2.2
                let bar = NSBezierPath(roundedRect: NSRect(x: x, y: 9.5 - height / 2, width: 1.3, height: height),
                                       xRadius: 0.65, yRadius: 0.65)
                bar.fill()
            }
        }
    }

    /// Frames of a waveform for the recording animation.
    static func recordingFrames(count: Int = 24) -> [NSImage] {
        (0..<count).map { frame in
            draw { _ in
                let dot = NSBezierPath(ovalIn: NSRect(x: 1, y: 5.5, width: 5, height: 5))
                dot.fill()
                for bar in 0..<5 {
                    let phase = Double(frame) / Double(count) * 2 * .pi + Double(bar) * 0.9
                    let height = 3 + 9 * (0.5 + 0.5 * sin(phase)) * (bar % 2 == 0 ? 1 : 0.75)
                    let rect = NSRect(x: 8.5 + Double(bar) * 2.4, y: 8 - height / 2, width: 1.5, height: height)
                    NSBezierPath(roundedRect: rect, xRadius: 0.75, yRadius: 0.75).fill()
                }
            }
        }
    }

    /// Frames of three dots for processing.
    static func workingFrames(count: Int = 24) -> [NSImage] {
        (0..<count).map { frame in
            draw { _ in
                for index in 0..<3 {
                    let phase = Double(frame) / Double(count) * 2 * .pi - Double(index) * 0.8
                    let lift = 2.5 * max(0, sin(phase))
                    let alpha = 0.4 + 0.6 * (sin(phase) + 1) / 2
                    NSColor.black.withAlphaComponent(alpha).setFill()
                    NSBezierPath(ovalIn: NSRect(x: 3.5 + Double(index) * 5, y: 6 + lift, width: 3.2, height: 3.2)).fill()
                }
            }
        }
    }

    static func symbol(_ name: String) -> NSImage {
        let configuration = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) ?? logo()
    }

    private static func draw(_ body: @escaping (NSRect) -> Void) -> NSImage {
        let image = NSImage(size: SIZE, flipped: false) { rect in
            NSColor.black.setStroke()
            NSColor.black.setFill()
            body(rect)
            return true
        }
        image.isTemplate = true
        return image
    }
}
