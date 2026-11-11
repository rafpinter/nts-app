import AppKit
import XCTest

final class AutosaveTests: XCTestCase {
    @MainActor private final class Fixture {
        let folder: URL
        let suite = UUID().uuidString
        let defaults: UserDefaults
        let store: NoteStore

        init(enabled: Bool = true, activate: Bool = true, delay: UInt64 = 40_000_000) throws {
            folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defaults = UserDefaults(suiteName: suite)!
            defaults.set(enabled, forKey: "notes.autosaveEnabled")
            store = NoteStore(defaults: defaults, autosaveDelayNanoseconds: delay)
            if activate { try store.activateFolder(folder) }
        }

        func cleanup() {
            store.autosaveEnabled = false
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: folder)
        }

        func note(_ name: String = "Existing.md") throws -> URL {
            let url = folder.appendingPathComponent(name)
            try Data("saved".utf8).write(to: url)
            store.open(url)
            return url
        }
    }

    private func runAsync(_ body: @escaping @MainActor () async throws -> Void) {
        let finished = expectation(description: "Autosave completed")
        Task.detached {
            do { try await body() }
            catch { XCTFail("Unexpected error: \(error)") }
            finished.fulfill()
        }
        wait(for: [finished], timeout: 10)
    }

    @objc func testAutosaveIsEnabledByDefaultAndPreferencePersists() {
        MainActor.assumeIsolated {
            let suite = UUID().uuidString
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let store = NoteStore(defaults: defaults)
            XCTAssertTrue(store.autosaveEnabled)
            store.autosaveEnabled = true
            XCTAssertTrue(NoteStore(defaults: defaults).autosaveEnabled)
            store.autosaveEnabled = false
            XCTAssertFalse(NoteStore(defaults: defaults).autosaveEnabled)
        }
    }

    @objc func testAutosaveDebouncesEditsAndPreservesFilenameAndSession() {
        runAsync {
            let fixture = try Fixture(delay: 120_000_000)
            defer { fixture.cleanup() }
            let store = fixture.store
            let url = try fixture.note()
            let editorID = store.editorID
            var saves = 0
            store.onSaved = { _ in saves += 1 }
            store.text = "first edit"
            try await Task.sleep(nanoseconds: 60_000_000)
            XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "saved")
            store.text = "final Café 👩‍💻"
            try await Task.sleep(nanoseconds: 80_000_000)
            XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "saved")
            try await Task.sleep(nanoseconds: 160_000_000)
            XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "final Café 👩‍💻")
            XCTAssertEqual(store.selected, url)
            XCTAssertEqual(store.editorID, editorID)
            XCTAssertFalse(store.isDirty)
            XCTAssertEqual(saves, 1)
        }
    }

    @objc func testNewDraftWaitsForFolderAndEmptyDraftDoesNotCreateFile() {
        runAsync {
            let fixture = try Fixture(activate: false)
            defer { fixture.cleanup() }
            let store = fixture.store
            store.text = "unsaved draft"
            try await Task.sleep(nanoseconds: 120_000_000)
            XCTAssertNil(store.selected)
            XCTAssertNil(store.folder)
            XCTAssertNil(store.errorMessage)
            try store.activateFolder(fixture.folder)
            try await Task.sleep(nanoseconds: 120_000_000)
            let url = try XCTUnwrap(store.selected)
            XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "unsaved draft")
            XCTAssertEqual(url.pathExtension, "md")
            store.create()
            try await Task.sleep(nanoseconds: 120_000_000)
            XCTAssertNil(store.selected)
            XCTAssertEqual(try NoteFileService().list(in: fixture.folder).count, 1)
        }
    }

    @objc func testDisablingCancelsPendingSaveAndEnablingSavesDirtyNote() {
        runAsync {
            let fixture = try Fixture()
            defer { fixture.cleanup() }
            let store = fixture.store
            let url = try fixture.note()
            store.text = "draft"
            store.autosaveEnabled = false
            try await Task.sleep(nanoseconds: 120_000_000)
            XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "saved")
            XCTAssertTrue(store.isDirty)
            store.autosaveEnabled = true
            try await Task.sleep(nanoseconds: 120_000_000)
            XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "draft")
        }
    }

    @objc func testAutosavePreservesExternalChangesAndReportsFailureOnce() {
        runAsync {
            let fixture = try Fixture()
            defer { fixture.cleanup() }
            let store = fixture.store
            let url = try fixture.note()
            store.text = "my draft"
            try Data("external changes".utf8).write(to: url)
            try await Task.sleep(nanoseconds: 120_000_000)
            XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "external changes")
            XCTAssertEqual(store.text, "my draft")
            XCTAssertTrue(store.isDirty)
            XCTAssertNotNil(store.errorMessage)
            store.errorMessage = nil
            try await Task.sleep(nanoseconds: 120_000_000)
            XCTAssertNil(store.errorMessage, "A failed autosave must not retry repeatedly without another edit")
        }
    }

    @objc func testNavigationAndExplicitSaveCancelStaleAutosaves() {
        runAsync {
            let fixture = try Fixture()
            defer { fixture.cleanup() }
            let store = fixture.store
            let first = try fixture.note("First.md")
            let second = fixture.folder.appendingPathComponent("Second.md")
            try Data("second".utf8).write(to: second)
            var saves = 0
            store.onSaved = { _ in saves += 1 }
            store.text = "first draft"
            store.open(second)
            try await Task.sleep(nanoseconds: 120_000_000)
            XCTAssertEqual(try String(contentsOf: first, encoding: .utf8), "first draft")
            XCTAssertEqual(try String(contentsOf: second, encoding: .utf8), "second")
            XCTAssertEqual(saves, 1)
            store.text = "second draft"
            XCTAssertTrue(store.save())
            try await Task.sleep(nanoseconds: 120_000_000)
            XCTAssertEqual(saves, 2)
            XCTAssertFalse(store.isDirty)
        }
    }

    @objc func testAutosaveWaitsForInputMethodComposition() {
        runAsync {
            let fixture = try Fixture()
            defer { fixture.cleanup() }
            let store = fixture.store
            let url = try fixture.note()
            let editor = store.editorSession.textView(for: store.text)
            editor.isRichText = false
            editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
            editor.setMarkedText("に", selectedRange: NSRange(location: 1, length: 0), replacementRange: editor.selectedRange())
            XCTAssertTrue(editor.hasMarkedText())
            store.text = editor.string
            try await Task.sleep(nanoseconds: 120_000_000)
            XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "saved")
            editor.unmarkText()
            try await Task.sleep(nanoseconds: 120_000_000)
            XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), editor.string)
            XCTAssertFalse(store.isDirty)
        }
    }
}
