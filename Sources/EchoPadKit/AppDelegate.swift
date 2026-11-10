import AppKit
import ScribeKit
import SwiftUI
import SystemAudioKit
import UniformTypeIdentifiers

/// Wires state, recording, meeting detection and UI together.
@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate {
    private let appState = AppState()
    private let library = ConversationLibrary()
    private let settings = SettingsModel(SettingsStore.load())
    private let hotkey = GlobalHotkey()
    private let sounds = SoundPlayer()
    private let meetings = MeetingNotifier()
    private var recorder: RecordingController!
    private var statusBar: StatusBarController!
    private var pill: RecordingPillController!
    private var liveTranscriptPanel: LiveTranscriptPanelController?
    private var windows: WindowCoordinator!
    private var modelTask: Task<Void, Never>?
    private var integrations: IntegrationHub!

    public override init() {
        super.init()
    }

    /// Text fields only get ⌘X/⌘C/⌘V/⌘A/⌘Z through menu items, so an app without
    /// a main menu just beeps. Shown in the menu bar while a window is open.
    private static func makeMainMenu() -> NSMenu {
        let main = NSMenu()

        let app = NSMenu()
        app.addItem(withTitle: "Quit EchoPad", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let appItem = NSMenuItem(title: "EchoPad", action: nil, keyEquivalent: "")
        appItem.submenu = app
        main.addItem(appItem)

        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        editItem.submenu = edit
        main.addItem(editItem)

        return main
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        NSApp.mainMenu = Self.makeMainMenu()
        recorder = RecordingController(appState: appState, library: library, settings: settings.value)
        recorder.sounds = sounds
        recorder.askForTitle = { [weak self] current in await self?.askForTitle(current) }
        recorder.onError = { message in print("EchoPad: \(message)") }
        integrations = IntegrationHub(controller: recorder, libraryDirectory: library.directory)
        recorder.events = integrations.events

        windows = WindowCoordinator(environment: { [unowned self] view in self.inject(view) })
        statusBar = StatusBarController(appState: appState, content: inject(AnyView(MenuBarPanel())))
        statusBar.onRightClick = { [weak self] in self?.recorder.toggle() }
        pill = RecordingPillController(appState: appState) { [unowned self] mover in inject(AnyView(RecordingPillView(mover: mover))) }

        meetings.isSuppressed = { [weak self] in self?.appState.phase.isBusy ?? false }
        meetings.onRecord = { [weak self] meeting in
            Task { await self?.recorder.start(meeting: meeting) }
        }
        meetings.onMeetingEnded = { [weak self] meeting in self?.recorder.meetingEnded(meeting) }
        meetings.onActiveChange = { [weak self] meeting in self?.appState.detectedMeeting = meeting?.appName }

        settings.onChange = { [weak self] new, old in self?.apply(new, old: old) }
        apply(settings.value, old: nil)
        loadModels()

        // Test copies only: force dark mode in this app without touching the system appearance.
        if ProcessInfo.processInfo.environment["ECHOPAD_APPEARANCE"] == "dark" {
            NSApp.appearance = NSAppearance(named: .darkAqua)
        }
        // Test copies open one section at launch for window checks (never the installed app's default).
        if let raw = ProcessInfo.processInfo.environment["ECHOPAD_OPEN_SECTION"],
           let section = MainSection(debugName: raw) {
            windows.showMain(section: section)
            if let size = ProcessInfo.processInfo.environment["ECHOPAD_WINDOW_SIZE"]?.split(separator: "x").compactMap({ Double($0) }),
               size.count == 2, let window = NSApp.windows.first(where: { $0.frameAutosaveName == "EchoPadMain" }) {
                window.setContentSize(NSSize(width: size[0], height: size[1]))
                window.center()
            }
        }

        if !settings.value.hasCompletedOnboarding {
            windows.showOnboarding { [weak self] in
                self?.settings.value.hasCompletedOnboarding = true
                self?.windows.showMain()
            }
        }
    }

    public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        windows.showMain()
        return true
    }

    public func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard appState.phase.isRecording else { return .terminateNow }
        // Never lose a recording on quit: stop and keep the audio; it is transcribed on the next launch.
        Task {
            await recorder.stop(transcribe: false)
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    // MARK: - Settings

    private func apply(_ value: Settings, old: Settings?) {
        recorder.settings = value
        integrations.apply(value.integrations)
        sounds.isEnabled = value.playsSounds
        pill.isEnabled = value.showsPill
        meetings.setEnabled(value.detectsMeetings)
        if old?.hotkey != value.hotkey {
            if !hotkey.register(value.hotkey, action: { [weak self] in self?.recorder.toggle() }) {
                print("EchoPad: \(HotkeyLabel.describe(value.hotkey)) is taken by another app.")
            }
        }
        if old?.identifySpeakers == false && value.identifySpeakers { loadModels() }
    }

    // MARK: - Models

    private func loadModels() {
        modelTask?.cancel()
        let diarize = settings.value.identifySpeakers
        let state = appState
        state.model = .loading(fraction: nil, detail: "")
        modelTask = Task {
            do {
                try await recorder.prepareSpeechModel(diarization: diarize) { progress in
                    Task { @MainActor in state.model = .loading(fraction: progress.fraction, detail: progress.detail) }
                }
                state.model = .ready
                await self.finishUnfinished()
            } catch {
                state.model = .failed(RecordingController.describe(error))
            }
        }
    }

    /// Downloads (first time) and compiles the live models, then frees them; a recording
    /// loads them again. Only on the user's request.
    private func prepareLiveModel() {
        guard appState.liveModel != .preparing else { return }
        let state = appState
        state.liveModel = .preparing
        let options = settings.value.live.options
        Task {
            let transcriber = LiveTranscriber(options: options)
            do {
                try await transcriber.start()
                await transcriber.cancel()
                state.liveModel = .downloaded
            } catch {
                await transcriber.cancel()
                state.liveModel = .failed(RecordingController.describe(error))
            }
        }
    }

    /// The live transcript panel, made on first use and only hidden when closed.
    private func showLiveTranscript() {
        if liveTranscriptPanel == nil {
            liveTranscriptPanel = LiveTranscriptPanelController(content: inject(AnyView(LiveTranscriptView())))
        }
        liveTranscriptPanel?.show()
    }

    /// Transcribes recordings left over from a quit or crash, oldest first.
    private func finishUnfinished() async {
        for conversation in library.unfinished.reversed() {
            while appState.phase.isBusy { try? await Task.sleep(for: .seconds(1)) }
            await recorder.process(conversation.id)
        }
    }

    // MARK: - Views

    private func inject(_ view: AnyView) -> AnyView {
        AnyView(view
            .environment(appState)
            .environment(settings)
            .environment(library)
            .environment(integrations.status)
            .environment(\.appActions, actions))
    }

    private var actions: AppActions {
        AppActions(
            toggleRecording: { [weak self] in
                self?.statusBar.closePopover()
                self?.recorder.toggle()
            },
            discardRecording: { [weak self] in Task { await self?.recorder.discard() } },
            checkSound: { [weak self] in self?.statusBar.showPopover() },
            playTestSound: { [weak self] in Task { await self?.recorder.testSystemAudio() } },
            openMainWindow: { [weak self] section in
                self?.statusBar.closePopover()
                self?.windows.showMain(section: section)
            },
            openConversation: { [weak self] id in
                self?.statusBar.closePopover()
                self?.windows.showMain(conversation: id)
            },
            reprocess: { [weak self] id in Task { await self?.recorder.process(id) } },
            reexport: { [weak self] id in self?.reexport(id) },
            renameSpeaker: { [weak self] id, speaker, name in self?.renameSpeaker(id, speaker: speaker, to: name) },
            importAudio: { [weak self] in self?.importAudio() },
            retryModel: { [weak self] in self?.loadModels() },
            prepareLiveModel: { [weak self] in self?.prepareLiveModel() },
            showLiveTranscript: { [weak self] in
                self?.statusBar.closePopover()
                self?.showLiveTranscript()
            },
            retryAPI: { [weak self] in self?.integrations.retryAPI() },
            copySecret: { [weak self] kind in
                guard let secret = self?.integrations.secret(kind) else { return false }
                NSPasteboard.general.clearContents()
                return NSPasteboard.general.setString(secret, forType: .string)
            },
            quit: { NSApp.terminate(nil) }
        )
    }

    private func reexport(_ id: UUID) {
        guard let conversation = library.conversation(id: id), let transcript = library.transcript(for: id) else { return }
        do {
            try recorder.export(conversation, transcript: transcript, runActions: false)
        } catch {
            appState.transition(to: .error(RecordingController.describe(error)), resetAfter: 6)
        }
    }

    private func renameSpeaker(_ id: UUID, speaker: String, to name: String) {
        guard var transcript = library.transcript(for: id) else { return }
        transcript.rename(speaker: speaker, to: name)
        try? library.store(transcript, for: id)
        reexportReplacing(id)
    }

    /// Re-exports over the previous files instead of creating "(2)" copies.
    private func reexportReplacing(_ id: UUID) {
        guard let conversation = library.conversation(id: id) else { return }
        for path in conversation.exportedFiles { try? FileManager.default.removeItem(atPath: path) }
        if let audio = conversation.exportedAudio { try? FileManager.default.removeItem(atPath: audio) }
        reexport(id)
    }

    /// Transcribes an existing audio or video file as a new conversation.
    private func importAudio() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio, .movie]
        panel.allowsMultipleSelection = false
        panel.message = "Choose a recording to transcribe."
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let id = UUID()
        let folder = library.folder(for: id)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            // Stored as the "system" track so the whole file is diarized into speakers.
            let target = folder.appendingPathComponent("system.wav")
            try AudioConverter.convertToWAV(url, to: target)
            let duration = AudioConverter.duration(of: target)
            let date = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
            var conversation = Conversation(id: id, title: url.deletingPathExtension().lastPathComponent, date: date,
                                            duration: duration, destinationID: settings.value.defaultDestinationID)
            conversation.status = .transcribing
            library.add(conversation)
            windows.showMain(conversation: id)
            Task { await recorder.process(id) }
        } catch {
            try? FileManager.default.removeItem(at: folder)
            appState.transition(to: .error(RecordingController.describe(error)), resetAfter: 6)
        }
    }

    private func askForTitle(_ current: String) async -> String? {
        let alert = NSAlert()
        alert.messageText = "Name this conversation"
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Use Default")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.stringValue = current
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        NSApp.activate()
        return alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil
    }
}
