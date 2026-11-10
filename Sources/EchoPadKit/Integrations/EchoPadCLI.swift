import Foundation
import ScribeKit

/// `echopad <command>`: reads the library from disk and talks to the running app over the
/// local API. Never opens a window or loads the speech models.
public enum EchoPadCLI {
    static let USAGE = """
    Usage: echopad [command] [options]

      (no command)                          open the EchoPad app
      list [--limit N] [--search TEXT]      conversations, newest first
      show <id>                             metadata of one conversation
      transcript <id> [--format txt|json]   saved transcript (default txt)
      status                                what the app is doing (local API)
      start [--title TITLE]                 start recording (local API)
      stop                                  stop recording; the app transcribes it (local API)
      events [--after N]                    recent events, oldest first (local API)
      live [--since REVISION]               live transcript of the current recording (local API)
      live-replay <id> [--paced] [--latency 560|1120|2080] [--lang pl]
                                            replay a saved recording through the live path
                                            (loads the live models; reads the library only)

    Options: --data-dir PATH (else ECHOPAD_DATA_DIR, else ~/Library/Application Support/EchoPad), --json
    The local API is off by default; see the README for turning it on.
    """

    struct Failure: Error {
        let message: String
        init(_ message: String) { self.message = message }
    }

    /// True when the process was started with a command rather than as the app. Launch
    /// arguments macOS or Xcode may add (`-psn_…`, `-NS…`, `-Apple…`) keep the app.
    public static func isCLIInvocation(_ arguments: [String]) -> Bool {
        guard let first = arguments.first else { return false }
        return !["-psn_", "-NS", "-Apple"].contains { first.hasPrefix($0) }
    }

    /// Runs one command; returns the exit code (0 success, 1 failure).
    public static func run(_ arguments: [String], output: (String) -> Void = { print($0) },
                           errors: (String) -> Void = { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }) -> Int32 {
        do {
            try execute(arguments, output: output)
            return 0
        } catch let failure as Failure {
            errors("echopad: \(failure.message)")
        } catch {
            errors("echopad: \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)")
        }
        return 1
    }

    private static func execute(_ arguments: [String], output: (String) -> Void) throws {
        var positional: [String] = []
        var options: [String: String] = [:]
        var json = false
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--json": json = true
            case "-h", "--help", "help":
                output(USAGE)
                return
            case "--paced": options["--paced"] = "1"
            case "--data-dir", "--limit", "--search", "--format", "--title", "--after", "--since", "--latency", "--lang":
                guard index + 1 < arguments.count else { throw Failure("\(argument) needs a value") }
                options[argument] = arguments[index + 1]
                index += 1
            default:
                guard !argument.hasPrefix("--") else { throw Failure("unknown option \(argument)\n\n\(USAGE)") }
                positional.append(argument)
            }
            index += 1
        }
        let support = options["--data-dir"].map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true) }
            ?? AppDirectories.applicationSupport
        let reader = LibraryReader(directory: support.appendingPathComponent("Library", isDirectory: true))
        let command = positional.first ?? ""

        switch command {
        case "list":
            guard let limit = Int(options["--limit"] ?? "50"), limit > 0 else { throw Failure("--limit must be a positive number") }
            var conversations = try reader.conversations()
            if let search = options["--search"] {
                conversations = conversations.filter { $0.title.localizedCaseInsensitiveContains(search) }
            }
            conversations = Array(conversations.prefix(limit))
            if json {
                struct Body: Encodable { let dataDirectory: String; let conversations: [Conversation] }
                output(try encode(Body(dataDirectory: support.path, conversations: conversations)))
            } else {
                let dates = ISO8601DateFormatter()
                for c in conversations { output("\(c.id.uuidString)  \(dates.string(from: c.date))  \(statusName(c.status))  \(c.title)") }
            }
        case "show":
            let id = try conversationID(positional)
            guard let conversation = try reader.conversation(id) else { throw Failure("no conversation \(id.uuidString)") }
            if json {
                output(try encode(conversation))
            } else {
                output("\(conversation.title)\n\(ISO8601DateFormatter().string(from: conversation.date))  \(Int(conversation.duration)) s  \(statusName(conversation.status))  \(conversation.wordCount) words")
                for file in conversation.exportedFiles { output(file) }
            }
        case "transcript":
            let id = try conversationID(positional)
            guard let transcript = try reader.transcript(id) else { throw Failure("no transcript for \(id.uuidString)") }
            let format = options["--format"] ?? (json ? "json" : "txt")
            switch format {
            case "txt" where !json: output(TranscriptRenderer.text(transcript))
            case "json": output(try encode(transcript))
            default: throw Failure("--format must be txt or json (--json implies json)")
            }
        case "status":
            output(try api("GET", "/v1/status", support: support))
        case "start":
            let body = try IntegrationJSON.encoder().encode(["title": options["--title"]])
            output(try api("POST", "/v1/recording/start", body: body, support: support))
        case "stop":
            output(try api("POST", "/v1/recording/stop", support: support))
        case "events":
            guard let after = Int(options["--after"] ?? "0") else { throw Failure("--after must be a number") }
            output(try api("GET", "/v1/events?after=\(after)", support: support))
        case "live":
            guard let since = Int(options["--since"] ?? "0") else { throw Failure("--since must be a number") }
            output(try api("GET", "/v1/recording/live?since=\(since)", support: support))
        case "live-replay":
            let id = try conversationID(positional)
            let folder = reader.directory.appendingPathComponent(id.uuidString)
            let tracks = ["microphone.wav", "system.wav"].map { folder.appendingPathComponent($0) }
                .map { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
            guard tracks.contains(where: { $0 != nil }) else { throw Failure("no audio for \(id.uuidString)") }
            var settings = LiveTranscriptionSettings()
            settings.enabled = true
            if let latency = options["--latency"] {
                guard let ms = Int(latency), LiveLatency(rawValue: ms) != nil else { throw Failure("--latency must be 560, 1120 or 2080") }
                settings.latencyMs = ms
            }
            if let language = options["--lang"] { settings.language = language == "auto" ? nil : language }
            let replaySettings = settings, paced = options["--paced"] != nil
            let snapshot = try Self.blocking {
                let session = LiveSession(settings: replaySettings)
                try await session.replay(microphone: tracks[0], system: tracks[1], paced: paced)
                return await session.snapshot()
            }
            if let error = snapshot.error { throw Failure(error) }
            output(json ? try encode(snapshot) : TranscriptRenderer.text(snapshot.transcript))
        default:
            throw Failure((command.isEmpty ? "missing command" : "unknown command \(command)") + "\n\n\(USAGE)")
        }
    }

    /// Runs async work from the synchronous CLI. Nothing here hops to the main actor.
    private static func blocking<T: Sendable>(_ work: @escaping @Sendable () async throws -> T) throws -> T {
        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result: Result<T, Error>?
        Task.detached {
            do { result = .success(try await work()) } catch { result = .failure(error) }
            semaphore.signal()
        }
        semaphore.wait()
        return try result!.get()
    }

    private static func conversationID(_ positional: [String]) throws -> UUID {
        guard positional.count > 1, let id = UUID(uuidString: positional[1]) else { throw Failure("give a conversation id (a UUID from list)") }
        return id
    }

    private static func statusName(_ status: Conversation.Status) -> String {
        switch status {
        case .recorded: return "recorded"
        case .transcribing: return "transcribing"
        case .done: return "done"
        case .failed: return "failed"
        }
    }

    private static func encode<T: Encodable>(_ value: T) throws -> String {
        let encoder = IntegrationJSON.encoder()
        encoder.outputFormatting.insert(.prettyPrinted)
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    /// Calls the running app. The token is read from its file, never taken from the command line.
    private static func api(_ method: String, _ path: String, body: Data? = nil, support: URL) throws -> String {
        let settingsURL = support.appendingPathComponent("settings.json")
        let settings = IntegrationSettings.load(fromSettingsFile: settingsURL)
        guard settings.apiEnabled else {
            throw Failure("the local API is off; set \"integrations\": {\"apiEnabled\": true} in \(settingsURL.path) and reopen EchoPad")
        }
        let tokenURL = IntegrationSecrets.apiTokenURL(in: support)
        guard let token = IntegrationSecrets.load(tokenURL) else {
            throw Failure("no API token at \(tokenURL.path); EchoPad writes it when it starts with the API on")
        }
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(settings.apiPort)\(path)")!, timeoutInterval: 15)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        final class Box: @unchecked Sendable { var result: Result<(Int, Data), Failure> = .failure(Failure("no response")) }
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let port = settings.apiPort
        session.dataTask(with: request) { data, response, error in
            if let error {
                let code = (error as? URLError)?.code.rawValue ?? -1
                box.result = .failure(Failure("EchoPad is not reachable on 127.0.0.1:\(port) (error \(code)); is it running with the API on?"))
            } else {
                box.result = .success(((response as? HTTPURLResponse)?.statusCode ?? 0, data ?? Data()))
            }
            done.signal()
        }.resume()
        done.wait()
        let (status, data) = try box.result.get()
        let text = String(decoding: data, as: UTF8.self)
        guard (200..<300).contains(status) else { throw Failure("HTTP \(status): \(text)") }
        return text
    }
}
