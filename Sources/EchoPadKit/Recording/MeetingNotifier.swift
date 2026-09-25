import AppKit
import Foundation
import SystemAudioKit
import UserNotifications

/// Turns meeting detection into a notification with a "Record" button.
@MainActor
public final class MeetingNotifier: NSObject, UNUserNotificationCenterDelegate {
    static let CATEGORY = "echopad.meeting"
    static let RECORD_ACTION = "echopad.record"

    private let detector = MeetingDetector()
    private var pending: [String: DetectedMeeting] = [:]
    private var isRunning = false
    /// Called when the user taps Record (or the notification itself).
    public var onRecord: ((DetectedMeeting) -> Void)?
    public var onMeetingEnded: ((DetectedMeeting) -> Void)?
    public var onActiveChange: ((DetectedMeeting?) -> Void)?
    /// Not notified while this returns true (for example while already recording).
    public var isSuppressed: () -> Bool = { false }

    /// UNUserNotificationCenter crashes outside an app bundle, so bare CLI builds skip it.
    private var canNotify: Bool { Bundle.main.bundleIdentifier != nil && Bundle.main.bundlePath.hasSuffix(".app") }

    public override init() {
        super.init()
        detector.onChange = { [weak self] started, ended in self?.handle(started: started, ended: ended) }
    }

    public func setEnabled(_ enabled: Bool) {
        guard enabled != isRunning else { return }
        isRunning = enabled
        if enabled {
            configureNotifications()
            detector.start()
        } else {
            detector.stop()
            onActiveChange?(nil)
        }
    }

    private func configureNotifications() {
        guard canNotify else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let record = UNNotificationAction(identifier: Self.RECORD_ACTION, title: "Record", options: [])
        let category = UNNotificationCategory(identifier: Self.CATEGORY, actions: [record], intentIdentifiers: [])
        center.setNotificationCategories([category])
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func handle(started: [DetectedMeeting], ended: [DetectedMeeting]) {
        for meeting in ended {
            pending[meeting.bundleID] = nil
            onMeetingEnded?(meeting)
            if canNotify {
                UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [meeting.bundleID])
            }
        }
        onActiveChange?(detector.active.first)
        guard !isSuppressed() else { return }
        for meeting in started {
            pending[meeting.bundleID] = meeting
            post(meeting)
        }
    }

    private func post(_ meeting: DetectedMeeting) {
        guard canNotify else { return }
        let content = UNMutableNotificationContent()
        content.title = "\(meeting.appName) is using the microphone"
        content.body = "Record and transcribe this conversation with EchoPad?"
        content.categoryIdentifier = Self.CATEGORY
        content.userInfo = ["bundleID": meeting.bundleID]
        let request = UNNotificationRequest(identifier: meeting.bundleID, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    public nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                                   didReceive response: UNNotificationResponse) async {
        let bundleID = response.notification.request.content.userInfo["bundleID"] as? String
        let action = response.actionIdentifier
        await MainActor.run {
            guard let bundleID, let meeting = pending[bundleID],
                  action == Self.RECORD_ACTION || action == UNNotificationDefaultActionIdentifier else { return }
            pending[bundleID] = nil
            onRecord?(meeting)
        }
    }

    public nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                                   willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
