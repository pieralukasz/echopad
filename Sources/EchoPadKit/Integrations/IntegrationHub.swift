import Foundation
import Network
import Observation

/// State of the local API listener, as Settings shows it.
public enum APIState: Equatable, Sendable {
    case off
    case listening(port: UInt16)
    case failed(String)
}

/// What the integrations are doing, observed by Settings.
@MainActor
@Observable
public final class IntegrationStatus {
    public internal(set) var api: APIState = .off
}

/// Runs the local API and webhooks for the app, as configured in ``IntegrationSettings``.
@MainActor
public final class IntegrationHub {
    public let events = EventLog()
    public let status = IntegrationStatus()
    private let controller: RecordingControlling
    private let reader: LibraryReader
    private let supportDirectory: URL
    private let retryDelays: [Duration]
    private var settings = IntegrationSettings()
    private var server: LocalHTTPServer?
    private var serverPort: UInt16?
    private var dispatcher: WebhookDispatcher?

    /// The port the API listens on, nil while it is off.
    public var apiPort: UInt16? { serverPort }

    public init(controller: RecordingControlling, libraryDirectory: URL = AppDirectories.library,
                supportDirectory: URL = AppDirectories.applicationSupport,
                retryDelays: [Duration] = WebhookDispatcher.RETRY_DELAYS) {
        self.controller = controller
        reader = LibraryReader(directory: libraryDirectory)
        self.supportDirectory = supportDirectory
        self.retryDelays = retryDelays
        events.onEvent = { [weak self] event in self?.forward(event) }
    }

    public func apply(_ new: IntegrationSettings) {
        let old = settings
        settings = new
        // Only our own listener restarts; a recording in progress is not touched.
        if new.apiEnabled != old.apiEnabled || new.apiPort != old.apiPort { restartServer() }
        if !new.webhooksEnabled {
            dispatcher = nil
        } else if dispatcher == nil {
            let secret: String?
            do {
                secret = try IntegrationSecrets.loadOrCreate(IntegrationSecrets.webhookSecretURL(in: supportDirectory), kind: .webhookSecret)
            } catch {
                secret = nil
                Log.integrations.error("Webhook secret unavailable, sending unsigned: \(error.localizedDescription, privacy: .public)")
            }
            dispatcher = WebhookDispatcher(secret: secret, retryDelays: retryDelays)
        }
    }

    public func stop() {
        server?.stop()
        server = nil
        serverPort = nil
        status.api = .off
    }

    /// Binds the API again after a failure (for example once another app frees the port).
    public func retryAPI() {
        restartServer()
    }

    /// The API token or webhook signing secret, for copying in Settings. Creates it only for
    /// an integration that is switched on; never logged.
    public func secret(_ kind: IntegrationSecrets.Kind) -> String? {
        switch kind {
        case .apiToken:
            let url = IntegrationSecrets.apiTokenURL(in: supportDirectory)
            return settings.apiEnabled ? try? IntegrationSecrets.loadOrCreate(url, kind: .apiToken) : IntegrationSecrets.load(url)
        case .webhookSecret:
            let url = IntegrationSecrets.webhookSecretURL(in: supportDirectory)
            return settings.webhooksEnabled ? try? IntegrationSecrets.loadOrCreate(url, kind: .webhookSecret) : IntegrationSecrets.load(url)
        }
    }

    static func describe(_ error: Error, port: UInt16) -> String {
        if case .posix(let code)? = error as? NWError, code == .EADDRINUSE {
            return "Port \(port) is already used by another app."
        }
        if let code = (error as? POSIXError)?.code, code == .EADDRINUSE {
            return "Port \(port) is already used by another app."
        }
        return "Could not listen on port \(port): \(error.localizedDescription)"
    }

    /// Waits for queued webhooks; used by tests and on quit.
    public func waitForWebhooks() async {
        await dispatcher?.waitUntilIdle()
    }

    private func restartServer() {
        stop()
        guard settings.apiEnabled else { return }
        do {
            let token = try IntegrationSecrets.loadOrCreate(IntegrationSecrets.apiTokenURL(in: supportDirectory), kind: .apiToken)
            let api = LocalAPI(token: token, controller: controller, reader: reader, events: events)
            let server = LocalHTTPServer { request in await api.handle(request) }
            let port = try server.start(port: settings.apiPort)
            self.server = server
            serverPort = port
            status.api = .listening(port: port)
            Log.integrations.info("Local API listening on 127.0.0.1:\(port)")
        } catch {
            status.api = .failed(Self.describe(error, port: settings.apiPort))
            Log.integrations.error("Local API could not start: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func forward(_ event: IntegrationEvent) {
        guard settings.webhooksEnabled, let dispatcher else { return }
        for webhook in settings.webhooks {
            guard let url = WebhookPolicy.validatedURL(webhook.url) else {
                Log.integrations.error("Webhook skipped: its URL must use https (plain http only to this Mac)")
                continue
            }
            let reader = reader
            guard let body = WebhookPayload.body(for: event, webhook: webhook, transcript: {
                event.conversationID.flatMap { try? reader.transcript($0) }
            }) else { continue }
            dispatcher.enqueue(WebhookDelivery(url: url, body: body, eventID: event.id))
        }
    }
}
