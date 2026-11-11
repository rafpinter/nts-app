# macOS Markdown Notes — Codex Handoff

A native Swift/SwiftUI macOS note dump: **just write; organization follows**. Portable Markdown and local images are canonical content. The native Nord-inspired editor and SQLite file index are implemented; a separate dev-only MLX evaluator is available. The app now offers opt-in local filename suggestions; library-wide text/screenshot search and a 2D semantic proximity map come later. Current-note Find is implemented.

## Canonical documents

- [WIKI_LINK_RENAME_PLAN.md](WIKI_LINK_RENAME_PLAN.md): wiki-link index,
  safe rename propagation, recovery and verification.

- [AGENTS.md](../AGENTS.md): repository-wide agent guidance, privacy boundaries,
  verification practices, and the mandatory task-logging workflow.
- [TASKS.md](TASKS.md): dated task progress, verification evidence, blockers, and
  remaining work; keep it updated throughout each task.

- [NOTE_EMBEDDINGS_AND_MAP_PLAN.md](NOTE_EMBEDDINGS_AND_MAP_PLAN.md): latest requested
  text-embedding/2D note-map handoff; E1–E3 are complete, with E4 next on request. This slice
  is prioritized ahead of summaries/images without deleting their roadmap steps.

- [FILENAME_SUGGESTIONS.md](FILENAME_SUGGESTIONS.md): Phases 3.2–3.3 in-app setup, model configuration file, save processing, Apply, and recovery.

- [LOCAL_MODEL_EVALUATION.md](LOCAL_MODEL_EVALUATION.md): Phase 3.1 dev-only Qwen/MLX setup, model configuration, measurements, and limitations.
- [NOTE_METADATA.md](NOTE_METADATA.md): Phase 2.3 dates and recovery.

- [PROJECT_CONTEXT.md](PROJECT_CONTEXT.md): product decisions and unresolved choices.
- [ROADMAP.md](ROADMAP.md): incremental phases and acceptance criteria.
- [IMPLEMENTATION_STATUS.md](IMPLEMENTATION_STATUS.md): implemented scope, validation, and limitations.
- [FILESYSTEM_INDEX.md](FILESYSTEM_INDEX.md): implemented Phase 2.2 registry, reconciliation triggers, identity/folder policy, and verification.
- [SQLITE_FOUNDATION.md](SQLITE_FOUNDATION.md): implemented Phase 2.1 storage, migrations, failure policies, and verification.
- [SQLITE_AND_SEARCH_SPEC.md](SQLITE_AND_SEARCH_SPEC.md): future SQLite records, synchronization, identity, recovery, privacy, and multimodal search contract.
- [CODEX_INSTRUCTIONS.md](CODEX_INSTRUCTIONS.md): development and collaboration rules.
- [SESSION_START.md](SESSION_START.md): prompt for a fresh session.

- [SMALL_TITLE_MODEL_RESEARCH.md](SMALL_TITLE_MODEL_RESEARCH.md): sourced small-model
  candidate assessment, runtime constraints and proposed title-evaluation shortlist.
- [TITLE_EVALUATION_PLAN.md](TITLE_EVALUATION_PLAN.md): proposed Python title benchmark,
  report and local MLflow workflow; includes the implementation checkpoint.
- [Python evaluation guide](../Developer/TitleEvaluation/README.md): one YAML file,
  model/sampling sweeps, local QLoRA adapters, reports, tracking and verification.

## Ideas for later

- [FUTURE_IDEAS.md](FUTURE_IDEAS.md): inline hashtag tags and a possible
  ⌘⇧S command to recompute summaries, tags, and embeddings. Discussion only;
  these ideas do not authorize implementation or replace the roadmap.

These files in `docs/` are the canonical consolidated handoff, incorporating the former `docs2/` material while preserving implementation updates. Use `docs/` for ongoing documentation.

## Resume work

Milestones **1.1–1.5 are complete**: native Xcode project and visual shell, filesystem notes, editor polish/keyboard commands, and image drop/paste into portable `imgs` assets. **1.5 (Phase-1 hardening) was accepted by the user on 2026-10-14**. **2.1 SQLite foundation is implemented** using system SQLite3. **2.2 filesystem indexing is implemented** with disposable database-local IDs. **2.3 date metadata is implemented**. **3.1 dev-only local model evaluation is implemented** using the initial configurable `mlx-community/Qwen3-0.6B-4bit` model. App filename suggestions (3.2) are implemented; explicit Apply (3.3) is implemented. The scoped note-embedding/map plan has completed E1 encoder evaluation, E2 SQLite persistence, and E3 opt-in production inference/save/backfill processing; projection and Map UI remain unimplemented. Summaries are deferred; tags are in the ideas backlog.

Startup automatically scans the remembered Markdown folder in the background.
External file changes while the app is open use **Refresh**; there is no watcher
or metadata-only fast check. Files remain authoritative and SQLite can be rebuilt
with fresh IDs. Latest full suite: **145 tests passed**, including E3 worker
coverage; an ARM64 Debug app build passed. See IMPLEMENTATION_STATUS.md for scope.
Interactive find match navigation, focus, picker,
Trash, and IME checks remain documented and outstanding. Phase 3.1 evaluator build/inference checks are recorded separately in `LOCAL_MODEL_EVALUATION.md`.

Open the existing Xcode project and read the canonical documents before proposing a small next feature. See the root [README](../README.md) for build/run instructions and manual acceptance checks. Keep actual notes, images, databases, and model files outside source control. Future architecture documents do not authorize implementing Phases 2–4.

## Current interaction contract

See the root [keyboard shortcut table](../README.md#keyboard-shortcuts) for all
commands. ⌘1 focuses the sidebar, ⌘2 focuses writing, and ⌘3 toggles the sidebar. Hold ⌘K
to show the translucent shortcut reference; releasing either key hides it.
⌘F opens current-note Find; ⌘G/⌘⇧G navigate matches. Sidebar ⌘D, ⌘D trashes a
note without confirmation; sidebar ⌘Z restores it. Editor ⌘Z/⌘⇧Z undo/redo text.

For an existing file, changed ⌘S saves text only; clean ⌘S accepts a ready filename
preview or silently does nothing without one. A new draft's first save requests a
preview. ⌘⇧S regenerates explicitly; Apply also accepts, and Escape dismisses.
Each note keeps its own native text undo/redo history across switches during the
app session. App renames and first saves retain it; changed external text resets
that note's stale history. Histories are memory-only and grow with visited notes.
The implementation-status chronology preserves older policies for history; its
current-controls summary and the canonical policy above take precedence.

Window appearance is adjustable live via **Settings → Appearance (⌘,)**, with a
translucency toggle, Toolbar tint, separate editor/sidebar opacity, and Restore Defaults.
Preferences persist across launches. Window and app controls share one compact
native toolbar; the native window-control backdrop stays opaque;
Reduce Transparency uses solid content backgrounds. Factory defaults and source-
only material/base tint remain in
[AppearanceConfiguration.swift](../Nts/AppearanceConfiguration.swift).
