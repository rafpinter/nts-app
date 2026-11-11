# Note dates and recovery — Phase 2.3

Implemented 2026-10-15, schema version 3. Markdown and image files are unchanged.

## Ownership and ordering

The registry stores `observed_created_at` and `observed_modified_at` from Foundation
filesystem resource values. Refresh updates these even when content hashes have
not changed. `preserved_created_at` is initialized from the first available
creation date, falling back to modification date. A missing date remains NULL
until a later observation supplies one. No date is inferred from a filename.

The sidebar uses the preserved date after asynchronous reconciliation completes,
newest first, with filename tie-breaking. While reconciliation is pending or the
index is unavailable, filesystem dates provide browsing. With neither filesystem
date available, the existing distant-past fallback sorts the file last. Updating
dates does not reopen a note, replace an editor draft, or change its conflict
baseline. SQLite failure never blocks writing.

Edits retain the preserved date. Recognized app renames retain it using the
existing saved-hash rename validation. External renames are new registry entries;
we do not associate files by matching content. The existing folder/path registry
also retains a date when a missing path reappears; replacing a file at the same
path is not distinguishable from editing/restoring it. A copied or moved notes
folder at a different root has its own registry scope.

## Migration and recovery

Migration 3 adds three nullable REAL timestamp columns to version 2. Existing
records retain their IDs; the next scan initializes dates from the current files.
Observed modification time describes the file, not the last successful index or
save. Index read errors remain separate from timestamp observations.

The preserved date is disposable cache state, not durable user-authored metadata.
After database loss, a scan reconstructs dates from the filesystem as it exists
now. It cannot recover earlier creation dates erased by copying or external
tools. No frontmatter, sidecars, backups, or portable date guarantees are added.
Corrupt databases continue to be preserved and reported.

## Verification

All 79 regression tests passed outside the execution sandbox, which is needed
for macOS bookmark, file coordination, and image services. New coverage checks
version-2 migration/backfill, timestamp-only changes, rename/restart preservation,
rebuild limitations, and sidebar ordering with an unsaved draft. The unsigned
Debug build passed with `CODE_SIGNING_ALLOWED=NO`; no signed desktop validation
was performed for this slice.

Run `sh Tests/run.sh`. Build/run the Nts scheme in Xcode for desktop checks:

1. Use a disposable notes folder; create two notes and note their sidebar order.
2. Edit/save and rename the older note; confirm its date and order stay stable.
3. Edit files externally, then Refresh with an unsaved editor draft. Confirm the
   draft remains intact and sidebar ordering remains stable.
4. Restart the app and confirm the dates remain stable. Import another Markdown
   file and confirm its filesystem creation date determines its initial position.

No tags, attachment registry, AI, search, watcher, or scanning optimization is
included. Native picker, Trash, VoiceOver, IME, and sandbox lifecycle checks from
previous milestones still need desktop verification.
