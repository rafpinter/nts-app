import Foundation
import XCTest

final class NoteFileServiceTests: XCTestCase {
    private var folder: URL!
    private let files = NoteFileService()

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: folder)
    }

    @objc func testTimestampCollisionsNeverOverwrite() throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let first = try files.create(in: folder, now: date)
        let original = Data("Existing note".utf8)
        try original.write(to: first)
        let second = try files.create(in: folder, now: date)
        let third = try files.create(in: folder, now: date)
        XCTAssertNotEqual(first, second)
        XCTAssertTrue(second.lastPathComponent.hasSuffix("-1.md"))
        XCTAssertTrue(third.lastPathComponent.hasSuffix("-2.md"))
        XCTAssertEqual(try Data(contentsOf: first), original)
        XCTAssertEqual(try Data(contentsOf: second), Data())
    }

    @objc func testTitleBecomesPortableFilenameAndCollisionsAreSafe() throws {
        let first = try files.create(in: folder, title: "Café & Groceries!", text: "body")
        let second = try files.create(in: folder, title: "Café & Groceries!", text: "second")
        XCTAssertEqual(first.lastPathComponent, "café-groceries.md")
        XCTAssertEqual(second.lastPathComponent, "café-groceries-1.md")
        XCTAssertEqual(try String(contentsOf: first, encoding: .utf8), "body")
        XCTAssertEqual(try String(contentsOf: second, encoding: .utf8), "second")
    }

    @objc func testUnicodeMarkdownRoundTrip() throws {
        let url = try files.create(in: folder)
        let birthDate = Date(timeIntervalSince1970: 1_000)
        try FileManager.default.setAttributes([.creationDate: birthDate], ofItemAtPath: url.path)
        let text = "# Café ☕️\n\n日本語 — مرحبا\n`let value = 42`\n"
        let saved = try files.save(text, to: url, expected: Data())
        let opened = try files.read(url)
        XCTAssertEqual(opened.text, text)
        XCTAssertEqual(opened.data, saved)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), text)
        let after = try URL(fileURLWithPath: url.path).resourceValues(forKeys: [.creationDateKey])
        XCTAssertEqual(after.creationDate, birthDate, "Saving should preserve creation order")
    }

    @objc func testExternalEditBlocksSaveAndDelete() throws {
        let url = try files.create(in: folder)
        let external = Data("Changed in another editor".utf8)
        try external.write(to: url)
        XCTAssertThrowsError(try files.save("Unsaved draft", to: url, expected: Data())) {
            XCTAssertTrue($0 is NoteFileError)
        }
        XCTAssertThrowsError(try files.trash(url, expected: Data()))
        XCTAssertEqual(try Data(contentsOf: url), external)
    }

    @objc func testMissingFileIsNotRecreatedOnSave() throws {
        let url = try files.create(in: folder)
        try FileManager.default.removeItem(at: url)
        XCTAssertThrowsError(try files.save("Draft", to: url, expected: Data()))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    @objc func testListingFiltersAndSorts() throws {
        let older = folder.appendingPathComponent("older.md")
        let newer = folder.appendingPathComponent("newer.MD")
        try Data().write(to: older)
        try Data().write(to: newer)
        try FileManager.default.setAttributes([.creationDate: Date(timeIntervalSince1970: 1_000)],
                                              ofItemAtPath: older.path)
        try FileManager.default.setAttributes([.creationDate: Date(timeIntervalSince1970: 2_000)],
                                              ofItemAtPath: newer.path)
        try Data().write(to: folder.appendingPathComponent("ignored.txt"))
        try Data().write(to: folder.appendingPathComponent(".hidden.md"))
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("nested.md"),
                                                withIntermediateDirectories: false)
        let link = folder.appendingPathComponent("link.md")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: older)
        XCTAssertEqual(try files.list(in: folder).map(\.name), ["newer.MD", "older.md"])
        XCTAssertThrowsError(try files.read(link))
    }

    @objc func testRenamePreservesContentsAndCreationDate() throws {
        let url = try files.create(in: folder)
        let data = Data("# Café ☕️".utf8)
        try data.write(to: url)
        let date = Date(timeIntervalSince1970: 1_000)
        try FileManager.default.setAttributes([.creationDate: date], ofItemAtPath: url.path)
        let renamed = try files.rename(url, to: "Meeting 日本語")
        XCTAssertEqual(renamed.lastPathComponent, "Meeting 日本語.md")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(try Data(contentsOf: renamed), data)
        XCTAssertEqual(try renamed.resourceValues(forKeys: [.creationDateKey]).creationDate, date)
        XCTAssertEqual(try files.rename(renamed, to: renamed.lastPathComponent), renamed)
        _ = try files.save("Draft after rename", to: renamed, expected: data)
        XCTAssertEqual(try files.read(renamed).text, "Draft after rename")
    }

    @objc func testRenameCollisionPreservesBothFiles() throws {
        let source = try files.create(in: folder)
        let destination = folder.appendingPathComponent("Existing.md")
        let data = Data("Keep me".utf8)
        try data.write(to: destination)
        XCTAssertThrowsError(try files.rename(source, to: "Existing.md"))
        XCTAssertEqual(try Data(contentsOf: source), Data())
        XCTAssertEqual(try Data(contentsOf: destination), data)
    }

    @objc func testRenameRejectsInvalidNames() throws {
        let source = try files.create(in: folder)
        for name in ["", "   ", ".hidden", "../outside", "nested/name", "bad:name", "bad\u{0}name", "bad\nname"] {
            XCTAssertThrowsError(try files.rename(source, to: name), name)
        }
        XCTAssertEqual(try Data(contentsOf: source), Data())
    }

    @objc func testCaseOnlyRename() throws {
        let source = folder.appendingPathComponent("Title.md")
        try Data("Original".utf8).write(to: source)
        let renamed = try files.rename(source, to: "title.md")
        XCTAssertEqual(try files.list(in: folder).map(\.name), ["title.md"])
        XCTAssertEqual(try files.read(renamed).text, "Original")
    }

    @objc func testCreationDateFallback() {
        let created = Date(timeIntervalSince1970: 100)
        let modified = Date(timeIntervalSince1970: 200)
        XCTAssertEqual(NoteFile.orderingDate(created: created, modified: modified), created)
        XCTAssertEqual(NoteFile.orderingDate(created: nil, modified: modified), modified)
        XCTAssertEqual(NoteFile.orderingDate(created: nil, modified: nil), .distantPast)
    }

    @objc func testInvalidUTF8AndMissingFolderSurfaceErrors() throws {
        let url = folder.appendingPathComponent("binary.md")
        let data = Data([0xFF, 0xFE, 0xFF])
        try data.write(to: url)
        XCTAssertThrowsError(try files.read(url))
        XCTAssertEqual(try Data(contentsOf: url), data)
        let missing = folder.appendingPathComponent("missing")
        XCTAssertThrowsError(try files.list(in: missing))
        XCTAssertThrowsError(try files.create(in: missing))
    }
}

final class DraftTests: XCTestCase {
    @objc func testTitleOnlyDraftSavesToTitleFilename() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        MainActor.assumeIsolated {
            let store = NoteStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
            do { try store.activateFolder(folder) } catch { XCTFail("Unexpected folder error: \(error)") }
            store.title = "My New Note"
            XCTAssertTrue(store.save())
            XCTAssertEqual(store.selected?.lastPathComponent, "my-new-note.md")
            XCTAssertEqual(try? String(contentsOf: XCTUnwrap(store.selected), encoding: .utf8), "")
        }
    }

    @objc func testStartupAndEmptyNewNotesStayInMemory() {
        MainActor.assumeIsolated {
            let store = NoteStore()
            XCTAssertNil(store.selected)
            XCTAssertEqual(store.text, "")
            XCTAssertFalse(store.isDirty)
            XCTAssertTrue(store.save())
            XCTAssertNil(store.folder)
            let identity = store.editorID
            store.create()
            XCTAssertNotEqual(store.editorID, identity)
            XCTAssertNil(store.selected)
            XCTAssertTrue(store.notes.isEmpty)
            store.text = "# Immediate typing ☕️"
            XCTAssertTrue(store.isDirty)
            store.text = ""
            XCTAssertFalse(store.isDirty)
            XCTAssertTrue(store.windowCanClose())
        }
    }

    @objc func testFirstSaveCreatesCompleteDraftWithoutOverwriting() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let files = NoteFileService()
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let first = try files.create(in: folder, now: date, text: "First draft")
        let second = try files.create(in: folder, now: date, text: "# 日本語 ☕️")
        XCTAssertEqual(try files.read(first).text, "First draft")
        XCTAssertEqual(try files.read(second).text, "# 日本語 ☕️")
        XCTAssertNotEqual(first, second)
    }
}

final class AppearanceSettingsTests: XCTestCase {
    @objc func testChangesPersistAndKeepSurfaceValuesIndependent() {
        let name = "AppearanceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppearanceSettings(defaults: defaults)
        settings.headerOpacity = 0.15
        settings.editorOpacity = 0.65
        settings.sidebarOpacity = 0.35
        settings.translucencyEnabled = false
        let restored = AppearanceSettings(defaults: defaults)
        XCTAssertFalse(restored.translucencyEnabled)
        XCTAssertEqual(restored.headerOpacity, 0.15)
        XCTAssertEqual(restored.editorOpacity, 0.65)
        XCTAssertEqual(restored.sidebarOpacity, 0.35)
        XCTAssertEqual(restored.opacity(restored.editorOpacity), 1)
        restored.translucencyEnabled = true
        XCTAssertEqual(restored.opacity(restored.editorOpacity), 0.65)
    }

    @objc func testRestoreDefaultsPersistsFactoryValues() {
        let name = "AppearanceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppearanceSettings(defaults: defaults)
        settings.translucencyEnabled = false
        settings.headerOpacity = 0.75
        settings.editorOpacity = 0.25
        settings.sidebarOpacity = 0.5
        settings.restoreDefaults()
        let restored = AppearanceSettings(defaults: defaults)
        XCTAssertEqual(restored.translucencyEnabled, AppearanceConfiguration.translucencyEnabled)
        XCTAssertEqual(restored.headerOpacity, AppearanceConfiguration.headerTintOpacity)
        XCTAssertEqual(restored.editorOpacity, AppearanceConfiguration.editorTintOpacity)
        XCTAssertEqual(restored.sidebarOpacity, AppearanceConfiguration.sidebarTintOpacity)
    }

    @objc func testInvalidStoredOpacitiesHaveSafeBoundsAndFallbacks() {
        let name = "AppearanceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(-4.0, forKey: "appearance.headerOpacity")
        defaults.set(8.0, forKey: "appearance.editorOpacity")
        defaults.set("invalid", forKey: "appearance.sidebarOpacity")
        let settings = AppearanceSettings(defaults: defaults)
        XCTAssertEqual(settings.headerOpacity, 0)
        XCTAssertEqual(settings.editorOpacity, 1)
        XCTAssertEqual(settings.sidebarOpacity, AppearanceConfiguration.sidebarTintOpacity)
    }
}

let suite = XCTestSuite(name: "Nts")
suite.addTest(WikiRenameTests.defaultTestSuite)
suite.addTest(AppearanceSettingsTests.defaultTestSuite)
suite.addTest(FilenameSuggestionTests.defaultTestSuite)
suite.addTest(NoteIndexTests.defaultTestSuite)
suite.addTest(SQLiteDatabaseTests.defaultTestSuite)
suite.addTest(EmbeddingRepositoryTests.defaultTestSuite)
suite.addTest(NoteProjectionTests.defaultTestSuite)
suite.addTest(NoteMapTests.defaultTestSuite)
suite.addTest(LocalMLXResourceGateTests.defaultTestSuite)
suite.addTest(NoteEmbeddingControllerTests.defaultTestSuite)
suite.addTest(DraftTests.defaultTestSuite)
suite.addTest(NoteFileServiceTests.defaultTestSuite)
suite.addTest(NoteNavigationTests.defaultTestSuite)
suite.addTest(NativeEditorTests.defaultTestSuite)
suite.addTest(AutosaveTests.defaultTestSuite)
suite.addTest(ImageAssetTests.defaultTestSuite)
suite.addTest(ImageInsertionTests.defaultTestSuite)
suite.addTest(LiveMarkdownTests.defaultTestSuite)
suite.addTest(LocalMarkdownImageTests.defaultTestSuite)
suite.run()
guard let run = suite.testRun, run.executionCount == suite.testCaseCount, run.hasSucceeded else {
    exit(1)
}
