import AppKit
import Foundation
import ScribeKit
import SwiftUI
import XCTest
@testable import EchoPadKit

/// Never returns and ignores cancellation, like a CoreML call stuck in the Neural Engine.
private func hangForever() async {
    await withUnsafeContinuation { (_: UnsafeContinuation<Void, Never>) in }
}

private actor StuckScribe: ConversationTranscribing {
    private(set) var calls = 0
    func prepare(diarization: Bool, progress: (@Sendable (ModelProgress) -> Void)?) async throws {
        calls += 1
        await hangForever()
    }
    func transcribeConversation(microphone: URL?, system: URL?, options: TranscriptionOptions,
                                progress: (@Sendable (TranscriptionStage) -> Void)?) async throws -> Transcript {
        calls += 1
        progress?(.loadingModels)
        progress?(.transcribing(track: "system audio"))
        await hangForever()
        throw CancellationError()
    }
}

private actor WorkingScribe: ConversationTranscribing {
    private(set) var calls = 0
    func prepare(diarization: Bool, progress: (@Sendable (ModelProgress) -> Void)?) async throws { calls += 1 }
    func transcribeConversation(microphone: URL?, system: URL?, options: TranscriptionOptions,
                                progress: (@Sendable (TranscriptionStage) -> Void)?) async throws -> Transcript {
        calls += 1
        return Transcript(segments: [Segment(speakerID: "remote", start: 0, end: 1, text: "Dzień dobry")],
                          speakers: [Speaker(id: "remote", name: "Speaker 1")], language: "pl", duration: 3)
    }
}

final class WatchdogTests: XCTestCase {
    /// A task group would wait for the stuck child and never return; the watchdog must not.
    func testAStepThatNeverReturnsAndIgnoresCancellationTimesOut() async {
        let done = expectation(description: "watchdog returned")
        Task {
            do {
                try await Watchdog.run(budget: .milliseconds(200), stage: "Loading the speech model") { _ in
                    await hangForever()
                }
                XCTFail("a stuck step cannot succeed")
            } catch let error as Watchdog.TimedOut {
                XCTAssertEqual(error.stage, "Loading the speech model")
            } catch {
                XCTFail("unexpected \(error)")
            }
            done.fulfill()
        }
        await fulfillment(of: [done], timeout: 3)
    }

    /// Progress moves the deadline: a step longer than its budget is not cut off while it advances.
    func testAStepThatKeepsReportingProgressIsNotCutOff() async throws {
        let clock = ContinuousClock(), began = clock.now
        let value = try await Watchdog.run(budget: .milliseconds(300), stage: "Transcribing") { watch in
            for _ in 0..<10 {
                try await Task.sleep(for: .milliseconds(100))
                watch.advance()
            }
            return 42
        }
        XCTAssertEqual(value, 42)
        XCTAssertGreaterThan(clock.now - began, .milliseconds(900))
    }
}

@MainActor
final class StuckTranscriptionTests: XCTestCase {
    func testAStuckTranscriptionFailsVisiblyKeepsTheAudioAndTheRetryUsesAFreshModel() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = ConversationLibrary(directory: root.appendingPathComponent("Library"))
        var settings = Settings()
        let destination = Destination(name: "Test", folder: root.appendingPathComponent("Notes").path,
                                      fileNameTemplate: "{title}", formats: [.text])
        settings.destinations = [destination]
        settings.defaultDestinationID = destination.id
        let stuck = StuckScribe(), fresh = WorkingScribe()
        var made = 0
        let controller = RecordingController(appState: AppState(), library: library, settings: settings,
                                             scribe: stuck, makeScribe: { made += 1; return fresh })
        controller.modelLoadBudget = .milliseconds(300)
        controller.stepBudget = { _ in .milliseconds(300) }

        let conversation = Conversation(title: "Probe", date: Date(), duration: 3, destinationID: destination.id)
        library.add(conversation)
        let folder = library.folder(for: conversation.id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let audio = folder.appendingPathComponent("system.wav")
        try Data(repeating: 1, count: 64).write(to: audio)

        let finished = expectation(description: "process returned")
        Task { await controller.process(conversation.id); finished.fulfill() }
        await fulfillment(of: [finished], timeout: 5)

        guard case .failed(let message) = library.conversation(id: conversation.id)?.status else {
            return XCTFail("status \(String(describing: library.conversation(id: conversation.id)?.status))")
        }
        XCTAssertTrue(message.contains("transcribing the system audio"), message)
        XCTAssertTrue(message.contains("Transcribe Again"), message)
        XCTAssertTrue(FileManager.default.fileExists(atPath: audio.path), "the audio stays for a retry")
        XCTAssertEqual(made, 1, "the stuck model is replaced")

        await controller.process(conversation.id)
        XCTAssertEqual(library.conversation(id: conversation.id)?.status, .done)
        let stuckCalls = await stuck.calls, freshCalls = await fresh.calls
        XCTAssertEqual(stuckCalls, 1, "the retry never calls the stuck model again")
        XCTAssertEqual(freshCalls, 1)
    }
}

@MainActor
final class LiveTranscriptPanelTests: XCTestCase {
    private func word(_ id: String, _ text: String, _ start: Double, speaker: String? = "s1",
                      draft: Bool = false, revision: Int = 1) -> LiveWord {
        LiveWord(id: id, track: .system, text: text, start: start, end: start + 0.4, speakerID: speaker,
                 textState: draft ? .pending : .final, speakerState: .final, revision: revision)
    }

    private func snapshot(_ words: [LiveWord], revision: Int) -> LiveSnapshot {
        LiveSnapshot(revision: revision, phase: .running, engine: "test", words: words,
                     speakers: [Speaker(id: "s1", name: "Speaker 1"), Speaker(id: "s2", name: "Speaker 2")],
                     gaps: [], received: ["system": 10], error: nil)
    }

    func testARevisedDraftReplacesItsTextInsteadOfBeingAppendedAgain() {
        let first = snapshot([word("a", "Dzień", 0), word("b", "dob", 0.5, draft: true)], revision: 1)
        XCTAssertEqual(LiveTranscriptLine.lines(from: first).lines.first?.runs,
                       [.init(text: "Dzień", isDraft: false), .init(text: "dob", isDraft: true)])

        let revised = snapshot([word("a", "Dzień", 0), word("b", "dobry", 0.5, revision: 2),
                                word("c", "wszystkim", 1.0, draft: true, revision: 2),
                                word("d", "Cześć", 1.6, speaker: "s2", revision: 2)], revision: 2)
        let lines = LiveTranscriptLine.lines(from: revised).lines
        XCTAssertEqual(lines.map(\.speaker), ["Speaker 1", "Speaker 2"])
        XCTAssertEqual(lines[0].id, "a", "a line keeps its identity while its words are revised")
        XCTAssertEqual(lines[0].runs, [.init(text: "Dzień dobry", isDraft: false), .init(text: "wszystkim", isDraft: true)])
        XCTAssertEqual(lines[0].text, "Dzień dobry wszystkim")
        XCTAssertEqual(lines[1].text, "Cześć")
    }

    func testALongSessionDrawsOnlyTheLastLinesAndKeepsEveryWord() {
        let words = (0..<350).map { word("w\($0)", "słowo\($0)", Double($0), speaker: $0 % 2 == 0 ? "s1" : "s2") }
        let live = snapshot(words, revision: 9)
        let built = LiveTranscriptLine.lines(from: live, limit: 300)
        XCTAssertEqual(built.lines.count, 300)
        XCTAssertEqual(built.hidden, 50)
        XCTAssertEqual(built.lines.last?.text, "słowo349")
        XCTAssertEqual(live.words.count, 350, "the snapshot itself is not trimmed")
    }

    func testAMonologueWithoutPausesIsSplitIntoBoundedLines() {
        let words = (0..<400).map { word("w\($0)", $0 % 10 == 9 ? "koniec." : "słowo", Double($0) * 0.3) }
        let lines = LiveTranscriptLine.lines(from: snapshot(words, revision: 1)).lines
        XCTAssertGreaterThan(lines.count, 1)
        XCTAssertTrue(lines.allSatisfy { $0.text.split(separator: " ").count <= LiveTranscriptLine.MAX_LINE_WORDS })
        XCTAssertEqual(lines.map { $0.text.split(separator: " ").count }.reduce(0, +), 400, "no word is lost or doubled")
    }

    func testPunctuationSticksToTheSpeakersLineAndNeverStartsOne() {
        let lines = LiveTranscriptLine.lines(from: snapshot([
            word("a", "Chcę", 0), word("b", "drugi", 0.4), word("c", ".", 0.8), word("d", "Na", 1.0),
            word("e", "przykład", 1.4),
            word("f", "No", 3.5, speaker: "s2"),
            word("g", ",", 6.0), word("h", "niech", 6.2), word("i", "będzie", 6.6), word("j", ".", 7.0),
            word("k", ".", 7.1, speaker: nil),
        ], revision: 1)).lines
        XCTAssertEqual(lines.map(\.text), ["Chcę drugi. Na przykład,", "No", "niech będzie."])
        XCTAssertEqual(lines.map(\.speaker), ["Speaker 1", "Speaker 2", "Speaker 1"])
    }

    func testOverlappingSpeechStaysInEachSpeakersLine() {
        // Two people talking over each other: their words interleave within a second.
        let lines = LiveTranscriptLine.lines(from: snapshot([
            word("a", "No", 12.5), word("b", "też", 13.0), word("c", "nie", 13.3),
            word("d", "Ale", 13.5, speaker: "s2"), word("e", "bych", 13.4), word("f", "opowiedz", 13.8, speaker: "s2"),
            word("g", "to", 13.6), word("h", "miał", 13.7), word("i", "mi", 14.2, speaker: "s2"),
            word("j", "działać", 13.9), word("k", "błąd", 14.3, speaker: "s2"),
        ], revision: 1)).lines
        XCTAssertEqual(lines.map(\.text), ["No też nie bych to miał działać", "Ale opowiedz mi błąd"])
    }

    func testAlternatingTurnsKeepTheirOrderAndRepeatedSpeakersShowOneHeader() {
        let lines = LiveTranscriptLine.lines(from: snapshot([
            word("a", "Jeden", 0), word("b", "sklep", 0.4),
            word("c", "Drugi", 4.0), word("d", "sklep", 4.4),
            word("e", "Tak", 6.0, speaker: "s2"),
            word("f", "Trzeci", 9.0),
        ], revision: 1)).lines
        XCTAssertEqual(lines.map(\.text), ["Jeden sklep", "Drugi sklep", "Tak", "Trzeci"])
        XCTAssertEqual(lines.map(\.continuesSpeaker), [false, true, false, false],
                       "a pause starts a new line, but the same speaker's next line has no second name")
    }

        func testNewWordsDoNotStopFollowingButScrollingUpDoesUntilTheReaderReturns() {
        var follow = ScrollFollowing()
        follow.scrolled(distanceFromBottom: 0, contentHeight: 500)
        follow.scrolled(distanceFromBottom: 120, contentHeight: 620) // new words, not yet scrolled down
        XCTAssertTrue(follow.isFollowing)
        follow.scrolled(distanceFromBottom: 0, contentHeight: 620)
        follow.scrolled(distanceFromBottom: 300, contentHeight: 620) // the reader scrolled up
        XCTAssertFalse(follow.isFollowing)
        follow.scrolled(distanceFromBottom: 420, contentHeight: 740) // more words arrive meanwhile
        XCTAssertFalse(follow.isFollowing, "new words must not pull the reader back")
        follow.resume()
        XCTAssertTrue(follow.isFollowing)
        follow.scrolled(distanceFromBottom: 300, contentHeight: 740)
        follow.scrolled(distanceFromBottom: 10, contentHeight: 740) // scrolled back to the end
        XCTAssertTrue(follow.isFollowing)
    }

    /// A real NSPanel: shown without activating EchoPad or taking the keyboard, closing only hides it.
    func testThePanelShowsWithoutActivatingAndReopensAfterClosing() {
        _ = NSApplication.shared
        let wasActive = NSApp.isActive
        let state = AppState()
        state.live = .listening(words: 3)
        let controller = LiveTranscriptPanelController(content: LiveTranscriptView().environment(state))
        XCTAssertTrue(controller.panel.styleMask.contains(.nonactivatingPanel))
        XCTAssertTrue(controller.panel.becomesKeyOnlyIfNeeded)
        XCTAssertFalse(controller.panel.hidesOnDeactivate)

        controller.show()
        XCTAssertTrue(controller.isVisible)
        XCTAssertFalse(controller.panel.isKeyWindow)
        XCTAssertEqual(NSApp.isActive, wasActive)

        controller.panel.performClose(nil)
        XCTAssertFalse(controller.isVisible)
        controller.show()
        XCTAssertTrue(controller.isVisible, "the same panel opens again after closing")
        XCTAssertEqual(state.live, .listening(words: 3))
        controller.close()
    }
}
