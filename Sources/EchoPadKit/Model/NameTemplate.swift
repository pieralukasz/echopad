import Foundation

/// Fills `{token}` placeholders in folder and file name templates.
///
/// Tokens: `{date}` 2026-09-25 · `{time}` 14.05 · `{title}` · `{year}` · `{month}` · `{day}` ·
/// `{hour}` · `{minute}` · `{weekday}` Thursday · `{app}` Zoom · `{duration}` 47m ·
/// `{speakers}` 3 · `{destination}`.
public struct NameTemplate: Sendable {
    public struct Values: Sendable {
        public var date: Date
        public var title: String
        public var app: String?
        public var duration: TimeInterval
        public var speakerCount: Int
        public var destination: String

        public init(date: Date, title: String, app: String? = nil, duration: TimeInterval = 0,
                    speakerCount: Int = 0, destination: String = "") {
            self.date = date
            self.title = title
            self.app = app
            self.duration = duration
            self.speakerCount = speakerCount
            self.destination = destination
        }
    }

    public static let tokens = ["date", "time", "title", "year", "month", "day", "hour", "minute",
                                "weekday", "app", "duration", "speakers", "destination"]

    public let template: String

    public init(_ template: String) {
        self.template = template
    }

    /// The filled-in name, safe to use as one path component.
    public func fileName(_ values: Values) -> String {
        let name = Self.sanitize(fill(values, sanitizingValues: true))
        return name.isEmpty ? Self.sanitize(fillFallback(values)) : name
    }

    /// The filled-in relative folder path; `/` separates folders.
    public func folderPath(_ values: Values) -> String {
        fill(values, sanitizingValues: true)
            .split(separator: "/")
            .map { Self.sanitize(String($0)) }
            .filter { !$0.isEmpty && $0 != "." && $0 != ".." }
            .joined(separator: "/")
    }

    private func fillFallback(_ values: Values) -> String {
        NameTemplate(Destination.DEFAULT_FILE_NAME).fill(values, sanitizingValues: true)
    }

    func fill(_ values: Values, sanitizingValues: Bool) -> String {
        var result = ""
        var index = template.startIndex
        while index < template.endIndex {
            if template[index] == "{", let close = template[index...].firstIndex(of: "}") {
                let key = String(template[template.index(after: index)..<close]).lowercased()
                if let value = value(for: key, values) {
                    // Values must not create folders of their own.
                    result += sanitizingValues ? value.replacingOccurrences(of: "/", with: "-") : value
                    index = template.index(after: close)
                    continue
                }
            }
            result.append(template[index])
            index = template.index(after: index)
        }
        return result
    }

    private func value(for key: String, _ values: Values) -> String? {
        let calendar = Calendar.current
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: values.date)
        func two(_ number: Int?) -> String { String(format: "%02d", number ?? 0) }
        switch key {
        case "date": return "\(parts.year ?? 0)-\(two(parts.month))-\(two(parts.day))"
        case "time": return "\(two(parts.hour)).\(two(parts.minute))"
        case "title": return values.title
        case "year": return String(parts.year ?? 0)
        case "month": return two(parts.month)
        case "day": return two(parts.day)
        case "hour": return two(parts.hour)
        case "minute": return two(parts.minute)
        case "weekday":
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "EEEE"
            return formatter.string(from: values.date)
        case "app": return values.app ?? ""
        case "duration":
            let minutes = Int((values.duration / 60).rounded())
            return minutes >= 60 ? "\(minutes / 60)h\(two(minutes % 60))m" : "\(max(minutes, 1))m"
        case "speakers": return String(values.speakerCount)
        case "destination": return values.destination
        default: return nil
        }
    }

    /// Removes characters that are unsafe in file names on macOS and in Obsidian links.
    static func sanitize(_ name: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/:\\?%*|\"<>[]#^").union(.controlCharacters).union(.newlines)
        let cleaned = name.unicodeScalars.map { forbidden.contains($0) ? " " : String($0) }.joined()
        let collapsed = cleaned.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        var trimmed = collapsed.trimmingCharacters(in: CharacterSet(charactersIn: " .-"))
        if trimmed.count > 150 { trimmed = String(trimmed.prefix(150)).trimmingCharacters(in: .whitespaces) }
        return trimmed
    }
}
