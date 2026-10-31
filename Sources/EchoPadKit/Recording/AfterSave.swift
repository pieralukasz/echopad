import AppKit
import Foundation
import ScribeKit

/// Runs a destination's after-save actions.
@MainActor
enum AfterSave {
    /// Sorting runs first, so the other actions see the note at its new place.
    /// `onSorted` gets Claude's title and the files' new locations.
    static func run(_ actions: [AfterSaveAction], result: Exporter.Result, transcript: Transcript,
                    destination: Destination, conversation: Conversation,
                    onSorted: @escaping (String, [URL]) -> Void = { _, _ in }) async {
        var files = result.files
        for case .sortWithClaude(let rulesPath) in actions {
            if let sorted = await sort(files, rulesPath: rulesPath, transcript: transcript,
                                       destination: destination, conversation: conversation) {
                files = sorted.files
                onSorted(sorted.title, sorted.files)
            }
        }
        guard let main = files.first else { return }
        for action in actions {
            switch action {
            case .sortWithClaude:
                continue
            case .revealInFinder:
                NSWorkspace.shared.activateFileViewerSelecting([main])
            case .openFile:
                NSWorkspace.shared.open(main)
            case .openInObsidian:
                if let vault = destination.obsidianVault, let url = ObsidianVault.openURL(for: main, in: vault) {
                    NSWorkspace.shared.open(url)
                } else {
                    NSWorkspace.shared.open(main)
                }
            case .copyTranscript:
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(TranscriptRenderer.text(transcript), forType: .string)
            case .runShortcut(let name):
                guard !name.isEmpty else { continue }
                launch("/usr/bin/shortcuts", ["run", name, "--input-path", main.path])
            case .runScript(let path):
                let expanded = (path as NSString).expandingTildeInPath
                guard !expanded.isEmpty else { continue }
                launch(expanded, [main.path, result.audio?.path ?? ""])
            }
        }
    }

    /// Files the note with Claude. On any failure the note stays where it was saved.
    private static func sort(_ files: [URL], rulesPath: String, transcript: Transcript, destination: Destination,
                             conversation: Conversation) async -> (title: String, files: [URL])? {
        guard let apiKey = APIKeyStore.load() else {
            Log.sorting.error("\(ClaudeSorter.Failure.missingAPIKey.localizedDescription, privacy: .public)")
            return nil
        }
        let sorter = ClaudeSorter()
        let root = destination.obsidianVault ?? destination.folderURL
        let folders = sorter.folders(in: root, excluding: destination.folderURL)
        do {
            let decision = try await sorter.decide(
                transcript: TranscriptRenderer.text(transcript), recordedAt: conversation.date, app: conversation.app,
                folders: folders, rules: sorter.rules(at: rulesPath, root: root), apiKey: apiKey)
            let values = NameTemplate.Values(
                date: conversation.date, title: decision.title, app: conversation.app,
                duration: conversation.duration, speakerCount: transcript.speakers.count,
                destination: destination.name)
            let baseName = NameTemplate(destination.fileNameTemplate).fileName(values)
            let moved = try sorter.file(files, decision: decision, root: root, newBaseName: baseName)
            Log.sorting.info("Filed \(decision.title, privacy: .public) into \(decision.folder, privacy: .public)")
            return (decision.title, moved)
        } catch {
            Log.sorting.error("Sorting failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Starts a process without waiting for it; its output goes to EchoPad's log.
    private static func launch(_ executable: String, _ arguments: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        do {
            try process.run()
        } catch {
            print("After-save action failed to start \(executable): \(error.localizedDescription)")
        }
    }
}
