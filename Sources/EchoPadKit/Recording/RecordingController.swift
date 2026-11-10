import AppKit
import Foundation
import ScribeKit
import SystemAudioKit

/// The part of ScribeKit's ``Scribe`` that makes the saved transcript; a fake in tests.
public protocol ConversationTranscribing: Actor {
    func prepare(diarization: Bool, progress: (@Sendable (ModelProgress) -> Void)?) async throws
    func transcribeConversation(microphone: URL?, system: URL?, options: TranscriptionOptions,
                                progress: (@Sendable (TranscriptionStage) -> Void)?) async throws -> Transcript
}

extension Scribe: ConversationTranscribing {}

/// Runs a recording from start to saved files: capture with SystemAudioKit, transcribe
/// with ScribeKit, then export to the chosen destination and run its after-save actions.
@MainActor
public final class RecordingController {
    /// Seconds of silent system audio during a detected call before the UI warns about it.
    static let SILENT_SYSTEM_WARNING: TimeInterval = 20
    /// Peak level above which the system track counts as carrying sound.
    static let SOUND_THRESHOLD: Float = 0.02
    /// How long the sound check listens for its test sound.
    static let TEST_SOUND_WAIT: Duration = .milliseconds(1800)
    static let TEST_SOUND = "/System/Library/Sounds/Ping.aiff"
    /// Shorter recordings are treated as accidental and discarded.
    static let MINIMUM_DURATION: TimeInterval = 1.5
    /// How often the pill, the menu and the live transcript panel take the live state.
    static let LIVE_REFRESH: Duration = .milliseconds(500)

    private let appState: AppState
    private let library: ConversationLibrary
    private let recorder = AudioRecorder()
    /// Makes the saved transcript. Replaced by a fresh one from `makeScribe` after a step got
    /// stuck, so a retry never calls into the stuck model again.
    private var scribe: any ConversationTranscribing
    private let makeScribe: () -> any ConversationTranscribing
    /// Time without progress after which a step of the saved transcript counts as stuck.
    var modelLoadBudget = TranscriptionBudget.MODEL_LOAD
    var stepBudget: (TimeInterval) -> Duration = TranscriptionBudget.step
    public var settings: Settings
    public var sounds: SoundPlayer?
    public var onSaved: ((Conversation) -> Void)?
    public var onError: ((String) -> Void)?
    /// Receives recording events for the local API and webhooks.
    public var events: EventLog?
    /// Asked for a title when a recording stops and `asksForTitle` is on; nil keeps the current title.
    public var askForTitle: ((String) async -> String?)?

    private var currentID: UUID?
    private var startDate: Date?
    private var meetingBundleID: String?
    private var silenceTimer: Timer?
    private var silentSince: Date?
    /// Set while the sound check listens, so the silence timer does not take its peak.
    private var isTestingSound = false
    /// Live transcript of the current recording, kept after Stop until the next one starts.
    private var live: LiveSession?
    private var liveConversationID: UUID?
    /// Copies the live session's state into ``AppState/live`` for the pill and the menu.
    private var liveWatch: Task<Void, Never>?

    public convenience init(appState: AppState, library: ConversationLibrary, settings: Settings) {
        self.init(appState: appState, library: library, settings: settings, scribe: Scribe.shared, makeScribe: { Scribe() })
    }

    init(appState: AppState, library: ConversationLibrary, settings: Settings,
         scribe: any ConversationTranscribing, makeScribe: @escaping () -> any ConversationTranscribing) {
        self.appState = appState
        self.library = library
        self.settings = settings
        self.scribe = scribe
        self.makeScribe = makeScribe
        recorder.onLevels = { [weak appState] mic, system in
            Task { @MainActor in appState?.push(microphone: mic, system: system) }
        }
    }

    // MARK: - Start and stop

    public func toggle() {
        if appState.phase.isRecording {
            Task { await stop() }
        } else if !appState.phase.isBusy {
            Task { await start() }
        }
    }

    /// Starts recording. `meeting` is the call app when the recording starts from a meeting
    /// notification; with the "only the meeting app" setting, just that app is recorded.
    public func start(title: String? = nil, meeting: DetectedMeeting? = nil, destinationID: UUID? = nil) async {
        guard !appState.phase.isBusy else { return }
        let id = UUID()
        let folder = library.folder(for: id)
        let date = Date()
        meetingBundleID = meeting?.bundleID

        let configuration = configuration(for: meeting)
        let session = settings.live.enabled ? LiveSession(settings: settings.live) : nil
        recorder.liveFeed = session?.feed
        do {
            try await recorder.start(configuration, in: folder)
        } catch {
            recorder.liveFeed = nil
            try? FileManager.default.removeItem(at: folder)
            fail(Self.describe(error))
            return
        }

        currentID = id
        startDate = date
        if let previous = live { Task { await previous.cancel() } }
        live = session
        liveConversationID = session == nil ? nil : id
        if let session { await session.start() }
        watchLive(session)
        appState.currentTitle = title ?? defaultTitle(meeting: meeting, date: date)
        appState.currentApp = meeting?.appName
        appState.currentDestinationID = destinationID ?? settings.defaultDestinationID
        appState.systemAudioLooksSilent = false
        appState.soundTest = nil
        appState.captureScope = Self.scope(of: configuration, meeting: meeting)
        appState.transition(to: .recording(since: date))
        events?.emit(.recordingStarted, conversationID: id, title: appState.currentTitle)
        sounds?.play(.start)
        watchSystemAudio()
    }

    /// Stops recording. With `transcribe: false` (used on quit) the audio is kept and
    /// transcribed on the next launch.
    public func stop(transcribe: Bool = true) async {
        guard appState.phase.isRecording, let id = currentID, let startDate else { return }
        silenceTimer?.invalidate()
        silenceTimer = nil
        appState.transition(to: .processing(.finishingAudio))
        sounds?.play(.stop)

        guard let recording = await recorder.stop() else {
            // Its feed may never be closed: stop the live model instead of leaving it waiting.
            await live?.cancel()
            fail("The recording could not be finished.")
            return
        }
        currentID = nil
        self.startDate = nil
        events?.emit(.recordingStopped, conversationID: id, title: appState.currentTitle, duration: recording.duration)

        if recording.duration < Self.MINIMUM_DURATION {
            await dropLive()
            try? FileManager.default.removeItem(at: library.folder(for: id))
            events?.emit(.recordingDiscarded, conversationID: id)
            appState.transition(to: .idle)
            return
        }

        var title = appState.currentTitle
        if transcribe, settings.asksForTitle, let ask = askForTitle, let chosen = await ask(title) {
            title = chosen.isEmpty ? title : chosen
        }

        var conversation = Conversation(id: id, title: title, date: startDate, duration: recording.duration,
                                        app: appState.currentApp, destinationID: appState.currentDestinationID)
        conversation.status = transcribe ? .transcribing : .recorded
        library.add(conversation)
        guard transcribe else {
            appState.transition(to: .idle)
            return
        }
        await process(id)
    }

    /// Stops and throws the recording away.
    public func discard() async {
        guard appState.phase.isRecording, let id = currentID else { return }
        silenceTimer?.invalidate()
        _ = await recorder.stop()
        await dropLive()
        try? FileManager.default.removeItem(at: library.folder(for: id))
        currentID = nil
        startDate = nil
        events?.emit(.recordingDiscarded, conversationID: id)
        appState.transition(to: .idle)
    }

    /// Stops a recording because the call ended, if it was started for that call.
    public func meetingEnded(_ meeting: DetectedMeeting) {
        guard appState.phase.isRecording, meetingBundleID == meeting.bundleID else { return }
        Task { await stop() }
    }

    // MARK: - Processing

    /// Transcribes and exports a conversation already in the library. Used after a
    /// recording and for "Transcribe Again".
    public func process(_ id: UUID) async {
        guard var conversation = library.conversation(id: id) else { return }
        let tracks = library.tracks(for: id)
        guard tracks.microphone != nil || tracks.system != nil else {
            fail("The audio of this conversation is no longer kept, so it cannot be transcribed again.")
            return
        }
        library.update(id) { $0.status = .transcribing }
        appState.transition(to: .processing(.transcribing))

        let options = TranscriptionOptions(
            language: settings.language == "auto" ? nil : settings.language,
            diarize: settings.identifySpeakers,
            localSpeakerName: settings.myName.isEmpty ? "Me" : settings.myName
        )

        do {
            let appState = self.appState
            let scribe = self.scribe
            let step = stepBudget(conversation.duration)
            let load = modelLoadBudget
            let loading = "Loading the speech model"
            let transcript = try await Watchdog.run(budget: load, stage: loading) { watch in
                try await scribe.transcribeConversation(
                    microphone: tracks.microphone, system: tracks.system, options: options,
                    progress: { stage in
                        switch stage {
                        case .loadingModels: watch.advance(stage: loading, budget: load)
                        case .transcribing(let track): watch.advance(stage: "Transcribing the \(track)", budget: step)
                        case .identifyingSpeakers: watch.advance(stage: "Identifying speakers", budget: step)
                        default: watch.advance(stage: "Finishing the transcript", budget: step)
                        }
                        Task { @MainActor in
                            switch stage {
                            case .identifyingSpeakers: appState.transition(to: .processing(.identifyingSpeakers))
                            case .finishing: appState.transition(to: .processing(.saving))
                            default: break
                            }
                        }
                    })
            }
            try library.store(transcript, for: id)
            conversation = library.conversation(id: id) ?? conversation
            try export(conversation, transcript: transcript)
        } catch let stuck as Watchdog.TimedOut {
            resetSpeechModel()
            let message = "The transcript was not finished: \(stuck.stage.lowercased()) made no progress for \(stuck.seconds) s. The audio is kept; choose Transcribe Again."
            library.update(id) { $0.status = .failed(message) }
            fail(message, conversationID: id)
            return
        } catch {
            let message = Self.describe(error)
            library.update(id) { $0.status = .failed(message) }
            fail(message, conversationID: id)
            return
        }
        library.enforceAudioLimit(settings.libraryLimit)
    }

    /// Downloads (first time) and loads the speech model ahead of the first recording.
    public func prepareSpeechModel(diarization: Bool, progress: (@Sendable (ModelProgress) -> Void)?) async throws {
        let scribe = self.scribe
        let stage = "Loading the speech model"
        do {
            try await Watchdog.run(budget: modelLoadBudget, stage: stage) { watch in
                try await scribe.prepare(diarization: diarization) { update in
                    watch.advance()
                    progress?(update)
                }
            }
        } catch let stuck as Watchdog.TimedOut {
            resetSpeechModel()
            throw stuck
        }
    }

    /// Drops the speech model after a step got stuck. CoreML gives no way to interrupt the
    /// stuck call, so its memory is not freed here; the next transcription loads a new model
    /// instead of queueing behind it.
    func resetSpeechModel() {
        Log.recording.error("A speech model step got stuck; the next transcription loads a new model.")
        scribe = makeScribe()
        appState.model = .notLoaded
    }

    /// Writes the stored transcript again (for example after renaming speakers or
    /// choosing another destination) and runs the destination's after-save actions.
    public func export(_ conversation: Conversation, transcript: Transcript, runActions: Bool = true) throws {
        appState.transition(to: .processing(.saving))
        let destination = settings.destination(id: conversation.destinationID)
        let tracks = library.tracks(for: conversation.id)
        let result = try Exporter().export(conversation, transcript: transcript,
                                           tracks: [tracks.microphone, tracks.system].compactMap { $0 },
                                           to: destination)
        library.update(conversation.id) {
            $0.status = .done
            $0.wordCount = transcript.wordCount
            $0.speakers = transcript.speakers
            $0.language = transcript.language
            $0.exportedFiles = result.files.map(\.path)
            $0.exportedAudio = result.audio?.path
        }
        appState.transition(to: .saved(title: conversation.title), resetAfter: 2.5)
        events?.emit(.conversationSaved, conversationID: conversation.id, title: conversation.title,
                     duration: conversation.duration, wordCount: transcript.wordCount)
        sounds?.play(.saved)
        if runActions {
            let library = library
            Task {
                await AfterSave.run(destination.afterSave, result: result, transcript: transcript,
                                    destination: destination, conversation: conversation) { title, files in
                    library.update(conversation.id) {
                        $0.title = title
                        $0.exportedFiles = files.map(\.path)
                    }
                }
            }
        }
        if let saved = library.conversation(id: conversation.id) { onSaved?(saved) }
    }

    // MARK: - Helpers

    private func configuration(for meeting: DetectedMeeting?) -> AudioRecorder.Configuration {
        var configuration = AudioRecorder.Configuration()
        configuration.backend = SystemAudioBackend(rawValue: settings.systemAudioBackend) ?? .processTap
        if settings.recordsMicrophone {
            configuration.microphone = settings.microphoneUID.map { .device(uid: $0) } ?? .systemDefault
        } else {
            configuration.microphone = nil
        }
        switch settings.systemAudio {
        case .off: configuration.systemAudio = nil
        case .everything: configuration.systemAudio = .everything
        case .meetingApp: configuration.systemAudio = meeting.map { .apps([$0.bundleID]) } ?? .everything
        case .selectedApps:
            configuration.systemAudio = settings.systemAudioApps.isEmpty ? .everything : .apps(settings.systemAudioApps)
        }
        // App isolation needs a process tap; ScreenCaptureKit always records everything.
        if configuration.backend == .screenCaptureKit, case .apps = configuration.systemAudio {
            configuration.systemAudio = .everything
        }
        return configuration
    }

    private func defaultTitle(meeting: DetectedMeeting?, date: Date) -> String {
        if let meeting { return "\(meeting.appName) call" }
        let hour = Calendar.current.component(.hour, from: date)
        let part = hour < 12 ? "Morning" : hour < 18 ? "Afternoon" : "Evening"
        return "\(part) conversation"
    }

    /// Warns when a call is being recorded but the system track stays silent, which usually
    /// means the system audio permission was not granted.
    private func watchSystemAudio() {
        silentSince = nil
        guard settings.systemAudio != .off else { return }
        silenceTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.isTestingSound else { return }
                let peak = self.recorder.systemAudioPeak() ?? 0
                if peak > Self.SOUND_THRESHOLD {
                    self.silentSince = nil
                    self.appState.systemAudioLooksSilent = false
                } else if self.meetingBundleID != nil || self.appState.detectedMeeting != nil {
                    let since = self.silentSince ?? Date()
                    self.silentSince = since
                    self.appState.systemAudioLooksSilent = Date().timeIntervalSince(since) > Self.SILENT_SYSTEM_WARNING
                }
            }
        }
    }

    /// Plays a short sound from a separate process (EchoPad's own sound is excluded from the
    /// capture) and checks whether it reaches the system track of the recording in progress.
    public func testSystemAudio() async {
        guard appState.phase.isRecording, !isTestingSound else { return }
        isTestingSound = true
        defer { isTestingSound = false }
        appState.soundTest = .running
        _ = recorder.systemAudioPeak()
        let player = Process()
        player.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        player.arguments = ["-v", "0.6", Self.TEST_SOUND]
        do {
            try player.run()
        } catch {
            Log.recording.error("Test sound failed: \(error.localizedDescription, privacy: .public)")
        }
        try? await Task.sleep(for: Self.TEST_SOUND_WAIT)
        guard appState.phase.isRecording else { return }
        let heard = (recorder.systemAudioPeak() ?? 0) > Self.SOUND_THRESHOLD
        appState.soundTest = heard ? .heard : .notHeard
        if heard {
            silentSince = nil
            appState.systemAudioLooksSilent = false
        }
    }

    static func scope(of configuration: AudioRecorder.Configuration, meeting: DetectedMeeting?) -> SoundCheck.Scope {
        guard configuration.backend == .processTap, case .apps(let bundleIDs) = configuration.systemAudio else {
            return .everything
        }
        return .apps(bundleIDs.map { bundleID in
            if bundleID == meeting?.bundleID, let name = meeting?.appName { return name }
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return bundleID }
            return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        })
    }

    private func watchLive(_ session: LiveSession?) {
        liveWatch?.cancel()
        appState.live = session == nil ? nil : .preparing
        appState.liveTranscript = nil
        guard let session else { return }
        liveWatch = Task { [weak self] in
            while !Task.isCancelled {
                let (status, snapshot) = await session.current()
                guard !Task.isCancelled, let self else { return }
                if self.appState.live != status { self.appState.live = status }
                if self.appState.liveTranscript != snapshot { self.appState.liveTranscript = snapshot }
                if status.isTerminal { return }
                try? await Task.sleep(for: Self.LIVE_REFRESH)
            }
        }
    }

    /// A thrown-away recording keeps no live transcript either.
    private func dropLive() async {
        await live?.cancel()
        live = nil
        liveConversationID = nil
        watchLive(nil)
    }

    private func fail(_ message: String, conversationID: UUID? = nil) {
        Log.recording.error("\(message, privacy: .public)")
        events?.emit(.recordingFailed, conversationID: conversationID ?? currentID, message: message)
        appState.transition(to: .error(message), resetAfter: 6)
        sounds?.play(.error)
        onError?(message)
    }

    static func describe(_ error: Error) -> String {
        if let error = error as? LocalizedError, let description = error.errorDescription { return description }
        return error.localizedDescription
    }
}

extension RecordingController: RecordingControlling {
    public var recordingStatus: RecordingStatus {
        RecordingStatus(phase: appState.phase, title: appState.currentTitle, conversationID: currentID)
    }

    public func startRecording(title: String?) async {
        await start(title: title)
    }

    public func stopRecording() {
        Task { await stop() }
    }

    public func liveTranscript() async -> LiveTranscriptStatus? {
        guard let live else { return nil }
        return LiveTranscriptStatus(conversationID: liveConversationID, snapshot: await live.snapshot())
    }
}
