import AppKit
import XCTest

final class WikiRenameTests: XCTestCase {
    private var root: URL!
    private var folder: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        folder = root.appendingPathComponent("notes")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    @discardableResult private func write(_ name: String, _ text: String) throws -> URL {
        let url = folder.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url
    }
    private func read(_ name: String) throws -> String {
        try String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8)
    }
    private var coordinator: WikiRenameCoordinator {
        WikiRenameCoordinator(recoveryRoot: root.appendingPathComponent("recovery"))
    }

    @objc func testSyntaxAndResolution() throws {
        let text = "😀 [[ Old |label]] [[old.md]]\r\n`[[Old]]` \\[[Old]] ![[Old]]\n```\n[[Old]]\n```\n[[Old#heading]]"
        let edits = try WikiLinks.edits(in: text, old: "Old.md", new: "日本語.md", names: ["Old.md"])
        XCTAssertEqual(edits.count, 2)
        XCTAssertTrue(WikiLinks.occurrences(in: "    [[Old]]\n`multi\n[[Old]]\nline`").isEmpty)
        XCTAssertEqual(WikiLinkEdit.applying(edits, to: text), "😀 [[ 日本語 |label]] [[日本語.md]]\r\n`[[Old]]` \\[[Old]] ![[Old]]\n```\n[[Old]]\n```\n[[Old#heading]]")
        XCTAssertEqual(WikiLinks.matches("OLD", names: ["Old.md", "old.md"]).count, 2)
        XCTAssertTrue(try WikiLinks.edits(in: "[[OLD]]", old: "Old.md", new: "New.md", names: ["Old.md", "old.md"]).isEmpty)
        XCTAssertThrowsError(try WikiLinks.edits(in: "[[Old]]", old: "Old.md", new: "a|b.md", names: ["Old.md"]))
    }

    @objc func testRenameSelfLinksAndReferences() throws {
        let old = try write("Old.md", "[[Old|self]]")
        try write("Other.md", "[[Old]] and [[Old.md|alias]]")
        let plan = try WikiRenamePlan.prepare(old, name: "New", expected: nil)
        try coordinator.execute(plan)
        XCTAssertEqual(try read("New.md"), "[[New|self]]")
        XCTAssertEqual(try read("Other.md"), "[[New]] and [[New.md|alias]]")
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        try coordinator.recover(folder: folder)
    }

    @objc func testRollbackAtEveryMutation() throws {
        let old = try write("Old.md", "[[Old]]")
        try write("Other.md", "[[Old]]")
        let plan = try WikiRenamePlan.prepare(old, name: "New", expected: nil)
        for failure in 0...plan.changes.count {
            var operation = coordinator
            operation.checkpoint = { if $0 == failure { throw WikiRenameError.message("Injected") } }
            XCTAssertThrowsError(try operation.execute(plan))
            XCTAssertEqual(try read("Old.md"), "[[Old]]")
            XCTAssertEqual(try read("Other.md"), "[[Old]]")
            XCTAssertFalse(FileManager.default.fileExists(atPath: plan.destination.path))
        }
    }

    @objc func testCaseOnlyRenameRollbackRestoresSpelling() throws {
        let old = try write("Old.md", "[[Old]]")
        let plan = try WikiRenamePlan.prepare(old, name: "old", expected: nil)
        var operation = coordinator
        operation.checkpoint = { _ in throw WikiRenameError.message("Injected") }
        XCTAssertThrowsError(try operation.execute(plan))
        XCTAssertEqual(try NoteFileService().list(in: folder).map(\.name), ["Old.md"])
        XCTAssertEqual(try read("Old.md"), "[[Old]]")
    }

    @objc func testRestartAtEachUncommittedStage() throws {
        let old = try write("Old.md", "[[Old]]")
        try write("Other.md", "[[Old]]")
        let plan = try WikiRenamePlan.prepare(old, name: "New", expected: nil)
        let operation = coordinator
        try FileManager.default.createDirectory(at: operation.recoveryRoot, withIntermediateDirectories: true)
        for completedWrites in -1...plan.changes.count {
            try JSONEncoder().encode(plan).write(to: operation.journal(folder), options: .atomic)
            if completedWrites >= 0 {
                _ = try NoteFileService().rename(old, to: plan.new, expected: plan.source)
                for change in plan.changes.prefix(completedWrites) {
                    let name = change.name == plan.old ? plan.new : change.name
                    _ = try write(name, String(decoding: change.after, as: UTF8.self))
                }
            }
            try coordinator.recover(folder: folder)
            XCTAssertEqual(try read("Old.md"), "[[Old]]")
            XCTAssertEqual(try read("Other.md"), "[[Old]]")
            XCTAssertFalse(FileManager.default.fileExists(atPath: plan.destination.path))
        }
    }

    @objc func testExternalChangesArePreservedAndRecoveryCanRetry() throws {
        let old = try write("Old.md", "body")
        try write("Other.md", "[[Old]]")
        let plan = try WikiRenamePlan.prepare(old, name: "New", expected: nil)
        var operation = coordinator
        operation.checkpoint = { step in
            if step == 1 {
                try self.write("Other.md", "external")
                throw WikiRenameError.message("Injected")
            }
        }
        XCTAssertThrowsError(try operation.execute(plan))
        XCTAssertEqual(try read("Other.md"), "external")
        XCTAssertEqual(try read("New.md"), "body")
        // Restore the operation's output, then restart recovery using a fresh coordinator.
        try write("Other.md", "[[New]]")
        try coordinator.recover(folder: folder)
        XCTAssertEqual(try read("Old.md"), "body")
        XCTAssertEqual(try read("Other.md"), "[[Old]]")
    }

    @objc func testStaleScanAndCollisionDoNotWrite() throws {
        let old = try write("Old.md", "body")
        let plan = try WikiRenamePlan.prepare(old, name: "New", expected: nil)
        try write("Later.md", "[[Old]]")
        XCTAssertThrowsError(try coordinator.execute(plan))
        XCTAssertEqual(try read("Later.md"), "[[Old]]")
        try write("New.md", "existing")
        XCTAssertThrowsError(try WikiRenamePlan.prepare(old, name: "New", expected: nil))
        XCTAssertEqual(try read("New.md"), "existing")
        XCTAssertEqual(try read("Old.md"), "body")
    }

    @objc func testSessionUndoAndDirtySelfLink() throws {
        try MainActor.assumeIsolated {
            let name = "WikiTests.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: name)!
            defer { defaults.removePersistentDomain(forName: name) }
            defaults.set(false, forKey: "notes.autosaveEnabled")
            let store = NoteStore(defaults: defaults)
            let old = try write("Old.md", "body")
            let other = try write("Other.md", "😀 [[Old]]")
            try store.activateFolder(folder)
            store.open(other)
            let session = store.editorSession
            let view = session.textView(for: store.text)
            view.allowsUndo = true
            view.setSelectedRange(NSRange(location: 10, length: 0))
            try store.rename(old, to: "Longer")
            XCTAssertEqual(view.string, "😀 [[Longer]]")
            XCTAssertEqual(view.selectedRange().location, 13)
            XCTAssertFalse(store.isDirty)
            view.undoManager?.undo()
            XCTAssertEqual(view.string, "😀 [[Old]]")
            store.text = view.string
            XCTAssertTrue(store.isDirty)
            XCTAssertTrue(store.save())
            XCTAssertEqual(try read("Other.md"), "😀 [[Old]]")
            store.open(folder.appendingPathComponent("Longer.md"))
            store.text = "[[Longer]] unsaved"
            try store.rename(folder.appendingPathComponent("Longer.md"), to: "Final")
            XCTAssertEqual(store.text, "[[Final]] unsaved")
            XCTAssertTrue(store.save())
            store.text = "[[Final]]"
            XCTAssertTrue(store.save())
            store.text += " more"
            try store.rename(folder.appendingPathComponent("Final.md"), to: "Again")
            XCTAssertEqual(store.text, "[[Again]] more")
            XCTAssertTrue(store.isDirty)
        }
    }

    @objc func testOpenTargetRebasesUnsavedSelfLinkWithoutReplacingDraft() throws {
        try MainActor.assumeIsolated {
            let name = "WikiTests.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: name)!
            defer { defaults.removePersistentDomain(forName: name) }
            defaults.set(false, forKey: "notes.autosaveEnabled")
            let store = NoteStore(defaults: defaults)
            let old = try write("Old.md", "saved body")
            try store.activateFolder(folder)
            store.open(old)
            let session = store.editorSession
            let view = session.textView(for: store.text)
            view.allowsUndo = true
            view.string = "draft [[Old]] with unsaved text"
            view.setSelectedRange(NSRange(location: view.string.utf16.count, length: 0))
            store.text = view.string

            try store.rename(old, to: "New")

            XCTAssertEqual(store.selected, folder.appendingPathComponent("New.md"))
            XCTAssertEqual(view.string, "draft [[New]] with unsaved text")
            XCTAssertEqual(try read("New.md"), "saved body")
            XCTAssertTrue(store.isDirty)
            XCTAssertTrue(store.save())
            XCTAssertEqual(try read("New.md"), "draft [[New]] with unsaved text")
        }
    }

    @objc func testRenameWithDirtySelfLinkPreservesSelectionAndUndo() throws {
        try MainActor.assumeIsolated {
            let name = "WikiTests.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: name)!
            defer { defaults.removePersistentDomain(forName: name) }
            defaults.set(false, forKey: "notes.autosaveEnabled")
            let store = NoteStore(defaults: defaults)
            let old = try write("Old.md", "body [[Old]] tail")
            try store.activateFolder(folder)
            store.open(old)
            let session = store.editorSession
            let view = session.textView(for: store.text)
            view.allowsUndo = true
            view.string = "body [[Old]] tail plus draft"
            view.setSelectedRange(NSRange(location: view.string.utf16.count, length: 0))
            store.text = view.string
            let oldCaret = view.selectedRange().location

            try store.rename(old, to: "Longer")

            XCTAssertEqual(view.string, "body [[Longer]] tail plus draft")
            XCTAssertEqual(view.selectedRange().location, oldCaret + 3)
            XCTAssertEqual(try read("Longer.md"), "body [[Longer]] tail")
            XCTAssertTrue(store.isDirty)
            view.undoManager?.undo()
            XCTAssertEqual(view.string, "body [[Old]] tail plus draft")
            store.text = view.string
            XCTAssertTrue(store.isDirty)
        }
    }

    @objc func testRenameTargetWhileAffectedNoteHasDirtyDraft() throws {
        try MainActor.assumeIsolated {
            let name = "WikiTests.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: name)!
            defer { defaults.removePersistentDomain(forName: name) }
            defaults.set(false, forKey: "notes.autosaveEnabled")
            let store = NoteStore(defaults: defaults)
            let target = try write("Old.md", "target")
            let source = try write("Source.md", "[[Old]] body")
            try store.activateFolder(folder)
            store.open(source)
            let view = store.editorSession.textView(for: store.text)
            view.insertText(" draft", replacementRange: NSRange(location: view.string.utf16.count, length: 0))
            store.text = view.string

            try store.rename(target, to: "New")

            XCTAssertEqual(view.string, "[[New]] body draft")
            XCTAssertEqual(try read("Source.md"), "[[New]] body")
            XCTAssertTrue(store.isDirty)
            XCTAssertTrue(store.save())
            XCTAssertEqual(try read("Source.md"), "[[New]] body draft")
            XCTAssertEqual(try read("New.md"), "target")
        }
    }

    @objc func testIndexRebuildResolutionAndDeletion() {
        let finished = expectation(description: "index")
        Task {
            do {
                let db = SQLiteDatabase(url: root.appendingPathComponent("metadata.sqlite"))
                try await db.initialize()
                try write("Other.md", "[[Old]] [[Missing|alias]]")
                try write("Old.md", "body")
                try await db.reconcile(folder: folder)
                let rows = try await db.query(SQLiteStatement("SELECT target_text, target_id IS NOT NULL FROM note_links ORDER BY target_text"))
                XCTAssertEqual(rows.count, 2)
                XCTAssertEqual(rows[0], [.text("Missing"), .integer(0)])
                XCTAssertEqual(rows[1][1], .integer(1))
                try write("Missing.md", "body")
                try await db.reconcile(folder: folder)
                let resolved = try await db.query(SQLiteStatement("SELECT COUNT(*) FROM note_links WHERE target_id IS NOT NULL"))
                XCTAssertEqual(resolved, [[.integer(2)]])
                try write("Other.md", "no links")
                try await db.reconcile(folder: folder)
                let cleared = try await db.query(SQLiteStatement("SELECT COUNT(*) FROM note_links"))
                XCTAssertEqual(cleared, [[.integer(0)]])
            } catch { XCTFail("\(error)") }
            finished.fulfill()
        }
        wait(for: [finished], timeout: 20)
    }
}
