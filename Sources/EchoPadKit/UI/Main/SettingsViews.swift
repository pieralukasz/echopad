import AppKit
import ScribeKit
import SwiftUI
import SystemAudioKit

struct RecordingSettingsView: View {
    @Environment(SettingsModel.self) private var settings
    @State private var microphones: [AudioDevice] = []
    @State private var permissions = PermissionSnapshot.current()

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                Toggle("Record my microphone", isOn: $settings.value.recordsMicrophone)
                if settings.value.recordsMicrophone {
                    Picker("Microphone", selection: $settings.value.microphoneUID) {
                        Text("System default").tag(String?.none)
                        ForEach(microphones) { Text($0.name).tag(Optional($0.uid)) }
                    }
                }
            } header: {
                Text("You")
            } footer: {
                Text("Everything on this track is labelled with your name, so it needs no speaker detection.")
            }

            Section {
                Picker("System audio", selection: $settings.value.systemAudio) {
                    ForEach(Settings.SystemAudioChoice.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                if settings.value.systemAudio == .selectedApps {
                    AppListEditor(bundleIDs: $settings.value.systemAudioApps)
                }
                if settings.value.systemAudio != .off {
                    Picker("Capture with", selection: $settings.value.systemAudioBackend) {
                        Text("Core Audio (recommended)").tag(SystemAudioBackend.processTap.rawValue)
                        Text("ScreenCaptureKit").tag(SystemAudioBackend.screenCaptureKit.rawValue)
                    }
                }
            } header: {
                Text("The other side")
            } footer: {
                Text(systemAudioFooter)
            }

            Section("Permissions") {
                PermissionRow(title: "Microphone", status: permissions.microphone, pane: .microphone) {
                    _ = await AudioPermissions.requestMicrophone()
                }
                if settings.value.systemAudio != .off {
                    if settings.value.systemAudioBackend == SystemAudioBackend.screenCaptureKit.rawValue {
                        PermissionRow(title: "Screen Recording", status: permissions.screenRecording, pane: .screenRecording) {
                            _ = CGRequestScreenCaptureAccess()
                        }
                    } else {
                        PermissionRow(title: "System Audio Recording", status: permissions.systemAudio, pane: .systemAudio) {
                            _ = await AudioPermissions.requestSystemAudio()
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Recording")
        .onAppear { microphones = AudioDevices.inputs() }
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
            permissions = PermissionSnapshot.current()
        }
    }

    private var systemAudioFooter: String {
        switch settings.value.systemAudio {
        case .everything: return "Records whatever this Mac plays, from any app, so it works with every call app and browser."
        case .meetingApp: return "When a recording starts from a meeting notification, only that app is recorded. Other recordings capture everything."
        case .selectedApps: return "Only these apps are recorded, including their helper processes (browsers play calls from helpers)."
        case .off: return "Only your microphone is recorded. Speaker detection still separates voices in the room."
        }
    }
}

struct PermissionSnapshot: Equatable {
    var microphone: AudioPermissions.Status
    var systemAudio: AudioPermissions.Status
    var screenRecording: AudioPermissions.Status

    static func current() -> PermissionSnapshot {
        PermissionSnapshot(microphone: AudioPermissions.microphone, systemAudio: AudioPermissions.systemAudio,
                           screenRecording: AudioPermissions.screenRecording)
    }
}

struct PermissionRow: View {
    let title: String
    let status: AudioPermissions.Status
    let pane: AudioPermissions.Pane
    let request: () async -> Void

    var body: some View {
        LabeledContent(title) {
            switch status {
            case .authorized:
                Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            case .notDetermined, .unknown:
                Button("Allow…") { Task { await request() } }
            case .denied:
                Button("Open Privacy Settings…") { NSWorkspace.shared.open(AudioPermissions.settingsURL(for: pane)) }
            }
        }
    }
}

/// Picks apps (by bundle ID) whose audio is recorded.
struct AppListEditor: View {
    @Binding var bundleIDs: [String]

    var body: some View {
        ForEach(bundleIDs, id: \.self) { bundleID in
            HStack {
                appIcon(bundleID)
                Text(appName(bundleID))
                Spacer()
                Button { bundleIDs.removeAll { $0 == bundleID } } label: { Image(systemName: "minus.circle") }
                    .buttonStyle(.borderless)
            }
        }
        Menu("Add App") {
            ForEach(suggestions, id: \.self) { bundleID in
                Button(appName(bundleID)) { bundleIDs.append(bundleID) }
            }
            Divider()
            Button("Choose…") { choose() }
        }
        .fixedSize()
    }

    private var suggestions: [String] {
        let known = MeetingDetector.knownApps.keys.filter {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil
        }
        let running = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap(\.bundleIdentifier)
        return Array(Set(known + running)).filter { !bundleIDs.contains($0) && $0 != Bundle.main.bundleIdentifier }
            .sorted { appName($0).localizedCaseInsensitiveCompare(appName($1)) == .orderedAscending }
    }

    private func appName(_ bundleID: String) -> String {
        if let name = MeetingDetector.knownApps[bundleID] { return name }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return bundleID }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    @ViewBuilder
    private func appIcon(_ bundleID: String) -> some View {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 18, height: 18)
        } else {
            Image(systemName: "app").frame(width: 18, height: 18)
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK, let url = panel.url,
              let bundleID = Bundle(url: url)?.bundleIdentifier, !bundleIDs.contains(bundleID) else { return }
        bundleIDs.append(bundleID)
    }
}

struct TranscriptionSettingsView: View {
    @Environment(SettingsModel.self) private var settings
    @Environment(AppState.self) private var appState
    @Environment(\.appActions) private var actions

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                Picker("Language", selection: $settings.value.language) {
                    Text("Detect automatically").tag("auto")
                    Divider()
                    ForEach(Languages.all, id: \.code) { Text($0.name).tag($0.code) }
                }
            } footer: {
                Text("Parakeet v3 understands 25 European languages. Choosing one helps with short or mixed recordings.")
            }
            Section {
                Toggle("Identify speakers", isOn: $settings.value.identifySpeakers)
                TextField("Your name", text: $settings.value.myName, prompt: Text("Me"))
            } footer: {
                Text("Voices on the system track are told apart and labelled Speaker 1, Speaker 2… You can rename them in each conversation.")
            }
            Section {
                LabeledContent("Model", value: "Parakeet TDT 0.6B v3 + pyannote")
                LabeledContent("Status") { modelStatus }
                LabeledContent("Runs on", value: "Apple Neural Engine, fully offline")
            } header: {
                Text("Speech model")
            } footer: {
                Text("Makes the transcript that is saved after Stop, with or without the live transcript.")
            }
            Section {
                Toggle("Live transcript while recording", isOn: $settings.value.live.enabled)
                if settings.value.live.enabled {
                    Picker("Language", selection: $settings.value.live.language) {
                        Text("Detect automatically").tag(String?.none)
                        Divider()
                        ForEach(Languages.live, id: \.code) { Text($0.name).tag(Optional($0.code)) }
                    }
                    Picker("Model look-ahead", selection: $settings.value.live.latencyMs) {
                        Text("0.56 s").tag(560)
                        Text("1.12 s (recommended)").tag(1120)
                        Text("2.08 s").tag(2080)
                    }
                    Toggle("Tell the other speakers apart", isOn: $settings.value.live.diarize)
                }
                LabeledContent("Model", value: settings.value.live.diarize ? "Nemotron Unified ASR 0.6B + LS-EEND" : "Nemotron Unified ASR 0.6B")
                LabeledContent("Status") { liveModelStatus }
            } header: {
                Text("Live transcript")
            } footer: {
                Text(liveFooter)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Transcription")
    }

    private var liveFooter: String {
        var text = "A draft transcript while you record: open it from the pill or the menu bar, or read it from apps and agents on this Mac (Local API and the echopad live command). "
            + "It loads a second model, about 1.2 GB of memory while recording. Look-ahead is the model's window: "
            + "a shorter one shows words sooner but less accurately; it is not the whole delay. "
            + "Speakers on the system track are anonymous (Speaker 1, 2…)."
        if appState.phase.isBusy { text += " Changes apply to the next recording." }
        return text
    }

    @ViewBuilder
    private var liveModelStatus: some View {
        let live = settings.value.live
        switch appState.liveModel {
        case .preparing:
            HStack {
                ProgressView().controlSize(.small)
                Text("Downloading and preparing…").foregroundStyle(.secondary)
            }
        case .failed(let message):
            HStack {
                Text(message).foregroundStyle(.secondary).lineLimit(2)
                Button("Try Again") { actions.prepareLiveModel() }
            }
        case .downloaded, .notDownloaded:
            if LiveModelCache.isDownloaded(latencyMs: live.latencyMs, diarize: live.diarize) {
                Label("Downloaded", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                HStack {
                    Text("Not downloaded").foregroundStyle(.secondary)
                    Button("Download Now") { actions.prepareLiveModel() }
                        .help("Downloads about 1.2 GB from Hugging Face once and prepares it. Otherwise this happens at the first recording with live transcript on.")
                }
            }
        }
    }

    @ViewBuilder
    private var modelStatus: some View {
        switch appState.model {
        case .ready: Label("Ready", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .notLoaded: Text("Not loaded").foregroundStyle(.secondary)
        case .loading(let fraction, let detail):
            HStack {
                if let fraction { ProgressView(value: fraction).frame(width: 100) } else { ProgressView().controlSize(.small) }
                Text(detail).foregroundStyle(.secondary)
            }
        case .failed(let message):
            HStack {
                Text(message).foregroundStyle(.secondary).lineLimit(2)
                Button("Try Again", action: actions.retryModel)
            }
        }
    }
}

enum Languages {
    struct Language { let code: String; let name: String }

    /// Parakeet v3 languages, by English name.
    static let all: [Language] = [
        ("bg", "Bulgarian"), ("hr", "Croatian"), ("cs", "Czech"), ("da", "Danish"), ("nl", "Dutch"),
        ("en", "English"), ("et", "Estonian"), ("fi", "Finnish"), ("fr", "French"), ("de", "German"),
        ("el", "Greek"), ("hu", "Hungarian"), ("it", "Italian"), ("lv", "Latvian"), ("lt", "Lithuanian"),
        ("mt", "Maltese"), ("pl", "Polish"), ("pt", "Portuguese"), ("ro", "Romanian"), ("ru", "Russian"),
        ("sk", "Slovak"), ("sl", "Slovenian"), ("es", "Spanish"), ("sv", "Swedish"), ("uk", "Ukrainian"),
    ].map { Language(code: $0.0, name: $0.1) }

    /// Languages of the live model, Polish first (the default), then by name.
    static let live: [Language] = LiveEngineFactory.supportedLanguages.map { code in
        Language(code: code, name: all.first { $0.code == code }?.name
                 ?? Locale(identifier: "en").localizedString(forLanguageCode: code) ?? code)
    }
    .sorted { ($0.code == "pl" ? 0 : 1, $0.name) < ($1.code == "pl" ? 0 : 1, $1.name) }
}

struct GeneralSettingsView: View {
    @Environment(SettingsModel.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section("Shortcut") {
                LabeledContent("Start or stop recording") { HotkeyRecorder(hotkey: $settings.value.hotkey) }
            }
            Section {
                Toggle("Notify me when a call starts", isOn: $settings.value.detectsMeetings)
            } header: {
                Text("Meetings")
            } footer: {
                Text("When Zoom, Teams, Meet, Slack, FaceTime or another call app starts using the microphone, EchoPad offers to record. Recordings started this way stop when the call ends.")
            }
            Section("While recording") {
                Toggle("Show the floating recording pill", isOn: $settings.value.showsPill)
                Toggle("Play sounds", isOn: $settings.value.playsSounds)
                Toggle("Ask for a title when stopping", isOn: $settings.value.asksForTitle)
            }
            Section {
                Picker("Keep audio of the last", selection: $settings.value.libraryLimit) {
                    ForEach(Settings.LIBRARY_LIMITS, id: \.self) { limit in
                        Text(limit == 0 ? "None" : "\(limit) conversations").tag(limit)
                    }
                }
                Button("Show Library in Finder") { NSWorkspace.shared.open(AppDirectories.library) }
            } header: {
                Text("Library")
            } footer: {
                Text("EchoPad keeps the original tracks so you can transcribe again. Transcripts in your save locations are never deleted.")
            }
            Section {
                LaunchAtLoginToggle()
            }
        }
        .formStyle(.grouped)
        .navigationTitle("General")
    }
}

struct AboutView: View {
    var body: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 112, height: 112)
            Text("EchoPad").font(.largeTitle.weight(.semibold))
            Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")")
                .foregroundStyle(.secondary)
            Text("Transcribes your calls and conversations on this Mac, with speakers, and saves them wherever you want. Nothing leaves your computer.")
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            HStack(spacing: 16) {
                Link("Website", destination: URL(string: "https://echopad.lucaspiera.com")!)
                Link("Source", destination: URL(string: "https://github.com/pieralukasz/echopad")!)
            }
            Text("Built with ScribeKit, SystemAudioKit and FluidAudio.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("About")
    }
}
