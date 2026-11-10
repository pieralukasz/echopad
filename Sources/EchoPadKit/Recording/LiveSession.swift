import Foundation
import ScribeKit
import SystemAudioKit

/// Live transcription while recording. Off by default: it loads a second speech model
/// (Nemotron Unified, about 1.2 GB on disk) next to the Parakeet one that still makes the
/// saved transcript after Stop.
public struct LiveTranscriptionSettings: Codable, Equatable, Sendable {
    public static let ENGINE_NEMOTRON = "nemotron-unified"

    public var enabled = false
    /// The only live engine so far; Parakeet stays the engine of the saved transcript.
    public var engine = ENGINE_NEMOTRON
    /// ISO 639-1, or nil for automatic detection.
    public var language: String? = "pl"
    /// Model look-ahead: 560, 1120 or 2080 ms.
    public var latencyMs = LiveLatency.ms1120.rawValue
    /// Split the system audio into anonymous speakers (LS-EEND).
    public var diarize = true

    private enum CodingKeys: String, CodingKey { case enabled, engine, language, latencyMs, diarize }

    public init() {}

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = LiveTranscriptionSettings()
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? defaults.enabled
        engine = try container.decodeIfPresent(String.self, forKey: .engine) ?? defaults.engine
        language = container.contains(.language) ? try container.decodeIfPresent(String.self, forKey: .language) : defaults.language
        latencyMs = try container.decodeIfPresent(Int.self, forKey: .latencyMs) ?? defaults.latencyMs
        diarize = try container.decodeIfPresent(Bool.self, forKey: .diarize) ?? defaults.diarize
    }

    /// Writes `language: null` for automatic detection: a missing key means the Polish default.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(enabled, forKey: .enabled)
        try container.encode(engine, forKey: .engine)
        try container.encode(language, forKey: .language)
        try container.encode(latencyMs, forKey: .latencyMs)
        try container.encode(diarize, forKey: .diarize)
    }

    public var options: LiveOptions {
        LiveOptions(language: language, latency: LiveLatency(rawValue: latencyMs) ?? .ms1120, diarizeSystem: diarize,
                    modelDirectory: LiveModelCache.overrideDirectory)
    }
}

/// What ``LiveSession`` needs from a live transcriber; ``LiveTranscriber`` in the app.
public protocol LiveTranscribing: Actor {
    func start() async throws
    func feed(_ samples: [Float], track: LiveTrack, at time: TimeInterval?) async throws
    @discardableResult func finish() async throws -> LiveSnapshot
    func cancel() async
    func snapshot() async -> LiveSnapshot
    func reportGap(_ gap: LiveGap) async
}

extension LiveTranscriber: LiveTranscribing {}

/// Connects a ``LiveAudioFeed`` (written audio of both tracks) to a live transcriber. The
/// same path serves a real recording and the replay of an archived one.
public actor LiveSession {
    /// Audio the feed holds while the model loads or falls behind; more is dropped and
    /// reported as a gap. 120 s of two 16 kHz tracks is about 15 MB.
    public static let BUFFER_SECONDS: Double = 120
    /// A cold first load compiles the models for the Neural Engine (about 25 s measured on an
    /// M1 Max). A load still running after this is treated as stuck: CoreML's load cannot be
    /// interrupted, so the live transcript of this recording fails visibly instead of showing
    /// "preparing" forever.
    public static let LOAD_TIMEOUT: Duration = .seconds(120)

    public nonisolated let feed: LiveAudioFeed
    private let transcriber: any LiveTranscribing
    private var pump: Task<Void, Never>?
    private var startError: String?
    /// Set once the models are loaded; before that the snapshot is `idle` while audio waits.
    private var modelsReady = false
    private let loadTimeout: Duration
    private var loadWatchdog: Task<Void, Never>?

    public init(transcriber: any LiveTranscribing, bufferSeconds: Double = BUFFER_SECONDS,
                loadTimeout: Duration = LOAD_TIMEOUT) {
        self.transcriber = transcriber
        self.loadTimeout = loadTimeout
        self.feed = LiveAudioFeed(sampleRate: LiveTranscriber.SAMPLE_RATE, capacitySeconds: bufferSeconds)
    }

    public init(settings: LiveTranscriptionSettings) {
        self.init(transcriber: LiveTranscriber(options: settings.options))
    }

    /// Loads the models and starts consuming the feed. Audio pushed before the models are
    /// ready waits in the feed.
    public func start() {
        guard pump == nil else { return }
        let feed = feed, transcriber = transcriber
        pump = Task { [weak self] in
            do {
                try await transcriber.start()
            } catch {
                await self?.recordStartError(error)
                // Keep draining so the recorder's pushes never pile up.
                while await feed.next() != nil {}
                return
            }
            await self?.markModelsReady()
            var failed = false
            var end: [LiveTrack: TimeInterval] = [:], seenDrops: [LiveTrack: Int64] = [:]
            while let chunk = await feed.next() {
                guard !failed else { continue }
                let track: LiveTrack = chunk.track == .microphone ? .microphone : .system
                // A drop before this chunk shows up as a jump in `at`; the transcriber records it.
                seenDrops[track, default: 0] += chunk.droppedFramesBefore
                end[track] = Double(chunk.startFrame + Int64(chunk.samples.count)) / LiveTranscriber.SAMPLE_RATE
                do {
                    try await transcriber.feed(chunk.samples, track: track,
                                               at: Double(chunk.startFrame) / LiveTranscriber.SAMPLE_RATE)
                } catch {
                    failed = true // the transcriber keeps the error in its snapshot
                }
            }
            // Drops after the last delivered chunk have no later chunk to reveal them.
            for (audioTrack, dropped) in feed.droppedFrames {
                let track: LiveTrack = audioTrack == .microphone ? .microphone : .system
                let unseen = dropped - seenDrops[track, default: 0]
                if unseen > 0 {
                    await transcriber.reportGap(LiveGap(track: track, start: end[track] ?? 0,
                                                        duration: Double(unseen) / LiveTranscriber.SAMPLE_RATE,
                                                        reason: "dropped while the model was busy"))
                }
            }
            if !failed { _ = try? await transcriber.finish() }
        }
        let timeout = loadTimeout
        loadWatchdog = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            await self?.giveUpLoading(after: timeout)
        }
    }

    /// The models did not load in time: stop waiting for them, so the recording's audio no
    /// longer piles up in the feed and the pill shows the failure.
    private func giveUpLoading(after timeout: Duration) async {
        guard !modelsReady, startError == nil else { return }
        startError = "The live model did not load within \(timeout.components.seconds) s. The saved transcript is not affected."
        feed.finish()
        await transcriber.cancel()
    }

    /// Waits until the feed is finished (recording stopped) and the last words are flushed.
    public func waitUntilDone() async {
        await pump?.value
    }

    public func cancel() async {
        loadWatchdog?.cancel()
        feed.finish()
        await transcriber.cancel()
    }

    public func snapshot() async -> LiveSnapshot {
        var snapshot = await transcriber.snapshot()
        if let startError, snapshot.error == nil { snapshot.error = startError }
        return snapshot
    }

    /// The state the pill and the menu show while recording.
    public func status() async -> LiveStatus {
        await current().status
    }

    /// The state and the words, from one snapshot, for the pill and the live transcript panel.
    public func current() async -> (status: LiveStatus, snapshot: LiveSnapshot) {
        let snapshot = await snapshot()
        return (LiveStatus(snapshot: snapshot, modelsReady: modelsReady), snapshot)
    }

    private func markModelsReady() {
        modelsReady = true
        loadWatchdog?.cancel()
    }

    private func recordStartError(_ error: Error) {
        loadWatchdog?.cancel()
        startError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
    }

    /// Replays an archived recording through the same feed as a live one. `paced` feeds in
    /// real time (measures live delays); otherwise as fast as the model allows.
    public func replay(microphone: URL?, system: URL?, chunkSeconds: Double = 0.1, paced: Bool = false) async throws {
        let tracks = try [(LiveAudioTrack.microphone, microphone), (.system, system)].compactMap { track, url in
            try url.map { (track, try Self.readSamples($0)) }
        }
        start()
        let chunk = Int(chunkSeconds * LiveTranscriber.SAMPLE_RATE)
        let total = tracks.map(\.1.count).max() ?? 0
        let clock = ContinuousClock(), began = clock.now
        var offset = 0
        while offset < total {
            if paced {
                let due = Duration.seconds(Double(offset + chunk) / LiveTranscriber.SAMPLE_RATE)
                let wait = due - (clock.now - began)
                if wait > .zero { try await Task.sleep(for: wait) }
            } else {
                // Unpaced: keep within the feed's capacity instead of dropping.
                while feed.backlogFrames * 2 > feed.capacityFrames { try await Task.sleep(for: .milliseconds(5)) }
            }
            for (track, samples) in tracks where offset < samples.count {
                feed.push(track, startFrame: Int64(offset), samples: Array(samples[offset..<min(offset + chunk, samples.count)]))
            }
            offset += chunk
        }
        feed.finish()
        await waitUntilDone()
    }

    static func readSamples(_ url: URL) throws -> [Float] {
        let data = try Data(contentsOf: url)
        guard data.count > 44, String(decoding: data[8..<12], as: UTF8.self) == "WAVE" else {
            throw CocoaError(.fileReadCorruptFile)
        }
        // Walk RIFF chunks to "fmt " and "data"; EchoPad writes 16 kHz mono 16-bit PCM.
        var index = 12
        var format: (channels: Int, rate: Int, bits: Int)?
        while index + 8 <= data.count {
            let id = String(decoding: data[index..<index + 4], as: UTF8.self)
            let size = Int(data[index + 4]) | Int(data[index + 5]) << 8 | Int(data[index + 6]) << 16 | Int(data[index + 7]) << 24
            let body = index + 8
            if id == "fmt " {
                // PCM "fmt " holds at least 16 bytes; a shorter or cut-off one would be read past the file.
                guard size >= 16, body + size <= data.count else { throw CocoaError(.fileReadCorruptFile) }
                func u16(_ at: Int) -> Int { Int(data[body + at]) | Int(data[body + at + 1]) << 8 }
                format = (u16(2), u16(4) | u16(6) << 16, u16(14))
            } else if id == "data", let format {
                guard format.channels == 1, format.rate == 16_000, format.bits == 16 else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                let end = min(data.count, body + size)
                return stride(from: body, to: end - 1, by: 2).map {
                    Float(Int16(bitPattern: UInt16(data[$0]) | UInt16(data[$0 + 1]) << 8)) / 32_768
                }
            }
            index = body + size + (size & 1)
        }
        throw CocoaError(.fileReadCorruptFile)
    }
}
