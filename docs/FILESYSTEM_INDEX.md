# Filesystem index — Phase 2.2

Implemented 2026-10-14. SQLite now tracks saved Markdown files; it remains a
rebuildable index. Descriptions, tags, attachments, embeddings, and search are
not implemented by this step.

## Schema version 2

The ordered migration from version 1 adds:

- `folders`: a database-local ID and unique canonical root path.
- `notes`: a database-local ID, folder ID, relative filename, SHA-256 content
  hash, filesystem sync state, optional read error, and last successful indexing
  time. `(folder_id, relative_path)` is unique; foreign keys scope each note to
  its folder.

No canonical note text is stored in SQLite. Creation/modification-date metadata
belongs to Phase 2.3; `indexed_at` only describes indexing, not note creation.
The database stays in the app's Application Support directory.

## Scanning and triggers

`NoteIndexScanner` reads top-level, nonhidden, regular UTF-8 `.md` files using
the same file rules as the editor. Symlink files, directories, other extensions,
and nested notes are excluded. Hashes cover saved file bytes, including files
whose modification time was preserved by an external editor.

Reconciliation runs when:

- A notes folder is selected or its saved bookmark is restored at startup.
- A Markdown file is successfully created/saved, renamed, or moved to Trash by
  the app. Empty in-memory drafts do not create registry entries.
- The user clicks **Refresh**. External creates, edits, renames, and deletions
  are detected on that refresh or the next startup/folder scan.
- The user clicks **Retry** after a database/index error; the latest folder is
  rescanned so successful file operations during downtime are picked up.

There is no filesystem watcher or polling. App file operations return after
saving the file; the asynchronous index can catch up afterward. If the app quits
before queued work finishes, the next startup scan catches up.

`DatabaseStatus` orders requests and coalesces queued full scans, retaining
explicit rename events. Each request holds its own security-scoped folder access
until its scan completes, even across a folder switch. Opening/configuration,
file reads/hashing, and reconciliation run on the database actor rather than
the UI thread. Files are read before starting the database write transaction.
A scan commits its registry changes as one transaction; scans cannot commit out
of order on this connection.

## Identity and folder policy

- Canonical folder paths distinguish selected roots; note paths are relative to
  their own root. Identical filenames and contents in different roots remain
  independent. A symlink alias of the same root resolves to the same namespace.
- IDs exist only in SQLite. They need not survive database loss. No Markdown IDs,
  frontmatter, manifest, or content-based deduplication is added.
- An explicit app rename can preserve its record if the source is absent, the
  destination has no previous record, and its hash matches the source's last
  indexed saved bytes. Conflicting/stale hints safely fall back to reindexing.
- External renames are treated as a missing old path and a new path. The app
  deliberately does not guess identity from matching content, which may belong
  to several independent files. New IDs in ambiguous cases are acceptable.
- A successful scan deletes metadata for paths no longer present, including
  dependent embeddings, filename suggestions, and projection layouts. A restored
  file is indexed as a new note with a fresh ID and derived data is rebuilt.
- A moved/copied root, once selected again, is a new namespace with fresh IDs.
  It remains usable without rewriting Markdown. Records for unselected roots
  remain as their last observation; the app scans only the selected root.

## Failures and draft safety

- A directory-listing failure aborts reconciliation without changing registry
  records. It must not mark all notes missing because the folder was unavailable.
- A per-file read/UTF-8 error sets `error`, records the error, and retains its last
  good hash/time if any. A never-readable file has no invented hash. Error records
  must not be treated as current sources by future processing.
- Unchanged files keep their IDs, hashes, and indexing timestamps. Changed saved
  bytes update the hash, even if an editor draft currently has different text.
- Index scans never write Markdown, change editor text/selection/undo state,
  or replace the editor's last-saved conflict baseline. Refresh with unsaved edits
  leaves the draft intact; existing save-conflict checks still protect disk edits.
- Index failures display a separate nonmodal notice. A successful Markdown save
  remains successful; note actions remain available. Retry rescans saved files.
- Missing databases initialize and rebuild on the next launch/scan using fresh
  IDs. Corrupt databases or failed migrations are preserved and reported, not
  silently deleted. Removing a database while the app holds an open connection
  is not a supported reset procedure; quit the app first.
- Filesystem snapshots can race with external uncoordinated writes. Refresh
  again to reconcile subsequent changes. This step does not merge conflicts.

[SQLite UPSERT](https://www.sqlite.org/lang_upsert.html) makes path-scoped updates
idempotent; hashes use Apple's system [CryptoKit SHA256](https://developer.apple.com/documentation/cryptokit/sha256).

## Verification

`sh Tests/run.sh` includes registry migration, idempotence, known SHA-256 output,
external changes with preserved timestamps, deletion/reappearance, duplicate
contents, safe rename hints, folder switching/moves, read failures, unavailable
folders, transaction rollback, database loss, retry after downtime, bookmark
restoration, and preserving unsaved drafts and file-conflict detection.
Tests use disposable directories/databases and a private UserDefaults suite.
They do not delete personal notes or move anything into the user's Trash.

Manual desktop checks:

1. Run from Xcode, choose a disposable notes folder, type, and save. Confirm the
   `.md` file remains usable in another editor and the startup draft stays stable.
2. Add/edit/rename/delete disposable Markdown files in Finder. Click Refresh;
   check the file list. Registry state can be inspected with a SQLite viewer if
   desired; users do not need to install one for normal app operation.
3. Leave unsaved text in the editor, change its disk file externally, and Refresh.
   Verify the draft remains; saving should report the existing external conflict.
4. Rename a note through the app, save, then move a disposable note to Trash.
   Confirm file actions, focus, and undo still work in the signed sandboxed app.
5. Quit and reopen to check bookmark restoration. To test rebuilding, use a
   disposable database and quit before removing it; reopening must rescan files.

Real desktop picker/Trash/VoiceOver behavior and security-scope lifetime across
folder switches still require manual verification. File writes and sidebar
listing remain synchronous as before; background indexing itself is off the UI
thread and reads one file at a time.

## Wiki-link relationships — 2026-11-10

Schema 7 adds disposable `note_links` occurrences with source hash, parser version,
UTF-16 target range, target text and optional resolved note ID. Reconciliation
replaces the folder's links transactionally from successfully read saved sources;
read failures remove stale outgoing relationships. Resolution uses the same exact
then unique case-insensitive filename/stem rules as navigation. New/deleted names
re-resolve all links. SQLite loss rebuilds these records from Markdown.

App renames update supported wiki links through the [recoverable rename flow](WIKI_LINK_RENAME_PLAN.md).
Database errors never roll back a committed filesystem operation. External renames
still do not cause reference rewrites. A verified self-link rewrite may preserve
identity using the operation's original and resulting content hashes.
