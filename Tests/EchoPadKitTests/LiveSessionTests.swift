import Foundation
import XCTest
@testable import EchoPadKit
import ScribeKit

/// Records what the live path feeds it, standing in for the Nemotron/LS-EEND transcriber.
private actor RecordingTranscriber: LiveTranscribing {
    struct Fed: Equatable { let track: LiveTrack; let at: TimeInterval; let count: Int }
    var fed: [Fed] = []
    var finished = 0
    var cancelled = false
    var startError: Error?

    init(startError: Error? = nil) { self.startError = startError }

    func start() async throws { if let startError { throw startError } }
    func feed(_ samples: [Float], track: LiveTrack, at time: TimeInterval?) async throws {
        fed.append(Fed(track: track, at: time ?? -1, count: samples.count))
    }
    func finish() async throws -> LiveSnapshot { finished += 1; return snapshot() }
    func cancel() async { cancelled = true }
    func reportGap(_ gap: LiveGap) async {}
    func snapshot() -> LiveSnapshot {
        LiveSnapshot(revision: fed.count, phase: finished > 0 ? .finished : .running, engine: "fake", words: [],
                     speakers: [], gaps: [], received: [:], error: nil)
    }
}

@MainActor
private final class LiveMock: RecordingControlling {
    var recordingStatus = RecordingStatus(state: "recording")
    var live: LiveTranscriptStatus?
    func startRecording(title: String?) async {}
    func stopRecording() {}
    func liveTranscript() async -> LiveTranscriptStatus? { live }
}

final class LiveSessionTests: XCTestCase {
    private func wav(seconds: Double) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("live-\(UUID().uuidString).wav")
        let frames = Int(seconds * 16_000)
        var data = Data()
        func u32(_ v: Int) { withUnsafeBytes(of: UInt32(v).littleEndian) { data.append(contentsOf: $0) } }
        func u16(_ v: Int) { withUnsafeBytes(of: UInt16(v).littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8)); u32(36 + frames * 2); data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1); u32(16_000); u32(32_000); u16(2); u16(16)
        data.append(contentsOf: Array("data".utf8)); u32(frames * 2)
        for index in 0..<frames { u16(Int(UInt16(bitPattern: Int16(index % 200 - 100)))) }
        try data.write(to: url)
        return url
    }

    func testReplayFeedsBothTracksOnOneTimelineThroughTheLiveFeedAndFlushesAtTheEnd() async throws {
        let mic = try wav(seconds: 1.0), system = try wav(seconds: 0.55)
        defer { try? FileManager.default.removeItem(at: mic); try? FileManager.default.removeItem(at: system) }
        let transcriber = RecordingTranscriber()
        let session = LiveSession(transcriber: transcriber)
        try await session.replay(microphone: mic, system: system, chunkSeconds: 0.25)

        let fed = await transcriber.fed
        XCTAssertEqual(fed.filter { $0.track == .microphone }.map(\.at), [0, 0.25, 0.5, 0.75])
        XCTAssertEqual(fed.filter { $0.track == .system }.map(\.at), [0, 0.25, 0.5])
        XCTAssertEqual(fed.filter { $0.track == .system }.map(\.count).reduce(0, +), 8_800, "every sample arrives")
        let finished = await transcriber.finished
        XCTAssertEqual(finished, 1, "the end of the feed flushes the last words once")
    }

    func testMalformedWavIsRejectedInsteadOfCrashing() throws {
        func riff(_ chunks: [(String, [UInt8], UInt32?)]) throws -> URL {
            var bytes = Array("RIFF".utf8) + [0, 0, 0, 0] + Array("WAVE".utf8)
            for (id, body, declared) in chunks {
                let size = declared ?? UInt32(body.count)
                bytes += Array(id.utf8) + withUnsafeBytes(of: size.littleEndian, Array.init) + body
            }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("bad-\(UUID().uuidString).wav")
            try Data(bytes).write(to: url)
            return url
        }
        // A 2-byte "fmt " chunk at the very end: reading its fields ran past the file.
        let shortFormat = try riff([("JUNK", [UInt8](repeating: 0, count: 36), nil), ("fmt ", [1, 0], 2)])
        // A "fmt " chunk claiming more bytes than the file has.
        let overlong = try riff([("JUNK", [UInt8](repeating: 0, count: 36), nil), ("fmt ", [1, 0, 1, 0], 64)])
        for url in [shortFormat, overlong] {
            XCTAssertThrowsError(try LiveSession.readSamples(url), url.lastPathComponent)
        }
    }

    func testModelThatFailsToLoadIsReportedAndTheFeedStillDrains() async throws {
        let mic = try wav(seconds: 0.3)
        defer { try? FileManager.default.removeItem(at: mic) }
        let session = LiveSession(transcriber: RecordingTranscriber(startError: LiveError.model("no encoder")))
        try await session.replay(microphone: mic, system: nil)
        let snapshot = await session.snapshot()
        XCTAssertEqual(snapshot.error, "Live model error: no encoder")
        XCTAssertEqual(session.feed.backlogFrames, 0)
    }

    func testSettingsDefaultToOffWithNemotronAndOldSettingsFilesStillLoad() throws {
        let old = try JSONDecoder().decode(Settings.self, from: Data(#"{"libraryLimit": 10}"#.utf8))
        XCTAssertFalse(old.live.enabled)
        XCTAssertEqual(old.live.engine, LiveTranscriptionSettings.ENGINE_NEMOTRON)
        XCTAssertEqual(old.live.language, "pl")
        XCTAssertEqual(old.live.options.latency, .ms1120)
        XCTAssertFalse(old.integrations.apiEnabled, "integration safety defaults unchanged")
    }

    @MainActor
    func testAPIServesLiveWordsChangedSinceARevision() async throws {
        let mock = LiveMock()
        let api = LocalAPI(token: "t", controller: mock, reader: LibraryReader(directory: FileManager.default.temporaryDirectory),
                           events: EventLog())
        func get(_ target: String) async -> HTTPResponse {
            await api.handle(HTTPRequest(method: "GET", target: target,
                                         headers: ["host": "127.0.0.1", "authorization": "Bearer t"]))
        }
        let off = await get("/v1/recording/live")
        XCTAssertEqual(off.status, 404)

        func word(_ id: String, _ text: String, revision: Int) -> LiveWord {
            LiveWord(id: id, track: .system, text: text, start: 0, end: 0.3, speakerID: "slot-0", textState: .final,
                     speakerState: .pending, isBleed: false, revision: revision)
        }
        mock.live = LiveTranscriptStatus(conversationID: nil, snapshot: LiveSnapshot(
            revision: 5, phase: .running, engine: "fake", words: [word("sys-0", "dzień", revision: 2), word("sys-1", "dobry", revision: 5)],
            speakers: [Speaker(id: "slot-0", name: "Speaker 1")], gaps: [], received: ["system": 1], error: nil))
        let response = await get("/v1/recording/live?since=2")
        XCTAssertEqual(response.status, 200)
        let body = try JSONSerialization.jsonObject(with: response.body) as? [String: Any]
        XCTAssertEqual(body?["revision"] as? Int, 5)
        XCTAssertEqual((body?["words"] as? [[String: Any]])?.compactMap { $0["id"] as? String }, ["sys-1"])
        XCTAssertEqual(body?["text"] as? String, TranscriptRenderer.text(mock.live!.snapshot.transcript))
        let bad = await get("/v1/recording/live?since=x")
        XCTAssertEqual(bad.status, 400)
    }
}
