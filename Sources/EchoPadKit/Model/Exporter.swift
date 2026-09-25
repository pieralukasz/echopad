import Foundation
import ScribeKit
import SystemAudioKit

/// Writes a finished conversation to a ``Destination``: transcript files in every chosen
/// format, and the audio when the destination keeps it. Pure file work, no UI, so it can be tested.
public struct Exporter {
    public struct Result: Sendable, Equatable {
        /// Transcript files, in the order of the destination's formats.
        public var files: [URL]
        public var audio: URL?
    }

    public enum Failure: LocalizedError {
        case folderNotWritable(String, underlying: String)

        public var errorDescription: String? {
            switch self {
            case .folderNotWritable(let path, let underlying):
                return "Could not write to \(path): \(underlying)"
            }
        }
    }

    public var fileManager = FileManager.default

    public init() {}

    public func export(_ conversation: Conversation, transcript: Transcript, tracks: [URL],
                       to destination: Destination) throws -> Result {
        let values = NameTemplate.Values(
            date: conversation.date, title: conversation.title, app: conversation.app,
            duration: conversation.duration, speakerCount: transcript.speakers.count,
            destination: destination.name)

        var folder = destination.folderURL
        let subfolder = NameTemplate(destination.subfolderTemplate).folderPath(values)
        if !subfolder.isEmpty { folder.appendPathComponent(subfolder, isDirectory: true) }
        try createFolder(folder)

        let baseName = NameTemplate(destination.fileNameTemplate).fileName(values)
        let formats = destination.formats.isEmpty ? [.markdown] : destination.formats

        // Pick one base name that is free for every file this export writes.
        let audioFolder = audioFolder(for: destination, transcriptFolder: folder)
        let audioExtension = destination.audio.format.rawValue
        let name = uniqueName(baseName) { candidate in
            formats.contains { fileManager.fileExists(atPath: folder.appendingPathComponent("\(candidate).\($0.fileExtension)").path) }
                || (audioFolder.map { fileManager.fileExists(atPath: $0.appendingPathComponent("\(candidate).\(audioExtension)").path) } ?? false)
        }

        var audioURL: URL?
        if let audioFolder, !tracks.isEmpty {
            try createFolder(audioFolder)
            let url = audioFolder.appendingPathComponent("\(name).\(audioExtension)")
            try AudioMixer.mix(tracks, to: url)
            audioURL = url
        }

        var files: [URL] = []
        for format in formats {
            let url = folder.appendingPathComponent("\(name).\(format.fileExtension)")
            let contents = try TranscriptRenderer.render(
                transcript, as: format,
                markdown: markdownOptions(conversation, transcript: transcript, destination: destination,
                                          note: url, audio: audioURL))
            do {
                try contents.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                throw Failure.folderNotWritable(folder.path, underlying: error.localizedDescription)
            }
            files.append(url)
        }
        return Result(files: files, audio: audioURL)
    }

    func markdownOptions(_ conversation: Conversation, transcript: Transcript, destination: Destination,
                         note: URL, audio: URL?) -> TranscriptRenderer.MarkdownOptions {
        var metadata: [(String, String)] = []
        if destination.includeFrontMatter {
            let dateFormatter = DateFormatter()
            dateFormatter.locale = Locale(identifier: "en_US_POSIX")
            dateFormatter.dateFormat = "yyyy-MM-dd"
            let timeFormatter = DateFormatter()
            timeFormatter.locale = Locale(identifier: "en_US_POSIX")
            timeFormatter.dateFormat = "HH:mm"
            metadata = [
                ("title", conversation.title),
                ("date", dateFormatter.string(from: conversation.date)),
                ("time", timeFormatter.string(from: conversation.date)),
                ("duration", TranscriptRenderer.duration(conversation.duration)),
            ]
            if let app = conversation.app { metadata.append(("app", app)) }
            if !transcript.speakers.isEmpty {
                metadata.append(("speakers", transcript.speakers.map(\.name).joined(separator: ", ")))
            }
            if let language = transcript.language { metadata.append(("language", language)) }
            if let audio, destination.audio.linkFromNote {
                metadata.append(("audio", audioReference(audio, from: note, vault: destination.obsidianVault)))
            }
            metadata.append(("source", "EchoPad"))
            for line in destination.extraFrontMatter.split(whereSeparator: \.isNewline) {
                let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                guard parts.count == 2, !parts[0].isEmpty else { continue }
                metadata.append((parts[0], parts[1]))
            }
        }

        var preamble: String?
        if let audio, destination.audio.linkFromNote {
            if let vault = destination.obsidianVault, let path = audio.path.relativePath(from: vault.path) {
                preamble = "![[\(path)]]"
            } else {
                let relative = relativeLink(from: note.deletingLastPathComponent(), to: audio)
                preamble = "[Recording](\(relative.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? relative))"
            }
        }
        return .init(title: conversation.title, metadata: metadata,
                     includeTimestamps: destination.includeTimestamps, preamble: preamble)
    }

    func audioReference(_ audio: URL, from note: URL, vault: URL?) -> String {
        if let vault, let path = audio.path.relativePath(from: vault.path) { return "[[\(path)]]" }
        return relativeLink(from: note.deletingLastPathComponent(), to: audio)
    }

    func audioFolder(for destination: Destination, transcriptFolder: URL) -> URL? {
        switch destination.audio.location {
        case .none: return nil
        case .withTranscript: return transcriptFolder
        case .folder:
            let raw = (destination.audio.folder as NSString).expandingTildeInPath
            if raw.hasPrefix("/") { return URL(fileURLWithPath: raw, isDirectory: true) }
            // Relative folders hang off the destination root, so notes in dated subfolders share one attachments folder.
            let base = destination.obsidianVault ?? destination.folderURL
            return raw.isEmpty ? transcriptFolder : base.appendingPathComponent(raw, isDirectory: true)
        }
    }

    func uniqueName(_ base: String, taken: (String) -> Bool) -> String {
        guard taken(base) else { return base }
        var index = 2
        while taken("\(base) (\(index))") { index += 1 }
        return "\(base) (\(index))"
    }

    func relativeLink(from folder: URL, to file: URL) -> String {
        let from = folder.standardizedFileURL.pathComponents
        let to = file.standardizedFileURL.pathComponents
        var common = 0
        while common < min(from.count, to.count), from[common] == to[common] { common += 1 }
        let ups = Array(repeating: "..", count: from.count - common)
        return (ups + to[common...]).joined(separator: "/")
    }

    private func createFolder(_ url: URL) throws {
        do {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            throw Failure.folderNotWritable(url.path, underlying: error.localizedDescription)
        }
    }
}
