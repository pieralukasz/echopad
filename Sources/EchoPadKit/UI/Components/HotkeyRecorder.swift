import AppKit
import ServiceManagement
import SwiftUI

/// Click, then press a key combination. Requires at least one modifier so plain typing
/// never starts a recording.
struct HotkeyRecorder: View {
    @Binding var hotkey: Hotkey
    @State private var isRecording = false
    @State private var monitor: Any?

    var body: some View {
        Button {
            isRecording ? stop() : start()
        } label: {
            Text(isRecording ? "Press keys…" : HotkeyLabel.describe(hotkey))
                .font(.body.monospaced())
                .frame(minWidth: 90)
        }
        .buttonStyle(.glass)
        .onDisappear { stop() }
    }

    private func start() {
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { // Escape cancels
                stop()
                return nil
            }
            let modifiers = HotkeyLabel.carbonModifiers(event.modifierFlags)
            guard modifiers != 0 else { NSSound.beep(); return nil }
            hotkey = Hotkey(keyCode: UInt32(event.keyCode), modifiers: modifiers)
            stop()
            return nil
        }
    }

    private func stop() {
        isRecording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

struct LaunchAtLoginToggle: View {
    @State private var enabled = SMAppService.mainApp.status == .enabled
    @State private var error: String?

    var body: some View {
        Toggle("Open at login", isOn: Binding(get: { enabled }, set: { newValue in
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                enabled = newValue
                error = nil
            } catch {
                self.error = error.localizedDescription
            }
        }))
        if let error { Text(error).font(.caption).foregroundStyle(.secondary) }
    }
}
