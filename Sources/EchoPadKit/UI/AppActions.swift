import SwiftUI

/// Actions views can trigger without knowing about the controllers behind them.
struct AppActions {
    var toggleRecording: () -> Void = {}
    var discardRecording: () -> Void = {}
    var openMainWindow: (MainSection?) -> Void = { _ in }
    var openConversation: (UUID) -> Void = { _ in }
    var reprocess: (UUID) -> Void = { _ in }
    var reexport: (UUID) -> Void = { _ in }
    var renameSpeaker: (UUID, String, String) -> Void = { _, _, _ in }
    var importAudio: () -> Void = {}
    var retryModel: () -> Void = {}
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

enum MainSection: Hashable {
    case conversations
    case destinations
    case recording
    case transcription
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
