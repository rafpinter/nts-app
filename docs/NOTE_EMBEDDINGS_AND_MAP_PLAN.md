# Local note embeddings and 2D map — implementation handoff

Status: **E1–E4 complete; E5 implemented (2026-10-17); E6 automated hardening complete, acceptance outstanding.**
A follow-up aligns regenerated PCA layouts to the previous persisted layout. E3
adds explicit local embedding-model setup, a production MLX embedding backend,
saved-note backfill/refresh/save processing, durable retries, and shared MLX
resource serialization. E4 adds deterministic PCA reduction and schema-v6 projection
persistence. E5 adds Notes / Map modes, the persisted-layout canvas, status and
unplaced-note accounting, accessible map points, overlap choices, and guarded
navigation. E6 automated lifecycle and reducer-scale checks pass. Real-model,
interactive desktop/VoiceOver, Reduce Transparency, and signed-build acceptance
remain outstanding. Read this document and inspect the actual checkout before
continuing.

## Completed evaluation and storage evidence

- **E1 model:** `intfloat/multilingual-e5-small`, immutable model and tokenizer
  revision `614241f622f53c4eeff9890bdc4f31cfecc418b3`; license **MIT** per the
  model card at that revision. The required evaluator artifact files total
  **487,726,239 bytes** (about 465.2 MiB). Runtime pins:
  `mlx-swift-lm` 2.29.3, `mlx-swift` 0.29.1, `swift-transformers` 1.1.9.
- Native evaluation passed English/Portuguese similarity fixtures, Unicode,
  seven-chunk long-note coverage, repeated determinism, unload/reload, and
  offline reload. Python/PyTorch parity passed 20 chunks with maximum absolute
  error `1.61e-7` and minimum cosine `0.99999988`. Cold load was 0.553 s,
  short-fixture inference after warmup 0.002–0.004 s, seven-chunk long-note
  inference 0.107–0.122 s, peak MLX memory 638 MiB, and peak RSS
  613 MiB on the evaluation machine. A pair of long notes differing near the
  end had cosine 0.9943, confirming tail coverage but also the expected topic
  dilution from weighted averaging.
- Reports are local and ignored by Git:
  `Developer/LocalEmbeddingEval/results/evaluation.json`,
  `evaluation-parity.json`, and `offline.json`.
- **E2:** added Float32 little-endian BLOB access, schema v5, immutable embedding
  space records, source-bound job tokens and CAS transitions, vector integrity
  checks, current-source-only reads, and interrupted-job recovery. Migration,
  rollback, BLOB/NULL/Unicode, stale/missing source, model-space isolation,
  failure/retry, and malformed-vector tests pass. The fake encoder is test-only.
- **E3:** added first-Map-use model download/enable, pinned-artifact validation,
  chunked production inference, MainActor status/progress, existing-note backfill,
  changed-save and refresh handling, latest-source checks, cancellation/disable,
  bounded inference retries, and interrupted-job recovery. Filename and
  embedding inference share a tested exclusive MLX resource gate; filename AI
  remains independently opt-in. Live model download/inference from the shipping
  app still needs manual acceptance with the real model.
- The full test runner passed **145 tests**; the ARM64 Debug app build passed.
  The test coverage includes controller backfill, empty notes, changed saves,
  external refresh, rapid-save coalescing, disable/re-enable recovery, retries,
  and MLX resource exclusivity. Projection and Map behavior remain unimplemented.

## Scope and decisions

Deliver local text embeddings stored in SQLite, a separate 2D projection, and a
**Map** tab: one point per eligible saved Markdown file, current filename on hover,
click to open the file in the existing editor. Scope is the selected notes folder.

This request prioritizes the text-embedding/map subset of roadmap 4.2/4.6/4.7.
Summaries (3.4), attachment registry, captions, tags, FTS, query UI, image embeddings,
and screenshot search are **not prerequisites and are not included**. Their
existing documented steps remain deferred, not deleted or marked complete.
Choosing a text encoder does not settle the future text/image embedding-space choice.

Proposed defaults, to verify in E1 rather than silently treat as user selections:

| Decision | First implementation |
| --- | --- |
| Runtime | `MLXEmbedders` from the already-pinned `mlx-swift-lm` 2.29.3 |
| Model | Prefer `intfloat/multilingual-e5-small` for English/Portuguese notes; 384 dimensions |
| Smaller English-only alternative | `sentence-transformers/all-MiniLM-L6-v2`; 384 dimensions |
| Representation | One normalized vector per file, pooling token-bounded chunks of its saved text |
| Projection | Centered PCA to two components using system Accelerate/LAPACK |
| Map refresh | Initial build when ready; contextual **Update map** for subsequent changes |
| UI | Notes / Map modes in the existing window; preserve the single-row native toolbar |

The E5 model card describes multilingual support, a 512-token limit, mean pooling,
normalization, and `query:` prefixes for symmetric similarity/clustering. Follow
that contract for this map; do not borrow passage-retrieval prefixes accidentally.
MiniLM's card describes English text and a 256-wordpiece default limit. Evaluate
actual tokenizer/pooling behavior with the chosen pinned artifact, not just its
registry name. Neither model is the current filename-generating Qwen model.
Sources: [E5 model card](https://huggingface.co/intfloat/multilingual-e5-small),
[MiniLM model card](https://huggingface.co/sentence-transformers/all-MiniLM-L6-v2).

PCA is a proposed dependency-light baseline, not a promise of separated semantic
clusters. Evaluate the resulting neighborhood quality before accepting it. UMAP
or another nonlinear reducer can be a later replacement behind the same boundary;
do not add a Python service or implement a custom UMAP algorithm for v1.

## Existing integration points — verified in this checkout

- Native SwiftUI/AppKit app, macOS 14 minimum. Existing local inference targets
  Apple Silicon; retain a clear unsupported/disabled embedding path on Intel.
- `NoteStore`: saved files are authoritative; `onSaved(URL)` fires only after a
  successful changed-content save, including lifecycle/navigation saves. Clean
  saves, filename acceptance, failed saves, and typing are not embedding triggers.
- `DatabaseStatus`: ordered reconciliation, `onReconciled(URL)`, and
  `waitForPendingWork()`. Startup/folder activation/Refresh discover external changes;
  there is no filesystem watcher. Hook callbacks by fan-out, retaining filename work.
- `SQLiteDatabase` actor: schema **6**, application-owned Application Support DB;
  `notes` has disposable IDs, folder/path, source hash, and indexed/error state.
  Recognized app renames preserve IDs; external renames may not. A successful
  scan deletes metadata for confirmed missing notes; failed folder scans preserve
  existing metadata.
- **Important prerequisite:** `SQLiteValue` supports integer/real/text/null only.
  Add BLOB binding/reading before storing vectors; do not assume it exists.
- The pinned package exports `MLXEmbedders`; its sources are in
  `Libraries/Embedders/`. The app links this product and uses the pinned API,
  not newer `main` examples.
  [Pinned package manifest](https://github.com/ml-explore/mlx-swift-lm/blob/2.29.3/Package.swift).
- `NtsApp` composes services; `ContentView` owns sidebar, native toolbar,
  keyboard focus, and note editor. `NoteEditorSession` preserves per-file text
  undo/redo across navigation, first save, app rename, and deletion restoration.
- SQLite index schema remains v4; overall database schema v5 adds E2 embedding
  tables. E3 registers its source files and the MLXEmbedders product in Xcode.
- Latest full suite: **145 passing tests** after E3 worker integration. Re-run
  the suite after each subsequent implementation slice.
  Preserve user changes/uncommitted work; do not reset the checkout.

## Boundaries and configuration

Keep plain Swift values between UI, database, and numerical/model workers:

- `EmbeddingModelConfiguration.swift`: model/revision, tokenizer revision, dimensions,
  precision, prefix, pooling/normalization, text preparation/chunk policy, batch and
  retry limits. Separate from filename and appearance configuration.
- `NoteEmbeddingBackend` protocol and MLX backend: explicit download, load local weights,
  encode chunks, unload. Return `[Float]`; never pass MLX arrays across actors.
- Embedding controller: durable queue coordination, indexing integration, progress,
  cancellation, retry. UI state on MainActor; inference/tokenization/file work off it.
- SQLite extension for embedding jobs/results; projection worker/service behind a
  small reducer interface; map view model receives immutable point snapshots.

Fingerprint the complete vector-space contract (including aggregation and runtime/
implementation version), not just model ID or dimension. Pin a real immutable model
revision during E1; verify required weights/config/tokenizer/pooling files at that
revision. A future model change creates an incompatible space and a fresh backfill.
The app currently uses the E1-selected E5 configuration without a model selector;
keep source configuration easy to change. Model download and Map indexing have a
separate explicit opt-in with progress, disable, and retry. Enabling filename AI
does not enable or download this encoder.

## Saved-text representation

Use UTF-8 saved Markdown content, not filename, LLM summary, image pixels, or dirty
editor text. Preserve Markdown for v1; trim only for empty detection and version any
line-ending/text normalization. Renaming a file must not require re-embedding it.

Tokenize using the actual encoder. Proposed E5 chunk budget: 384 content tokens,
plus prefix/special tokens within its supported context; no overlap initially.
The English fallback needs its own smaller budget. Never truncate the entire note
to the first context window. Stream all chunks, attention-mask-aware mean-pool
according to the model contract, normalize chunk vectors, average weighted by
content-token count, then normalize the file vector. Record that exact policy.
Only persist the file vector initially; do not prebuild chunk-retrieval tables.

Reject wrong dimension, NaN/infinity, zero norm, or malformed output. Empty/whitespace
notes get an explicit skipped-empty state, not a fake zero vector. Long notes need
cancellation/progress and bounded working memory; if a safety size limit is required,
show a reason and count excluded files rather than silently dropping their endings.
Averaging can dilute mixed topics; include a long-note fixture whose relevant text
is near the end in E1, and treat this as a known v1 limitation.

## Storage contract — migrate only when its step starts

Extend the existing system SQLite layer, with transactions and bound parameters.
No vector database, extension, extra server, or Markdown/frontmatter changes.

| Planned table | Minimum data / invariant |
| --- | --- |
| `embedding_spaces` | Fingerprint PK, full config JSON, model/tokenizer revisions, dimension, vector encoding, pipeline version |
| `note_embeddings` | PK `(note_id, space_id)`, FKs, source hash, job token, queued/processing/ready/error/skipped-empty state, vector BLOB/hash, attempts/error/time |
| `projection_runs` | Complete run ID, folder/space, input fingerprint, PCA/version/parameters, mean/basis, creation time |
| `note_positions` | PK `(run_id, note_id)`, source/vector hashes, finite `x/y`; FK to run and note |

Proposed migrations: v5 adds embedding records; v6 adds projection records. Verify
current schema first and use the next available versions if the checkout advanced.
Store original vectors as explicitly encoded Float32 little-endian (384 values =
1,536 bytes), validate length and finite values when reading/writing. Test empty BLOB
versus NULL, Unicode/text interoperability, malformed payloads, and migration rollback.
Persist PCA mean/basis with an explicit numeric encoding/version too.

Do not use `ON DELETE` alone for invalidation: current indexing often marks rows
missing. Queries must join indexed notes and matching current source/space hashes.
A result becomes ready only if its claimed job token/source/space still match and
the latest indexed/disk bytes remain current. Fresh source changes replace queued
work; old completions must not overwrite them. Clearing a ready vector on changed
input is acceptable; never present it as current while regeneration is pending.

## Queue, resource use, and recovery

1. After every successful changed save, enqueue background work **after** its
   indexing request, resolving the current note ID/hash after reconciliation.
2. After startup/activation/explicit Refresh, enqueue missing/stale embeddings for
   accessible indexed notes, including existing libraries. Never prompt for model
   download on save. With indexing disabled, do not start inference.
3. Coalesce per note/space; use one inference job at a time and small chunk batches.
   Resume interrupted processing as queued after restart. Bound automatic retries
   (propose two attempts); persistent errors wait for explicit retry or new input.
4. Hold security-scoped folder access for the job; revalidate before reading/committing.
   Folder changes/disable cancel relevant UI work; do not resurrect an old folder map.
5. Serialize MLX model use with filename generation through a small shared resource
   queue. An actor alone is not sufficient if its methods await and reenter.
   Favor interactive filename requests; release model memory when idle/between
   model types. Review global MLX cache settings/clear calls before sharing the GPU.
6. Saves never wait for embedding or projection. Errors are nonmodal indexing/map
   status, not file-save failures. DB loss can rebuild IDs, vectors, and positions.

Reconciliation must invalidate changed/error sources for embeddings and projection
eligibility in addition to existing filename invalidation. A successful scan
deletes missing note metadata and its dependent embeddings, filename suggestions,
and projection runs for that folder. Failed folder scans preserve all metadata.
App rename retains the vector and resolves the fresh tooltip/path through the note
ID. Restore after a confirmed deletion creates a fresh ID and rebuilds derived
data. A late external change remains undiscoverable until Refresh under today's
policy.

## Projection contract

PCA consumes a single space's **current full-dimensional file vectors**, sorted
by note ID, scoped to one folder. Center them, fit two principal components, and
store coordinates separately. Use optimized Accelerate covariance/eigensolver work
away from MainActor; no pairwise `N × N` distance matrix or hand-written eigensolver.
Keep original vectors for future cosine-based retrieval; 2D distance is display only.

Persist completed runs atomically. Input fingerprint includes sorted note IDs,
source hashes, vector hashes, space, and reducer version/parameters. Recheck it
before publication: a changed dataset cannot replace the current map with stale
coordinates. Reuse an unchanged stored run on reopen. Canonicalize component signs
and align each new PCA frame to the previous persisted frame using shared stable
note IDs; the best-fitting 2D rotation/reflection minimizes movement of those
anchors without scaling or distorting distances. If fewer than two usable shared
points exist, use canonical PCA orientation. This reduces whole-map flips/turns
across updates but cannot prevent movement when the semantic data or cluster shape
actually changes. Legacy v1 layouts remain readable as alignment anchors; new runs
use a fingerprinted v2 alignment policy. No continuous animation/refitting per save
or window resize. Resize only changes the screen transform.

- Zero eligible notes: explain missing/downloading/empty/error states.
- One note: center it. Two/rank-one: line with unused axis zero. Rank-zero/identical
  vectors: coincident coordinates, never random semantic positions.
- Keep the last complete layout during updates, clearly labeled out of date;
  hide positions whose note/vector is no longer current. Show a concise status,
  offer **Retry** when indexing needs attention, and show **Update map** when the
  layout needs updating. Initial map can build automatically
  when enabled and the first embedding batch is ready; later updates are explicit.
- Expensive work is cancellable; cap simultaneous snapshots. Benchmark 100/1,000/
  10,000 notes before claiming a supported size; do not silently sample a library.

## Map tab and navigation

Add Notes / Map as modes/tabs inside the existing window, not a new document window
or a replacement for the sidebar. Keep the compact plain native toolbar. Use a
native SwiftUI point view/Canvas with a shared coordinate transform and hit testing;
choose the simplest renderer that passes the measured note-count target.

- Uniform scale/aspect ratio plus padding; never independently stretch axes.
  Display coordinates must derive from the stored projection, not a force layout.
- Hover tooltip shows the **current filename including extension**. Each note ID
  has one point, including separate files with identical content.
- The plot uses a subdued Nord gradient and decorative grid; the grid does not
  represent coordinate axes or imply note relationships.
- Exact overlaps: tooltip/selection offers all coincident files in a small chooser;
  no random jitter hiding actual coordinates. The circular hover and click area
  matches the drawn dot diameter, using the same size setting.
- Click resolves the current note ID/path, confirms it still exists, and uses
  `NoteStore.open` with its existing save/conflict guard. Switch to Notes/focus
  only when opening succeeds. Do not bypass conflicts or lose a dirty draft.
- Entering/leaving Map itself does not discard or force-save editor text. Map is
  based on saved text; show that an active dirty note may not be reflected yet.
- ⌘2 and ⌘F return to Notes before focusing/finding. Sidebar open/Return also
  return to Notes. Preserve ⌘1/⌘3, ⌘K, save/naming behavior, undo, and appearance.
- Provide keyboard/VoiceOver access to every mapped point and an overlap chooser
  for coincident notes. Pan/zoom are optional follow-up, not required for initial
  dots.
- Files without a usable current vector have no invented coordinates: list/count
  them as unplaced with a reason. Thus “one dot per file” means every eligible file,
  with explicit accounting for blank/error/disabled/pending exceptions.

## Ordered implementation slices — stop after each acceptance check

| Step | Deliverable | Required verification before advancing |
| --- | --- | --- |
| E1 | **Complete:** dev-only encoder spike + separate config + model/revision decision | Pinned-runtime smoke; valid 384-vector; English/Portuguese fixtures; full long-note coverage; pooling parity; cold/warm latency, peak memory, offline reload. Evidence recorded above. |
| E2 | **Complete:** BLOB support, v5 schema, embedding repository with fake encoder | Byte round trips, v4 upgrade/rollback, uniqueness/FKs, changed/missing sources, job-token CAS, failure/restart/model-space isolation; existing DB-unavailable editor tests pass. Full suite: 140 passing. |
| E3 | **Complete:** first-use model setup + production worker + existing-note/backfill/save hooks | Controller/repository tests cover existing/new notes, changed saves, external refresh, rapid-save coalescing, empty notes, cancellation/disable/re-enable recovery, retries, startup-without-download, and filename/embedding gate exclusivity. Existing NoteStore tests cover clean saves producing no event. ARM64 Debug build and full test suite pass. Manual real-model download/inference acceptance remains outstanding. |
| E4 | **Complete:** standalone PCA reducer + v6 projection persistence; no Map UI | Known geometry and zero/one/two/duplicate/rank-deficient inputs, finite output, full-vector preservation, deterministic unchanged input, obsolete snapshot rejection, folder/space isolation, bounded-memory estimate, and atomic v6 migration rollback. Full suite: 150 passing; ARM64 Debug app build succeeds. |
| E5 | **Implemented:** Notes / Map toolbar mode, persisted-layout canvas, accessible map points, hover/click and failure/empty states | Stored positions only; current filename tooltips; exact-overlap chooser; NoteStore-guarded opens; dirty-draft notice; Notes-return navigation and shortcuts; explicit ready/pending/empty/error counts; full suite: 154 passing; ARM64 Debug build succeeds. Manual desktop/VoiceOver and real-model end-to-end checks remain. |
| E6 | **Automated hardening complete; acceptance outstanding** | Saved note → vector → projection → dot → editor; restart/persisted-layout reuse/DB rebuild; edit/rename/delete/restore; offline use of persisted data; reducer benchmarks at 100/1,000/10,000 notes; full 156-test suite and arm64 Debug build pass. Signed build is blocked by no installed signing identity; real-model, interactive desktop/VoiceOver, and system Reduce Transparency checks remain. |

E6 automated lifecycle coverage now exercises saved-note embedding and projection,
Map opening through the existing editor, restart with persisted vectors/layout,
database rebuild, edit, rename, delete, restore with a fresh identity, and
offline use of persisted data. The full suite passes **156 tests**. On an
Apple M5 (arm64), macOS 26.6, a synthetic normalized 384-dimensional reducer
benchmark measured:

| Notes | Snapshot preparation | PCA reduction | Reducer working-memory estimate |
| ---: | ---: | ---: | ---: |
| 100 | 0.026 s | 0.038 s | 1,486,848 bytes |
| 1,000 | 0.242 s | 0.197 s | 4,251,648 bytes |
| 10,000 | 2.402 s | 1.689 s | 31,899,648 bytes |

Preparation includes generating and normalizing fixture vectors, encoding and
hash validation, and snapshot fingerprinting. The memory figure is the
reducer's centered-matrix-plus-covariance estimate, not total application RSS.
These timings are one run per size and are indicative, not a latency guarantee.
The ARM64 Debug build succeeds when explicitly constrained to arm64 with code
signing disabled. No signing identities are installed, and the pinned real
model is not cached; downloading it and performing signed-build, real-inference,
interactive desktop, VoiceOver, and system Reduce Transparency checks remain
unverified.

E1 should extend the dev-only tooling pattern (a sibling embedding evaluator or a
small isolated target), not turn evaluation diagnostics into product screens.
Reference Python is acceptable for developer parity checks only; shipped users
must need no Python, terminal setup, Homebrew, or service. Do not upgrade the
existing MLX packages just because current upstream APIs differ; prove a specific
compatibility issue first. Record actual chosen revision/license/download size.

For implementation, add meaningful fixtures/tests to `Tests/run.sh`, register new
app source/products in Xcode explicitly, run targeted tests then the full suite,
and report manual desktop checks honestly. Cached-package build flags can avoid
unnecessary package-update stalls. Keep each slice independently reviewable;
mark completed steps/evidence here, without deleting deferred or failed checks.

## New-session starting instruction

Read this plan, `PROJECT_CONTEXT.md`, the current-controls summary in
`IMPLEMENTATION_STATUS.md`, and relevant source files. The remaining E6 slice is
manual and real-model acceptance of the embedding-to-map workflow. Do not
broaden into search, captions, tags, or a production
model selector.
