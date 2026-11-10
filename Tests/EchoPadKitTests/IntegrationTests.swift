import CryptoKit
import XCTest
import ScribeKit
@testable import EchoPadKit

/// Stands in for the recorder: start/stop are recorded and emit the events the real one does.
@MainActor
private final class MockRecorder: RecordingControlling {
    var status = RecordingStatus(state: "idle")
    var calls: [String] = []
    var events: EventLog?
    let id: UUID

    init(id: UUID = UUID()) { self.id = id }

    var recordingStatus: RecordingStatus { status }

    func startRecording(title: String?) async {
        calls.append("start:\(title ?? "-")")
        status = RecordingStatus(state: "recording", since: Date(), title: title, conversationID: id)
        events?.emit(.recordingStarted, conversationID: id, title: title)
    }

    func stopRecording() {
        calls.append("stop")
        status = RecordingStatus(state: "processing", step: "finishingAudio")
        events?.emit(.recordingStopped, conversationID: id, duration: 12)
        events?.emit(.conversationSaved, conversationID: id, title: "Sync", wordCount: 3)
    }
}

/// A synthetic data directory: two conversations, one recording in progress, no real data.
private struct Fixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("echopad-integrations-\(UUID().uuidString)")
    let id = UUID()
    let olderID = UUID()
    let inProgressID = UUID()
    var library: URL { root.appendingPathComponent("Library") }

    init() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        for (id, date, status) in [(id, 1_790_000_000.0, Conversation.Status.done), (olderID, 1_780_000_000.0, .transcribing)] {
            let folder = library.appendingPathComponent(id.uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let conversation = Conversation(id: id, title: id == self.id ? "Weekly sync" : "Older call",
                                            date: Date(timeIntervalSince1970: date), duration: 65, status: status)
            try encoder.encode(conversation).write(to: folder.appendingPathComponent("conversation.json"))
        }
        let transcript = Transcript(segments: [Segment(speakerID: "s1", start: 0, end: 2, text: "Hello synthetic world.")],
                                    speakers: [Speaker(id: "s1", name: "Alex")], duration: 2)
        try JSONEncoder().encode(transcript).write(to: library.appendingPathComponent(id.uuidString).appendingPathComponent("transcript.json"))
        let recording = library.appendingPathComponent(inProgressID.uuidString)
        try FileManager.default.createDirectory(at: recording, withIntermediateDirectories: true)
        try Data(count: 64).write(to: recording.appendingPathComponent("microphone.wav"))
    }

    func checksums() -> [String: String] {
        var result: [String: String] = [:]
        for case let url as URL in FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)! {
            if let data = try? Data(contentsOf: url) {
                result[url.path] = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            }
        }
        return result
    }

    func writeSettings(apiEnabled: Bool, port: UInt16) throws {
        try Data(#"{"language":"en","integrations":{"apiEnabled":\#(apiEnabled),"apiPort":\#(port)}}"#.utf8)
            .write(to: root.appendingPathComponent("settings.json"))
    }
}

/// A webhook receiver on localhost answering with the given statuses in turn (the last repeats).
private final class Receiver: @unchecked Sendable {
    private let lock = NSLock()
    private var received: [HTTPRequest] = []
    private let statuses: [Int]
    private var server: LocalHTTPServer?
    private(set) var url = ""

    init(statuses: [Int]) throws {
        self.statuses = statuses
        let server = LocalHTTPServer { [unowned self] request in self.handle(request) }
        url = "http://127.0.0.1:\(try server.start(port: 0))/hook"
        self.server = server
    }

    deinit { server?.stop() }

    var requests: [HTTPRequest] { lock.withLock { received } }

    private func handle(_ request: HTTPRequest) -> HTTPResponse {
        lock.withLock {
            received.append(request)
            return HTTPResponse(status: statuses[min(received.count, statuses.count) - 1])
        }
    }
}

private func json(_ data: Data) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
}

/// First IPv4 address of this Mac that is not loopback, if any.
private func lanIPv4() -> String? {
    var list: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&list) == 0, let first = list else { return nil }
    defer { freeifaddrs(list) }
    for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
        guard let address = entry.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET) else { continue }
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
        let text = String(cString: host)
        if !text.hasPrefix("127.") { return text }
    }
    return nil
}

private func runCLI(_ arguments: [String]) async -> (code: Int32, output: String, errors: String) {
    // Off the main actor: the CLI blocks while the API it calls answers on the main actor.
    await Task.detached {
        var output: [String] = [], errors: [String] = []
        let code = EchoPadCLI.run(arguments, output: { output.append($0) }, errors: { errors.append($0) })
        return (code, output.joined(separator: "\n"), errors.joined(separator: "\n"))
    }.value
}

@MainActor
final class IntegrationTests: XCTestCase {
    private nonisolated static let TOKEN = "test-token-0123456789"
    private var fixture: Fixture!

    override func setUpWithError() throws {
        fixture = try Fixture()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: fixture.root)
    }

    private func makeAPI() -> (LocalAPI, MockRecorder, EventLog) {
        let events = EventLog()
        let mock = MockRecorder(id: fixture.id)
        mock.events = events
        let api = LocalAPI(token: Self.TOKEN, controller: mock, reader: LibraryReader(directory: fixture.library), events: events)
        return (api, mock, events)
    }

    private func request(_ method: String, _ target: String, token: String? = TOKEN,
                         headers: [String: String] = [:], body: String = "") -> HTTPRequest {
        var all = ["Host": "127.0.0.1:47821"]
        if let token { all["Authorization"] = "Bearer \(token)" }
        all.merge(headers) { $1 }
        return HTTPRequest(method: method, target: target, headers: all, body: Data(body.utf8))
    }

    // MARK: - API

    func testAPIRefusesMissingOrWrongTokenWebPagesAndForeignHosts() async {
        let (api, _, _) = makeAPI()
        for token in [nil, "wrong", String(Self.TOKEN.dropLast()), Self.TOKEN + "x"] {
            let response = await api.handle(request("GET", "/v1/status", token: token))
            XCTAssertEqual(response.status, 401, "token \(token ?? "none")")
        }
        let fromPage = await api.handle(request("GET", "/v1/status", headers: ["Origin": "https://site.example"]))
        XCTAssertEqual(fromPage.status, 403)
        XCTAssertNil(fromPage.headers["Access-Control-Allow-Origin"])
        let rebound = await api.handle(request("GET", "/v1/status", headers: ["Host": "rebind.example:47821"]))
        XCTAssertEqual(rebound.status, 403)
        let allowed = await api.handle(request("GET", "/v1/status"))
        XCTAssertEqual(allowed.status, 200)
        XCTAssertEqual(json(allowed.body)["state"] as? String, "idle")
    }

    func testAPIStartStopDriveTheControllerAndEventsKeepTheirOrder() async {
        let (api, mock, _) = makeAPI()
        let started = await api.handle(request("POST", "/v1/recording/start", body: #"{"title":"  Sync "}"#))
        XCTAssertEqual(started.status, 200)
        XCTAssertEqual(json(started.body)["state"] as? String, "recording")
        XCTAssertEqual(json(started.body)["conversationID"] as? String, fixture.id.uuidString)
        let twice = await api.handle(request("POST", "/v1/recording/start"))
        XCTAssertEqual(twice.status, 409)
        let stopped = await api.handle(request("POST", "/v1/recording/stop"))
        XCTAssertEqual(stopped.status, 202)
        let stoppedAgain = await api.handle(request("POST", "/v1/recording/stop"))
        XCTAssertEqual(stoppedAgain.status, 409)
        XCTAssertEqual(mock.calls, ["start:Sync", "stop"])
        let badBody = await api.handle(request("POST", "/v1/recording/start", body: "title=x"))
        XCTAssertEqual(badBody.status, 400)

        let all = json(await api.handle(request("GET", "/v1/events?after=0")).body)
        let events = all["events"] as? [[String: Any]] ?? []
        XCTAssertEqual(events.compactMap { $0["type"] as? String }, ["recording.started", "recording.stopped", "conversation.saved"])
        XCTAssertEqual(events.compactMap { $0["sequence"] as? Int }, [1, 2, 3])
        XCTAssertEqual(Set(events.compactMap { $0["id"] as? String }).count, 3)
        XCTAssertEqual(all["latest"] as? Int, 3)
        let later = json(await api.handle(request("GET", "/v1/events?after=1")).body)["events"] as? [[String: Any]] ?? []
        XCTAssertEqual(later.compactMap { $0["type"] as? String }, ["recording.stopped", "conversation.saved"])
    }

    func testAPIReadsLibraryAndTranscriptWithoutChangingFiles() async {
        let (api, _, _) = makeAPI()
        let before = fixture.checksums()
        let list = await api.handle(request("GET", "/v1/conversations"))
        XCTAssertEqual(list.status, 200)
        let ids = (json(list.body)["conversations"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
        XCTAssertEqual(ids, [fixture.id.uuidString, fixture.olderID.uuidString], "newest first, recording in progress skipped")
        let limited = await api.handle(request("GET", "/v1/conversations?limit=1"))
        XCTAssertEqual((json(limited.body)["conversations"] as? [Any])?.count, 1)
        let show = await api.handle(request("GET", "/v1/conversations/\(fixture.id.uuidString)"))
        XCTAssertEqual(json(show.body)["title"] as? String, "Weekly sync")
        let transcript = await api.handle(request("GET", "/v1/conversations/\(fixture.id.uuidString)/transcript"))
        XCTAssertEqual(transcript.status, 200)
        XCTAssertTrue((json(transcript.body)["text"] as? String ?? "").contains("Hello synthetic world."))
        for target in ["/v1/conversations/\(UUID().uuidString)", "/v1/conversations/nope", "/v1/conversations/\(fixture.olderID.uuidString)/transcript", "/v1/nothing"] {
            let missing = await api.handle(request("GET", target))
            XCTAssertEqual(missing.status, 404, target)
        }
        let badLimit = await api.handle(request("GET", "/v1/conversations?limit=0"))
        XCTAssertEqual(badLimit.status, 400)
        XCTAssertEqual(fixture.checksums(), before, "reads must not touch the library")
    }

    func testParserLimitsRequestSize() {
        func status(_ raw: String) -> Int? {
            if case .failed(let response) = LocalHTTPServer.parse(Data(raw.utf8)) { return response.status }
            return nil
        }
        XCTAssertEqual(status("POST /v1/recording/start HTTP/1.1\r\nContent-Length: 70000\r\n\r\n"), 413)
        XCTAssertEqual(status("POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n"), 501)
        XCTAssertEqual(status("GET / HTTP/1.1\r\nX: " + String(repeating: "a", count: 20_000) + "\r\n\r\n"), 431)
        XCTAssertEqual(status("GET /x HTTP/1.1\r\nX: " + String(repeating: "a", count: 20_000)), 431)
        XCTAssertEqual(status("garbage\r\n\r\n"), 400)
        if case .incomplete = LocalHTTPServer.parse(Data("POST / HTTP/1.1\r\nContent-Length: 5\r\n\r\nab".utf8)) {} else {
            XCTFail("a partial body waits for the rest")
        }
    }

    func testHTTPRoundtripOnLoopback() async throws {
        let (api, _, _) = makeAPI()
        let server = LocalHTTPServer { request in await api.handle(request) }
        let port = try server.start(port: 0)
        defer { server.stop() }
        let session = URLSession(configuration: .ephemeral)
        func send(_ headers: [String: String]) async throws -> (Int, HTTPURLResponse, Data) {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/status")!)
            headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
            let (data, response) = try await session.data(for: request)
            let http = response as! HTTPURLResponse
            return (http.statusCode, http, data)
        }
        let (anonymous, _, _) = try await send([:])
        XCTAssertEqual(anonymous, 401)
        let (fromPage, _, _) = try await send(["Authorization": "Bearer \(Self.TOKEN)", "Origin": "https://site.example"])
        XCTAssertEqual(fromPage, 403)
        let (ok, response, body) = try await send(["Authorization": "Bearer \(Self.TOKEN)"])
        XCTAssertEqual(ok, 200)
        XCTAssertEqual(json(body)["state"] as? String, "idle")
        XCTAssertNil(response.value(forHTTPHeaderField: "Access-Control-Allow-Origin"))
        XCTAssertEqual(response.value(forHTTPHeaderField: "Cache-Control"), "no-store")

        // Not reachable from the network: the same port on this Mac's LAN address refuses.
        if let lan = lanIPv4() {
            var request = URLRequest(url: URL(string: "http://\(lan):\(port)/v1/status")!, timeoutInterval: 2)
            request.setValue("Bearer \(Self.TOKEN)", forHTTPHeaderField: "Authorization")
            do {
                _ = try await session.data(for: request)
                XCTFail("the API answered on \(lan)")
            } catch {}
        }
    }

    // MARK: - CLI

    func testCLIStartStopAndStatusGoThroughTheRunningAPI() async throws {
        let (_, mock, events) = makeAPI()
        let token = try IntegrationSecrets.loadOrCreate(IntegrationSecrets.apiTokenURL(in: fixture.root), kind: .apiToken)
        let api = LocalAPI(token: token, controller: mock, reader: LibraryReader(directory: fixture.library), events: events)
        let server = LocalHTTPServer { request in await api.handle(request) }
        let port = try server.start(port: 0)
        defer { server.stop() }
        try fixture.writeSettings(apiEnabled: true, port: port)
        let dataDir = ["--data-dir", fixture.root.path]

        let start = await runCLI(["start", "--title", "Sync"] + dataDir)
        XCTAssertEqual(start.code, 0, start.errors)
        XCTAssertTrue(start.output.contains("\"recording\""))
        let stop = await runCLI(["stop"] + dataDir)
        XCTAssertEqual(stop.code, 0, stop.errors)
        let status = await runCLI(["status", "--json"] + dataDir)
        XCTAssertTrue(status.output.contains("\"processing\""))
        let stopIdle = await runCLI(["stop"] + dataDir)
        XCTAssertEqual(stopIdle.code, 1)
        XCTAssertTrue(stopIdle.errors.contains("409"))
        let log = await runCLI(["events", "--after", "1"] + dataDir)
        XCTAssertTrue(log.output.contains("recording.stopped"))
        XCTAssertEqual(mock.calls, ["start:Sync", "stop"])
        for run in [start, stop, status, stopIdle, log] {
            XCTAssertFalse((run.output + run.errors).contains(token), "the token never appears in output")
        }

        try fixture.writeSettings(apiEnabled: false, port: port)
        let off = await runCLI(["start"] + dataDir)
        XCTAssertEqual(off.code, 1)
        XCTAssertTrue(off.errors.contains("local API is off"))
        XCTAssertEqual(mock.calls, ["start:Sync", "stop"], "no request while the API is off")
    }

    func testCLIReadsTheLibraryReadOnlyAndKeepsTheAppForNoArguments() async {
        let before = fixture.checksums()
        let dataDir = ["--data-dir", fixture.root.path]
        let list = await runCLI(["list", "--json"] + dataDir)
        XCTAssertEqual(list.code, 0, list.errors)
        XCTAssertTrue(list.output.contains(fixture.id.uuidString))
        XCTAssertFalse(list.output.contains(fixture.inProgressID.uuidString))
        let search = await runCLI(["list", "--search", "older"] + dataDir)
        XCTAssertEqual(search.output.components(separatedBy: "\n").count, 1)
        XCTAssertTrue(search.output.contains(fixture.olderID.uuidString))
        let text = await runCLI(["transcript", fixture.id.uuidString] + dataDir)
        XCTAssertTrue(text.output.contains("Hello synthetic world."))
        let missing = await runCLI(["show", UUID().uuidString] + dataDir)
        XCTAssertEqual(missing.code, 1)
        let unknown = await runCLI(["record"] + dataDir)
        XCTAssertEqual(unknown.code, 1)
        XCTAssertEqual(fixture.checksums(), before)

        XCTAssertFalse(EchoPadCLI.isCLIInvocation([]))
        XCTAssertFalse(EchoPadCLI.isCLIInvocation(["-psn_0_12345"]))
        XCTAssertFalse(EchoPadCLI.isCLIInvocation(["-NSDocumentRevisionsDebugMode", "YES"]))
        XCTAssertTrue(EchoPadCLI.isCLIInvocation(["status"]))
    }

    // MARK: - Webhooks

    func testWebhooksArriveInOrderSignedAndCarryTheTranscriptOnlyWhenOptedIn() async throws {
        let plain = try Receiver(statuses: [200])
        let withText = try Receiver(statuses: [200])
        let mock = MockRecorder(id: fixture.id)
        let hub = IntegrationHub(controller: mock, libraryDirectory: fixture.library, supportDirectory: fixture.root,
                                 retryDelays: [.milliseconds(10)])
        mock.events = hub.events
        var settings = IntegrationSettings()
        settings.webhooksEnabled = true
        settings.webhooks = [.init(url: plain.url),
                             .init(url: withText.url, events: ["conversation.saved"], includeTranscript: true)]
        hub.apply(settings)
        XCTAssertNil(hub.apiPort, "webhooks alone do not open the API")

        await mock.startRecording(title: "Sync")
        mock.stopRecording()
        await hub.waitForWebhooks()

        let received = plain.requests
        XCTAssertEqual(received.compactMap { json($0.body)["type"] as? String },
                       ["recording.started", "recording.stopped", "conversation.saved"])
        XCTAssertEqual(received.compactMap { $0.headers["webhook-id"] }, hub.events.events.map(\.id))
        XCTAssertFalse(received.contains { String(decoding: $0.body, as: UTF8.self).contains("Hello synthetic") })
        XCTAssertFalse(received.contains { json($0.body)["transcript"] != nil })

        let secret = try XCTUnwrap(IntegrationSecrets.load(IntegrationSecrets.webhookSecretURL(in: fixture.root)))
        let key = SymmetricKey(data: try XCTUnwrap(Data(base64Encoded: String(secret.dropFirst("whsec_".count)))))
        for request in received {
            let signed = Data("\(request.headers["webhook-id"]!).\(request.headers["webhook-timestamp"]!).".utf8) + request.body
            let expected = "v1," + Data(HMAC<SHA256>.authenticationCode(for: signed, using: key)).base64EncodedString()
            XCTAssertEqual(request.headers["webhook-signature"], expected)
        }

        XCTAssertEqual(withText.requests.count, 1, "only the subscribed event")
        let saved = json(withText.requests[0].body)
        XCTAssertEqual(saved["type"] as? String, "conversation.saved")
        XCTAssertTrue((saved["transcriptText"] as? String ?? "").contains("Hello synthetic world."))
    }

    func testWebhookRetriesAreBoundedKeepTheEventIDAndDoNotBlock() async throws {
        let failing = try Receiver(statuses: [500])
        let flaky = try Receiver(statuses: [503, 200])
        let rejecting = try Receiver(statuses: [400])
        let hub = IntegrationHub(controller: MockRecorder(), libraryDirectory: fixture.library, supportDirectory: fixture.root,
                                 retryDelays: [.milliseconds(300), .milliseconds(20)])
        var settings = IntegrationSettings()
        settings.webhooksEnabled = true
        settings.webhooks = [failing, flaky, rejecting].map { .init(url: $0.url) }
        hub.apply(settings)

        let clock = ContinuousClock.now
        let event = hub.events.emit(.recordingStarted, conversationID: fixture.id)
        XCTAssertLessThan(ContinuousClock.now - clock, .milliseconds(200), "emitting never waits for delivery")
        await hub.waitForWebhooks()

        XCTAssertEqual(failing.requests.count, 3, "one try plus two retries")
        XCTAssertEqual(Set(failing.requests.compactMap { $0.headers["webhook-id"] }), [event.id])
        XCTAssertEqual(flaky.requests.count, 2)
        XCTAssertEqual(rejecting.requests.count, 1, "4xx is not retried")
    }

    func testWebhookURLPolicyAndRedactedLogTarget() {
        XCTAssertNotNil(WebhookPolicy.validatedURL("https://hooks.example.com/x"))
        XCTAssertNotNil(WebhookPolicy.validatedURL("http://127.0.0.1:9000/hook"))
        XCTAssertNil(WebhookPolicy.validatedURL("http://hooks.example.com/x"))
        XCTAssertNil(WebhookPolicy.validatedURL("file:///etc/hosts"))
        XCTAssertNil(WebhookPolicy.validatedURL("not a url"))
        XCTAssertEqual(WebhookPolicy.redacted(URL(string: "https://user:pw@hooks.example.com/T0/abc?token=x")!),
                       "https://hooks.example.com")
    }

    // MARK: - Settings and secrets

    func testIntegrationsAreOffByDefaultAndSecretsArePrivate() throws {
        XCTAssertEqual(Settings().integrations, IntegrationSettings())
        XCTAssertFalse(IntegrationSettings().apiEnabled)
        XCTAssertFalse(IntegrationSettings().webhooksEnabled)
        let old = try JSONDecoder().decode(Settings.self, from: Data(#"{"language":"pl"}"#.utf8))
        XCTAssertEqual(old.integrations, IntegrationSettings())
        let partial = try JSONDecoder().decode(Settings.self, from: Data(#"{"integrations":{"apiEnabled":true,"webhooks":[{"url":"https://x.example"}]}}"#.utf8))
        XCTAssertEqual(partial.integrations.apiPort, IntegrationSettings.DEFAULT_PORT)
        XCTAssertFalse(partial.integrations.webhooksEnabled)
        XCTAssertFalse(partial.integrations.webhooks[0].includeTranscript)

        let url = IntegrationSecrets.apiTokenURL(in: fixture.root)
        let token = try IntegrationSecrets.loadOrCreate(url, kind: .apiToken)
        XCTAssertEqual(token.count, 64)
        XCTAssertEqual(try IntegrationSecrets.loadOrCreate(url, kind: .apiToken), token)
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
        let secret = try IntegrationSecrets.loadOrCreate(IntegrationSecrets.webhookSecretURL(in: fixture.root), kind: .webhookSecret)
        XCTAssertTrue(secret.hasPrefix("whsec_"))
    }
}
