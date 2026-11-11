import Foundation
import XCTest

final class NoteNavigationTests: XCTestCase {
    @objc @MainActor func testWikiLinkOpensExistingNoteAndSavesCurrentDraft() throws {
        let folder = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = folder.appendingPathComponent("First.md")
        let second = folder.appendingPathComponent("Café 👩‍💻.md")
        try Data("first".utf8).write(to: first)
        try Data("second".utf8).write(to: second)
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = NoteStore(defaults: defaults)
        try store.activateFolder(folder)
        store.open(first)
        store.text = "Draft with [[Café 👩‍💻]]"
        store.openWikiLink("Café 👩‍💻")
        XCTAssertEqual(store.selected?.resolvingSymlinksInPath(), second.resolvingSymlinksInPath())
        XCTAssertEqual(store.text, "second")
        XCTAssertEqual(try String(contentsOf: first, encoding: .utf8), "Draft with [[Café 👩‍💻]]")
        store.openWikiLink("First.md")
        XCTAssertEqual(store.selected?.resolvingSymlinksInPath(), first.resolvingSymlinksInPath())
        store.openWikiLink("café 👩‍💻")
        XCTAssertEqual(store.selected?.resolvingSymlinksInPath(), second.resolvingSymlinksInPath())
        let originalCount = store.notes.count
        store.openWikiLink("Missing")
        XCTAssertEqual(store.selected?.resolvingSymlinksInPath(), second.resolvingSymlinksInPath())
        XCTAssertNotNil(store.errorMessage)
        XCTAssertEqual(try NoteFileService().list(in: folder).count, originalCount)
        store.openWikiLink("../outside.md")
        XCTAssertEqual(store.selected?.resolvingSymlinksInPath(), second.resolvingSymlinksInPath())
    }

    private let notes = ["newest", "middle", "oldest"].map {
        URL(fileURLWithPath: "/tmp/\($0).md")
    }

    @objc @MainActor func testSidebarDeleteUndoPreservesDraftAndRefusesOverwrite() throws {
        let folder = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let store = NoteStore(defaults: defaults, trashNote: { url, expected in
            XCTAssertEqual(try Data(contentsOf: url), expected)
            try FileManager.default.removeItem(at: url)
        })
        let url = folder.appendingPathComponent("note.md")
        try Data("saved".utf8).write(to: url)
        try store.activateFolder(folder)
        store.open(url)
        store.text = "unsaved draft"
        store.deleteFromSidebar()
        XCTAssertNil(store.selected)
        XCTAssertTrue(store.notes.isEmpty)
        try Data("external file".utf8).write(to: url)
        store.restoreDeletedNote()
        XCTAssertNotNil(store.errorMessage)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "external file")
        try FileManager.default.removeItem(at: url)
        store.errorMessage = nil
        store.restoreDeletedNote()
        XCTAssertEqual(store.selected, url)
        XCTAssertEqual(store.text, "unsaved draft")
        XCTAssertTrue(store.isDirty)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "saved")
        XCTAssertNil(store.errorMessage)
    }

    @objc @MainActor func testFailedSidebarDeleteKeepsNoteAndDraft() throws {
        let folder = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = NoteStore(defaults: UserDefaults(suiteName: UUID().uuidString)!,
                              trashNote: { _, _ in throw NoteFileError.changedOnDisk })
        let url = folder.appendingPathComponent("note.md")
        try Data("saved".utf8).write(to: url)
        try store.activateFolder(folder)
        store.open(url)
        store.text = "draft"
        store.deleteFromSidebar()
        XCTAssertEqual(store.selected, url)
        XCTAssertEqual(store.text, "draft")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertNotNil(store.errorMessage)
    }

    @objc @MainActor func testSidebarRestoresMultipleDeletesInReverseOrder() throws {
        let folder = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = NoteStore(defaults: UserDefaults(suiteName: UUID().uuidString)!,
                              trashNote: { url, _ in try FileManager.default.removeItem(at: url) })
        let first = folder.appendingPathComponent("first.md")
        let second = folder.appendingPathComponent("second.md")
        try Data("first".utf8).write(to: first)
        try Data("second".utf8).write(to: second)
        try store.activateFolder(folder)
        store.open(first)
        store.deleteFromSidebar()
        XCTAssertEqual(store.selected?.resolvingSymlinksInPath().path, second.resolvingSymlinksInPath().path)
        store.deleteFromSidebar()
        XCTAssertTrue(store.notes.isEmpty)
        store.restoreDeletedNote()
        XCTAssertEqual(store.selected?.resolvingSymlinksInPath().path, second.resolvingSymlinksInPath().path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path))
        store.restoreDeletedNote()
        XCTAssertEqual(store.selected, first)
        XCTAssertEqual(store.notes.count, 2)
        store.restoreDeletedNote()
        XCTAssertEqual(store.selected, first)
    }

    @objc func testMovesBetweenNeighborsWithoutWrapping() {
        XCTAssertEqual(NoteNavigation.target(in: notes, selected: notes[1], direction: .previous), notes[0])
        XCTAssertEqual(NoteNavigation.target(in: notes, selected: notes[1], direction: .next), notes[2])
        XCTAssertNil(NoteNavigation.target(in: notes, selected: notes[0], direction: .previous))
        XCTAssertNil(NoteNavigation.target(in: notes, selected: notes[2], direction: .next))
    }

    @objc func testNoSelectionOrMissingSelectionStartsAtFirstNote() {
        let missing = URL(fileURLWithPath: "/tmp/removed.md")
        for direction in [NoteNavigation.Direction.previous, .next] {
            XCTAssertEqual(NoteNavigation.target(in: notes, selected: nil, direction: direction), notes[0])
            XCTAssertEqual(NoteNavigation.target(in: notes, selected: missing, direction: direction), notes[0])
        }
    }

    @objc func testEmptyAndSingleNoteLists() {
        XCTAssertNil(NoteNavigation.target(in: [], selected: nil, direction: .next))
        XCTAssertNil(NoteNavigation.target(in: [notes[0]], selected: notes[0], direction: .next))
        XCTAssertNil(NoteNavigation.target(in: [notes[0]], selected: notes[0], direction: .previous))
    }
}
