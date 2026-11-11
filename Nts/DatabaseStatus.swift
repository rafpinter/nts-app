import Foundation
import Combine

/// Index failures never gate editing or turn a successful file save into a failure.
@MainActor
final class DatabaseStatus: ObservableObject {
    @Published private(set) var failureMessage: String?
    @Published private(set) var isInitializing = false
    @Published private(set) var databaseURL: URL?
    @Published private(set) var noteDates: (folder: URL, dates: [String: Date])?
    var onReconciled: ((URL) -> Void)?
    private let database: SQLiteDatabase
    private var latestFolder: URL?
    private var pending: [Request] = []
    private var worker: Task<Void, Never>?

    private struct Request {
        let folder: URL?
        let rename: NoteRename?
        let access: ScopedFolderAccess?
    }

    init(database: SQLiteDatabase = SQLiteDatabase()) {
        self.database = database
    }

    /// Retry also reconciles the latest folder, including changes made during downtime.
    func initialize() async {
        enqueue(folder: latestFolder)
        await waitForPendingWork()
    }

    func reconcile(folder: URL, rename: NoteRename? = nil) {
        latestFolder = folder
        enqueue(folder: folder, rename: rename)
    }

    func waitForPendingWork() async {
        await worker?.value
    }

    private func enqueue(folder: URL?, rename: NoteRename? = nil) {
        // Coalesce queued full scans, keeping explicit rename events ordered.
        if rename == nil, let last = pending.last, last.rename == nil, last.folder == folder { return }
        pending.append(Request(folder: folder, rename: rename,
                               access: folder.map(ScopedFolderAccess.init)))
        guard worker == nil else { return }
        isInitializing = true
        worker = Task { await processRequests() }
    }

    private func processRequests() async {
        while !pending.isEmpty {
            let request = pending.removeFirst()
            do {
                databaseURL = try await database.initialize()
                if let folder = request.folder {
                    let result = try await database.reconcile(folder: folder, rename: request.rename)
                    noteDates = (folder, result.dates)
                    onReconciled?(folder)
                    if result.fileErrors > 0 {
                        throw SQLiteFailure(message: "Could not index \(result.fileErrors) Markdown file(s). Check file access and UTF-8 encoding, then refresh or retry.")
                    }
                }
                failureMessage = nil
            } catch {
                noteDates = nil
                failureMessage = error.localizedDescription
            }
            // Keep this request's security scope alive until its scan has finished,
            // even if the editor switched folders while the actor was working.
            withExtendedLifetime(request.access) { }
        }
        isInitializing = false
        worker = nil
    }
}

private final class ScopedFolderAccess {
    let url: URL
    let active: Bool

    init(_ url: URL) {
        self.url = url
        active = url.startAccessingSecurityScopedResource()
    }

    deinit {
        if active { url.stopAccessingSecurityScopedResource() }
    }
}
