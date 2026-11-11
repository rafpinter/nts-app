# Incremental Roadmap

Milestones **1.1–1.5 are complete**. **2.1 SQLite foundation is implemented** using system SQLite3. **2.2 filesystem indexing is implemented** with disposable database-local IDs. **2.3 date metadata is implemented**; local model evaluation is implemented as a dev-only tool (3.1); in-app filename suggestions are implemented (3.2); safe application is implemented (3.3); summaries are next (3.4); tags are deferred to [FUTURE_IDEAS.md](FUTURE_IDEAS.md#deferred-tag-features). **1.5 was accepted by the user on 2026-10-14**. See [IMPLEMENTATION_STATUS.md](IMPLEMENTATION_STATUS.md) for actual scope and validation.

Work in small, reviewable vertical slices. Do **not** implement all phases at once.

## Phase 1 — Functional note-taking app, polished UI

### 1.1 App foundation and visual shell

- Create a native SwiftUI macOS Xcode project; document how to build/run it.
- Build a Nord-inspired dark window with a sidebar, editor area, and carefully designed empty states.
- Define palette, font/type scale, spacing, reusable UI primitives; no model integrations or SQLite necessary yet.
- Let the user review the look and feel before heavy feature work.

**Acceptance:** app launches locally; visual shell is coherent; no real notes required yet.

### 1.2 Filesystem note model

- User-selected local notes directory; permission/access approach appropriate to macOS.
- List `.md` files; create a note with temporary collision-safe timestamp filename; open, edit, and explicitly save text. Implemented follow-up: automatic saving before switching/creating/closing/quitting, with failures blocking the action.
- Delete with a safe/confirmable mechanism; surface I/O errors instead of silently losing work.
- Sort by creation date (with sensible fallback when creation timestamps are absent).

**Acceptance:** files created in Finder can be read from the app, and files saved by the app open in other Markdown editors.

### 1.3 Editor polish and shortcuts

- Simple Markdown source editor, readable monospace font, caret/selection, scrolling, unsaved changes indication.
- Add lightweight syntax highlighting only if it does not undermine typing/cursor behavior.
- Shortcuts for new/open/save/delete and basic navigation.

**Acceptance:** editing feels stable and pleasant with long notes, Unicode, Markdown, and keyboard use.

### 1.4 Images and assets

- Drop or paste an image into the note. Copy/store it in the selected notes folder's `imgs` subfolder and insert a **relative Markdown link**, e.g. `![image](imgs/<safe-file-name>.png)`.
- Avoid collisions; handle unsupported files/error paths; preserve Markdown portability.

**Acceptance:** images resolve in Markdown tools that support relative paths, independent of this app.

### 1.5 Phase-1 hardening

Completed and accepted by the user on 2026-10-14. See the implementation status
for validation and remaining manual-check limitations.

- Tests for filename collisions, read/write, ordering, delete behavior, image asset handling, and basic app lifecycle.
- UI refinements and bug fixes driven by actual use.

**Explicitly out of scope for Phase 1:** SQLite, text/screenshot semantic search, LLM-generated names, summaries/tags, image captions, embeddings, semantic maps, and full Markdown rendering.

## Implementation order for Phases 2–4

The numbered steps below are the implementation order. Finish and verify each step before starting the next; implement only the requested step. Substeps run in their listed order and are separately reviewable. A decision gate must be resolved before its dependent implementation; it does not authorize choosing an undecided product policy silently.

**SQLite evolves throughout all three phases.** Phase 2 establishes storage and filesystem indexing. Phases 3 and 4 add their own migrations, data access, synchronization, recovery behavior, and tests with each feature. Do not create future tables in advance. Each schema change must preserve existing records, and each derived-data feature must handle changed/missing sources without losing Markdown or manual metadata.

See [SQLITE_AND_SEARCH_SPEC.md](SQLITE_AND_SEARCH_SPEC.md) for architecture constraints. This roadmap owns execution order; the specification owns data and safety requirements.

## Phase 2 — SQLite foundation and filesystem metadata

Use **system SQLite3**, as selected by the user. The database belongs in app-owned **Application Support**, resolved through Foundation with sandbox support. Creation and migrations run automatically; users install only the app. Markdown editing and image insertion remain usable when the database fails.

### 2.1 SQLite foundation

Implemented on 2026-10-14. See [SQLITE_FOUNDATION.md](SQLITE_FOUNDATION.md) for
storage, migration, durability, failure policies, and verification.

- Add a small Swift access layer around system SQLite3, with serialized database work off the main UI thread and safe connection/statement lifetimes.
- Resolve a stable app-support location; create/open the database and initialize it through the app lifecycle.
- Add schema versioning and ordered transactional migrations, foreign keys, short transactions, and a deliberate journal/busy-handling policy.
- Surface initialization/migration failures without silently deleting the database or blocking Markdown use; refuse unsupported newer schemas safely.
- Test first launch, reopening, migration rollback, transaction rollback, foreign-key enforcement, and unavailable/corrupt database behavior.

**Acceptance:** the app opens its database without user setup; failures preserve existing data and leave note-taking usable. No note registry, tags, attachments, AI, or search tables yet.

### 2.2 Note registry and filesystem reconciliation

Implemented on 2026-10-14; see [FILESYSTEM_INDEX.md](FILESYSTEM_INDEX.md) for
identity/folder policy, explicit-refresh behavior, safety, and verification.

1. **Recovery decision resolved (2026-10-14):** IDs are database-local and disposable. Database loss permits fresh IDs and recomputation of descriptions/embeddings. No identity frontmatter or manifest. Define folder scoping and safe rename handling in this implementation; ambiguous external renames can be reindexed rather than forcing ID continuity.
2. Add the note/folder registry migration, relative paths scoped to the correct folder, content hashes, and indexing state.
3. Reconcile initial scans and app create/save/rename/Trash operations after successful filesystem changes. Detect external creates/edits/deletes/renames through a documented refresh/watch strategy.
4. Preserve derived outputs across recognized renames where practical; reindex/recompute ambiguous cases rather than guessing associations. ID continuity is not required. Never overwrite an open draft during reindexing.

**Acceptance:** repeat reconciliation is idempotent; duplicate contents/filenames, folder switching/moves, external changes, and database downtime do not misassociate notes or lose drafts. Test these cases and the approved identity policy.

### 2.3 Note metadata and recovery rules

Implemented: see [NOTE_METADATA.md](NOTE_METADATA.md) for date ownership, schema 3, recovery limits, and verification.

- Define observed filesystem timestamps versus app-preserved creation dates, imported-file fallbacks, and ownership of each value.
- Add any required metadata migration and integrate persisted dates with chronological browsing without changing the portable files.
- Define exactly what a registry rebuild can recover and which values need protection; do not promise original creation dates after a copy if they cannot be recovered.

**Acceptance:** dates and ordering remain predictable across edits, renames, imports, and restarts; rebuild limitations are documented and tested.

**Phase-2 exit:** registry, date metadata, migration upgrades, and rebuilding work together; database failure leaves files usable. Tags are deferred to the ideas backlog. Attachment indexing moves to 3.5 so filename generation can come first.

## Phase 3 — Local AI, starting with filenames

Priority updated 2026-10-15: local LLM filename generation comes next. Manual and generated tags are deferred, with all original steps and acceptance criteria preserved in [FUTURE_IDEAS.md](FUTURE_IDEAS.md#deferred-tag-features). No tags or attachment registry are prerequisites for filenames. This is a roadmap change only; implementation of each slice still requires a request.

### 3.1 Local text-model evaluation and integration

Implemented as a development-only native Swift evaluator; see [LOCAL_MODEL_EVALUATION.md](LOCAL_MODEL_EVALUATION.md).
Initial user-selected model: `mlx-community/Qwen3-0.6B-4bit`; model ID/revision
are configuration, allowing later replacement and a possible future selector.
Evaluation measurements remain dev diagnostics. Phase 3.2 now loads the model
in the app after explicit setup; filename quality still needs refinement.

- Evaluate a small text model/runtime on representative notes and an 8–16 GB Apple Silicon memory budget; choose the runtime/model before building its persistent outputs.
- Integrate local model availability/loading and an AI-disabled path. Model delivery/setup must be explicit; note content stays on device.
- Measure latency and memory, keeping loading/inference off the UI thread.

**Acceptance:** an installed model produces a small local test output without disrupting editing, and the app remains usable when the model is missing/disabled.

### 3.2 Background processing and filename suggestions

Implemented: see [FILENAME_SUGGESTIONS.md](FILENAME_SUGGESTIONS.md). All production
model/prompt/generation settings are in `Nts/FilenameModelConfiguration.swift`.
Current trigger policy (2026-10-17): first explicit save of a nonempty new draft
saves a timestamp file and requests a preview. ⌘S with edits to an existing file
only saves text; it never generates or applies a name. ⌘⇧S explicitly regenerates,
saving pending edits first. Clean ⌘S accepts a ready preview; no candidate means
a silent no-op. Explicit Generate/Apply remains; Escape cancels/dismisses naming.
Refresh invalidates external changes without new inference. Automatic saves
remain plain saves. No name is applied by generation alone.

1. Save/preview/regenerate/accept are distinct operations. Coalesce requests and
   preserve changed-save events for future embeddings on every successful changed
   save. Clean regeneration or accepting a filename does not trigger embeddings.
2. Add only the migrations needed for filename processing state and outputs: source hash, model/revision, prompt version, generation time, status, errors, and retry state.
3. Generate a concise filename from saved note text in the background. Commit a result only if its source/version still matches. Persist and display safe filename suggestions with source/model provenance; do not rename automatically.
4. Handle invalid names, empty notes, stale suggestions, and collisions in the suggestion/acceptance experience.
5. Handle restart, cancellation, retries, unchanged sources, and missing notes idempotently.

**Acceptance:** a successful Markdown save remains successful even when AI fails; tests cover stale-output races, repeated saves, restart/retry, and deleted notes. A suggestion cannot silently change a file, identity, or link.

### 3.3 Safe application of suggested filenames

Implemented 2026-10-15: explicit Apply revalidates the saved source, configuration,
and filename, then uses the existing coordinated rename path. Editor state and
healthy-index metadata are preserved. **Link policy:** inbound Markdown/external
references are not rewritten; the UI states this before Apply. Same-folder
relative image references remain intact. See [FILENAME_SUGGESTIONS.md](FILENAME_SUGGESTIONS.md)
for failure/recovery behavior, 96 passing tests, and remaining desktop checks.

- Resolve the policy for inbound Markdown references and external links before implementing AI-assisted rename.
- Extend the existing rename flow to apply a suggestion explicitly, coordinating file changes and registry identity; handle partial failures and collisions.

**Acceptance:** applying a suggestion preserves the draft, metadata, and references covered by the approved policy. Test failure recovery; unattended auto-renaming remains unimplemented unless separately requested.

### 3.4 Summaries

- Reuse the filename processing pipeline for a short summary with minimal display/status controls.
- Add summary storage and source/model provenance only when implementing this slice; commit a result only if its source/version still matches.
- Retain save independence and restart, cancellation, retry, unchanged-source, and missing-note handling from 3.2.

**Acceptance:** summaries survive restart, stale results are rejected, and failed processing never turns a successful Markdown save into a failure. Test summary generation/display and pipeline failure/recovery behavior.

### 3.5 Attachment registry

1. **Decision gate:** choose shared-image association semantics for one image referenced by multiple notes.
2. Add attachment and note-association migrations, relative asset paths, image hashes, media types, and needed file properties.
3. Index existing Markdown image references and app imports; reconcile changed/missing images and removed links. Support multiple images per note and shared assets.
4. Preserve the existing policy that undo, link removal, and note deletion do not automatically delete image files.

**Acceptance:** indexed images resolve to every referencing note without duplication or premature deletion; reconciliation and migration tests cover shared/missing/changed assets. No captions, fingerprints, embeddings, or search yet.

### 3.6 Local image descriptions

- Evaluate/select a local vision runtime/model within the same memory budget before integrating it; avoid loading text and vision models together unnecessarily.
- Add attachment-output migrations for captions and image/model provenance; reuse background processing and source-hash validation.
- Generate/display descriptions per image, including existing assets under the agreed processing policy. Shared images must not trigger duplicate work.

**Acceptance:** captions survive restart, stale results cannot replace newer ones, and model failure never blocks image insertion or saving. Captions alone do not implement screenshot search.

**Phase-3 exit:** verify the full save/processing lifecycle, safe filename application, attachment reconciliation/recovery, upgrades from Phase 2, AI-disabled behavior, and measured memory/latency before Phase 4. Deferred tags are not an exit requirement.

## Phase 4 — Search and semantic discovery

### 4.1 Keyword and phrase search

- Add FTS5 migrations and derived note-text indexing, plus captions where useful; maintain source-version tracking and rebuild support.
- Synchronize the index with saves, external reconciliation, captions, and deletions.
- Add text search UI with keyword/phrase results resolving to current Markdown files, useful snippets, and keyboard navigation.

**Acceptance:** lexical search works with AI disabled; tests cover external edits, deleted notes, phrase matches, index rebuild, and migration.

### 4.2 Semantic text search

1. Evaluate/select a local text embedding model and retrieval approach within the memory budget; decide chunking/aggregation for long notes and model-version changes.
2. Add note-embedding migrations with source hashes, model/revision, vector type/dimensions, and processing state. Generate incrementally through background work.
3. Embed queries and retrieve by original-vector similarity; combine lexical and semantic text results without suppressing exact matches or comparing incompatible spaces.

**Acceptance:** meaningful text queries find current notes; missing/stale/incompatible embeddings have a defined fallback. Test ranking fixtures, invalidation, restart, and model upgrades.

### 4.3 Image indexing for visual retrieval

1. **Decision gate:** select/evaluate the vision embedding strategy, including whether it shares a compatible text/image space. Decide whether perceptual fingerprints are included. Decide OCR's role; if approved, insert its implementation and storage substep here before screenshot retrieval.
2. Add image-embedding migrations and, if selected, versioned fingerprint/OCR records. Index each image independently with hashes and model provenance.
3. Handle shared images, changed/missing assets, reprocessing, and model changes without comparing incompatible vectors.

**Acceptance:** visual retrieval data is available for individual images within the memory budget; test synchronization and model/version invalidation. Screenshot search does not yet exist.

### 4.4 Screenshot query and matched-image results

- Add paste/drop image query input to search, distinct from importing an image into a note. Query images are transient by default.
- Encode the query using the compatible vision model; use selected fingerprint/OCR signals where applicable.
- Retrieve individual matching images and return all valid referencing notes, showing the particular matched image and why it matched.

**Acceptance:** queries find near-duplicate and semantically similar screenshots even when surrounding note prose is unrelated. Test multiple/shared images, missing assets, and query handling; caption-only retrieval is insufficient.

### 4.5 Unified results and search hardening

- Consolidate lexical, semantic text, and image-result presentation; calibrate/fuse only compatible retrieval signals and make match reasons clear.
- Add cancellation, bounded memory use, loading/error states, and defined behavior with incomplete indexes or unavailable models.
- Benchmark representative libraries on constrained Macs and test upgrades/rebuilds across all search indexes.

**Acceptance:** search stays useful offline and responsive during background indexing; exact matches remain discoverable and results point to valid files/images.

### 4.6 Versioned 2D projection

- Choose/evaluate a projection algorithm and a note-level representation if text retrieval uses chunks.
- Add projection-run and note-position migrations with model/input versions, parameters, and timestamps.
- Compute projections in the background; define layout drift, regeneration, and handling of notes without current embeddings.

**Acceptance:** a projection can be rebuilt without modifying original embeddings, manual metadata, or files. Test stale-input rejection and version association; similarity never uses 2D distances.

### 4.7 Interactive semantic map

- Build map navigation from the versioned positions: select/open notes, pan/zoom, and communicate incomplete/stale layouts.
- Preserve editor drafts and native keyboard/accessibility behavior when navigating from the map.

**Acceptance:** the map helps rediscovery without presenting projected distances as exact similarity. Validate navigation, layout updates, and performance on representative libraries.

## Editor rendering follow-ups

Source/live-preview editing is already implemented in the native editor. Any
additional rendering/reading modes or parser expansion require a separate request.

## Working style

Follow the [required iteration contract](CODEX_INSTRUCTIONS.md#required-iteration-contract): one requested feature per reviewable slice, with verification results and limitations. Do not advance to another slice or phase without a user request.
