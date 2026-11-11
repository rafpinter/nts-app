# Implementation status

This file records implemented scope independently of the roadmap.

## Wiki-link rename propagation — 2026-11-10

Manual rename and filename Apply update uniquely resolved `[[...]]` references,
including aliases, explicit extensions and self-links. Schema 7 indexes occurrences
as rebuildable derived data. A local journal supports conflict-aware rollback and
restart recovery; already-retained editors independently rebase wiki-link edits
after disk commit, preserving unsaved body text, caret and native undo. Renaming an
open note does not require opening other notes in the UI. Successful renames do not
show a routine status message; failures remain visible. Ordinary Markdown links,
external renames, recursive folders and heading/block targets are outside this slice.
See [implementation details and limits](WIKI_LINK_RENAME_PLAN.md) and TASKS.md for
verification. Interactive desktop acceptance remains outstanding.

## Simplified Map status — 2026-11-10

The Map presents one short status instead of four counters and routine indexing
messages. Enable, Retry, and Update map appear when relevant: retry addresses
failed or waiting indexing, while updating the map places current embeddings in
the layout. Errors and download activity remain visible.

## Map visual refresh — 2026-11-10

The map uses a subdued Nord gradient, a faint decorative grid, inset points and
refined hover cards. The grid is decorative and has no coordinate meaning. Dot
selection remains circular and tied to the drawn diameter; layout and navigation
are unchanged.

## Map orientation stability — 2026-11-10

Regenerated PCA layouts align their 2D coordinate frame to the previous persisted
layout using shared note IDs, minimizing movement with a rigid rotation or
reflection. Distances are not scaled. With fewer than two usable shared anchors,
the canonical PCA orientation is retained. The projection fingerprint records the
new alignment-policy version, while legacy layouts remain usable as anchors.
Semantic changes can still move or reshape clusters.

## Map dot selection size — 2026-11-10

Map dots and their circular hover/click regions share one diameter, so changing
the dot size also changes the selection area. Overlapping dots retain their chooser.

## Rename from the editor title — 2026-11-10

Click a saved note's filename above the editor to rename it inline. Return applies
the name; Escape or moving focus away cancels. Validation errors appear below the
field. The existing file rename path retains the editor session and draft, checks
the destination for collisions, and updates matching wiki links through the recoverable rename flow.

## Optional draft titles become filenames — 2026-11-10

New drafts show an optional title field above the Markdown editor. On first save,
the title is normalized to a lowercase, Unicode-aware hyphenated `.md` filename;
collisions receive a numeric suffix and never overwrite. A title can be saved
without body text, and it is not inserted into the Markdown. Drafts without a
usable title retain timestamp filenames. After first save, the field becomes the
filename display; editing text does not rename the note. See
[`FILENAME_SUGGESTIONS.md`](FILENAME_SUGGESTIONS.md#current-save-and-filename-workflow--2026-10-17).

## Empty list marker heading styling — 2026-11-02

Fixed Setext decoration recognition in `LiveMarkdown.swift`: a lone hyphen,
including trailing spaces/tabs, no longer applies heading size/color to the
preceding paragraph. Two or more underline hyphens still produce a level-2
Setext heading; equals underlines are unchanged. Markdown bytes are preserved.
Native regressions cover plain/Unicode/CRLF input, font/color reset after editing
an underline down to an empty list marker, selection and undo restoration.
The full native runner passed 188 tests, and the signed Debug app build passed.
Manual check after relaunch: type `feijoada`, Enter, then `- ` and confirm the first
line retains its normal size/color. No user vault was opened for verification.

## Python title experiments — 2026-11-02

Implemented the development-only configurable Python benchmark described in
[the operating guide](../Developer/TitleEvaluation/README.md). One working YAML
selects local models, sampling grids, seeds, optional public-data QLoRA jobs,
scorers and local MLflow tracking. The unchanged Qwen3-0.6B 4-bit baseline remains
the fixed control. Source/templates are reviewable under `Developer/TitleEvaluation/`;
configuration, data and artifacts remain ignored under `benchmarks/title_generation/`.
The shipping app and historical Swift evaluator are unchanged.

Synthetic checks cover configuration validation, production settings export,
Unicode prefixes, retries/resume, protected logging, training split leakage,
adapter lineage, metrics, paired comparisons and interactive aggregate reports.
Real SQLite/MLflow integration verifies evaluation and numeric training logging
and idempotent reimport. No existing dataset contents were inspected, models
downloaded or real training/inference executed. Runtime/model feasibility and
quality remain unverified; Python performance is not Swift app performance.
Human-review import, near-duplicate alignment, private training, automatic best
checkpoint selection and some proposed export formats remain unimplemented.
See [task 20261102-004](TASKS.md#20261102-004--implement-configurable-python-title-experiments)
for current verification evidence.

## Current status — 2026-10-17

Roadmap reordered on 2026-10-15 to prioritize local LLM filenames. Tag requirements
are preserved in `FUTURE_IDEAS.md`. Phase 3.1 now has a dev-only native Swift/MLX evaluator; Phase 3.2 now adds opt-in local filename suggestions to the app; Phase 3.3 adds explicit Apply with no inbound/external link rewriting.

| Area | Status |
| --- | --- |
| Phase 1.1–1.5: native editor, Markdown files, images, hardening | Complete; 1.5 accepted by the user |
| Phase 2.1: system SQLite foundation | Implemented |
| Phase 2.2: file registry and reconciliation | Implemented; index schema v4; overall DB schema v5 adds E2 embedding tables |
| Phase 2.3: note dates/metadata and recovery rules | Implemented; see [NOTE_METADATA.md](NOTE_METADATA.md) |
| Tags (former 2.4 and 3.3) | Deferred to FUTURE_IDEAS.md; not implemented |
| Phase 3.1: local model evaluation/integration | Implemented as a dev-only Swift/MLX tool |
| Phase 3.2: app filename suggestions | Implemented; opt-in local inference |
| Phase 3.3: safe filename application | Implemented; explicit Apply |
| Phase 3.5: attachment indexing (former 2.5) | Not implemented |
| Note embeddings/map experiment E1–E5 | Encoder evaluated; SQLite embedding persistence, first-Map-use model setup, saved-note worker, deterministic PCA reducer, schema-v6 projection persistence, and Notes / Map modes implemented. Confirmed deletions remove note metadata and dependent enrichment/layout data; failed scans preserve it. The full regression suite and ARM64 Debug build pass. Manual desktop/VoiceOver and real-model end-to-end acceptance remain; see [NOTE_EMBEDDINGS_AND_MAP_PLAN.md](NOTE_EMBEDDINGS_AND_MAP_PLAN.md). |
| Summaries, image descriptions, search/map integration | Not implemented |

**Files remain authoritative.** Users can create, edit, rename, and delete
Markdown outside the app. Startup restores the chosen folder and automatically
runs a background scan; folder selection and successful app file actions also
trigger reconciliation. While the app stays open, **Refresh** checks external
changes. No script, CLI, or extra software is needed.

The current scan reads and SHA-256 hashes every supported top-level Markdown
file. It is a full scan, not a cheap timestamp-only change check. There is no
watcher, polling, or large-folder optimization yet. Scans preserve unsaved drafts
and the editor's conflict baseline.

**SQLite is disposable:** it stores relative file paths scoped to their folder,
content hashes, indexing state, and recomputable enrichment records. Database
loss permits rescanning with fresh IDs; no IDs are added to Markdown. The embedding repository stores vectors bound to a note source hash and
model-space fingerprint. The E3 worker downloads the pinned model automatically
when Map indexing is first used (or when an enabled feature processes a saved
note); startup refresh alone does not trigger a download. Explicitly disabling
indexing suppresses automatic re-enabling. The worker backfills indexed notes
and updates embeddings from successful changed saves or folder refreshes. E4 computes deterministic 2D PCA layouts
from current ready embeddings and persists them only if the input snapshot is
still current. Successful folder reconciliation removes metadata for confirmed
deletions, cascading through embeddings and filename suggestions and discarding
folder layouts; failed scans retain existing records. Restored files get new
index identities. E5 displays persisted layouts in a Notes / Map mode, accounts
for unplaced notes, and routes map opens through the editor's normal draft guard.
Corrupt databases are preserved and reported rather than silently deleted.

**Current product name and bundle identifier:** Nts,
`com.rafaelapinter.Nts`. Its database lives at
`Library/Application Support/com.rafaelapinter.Nts/metadata.sqlite` inside the
app's sandbox container; Markdown/images stay in the user-selected folder. This
identity change intentionally starts a fresh database/container. The prior
container is preserved; users must select their existing notes folder again to
rebuild the index.

**Editor today:** unsaved startup draft, stable title-row spacing through first
save, native source/live-preview toggle, list continuation, checkboxes, and local
image rendering/support. The sections below record earlier milestone states;
their old deferred-rendering notes describe the implementation at that time.

**Verification at the live Appearance settings milestone:** all **133 tests passed**, including 41 filename tests and 3 appearance-preference tests.
A locally signed Debug app build passed; final backend smoke details are recorded
in [FILENAME_SUGGESTIONS.md](FILENAME_SUGGESTIONS.md). Signed desktop picker,
Trash, VoiceOver, real IME sessions, and security-scope behavior across folder
switches still have manual checks outstanding. No interactive desktop checks were run for Phase 3.3.

**Ideas only:** inline Markdown hashtags and a possible ⌘⇧S recomputation command
are recorded in `FUTURE_IDEAS.md`. Neither is implemented. Automatic watching and
faster change detection are possible future improvements, not approved work.

See [FILESYSTEM_INDEX.md](FILESYSTEM_INDEX.md) for exact scope and manual checks.

## Current controls and limitations — 2026-10-17

This is the active behavior. The milestone chronology below preserves older
shortcuts and save policies; those historical variants do not override this section.

| Command | Current behavior |
| --- | --- |
| ⌘1 / ⌘2 / ⌘3 | Focus sidebar / focus editor / toggle sidebar visibility |
| ⌘, | Open live Appearance settings |
| Hold ⌘K | Momentary translucent keyboard shortcut reference; release K or Command to hide |
| ⌘S with edits to an existing file | Save text only; no filename generation or application |
| First ⌘S on a nonempty new draft | Save a safe timestamp file, then request a filename preview |
| ⌘S with no text edits | Apply a ready filename preview; silent no-op without one |
| ⌘⇧S | Save pending edits and explicitly regenerate a filename preview |
| Apply / Escape for filenames | Accept a validated preview / cancel or dismiss naming |
| ⌘D, ⌘D in sidebar | Two distinct presses within one second trash without confirmation |
| ⌘Z in sidebar | Restore the last deleted note in the current folder, including its captured draft |
| ⌘Z / ⌘⇧Z in text | Native text undo/redo with ordinary typing coalescing |
| ⌘F / ⌘G / ⌘⇧G | Current-note native Find / next match / previous match |
| Escape in Find | Close the native find interface before dismissing a filename preview |

Text undo and deletion restore are separate histories. Visited notes retain their
own native editor, selection, and undo/redo across switching, first saves, app
renames, and deletion restoration during this app session. Reopening changed
external text resets that note's stale history. Histories grow with visited notes
and are not persisted across app restarts. File renames/navigation have no undo, and sidebar
restoration has no redo. Delete snapshots last for the app session; in-app restore
recreates a file without overwriting a collision and leaves its saved Trash copy.

At that milestone, the full suite had **133 tests passed** after live Appearance settings integration.
The signed Debug build and whitespace checks passed. Native find-bar visibility/Escape/undo are tested; actual find match
navigation and full desktop focus/keyboard interactions still require manual checks.

Current window chrome is one native unified compact toolbar: window controls,
sidebar toggle, view mode, folder, refresh, and new note. The app's
separate header row is removed. Settings → Appearance (⌘,) applies a translucency
toggle, Toolbar tint (the saved header preference), and independent editor/sidebar
opacity live, with persistence and Restore Defaults. Native window-control backdrop
and text remain opaque; Reduce Transparency uses solid content backgrounds.
AppearanceConfiguration.swift holds factory defaults and source-only material/base
tint, not live user overrides.

## 1.1 — App foundation and visual shell

Implemented on 2026-10-13:

- Native macOS SwiftUI app, Xcode project, and shared Nts scheme.
- macOS 14 deployment target; temporary app name and bundle identifier.
- Dark Nord-inspired window with a resizable sidebar and editor area.
- Empty states for an empty notes list and unselected editor.
- Shared palette, monospace type scale, spacing, and reusable empty-state view.
- Accessible sidebar toggle with ⌘⌥S; native window controls and resizing.
- Build/run and manual visual-review instructions in the root README.

Validation: Xcode 27 Debug build succeeded for arm64 and x86_64 using
`CODE_SIGNING_ALLOWED=NO`; `git diff --check` passed. Xcode's Swift macro
compiler required running the build outside the execution sandbox.
Interactive launch, visual review, and VoiceOver checks remain unverified.

### 1.1 visual review adjustments

- Set the sidebar's initial preferred width to its 220-point minimum;
  it remains resizable up to 340 points.
- Left-aligned the sidebar toggle and app label below native window controls.
- Removed the extra 28-point top padding and reduced the header height to
  40 points to bring the toggle closer to the window controls.
- Removed sidebar/editor empty-state prose and the editor preview caption;
  retained restrained decorative icons.
- User confirmed the app launches locally after local fixes.

## 1.2 — Filesystem note model

Implemented on 2026-10-13:

- User-selected folder via NSOpenPanel, sandbox read/write entitlement, and
  persisted security-scoped bookmark with balanced access when switching folders.
- Top-level regular `.md` files listed newest first by creation date, with
  modification-date fallback and filename tie-breaking; explicit list refresh.
- Exclusive timestamp-based creation with collision suffixes and no overwrites.
- UTF-8 opening, a basic native TextEditor, and explicit Save button.
- Coordinated atomic replacement preserving original creation dates/permissions;
  byte comparisons reject detected external edits before save or deletion.
- Confirmed macOS Trash deletion; errors preserve the draft and surface an alert.
- Save/discard/cancel protection for switching, creating, window close, and quit.
- Single main window to avoid competing editor drafts; editor identity resets
  per note, with minimal dirty-state feedback needed for safe explicit saving.
- Seven filesystem tests covering collisions, Unicode/creation-date preservation,
  external conflicts, missing files/folders, list filtering/order, date fallback,
  and invalid UTF-8. A standalone XCTest runner lives in `Tests/run.sh`.
- README usage instructions, manual acceptance checks, and updated handoff.
- Corrected the `.DS_Store` ignore typo.

Validation: all seven filesystem tests passed outside the execution sandbox
(macOS file coordination requires system-service access). The final locally
signed Debug build passed in Xcode 27; the signed app contains the sandbox,
user-selected read/write, and app-scoped bookmark entitlements. `git diff --check`
passed. Folder-picker/bookmark behavior, close/quit prompts, and successful Trash
deletion require manual desktop verification using the README checklist.

Limitations: synchronous I/O; explicit refresh rather than folder watching;
top-level UTF-8 Markdown only; no conflict merge UI. Uncoordinated writes by
external tools can race with a save even with content checks/file coordination.

### Requested follow-ups

- Replaced Save/Discard/Cancel prompts with automatic saving before switching
  notes/folders, creating another note, closing, or quitting. Failed saves block
  the action and retain the draft with an error. ⌘S and Trash confirmation remain.
  Validation: signed Debug build and all 17 regression tests passed.
- Hid the Markdown extension in sidebar names, tooltips, and editor titles;
  actual filenames still retain `.md` for portability.
- Configured the native editor to use autohiding overlay scrollbars, appearing
  during scrolling and fading afterward without replacing the text editor.
- Replaced the split view's preferred width with an explicit 220-point initial
  sidebar width and a draggable, accessible divider. Width stays within
  220–340 points and shrinks as needed to leave 400 points for the editor.
  Width adjustments last for the current session; launches start at 220 points.
- Removed the editor's “Writing space” placeholder and document icon; the
  editor header appears only when a note is selected.
- Enabled **New Folder** in the native notes-folder picker.
- Added **File → Save** with **⌘S**, using the same save operation and dirty-state
  availability. Removed the toolbar Save button; retained the unsaved circle.
- Added sidebar **Move to Trash** context menus targeting the clicked note,
  with confirmation. Deleting a different note preserves the active draft.
  Other 1.3 editor work remains deferred.
- Added sidebar **Rename…** with inline filename editing, automatic `.md` suffix,
  invalid-name checks, coordinated file moves, and collision refusal.
  Renaming preserves creation dates, contents, and any open unsaved draft;
  a stable editor identity preserves the native editor through filename changes.
  Existing Markdown links are not rewritten.
- Replaced the rename dialog with a focused sidebar text field: Return confirms,
  Escape/focus loss cancels, and rename errors appear inline for correction.
- Rename validation: all 11 filesystem tests passed, including case-only moves,
  Unicode names, collisions, invalid names, and saving after a rename.

Manual check: create/select a folder in the picker, edit a note, press ⌘S while
the editor has focus, and verify the saved file in another editor.
For renaming, check Return, Escape/focus loss, an existing filename, renaming an inactive note,
and renaming the active note with unsaved edits before saving with ⌘S.

## 1.3 — Editor polish and shortcuts

Implemented on 2026-10-13:

- Retained the native SwiftUI TextEditor, stable editor identity across rename,
  and the existing unsaved circle. Added a shared 15-point monospace editor font,
  Nord caret/selection colors, and vertical text inset.
- Expanded `EditorScrollbars.swift` into `EditorConfiguration.swift` to configure
  the existing NSTextView without replacing its text storage. Retained transient
  overlay scrollbars and native caret, selection, undo/redo, and input methods.
- Disabled smart quotes/dashes, automatic text substitution/correction,
  spell/grammar checking, and link/data detection for literal Markdown/code.
- File commands: ⌘N new, ⌘O open from the selected folder, ⌘⇧O choose folder,
  ⌘S save, and ⌘⇧⌫ confirmed Trash deletion. Native ⌘⌫ remains available to edit text.
- Navigate menu: ⌘⌥↑/↓ previous/next, ⌘⇧L focus notes list, ⌘⇧E focus editor.
  List arrow keys select notes; Return enters the editor. Keyboard selections
  scroll into view. Navigation stops at boundaries and saves dirty drafts before
  switching; save failures prevent navigation.
- New/open request editor focus; list-arrow navigation keeps list focus.
- Added a small pure navigation helper and three boundary/fallback tests.
- Added three native editor tests checking long Unicode text/selection,
  typing undo/redo, and marked-text preservation during configuration.
- Updated README commands, manual acceptance checklist, and session handoff.

Validation: locally signed Xcode 27 Debug build passed; all 17 filesystem,
navigation, and native editor tests passed outside the execution sandbox.
Menu routing, keyboard focus, real IME sessions, and VoiceOver still need
interactive verification using the README checklist.

Syntax highlighting remains deferred: 1.3 makes it conditional on preserving
typing/cursor behavior. This milestone retains the existing native editor and
does not recolor or rewrite text storage. Markdown rendering is still deferred.

## 1.4 — Images and assets

Implemented on 2026-10-13:

- Creates/reuses `imgs` inside the selected notes folder on folder selection
  and bookmark restoration, as requested; refuses blocking files or symlinks.
- Validates image contents with ImageIO, preserves original bytes/format, and
  copies to safe filenames with collision suffixes. Stages complete files before
  publication; validates a whole batch before copying and attempts rollback on failure.
- Inserts relative `![image](imgs/filename.ext)` links. File drops insert at the
  drop position; ⌘V inserts clipboard image data or copied local files at the
  caret/replaces the selection. Ordinary text paste stays native.
- Replaced the SwiftUI TextEditor bridge/probe with a small native NSTextView
  wrapper to handle drag and paste directly. Retained Nord styling, wrapping,
  overlay scrollbars, focus controls, stable identity across rename, and input methods.
- Native text insertion updates the draft binding and supports undo/redo;
  each note editor has a separate undo manager. Marked-text composition blocks
  image insertion until the phrase is committed.
- Advertises image-readable pasteboard types and validates the Paste command
  so image-only clipboards enable Paste/⌘V. Tests use the actual paste action
  and a private pasteboard, without changing the user's clipboard.
- Clipboard screenshots use `screenshot-yyyy-MM-dd-HHmmss` stems based on local
  paste time; capture timestamps aren't reliably provided by clipboard data.
  Same-second imports retain collision suffixes. Added a timestamp regression test.
- Unsupported files and I/O errors surface an alert without altering the draft.
- Images remain on disk after undo/link removal/note deletion because links
  can be shared. Images are copied immediately; note text follows existing saves.

Validation: signed Xcode 27 Debug build and all 32 tests passed. Nine image
asset tests and six insertion tests cover creation/reuse, collisions, safe names,
byte preservation, actual format detection, invalid files/paths, relative links,
Paste validation/action, multi-file insertion, selection/undo/redo, draft binding,
marked text, and separate undo histories. Existing regressions still pass.
Actual Finder drops, screenshot clipboard paste, sandbox access, keyboard focus,
and external Markdown rendering remain manual checks in the README.

Limitations: synchronous image I/O; PNG/TIFF clipboard data and local files,
without remote downloads or promised-file support. No rendering, image cleanup,
compression, or AI captions.

## 1.5 — Phase-1 hardening

Completed and accepted by the user on 2026-10-14 after testing and refinements.

- Regression coverage includes filesystem collisions, UTF-8 read/write, creation
  ordering, conflict/missing-file protection, rename collisions, native editor
  behavior, image handling, and in-memory draft state.
- Follow-up refinements include unsaved startup notes, a stable editor position
  through first save, and concise rename collision feedback, detailed below.
- Latest validation: all 48 tests passed; the startup-draft/editor-position
  Debug builds passed for arm64 and x86_64. No new tests were run for this
  documentation-only milestone update.
- Acceptance does not imply every manual check was independently automated or
  verified by Codex. Prior manual-check notes and known limitations still apply,
  including real IME/VoiceOver checks, sandbox picker behavior, successful Trash
  operations, synchronous I/O, and explicit folder refresh.

## Remaining milestones

- Phase 3.4 onward — summaries, attachments, image descriptions, semantic discovery: not implemented. The scoped embeddings/map work has completed evaluation (E1) and SQLite persistence (E2) only; production processing starts at E3. Phase 3.1 has a dev-only evaluator, 3.2 has app suggestions, and 3.3 adds Apply. Tags are deferred to `FUTURE_IDEAS.md`.

Embedding inference, projection, Map UI, summaries, search, tag/attachment
indexing, and automatic folder watching remain unimplemented. Source/live-preview
editing and the SQLite file index are implemented; see the current-status summary
above.

### Unsaved startup note (2026-10-14)

- Launch and New Note show a focused in-memory draft without creating a file.
- Typing requires no configured folder; first save requests one if needed.
- Nonempty drafts use existing automatic saves before navigation/close/quit;
  cancelling folder selection or failing to save preserves the draft.
- Empty drafts never create files; first save writes the draft directly with
  collision-safe creation. Saving preserves editor identity and undo history.
- Image imports work in drafts once a notes folder is selected; image files
  continue to be copied immediately, as before.
- Changed NoteStore, ContentView, NtsApp, NoteFileService, the test runner,
  draft regression tests, and README usage instructions.

Validation: unsigned Debug build passed for arm64/x86_64; all 48 tests and
`git diff --check` passed. Interactive launch
focus and first-save folder picker still require desktop verification: relaunch,
type immediately, save with ⌘S, then use ⌘N and quit with an empty draft to check
that no extra Markdown file appears. Database/search scope remains deferred.

### Stable draft editor position

- The editor title row now always occupies the same height, displaying
  “Unsaved note” before first save and the filename afterward. The Trash control
  reserves space while hidden and disabled for drafts, keeping typing position
  stable when saving. Changed ContentView and this status document.
- Manual verification: type multiple lines into a new draft, save with ⌘S,
  and confirm the text and caret stay in place as the title changes.
- Validation: unsigned Debug build and `git diff --check` passed. Visual caret
  stability requires the manual check above.

### Rename collision wording

- Rename collisions now display “The name already exists.” while preserving
  both files. Other filesystem errors retain their original descriptions.

## 2.1 — SQLite foundation

Implemented on 2026-10-14 at the user's request.

- Added `SQLiteDatabase.swift`: system SQLite3, a serialized actor, parameter
  binding, scoped statement/connection lifetimes, transactions, and ordered
  versioned migrations. Version 1 creates no feature tables.
- Resolves `com.example.Nts/metadata.sqlite` beneath Foundation's
  user-domain Application Support, including sandbox container resolution.
- Enables foreign keys; uses DELETE journaling, FULL synchronization, a 1,500 ms
  busy timeout, and an integrity check. Refuses unsupported newer schemas and
  preserves existing database files on failure.
- Added `DatabaseStatus.swift` and app/view startup integration. A nonmodal error
  notice with Retry leaves Markdown operations independent and available.
- Updated the Xcode project, test runner, and handoff/product documentation;
  added `SQLiteDatabaseTests.swift` and `SQLITE_FOUNDATION.md`.
- Validation: unsigned Debug build passed for arm64/x86_64. All 62 tests passed,
  including 14 database tests for migration/transaction rollback, foreign keys,
  preservation, locking, concurrent batches, binding, and failure/retry while
  Markdown remains usable. macOS service tests require execution outside the
  restricted sandbox; the initial restricted run failed on those services.

Limitations at completion of 2.1: no indexing/feature tables, backup/recovery UI,
or binary SQL values. Phase 2.2 subsequently added the registry.
App-container placement and error-notice appearance still need desktop
verification; follow the manual checklist in `SQLITE_FOUNDATION.md`. No Phase 2.2
identity policy was chosen and no filesystem synchronization was implemented.

### Permanent app identifier

- Changed Debug and Release bundle identifiers and the Application Support
  subdirectory to `com.rafaelapinter.NordNotes`; updated README/storage docs.
- Verified the old database is schema version 1 with no tables. The old container
  is preserved and the new identity initializes a fresh foundation database.
- The notes directory and its files are unchanged. Users must choose their notes
  folder once under the new identity; cross-container bookmark migration is not
  implemented.
- Validation: locally signed Debug build passed for arm64/x86_64; the built
  app has the new identifier and retains its sandbox/bookmark entitlements.
  `git diff --check` passed. No additional tests were needed for this identity
  change; launch and folder reselection remain manual checks.

### Disposable database recovery decision

The user confirmed that note IDs do not matter across database loss. SQLite is
intended to store recomputable file descriptions and embeddings; loss is
acceptable. New IDs after a rescan are allowed. No identity frontmatter,
identity manifest, or database backup system is required for this workflow.
Updated the architecture contract, roadmap, context, and handoff documents.
No runtime code changed; file reconciliation, descriptions, embeddings, and
recomputation remain unimplemented. `git diff --check` passed; no tests run for
this documentation-only decision.

## 2.2 — Filesystem indexing and reconciliation

Implemented on 2026-10-14 at the user's request.

- Migration 2 adds `folders` and path-scoped `notes` records, SHA-256 content
  hashes, indexing state/errors, and last successful indexing time. No canonical
  Markdown text, user metadata, AI outputs, or search tables were added.
- Added `NoteIndex.swift` and actor-based reconciliation in `SQLiteDatabase`.
  Full snapshots commit transactionally; failed listings preserve the previous
  registry. Read errors are recorded; confirmed deletions remove their registry
  records and dependent derived data.
- `DatabaseStatus` queues/coalesces scans and retains per-request scoped access.
  `NoteStore` schedules after folder selection/restoration, successful saves,
  renames, Trash actions, and Refresh. Retry scans the latest folder to catch up.
- Explicit app renames preserve IDs only when safe; external renames and moved
  roots may get new IDs. Database loss permits rebuilding with fresh IDs.
- Scans read disk only and never change editor drafts, undo identity, or conflict
  baselines. Markdown operations remain available during index/database failure.
- Updated app/view integration, Xcode project, tests/runner, README and handoff
  documents; added `NoteIndexTests.swift` and `FILESYSTEM_INDEX.md`.

Limitations: explicit Refresh rather than watching; top-level regular UTF-8
Markdown only; no cross-root identity matching or AI processing. Existing file
writes/sidebar listing remain synchronous. See `FILESYSTEM_INDEX.md` for exact
folder/error policy and manual desktop checks.

Validation: locally signed Debug build passed for arm64/x86_64; all 76 tests
passed, including 14 new file-index tests. `git diff --check` passed. The first
run found an assertion comparing equivalent `/var` and `/private/var` bookmark
paths; the test now compares resolved paths. Signed desktop picker/Trash,
VoiceOver, and security-scope behavior still need the documented manual checks.
No Phase 2.3 metadata or AI/search work was implemented.


## 3.1 — Development-only local model evaluation

Implemented 2026-10-15. See [LOCAL_MODEL_EVALUATION.md](LOCAL_MODEL_EVALUATION.md).

- Separate Swift package/workspace using native MLX; no app target dependencies,
  network entitlement changes, database migrations, save hooks, or production UI.
- Initial model `mlx-community/Qwen3-0.6B-4bit`, with configurable ID/revision or
  local-only weights behind a plain Swift inference interface.
- Bounded inputs/outputs, explicit model downloads, fresh context per case,
  sequential runs, load/generation/memory diagnostics, and explicit unload.
- Release build passed; four synthetic cases ran twice. Fresh-process local-only
  inference also passed with all network access denied. Four pre-load failure
  checks passed; `git diff --check` passed. App tests were not rerun for this tool.
- Observed quality limitations include an invented year in the Portuguese case.
  No claim of production filename quality or constrained-Mac benchmarking.

Phase 3.2 subsequently added app filename processing/output persistence; 3.3 adds safe explicit
application. A product model selector, tags, and other AI outputs remain deferred.


## 3.2 — In-app local filename suggestions

Implemented 2026-10-15; see [FILENAME_SUGGESTIONS.md](FILENAME_SUGGESTIONS.md).

- Separate `FilenameModelConfiguration.swift` for the model/revision, system and
  user prompts, temperature, top-p, thinking, limits, and configuration provenance.
- Explicit download/enable and disable menu commands; saved notes enqueue local
  background work. Generate handles existing files and retries. No rename action.
- Schema 4 persists source/configuration hashes, model/prompt provenance, output,
  queued/processing/error/stale state, attempt count, and generation time.
- Coalesced saves, draft isolation, stale-result rejection, interrupted-work
  recovery, and model release. No summaries/tags/attachment/search schema.
- Native MLX package products and network-client entitlement for explicit model
  downloads. Swift package versions are recorded in the project lockfile.
- All 90 regression tests passed, including configuration, collision/path safety,
  migration, rapid saves, stale sources/configs, deletion, restart, failure/retry,
  failed saves, disabled mode, and cancellation/resume. Signed app build passed.
- Final production backend smoke returned valid stems on four synthetic cases;
  the Portuguese result still invented a year. This smoke ran outside the GUI.
- Interactive sandbox setup/download, menu routing, and responsiveness remain
  manual desktop checks. Backend smoke runs use synthetic text outside the GUI.


## 3.3 — Explicit application of suggested filenames

Implemented 2026-10-15. See [FILENAME_SUGGESTIONS.md](FILENAME_SUGGESTIONS.md).

- Apply appears beside a ready suggestion for the selected clean note; the UI
  states that links to the old name are not updated. No automatic rename.
- Revalidates the exact suggestion/configuration and saved bytes, checks the
  editor/selection after awaiting validation, and rechecks bytes during the
  coordinated filesystem rename. Existing destinations are never overwritten.
- Reuses the existing rename/reconciliation path, preserving editor identity,
  contents, and metadata when indexing succeeds. Failures retain the draft;
  indexing failures after a successful move leave the file usable at its new
  path and use the existing retry/rebuild policy. No schema change.
- All 96 tests passed (17 filename tests); locally signed Debug build and
  `git diff --check` passed. Interactive Apply/focus/VoiceOver checks remain.

Phase 3.4 summaries is next, awaiting a new request. Tags remain deferred.


### Filename validation diagnostics

Debug builds now print each raw model response to the Xcode console before
validation, bracketed by `[Filename Model] Raw output BEGIN` and `END`. The
`DEBUG` compilation condition is explicitly enabled for the project's Debug
configuration. In-app errors remain concise; raw output is not stored in SQLite
or logged by Release builds. Rebuild and regenerate to inspect a new response.


### Prompt/filename format debugging — 2026-10-17

The edited purpose-focused prompt was being sent and stored correctly; its
natural-title-with-extension output conflicted with the original stem-only
validator. Normalization now accepts one title, optional `.md`, common title
labels/matching quotes, and returns a safe lowercase hyphenated name. Paths,
multiline output, other extensions, and collisions remain rejected. The user's
prompt text is preserved. Debug logs show effective prompt/settings, raw output,
and the normalized filename; app error text stays concise.

All 100 regression tests passed. A cached production-backend smoke using the
edited prompt returned four usable titles, normalized successfully; see
`FILENAME_SUGGESTIONS.md`. Interactive checks remain manual.


### Save / Save and Rename commands — 2026-10-17

⌘S now saves changed text only, with the command left enabled to consume clean
saves silently. The shared save method returns before any I/O for unchanged text.
⌘⇧S saves changed text, explicitly generates a name, then applies it safely.
Unchanged notes are no-ops for both commands. Automatic saves no longer queue
naming; explicit Generate/Apply remains available for existing notes and retries.

The successful changed-save callback is retained for future embeddings: every
changed save, including explicit/automatic/Save and Rename, must trigger future
embedding processing; failed or unchanged saves must not. No embeddings added.

All 107 tests passed, covering unchanged-save modification times, changed-save
hook counts, no naming after ordinary saves, Save and Rename success/failure,
model-disabled save preservation, and typing during inference. Signed Debug build
and `git diff --check` passed. Shortcut sound/focus checks remain manual.


First-save correction: the first explicit ⌘S on a new unsaved draft now saves
and applies an LLM name. Later ⌘S saves edits only; ⌘⇧S still saves and renames.
A safe timestamp file is written first so a naming failure cannot lose text.
Blank drafts remain no-ops. All 110 tests and the signed Debug build passed,
including first-save naming, later save-only behavior, and naming failure fallback.


### Current naming workflow — 2026-10-17 (supersedes shortcut variants above)

Changed ⌘S saves and generates a preview; ⌘⇧S / Regenerate Filename generates
again, even when clean, without applying. Clean ⌘S accepts the current ready
preview; no pending candidate means a silent no-op. New notes keep their safe
timestamp filename until acceptance. Automatic saves remain plain saves.
Sampling defaults to temperature 0.7/top-p 0.9 so rerolls permit variation;
configuration remains centralized. The prompt text is preserved.

All 111 tests and the signed Debug build passed. Tests cover the full preview→
reroll→accept cycle, repeated clean regeneration without file writes, edits that
must refresh rather than apply an old candidate, and no-candidate no-ops.
Future embeddings remain attached to successful changed-content saves only,
not clean regeneration or filename acceptance; they are not implemented.


### Automatic filename retries — 2026-10-17

Recoverable inference and filename-validation failures now automatically retry
(default 3 attempts, configurable up to 5), rechecking sources/cancellation before
each attempt. A successful validated candidate is still only a preview. Exhaustion
is a retryable inline error, not a save-failure alert; saved text is unchanged.
Debug logs include attempts/raw output/failure reasons. Invalid model settings
throw a recoverable error rather than trapping during prompt setup/encoding.
No process-isolation guarantee is made for fatal MLX/GPU failures.

All 116 tests and the signed Debug build passed, with coverage for malformed
responses, transient errors, collisions, bounded exhaustion and later recovery,
and invalid configuration. `git diff --check` passed.


### Sidebar focus, deletion, and restore — 2026-10-17

⌘1 focuses the sidebar, including when empty; ⌘2 focuses the editor. While the
sidebar is focused, two distinct ⌘D presses within one second move the selected
note to Trash without confirmation and select a neighbor. Holding D does not
trigger deletion. Sidebar ⌘Z restores deleted notes in reverse order for the
current folder, preserving any unsaved draft. Editor/inline-rename text undo
remains separate. Existing button/menu Trash actions retain confirmation.

Undo snapshots are in memory for this app session, independent of SQLite.
Restoration exclusively recreates the original filename and refuses collisions;
a failed restore retains its snapshot for another attempt. Saved file dates are
restored where supported. The saved copy remains in macOS Trash, including after
in-app restoration. Images are left untouched. Filename/save behavior is unchanged.

Changed files for this slice: ContentView.swift, NtsApp.swift, NoteStore.swift,
NoteFileService.swift, NoteNavigationTests.swift, README.md, PROJECT_CONTEXT.md,
and this status document. Interactive focus/key-sequence testing remains manual;
see README for the disposable-note verification steps.

Validation: all 119 tests passed and the signed Debug app built successfully.
New tests cover draft restoration, collision refusal and retry, failed deletion,
and multiple deletions/restores in reverse order. `git diff --check` passed.


### Editor focus correction — 2026-10-17

After the reported ⌘2 failure, replaced the editor's unattached SwiftUI FocusState
with ordinary State. MarkdownEditor already manages AppKit first-responder focus;
its request flag must persist independently of SwiftUI focus targets. Sidebar and
rename fields retain their actual SwiftUI focus bindings. Signed Debug build and
`git diff --check` passed. Interactive verification remains: ⌘1 → ⌘2 → type,
then repeat with an empty draft and an existing note; confirm cursor position
and editor undo are retained. The 119-test result above predates this UI correction.


### Editor publication guard — 2026-10-17

Following reports of “Publishing changes from within view updates”, the native
editor delegate now compares text before writing its SwiftUI binding. Repeated
notifications for unchanged/model-driven presentation no longer republish the
NoteStore text during view updates. Actual edits still propagate synchronously
so save and navigation see the current draft. Added a regression test covering
unchanged notifications, one real edit, and a repeated notification after it.
Changed files: MarkdownEditor.swift, NativeEditorTests.swift, this document.
Interactive confirmation of warning removal remains pending after relaunch.

Validation: all 120 tests passed, signed Debug build passed, and `git diff --check` passed.


### Escape filename generation/preview — 2026-10-17

Escape cancels a filename request or dismisses its preview without renaming or
rolling back saved text. The request token prevents work waiting on metadata or
late inference output from reviving the abandoned preview. Worker cancellation
is cooperative. Dismissal removes the persisted suggestion, filters pending
publications, and prevents an in-flight Apply from accepting the abandoned name.
Regeneration waits for pending dismissal before queuing fresh work. Inline
manual filename editing retains priority for Escape.

Changed files: FilenameSuggestionController.swift, FilenameSuggestions.swift,
ContentView.swift, FilenameSuggestionTests.swift, README.md,
FILENAME_SUGGESTIONS.md, and this document. All 122 tests passed, including preview
dismissal/no-rename, persistence, late-output rejection, and regeneration after
cancellation. Signed Debug build and `git diff --check` passed. Manual verification:
⌘⇧S → Escape during generation and after a preview; confirm clean ⌘S cannot apply
the dismissed name, then ⌘⇧S can generate a fresh one.


### Undo evaluation and erased-text correction — 2026-10-17

A native AppKit probe reproduced the reported erasure failure: the custom editor
UndoManager had an undoable deletion, but the text view did not expose undo: and
the standard responder action left the text erased. Earlier tests called the
manager directly and therefore missed command routing. MarkdownTextView now
exposes undo:/redo: and validates both actions against its own manager. The sidebar
keyboard monitor defers to an actual NSTextView first responder (including inline
rename fields), regardless of stale SwiftUI focus state.

A new regression exercises whole-note erasure, native responder Undo, Redo, and
Undo again, with live preview and the actual draft binding attached. All 123 tests
and the signed Debug build passed; `git diff --check` passed. Manual verification:
erase selected text, ⌘Z restores it, ⌘⇧Z erases it again; repeat after ⌘1 → ⌘2,
Save, preview dismissal, and filename acceptance. Sidebar deletion restore remains
separate. Interactive app/menu verification and recovery of the user's previous
text are not claimed by the automated tests.

Overall scope assessment: text changes use the current native editor's history;
sidebar deletions use session snapshots. Save/generation/renaming preserve editor
identity, but note switching/new-note creation recreates the editor and discards
its old undo history. Accepted filename changes and navigation have no undo
entries; sidebar restore has no redo. There is no unified chronological app-wide
undo stack. This fix repairs text erasure Undo/Redo; it does not claim that broader
history is implemented. Changed files: MarkdownEditor.swift, ContentView.swift,
NativeEditorTests.swift, README.md, and this status document.


### Existing-file Save only writes text — 2026-10-17 (supersedes earlier save variants)

⌘S on an existing file only saves changed text. It never generates a filename or
accepts a pending preview, and a clean save is silent. Only the first explicit save
of a nonempty new draft automatically requests a preview after safely writing the
timestamp file. ⌘⇧S/Generate explicitly requests naming; Apply explicitly accepts
it. Successful changed saves still call onSaved for future embeddings; no embeddings
were added. Existing edits clear the visible outdated preview and index reconciliation
invalidates its persisted source. Model configuration/prompt are unchanged.

Changed source/tests: FilenameSuggestionController.swift, ContentView.swift,
FilenameSuggestionTests.swift. README and canonical policy/spec/session docs updated.
All 124 tests passed and signed Debug build passed; `git diff --check` passed.
Coverage includes first-save previews, clean saves with pending candidates that must
not apply, edited existing saves with no inference or rename, and explicit Apply.
Manual verification: edit an existing note, ⌘S twice, confirm text is saved and the
filename is unchanged with no model request; ⌘⇧S then Apply remains available.


### Clean Save accepts a ready filename — 2026-10-17 (latest save policy)

The previous correction removed clean-save acceptance too broadly. Restored it:
changed existing-file ⌘S only saves text, with no inference or rename; clean ⌘S
accepts a current ready preview through the safe Apply path. Without a ready
candidate, clean Save is silent. First-save previews, explicit ⌘⇧S regeneration,
Escape dismissal, source/configuration/collision checks, and text undo remain
unchanged. A changed save clears its obsolete preview before another Save can
accept it. This supersedes the no-clean-acceptance policy immediately above.

All 125 tests and signed Debug build passed; `git diff --check` passed. New coverage
checks clean-save acceptance without model calls or changed-text save events,
editor identity preservation, and repeated Save after acceptance. Existing coverage
checks edited saves do not generate/apply and dismissed previews cannot be applied.
Controller, suggestion tooltip, filename tests, README and canonical policy docs
were updated. Manual flow: edit existing note → ⌘S saves only → ⌘⇧S previews →
clean ⌘S applies.


### Current-note Find — 2026-10-17

Added Edit-menu Find in Note (⌘F), Find Next (⌘G), and Find Previous (⌘⇧G),
using NSTextView's native find bar and incremental search. Commands target the
current editor even from the sidebar. Tokenized requests run outside SwiftUI
view updates and are scoped to editor identity so switching notes cannot replay
an old request. Escape prioritizes native find fields/bar over filename preview
dismissal; editor Escape closes a visible bar and restores text focus.

Uses the existing Markdown source in both source/live preview. No library index,
AI, or Phase-4 search work was added. Native API reference:
[Apple NSTextFinder](https://developer.apple.com/documentation/appkit/nstextfinder).

Changed files: MarkdownEditor.swift, EditorConfiguration.swift, NoteStore.swift,
ContentView.swift, NtsApp.swift, NativeEditorTests.swift, README.md,
PROJECT_CONTEXT.md, and this document. All 126 tests and signed Debug build
passed; `git diff --check` passed. The regression verifies native bar visibility,
Escape, unchanged text, and preserved Undo. Match-selection assertions were not
retained: standalone AppKit probes could not acquire a key window in this runner,
although the native query field and find bar initialized. Actual match navigation
and full SwiftUI focus interaction remain manual verification, not claimed tested.

Manual check: open a note with repeated words, ⌘F from sidebar and editor, type a
query, navigate with ⌘G/⌘⇧G, Escape, type and undo; repeat in both modes and on an
unsaved draft. Confirm ⌘1/⌘2, filename Escape, and saves still behave as documented.


### Sidebar toggle shortcut — 2026-10-17

⌘3 now toggles sidebar visibility, replacing ⌘⌥S. The existing header button,
layout, and ⌘1/⌘2 focus commands are preserved. Updated ContentView.swift,
README.md, PROJECT_CONTEXT.md, and this document. Signed Debug build and
`git diff --check` passed; no new tests for this shortcut-only change. Manual
check: press ⌘3 twice to collapse/reopen, then verify ⌘1 and ⌘2 focus as before.


### Documentation consistency review — 2026-10-17

Updated the root README, roadmap, docs index, session handoff, project context,
Codex instructions, and current-controls summary to match the latest save/accept,
focus/toggle, Find, deletion, and Undo behavior. Corrected stale manual shortcuts,
validation counts, and claims about undo surviving note navigation. Historical
milestone policies and deferred feature steps remain preserved. Documentation-only
change. Also corrected a broken FILESYSTEM_INDEX link in SQLITE_FOUNDATION.md.
`git diff --check` passed and all 52 local Markdown link targets exist (anchor
validation not included). No source changes, new build, or new test run.


### Hold ⌘K for shortcut reference — 2026-10-17

Holding ⌘K shows a compact, rounded ultra-thin-material shortcut card over the
current window. Releasing K or Command hides it; window/app deactivation also
hides it. The overlay takes no keyboard focus or pointer input. App-local key
monitoring consumes ⌘K repeats and K repeats after Command-up until K-up so the
hold does not type stray K characters. Focus-loss observers and event monitors
are removed when the bridge detaches/deinitializes. Existing editor, sidebar,
Find, save, filename, and undo commands remain in the reference list.

Changed implementation: ContentView.swift; README, project context, docs index,
session handoff, and this status document updated. Signed Debug build and
`git diff --check` passed. No new automated test run for this UI-only change.
Manual verification remains: hold ⌘K in editor/sidebar/search/rename fields;
release K first, then Command first while K continues to be held; ensure no stray
characters or focus changes. Switch apps/windows while held and verify dismissal.
Check the translucent card at minimum window size and with accessibility settings.


### Shortcut panel text layout — 2026-10-17

Removed the expanding key-column frame that could squeeze shortcut descriptions.
Descriptions retain their full vertical size; key labels use their intrinsic
width and trailing column alignment. The card is now 430 points wide and keeps
its natural height instead of compressing rows.

Signed Debug build and `git diff --check` passed. A temporary NSHostingView probe
using the actual KeyboardShortcutCard and DesignSystem source measured 430 × 432
points, fitting the minimum 680 × 480 window with 16-point outer padding. No full
test-suite rerun for this layout-only change. Visual verification in the running
app remains manual; hold ⌘K at minimum window size and check every description
and key label. Changed files: ContentView.swift and this document.


### Shortcut key labels at the right edge — 2026-10-17

Replaced the intrinsic-width Grid with full-width horizontal rows and a flexible
spacer between each description and its fixed-width key label. All key labels
now share the card's trailing content edge. The card still measures 430 × 432
points in the NSHostingView probe, fitting the minimum window with outer padding.
Signed Debug build and `git diff --check` passed; no full suite rerun for this
layout-only adjustment. Changed files: ContentView.swift and this document.
Visual alignment in the running app remains a manual check.


### Per-note text undo survives navigation — 2026-10-17

NoteEditorSession retains each visited note's native NSTextView, including its
own UndoManager and selection, for this app session. Recreated SwiftUI wrappers
reattach that view and reconnect delegates/callbacks. A bridge identity prevents
old queued focus/find work from affecting a remounted editor; teardown detaches
only its own coordinator. NoteStore keeps sessions by canonical full path, assigns
stable editor IDs, registers drafts on first save, migrates entries on app rename,
and carries a session through deletion/restoration. It still rereads disk when
opening a note; changed text clears that note's incompatible history. Find request
tokens are cleared on navigation so stable identities do not replay old requests.

All 130 tests and signed Debug build passed before the appearance work below.
Four new tests cover erase → navigate → return → native Undo/Redo with live
preview/binding, independent histories/selection, first save plus rename, reset
on external edits, and text history after restoring a deleted unsaved draft.
Undo changes remain drafts until saved and keep the existing conflict baseline.
No app-wide chronological undo, rename/navigation undo, deletion redo, history
persistence, or external-rename history tracking was added. Retained native text
views/history use memory proportional to visited notes and are released on quit.

Changed source: MarkdownEditor.swift, NoteStore.swift, ContentView.swift;
NativeEditorTests.swift and canonical user/handoff docs updated. Corrected an
existing misspelled trash button call (icocannButton → iconButton) that blocked
the app build. Manual verification: erase in A, edit B, return to A, ⌘Z/⌘⇧Z;
repeat through saving, app rename, deletion/restore, and keyboard focus changes.


### Configurable subtle window translucency — 2026-10-17

Added AppearanceConfiguration.swift for the enable toggle, native material, and
base/editor/sidebar tint opacity. A native NSVisualEffectView blends behind the
window; the NSWindow is transparent while text remains fully opaque. Content
surfaces use independent Nord tints over the material. The SwiftUI accessibility
Reduce Transparency setting replaces the material with a solid background;
disabling the configuration restores solid surfaces. No runtime settings UI added.

Registered the file in Xcode and the direct-source test runner. Updated
DesignSystem.swift, ContentView.swift, NoteStore.swift, README and handoff docs.
Visual strength/contrast and accessibility fallback need manual desktop checks.

Validation after appearance integration: all 130 tests passed, signed Debug build passed, and `git diff --check` passed.


### Solid native title bar and header — 2026-10-17

Restored solid window chrome: the native title bar disables transparent title-bar
appearance and uses the Nord window base color. The app's header has its own
solid Nord background. Native behind-window material and configured tints remain
on content surfaces. Appearance configuration comments and README/project context
now state that the title bar/header are always opaque.

Signed Debug build and `git diff --check` passed. No full suite rerun for this
appearance-only correction. Manual verification: check the traffic-light area and
header against a bright desktop while confirming editor/sidebar translucency.
Changed files: NoteStore.swift, ContentView.swift, AppearanceConfiguration.swift,
README.md, PROJECT_CONTEXT.md, and this document.


### Live Appearance settings — 2026-10-17

Added a native Settings scene (⌘,) and AppearanceSettingsView with a global
translucency toggle, separate header/editor/sidebar opacity sliders, percentages,
and Restore Defaults. One shared AppearanceSettings observable model applies
changes immediately in the main window and persists them in UserDefaults. Invalid
stored values are bounded or use factory fallbacks. Disabling translucency keeps
slider choices for later; restoring defaults persists source factory values.

Header defaults to zero extra tint over the base material, restoring its earlier
translucency. The native traffic-light/title bar remains opaque regardless of
preferences. NSWindow opacity updates live; content changes do not replace editor
sessions. Text is opaque and accessibility Reduce Transparency forces solid
backgrounds. Material and base-window tint remain source-only configuration.

Changed implementation: AppearanceConfiguration.swift, AppearanceSettingsView.swift,
DesignSystem.swift, ContentView.swift, NoteStore.swift, NtsApp.swift, Xcode
project, and Tests/main.swift; canonical appearance/user/handoff docs updated.
The held-shortcut card includes ⌘, without adding another row.

All 133 tests and the signed Debug build passed; `git diff --check` passed.
Three new tests cover preference persistence/independent values, disabling and
re-enabling, persistent Restore Defaults, and malformed stored opacity bounds.
A native NSHostingView probe measured the actual settings view at 440 × 354 points.
Interactive desktop validation remains: ⌘, opens Settings; each slider changes only
its target surface; toggle/Restore Defaults work; relaunch preserves choices;
traffic lights remain solid; Reduce Transparency uses solid content backgrounds;
editing/selection/undo and Find remain intact while settings are adjusted.


### One native toolbar row — 2026-10-17

Moved the existing sidebar toggle, view-mode, folder, refresh, and
new-note controls into a native unified compact toolbar beside the traffic-light
controls. Navigation placement puts the toggle/title after window controls;
primary actions stay trailing. Removed the app's separate 40-point header row.
Native title text is hidden with a macOS-14-compatible AppKit property. macOS
manages window controls, spacing, dragging, fullscreen behavior, and overflow.

The native window-control backdrop stays solid. The previous header opacity
preference still drives native toolbar tint and is labeled Toolbar tint in Settings;
its stored key/defaults are retained. Editor/sidebar appearance remains independent.
Existing shortcut actions, help, disabled states, and accessibility labels remain
on their buttons. No editor session or content/save changes.

Changed implementation: ContentView.swift, NtsApp.swift, NoteStore.swift,
AppearanceSettingsView.swift; README and canonical handoff/appearance docs updated.
Signed Debug build and `git diff --check` passed. The suite was not rerun for this
toolbar layout change; its then-latest result was 133 passing tests. Manual verification: at minimum/default/fullscreen sizes, check
one row, toggle immediately after dots, no duplicated native title, all action
buttons and ⌘3, dragging/resizing, title-bar backdrop, and Toolbar tint behavior.


### Plain unified-toolbar items — 2026-10-17

Hid the native shared glass/group backgrounds around the navigation title/toggle
and trailing action icons on macOS 26+, keeping the unified row and existing plain
button styles. An availability-gated ToolbarContent helper preserves macOS 14–15
compatibility. No window controls, spacing, actions, or appearance preferences
were changed. Signed Debug build and `git diff --check` passed; no test rerun for
this styling-only change. Manual check: no persistent rounded/circular group
backgrounds around toolbar icons; hover/disabled states and clicks work.
Changed files: ContentView.swift, README.md, PROJECT_CONTEXT.md, and this document.


### Slightly larger shortcut reference text — 2026-10-17

Increased shortcut row text from 11 to 12 points and reduced row spacing from
6 to 5 points. Key labels remain right-aligned. NSHostingView measured the updated
panel at 430 × 433 points, within the minimum window's padded bounds. Signed Debug
build and `git diff --check` passed; no full suite rerun for this font-only change.
Changed files: ContentView.swift and this document.


### Remove sidebar bottom folder label — 2026-10-17

Removed the small folder-name label (or LOCAL · MARKDOWN fallback) at the bottom
of the notes sidebar. This removes its reserved padding as well. Sidebar note
browsing, focus shortcuts, and folder selection are unchanged. Changed files:
ContentView.swift and this document. No new tests for this label-only removal.

Sidebar label validation: signed Debug build passed with cached package resolution, and `git diff --check` passed. The first build was interrupted after stalling before compilation; no test suite rerun for the label removal.


### Local note embeddings E1–E3 — 2026-10-17

E1 evaluated `intfloat/multilingual-e5-small` at immutable revision
`614241f622f53c4eeff9890bdc4f31cfecc418b3` with the pinned MLX runtime; the
revision's model card declares MIT. Results and measured model size are recorded
in `NOTE_EMBEDDINGS_AND_MAP_PLAN.md`. E2 adds SQLite BLOB support, schema v5,
embedding-space metadata, source-bound job records, CAS state transitions,
strict Float32 little-endian vector validation, current-source filtering, and
recovery of interrupted jobs. E3 adds explicit model download/enable, a
production MLX backend, saved-note backfill and save/refresh processing,
bounded retries, cancellation/recovery, and serialization with filename
inference. Projection and Map UI remain unimplemented; real-model in-app
download/inference still needs manual acceptance.

The full runner passed **145 tests**. The ARM64 Debug app build passed.
`git diff --check` passed. Desktop model-download/inference behavior and all
projection/map behavior remain to be accepted in later steps.


### Evaluation resource instrumentation — 2026-11-02

Python title evaluation now records per-session phase wall/CPU time and process
peak RSS, attempt CPU consumption and retry-inclusive throughput. Aggregate metrics
flow through standalone reports and local MLflow. Resumed sessions retain costs;
missing token counts remain unmeasured. See the
[measurement semantics](../Developer/TitleEvaluation/README.md#resource-measurements).
GPU utilization, energy, FLOPs and scoring-process instrumentation remain outside
this implementation. No real model or private dataset was executed for this change.


### Optional SmolLM and minimum Gemma candidates — 2026-11-02

Added disabled revision-pinned SmolLM2-1.7B-Instruct (author-published 8-bit MLX)
and Gemma 3 270M IT (4-bit MLX) entries to the Python experiment template and
working YAML, included in the disabled shared-control profile. Configuration
addition only: no weights downloaded, no inference or actual load verification.
See [the selected artifacts](SMALL_TITLE_MODEL_RESEARCH.md#user-selected-additions--2026-11-02).
