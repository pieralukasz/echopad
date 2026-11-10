import CryptoKit
import Foundation
import ScribeKit

/// Something that happened in EchoPad, for `GET /v1/events` and webhooks.
public struct IntegrationEvent: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        case recordingStarted = "recording.started"
        case recordingStopped = "recording.stopped"
        case recordingDiscarded = "recording.discarded"
        case conversationSaved = "conversation.saved"
        case recordingFailed = "recording.failed"
        // Live transcription will add "transcript.segment", one finished segment per event,
        // on the same stream and sequence.
    }

    /// Unique per event and the same on every webhook retry, so receivers can drop duplicates.
    public var id: String
    /// Grows by one per event within one ``EventLog/streamID``.
    public var sequence: Int
    public var type: Kind
    public var createdAt: Date
    public var conversationID: UUID?
    public var title: String?
    public var duration: TimeInterval?
    public var wordCount: Int?
    public var message: String?
}

/// Recent events in order. Kept in memory only; a new app run starts a new stream.
@MainActor
public final class EventLog {
    public static let CAPACITY = 500

    public let streamID = UUID()
    public private(set) var events: [IntegrationEvent] = []
    public private(set) var latestSequence = 0
    public var onEvent: ((IntegrationEvent) -> Void)?

    public init() {}

    @discardableResult
    public func emit(_ type: IntegrationEvent.Kind, conversationID: UUID? = nil, title: String? = nil,
                     duration: TimeInterval? = nil, wordCount: Int? = nil, message: String? = nil) -> IntegrationEvent {
        latestSequence += 1
        let event = IntegrationEvent(id: UUID().uuidString.lowercased(), sequence: latestSequence, type: type,
                                     createdAt: Date(), conversationID: conversationID, title: title,
                                     duration: duration, wordCount: wordCount, message: message)
        events.append(event)
        if events.count > Self.CAPACITY { events.removeFirst(events.count - Self.CAPACITY) }
        onEvent?(event)
        return event
    }

    public func events(after sequence: Int, limit: Int = 100) -> [IntegrationEvent] {
        Array(events.filter { $0.sequence > sequence }.prefix(limit))
    }
}

/// The JSON a webhook receives: the event, plus the transcript when the webhook opted in.
struct WebhookPayload: Encodable {
    let event: IntegrationEvent
    let transcriptText: String?
    let transcript: Transcript?

    private enum Keys: String, CodingKey { case transcriptText, transcript }

    func encode(to encoder: Encoder) throws {
        try event.encode(to: encoder)
        var container = encoder.container(keyedBy: Keys.self)
        try container.encodeIfPresent(transcriptText, forKey: .transcriptText)
        try container.encodeIfPresent(transcript, forKey: .transcript)
    }

    /// nil when the webhook does not subscribe to this event type.
    static func body(for event: IntegrationEvent, webhook: IntegrationSettings.Webhook,
                     transcript: () -> Transcript?) -> Data? {
        guard webhook.events.isEmpty || webhook.events.contains(event.type.rawValue) else { return nil }
        let attached = webhook.includeTranscript && event.type == .conversationSaved ? transcript() : nil
        let payload = WebhookPayload(event: event, transcriptText: attached.map(TranscriptRenderer.text), transcript: attached)
        return try? IntegrationJSON.encoder().encode(payload)
    }
}

public enum WebhookPolicy {
    /// https anywhere; plain http only to this Mac.
    public static func validatedURL(_ string: String) -> URL? {
        guard let url = URL(string: string), let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased(), !host.isEmpty else {
            return nil
        }
        if scheme == "https" { return url }
        if scheme == "http", ["127.0.0.1", "localhost", "::1"].contains(host) { return url }
        return nil
    }

    /// Why Settings rejects `string` as a webhook URL; nil when it is accepted.
    public static func problem(_ string: String) -> String? {
        let trimmed = string.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed == "https://" { return "Enter the URL of the receiver." }
        if trimmed != string { return "Remove the spaces around the URL." }
        if validatedURL(string) != nil { return nil }
        if string.lowercased().hasPrefix("http://") { return "Use https. Plain http is allowed only to this Mac (localhost)." }
        return "Enter a full https:// URL."
    }

    /// Scheme and host only, for logs: paths, queries and user info often carry credentials.
    public static func redacted(_ url: URL) -> String {
        "\(url.scheme ?? "?")://\(url.host ?? "?")"
    }
}

public struct WebhookDelivery: Sendable {
    public var url: URL
    public var body: Data
    public var eventID: String
}

/// Sends webhooks one at a time in event order, off the main thread, so a slow or failing
/// receiver never holds up recording. Retries are bounded; the queue is bounded too.
public final class WebhookDispatcher: @unchecked Sendable {
    public static let MAX_PENDING = 100
    public static let REQUEST_TIMEOUT: TimeInterval = 10
    public static let RETRY_DELAYS: [Duration] = [.seconds(2), .seconds(10)]

    private let session: URLSession
    private let key: Data?
    private let retryDelays: [Duration]
    private let lock = NSLock()
    private var queue: [WebhookDelivery] = []
    private var worker: Task<Void, Never>?

    public init(secret: String?, retryDelays: [Duration] = RETRY_DELAYS) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = Self.REQUEST_TIMEOUT
        configuration.timeoutIntervalForResource = Self.REQUEST_TIMEOUT * 2
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        session = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
        key = secret.map(IntegrationSecrets.webhookKey)
        self.retryDelays = retryDelays
    }

    deinit { session.invalidateAndCancel() }

    public func enqueue(_ delivery: WebhookDelivery) {
        lock.lock()
        defer { lock.unlock() }
        guard queue.count < Self.MAX_PENDING else {
            Log.integrations.error("Webhook queue full, dropped event \(delivery.eventID, privacy: .public)")
            return
        }
        queue.append(delivery)
        if worker == nil { worker = Task.detached { [self] in await drain() } }
    }

    /// Waits until every queued webhook was delivered or gave up.
    public func waitUntilIdle() async {
        while let worker = lock.withLock({ self.worker }) { await worker.value }
    }

    private func next() -> WebhookDelivery? {
        lock.withLock {
            if queue.isEmpty {
                worker = nil
                return nil
            }
            return queue.removeFirst()
        }
    }

    private func drain() async {
        while let delivery = next() { await send(delivery) }
    }

    @discardableResult
    func send(_ delivery: WebhookDelivery) async -> Bool {
        let target = WebhookPolicy.redacted(delivery.url)
        for attempt in 0...retryDelays.count {
            if attempt > 0 { try? await Task.sleep(for: retryDelays[attempt - 1]) }
            var request = URLRequest(url: delivery.url, timeoutInterval: Self.REQUEST_TIMEOUT)
            request.httpMethod = "POST"
            request.httpBody = delivery.body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("EchoPad/\(EchoPadVersion.version)", forHTTPHeaderField: "User-Agent")
            // Standard Webhooks headers: https://www.standardwebhooks.com
            let timestamp = Int(Date().timeIntervalSince1970)
            request.setValue(delivery.eventID, forHTTPHeaderField: "webhook-id")
            request.setValue(String(timestamp), forHTTPHeaderField: "webhook-timestamp")
            if let key {
                request.setValue(Self.signature(key: key, id: delivery.eventID, timestamp: timestamp, body: delivery.body),
                                 forHTTPHeaderField: "webhook-signature")
            }
            do {
                let (_, response) = try await session.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                if (200..<300).contains(status) { return true }
                Log.integrations.error("Webhook \(delivery.eventID, privacy: .public) to \(target, privacy: .public): HTTP \(status), attempt \(attempt + 1)")
                guard status == 408 || status == 429 || status >= 500 else { return false }
            } catch {
                // The error code only: URL errors can carry the full URL in their description.
                let code = (error as? URLError)?.code.rawValue ?? -1
                Log.integrations.error("Webhook \(delivery.eventID, privacy: .public) to \(target, privacy: .public): network error \(code), attempt \(attempt + 1)")
            }
        }
        return false
    }

    static func signature(key: Data, id: String, timestamp: Int, body: Data) -> String {
        var message = Data("\(id).\(timestamp).".utf8)
        message.append(body)
        let mac = HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: key))
        return "v1," + Data(mac).base64EncodedString()
    }

    /// A redirect would resend the body to a host nobody configured.
    private final class NoRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }
}
