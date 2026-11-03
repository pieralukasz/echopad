import SystemAudioKit
import XCTest
@testable import EchoPadKit

final class SoundCheckTests: XCTestCase {
    private func steps(backend: SystemAudioBackend = .processTap, permission: AudioPermissions.Status = .authorized,
                       scope: SoundCheck.Scope = .everything, test: SoundCheck.TestResult? = nil) -> [SoundCheck.Step] {
        SoundCheck.steps(backend: backend, permission: permission, scope: scope, test: test)
    }

    private func step(_ id: String, in steps: [SoundCheck.Step]) throws -> SoundCheck.Step {
        try XCTUnwrap(steps.first { $0.id == id })
    }

    func testDeniedPermissionPointsToPrivacySettings() throws {
        let permission = try step("permission", in: steps(permission: .denied))
        XCTAssertEqual(permission.kind, .problem)
        XCTAssertEqual(permission.fix, .openPrivacySettings(.systemAudio))
    }

    func testUnansweredPermissionCanBeAllowedInPlace() throws {
        let permission = try step("permission", in: steps(permission: .notDetermined))
        XCTAssertEqual(permission.kind, .problem)
        XCTAssertEqual(permission.fix, .allowPermission(.systemAudio))
    }

    func testScreenCaptureKitChecksScreenRecording() throws {
        let permission = try step("permission", in: steps(backend: .screenCaptureKit, permission: .denied))
        XCTAssertTrue(permission.title.contains("Screen Recording"))
        XCTAssertEqual(permission.fix, .openPrivacySettings(.screenRecording))
    }

    func testAllowedPermissionNeedsNoFix() throws {
        let permission = try step("permission", in: steps())
        XCTAssertEqual(permission.kind, .ok)
        XCTAssertNil(permission.fix)
    }

    func testOnlySomeAppsRecordedOffersSettingsAndSkipsTestSound() throws {
        let all = steps(scope: .apps(["Zoom"]))
        let scope = try step("scope", in: all)
        XCTAssertEqual(scope.kind, .info)
        XCTAssertTrue(scope.title.contains("Zoom"))
        XCTAssertEqual(scope.fix, .openRecordingSettings)
        // The test sound comes from another process, so an app-only capture never hears it.
        XCTAssertNil(all.first { $0.id == "test" })
    }

    func testTestSoundIsOfferedBeforeItRuns() throws {
        XCTAssertEqual(try step("test", in: steps()).fix, .playTestSound)
        XCTAssertNil(try step("test", in: steps(test: .running)).fix)
    }

    func testHeardTestSoundMeansCaptureWorks() throws {
        let test = try step("test", in: steps(test: .heard))
        XCTAssertEqual(test.kind, .ok)
        XCTAssertNil(test.fix)
    }

    func testSilenceDespiteAllowedPermissionPointsToStalePermission() throws {
        let test = try step("test", in: steps(test: .notHeard))
        XCTAssertEqual(test.kind, .problem)
        XCTAssertEqual(test.fix, .openPrivacySettings(.systemAudio))
    }

    func testSilenceWithMissingPermissionOffersRetry() throws {
        let test = try step("test", in: steps(permission: .denied, test: .notHeard))
        XCTAssertEqual(test.fix, .playTestSound)
    }

    func testAppListIsShortened() {
        XCTAssertEqual(SoundCheck.list([]), "selected apps")
        XCTAssertEqual(SoundCheck.list(["Zoom", "Slack"]), "Zoom and Slack")
        XCTAssertEqual(SoundCheck.list(["Zoom", "Slack", "Teams", "Meet"]), "Zoom, Slack and 2 more")
    }

    func testVerdict() {
        XCTAssertTrue(SoundCheck.hasProblem(steps(permission: .denied)))
        XCTAssertFalse(SoundCheck.hasProblem(steps(test: .heard)))
    }
}
