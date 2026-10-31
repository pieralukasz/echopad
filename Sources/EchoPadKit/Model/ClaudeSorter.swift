import Foundation

/// Files a saved transcript into the right folder of a vault: Claude reads the transcript,
/// the vault's folder list and the user's rules, and picks a folder, a title and a summary.
public struct ClaudeSorter {
    public struct Decision: Codable, Equatable, Sendable {
        /// A folder relative to the vault, or ``ClaudeSorter.STAY`` to leave the note where it is.
        public var folder: String
        public var title: String
        public var summary: String
        public var confident: Bool
    }

    public enum Failure: LocalizedError, Equatable {
        case missingAPIKey
        case http(Int, String)
        case unexpectedResponse(String)
        /// The answer had the right shape but broke a rule; one message per field.
        case invalidDecision([String])

        public var errorDescription: String? {
            switch self {
            case .missingAPIKey: return "No Anthropic API key saved (Destinations → Sort into folders)."
            case .http(let status, let body): return "Anthropic API returned \(status): \(body)"
            case .unexpectedResponse(let detail): return "Unexpected answer from Claude: \(detail)"
            case .invalidDecision(let issues): return "Claude's answer failed validation: \(issues.joined(separator: "; "))"
            }
        }
    }

    static let MAX_TITLE = 80
    static let MAX_SUMMARY = 600

    /// Checks every field of a decoded answer and returns a cleaned copy (trimmed, single-line),
    /// or throws with all problems at once.
    static func validate(_ raw: Decision, folders: [String]) throws -> Decision {
        func clean(_ value: String) -> String {
            value.components(separatedBy: .newlines).joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var decision = raw
        decision.title = clean(raw.title)
        decision.summary = clean(raw.summary)

        var issues: [String] = []
        if decision.folder != STAY && !folders.contains(decision.folder) {
            issues.append("folder: \"\(decision.folder)\" is not a folder of the vault")
        }
        if decision.title.isEmpty { issues.append("title: empty") }
        if decision.title.count > MAX_TITLE { issues.append("title: longer than \(MAX_TITLE) characters") }
        if decision.summary.isEmpty { issues.append("summary: empty") }
        if decision.summary.count > MAX_SUMMARY { issues.append("summary: longer than \(MAX_SUMMARY) characters") }
        guard issues.isEmpty else { throw Failure.invalidDecision(issues) }
        return decision
    }

    /// Folder value meaning "leave the note in the destination folder".
    public static let STAY = "(stay)"
    static let MODEL = "claude-haiku-5-5"
    static let API_VERSION = "2026-10-21"

    public var session = URLSession.shared
    public var fileManager = FileManager.default
    /// How hard Claude thinks: "low", "medium" or "high".
    public var effort = "medium"

    public init() {}

    // MARK: - Folders and rules

    /// Folders a note can go to: every non-hidden folder of `root` up to two levels deep,
    /// except `inbox` itself and anything inside it.
    public func folders(in root: URL, excluding inbox: URL) -> [String] {
        let inboxPath = inbox.standardizedFileURL.path
        var result: [String] = []
        func walk(_ url: URL, prefix: String, depth: Int) {
            guard depth > 0,
                  let children = try? fileManager.contentsOfDirectory(
                    at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
            else { return }
            for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                guard (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                      child.standardizedFileURL.path != inboxPath else { continue }
                let relative = prefix.isEmpty ? child.lastPathComponent : "\(prefix)/\(child.lastPathComponent)"
                result.append(relative)
                walk(child, prefix: relative, depth: depth - 1)
            }
        }
        walk(root, prefix: "", depth: 2)
        return result
    }

    /// Reads the rules file: relative to `root`, or an absolute / `~` path. Missing file → no rules.
    public func rules(at path: String, root: URL) -> String {
        guard !path.isEmpty else { return "" }
        let expanded = (path as NSString).expandingTildeInPath
        let url = expanded.hasPrefix("/") ? URL(fileURLWithPath: expanded) : root.appendingPathComponent(path)
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    // MARK: - Claude

    public func decide(transcript: String, recordedAt date: Date, app: String?, folders: [String],
                       rules: String, apiKey: String) async throws -> Decision {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 180
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(Self.API_VERSION, forHTTPHeaderField: "anthropic-version")
        request.httpBody = try JSONSerialization.data(withJSONObject: Self.requestBody(
            transcript: transcript, recordedAt: date, app: app, folders: folders, rules: rules, effort: effort))

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            throw Failure.http(status, String(decoding: data.prefix(500), as: UTF8.self))
        }
        return try Self.parse(data, folders: folders)
    }

    static func requestBody(transcript: String, recordedAt date: Date, app: String?, folders: [String],
                            rules: String, effort: String = "medium") -> [String: Any] {
        let schema: [String: Any] = [
            "type": "object",
            "properties": [
                "folder": ["type": "string", "enum": [STAY] + folders],
                "title": ["type": "string", "description": "At most \(MAX_TITLE) characters, one line"],
                "summary": ["type": "string", "description": "1-2 sentences, at most \(MAX_SUMMARY) characters"],
                "confident": ["type": "boolean"],
            ],
            "required": ["folder", "title", "summary", "confident"],
            "additionalProperties": false,
        ]
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = .current
        let weekday = DateFormatter()
        weekday.locale = Locale(identifier: "en_US_POSIX")
        weekday.dateFormat = "EEEE"
        var context = "Recorded: \(weekday.string(from: date)) \(formatter.string(from: date)) (\(TimeZone.current.identifier))"
        if let app, !app.isEmpty { context += "\nCall app: \(app)" }

        return [
            "model": MODEL,
            "max_tokens": 8000,
            "output_config": ["effort": effort, "format": ["type": "json_schema", "schema": schema]],
            "system": systemPrompt(folders: folders, rules: rules),
            "messages": [["role": "user", "content": "\(context)\n\n<transcript>\n\(transcript)\n</transcript>"]],
        ]
    }

    static func systemPrompt(folders: [String], rules: String) -> String {
        var prompt = """
        You file meeting transcripts into folders of the user's notes vault.

        Pick the one folder the conversation belongs in. Prefer the most specific subfolder that fits. \
        Use "\(STAY)" for recordings with no real conversation (a microphone test, a greeting, noise) \
        or when no folder fits.

        Write a short title (at most 8 words) and a 1-2 sentence summary, both in the language of the \
        conversation. Set confident to false when the folder is a guess, so the user checks it.

        Folders:
        \(folders.map { "- \($0)" }.joined(separator: "\n"))
        """
        if !rules.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            prompt += "\n\nThe user's rules for choosing folders:\n<rules>\n\(rules)\n</rules>"
        }
        return prompt
    }

    static func parse(_ data: Data, folders: [String]) throws -> Decision {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure.unexpectedResponse("not JSON")
        }
        let stopReason = json["stop_reason"] as? String
        guard stopReason == "end_turn" else {
            throw Failure.unexpectedResponse("stop_reason \(stopReason ?? "missing")")
        }
        let blocks = json["content"] as? [[String: Any]] ?? []
        guard let text = blocks.first(where: { $0["type"] as? String == "text" })?["text"] as? String else {
            throw Failure.unexpectedResponse("no text block")
        }
        let raw: Decision
        do {
            raw = try JSONDecoder().decode(Decision.self, from: Data(text.utf8))
        } catch {
            throw Failure.unexpectedResponse("answer does not match the schema (\(error))")
        }
        return try validate(raw, folders: folders)
    }

    // MARK: - Filing

    /// Moves `files` into `decision.folder` under `root` (``STAY`` leaves them put), renames them
    /// with `newBaseName`, and adds the summary to the Markdown front matter. Unsure decisions
    /// are still filed, marked `review: true`.
    /// Returns the files' new locations.
    public func file(_ files: [URL], decision: Decision, root: URL, newBaseName: String) throws -> [URL] {
        let stays = decision.folder == Self.STAY
        var moved: [URL] = []
        for file in files {
            let folder = stays ? file.deletingLastPathComponent()
                               : root.appendingPathComponent(decision.folder, isDirectory: true)
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
            let ext = file.pathExtension
            var target = folder.appendingPathComponent("\(newBaseName).\(ext)")
            var counter = 2
            while target.standardizedFileURL != file.standardizedFileURL, fileManager.fileExists(atPath: target.path) {
                target = folder.appendingPathComponent("\(newBaseName) \(counter).\(ext)")
                counter += 1
            }
            if target.standardizedFileURL != file.standardizedFileURL {
                try fileManager.moveItem(at: file, to: target)
            }
            if ext == "md" { try addFrontMatter(decision, to: target) }
            moved.append(target)
        }
        return moved
    }

    func addFrontMatter(_ decision: Decision, to note: URL) throws {
        var lines = [
            "summary: \(Self.yamlString(decision.summary))",
            "folder: \(Self.yamlString(decision.folder))",
        ]
        if decision.folder == Self.STAY || !decision.confident { lines.append("review: true") }
        let added = lines.joined(separator: "\n")

        let text = try String(contentsOf: note, encoding: .utf8)
        let updated: String
        if text.hasPrefix("---\n") {
            updated = "---\n\(added)\n" + text.dropFirst(4)
        } else {
            updated = "---\n\(added)\n---\n\n" + text
        }
        try updated.write(to: note, atomically: true, encoding: .utf8)
    }

    /// A double-quoted YAML scalar (JSON string syntax is valid YAML).
    static func yamlString(_ value: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [value], options: [.withoutEscapingSlashes])) ?? Data()
        let array = String(decoding: data, as: UTF8.self)
        return String(array.dropFirst().dropLast())
    }
}
