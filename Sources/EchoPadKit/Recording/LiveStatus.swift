import Foundation
import ScribeKit

/// What the live transcript of the recording in progress is doing, for the pill and the menu.
public enum LiveStatus: Equatable, Sendable {
    /// Downloading (first time) or loading the live models; audio waits in the feed.
    case preparing
    case listening(words: Int)
    case finished(words: Int)
    case failed(String)

    public init(snapshot: LiveSnapshot, modelsReady: Bool) {
        let words = snapshot.words.count
        if let error = snapshot.error {
            self = .failed(error)
            return
        }
        switch snapshot.phase {
        case .failed: self = .failed("Live transcription stopped.")
        case .finished, .cancelled: self = .finished(words: words)
        case .idle: self = modelsReady ? .listening(words: words) : .preparing
        case .running: self = .listening(words: words)
        }
    }

    public var isTerminal: Bool {
        switch self {
        case .finished, .failed: return true
        case .preparing, .listening: return false
        }
    }

    public var title: String {
        switch self {
        case .preparing: return "Live transcript: preparing model…"
        case .listening(let words): return words == 0 ? "Live transcript: listening" : "Live transcript: \(words) words"
        case .finished(let words): return "Live transcript: \(words) words"
        case .failed: return "Live transcript failed"
        }
    }
}

/// Whether the live models are in FluidAudio's cache. Only looks at files: opening the
/// settings must never download or load a model.
public enum LiveModelCache {
    public static var defaultDirectory: URL {
        overrideDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FluidAudio/Models", isDirectory: true)
    }

    /// Test copies only: `ECHOPAD_LIVE_MODEL_DIR` points the live models at their own cache, so a
    /// first download can be checked without touching the real one. nil in normal use.
    public static var overrideDirectory: URL? {
        ProcessInfo.processInfo.environment["ECHOPAD_LIVE_MODEL_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    /// The speech model for `latencyMs` (each look-ahead is its own encoder) and, with
    /// `diarize`, LS-EEND.
    public static func isDownloaded(latencyMs: Int, diarize: Bool, in base: URL = defaultDirectory) -> Bool {
        let manager = FileManager.default
        let speech = base.appendingPathComponent("nemotron-labs-unified-asr/coreml")
        // Encoder export per look-ahead (left_chunk_right frames), as in FluidAudio's UnifiedConfig.
        let suffix = [560: "70_2_5", 1120: "70_7_7", 2080: "70_13_13"][latencyMs] ?? "70_7_7"
        let encoder = "nemotron_unified_encoder_streaming_\(suffix)"
        let files = (try? manager.contentsOfDirectory(atPath: speech.path)) ?? []
        let hasSpeech = files.contains { $0.hasPrefix(encoder) && $0.hasSuffix(".mlmodelc") }
            && files.contains { $0.hasPrefix("nemotron_unified_decoder") }
            && files.contains { $0.hasPrefix("nemotron_unified_joint") }
            && files.contains("vocab.json")
        guard hasSpeech else { return false }
        guard diarize else { return true }
        let diarizer = (try? manager.contentsOfDirectory(atPath: base.appendingPathComponent("ls-eend").path)) ?? []
        return !diarizer.isEmpty
    }
}

/// The live model outside a recording: on disk or not, and an explicit download in progress.
public enum LiveModelState: Equatable, Sendable {
    case notDownloaded
    case downloaded
    case preparing
    case failed(String)
}
