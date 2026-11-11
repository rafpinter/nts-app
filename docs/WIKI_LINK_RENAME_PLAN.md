# Wiki-link updates on rename

Accepted and implemented 2026-11-10; verification is recorded in TASKS.md. This plan narrows the older task
20261110-010 to wiki links first. Ordinary Markdown links remain a separate slice.

## Current behavior

`NoteStore.rename` is shared by manual rename and generated-filename application.
It moves the file, rekeys its editor session, and queues index reconciliation;
it does not rewrite references. `NoteFileService.rename` checks collisions and
optional expected bytes within file coordination, but has no multi-file transaction.

Wiki-link decoration already excludes inline/fenced code and supports aliases.
`openWikiLink` resolves names in the selected folder: exact filename/stem first,
then a unique case-insensitive match. Listing is currently nonrecursive. SQLite
has no link index. Visited notes retain native editor sessions and undo history.

## Proposed behavior

- Explicit manual rename and Apply update inbound wiki links in the current
  supported notes folder, including self-links. Autosave never initiates renames.
- `[[Old]]` becomes `[[New]]`; `[[Old.md|Label]]` becomes
  `[[New.md|Label]]`. Preserve aliases, extension presence, surrounding whitespace,
  line endings and every byte outside the destination span.
- Resolve against the pre-rename file list using the same rules as navigation.
  Rewrite only links uniquely identifying the renamed note. Never guess ambiguous
  matches. Check the resulting destination still resolves uniquely; use the full
  filename when necessary, or stop with an actionable conflict.
- Exclude escaped syntax, code, image embeds and ordinary Markdown links.
  Folder paths, heading/block fragments and recursive vault support are deferred:
  current navigation does not resolve them. Leave these unsupported targets intact.
- Finder/external renames only reconcile the index. Do not infer a rename and
  rewrite other files automatically.
- Explain beside rename/Apply that matching wiki links will be updated. Do not show
  a routine success message or changed-note count, and do not add a confirmation dialog.

## Rebuildable SQLite index

Recommend adding a `note_links` table in the next sequential migration. Each
occurrence records source note ID, source content hash, parser version, target
text, destination UTF-16 range, and nullable resolved target note ID. Index resolved
targets for inbound lookup and source IDs for replacement; enforce folder scope.
Unresolved links remain indexed so new files can resolve them later. Do not store
canonical note text or durable identity in this table.

Extract a shared parser/resolver for navigation, indexing and rewriting. Update
outgoing rows transactionally when indexing a successfully read source; invalidate
stale rows on read failures, edits, deletion or parser-version changes. Re-resolve
links when the folder's name inventory changes, including case ambiguity. A full
rescan rebuilds everything after database loss.

The index is a candidate lookup, not write authority. Initially perform a fresh
folder scan at rename time to catch newly added or externally edited links and
verify completeness. Reparse current bytes before rewriting; never apply cached
ranges directly. Database downtime uses that same scan and does not block capture.
This does not claim a rename-speed improvement until a reliable freshness strategy
exists; the table supplies reusable relationships without becoming authoritative.

## Safe operation and editor integration

1. Validate name, destination and source; enumerate and read supported Markdown
   files off the main thread. If a required file cannot be read, stop before writes
   rather than claiming all links were updated. Build immutable before/after edits.
2. Check retained sessions without opening notes in the UI. Reparse and independently
   plan edits for each affected live buffer so dirty text can be preserved and rebased;
   do not autosave solely to rename. Defer while input composition is active.
3. Stage original bytes and a recovery manifest in app-owned local storage before
   mutation, separate from disposable SQLite. Record paths and operation state;
   exclude this material from Git and logs. Recheck expected bytes, file type and
   destination inside coordinated operations. Never overwrite an external change.
4. Apply the file move and reference writes as one recoverable operation. Individual
   atomic writes are not a filesystem-wide transaction. On failure, roll back only
   files still matching this operation's output. Preserve backups and explain any
   unresolved partial changes; provide recovery on restart before another rename.
   Journal transitions must tolerate interruption between an action and its record.
5. After successful disk writes, update retained editor sessions through range edits
   with selection mapping and native undo integration, preserving drafts, IME state
   and typing history. Update saved-byte baselines only for committed files; keep
   unsaved body edits dirty. Undoing a reference edit becomes an ordinary unsaved
   text change. Rekey the renamed session without recreating it. Do not promise
   cross-file rename undo.
6. Reconcile all changed sources and the explicit rename hint. Invalidate stale
   filename suggestions/embeddings for rewritten text through existing saved-content
   paths. Index failure must not undo successful file writes; expose retry as today.

The recovery coordinator and editor-session handling are the main implementation
risk. Test these before connecting UI actions. Existing protection against
uncoordinated external writers remains best-effort; do not promise global atomicity.

## Open-editor reconciliation — implemented 2026-11-10

Rename still performs a fresh folder scan and validates/writes saved bytes through
the recoverable disk coordinator; it does not open or mount every note in the UI.
Already-retained editor buffers are reparsed separately, including the selected
renamed note even when its saved file has no self-link. Their edits are calculated
from current live text and applied only after disk commit succeeds. This preserves
unsaved body text and updates saved baselines from committed disk content without
replacing a draft. Composition blocks only when a live buffer needs a link edit.

The renamed editor session is rekeyed, caret/selection mapping and native undo are
preserved, and an undone link edit is an ordinary unsaved editor change. A dirty
buffer may still contain references not present on disk; those are updated in
memory and will become durable on the next save. External disk conflicts continue
to abort the operation. Fresh-plan revalidation also compares resulting bytes so a
change in link resolution cannot silently commit stale rewrites.

Synthetic tests cover an open renamed target with an unsaved self-link, a dirty
affected source, preserved draft content, caret mapping, undo and conflict/recovery.
No private notes were used.

## Implementation slices and verification

1. Shared parser/resolver with synthetic fixtures: aliases, repeated/self links,
   explicit extensions, whitespace, Unicode/UTF-16, CRLF, escapes, code exclusions,
   exact/case-insensitive resolution, ambiguity and unsupported syntax.
2. Migration/index integration: rebuild, stale hashes, unreadable sources, deletes,
   folder changes, newly resolved links and database failure fallback.
3. Rename planner and journaled file coordinator: collision, changed bytes, symlinks,
   unreadable notes, partial writes, failed rollback and simulated restart at every
   transition. All verification uses temporary synthetic notes.
4. Shared rename/UI integration: manual rename and generated Apply, self-links,
   saved baselines, dirty-session rebasing, retained undo/redo, caret, selection,
   IME and derived-data refresh. Update filename/index/status documentation.

Run `sh Tests/run.sh` and an Xcode app build for implementation. Manual acceptance
uses a disposable folder: rename a linked note, reopen references, exercise undo,
change a file externally, and verify conflict/recovery behavior. No private vault
or dataset content is authorized for testing. Planning itself needs only Markdown
link and diff checks.

## Implementation checkpoint — 2026-11-10

Schema 7 stores source-bound wiki-link occurrences and nullable resolved targets.
Reconciliation rebuilds relationships for the scanned folder. Rename deliberately
uses a fresh scan rather than trusting cached ranges. Manual rename and generated
Apply share the same planner/coordinator. Self-link rewrites carry verified old/new
hashes into reconciliation so the note can retain its database identity.

Initial planning runs in the background. Final revalidation and coordinated writes
are synchronous to prevent editor changes during commit; large folders may briefly
pause the UI. This is a known performance limitation, not a watcher or atomic
multi-file filesystem transaction. Indented wiki syntax is conservatively treated
as code, including indented list continuations. Paths/fragments remain unsupported.

Originals and the operation manifest are retained under app-owned Application
Support `Nts/RenameRecovery` until commit. Recovery restores only matching operation
outputs, runs on folder activation and before another rename, and leaves conflicted
files untouched with an actionable error and backup location. Notes remain readable
when recovery is blocked. Editor undo restores reference text only, not the rename
or the entire cross-file operation. No private notes were used for verification.
