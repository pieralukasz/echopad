import Foundation
import ScribeKit

/// What the recorder is doing, as the API and CLI report it.
public struct RecordingStatus: Codable, Equatable, Sendable {
    /// `idle`, `recording`, `processing`, `saved` or `error`.
    public var state: String
    /// Processing step (`finishingAudio`, `transcribing`, `identifyingSpeakers`, `saving`).
    public var step: String?
    public var since: Date?
    public var title: String?
    public var conversationID: UUID?
    public var message: String?

    public init(state: String, step: String? = nil, since: Date? = nil, title: String? = nil,
                conversationID: UUID? = nil, message: String? = nil) {
        self.state = state
        self.step = step
        self.since = since
        self.title = title
        self.conversationID = conversationID
        self.message = message
    }

    public init(phase: Phase, title: String?, conversationID: UUID?) {
        switch phase {
        case .idle: self.init(state: "idle")
        case .recording(let since): self.init(state: "recording", since: since, title: title, conversationID: conversationID)
        case .processing(let step): self.init(state: "processing", step: "\(step)")
        case .saved(let title): self.init(state: "saved", title: title)
        case .error(let message): self.init(state: "error", message: message)
        }
    }

    public var isBusy: Bool { state == "recording" || state == "processing" }
}

/// The recorder as the API drives it; ``RecordingController`` in the app, a mock in tests.
@MainActor
public protocol RecordingControlling: AnyObject {
    var recordingStatus: RecordingStatus { get }
    func startRecording(title: String?) async
    /// Returns at once; finishing the audio and transcribing continue in the app.
    func stopRecording()
    /// The live transcript of the current (or last) recording; nil when live transcription is off.
    func liveTranscript() async -> LiveTranscriptStatus?
}

extension RecordingControlling {
    public func liveTranscript() async -> LiveTranscriptStatus? { nil }
}

/// A live transcript as the API returns it.
public struct LiveTranscriptStatus: Sendable {
    public var conversationID: UUID?
    public var snapshot: LiveSnapshot

    public init(conversationID: UUID?, snapshot: LiveSnapshot) {
        self.conversationID = conversationID
        self.snapshot = snapshot
    }
}

/// Reads the library on disk without changing it: no folders created, no statuses repaired.
public struct LibraryReader: Sendable {
    public struct Failure: LocalizedError {
        public let errorDescription: String?
    }

    public let directory: URL

    public init(directory: URL = AppDirectories.library) {
        self.directory = directory
    }

    /// Newest first. Folders without `conversation.json` are recordings in progress and skipped.
    public func conversations() throws -> [Conversation] {
        let folders = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return try folders.compactMap { folder in
            guard let id = UUID(uuidString: folder.lastPathComponent) else { return nil }
            return try conversation(id)
        }.sorted { $0.date > $1.date }
    }

    public func conversation(_ id: UUID) throws -> Conversation? {
        try decode(Conversation.self, id, "conversation.json")
    }

    public func transcript(_ id: UUID) throws -> Transcript? {
        try decode(Transcript.self, id, "transcript.json")
    }

    private func decode<T: Decodable>(_ type: T.Type, _ id: UUID, _ name: String) throws -> T? {
        let url = directory.appendingPathComponent(id.uuidString).appendingPathComponent(name)
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw Failure(errorDescription: "\(id.uuidString)/\(name) is not readable: \(error.localizedDescription)")
        }
    }
}

/// Routes of the local API. Every request needs the bearer token; requests from web pages
/// (an `Origin` header) and with a non-loopback `Host` (DNS rebinding) are refused, and no
/// CORS headers are ever sent.
///
///     GET  /v1/status
///     POST /v1/recording/start     {"title": "…"} optional
///     POST /v1/recording/stop
///     GET  /v1/recording/live?since=<revision>   live words changed after that revision
///     GET  /v1/conversations?limit=50
///     GET  /v1/conversations/<id>
///     GET  /v1/conversations/<id>/transcript
///     GET  /v1/events?after=<sequence>
@MainActor
public final class LocalAPI {
    public static let DEFAULT_LIMIT = 50
    public static let MAX_LIMIT = 500
    public static let MAX_TITLE_LENGTH = 200

    private let token: String
    private let controller: RecordingControlling
    private let reader: LibraryReader
    private let events: EventLog

    public init(token: String, controller: RecordingControlling, reader: LibraryReader, events: EventLog) {
        self.token = token
        self.controller = controller
        self.reader = reader
        self.events = events
    }

    public func handle(_ request: HTTPRequest) async -> HTTPResponse {
        if request.headers["origin"] != nil { return .error(403, "Requests from web pages are not allowed") }
        guard Self.isLoopbackHost(request.headers["host"]) else { return .error(403, "Host not allowed") }
        guard isAuthorized(request.headers["authorization"]) else {
            var response = HTTPResponse.error(401, "Missing or wrong API token")
            response.headers["WWW-Authenticate"] = "Bearer"
            return response
        }
        do {
            return try await route(request)
        } catch {
            return .error(500, (error as? LocalizedError)?.errorDescription ?? "Internal error")
        }
    }

    private func route(_ request: HTTPRequest) async throws -> HTTPResponse {
        let parts = request.path.split(separator: "/").map(String.init)
        var route = parts
        if route.count >= 3, route[0] == "v1", route[1] == "conversations" { route[2] = ":id" }
        switch (request.method, route.joined(separator: "/")) {
        case ("GET", "v1/status"):
            return .json(200, controller.recordingStatus)
        case ("POST", "v1/recording/start"):
            struct Body: Decodable { var title: String? }
            var title: String?
            if !request.body.isEmpty {
                guard let body = try? JSONDecoder().decode(Body.self, from: request.body) else { return .error(400, "Body must be JSON") }
                title = body.title?.trimmingCharacters(in: .whitespacesAndNewlines)
                if title?.isEmpty == true { title = nil }
                guard (title?.count ?? 0) <= Self.MAX_TITLE_LENGTH else { return .error(400, "Title is too long") }
            }
            guard !controller.recordingStatus.isBusy else { return .error(409, "EchoPad is already recording or processing") }
            await controller.startRecording(title: title)
            let status = controller.recordingStatus
            return status.state == "recording" ? .json(200, status) : .json(500, status)
        case ("POST", "v1/recording/stop"):
            guard controller.recordingStatus.state == "recording" else { return .error(409, "EchoPad is not recording") }
            controller.stopRecording()
            return .json(202, controller.recordingStatus)
        case ("GET", "v1/recording/live"):
            guard let since = Int(request.query["since"] ?? "0"), since >= 0 else { return .error(400, "since must be a revision number") }
            guard let live = await controller.liveTranscript() else {
                return .error(404, "Live transcription is off or has not run since the app started")
            }
            struct Body: Encodable {
                let conversationID: UUID?
                let revision: Int
                let phase: LiveSnapshot.Phase
                let engine: String
                let text: String
                let words: [LiveWord]
                let speakers: [Speaker]
                let gaps: [LiveGap]
                let received: [String: TimeInterval]
                let error: String?
            }
            let snapshot = live.snapshot
            return .json(200, Body(conversationID: live.conversationID, revision: snapshot.revision, phase: snapshot.phase,
                                   engine: snapshot.engine, text: TranscriptRenderer.text(snapshot.transcript),
                                   words: snapshot.changes(since: since), speakers: snapshot.speakers, gaps: snapshot.gaps,
                                   received: snapshot.received, error: snapshot.error))
        case ("GET", "v1/conversations"):
            guard let limit = Int(request.query["limit"] ?? "\(Self.DEFAULT_LIMIT)"), (1...Self.MAX_LIMIT).contains(limit) else {
                return .error(400, "limit must be 1-\(Self.MAX_LIMIT)")
            }
            return .json(200, ["conversations": Array(try reader.conversations().prefix(limit))])
        case ("GET", "v1/conversations/:id"):
            guard let id = UUID(uuidString: parts[2]), let conversation = try reader.conversation(id) else { return .error(404, "No such conversation") }
            return .json(200, conversation)
        case ("GET", "v1/conversations/:id/transcript"):
            guard let id = UUID(uuidString: parts[2]), let transcript = try reader.transcript(id) else { return .error(404, "No transcript") }
            struct Body: Encodable { let conversationID: UUID; let text: String; let transcript: Transcript }
            return .json(200, Body(conversationID: id, text: TranscriptRenderer.text(transcript), transcript: transcript))
        case ("GET", "v1/events"):
            guard let after = Int(request.query["after"] ?? "0") else { return .error(400, "after must be a number") }
            struct Body: Encodable { let stream: UUID; let latest: Int; let events: [IntegrationEvent] }
            return .json(200, Body(stream: events.streamID, latest: events.latestSequence, events: events.events(after: after)))
        default:
            return .error(404, "Not found")
        }
    }

    private func isAuthorized(_ header: String?) -> Bool {
        guard let header, header.hasPrefix("Bearer "), !token.isEmpty else { return false }
        return Self.constantTimeEqual(String(header.dropFirst(7)), token)
    }

    static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        return zip(x, y).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }

    static func isLoopbackHost(_ host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        let name: Substring
        if host.hasPrefix("[") {
            name = host.dropFirst().prefix { $0 != "]" }
        } else {
            name = host.prefix { $0 != ":" }
        }
        return ["127.0.0.1", "localhost", "::1"].contains(String(name))
    }
}
