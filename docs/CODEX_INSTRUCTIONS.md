# Instructions for Codex

You are assisting a programmer learning **native macOS app development**. Focus on a **beautiful, minimal, dark, Nord-inspired Markdown notes app**. Read `PROJECT_CONTEXT.md`, `ROADMAP.md`, `IMPLEMENTATION_STATUS.md`, and `SQLITE_AND_SEARCH_SPEC.md` before suggesting work. Inspect existing code before proposing changes.

## Non-negotiables

- Swift + SwiftUI native macOS. Don't switch to Electron/Tauri/web without explicit user approval.
- User data lives in portable plain Markdown files plus relative-linked local image assets. Use a user-selected notes directory outside the source repo; never hardcode a personal notes path.
- Keep the Nord-inspired, monospace interface editor-first; browsing and organization support writing.
- Phase 3.1 uses `mlx-community/Qwen3-0.6B-4bit` in the separate dev-only Swift/MLX evaluator; see `LOCAL_MODEL_EVALUATION.md`. Keep model configuration separate from inference for future replacement or selection. Evaluation diagnostics are not product features. Phase 3.2 adds opt-in app model loading and explicit filename suggestions; production settings are centralized in `Nts/FilenameModelConfiguration.swift`. Do not add automatic rename, network AI services, vector databases, or embeddings before the requested slice.
- Phase 2.1 SQLite foundation using system SQLite3 is implemented. Keep SQLite separate from Markdown; implement only the requested roadmap step. Phase 2.2 filesystem indexing is implemented; Phase 2.3 date metadata is implemented; Phase 3.1 has a dev-only MLX evaluator and Phase 3.2 in-app filename suggestions are implemented; safe application (3.3) is implemented. Scoped embeddings/map E1–E3 are complete; continue with E4 only when explicitly requested, as detailed in `NOTE_EMBEDDINGS_AND_MAP_PLAN.md`. Summaries remain deferred; tags are in `FUTURE_IDEAS.md`. Database-local IDs are disposable.
- SQLite is an index/enrichment store, never canonical note text. Store it in app-owned **Application Support**, resolved through Foundation with sandbox-container support, never in the notes directory. Initialize and migrate automatically; end users install only the app, with no Python, SQLite CLI, or Homebrew requirement.
- Follow the revised roadmap for general work: **2.1–2.3 complete → 3.1 local model → 3.2 filename suggestions → 3.3 safe application → 3.4 summaries → 3.5 attachments → 3.6 image descriptions → Phase 4 search/map**. The separately requested note-embedding/map work follows E1–E6 in `NOTE_EMBEDDINGS_AND_MAP_PLAN.md`; E1–E3 are complete and E4 is next. Tags are deferred to `FUTURE_IDEAS.md`; implement only the requested slice and its required schema.
- Preserve the note-dump UX: just write; organization follows. Capture must not require titles, filenames, folders, or tags.
- Future text/screenshot search is local, supports independent image matches, and follows the identity, backup, provenance, and vector-space constraints in `SQLITE_AND_SEARCH_SPEC.md`. Keep OPEN choices undecided until approved.
- Source/live-preview editing is implemented. Preserve the existing native editor and its mode toggle; additional rendering work needs a separate request.
- Preserve external file freedom: users can manage Markdown outside the app. Startup/folder scans and explicit Refresh reconcile saved files without replacing editor drafts. Current scans read/hash files; watching and scan optimizations require a separate request.
- Avoid major refactors or large chunks of code before the user approves each feature.
- Favor macOS-native accessibility, text editing behavior, keyboard support, and file safety.
- Use clear layered boundaries: SwiftUI views; note/file services; eventual metadata/AI services. Don't overengineer a tiny first version.
- Support constrained Macs in future (8–16 GB RAM). Keep eventual AI local/private.

## Repo and Git hygiene

- GitHub **Swift `.gitignore` template** is appropriate for an Xcode/Swift project. Review it after Xcode scaffolding.
- Keep README, docs, `.swift` source, project configuration, and test fixtures tracked.
- Exclude Xcode DerivedData/build artifacts, machine-specific state, secrets, generated models, and actual personal notes/data stores.
- Do **not** ignore all `*.md` files: docs and markdown fixtures need version control.
- Do not automatically ignore `.xcodeproj/project.pbxproj` or project-shared schemes; they are part of a reproducible Xcode app.
- Avoid destructive Git commands without user approval.
- Add project-specific ignores for local working-note directories/databases as soon as paths are known.

## Collaboration

- Keep answers concise, precise, and implement **one feature at a time**.
- Explain Apple-specific concepts briefly where they influence implementation choices.
- Ask only essential design questions; otherwise pick simple reversible defaults and state them.
- Validate changes with build/tests if the environment permits, and do not claim tests passed unless run.
- When touching the Markdown editor, preserve text selection, cursor position, input methods, undo behavior, and keyboard shortcuts.

## Required iteration contract

For each step:

1. State the **one** concrete feature.
2. Explain minimal decisions and tradeoffs.
3. Make a small, reviewable, commit-sized change; do not prebuild future infrastructure.
4. Give manual verification steps and report builds/tests actually run.
5. List changed files, limitations, and remaining unimplemented scope. If suggesting a next step, keep it optional and **never automatically begin it**.

## Immediate goal

Review existing progress using [IMPLEMENTATION_STATUS.md](IMPLEMENTATION_STATUS.md). Milestones 1.1–1.5 are complete; the user accepted Phase-1 hardening on 2026-10-14. Phase 2.1 SQLite foundation is implemented; see `SQLITE_FOUNDATION.md`. Phase 2.2 filesystem indexing is implemented; see `FILESYSTEM_INDEX.md`. Phase 2.3 date metadata is implemented; see `NOTE_METADATA.md`. Phase 3.1 has a dev-only MLX evaluator and Phase 3.2 in-app filename suggestions are implemented; safe application (3.3) is implemented. Embedding/map E1–E3 are complete; see `NOTE_EMBEDDINGS_AND_MAP_PLAN.md`; E4 awaits an explicit request. Summaries and tags remain deferred. Follow the applicable plan and do not advance to another step without a request.

## Definition of good Phase-1 experience

A window that looks intentional, launches reliably, responds to keyboard input, creates and saves real Markdown files, does not corrupt them, and remains pleasurable to use even before any AI exists.


Save policy (2026-10-17, latest correction): ⌘S with edits to an existing file
only saves text, without generating or applying a filename. Clean ⌘S accepts a
ready filename preview; without a candidate it is a silent no-op. First save of a
nonempty new draft saves a timestamp file and requests a preview. ⌘⇧S explicitly
regenerates, saving edits first if needed. Apply also accepts a preview. Empty new
drafts do nothing. Automatic saves do not request filenames.
Opt-in E3 embeddings run on every successful changed save via `NoteStore.onSaved`,
independently of naming. Clean regeneration/acceptance and failed saves do not
trigger them. External changes are picked up by folder reconciliation.

Keyboard contract: ⌘1 focuses the sidebar, ⌘2 the editor, ⌘3 toggles the sidebar.
⌘F is native current-note Find, with ⌘G/⌘⇧G match navigation and Escape to close.
Sidebar ⌘D, ⌘D within one second deletes without confirmation; sidebar ⌘Z
restores the note. Native text responders take priority over sidebar shortcut
handling. Preserve standard responder undo:/redo: actions and their validation;
testing UndoManager directly does not verify keyboard/menu routing. Typing uses
native undo coalescing. NoteEditorSession retains each note's native text view,
selection, and undo/redo across switching, first save, app rename, and deletion
restore. Rebind delegates/callbacks when mounting a new SwiftUI wrapper; stale
focus callbacks must not target a remounted editor. Reopening changed disk text
resets that note's old history. Histories are memory-only; rename/navigation undo
and deletion redo are not implemented. See the root README
for current shortcuts and the status document for actual validation limits.

Appearance controls live in the native Settings scene (⌘,). The shared
AppearanceSettings object publishes header/editor/sidebar opacity and the enabled
flag, persists overrides in UserDefaults, and updates the main window live. Keep
factory defaults/material/base tint in AppearanceConfiguration.swift. Preserve
opaque native title-bar controls and text, configurable unified-toolbar tint,
and the accessibility Reduce Transparency fallback. Avoid recreating editors or
undo sessions when changing appearance.

The main window uses a native unified compact toolbar containing window controls,
sidebar toggle, view mode, folder, refresh, and new actions. Do not
reintroduce a separate header row. Native title text is hidden via AppKit to
support macOS 14. Toolbar tint reuses the saved header opacity preference.
