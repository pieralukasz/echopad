import AppKit
import ScribeKit
import SwiftUI

/// Save locations: where transcripts go, how files are named, which formats, audio, and
/// what happens after saving.
struct DestinationsView: View {
    @Environment(SettingsModel.self) private var settings
    @State private var selection: UUID?

    var body: some View {
        Group {
            if let index = settings.value.destinations.firstIndex(where: { $0.id == selection }) {
                DestinationEditor(destination: binding(index))
                    .id(settings.value.destinations[index].id)
            } else {
                Color.clear
            }
        }
        .navigationTitle("Save Locations")
        .toolbar {
            ToolbarItemGroup {
                Picker("Save location", selection: $selection) {
                    ForEach(settings.value.destinations) { destination in
                        Text(destination.id == settings.value.defaultDestinationID
                             ? "\(destination.name) (default)" : destination.name)
                            .tag(Optional(destination.id))
                    }
                }
                .pickerStyle(.menu)
                .fixedSize()
                .help("Choose the save location to edit")
                Button { add() } label: { Label("Add Save Location", systemImage: "plus") }
                    .help("Add a save location")
                Button { remove() } label: { Label("Remove Save Location", systemImage: "trash") }
                    .disabled(settings.value.destinations.count < 2 || selection == nil)
                    .help("Remove this save location")
            }
        }
        .onAppear { selection = selection ?? settings.value.defaultDestinationID }
    }

    private func binding(_ index: Int) -> Binding<Destination> {
        Binding(get: { settings.value.destinations[index] },
                set: { settings.value.destinations[index] = $0 })
    }

    private func add() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "Choose the folder new transcripts are saved to."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var destination = Destination(name: url.lastPathComponent, folder: abbreviated(url.path))
        if destination.obsidianVault != nil {
            // Sensible Obsidian defaults: audio in the vault's attachments folder, open the note after saving.
            destination.audio = AudioSaving(location: .folder, folder: "attachments", format: .m4a, linkFromNote: true)
            destination.afterSave = [.openInObsidian]
        }
        settings.value.destinations.append(destination)
        selection = destination.id
    }

    private func remove() {
        guard let selection, settings.value.destinations.count > 1 else { return }
        settings.value.destinations.removeAll { $0.id == selection }
        if settings.value.defaultDestinationID == selection {
            settings.value.defaultDestinationID = settings.value.destinations.first?.id
        }
        self.selection = settings.value.defaultDestinationID
    }
}

func abbreviated(_ path: String) -> String {
    (path as NSString).abbreviatingWithTildeInPath
}

struct DestinationEditor: View {
    @Environment(SettingsModel.self) private var settings
    @Binding var destination: Destination

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $destination.name)
                LabeledContent("Folder") {
                    HStack {
                        Text(abbreviated(destination.folder)).lineLimit(1).truncationMode(.middle)
                        Button("Choose…") { chooseFolder() }
                    }
                }
                if let vault = destination.obsidianVault {
                    LabeledContent("Obsidian") {
                        Label("Inside the vault “\(vault.lastPathComponent)”", systemImage: "checkmark.seal.fill")
                            .foregroundStyle(.secondary)
                    }
                }
                Toggle("Use by default", isOn: Binding(
                    get: { settings.value.defaultDestinationID == destination.id },
                    set: { if $0 { settings.value.defaultDestinationID = destination.id } }))
                    .disabled(settings.value.defaultDestinationID == destination.id)
            }

            Section {
                TextField("File name", text: $destination.fileNameTemplate, prompt: Text(Destination.DEFAULT_FILE_NAME))
                TextField("Subfolder", text: $destination.subfolderTemplate, prompt: Text("none, e.g. {year}/{month}"))
                LabeledContent("Preview") {
                    Text(preview).font(.callout.monospaced()).foregroundStyle(.secondary)
                        .lineLimit(2).truncationMode(.head).textSelection(.enabled)
                }
            } header: {
                Text("Naming")
            } footer: {
                Text(NameTemplate.tokens.map { "{\($0)}" }.joined(separator: " "))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            Section("Files") {
                ForEach(TranscriptFormat.allCases) { format in
                    Toggle(format.displayName, isOn: formatBinding(format))
                }
                if destination.formats.contains(.markdown) {
                    Toggle("Properties (front matter)", isOn: $destination.includeFrontMatter)
                    Toggle("Timestamps", isOn: $destination.includeTimestamps)
                    if destination.includeFrontMatter {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Extra properties").font(.callout)
                            TextEditor(text: $destination.extraFrontMatter)
                                .font(.callout.monospaced())
                                .frame(minHeight: 44, maxHeight: 80)
                                .scrollContentBackground(.hidden)
                                .padding(4)
                                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                            Text("One per line, for example tags: meeting").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Section("Audio") {
                Picker("Keep the recording", selection: $destination.audio.location) {
                    Text("No").tag(AudioSaving.Location.none)
                    Text("Next to the transcript").tag(AudioSaving.Location.withTranscript)
                    Text("In a folder").tag(AudioSaving.Location.folder)
                }
                if destination.audio.location == .folder {
                    HStack {
                        TextField("Audio folder", text: $destination.audio.folder,
                                  prompt: Text("attachments, or a full path"))
                        Button("Choose…") { chooseAudioFolder() }
                    }
                }
                if destination.audio.location != .none {
                    Picker("Format", selection: $destination.audio.format) {
                        ForEach(AudioSaving.Format.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    if destination.formats.contains(.markdown) {
                        Toggle(destination.obsidianVault != nil ? "Embed the audio in the note" : "Link the audio from the note",
                               isOn: $destination.audio.linkFromNote)
                    }
                }
            }

            Section("After saving") {
                AfterSaveEditor(actions: $destination.afterSave, isObsidian: destination.obsidianVault != nil)
            }
        }
        .formStyle(.grouped)
    }

    private var preview: String {
        let values = NameTemplate.Values(date: Date(), title: "Weekly sync", app: "Zoom", duration: 47 * 60,
                                         speakerCount: 3, destination: destination.name)
        var parts = [abbreviated(destination.folder)]
        let subfolder = NameTemplate(destination.subfolderTemplate).folderPath(values)
        if !subfolder.isEmpty { parts.append(subfolder) }
        let ext = destination.formats.first?.fileExtension ?? "md"
        parts.append("\(NameTemplate(destination.fileNameTemplate).fileName(values)).\(ext)")
        return parts.joined(separator: "/")
    }

    private func formatBinding(_ format: TranscriptFormat) -> Binding<Bool> {
        Binding(get: { destination.formats.contains(format) }, set: { enabled in
            if enabled {
                destination.formats = TranscriptFormat.allCases.filter { destination.formats.contains($0) || $0 == format }
            } else if destination.formats.count > 1 {
                destination.formats.removeAll { $0 == format }
            }
        })
    }

    private func chooseFolder() {
        guard let url = pickFolder(start: destination.folderURL) else { return }
        destination.folder = abbreviated(url.path)
    }

    private func chooseAudioFolder() {
        guard let url = pickFolder(start: destination.folderURL) else { return }
        let base = (destination.obsidianVault ?? destination.folderURL).standardizedFileURL.path
        destination.audio.folder = url.standardizedFileURL.path.relativePath(from: base) ?? abbreviated(url.path)
    }

    private func pickFolder(start: URL) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = start
        panel.prompt = "Choose"
        return panel.runModal() == .OK ? panel.url : nil
    }
}

/// A list of after-save actions with their arguments.
struct AfterSaveEditor: View {
    @Binding var actions: [AfterSaveAction]
    let isObsidian: Bool

    var body: some View {
        ForEach(AfterSaveAction.Kind.allCases, id: \.self) { kind in
            if kind != .openInObsidian || isObsidian || actions.contains(where: { $0.kind == kind }) {
                row(kind)
            }
        }
    }

    @ViewBuilder
    private func row(_ kind: AfterSaveAction.Kind) -> some View {
        let index = actions.firstIndex { $0.kind == kind }
        Toggle(kind.title, isOn: Binding(get: { index != nil }, set: { enabled in
            if enabled {
                actions.append(make(kind, argument: ""))
            } else {
                actions.removeAll { $0.kind == kind }
            }
        }))
        if let index {
            switch actions[index] {
            case .runShortcut(let name):
                TextField("Shortcut name", text: Binding(get: { name }, set: { actions[index] = .runShortcut($0) }),
                          prompt: Text("Name in the Shortcuts app"))
            case .runScript(let path):
                HStack {
                    TextField("Script", text: Binding(get: { path }, set: { actions[index] = .runScript($0) }),
                              prompt: Text("~/bin/after-echopad.sh"))
                    Button("Choose…") {
                        let panel = NSOpenPanel()
                        panel.canChooseFiles = true
                        if panel.runModal() == .OK, let url = panel.url { actions[index] = .runScript(abbreviated(url.path)) }
                    }
                }
                Text("Gets the transcript path and the audio path as arguments.")
                    .font(.caption).foregroundStyle(.secondary)
            default:
                EmptyView()
            }
        }
    }

    private func make(_ kind: AfterSaveAction.Kind, argument: String) -> AfterSaveAction {
        switch kind {
        case .revealInFinder: return .revealInFinder
        case .openFile: return .openFile
        case .openInObsidian: return .openInObsidian
        case .copyTranscript: return .copyTranscript
        case .runShortcut: return .runShortcut(argument)
        case .runScript: return .runScript(argument)
        }
    }
}
