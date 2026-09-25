import AppKit
import SwiftUI
import SystemAudioKit

/// First run: what EchoPad does, permissions, where to save, then the model download.
struct OnboardingView: View {
    @Environment(SettingsModel.self) private var settings
    @Environment(AppState.self) private var appState
    let finish: () -> Void

    enum Step: Int, CaseIterable { case welcome, permissions, location, ready }

    @State private var step: Step = .welcome
    @State private var permissions = PermissionSnapshot.current()

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch step {
                case .welcome: welcome
                case .permissions: permissionsStep
                case .location: locationStep
                case .ready: readyStep
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 44)
            .padding(.top, 36)
            .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                    removal: .move(edge: .leading).combined(with: .opacity)))

            HStack {
                HStack(spacing: 6) {
                    ForEach(Step.allCases, id: \.self) { item in
                        Capsule()
                            .fill(item == step ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary))
                            .frame(width: item == step ? 18 : 6, height: 6)
                    }
                }
                Spacer()
                if step != .welcome {
                    Button("Back") { move(-1) }
                }
                Button(step == .ready ? "Start Using EchoPad" : "Continue") {
                    step == .ready ? finish() : move(1)
                }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
            }
            .padding(20)
        }
        .frame(width: 560, height: 520)
        .animation(.smooth(duration: 0.35), value: step)
        .onReceive(Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()) { _ in
            permissions = PermissionSnapshot.current()
        }
    }

    private func move(_ delta: Int) {
        step = Step(rawValue: step.rawValue + delta) ?? step
    }

    private var welcome: some View {
        VStack(spacing: 18) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 120, height: 120)
            Text("Welcome to EchoPad").font(.largeTitle.weight(.semibold))
            Text("Record calls and conversations, get a transcript with who said what, saved as files wherever you keep your notes.")
                .font(.title3)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 10) {
                feature("lock.shield", "Runs entirely on your Mac. No account, no cloud.")
                feature("person.2.wave.2", "Separates you from the other side, and the other side into speakers.")
                feature("folder", "Markdown, text, subtitles or JSON, in any folder or Obsidian vault.")
            }
            .padding(.top, 6)
        }
    }

    private func feature(_ symbol: String, _ text: String) -> some View {
        Label { Text(text) } icon: { Image(systemName: symbol).foregroundStyle(.tint).frame(width: 24) }
    }

    private var permissionsStep: some View {
        VStack(spacing: 18) {
            HeroSymbol(name: "waveform.badge.mic")
            Text("Two permissions").font(.title.weight(.semibold))
            Text("EchoPad records your microphone for your side of the conversation, and the Mac's sound output for the other side.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
            Form {
                PermissionRow(title: "Microphone", status: permissions.microphone, pane: .microphone) {
                    _ = await AudioPermissions.requestMicrophone()
                }
                PermissionRow(title: "System Audio Recording", status: permissions.systemAudio, pane: .systemAudio) {
                    _ = await AudioPermissions.requestSystemAudio()
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .frame(height: 130)
            Text("You can skip this now. macOS asks the first time you record.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var locationStep: some View {
        @Bindable var settings = settings
        let destination = settings.value.defaultDestination
        VStack(spacing: 18) {
            HeroSymbol(name: "folder.badge.plus")
            Text("Where should transcripts go?").font(.title.weight(.semibold))
            Text("Pick any folder. If it is inside an Obsidian vault, EchoPad links the audio and opens notes in Obsidian.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
            HStack {
                Image(systemName: destination.obsidianVault != nil ? "books.vertical.fill" : "folder.fill").foregroundStyle(.tint)
                Text(abbreviated(destination.folder)).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button("Choose…") { chooseFolder() }
            }
            .padding(12)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
            Text("You can add more save locations later, each with its own naming, formats and audio settings.")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
    }

    private var readyStep: some View {
        VStack(spacing: 18) {
            HeroSymbol(name: "checkmark.seal")
            Text("You're set").font(.title.weight(.semibold))
            VStack(alignment: .leading, spacing: 10) {
                feature("keyboard", "Press \(HotkeyLabel.describe(settings.value.hotkey)) anywhere to start or stop.")
                feature("menubar.rectangle", "Or use the two bubbles in the menu bar.")
                feature("video", "When a call starts, EchoPad offers to record it.")
            }
            modelProgress.padding(.top, 8)
        }
    }

    @ViewBuilder
    private var modelProgress: some View {
        switch appState.model {
        case .ready:
            Label("Speech model ready", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .loading(let fraction, let detail):
            VStack(spacing: 6) {
                if let fraction { ProgressView(value: fraction) } else { ProgressView().controlSize(.small) }
                Text("Downloading the speech model once (about 600 MB). \(detail)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: 360)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill").symbolRenderingMode(.multicolor)
        case .notLoaded:
            EmptyView()
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url,
              let index = settings.value.destinations.firstIndex(where: { $0.id == settings.value.defaultDestination.id })
        else { return }
        var destination = settings.value.destinations[index]
        destination.folder = abbreviated(url.path)
        destination.name = url.lastPathComponent
        if destination.obsidianVault != nil {
            destination.audio = AudioSaving(location: .folder, folder: "attachments", format: .m4a, linkFromNote: true)
            destination.afterSave = [.openInObsidian]
        }
        settings.value.destinations[index] = destination
    }
}
