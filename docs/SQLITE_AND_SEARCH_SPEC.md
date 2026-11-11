# SQLite and Search Architecture (Design Contract)

## Purpose and boundaries

This app is a **fast, private note dump**: open, write, save, and let the app help organize and rediscover notes. SQLite is an index/enrichment store. **Markdown (`.md`) and image files are the canonical note content**, never dependent on SQLite or the app.

This document establishes architectural constraints. **Phases 2.1–2.3 are implemented**; see [SQLITE_FOUNDATION.md](SQLITE_FOUNDATION.md) and [FILESYSTEM_INDEX.md](FILESYSTEM_INDEX.md). See [NOTE_METADATA.md](NOTE_METADATA.md) for date ownership and recovery. Later steps require separate user requests. Do not prebuild AI/search schemas. This is a design proposal; any choices labelled **OPEN** need user approval before implementation.

## Confirmed SQLite deployment decisions (2026-10-14)

- **Database location:** the app's own **Application Support** directory, resolved with Foundation APIs (`FileManager`), **never** the user-selected Markdown directory, the Git repository, or the `.app` bundle. For sandboxed macOS apps, this may be within the app container's `Library/Application Support` directory.
- The database and any associated WAL/SHM files should be invisible in normal in-app notes browsing. They are not a security boundary: the user can still access app support files manually.
- **Zero prerequisites for end users:** the installed macOS application must automatically create its database and migrate its schema. No Python, SQLite CLI, Homebrew, terminal commands, or separate runtime installs.
- **Swift interface:** system `SQLite3`, selected by the user. Use a small Swift access layer; no third-party SQLite wrapper or user-installed tools are required.
- Use an app-specific, stable support location and an explicit initialization lifecycle; initialize on app startup or first database use, apply versioned migrations, and present actionable errors on failure. Never silently delete/recreate a problematic database, especially when manual tags exist.
- A damaged or missing DB must **not** prevent opening/saving existing Markdown files. Loss of the database is acceptable; descriptions and embeddings can be recomputed from the files.
- SQLite is extensible via sequential schema migrations. **Do not create future LLM/embedding/search tables as part of initial SQLite setup.**

## Disposable database and identity decision (2026-10-14)

The user confirmed that the ID itself does not matter. SQLite is a disposable
index/cache for file descriptions, embeddings, and other derived outputs.
Markdown and image files remain authoritative. If the database is lost, create
new internal IDs, rescan the files, and recompute derived outputs when the
required models are available. Previous IDs and generated outputs need not be
recovered. Phase 2.2 now rebuilds the file index; AI output generation/recomputation remains future work.

Do not add IDs to Markdown frontmatter or introduce an identity manifest.
Database backups and exact identity restoration are not prerequisites for this
workflow. Do not introduce irreplaceable database-only user data implicitly;
future manual features must respect the accepted disposable-database policy.
Inline Markdown hashtags remain the user's preferred direction for tags.
Missing databases can be recreated; corruption/migration failures still surface
errors and preserve the existing file rather than silently deleting it.

## Incremental database implementation order (confirmed)

1. **2.1 SQLite foundation:** use system SQLite3, establish app-support path, create/open DB, schema version/migration harness, foreign keys, transactions, and basic smoke tests. No note registry or feature tables yet unless strictly required by the migration mechanism.
2. **2.2 Filesystem synchronization:** note registry and reconciliation of `.md` files including external creates/edits/deletes/renames, hashes and paths. Use database-local IDs under the disposable-database policy; handle ambiguous renames by reindexing rather than guessing associations.
3. **2.3 Note metadata:** creation/modification times and metadata ownership/recovery decisions.
4. **3.1–3.3 Local model and filenames:** evaluate/select a local text model/runtime, then add filename processing/output migrations and safe explicit application. Preserve source/model provenance and stale-output rejection; no tag or attachment tables are needed first.
5. **3.4 Summaries:** extend the processing pipeline and schema only as required.
6. **3.5 Attachments (former 2.5):** image registry and links to notes; support multiple images/note and future screenshot lookup, without implementing embeddings yet.
7. **3.6 Image descriptions:** local vision-model evaluation and versioned captions.
8. **Phase 4:** lexical/semantic text search, image embeddings, screenshot matching, semantic map.

**Tags deferred (2026-10-15):** former 2.4 manual tags and former 3.3 generated tags,
including their relational links, provenance, protection, and acceptance criteria,
are preserved in [FUTURE_IDEAS.md](FUTURE_IDEAS.md#deferred-tag-features). They are
not prerequisites for filenames or the active Phase-2/3 exit checks. All tag data
ownership and safety constraints below still apply when tags are implemented.

The exact feature/substep order for Phases 2–4 is maintained in [ROADMAP.md](ROADMAP.md). SQLite migrations, data access, synchronization, and tests continue with AI and search features; Phase 2 does not complete all database work.

Each step is an independently reviewable vertical slice. **Do not advance to the next step without a user request.**

## Initial local text model and dev evaluation

The user selected `mlx-community/Qwen3-0.6B-4bit` as the initial model. Keep model
ID/revision configurable and inference isolated behind a plain Swift interface;
a future model selector must not require coupling note/file services to Qwen.
Phase 3.1 integrates MLX in a separate development tool; measurements remain dev
diagnostics. Phase 3.2 adds opt-in app model loading, explicit downloads, save hooks,
and persisted filename suggestions; see [FILENAME_SUGGESTIONS.md](FILENAME_SUGGESTIONS.md).
Production model/prompt/temperature settings live in `Nts/FilenameModelConfiguration.swift`.
Phase 3.3 now adds explicit Apply after source/configuration and collision checks; matching wiki links now update via the shared rename flow; ordinary Markdown/external links are not rewritten. Never treat choosing another model as permission to reuse
outputs without recording the actual model/version when persistence is added.

## Ownership of data

| Data | Where | Recovery and notes |
|---|---|---|
| Written note text | Individual `.md` files | Always readable in Obsidian or any text editor |
| Images | `<notes-root>/imgs/` | Markdown uses relative image links such as `![image](imgs/foo.png)` |
| Note ID, relative path, timestamps, content hash, sync state | SQLite registry | Rescan files; new internal IDs are acceptable |
| AI title suggestion, summary, generated tags, provenance | SQLite | Regenerable by rerunning a model; never overwrite manual metadata |
| User-added tags | Inline Markdown hashtags preferred; exact syntax/UI pending | Reindex from Markdown if stored there; SQLite must remain disposable |
| Image descriptions and provenance | SQLite | Regenerable |
| Text/image embeddings | SQLite (separate tables/indexing layer) | Regenerable using compatible models |
| Text search index | SQLite FTS5, derived from `.md` + captions | Rebuildable; not canonical note text |
| Screenshot visual fingerprints | SQLite | Rebuildable |
| 2D map projections | SQLite | Rebuildable; specific to embedding set + projection run |

**Confirmed policy:** database loss is acceptable. Generated descriptions and embeddings may be discarded and recomputed. Durable user-authored content belongs in the portable files; do not require a database backup system for the current scope.

## Logical records to plan for

Schema names are illustrative, **not a mandate to create all tables now**.

### `notes` — filesystem registry
- `id`: database-local note identifier; it can be replaced after reindexing or database loss.
- `relative_path`: unique relative path within selected notes directory.
- `created_at`, `modified_at`: observed timestamps; creation time may be absent/inaccurate on imported files.
- `indexed_at`: last successful scan/index.
- `content_hash`: hash of content as indexed, for change/staleness detection.
- `sync_status`: indexed / missing / error (do not confuse with AI status).

### `note_ai_outputs` — generated metadata
- `note_id`, `suggested_filename`, `summary`.
- `model_id`, `model_revision` (if available), `prompt_version`.
- `source_content_hash`, `generated_at`, `status`, optional error info.
- Generated filenames are suggestions; **Phase 3.3 applies them only on explicit Apply**, updating matching wiki links while leaving ordinary Markdown/external links unchanged.

### `tags` and `note_tags`
- `tags`: ID, display name, normalized unique name.
- `note_tags`: note/tag references, `source` (manual or model), source version and creation time as applicable.
- AI refreshes **must not delete manual tags**.

### `attachments` and `attachment_ai_outputs`
- `attachments`: ID, `note_id`, relative path, media type, file content hash, optional dimensions and size.
- Separate generated descriptions with model identity, source image hash, generation timestamp, status.
- **Multiple images per note** are supported; the same file being referenced from different notes needs a deliberate ownership/association rule.
- An attachment is an indexed filesystem asset; its actual bytes remain in `imgs/`.

### `note_embeddings` and `image_embeddings`
- `note_id` or `attachment_id`, embedding model ID and version, original vector dimensions and encoded vector, source hash, generation time, status.
- Text and image embeddings may require **different models and vector spaces**.
- Don't compare scores across incompatible model versions/spaces or treat them as directly comparable without calibrated retrieval.
- Store all vectors with explicit type/dimension information; choose an efficient representation when implemented.

### `search_index` (SQLite FTS5 virtual tables or equivalent)
- Index *derived* note text, and, if useful, generated image captions.
- FTS5 should support keyword/phrase search independently of embedding inference.
- Source/content version tracking enables reindexing after external edits.
- A derived FTS copy of text is allowed; canonical text is still Markdown.

### `image_fingerprints`
- Image/attachment reference, algorithm/version, perceptual hash or comparable fingerprint.
- Useful for duplicate/near-duplicate screenshots, not a substitute for semantic vision embeddings.

### `projections` and `note_positions`
- `projections`: ID, embedding model/revision, projection algorithm, parameters, dataset/input version or hash, timestamp.
- `note_positions`: projection ID, note ID, `x`, `y`.
- 2D coordinates are *display data*, not a similarity metric.

### Database versioning
- A durable migration version table or `PRAGMA user_version` with **ordered, testable migrations**.

## Search experience (Phase 4, designed now)

**Search by text**
- Enter keywords, an exact phrase, or a natural-language query.
- Combine FTS5 lexical search and semantic retrieval over note text.
- Image captions can make image contents discoverable by text.
- Ranking/fusion should clearly identify which note matched and why; exact weighting can be tuned later.

**Search by screenshot**
- Paste/drop a screenshot into search to find notes containing **visually or semantically similar images**.
- Search each stored image independently, then return the owning/referencing note(s), highlighting the matched image.
- Use perceptual fingerprints for near duplicates and local vision embeddings for broader visual similarity.
- Caption-only image search is **insufficient**.
- A screenshot containing lots of text raises an **OPEN design question**: whether to add on-device OCR as a distinct retrieval signal. Do not promise OCR support until planned and evaluated.

**All inference/retrieval remains on device**, designed for Apple Silicon 8–16 GB RAM. Embedding generation and heavy queries must not freeze the editor.

## Hard constraints

### Filesystem/portability
1. Every note is an independently readable `.md` file; do not make SQLite the only copy of note content.
2. Markdown editing, saving, and image insertion must work even if SQLite or AI is unavailable.
3. Image references use paths relative to the note's Markdown location, and files stay in `<notes-root>/imgs/` (unless a later design change is approved).
4. User data lives outside the Git repository by default; never commit personal notes, image assets, databases, model weights, or secrets.
5. Detect files created/changed/deleted/renamed externally. Do not silently overwrite edits performed in another editor.
6. Surface read/write/indexing failures; failed indexing must not report that saved Markdown was lost.
7. Folder moves must be supportable without embedding absolute note paths in records or Markdown links.

### Identity/recovery
8. Preserve derived outputs across recognized app renames where practical. If an external rename cannot be identified safely, reindex/recompute; ID continuity is not required and outputs must never be attached to the wrong file.
9. **Resolved:** IDs stay in SQLite only. After database loss, fresh IDs are acceptable. No identity frontmatter or sidecar manifest is needed.
10. File creation timestamps are not guaranteed after copying/moving/importing. Decide how to preserve creation dates before promising exact rebuilds.
11. Document separately which records are reconstructible, recomputable by AI, or non-regenerable user data.
12. SQLite is disposable by user decision. Do not make durable manual content depend solely on it; any future change to that product policy needs explicit agreement.
13. Use foreign keys, unique constraints, migrations, and transactions for multi-row updates.

### AI and indexing
14. Save Markdown successfully **before** enqueueing AI/index work; model failure never rolls back a note.
15. Background work never runs per keystroke. ⌘S with edits to an existing file only saves text. Clean ⌘S accepts a ready preview, or silently does nothing without one. First save of a nonempty new draft requests a preview; ⌘⇧S explicitly regenerates without applying, and Apply accepts it. Automatic saves do not request naming. Future embeddings must run on every successful changed-content save, independently of naming; clean regeneration/acceptance and failed saves do not trigger them.
16. Track source file/image hashes and model provenance for all generated artifacts.
17. Results computed on stale content cannot overwrite outputs for newer content.
18. Reprocessing an unchanged source should be idempotent; no duplicate tags, attachments, or outputs.
19. Auto-renames must be collision-safe and preserve references/identity; defer actual AI renaming until explicitly designed.
20. Each image is searchable independently, including when note prose is unrelated.

### Search and semantics
21. Support **text and image query inputs**; text must support lexical search as well as semantic search when models are available.
22. Screenshot search cannot rely only on generated captions.
23. Search hits must resolve to a valid `.md` note and, when relevant, the specific matched image.
24. Similarity uses original embedding spaces, **never** distances in 2D projected coordinates.
25. Do not compare embeddings from different incompatible models/revisions/spaces.
26. Semantic map coordinates are versioned/recomputable; account for layout drift when adding notes.

### Quality/privacy/performance
27. Offline by default: no remote note content, image data, queries, or telemetry without explicit user opt-in.
28. Treat SQLite/FTS/embeddings/captions as sensitive private data.
29. Keep disk I/O, indexing, database writes, and model inference off the main UI thread.
30. Set up SQLite carefully (foreign keys, short transactions, WAL where appropriate, checkpoint/backup correctness); never equate a raw database copy during WAL use with a verified backup.
31. Keep memory use practical on 8–16 GB Macs; don't load all vectors or notes unnecessarily.
32. Test filesystem sync, migrations, corruption handling, duplicate paths/filenames, stale-output races, deletions, and restore behavior.
33. Keep SQLite and its journal files under the app-owned Application Support directory, never in the Markdown folder. Resolve the path with macOS APIs; support sandboxed layouts.
34. Users must not need Python, a SQLite installation, developer tools, or CLI setup; database creation/migration is handled entirely by the installed app.
35. Do not silently delete a database after corruption or migration failure. Preserve it and report the problem while allowing Markdown use; disposable storage does not authorize destructive automatic recovery.

## Phase 2 step boundaries

Follow the **revised numbered sequence above**: completed 2.1–2.3 → local model/filenames (3.1–3.3) → summaries (3.4) → attachments (3.5) → image descriptions (3.6) → Phase 4 search/map. Tags remain in the ideas backlog. Do not implement any feature or future schema before its requested slice.

## Architecture choices requiring user approval (OPEN)

1. **Attachment sharing:** association semantics when the same image is linked from multiple notes.
2. **Screenshot OCR:** whether to use on-device text extraction in addition to visual retrieval.
3. **Embedding strategy:** separate text/vision models vs a shared cross-modal space, subject to on-device benchmarks.

These remain **undecided**, not presumed agreements.

Schema 7 implements disposable wiki-link occurrences; see [the rename plan](WIKI_LINK_RENAME_PLAN.md). Recovery originals are temporary operation files outside SQLite, not a canonical content store.
