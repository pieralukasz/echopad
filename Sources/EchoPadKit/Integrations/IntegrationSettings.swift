import Foundation
import Security

/// The local API and outgoing webhooks. Both are off until switched on in settings.json.
public struct IntegrationSettings: Codable, Equatable, Sendable {
    public static let DEFAULT_PORT: UInt16 = 47_821

    /// Serves the authenticated HTTP API on 127.0.0.1 only.
    public var apiEnabled = false
    public var apiPort: UInt16 = DEFAULT_PORT
    public var webhooksEnabled = false
    public var webhooks: [Webhook] = []

    public struct Webhook: Codable, Equatable, Sendable {
        public var url: String
        /// Event types to send (for example `conversation.saved`); empty sends every event.
        public var events: [String] = []
        /// Adds the transcript to `conversation.saved`. Off unless set.
        public var includeTranscript = false

        public init(url: String, events: [String] = [], includeTranscript: Bool = false) {
            self.url = url
            self.events = events
            self.includeTranscript = includeTranscript
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            url = try container.decode(String.self, forKey: .url)
            events = (try? container.decode([String].self, forKey: .events)) ?? []
            includeTranscript = (try? container.decode(Bool.self, forKey: .includeTranscript)) ?? false
        }
    }

    public init() {}

    // Missing keys keep their (off) defaults.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        apiEnabled = (try? container.decode(Bool.self, forKey: .apiEnabled)) ?? false
        apiPort = (try? container.decode(UInt16.self, forKey: .apiPort)) ?? Self.DEFAULT_PORT
        webhooksEnabled = (try? container.decode(Bool.self, forKey: .webhooksEnabled)) ?? false
        webhooks = (try? container.decode([Webhook].self, forKey: .webhooks)) ?? []
    }

    /// Reads only the `integrations` key of a settings file, without touching anything else.
    public static func load(fromSettingsFile url: URL) -> IntegrationSettings {
        struct File: Decodable { var integrations: IntegrationSettings? }
        guard let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(File.self, from: data) else { return IntegrationSettings() }
        return file.integrations ?? IntegrationSettings()
    }
}

/// Secrets of the integrations, each in its own file readable only by the user (mode 0600).
///
/// A file rather than the keychain: the app and the CLI are separate, ad-hoc signed builds, and a
/// keychain item made by one build prompts in the other, while a 0600 file gives the same
/// protection against other users.
public enum IntegrationSecrets {
    public enum Kind {
        /// Bearer token for the local API, hex.
        case apiToken
        /// Webhook signing secret in the Standard Webhooks form (`whsec_` + base64).
        case webhookSecret
    }

    public static func apiTokenURL(in directory: URL = AppDirectories.applicationSupport) -> URL {
        directory.appendingPathComponent("api-token")
    }

    public static func webhookSecretURL(in directory: URL = AppDirectories.applicationSupport) -> URL {
        directory.appendingPathComponent("webhook-secret")
    }

    public static func load(_ url: URL) -> String? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Returns the secret in `url`, creating it with 32 random bytes when the file is missing.
    public static func loadOrCreate(_ url: URL, kind: Kind) throws -> String {
        if let existing = load(url) { return existing }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw POSIXError(.EIO)
        }
        let secret: String
        switch kind {
        case .apiToken: secret = bytes.map { String(format: "%02x", $0) }.joined()
        case .webhookSecret: secret = "whsec_" + Data(bytes).base64EncodedString()
        }
        // O_EXCL: never overwrite a secret another process wrote in the meantime.
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard descriptor >= 0 else {
            if let existing = load(url) { return existing }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { close(descriptor) }
        let data = Array((secret + "\n").utf8)
        guard write(descriptor, data, data.count) == data.count else { throw POSIXError(.EIO) }
        return secret
    }

    /// Key bytes of a webhook secret: the base64 part of `whsec_…`, or the raw text otherwise.
    static func webhookKey(_ secret: String) -> Data {
        if secret.hasPrefix("whsec_"), let data = Data(base64Encoded: String(secret.dropFirst(6))) { return data }
        return Data(secret.utf8)
    }
}
