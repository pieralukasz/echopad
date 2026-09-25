import AppKit
import SwiftUI

/// Opens and reuses the main and onboarding windows. EchoPad is a menu bar app, so it
/// shows in the Dock only while a window is open.
@MainActor
final class WindowCoordinator: NSObject, NSWindowDelegate {
    private var mainWindow: NSWindow?
    private var onboardingWindow: NSWindow?
    private let environment: (AnyView) -> AnyView
    var selection: MainSection = .conversations
    var selectedConversation: UUID?

    init(environment: @escaping (AnyView) -> AnyView) {
        self.environment = environment
    }

    func showMain(section: MainSection? = nil, conversation: UUID? = nil) {
        if let section { selection = section }
        if let conversation {
            selection = .conversations
            selectedConversation = conversation
        }
        if mainWindow == nil {
            let root = MainRoot(coordinator: self)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 640),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                  backing: .buffered, defer: false)
            window.title = "EchoPad"
            window.titlebarAppearsTransparent = true
            window.toolbarStyle = .unified
            window.contentViewController = NSHostingController(rootView: environment(AnyView(root)))
            window.setContentSize(NSSize(width: 980, height: 640))
            window.minSize = NSSize(width: 820, height: 520)
            window.setFrameAutosaveName("EchoPadMain")
            window.isReleasedWhenClosed = false
            window.delegate = self
            if window.frame.origin == .zero { window.center() }
            mainWindow = window
        }
        NotificationCenter.default.post(name: .echoPadNavigate, object: nil)
        present(mainWindow)
    }

    func showOnboarding(finish: @escaping () -> Void) {
        if onboardingWindow == nil {
            let view = OnboardingView(finish: { [weak self] in
                self?.onboardingWindow?.close()
                finish()
            })
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 520),
                                  styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isMovableByWindowBackground = true
            window.contentViewController = NSHostingController(rootView: environment(AnyView(view)))
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            onboardingWindow = window
        }
        present(onboardingWindow)
    }

    private func present(_ window: NSWindow?) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let anyVisible = [self.mainWindow, self.onboardingWindow].contains { $0?.isVisible == true }
            if !anyVisible { NSApp.setActivationPolicy(.accessory) }
        }
    }
}

extension Notification.Name {
    static let echoPadNavigate = Notification.Name("EchoPadNavigate")
}

/// Keeps the sidebar selection in sync with the coordinator, so menu bar buttons can
/// jump to a section or a conversation in an open window.
private struct MainRoot: View {
    let coordinator: WindowCoordinator
    @State private var selection: MainSection = .conversations
    @State private var conversation: UUID?

    var body: some View {
        MainView(selection: $selection, selectedConversation: $conversation)
            .onAppear(perform: sync)
            .onReceive(NotificationCenter.default.publisher(for: .echoPadNavigate)) { _ in sync() }
            .onChange(of: selection) { coordinator.selection = selection }
            .onChange(of: conversation) { coordinator.selectedConversation = conversation }
    }

    private func sync() {
        selection = coordinator.selection
        conversation = coordinator.selectedConversation
    }
}
