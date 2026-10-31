import XCTest
@testable import EchoPadKit

final class ClaudeSorterTests: XCTestCase {
    private var root: URL!
    private let sorter = ClaudeSorter()

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        for folder in ["Inbox", "TapIn/Daily", "TapIn/Ad hoc", "Clients/CBM/2026", ".obsidian", ".meetings"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testFoldersSkipHiddenInboxAndDeepLevels() {
        let folders = sorter.folders(in: root, excluding: root.appendingPathComponent("Inbox"))
        XCTAssertEqual(folders, ["Clients", "Clients/CBM", "TapIn", "TapIn/Ad hoc", "TapIn/Daily"])
    }

    func testRulesRelativeToRoot() throws {
        try "TapIn daily is at 17:00".write(to: root.appendingPathComponent(".meetings/sorter.md"), atomically: true, encoding: .utf8)
        XCTAssertEqual(sorter.rules(at: ".meetings/sorter.md", root: root), "TapIn daily is at 17:00")
        XCTAssertEqual(sorter.rules(at: "missing.md", root: root), "")
        XCTAssertEqual(sorter.rules(at: "", root: root), "")
    }

    func testRequestUsesFolderEnum() throws {
        let body = ClaudeSorter.requestBody(transcript: "hi", recordedAt: Date(), app: "Zoom",
                                            folders: ["TapIn/Daily"], rules: "")
        let config = try XCTUnwrap(body["output_config"] as? [String: Any])
        let format = try XCTUnwrap(config["format"] as? [String: Any])
        let schema = try XCTUnwrap(format["schema"] as? [String: Any])
        let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
        let folder = try XCTUnwrap(properties["folder"] as? [String: Any])
        XCTAssertEqual(folder["enum"] as? [String], [ClaudeSorter.STAY, "TapIn/Daily"])
        XCTAssertNil(body["temperature"])
    }

    func testParseReadsTextBlockAndRejectsUnknownFolder() throws {
        func response(_ decision: String) -> Data {
            let json: [String: Any] = ["stop_reason": "end_turn",
                                       "content": [["type": "thinking", "thinking": ""], ["type": "text", "text": decision]]]
            return try! JSONSerialization.data(withJSONObject: json)
        }
        let good = try ClaudeSorter.parse(response(#"{"folder":"TapIn/Daily","title":"Daily","summary":"S","confident":true}"#),
                                          folders: ["TapIn/Daily"])
        XCTAssertEqual(good.folder, "TapIn/Daily")
        XCTAssertThrowsError(try ClaudeSorter.parse(response(#"{"folder":"Nope","title":"T","summary":"S","confident":true}"#),
                                                    folders: ["TapIn/Daily"]))
        XCTAssertThrowsError(try ClaudeSorter.parse(response(#"{"folder":"TapIn/Daily","title":"T"}"#),
                                                    folders: ["TapIn/Daily"]))
    }

    func testValidateCleansAndReportsEveryIssue() throws {
        let cleaned = try ClaudeSorter.validate(
            .init(folder: "TapIn/Daily", title: "  Daily\nsync ", summary: "Line one.\nLine two.", confident: true),
            folders: ["TapIn/Daily"])
        XCTAssertEqual(cleaned.title, "Daily sync")
        XCTAssertEqual(cleaned.summary, "Line one. Line two.")

        let bad = ClaudeSorter.Decision(folder: "Nope", title: " ", summary: String(repeating: "x", count: 700), confident: true)
        XCTAssertThrowsError(try ClaudeSorter.validate(bad, folders: ["TapIn/Daily"])) { error in
            guard case .invalidDecision(let issues) = error as? ClaudeSorter.Failure else { return XCTFail("\(error)") }
            XCTAssertEqual(issues.count, 3)
        }
    }

    func testParseFailsOnRefusal() {
        let data = try! JSONSerialization.data(withJSONObject: ["stop_reason": "refusal", "content": []])
        XCTAssertThrowsError(try ClaudeSorter.parse(data, folders: []))
    }

    func testFileMovesRenamesAndAddsFrontMatter() throws {
        let note = root.appendingPathComponent("Inbox/2026-10-31 10.00 - Zoom.md")
        try "---\ndate: 2026-10-31\n---\n\nHello".write(to: note, atomically: true, encoding: .utf8)
        let decision = ClaudeSorter.Decision(folder: "TapIn/Daily", title: "Daily", summary: #"Release "flags""#, confident: true)

        let moved = try sorter.file([note], decision: decision, root: root, newBaseName: "2026-10-31 10.00 - Daily")

        XCTAssertEqual(moved.map(\.path), [root.appendingPathComponent("TapIn/Daily/2026-10-31 10.00 - Daily.md").path])
        XCTAssertFalse(FileManager.default.fileExists(atPath: note.path))
        let text = try String(contentsOf: moved[0], encoding: .utf8)
        XCTAssertEqual(text, "---\nsummary: \"Release \\\"flags\\\"\"\nfolder: \"TapIn/Daily\"\ndate: 2026-10-31\n---\n\nHello")
    }

    func testUnsureNoteIsFiledAndMarkedForReview() throws {
        let note = root.appendingPathComponent("Inbox/a.md")
        try "Hello".write(to: note, atomically: true, encoding: .utf8)
        let decision = ClaudeSorter.Decision(folder: "TapIn/Daily", title: "T", summary: "S", confident: false)

        let moved = try sorter.file([note], decision: decision, root: root, newBaseName: "b")

        XCTAssertEqual(moved[0].deletingLastPathComponent().lastPathComponent, "Daily")
        XCTAssertTrue(try String(contentsOf: moved[0], encoding: .utf8).contains("review: true"))
    }

    func testStayLeavesNoteInInbox() throws {
        let note = root.appendingPathComponent("Inbox/a.md")
        try "Hello".write(to: note, atomically: true, encoding: .utf8)
        let decision = ClaudeSorter.Decision(folder: ClaudeSorter.STAY, title: "Mic test", summary: "S", confident: true)

        let moved = try sorter.file([note], decision: decision, root: root, newBaseName: "b")

        XCTAssertEqual(moved[0].deletingLastPathComponent().lastPathComponent, "Inbox")
        XCTAssertTrue(try String(contentsOf: moved[0], encoding: .utf8).contains("review: true"))
    }
}
