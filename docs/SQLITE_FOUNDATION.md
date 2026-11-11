# SQLite foundation — Phase 2.1

Implemented 2026-10-14 using macOS's system SQLite3. End users install only the
app: no database setup, CLI, Homebrew, Python, or downloaded dependencies.

## Location and startup

`SQLiteDatabase.applicationSupportURL()` uses Foundation's user-domain
Application Support directory, then appends
the current bundle identifier and `metadata.sqlite`. The current identifier is
`com.rafaelapinter.Nts`; Foundation resolves Application Support within the app
container when sandboxed. The path is never derived from the selected notes
folder or source repository.

`NtsApp` owns `DatabaseStatus` and starts initialization with the window's
SwiftUI task. The editor appears immediately. `DatabaseStatus` publishes success
or a separate, nonmodal failure notice with Retry; it never gates note actions.
Reopening the window does not reopen an already initialized connection.

## Access and durability

- `SQLiteDatabase` is an actor: opening, configuration, migrations, reads, and
  writes run serially on its executor, away from the main actor. Raw connections
  and prepared statements stay private. Transactions contain no suspension points.
- Statements bind integer, real, text, and null values. UTF-8 text, including
  embedded null characters, uses explicit byte lengths. Statement SQL accepts
  one statement at a time; binary values are not exposed yet.
- Every prepared statement is finalized on success or error. Closing the actor's
  connection or releasing it closes the SQLite handle. Failed initialization
  releases its connection and leaves Retry possible.
- Foreign keys are enabled and verified for every connection. A quick integrity
  check runs before migration. Read-only databases are refused.
- Journal mode is `DELETE`, with `synchronous = FULL`. This deliberately keeps
  rollback journaling for the current single-connection workload; WAL is not
  required yet. SQLite may temporarily create a `-journal` file beside the DB.
- A 1,500 ms busy timeout bounds lock waits per operation. Lock failures surface
  rather than retrying indefinitely or blocking the main thread.
- Transactions use `BEGIN IMMEDIATE`, commit on success, and attempt rollback
  on error. Keep batches short. Nested transactions are rejected.

These choices follow SQLite's [connection API](https://www.sqlite.org/c3ref/open.html),
[PRAGMA documentation](https://www.sqlite.org/pragma.html), and
[transaction behavior](https://www.sqlite.org/lang_transaction.html).

## Schema and failure policy

Schema version is stored in `PRAGMA user_version`. Migration definitions must
be numbered consecutively from 1. Each pending migration and its version update
share one transaction; earlier successful versions remain intact if a later
migration fails. The version is rechecked under the transaction's write lock.
Reopening applies only migrations newer than the stored version.

Version **1** establishes the foundation and creates **no feature tables**.
Version 2 now adds the folder/note registry described in
[FILESYSTEM_INDEX.md](FILESYSTEM_INDEX.md); 2.1 itself added no feature tables.
Tests use disposable fixture tables to exercise the migration/access mechanisms.

A schema newer than this app supports is refused before journal configuration
or migrations; the error asks for a newer app. Corrupt/unavailable databases
surface errors without deleting or rebuilding them. No automatic recovery,
backup/export, or schema downgrade is implemented. Markdown and image operations
remain independent of the database.

## Verification

`sh Tests/run.sh` covers first launch, reopen/idempotence, ordered upgrades,
migration and transaction rollback, foreign keys, unavailable/corrupt databases,
newer-schema preservation, value binding, statement validation, concurrent
batches, lock timeout/retry, and failure status with independent Markdown I/O.
All database fixtures live in temporary directories, not the app's real storage.
The full suite requires access to macOS services for existing file/editor tests.

Manual app checks:

1. Run the app from Xcode; type immediately and save a disposable Markdown note.
2. Locate the app's container in Finder and confirm `metadata.sqlite` is beneath
   its `Library/Application Support/com.rafaelapinter.Nts` directory. Confirm
   the selected notes folder contains no database.
3. Quit and reopen; confirm startup and Markdown editing/saving still work.
4. The error notice and Retry are covered at the state layer by automated tests;
   their visual appearance and sandboxed runtime behavior still need desktop
   verification. Do not corrupt or remove real app data to test failures.

Phase 2.2 is now implemented; see [FILESYSTEM_INDEX.md](FILESYSTEM_INDEX.md).
Database-local IDs are disposable: the file index can be rebuilt after database
loss. AI outputs and recomputation remain future work.

## App identifier transition

The bundle identifier and Application Support subdirectory changed from
`com.example.Nts` to `com.rafaelapinter.NordNotes`, then to
`com.rafaelapinter.Nts`. The current identity creates a fresh database and
sandbox container; the previous container is preserved and not automatically
migrated. Choose the existing notes folder once under the new identity to grant
access and create its bookmark. The filesystem index is rebuilt from the
existing Markdown files; those files and images stay in their original folder.
