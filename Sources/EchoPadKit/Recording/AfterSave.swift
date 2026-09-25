import AppKit
import Foundation
import ScribeKit

/// Runs a destination's after-save actions.
@MainActor
enum AfterSave {
    static func run(_ actions: [AfterSaveAction], result: Exporter.Result, transcript: Transcript,
                    destination: Destination) {
        guard let main = result.files.first else { return }
        for action in actions {
            switch action {
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
