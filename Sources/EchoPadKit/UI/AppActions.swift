import SwiftUI

/// Actions views can trigger without knowing about the controllers behind them.
struct AppActions {
    var toggleRecording: () -> Void = {}
    var discardRecording: () -> Void = {}
    /// Opens the menu bar panel with the sound check.
    var checkSound: () -> Void = {}
    var playTestSound: () -> Void = {}
    var openMainWindow: (MainSection?) -> Void = { _ in }
    var openConversation: (UUID) -> Void = { _ in }
    var reprocess: (UUID) -> Void = { _ in }
    var reexport: (UUID) -> Void = { _ in }
    var renameSpeaker: (UUID, String, String) -> Void = { _, _, _ in }
    var importAudio: () -> Void = {}
    var retryModel: () -> Void = {}
    /// Downloads and prepares the live model on request (never on opening Settings).
    var prepareLiveModel: () -> Void = {}
    /// Opens the live transcript panel; the recording goes on whether it is open or not.
    var showLiveTranscript: () -> Void = {}
    var retryAPI: () -> Void = {}
    /// Copies the API token or webhook secret to the clipboard; false when there is none.
    var copySecret: (IntegrationSecrets.Kind) -> Bool = { _ in false }
    var quit: () -> Void = {}
}

private struct AppActionsKey: EnvironmentKey {
    static let defaultValue = AppActions()
}

extension EnvironmentValues {
    var appActions: AppActions {
        get { self[AppActionsKey.self] }
        set { self[AppActionsKey.self] = newValue }
    }
}

extension MainSection {
    init?(debugName: String) {
        switch debugName {
        case "conversations": self = .conversations
        case "destinations": self = .destinations
        case "recording": self = .recording
        case "transcription": self = .transcription
        case "integrations": self = .integrations
        case "general": self = .general
        default: return nil
        }
    }
}

enum MainSection: Hashable {
    case conversations
    case destinations
    case recording
    case transcription
    case integrations
    case general
    case about
}

/// Settings wrapper that saves on every change and tells the app to apply it.
@MainActor
@Observable
final class SettingsModel {
    var value: Settings {
        didSet {
            guard value != oldValue else { return }
            try? SettingsStore.save(value)
            onChange?(value, oldValue)
        }
    }

    var onChange: ((Settings, Settings) -> Void)?

    init(_ value: Settings) {
        self.value = value
    }
}
