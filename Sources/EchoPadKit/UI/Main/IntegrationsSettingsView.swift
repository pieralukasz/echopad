import AppKit
import SwiftUI

/// Settings > Integrations: the local API and outgoing webhooks. Both stay off until switched on here.
struct IntegrationsSettingsView: View {
    @Environment(SettingsModel.self) private var settings
    @Environment(IntegrationStatus.self) private var status
    @Environment(\.appActions) private var actions
    @State private var portText = ""
    @State private var copied: IntegrationSecrets.Kind?

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                Toggle("Allow apps and agents on this Mac to use EchoPad", isOn: $settings.value.integrations.apiEnabled)
                LabeledContent("Port") {
                    HStack {
                        TextField("Port", text: $portText, prompt: Text(String(IntegrationSettings.DEFAULT_PORT)))
                            .labelsHidden()
                            .frame(width: 80)
                            .multilineTextAlignment(.trailing)
                            .onSubmit(applyPort)
                        if IntegrationsSettingsView.port(from: portText) != settings.value.integrations.apiPort {
                            Button("Apply", action: applyPort).disabled(IntegrationsSettingsView.port(from: portText) == nil)
                        }
                    }
                }
                LabeledContent("Status") { apiStatus }
                LabeledContent("Access token") {
                    HStack {
                        Text(verbatim: "••••••••••••").foregroundStyle(.secondary).accessibilityLabel("Hidden")
                        copyButton(.apiToken, enabled: settings.value.integrations.apiEnabled)
                    }
                }
            } header: {
                Text("Local API")
            } footer: {
                Text("Listens on 127.0.0.1 only, never on the network. Every request needs the access token. It lets local tools read your conversations, the live transcript, and start or stop a recording. The `echopad` command line uses it too.")
            }

            Section {
                Toggle("Send webhooks", isOn: $settings.value.integrations.webhooksEnabled)
                ForEach(0..<settings.value.integrations.webhooks.count, id: \.self) { index in
                    WebhookEditor(webhook: webhookBinding(index)) {
                        settings.value.integrations.webhooks.remove(at: index)
                    }
                }
                LabeledContent("Signing secret") {
                    HStack {
                        Text(verbatim: "••••••••••••").foregroundStyle(.secondary).accessibilityLabel("Hidden")
                        copyButton(.webhookSecret, enabled: settings.value.integrations.webhooksEnabled)
                    }
                }
                Button("Add Webhook") {
                    settings.value.integrations.webhooks.append(.init(url: "https://"))
                }
            } header: {
                Text("Webhooks")
            } footer: {
                Text("EchoPad posts each selected event as signed JSON (Standard Webhooks). URLs must use https; plain http only to this Mac. The transcript is sent only to webhooks where you turn it on.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Integrations")
        .onAppear { portText = String(settings.value.integrations.apiPort) }
    }

    @ViewBuilder
    private var apiStatus: some View {
        switch status.api {
        case .off:
            Text("Off").foregroundStyle(.secondary)
        case .listening(let port):
            Label("Listening on 127.0.0.1:\(String(port))", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed(let message):
            HStack {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .symbolRenderingMode(.multicolor)
                    .lineLimit(2)
                Button("Try Again", action: actions.retryAPI)
            }
        }
    }

    private func copyButton(_ kind: IntegrationSecrets.Kind, enabled: Bool) -> some View {
        Button(copied == kind ? "Copied" : "Copy") {
            if actions.copySecret(kind) {
                copied = kind
                Task { try? await Task.sleep(for: .seconds(2)); if copied == kind { copied = nil } }
            }
        }
        .disabled(!enabled)
        .help(enabled ? "Copies it to the clipboard. It is never shown on screen." : "Switch this on first.")
    }

    /// Index-safe: a removed row may render once more before the list shrinks.
    private func webhookBinding(_ index: Int) -> Binding<IntegrationSettings.Webhook> {
        Binding {
            let hooks = settings.value.integrations.webhooks
            return index < hooks.count ? hooks[index] : .init(url: "")
        } set: { value in
            guard index < settings.value.integrations.webhooks.count else { return }
            settings.value.integrations.webhooks[index] = value
        }
    }

    private func applyPort() {
        guard let port = Self.port(from: portText) else { return }
        settings.value.integrations.apiPort = port
    }

    /// A port the user may type: 1024–65535 (lower ones need root).
    static func port(from text: String) -> UInt16? {
        guard let value = UInt16(text.trimmingCharacters(in: .whitespaces)), value >= 1024 else { return nil }
        return value
    }
}

private struct WebhookEditor: View {
    @Binding var webhook: IntegrationSettings.Webhook
    let remove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("URL", text: $webhook.url, prompt: Text("https://example.com/hooks/echopad"))
                    .labelsHidden()
                    .textContentType(.URL)
                Button(action: remove) { Image(systemName: "minus.circle") }
                    .buttonStyle(.borderless)
                    .help("Remove this webhook")
            }
            if let problem = WebhookPolicy.problem(webhook.url) {
                Label(problem, systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            HStack {
                Menu(eventsTitle) {
                    ForEach(IntegrationEvent.Kind.allCases, id: \.self) { kind in
                        Toggle(kind.rawValue, isOn: eventBinding(kind))
                    }
                    Divider()
                    Button("All Events") { webhook.events = [] }
                }
                .fixedSize()
                Spacer()
                Toggle("Include transcript", isOn: $webhook.includeTranscript)
                    .toggleStyle(.checkbox)
                    .help("Adds the transcript text to conversation.saved. Off unless you turn it on.")
            }
        }
        .padding(.vertical, 2)
    }

    private var eventsTitle: String {
        webhook.events.isEmpty ? "All events" : webhook.events.count == 1 ? webhook.events[0] : "\(webhook.events.count) events"
    }

    private func eventBinding(_ kind: IntegrationEvent.Kind) -> Binding<Bool> {
        Binding {
            webhook.events.isEmpty || webhook.events.contains(kind.rawValue)
        } set: { on in
            var selected = webhook.events.isEmpty ? IntegrationEvent.Kind.allCases.map(\.rawValue) : webhook.events
            if on { if !selected.contains(kind.rawValue) { selected.append(kind.rawValue) } } else { selected.removeAll { $0 == kind.rawValue } }
            // Every event selected is stored as "all"; none selected keeps one so the webhook is not silently "all".
            webhook.events = selected.count == IntegrationEvent.Kind.allCases.count ? [] : (selected.isEmpty ? webhook.events : selected)
        }
    }
}
