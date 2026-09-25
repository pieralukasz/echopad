import AppKit
import SwiftUI

/// The menu bar item: an icon that animates while recording and processing, and a
/// popover with ``MenuBarPanel``. Right click toggles recording directly.
@MainActor
final class StatusBarController: NSObject {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let popover = NSPopover()
    private let appState: AppState
    private var animationTimer: Timer?
    private var frame = 0
    private lazy var logo = StatusBarIcons.logo()
    private lazy var recordingFrames = StatusBarIcons.recordingFrames()
    private lazy var workingFrames = StatusBarIcons.workingFrames()
    var onRightClick: (() -> Void)?

    init(appState: AppState, content: some View) {
        self.appState = appState
        super.init()
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: content)
        if let button = item.button {
            button.image = logo
            button.target = self
            button.action = #selector(clicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.setAccessibilityLabel("EchoPad")
        }
        observeContinuously({ [weak self] in _ = self?.appState.phase }, onChange: { [weak self] in self?.update() })
    }

    @objc private func clicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            onRightClick?()
            return
        }
        togglePopover()
    }

    func togglePopover() {
        guard let button = item.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    func closePopover() {
        popover.performClose(nil)
    }

    private func update() {
        animationTimer?.invalidate()
        animationTimer = nil
        switch appState.phase {
        case .recording: animate(recordingFrames)
        case .processing: animate(workingFrames)
        case .saved: item.button?.image = StatusBarIcons.symbol("checkmark.circle")
        case .error: item.button?.image = StatusBarIcons.symbol("exclamationmark.triangle")
        case .idle: item.button?.image = logo
        }
    }

    private func animate(_ frames: [NSImage]) {
        frame = 0
        item.button?.image = frames[0]
        animationTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 12, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.frame = (self.frame + 1) % frames.count
                self.item.button?.image = frames[self.frame]
            }
        }
    }
}
