import AppKit
import ScribeKit
import SwiftUI

/// One speaker's run of words in the live transcript panel.
struct LiveTranscriptLine: Identifiable, Equatable {
    struct Run: Equatable {
        var text: String
        /// Draft words the model may still revise.
        var isDraft: Bool
    }

    /// The first word's ID: stays the same while the line's words are revised.
    let id: String
    let speaker: String
    let isLocal: Bool
    let start: TimeInterval
    var runs: [Run]

    var text: String { runs.map(\.text).joined(separator: " ") }

    /// Same speaker as the line above it, so the panel draws it without the name and time.
    var continuesSpeaker = false

    /// Builds the panel's lines from the current snapshot. Revised words replace their old
    /// text (the snapshot keeps one entry per word ID), so nothing is appended twice. Only the
    /// last `limit` lines are returned; the engine keeps the whole transcript.
    ///
    /// The live model sends punctuation as separate words: they stick to the speaker's line
    /// without a space and never start a line. When two people talk over each other their
    /// words interleave in time; a word goes back to its speaker's line while only short
    /// interjections sit after it, so overlapping speech does not shatter into one-word lines.
    static func lines(from snapshot: LiveSnapshot, limit: Int = LiveTranscriptView.MAX_LINES)
        -> (lines: [LiveTranscriptLine], hidden: Int) {
        struct Open { var key: String; var end: TimeInterval; var words: Int; var endsSentence: Bool }
        let names = Dictionary(snapshot.speakers.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let words = snapshot.words.filter { !$0.isBleed }.sorted { ($0.start, $0.id) < ($1.start, $1.id) }
        var lines: [LiveTranscriptLine] = []
        var open: [Open] = []
        for word in words {
            let key = word.speakerID ?? "unassigned-\(word.track.rawValue)"
            let draft = word.textState == .pending
            let endsSentence = word.text.last.map { ".?!".contains($0) } ?? false
            let own = open.indices.suffix(OPEN_LINES).last { open[$0].key == key }

            if isPunctuation(word.text) {
                guard let target = own ?? lines.indices.last else { continue }
                if lines[target].runs.last?.text.hasSuffix(word.text) == false {
                    lines[target].runs[lines[target].runs.count - 1].text += word.text
                }
                // Only the newest line's end moves: a mark must not bridge a pause over an interjection.
                if target == lines.count - 1 { open[target].end = max(open[target].end, word.end) }
                open[target].endsSentence = endsSentence
                continue
            }

            if let index = own {
                let line = open[index]
                // A monologue still breaks into lines, so the line limit bounds what is drawn.
                let full = line.words >= MAX_LINE_WORDS || (line.endsSentence && line.words >= SENTENCE_SPLIT_WORDS)
                let gap = word.start - line.end
                let isLast = index == lines.count - 1
                let onlyInterjectionsAfter = open[(index + 1)...].allSatisfy { $0.words <= INTERJECTION_WORDS }
                if !full, isLast ? gap <= PAUSE_SPLIT : (onlyInterjectionsAfter && gap <= OVERLAP_JOIN) {
                    if lines[index].runs.last?.isDraft == draft {
                        lines[index].runs[lines[index].runs.count - 1].text += " " + word.text
                    } else {
                        lines[index].runs.append(Run(text: word.text, isDraft: draft))
                    }
                    open[index].words += 1
                    open[index].end = max(line.end, word.end)
                    open[index].endsSentence = endsSentence
                    continue
                }
            }

            let speaker = word.speakerID.flatMap { names[$0] }
            let label = speaker?.name ?? (word.track == .microphone ? "Me" : "Speaker…")
            lines.append(LiveTranscriptLine(id: word.id, speaker: label,
                                            isLocal: speaker?.isLocal ?? (word.track == .microphone),
                                            start: word.start, runs: [Run(text: word.text, isDraft: draft)]))
            open.append(Open(key: key, end: word.end, words: 1, endsSentence: endsSentence))
        }
        let hidden = max(0, lines.count - limit)
        var shown = Array(lines.suffix(limit))
        for index in shown.indices.dropFirst() {
            shown[index].continuesSpeaker = shown[index - 1].speaker == shown[index].speaker
                && shown[index - 1].isLocal == shown[index].isLocal
        }
        return (shown, hidden)
    }

    /// A word with no letters or digits: ",", ".", "?" and the like.
    static func isPunctuation(_ text: String) -> Bool {
        !text.isEmpty && !text.contains { $0.isLetter || $0.isNumber }
    }

    /// A pause this long starts a new line even for the same speaker.
    static let PAUSE_SPLIT: TimeInterval = 2
    /// A sentence end starts a new line once the line has this many words.
    static let SENTENCE_SPLIT_WORDS = 25
    static let MAX_LINE_WORDS = 80
    /// How many of the newest lines a word may go back to (its speaker's line plus one other).
    static let OPEN_LINES = 2
    /// A line this short after a speaker's line is an interjection, not a new turn.
    static let INTERJECTION_WORDS = 3
    /// Going back over an interjection only for a word this close to the speaker's last one.
    static let OVERLAP_JOIN: TimeInterval = 1
}

/// Keeps the panel at the newest line only while the reader is there. Scrolling up stops
/// following; scrolling back to the end or "Resume Following" starts it again.
struct ScrollFollowing: Equatable {
    /// Points from the end that still count as "at the end".
    static let THRESHOLD: CGFloat = 24

    private(set) var isFollowing = true
    private var lastContentHeight: CGFloat?

    /// Called on every scroll geometry change. A move away from the end while the content kept
    /// its height was the reader scrolling; a taller content is new words, not the reader.
    mutating func scrolled(distanceFromBottom: CGFloat, contentHeight: CGFloat) {
        defer { lastContentHeight = contentHeight }
        if distanceFromBottom <= Self.THRESHOLD {
            isFollowing = true
        } else if contentHeight == lastContentHeight {
            isFollowing = false
        }
    }

    mutating func resume() {
        isFollowing = true
    }
}

/// The live transcript of the recording in progress, read from the same live session as the
/// local API. Closing it changes nothing about the recording.
struct LiveTranscriptView: View {
    /// Lines drawn at once; older ones stay in the live session and the API.
    static let MAX_LINES = 300

    @Environment(AppState.self) private var appState
    @Environment(\.appActions) private var actions
    @State private var follow = ScrollFollowing()
    @State private var position = ScrollPosition(edge: .bottom)

    var body: some View {
        let built = appState.liveTranscript.map { LiveTranscriptLine.lines(from: $0) } ?? (lines: [], hidden: 0)
        VStack(spacing: 0) {
            header
            Divider()
            if built.lines.isEmpty {
                placeholder.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                transcript(built.lines, hidden: built.hidden)
            }
            if let footer { Divider(); footerView(footer) }
        }
        .frame(minWidth: 320, minHeight: 240)
    }

    private var header: some View {
        HStack(spacing: 8) {
            if let live = appState.live {
                LiveIndicator(status: live, size: .small)
                Text(live.title.replacingOccurrences(of: "Live transcript: ", with: "").capitalizedFirst)
                    .font(.callout.weight(.medium))
            } else {
                Image(systemName: "captions.bubble").foregroundStyle(.secondary)
                Text(appState.phase.isRecording ? "Off for this recording" : "No recording").font(.callout.weight(.medium))
            }
            Spacer()
            Text("Grey words are a draft")
                .font(.caption)
                .foregroundStyle(.secondary)
                .help("The model may still change grey words. Black words are settled.")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    private func transcript(_ lines: [LiveTranscriptLine], hidden: Int) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if hidden > 0 {
                    Text("\(hidden) earlier lines are not shown here. The whole live transcript is kept.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.bottom, 12)
                }
                ForEach(Array(lines.enumerated()), id: \.element.id) { index, line in
                    LineView(line: line)
                        .padding(.top, index == 0 ? 0 : (line.continuesSpeaker ? 6 : 12))
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollPosition($position)
        .defaultScrollAnchor(.bottom)
        .onScrollGeometryChange(for: [CGFloat].self) { geometry in
            [geometry.contentSize.height - geometry.visibleRect.maxY, geometry.contentSize.height]
        } action: { _, values in
            follow.scrolled(distanceFromBottom: values[0], contentHeight: values[1])
        }
        .onChange(of: lines) {
            if follow.isFollowing { position.scrollTo(edge: .bottom) }
        }
        .overlay(alignment: .bottom) {
            if !follow.isFollowing {
                Button {
                    follow.resume()
                    position.scrollTo(edge: .bottom)
                } label: {
                    Label("Resume Following", systemImage: "arrow.down")
                }
                .buttonStyle(.glass)
                .padding(.bottom, 10)
            }
        }
    }

    @ViewBuilder
    private var placeholder: some View {
        VStack(spacing: 10) {
            switch appState.live {
            case .preparing:
                ProgressView().controlSize(.small)
                Text("Preparing the live model…").font(.callout)
                Text("The recording is not affected. Words show up here once the model is ready.")
            case .listening:
                Text("Listening…").font(.callout)
                Text("Words show up here a moment after they are spoken.")
            case .finished:
                Text("No words were recognized.").font(.callout)
            case .failed(let message):
                Image(systemName: "exclamationmark.bubble.fill").foregroundStyle(.yellow).font(.title3)
                Text(message)
            case nil:
                if appState.phase.isRecording {
                    Text("Live transcript is off for this recording.").font(.callout)
                    Button("Open Transcription Settings") { actions.openMainWindow(.transcription) }
                } else {
                    Text("Nothing is being recorded.").font(.callout)
                    Text("Start a recording with live transcript on to see the words here.")
                }
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .padding(24)
    }

    private var footer: (text: String, isError: Bool)? {
        guard let live = appState.live else { return nil }
        switch live {
        case .failed(let message) where appState.liveTranscript?.words.isEmpty == false:
            return (message, true)
        case .finished:
            return ("Recording stopped. The saved transcript is made separately after Stop.", false)
        default:
            return nil
        }
    }

    private func footerView(_ footer: (text: String, isError: Bool)) -> some View {
        Label(footer.text, systemImage: footer.isError ? "exclamationmark.triangle.fill" : "checkmark.circle")
            .font(.caption)
            .foregroundStyle(.secondary)
            .symbolRenderingMode(footer.isError ? .multicolor : .monochrome)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
    }

    private struct LineView: View {
        let line: LiveTranscriptLine

        var body: some View {
            VStack(alignment: .leading, spacing: 3) {
                if !line.continuesSpeaker {
                    HStack(spacing: 6) {
                        Text(line.speaker).font(.caption.weight(.semibold))
                            .foregroundStyle(line.isLocal ? Color.accentColor : Color.primary)
                        Text(Self.time(line.start)).font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                    }
                }
                Text(attributed)
                    .font(.body)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(line.continuesSpeaker ? "\(line.speaker), \(Self.time(line.start))" : "")
            }
        }

        private var attributed: AttributedString {
            var result = AttributedString()
            for (index, run) in line.runs.enumerated() {
                var piece = AttributedString((index == 0 ? "" : " ") + run.text)
                if run.isDraft {
                    piece.foregroundColor = .secondary
                    piece.inlinePresentationIntent = .emphasized
                }
                result += piece
            }
            return result
        }

        static func time(_ seconds: TimeInterval) -> String {
            let total = Int(seconds.rounded(.down))
            return String(format: "%d:%02d", total / 60, total % 60)
        }
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

/// A floating panel with the live transcript. It never activates EchoPad or takes the
/// keyboard from the app in front, and closing it only hides it.
@MainActor
final class LiveTranscriptPanelController {
    static let SIZE = NSSize(width: 420, height: 480)

    let panel: NSPanel

    init(content: some View) {
        panel = NSPanel(contentRect: NSRect(origin: .zero, size: Self.SIZE),
                        styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel],
                        backing: .buffered, defer: true)
        panel.title = "Live Transcript"
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.contentView = NSHostingView(rootView: content)
        if !panel.setFrameUsingName(Self.AUTOSAVE_NAME) { place() }
        panel.setFrameAutosaveName(Self.AUTOSAVE_NAME)
    }

    static let AUTOSAVE_NAME = "EchoPadLiveTranscript"

    var isVisible: Bool { panel.isVisible }

    /// Shows the panel without activating EchoPad.
    func show() {
        panel.orderFrontRegardless()
    }

    func close() {
        panel.close()
    }

    /// Right side of the screen under the pointer, above the pill.
    private func place() {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main else { return }
        let area = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: area.maxX - Self.SIZE.width - 24, y: area.minY + 120))
    }
}
