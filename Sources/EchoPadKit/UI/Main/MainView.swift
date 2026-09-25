import SwiftUI

/// The main window: conversations and settings in one sidebar, like System Settings.
struct MainView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.appActions) private var actions
    @Binding var selection: MainSection
    @Binding var selectedConversation: UUID?

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section {
                    row(.conversations, "Conversations", "bubble.left.and.bubble.right")
                    row(.destinations, "Save Locations", "folder")
                }
                Section("Settings") {
                    row(.recording, "Recording", "mic")
                    row(.transcription, "Transcription", "text.bubble")
                    row(.general, "General", "gearshape")
                    row(.about, "About", "info.circle")
                }
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 260)
            .safeAreaInset(edge: .bottom) { statusFooter }
        } detail: {
            detail
        }
    }

    private func row(_ section: MainSection, _ title: String, _ symbol: String) -> some View {
        Label(title, systemImage: symbol).tag(section)
    }

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .conversations: ConversationsView(selection: $selectedConversation)
        case .destinations: DestinationsView()
        case .recording: RecordingSettingsView()
        case .transcription: TranscriptionSettingsView()
        case .general: GeneralSettingsView()
        case .about: AboutView()
        }
    }

    private var statusFooter: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Circle().fill(StatusText.color(appState)).frame(width: 7, height: 7)
                Text(StatusText.title(appState)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            if case .failed(let message) = appState.model {
                Text(message).font(.caption2).foregroundStyle(.secondary).lineLimit(3)
                Button("Try Again", action: actions.retryModel).controlSize(.small)
            }
            Button(action: actions.toggleRecording) {
                Label(appState.phase.isRecording ? "Stop" : "Record",
                      systemImage: appState.phase.isRecording ? "stop.fill" : "record.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .tint(appState.phase.isRecording ? .red : .accentColor)
            .disabled(!appState.phase.isRecording && appState.phase.isBusy)
        }
        .padding(12)
    }
}
