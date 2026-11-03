import SystemAudioKit

/// Works out why the other side of a call stays silent and which fix to offer.
/// Pure logic; ``SoundCheckView`` shows the steps and runs the fixes.
public enum SoundCheck {
    /// What the system track of the current recording captures.
    public enum Scope: Equatable, Sendable {
        case everything
        /// Only these apps, by display name.
        case apps([String])
    }

    public enum TestResult: Equatable, Sendable {
        case running, heard, notHeard
    }

    public enum Fix: Equatable, Sendable {
        case allowPermission(AudioPermissions.Pane)
        case openPrivacySettings(AudioPermissions.Pane)
        case openRecordingSettings
        case playTestSound
    }

    public struct Step: Equatable, Sendable, Identifiable {
        public enum Kind: Equatable, Sendable { case ok, problem, info }

        public var id: String
        public var kind: Kind
        public var title: String
        public var detail: String?
        public var fix: Fix?
    }

    public static func steps(backend: SystemAudioBackend, permission: AudioPermissions.Status,
                             scope: Scope, test: TestResult?) -> [Step] {
        let pane: AudioPermissions.Pane = backend == .screenCaptureKit ? .screenRecording : .systemAudio
        let name = backend == .screenCaptureKit ? "Screen Recording" : "System Audio Recording"
        var steps = [permissionStep(permission, name: name, pane: pane), scopeStep(scope)]
        // The test sound plays from another process, so a capture limited to some apps never hears it.
        if scope == .everything {
            steps.append(testStep(test, permissionAllowed: permission == .authorized, pane: pane))
        }
        return steps
    }

    public static func hasProblem(_ steps: [Step]) -> Bool {
        steps.contains { $0.kind == .problem }
    }

    /// "Zoom", "Zoom and Slack", "Zoom, Slack and 2 more".
    static func list(_ names: [String]) -> String {
        switch names.count {
        case 0: return "selected apps"
        case 1: return names[0]
        case 2: return "\(names[0]) and \(names[1])"
        default: return "\(names[0]), \(names[1]) and \(names.count - 2) more"
        }
    }

    private static func permissionStep(_ status: AudioPermissions.Status, name: String,
                                       pane: AudioPermissions.Pane) -> Step {
        switch status {
        case .authorized:
            return Step(id: "permission", kind: .ok, title: "\(name) is allowed")
        case .notDetermined:
            return Step(id: "permission", kind: .problem, title: "\(name) is not allowed yet",
                        detail: "Allow it, then start a new recording.", fix: .allowPermission(pane))
        case .denied:
            return Step(id: "permission", kind: .problem, title: "\(name) is off for EchoPad",
                        detail: "Turn EchoPad on in Privacy & Security, then start a new recording.",
                        fix: .openPrivacySettings(pane))
        case .unknown:
            return Step(id: "permission", kind: .info, title: "Can't read the \(name) permission",
                        detail: "Check that EchoPad is on in Privacy & Security.", fix: .openPrivacySettings(pane))
        }
    }

    private static func scopeStep(_ scope: Scope) -> Step {
        switch scope {
        case .everything:
            return Step(id: "scope", kind: .ok, title: "Recording sound from every app")
        case .apps(let names):
            return Step(id: "scope", kind: .info, title: "Recording only \(list(names))",
                        detail: "If the call plays from another app, set System audio to Everything on this Mac and start a new recording.",
                        fix: .openRecordingSettings)
        }
    }

    private static func testStep(_ test: TestResult?, permissionAllowed: Bool, pane: AudioPermissions.Pane) -> Step {
        switch test {
        case nil:
            return Step(id: "test", kind: .info, title: "Test the whole path",
                        detail: "EchoPad plays a short sound on this Mac and listens for it. The sound ends up in this recording.",
                        fix: .playTestSound)
        case .running:
            return Step(id: "test", kind: .info, title: "Listening for the test sound…")
        case .heard:
            return Step(id: "test", kind: .ok, title: "EchoPad heard the test sound",
                        detail: "Capture works. The other side is probably muted or not talking yet.")
        case .notHeard where permissionAllowed:
            return Step(id: "test", kind: .problem, title: "EchoPad heard nothing",
                        detail: "macOS can keep a stale permission after EchoPad is updated. Turn EchoPad off and on in Privacy & Security, then start a new recording. If that does not help, set Capture with to ScreenCaptureKit.",
                        fix: .openPrivacySettings(pane))
        case .notHeard:
            return Step(id: "test", kind: .problem, title: "EchoPad heard nothing",
                        detail: "Fix the permission above, then start a new recording.", fix: .playTestSound)
        }
    }
}
