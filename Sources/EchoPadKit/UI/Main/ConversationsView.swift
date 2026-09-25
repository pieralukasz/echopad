import AppKit
import ScribeKit
import SwiftUI

/// List of conversations on the left, the selected transcript on the right.
struct ConversationsView: View {
    @Environment(ConversationLibrary.self) private var library
    @Environment(\.appActions) private var actions
    @Binding var selection: UUID?
    @State private var search = ""

    var body: some View {
        Group {
            if library.conversations.isEmpty {
                list
            } else {
                split
            }
        }
        .navigationTitle("Conversations")
        .toolbar {
            ToolbarItem {
                Button(action: actions.importAudio) { Label("Import Audio", systemImage: "square.and.arrow.down") }
                    .help("Transcribe an existing audio or video file")
            }
        }
    }

    private var split: some View {
        HSplitView {
            list
                .frame(minWidth: 240, idealWidth: 280, maxWidth: 360)
            Group {
                if let id = selection, let conversation = library.conversation(id: id) {
                    ConversationDetailView(conversation: conversation)
                        .id(id)
                } else {
                    emptyDetail
                }
            }
            .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var filtered: [Conversation] {
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return library.conversations }
        return library.conversations.filter {
            $0.title.localizedCaseInsensitiveContains(query)
                || $0.speakers.contains { $0.name.localizedCaseInsensitiveContains(query) }
                || (library.transcript(for: $0.id)?.text.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    @ViewBuilder
    private var list: some View {
        if library.conversations.isEmpty {
            VStack(spacing: 12) {
                HeroSymbol(name: "bubble.left.and.bubble.right", size: 40)
                Text("No conversations yet").font(.headline)
                Text("Start a recording from the menu bar or with your shortcut. Transcripts appear here and in your save location.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(selection: $selection) {
                ForEach(grouped, id: \.0) { day, conversations in
                    Section(day) {
                        ForEach(conversations) { conversation in
                            ConversationRow(conversation: conversation).tag(conversation.id)
                                .contextMenu { contextMenu(for: conversation) }
                        }
                    }
                }
            }
            .searchable(text: $search, placement: .sidebar, prompt: "Search transcripts")
        }
    }

    private var grouped: [(String, [Conversation])] {
        let calendar = Calendar.current
        var groups: [(String, [Conversation])] = []
        for conversation in filtered {
            let label: String
            if calendar.isDateInToday(conversation.date) {
                label = "Today"
            } else if calendar.isDateInYesterday(conversation.date) {
                label = "Yesterday"
            } else {
                label = conversation.date.formatted(.dateTime.weekday(.wide).day().month(.wide))
            }
            if groups.last?.0 == label {
                groups[groups.count - 1].1.append(conversation)
            } else {
                groups.append((label, [conversation]))
            }
        }
        return groups
    }

    @ViewBuilder
    private func contextMenu(for conversation: Conversation) -> some View {
        if let file = conversation.exportedFiles.first {
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: file)]) }
        }
        Button("Transcribe Again") { actions.reprocess(conversation.id) }
            .disabled(!library.hasAudio(conversation.id))
        Divider()
        Button("Remove from EchoPad", role: .destructive) {
            if selection == conversation.id { selection = nil }
            library.remove(conversation.id)
        }
    }

    private var emptyDetail: some View {
        VStack(spacing: 10) {
            HeroSymbol(name: "text.bubble", size: 44)
            Text("Select a conversation").foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ConversationRow: View {
    let conversation: Conversation

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(conversation.title).font(.body.weight(.medium)).lineLimit(1)
                Spacer()
                ConversationStatusBadge(conversation: conversation)
            }
            HStack(spacing: 6) {
                Text(conversation.date.formatted(date: .omitted, time: .shortened))
                if let app = conversation.app { Text("·"); Text(app) }
                if !conversation.speakers.isEmpty {
                    Text("·")
                    Text(conversation.speakers.count == 1 ? "1 speaker" : "\(conversation.speakers.count) speakers")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
    }
}

/// A transcript with speakers you can rename, and actions for the saved files.
struct ConversationDetailView: View {
    @Environment(ConversationLibrary.self) private var library
    @Environment(SettingsModel.self) private var settings
    @Environment(AppState.self) private var appState
    @Environment(\.appActions) private var actions
    let conversation: Conversation
    @State private var transcript: Transcript?
    @State private var editingSpeaker: Speaker?
    @State private var speakerName = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .task(id: conversation.status) { transcript = library.transcript(for: conversation.id) }
        .sheet(item: $editingSpeaker) { speaker in renameSheet(speaker) }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(conversation.title).font(.title2.weight(.semibold)).textSelection(.enabled)
            HStack(spacing: 14) {
                Label(conversation.date.formatted(date: .abbreviated, time: .shortened), systemImage: "calendar")
                Label(durationText(conversation.duration), systemImage: "clock")
                if conversation.wordCount > 0 { Label("\(conversation.wordCount) words", systemImage: "text.word.spacing") }
                if let app = conversation.app { Label(app, systemImage: "video") }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            if let transcript, !transcript.speakers.isEmpty { speakerChips(transcript) }
            actionBar
        }
        .padding(Theme.pagePadding)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func speakerChips(_ transcript: Transcript) -> some View {
        HStack(spacing: 6) {
            ForEach(transcript.speakers) { speaker in
                Button {
                    speakerName = speaker.name
                    editingSpeaker = speaker
                } label: {
                    Label(speaker.name, systemImage: speaker.isLocal ? "person.fill" : "person")
                        .font(.callout)
                        .foregroundStyle(TranscriptView.color(for: speaker, in: transcript))
                }
                .buttonStyle(.glass)
                .help("Rename this speaker everywhere in the transcript")
            }
        }
    }

    private var actionBar: some View {
        HStack(spacing: 8) {
            if let file = conversation.exportedFiles.first.map({ URL(fileURLWithPath: $0) }) {
                Button("Open") { NSWorkspace.shared.open(file) }
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([file]) }
            }
            if let transcript {
                Button("Copy Text") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(TranscriptRenderer.text(transcript), forType: .string)
                }
            }
            Spacer()
            Menu {
                Picker("Save to", selection: Binding(
                    get: { conversation.destinationID ?? settings.value.defaultDestinationID },
                    set: { id in
                        library.update(conversation.id) { $0.destinationID = id }
                        actions.reexport(conversation.id)
                    })) {
                    ForEach(settings.value.destinations) { Text($0.name).tag(Optional($0.id)) }
                }
                Button("Save Again") { actions.reexport(conversation.id) }
                    .disabled(transcript == nil)
                Button("Transcribe Again") { actions.reprocess(conversation.id) }
                    .disabled(!library.hasAudio(conversation.id) || appState.phase.isBusy)
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
            .fixedSize()
        }
        .controlSize(.regular)
    }

    @ViewBuilder
    private var content: some View {
        switch conversation.status {
        case .failed(let message):
            VStack(spacing: 12) {
                HeroSymbol(name: "exclamationmark.triangle", size: 40)
                Text(message).multilineTextAlignment(.center).foregroundStyle(.secondary)
                if library.hasAudio(conversation.id) {
                    Button("Transcribe Again") { actions.reprocess(conversation.id) }
                        .buttonStyle(.glassProminent)
                }
            }
            .padding(32)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .transcribing, .recorded:
            VStack(spacing: 14) {
                WorkingDots()
                Text(StatusText.title(appState)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .done:
            if let transcript { TranscriptView(transcript: transcript) } else { Color.clear }
        }
    }

    private func renameSheet(_ speaker: Speaker) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Rename \(speaker.name)").font(.headline)
            TextField("Name", text: $speakerName)
                .textFieldStyle(.roundedBorder)
                .onSubmit { commitRename(speaker) }
            Text("The saved files are updated too.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { editingSpeaker = nil }.keyboardShortcut(.cancelAction)
                Button("Rename") { commitRename(speaker) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(speakerName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 320)
    }

    private func commitRename(_ speaker: Speaker) {
        let name = speakerName.trimmingCharacters(in: .whitespaces)
        editingSpeaker = nil
        guard !name.isEmpty, name != speaker.name else { return }
        actions.renameSpeaker(conversation.id, speaker.id, name)
        transcript?.rename(speaker: speaker.id, to: name)
    }
}

/// The transcript as speaker turns, with timestamps and one color per speaker.
struct TranscriptView: View {
    let transcript: Transcript

    static let SPEAKER_COLORS: [Color] = [.blue, .orange, .purple, .teal, .pink, .green, .indigo, .brown]

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                ForEach(Array(transcript.segments.enumerated()), id: \.offset) { index, segment in
                    let speaker = transcript.speaker(for: segment.speakerID)
                    let showName = index == 0 || transcript.segments[index - 1].speakerID != segment.speakerID
                    VStack(alignment: .leading, spacing: 4) {
                        if showName || speaker == nil {
                            HStack(spacing: 8) {
                                if let speaker {
                                    Text(speaker.name).font(.callout.weight(.semibold))
                                        .foregroundStyle(Self.color(for: speaker, in: transcript))
                                }
                                Text(TranscriptRenderer.clock(segment.start))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        Text(segment.text)
                            .font(.body)
                            .lineSpacing(3)
                            .textSelection(.enabled)
                            .frame(maxWidth: 680, alignment: .leading)
                    }
                }
            }
            .padding(Theme.pagePadding)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    static func color(for speaker: Speaker, in transcript: Transcript) -> Color {
        let index = transcript.speakers.firstIndex { $0.id == speaker.id } ?? 0
        return SPEAKER_COLORS[index % SPEAKER_COLORS.count]
    }
}
