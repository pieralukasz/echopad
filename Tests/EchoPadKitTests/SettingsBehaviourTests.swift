import Foundation
import ScribeKit
import XCTest
@testable import EchoPadKit

@MainActor
private final class IdleRecorder: RecordingControlling {
    var recordingStatus = RecordingStatus(state: "idle")
    func startRecording(title: String?) async {}
    func stopRecording() {}
}

/// Loads its "models" only when `release()` is called, so a test can look at the session meanwhile.
private actor SlowTranscriber: LiveTranscribing {
    private var waiter: CheckedContinuation<Void, Never>?
    private var released = false
    private let failure: Error?

    init(failure: Error? = nil) { self.failure = failure }

    func release() {
        released = true
        waiter?.resume()
        waiter = nil
    }

    func start() async throws {
        if !released { await withCheckedContinuation { waiter = $0 } }
        if let failure { throw failure }
    }
    func feed(_ samples: [Float], track: LiveTrack, at time: TimeInterval?) async throws {}
    func finish() async throws -> LiveSnapshot { snapshot() }
    private(set) var cancelled = false
    func cancel() async { cancelled = true }
    func reportGap(_ gap: LiveGap) async {}
    func snapshot() -> LiveSnapshot {
        LiveSnapshot(revision: 0, phase: .idle, engine: "fake", words: [], speakers: [], gaps: [], received: [:], error: nil)
    }
}

final class SettingsBehaviourTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("settings-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Library"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func get(_ port: UInt16, token: String?) async -> Int? {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/status")!)
        request.timeoutInterval = 3
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let session = URLSession(configuration: .ephemeral)
        guard let (_, response) = try? await session.data(for: request) else { return nil }
        return (response as? HTTPURLResponse)?.statusCode
    }

    @MainActor
    private func makeHub() -> IntegrationHub {
        IntegrationHub(controller: IdleRecorder(), libraryDirectory: root.appendingPathComponent("Library"), supportDirectory: root)
    }

    // MARK: - Local API switch

    @MainActor
    func testSwitchingTheAPIOnListensWithAuthAndSwitchingItOffClosesIt() async throws {
        let hub = makeHub()
        XCTAssertNil(hub.secret(.apiToken), "no token is made while the API is off")
        var settings = IntegrationSettings()
        settings.apiEnabled = true
        settings.apiPort = 0 // any free port
        hub.apply(settings)
        guard case .listening(let port) = hub.status.api else { return XCTFail("status \(hub.status.api)") }
        XCTAssertEqual(hub.apiPort, port)

        let token = try XCTUnwrap(hub.secret(.apiToken))
        XCTAssertEqual(token, IntegrationSecrets.load(IntegrationSecrets.apiTokenURL(in: root)))
        let mode = try FileManager.default.attributesOfItem(atPath: IntegrationSecrets.apiTokenURL(in: root).path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
        let authorized = await get(port, token: token)
        let anonymous = await get(port, token: nil)
        let wrong = await get(port, token: "not-the-token")
        XCTAssertEqual(authorized, 200)
        XCTAssertEqual(anonymous, 401)
        XCTAssertEqual(wrong, 401)

        settings.apiEnabled = false
        hub.apply(settings)
        XCTAssertEqual(hub.status.api, .off)
        XCTAssertNil(hub.apiPort)
        let afterOff = await get(port, token: token)
        XCTAssertNil(afterOff, "the port must refuse connections once access is switched off")
    }

    @MainActor
    func testABusyPortIsReportedAsFailedNotActiveAndTryAgainRecovers() async throws {
        let blocker = LocalHTTPServer { _ in HTTPResponse(status: 418) }
        let port = try blocker.start(port: 0)
        let hub = makeHub()
        var settings = IntegrationSettings()
        settings.apiEnabled = true
        settings.apiPort = port
        hub.apply(settings) // as at launch with the API on
        guard case .failed(let message) = hub.status.api else { return XCTFail("status \(hub.status.api)") }
        XCTAssertTrue(message.contains("\(port)"), message)
        XCTAssertNil(hub.apiPort)
        let busy = await get(port, token: hub.secret(.apiToken))
        XCTAssertEqual(busy, 418, "the other app keeps its port")

        // Editing webhooks does not rebind (or flap) the listener.
        settings.webhooks = [.init(url: "https://example.com/hook")]
        hub.apply(settings)
        XCTAssertNotEqual(hub.status.api, .listening(port: port))

        blocker.stop()
        try await Task.sleep(for: .milliseconds(200))
        hub.retryAPI()
        XCTAssertEqual(hub.status.api, .listening(port: port))
        let recovered = await get(port, token: hub.secret(.apiToken))
        XCTAssertEqual(recovered, 200)
        hub.stop()
    }

    @MainActor
    func testChangingThePortMovesTheListener() async throws {
        let hub = makeHub()
        var settings = IntegrationSettings()
        settings.apiEnabled = true
        settings.apiPort = 0
        hub.apply(settings)
        guard case .listening(let first) = hub.status.api else { return XCTFail("status \(hub.status.api)") }
        let probe = LocalHTTPServer { _ in HTTPResponse(status: 200) }
        let free = try probe.start(port: 0)
        probe.stop()
        try await Task.sleep(for: .milliseconds(200))
        settings.apiPort = free
        hub.apply(settings)
        XCTAssertEqual(hub.status.api, .listening(port: free))
        let old = await get(first, token: hub.secret(.apiToken))
        XCTAssertNil(old)
        hub.stop()
    }

    // MARK: - Persistence

    func testIntegrationAndLiveSettingsSurviveARestart() throws {
        var settings = Settings()
        settings.integrations.apiEnabled = true
        settings.integrations.apiPort = 50_123
        settings.integrations.webhooksEnabled = true
        settings.integrations.webhooks = [.init(url: "https://example.com/a", events: ["conversation.saved"], includeTranscript: true)]
        settings.live.enabled = true
        settings.live.language = nil // "Detect automatically"
        settings.live.latencyMs = 560
        settings.live.diarize = false
        let file = root.appendingPathComponent("settings.json")
        try SettingsStore.save(settings, to: file)
        let loaded = SettingsStore.load(from: file)
        XCTAssertEqual(loaded.integrations, settings.integrations)
        XCTAssertEqual(loaded.live, settings.live)
        XCTAssertNil(loaded.live.language, "automatic detection must not turn back into Polish")
    }

    func testDefaultsStayOffAndPolish() {
        let settings = Settings()
        XCTAssertFalse(settings.integrations.apiEnabled)
        XCTAssertFalse(settings.integrations.webhooksEnabled)
        XCTAssertFalse(settings.live.enabled)
        XCTAssertEqual(settings.live.language, "pl")
        XCTAssertEqual(Languages.live.first?.code, "pl")
    }

    // MARK: - Live state

    func testLiveSessionShowsPreparingUntilTheModelsAreLoaded() async throws {
        let transcriber = SlowTranscriber()
        let session = LiveSession(transcriber: transcriber)
        await session.start()
        let before = await session.status()
        XCTAssertEqual(before, .preparing)
        await transcriber.release()
        try await Task.sleep(for: .milliseconds(100))
        let after = await session.status()
        XCTAssertEqual(after, .listening(words: 0))
        await session.cancel()
    }

    /// Controlled fault injection of the stuck load seen in the probe (CoreML load that never
    /// returned): the session gives up visibly instead of staying "preparing" forever.
    func testALiveModelLoadThatNeverReturnsFailsVisiblyAfterTheTimeout() async throws {
        let transcriber = SlowTranscriber() // never released: start() never returns
        let session = LiveSession(transcriber: transcriber, loadTimeout: .milliseconds(200))
        await session.start()
        let early = await session.status()
        XCTAssertEqual(early, .preparing)
        try await Task.sleep(for: .milliseconds(600))
        let status = await session.status()
        guard case .failed(let message) = status else { return XCTFail("status \(status)") }
        XCTAssertTrue(message.contains("did not load"), message)
        XCTAssertTrue(status.isTerminal)
        let cancelled = await transcriber.cancelled
        XCTAssertTrue(cancelled, "the stuck transcriber is cancelled so its models are dropped if they ever load")
        let next = await session.feed.next()
        XCTAssertNil(next, "the feed is closed, so recorded audio no longer piles up")
        await transcriber.release()
    }

    func testALoadThatFinishesBeforeTheTimeoutKeepsListening() async throws {
        let transcriber = SlowTranscriber()
        let session = LiveSession(transcriber: transcriber, loadTimeout: .milliseconds(300))
        await session.start()
        await transcriber.release()
        try await Task.sleep(for: .milliseconds(600))
        let status = await session.status()
        XCTAssertEqual(status, .listening(words: 0))
        await session.cancel()
    }

    func testALiveModelThatFailsToLoadShowsFailed() async throws {
        let transcriber = SlowTranscriber(failure: LiveError.model("no network"))
        let session = LiveSession(transcriber: transcriber)
        await session.start()
        await transcriber.release()
        try await Task.sleep(for: .milliseconds(100))
        let status = await session.status()
        guard case .failed(let message) = status else { return XCTFail("status \(status)") }
        XCTAssertTrue(message.contains("no network"), message)
        XCTAssertTrue(status.isTerminal)
        await session.cancel()
    }

    func testLiveModelCacheChecksTheChosenLookAheadAndDiarizer() throws {
        let speech = root.appendingPathComponent("nemotron-labs-unified-asr/coreml")
        try FileManager.default.createDirectory(at: speech, withIntermediateDirectories: true)
        for name in ["nemotron_unified_encoder_streaming_70_7_7.mlmodelc", "nemotron_unified_decoder.mlmodelc",
                     "nemotron_unified_joint_decision_single_step.mlmodelc"] {
            try FileManager.default.createDirectory(at: speech.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        try Data("{}".utf8).write(to: speech.appendingPathComponent("vocab.json"))
        XCTAssertTrue(LiveModelCache.isDownloaded(latencyMs: 1120, diarize: false, in: root))
        XCTAssertFalse(LiveModelCache.isDownloaded(latencyMs: 560, diarize: false, in: root))
        XCTAssertFalse(LiveModelCache.isDownloaded(latencyMs: 1120, diarize: true, in: root))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("ls-eend/dih3"), withIntermediateDirectories: true)
        XCTAssertTrue(LiveModelCache.isDownloaded(latencyMs: 1120, diarize: true, in: root))
    }

    // MARK: - Form validation

    func testWebhookURLAndPortValidation() {
        XCTAssertNil(WebhookPolicy.problem("https://example.com/hook"))
        XCTAssertNil(WebhookPolicy.problem("http://localhost:8080/hook"))
        XCTAssertNotNil(WebhookPolicy.problem("http://example.com/hook"))
        XCTAssertNotNil(WebhookPolicy.problem("https://"))
        XCTAssertNotNil(WebhookPolicy.problem(" https://example.com"))
        XCTAssertNotNil(WebhookPolicy.problem("example.com"))
        XCTAssertEqual(IntegrationsSettingsView.port(from: "47821"), 47_821)
        XCTAssertNil(IntegrationsSettingsView.port(from: "80"))
        XCTAssertNil(IntegrationsSettingsView.port(from: "70000"))
        XCTAssertNil(IntegrationsSettingsView.port(from: "abc"))
    }
}
