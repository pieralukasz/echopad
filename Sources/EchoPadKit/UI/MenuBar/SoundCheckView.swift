import AppKit
import SwiftUI
import SystemAudioKit

/// Shown in the menu bar panel when the other side of a call stays silent: what EchoPad
/// checked, and a button next to each problem that fixes it.
struct SoundCheckView: View {
    @Environment(AppState.self) private var appState
    @Environment(SettingsModel.self) private var settings
    @Environment(\.appActions) private var actions
    @State private var permissions = PermissionSnapshot.current()

    private var backend: SystemAudioBackend {
        SystemAudioBackend(rawValue: settings.value.systemAudioBackend) ?? .processTap
    }

    private var steps: [SoundCheck.Step] {
        let permission = backend == .screenCaptureKit ? permissions.screenRecording : permissions.systemAudio
        return SoundCheck.steps(backend: backend, permission: permission, scope: appState.captureScope,
                                test: appState.soundTest)
    }

    var body: some View {
        let steps = steps
        VStack(alignment: .leading, spacing: 8) {
            Label(headline(steps), systemImage: SoundCheck.hasProblem(steps) || appState.systemAudioLooksSilent
                  ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .font(.callout.weight(.semibold))
                .foregroundStyle(SoundCheck.hasProblem(steps) || appState.systemAudioLooksSilent ? .yellow : .green)
            ForEach(steps) { step in row(step) }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
        .onReceive(Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()) { _ in
            permissions = PermissionSnapshot.current()
        }
    }

    private func headline(_ steps: [SoundCheck.Step]) -> String {
        if SoundCheck.hasProblem(steps) { return "Problem with the other side's sound" }
        if appState.soundTest == .heard { return "Sound from the other side works" }
        return "No sound from the other side"
    }

    private func row(_ step: SoundCheck.Step) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            icon(step.kind)
            VStack(alignment: .leading, spacing: 4) {
                Text(step.title).font(.callout)
                if let detail = step.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1...6)
                }
                if let fix = step.fix { button(fix) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func icon(_ kind: SoundCheck.Step.Kind) -> some View {
        switch kind {
        case .ok: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .problem: Image(systemName: "exclamationmark.triangle.fill").symbolRenderingMode(.multicolor)
        case .info:
            if appState.soundTest == .running {
                ProgressView().controlSize(.mini)
            } else {
                Image(systemName: "info.circle").foregroundStyle(.secondary)
            }
        }
    }

    private func button(_ fix: SoundCheck.Fix) -> some View {
        Button(title(fix)) { perform(fix) }
            .buttonStyle(.glass)
            .controlSize(.small)
    }

    private func title(_ fix: SoundCheck.Fix) -> String {
        switch fix {
        case .allowPermission: return "Allow…"
        case .openPrivacySettings: return "Open Privacy Settings…"
        case .openRecordingSettings: return "Recording Settings…"
        case .playTestSound: return appState.soundTest == nil ? "Play Test Sound" : "Try Again"
        }
    }

    private func perform(_ fix: SoundCheck.Fix) {
        switch fix {
        case .allowPermission(let pane):
            Task {
                if pane == .screenRecording {
                    _ = CGRequestScreenCaptureAccess()
                } else {
                    _ = await AudioPermissions.requestSystemAudio()
                }
                permissions = PermissionSnapshot.current()
            }
        case .openPrivacySettings(let pane):
            NSWorkspace.shared.open(AudioPermissions.settingsURL(for: pane))
        case .openRecordingSettings:
            actions.openMainWindow(.recording)
        case .playTestSound:
            actions.playTestSound()
        }
    }
}
