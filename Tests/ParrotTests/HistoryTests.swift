import Carbon.HIToolbox
import XCTest
@testable import ParrotCore

final class TranscriptHistoryTests: XCTestCase {
    private var dir: URL!
    private var file: URL!
    private var logged: [String] = []

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("parrot-history-\(UUID().uuidString)", isDirectory: true)
        file = dir.appendingPathComponent("history.json")
        logged = []
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func history(enabled: Bool = true, limit: Int = TranscriptHistory.limit) -> TranscriptHistory {
        TranscriptHistory(file: file, enabled: enabled, limit: limit, log: { [unowned self] in self.logged.append($0) })
    }

    private func mode(_ url: URL) throws -> Int {
        try (FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int) ?? -1
    }

    func testRecordsNewestFirstAndSurvivesARestart() {
        let first = history()
        first.record("one")
        first.record("two")
        XCTAssertEqual(first.entries, ["two", "one"])
        XCTAssertEqual(first.last, "two")
        XCTAssertEqual(history().entries, ["two", "one"])
    }

    func testKeepsOnlyTheLimit() {
        let history = history(limit: 3)
        for n in 1...5 { history.record("\(n)") }
        XCTAssertEqual(history.entries, ["5", "4", "3"])
        XCTAssertEqual(self.history(limit: 3).entries, ["5", "4", "3"])
    }

    func testDefaultLimitIsTwenty() {
        let history = history()
        for n in 1...25 { history.record("\(n)") }
        XCTAssertEqual(history.entries.count, 20)
        XCTAssertEqual(history.entries.first, "25")
    }

    func testBlankTextIsIgnored() {
        let history = history()
        history.record("")
        history.record("  \n")
        XCTAssertTrue(history.entries.isEmpty)
        XCTAssertNil(Paths.fileType(file.path))
    }

    func testFileAndDirectoryAreOwnerOnly() throws {
        history().record("secret-ish")
        XCTAssertEqual(try mode(file), 0o600)
        XCTAssertEqual(try mode(dir), 0o700)
        // No temporary file left beside it.
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), ["history.json"])
    }

    func testFileHoldsTextOnly() throws {
        history().record("hello there")
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any]
        XCTAssertEqual(Set(json?.keys.map { $0 } ?? []), ["version", "transcripts"])
        XCTAssertEqual(json?["transcripts"] as? [String], ["hello there"])
    }

    func testOffKeepsOnlyTheLastInMemoryAndDeletesTheFile() {
        let history = history()
        history.record("one")
        history.record("two")
        history.setEnabled(false)
        XCTAssertEqual(history.entries, ["two"])
        XCTAssertNil(Paths.fileType(file.path))

        history.record("three")
        XCTAssertEqual(history.entries, ["three"])
        XCTAssertEqual(history.last, "three")
        XCTAssertNil(Paths.fileType(file.path))
    }

    func testStartingOffDeletesALeftoverFileAndReadsNothing() {
        history().record("left over")
        let off = history(enabled: false)
        XCTAssertTrue(off.entries.isEmpty)
        XCTAssertNil(Paths.fileType(file.path))
    }

    func testTurningOnWritesWhatIsInMemory() {
        let history = history(enabled: false)
        history.record("kept")
        history.setEnabled(true)
        XCTAssertEqual(self.history().entries, ["kept"])
    }

    func testClearForgetsMemoryAndDisk() {
        let history = history()
        history.record("one")
        history.clear()
        XCTAssertTrue(history.entries.isEmpty)
        XCTAssertNil(history.last)
        XCTAssertNil(Paths.fileType(file.path))
    }

    func testCorruptFileStartsEmptyWithoutLoggingItsContents() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("not json: my bank PIN".utf8).write(to: file)
        XCTAssertTrue(history().entries.isEmpty)
        XCTAssertEqual(logged.count, 1)
        XCTAssertFalse(logged.joined().contains("PIN"))
    }

    func testSymlinkIsNotReadOrWrittenThrough() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let target = dir.appendingPathComponent("elsewhere.json")
        try Data(#"{"version":1,"transcripts":["planted"]}"#.utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)

        let history = history()
        XCTAssertTrue(history.entries.isEmpty)
        history.record("mine")
        // The link was replaced, not followed.
        XCTAssertEqual(Paths.fileType(file.path), .typeRegular)
        XCTAssertEqual(try String(contentsOf: target), #"{"version":1,"transcripts":["planted"]}"#)
    }

    func testLooseFileIsTightenedOnLoad() throws {
        history().record("one")
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        XCTAssertEqual(history().entries, ["one"])
        XCTAssertEqual(try mode(file), 0o600)
    }
}

final class KeyComboTests: XCTestCase {
    func testDefaultIsOptionCommandV() {
        let combo = KeyCombo.defaultPasteLast
        XCTAssertEqual(combo.name, "option+command+v")
        XCTAssertEqual(combo.displayName, "⌥⌘V")
        XCTAssertEqual(combo.keyCode, UInt32(kVK_ANSI_V))
        XCTAssertEqual(combo.carbonModifiers, UInt32(optionKey | cmdKey))
    }

    /// Josh dictates by holding left Control; the default must not use it.
    func testDefaultLeavesControlAlone() {
        XCTAssertFalse(KeyCombo.defaultPasteLast.modifiers.contains(.control))
    }

    func testParsesAliasesCaseAndSpacesInAnyModifierOrder() {
        XCTAssertEqual(KeyCombo("Cmd + Opt + V"), .defaultPasteLast)
        XCTAssertEqual(KeyCombo("command+alt+v"), .defaultPasteLast)
        XCTAssertEqual(KeyCombo("⌥+⌘+v"), .defaultPasteLast)
        XCTAssertEqual(KeyCombo("ctrl+shift+cmd+1")?.displayName, "⌃⇧⌘1")
        XCTAssertEqual(KeyCombo("ctrl+shift+cmd+1")?.name, "control+shift+command+1")
    }

    func testNameRoundTrips() {
        for combo in KeyCombo.pasteLastChoices {
            XCTAssertEqual(KeyCombo(combo.name), combo)
        }
    }

    func testRejectsCombosThatWouldSwallowTyping() {
        XCTAssertNil(KeyCombo("v"))
        XCTAssertNil(KeyCombo("shift+v"))
    }

    func testRejectsMalformedCombos() {
        XCTAssertNil(KeyCombo("command+option"))
        XCTAssertNil(KeyCombo("command+f5"))
        XCTAssertNil(KeyCombo("hyper+v"))
        XCTAssertNil(KeyCombo("command+command+v"))
        XCTAssertNil(KeyCombo("command+v+b"))
    }

    func testOff() {
        XCTAssertTrue(KeyCombo.isOff("off"))
        XCTAssertTrue(KeyCombo.isOff(" OFF "))
        XCTAssertTrue(KeyCombo.isOff(""))
        XCTAssertNil(KeyCombo("off"))
        XCTAssertFalse(KeyCombo.isOff("option+command+v"))
    }
}

final class HistorySettingsTests: XCTestCase {
    private func decode(_ json: String) throws -> Settings {
        try JSONDecoder().decode(Settings.self, from: Data(json.utf8))
    }

    func testDefaultsToOnWithOptionCommandV() throws {
        let history = try decode("{}").history
        XCTAssertTrue(history.enabled)
        XCTAssertEqual(history.pasteLastHotkey, "option+command+v")
    }

    func testDecodes() throws {
        let history = try decode(#"{"history": {"enabled": false, "pasteLastHotkey": "off"}}"#).history
        XCTAssertFalse(history.enabled)
        XCTAssertEqual(history.pasteLastHotkey, "off")
    }

    func testPartialObjectKeepsDefaults() throws {
        XCTAssertEqual(try decode(#"{"history": {"enabled": false}}"#).history.pasteLastHotkey, "option+command+v")
    }
}

final class RecentMenuTests: XCTestCase {
    func testTitleIsOneLine() {
        XCTAssertEqual(RecentMenu.title("first line\nsecond\tline  here"), "first line second line here")
    }

    func testLongTitleIsCut() {
        let title = RecentMenu.title(String(repeating: "a", count: 200))
        XCTAssertEqual(title.count, RecentMenu.titleLength)
        XCTAssertTrue(title.hasSuffix("…"))
    }

    func testShortTitleIsKept() {
        XCTAssertEqual(RecentMenu.title("hello"), "hello")
    }
}

final class TranscriptHistoryTempFileTests: XCTestCase {
    func testLeftoverTempFileIsRemovedAtStartAndOnClear() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("parrot-history-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("history.json")
        let temp = dir.appendingPathComponent(".history.json.tmp")

        try Data("crashed mid-save".utf8).write(to: temp)
        let history = TranscriptHistory(file: file, enabled: true, log: { _ in })
        XCTAssertNil(Paths.fileType(temp.path))

        try Data("crashed again".utf8).write(to: temp)
        history.clear()
        XCTAssertNil(Paths.fileType(temp.path))
    }
}
