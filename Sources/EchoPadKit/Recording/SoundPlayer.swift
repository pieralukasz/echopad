import AppKit

/// Short system sounds for start, stop, saved and error.
@MainActor
public final class SoundPlayer {
    public enum Cue {
        case start, stop, saved, error

        var name: NSSound.Name {
            switch self {
            case .start: return "Tink"
            case .stop: return "Pop"
            case .saved: return "Glass"
            case .error: return "Basso"
            }
        }
    }

    public var isEnabled = true

    public init() {}

    public func play(_ cue: Cue) {
        guard isEnabled, let sound = NSSound(named: cue.name) else { return }
        sound.volume = 0.35
        sound.play()
    }
}
