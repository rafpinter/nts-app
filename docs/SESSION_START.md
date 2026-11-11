# Paste this into a new Codex session

Latest scoped feature: read `docs/NOTE_EMBEDDINGS_AND_MAP_PLAN.md` first.
E1–E3 (encoder evaluation, SQLite persistence, and opt-in production worker)
are complete. E4 (standalone projection and persistence) is next but awaits an
explicit request; this scoped priority overrides older summaries-first/
embedding-deferral notes below. All other deferred steps and filesystem/editor
guarantees remain.

I'm building a native macOS Markdown note-dump app with Swift and SwiftUI. Read `docs/PROJECT_CONTEXT.md`, `docs/ROADMAP.md`, `docs/IMPLEMENTATION_STATUS.md`, `docs/SQLITE_AND_SEARCH_SPEC.md`, and `docs/CODEX_INSTRUCTIONS.md` first. These are the canonical consolidated product decisions, implementation history, and future architecture constraints.

The guiding UX is **just write; organization follows**. I want a minimal dark Nord-inspired interface, terminal-like monospace typography, and portable Markdown files with relative-linked local images.

Inspect the existing repository and Xcode project before proposing changes. Milestones 1.1–1.5 are complete; verify current progress rather than starting the app from scratch. The user accepted Phase 1.5 hardening on 2026-10-14. Phase 2.1 SQLite foundation with system SQLite3 is implemented; read `docs/SQLITE_FOUNDATION.md`. Phase 2.2 filesystem indexing is implemented; read `docs/FILESYSTEM_INDEX.md`. Phase 2.3 date metadata is implemented; read `docs/NOTE_METADATA.md`. Phase 3.1 has a dev-only MLX evaluator and Phase 3.2 in-app filename suggestions are implemented; safe application (3.3) is implemented. Embedding/map E1–E3 are complete; read `docs/NOTE_EMBEDDINGS_AND_MAP_PLAN.md`; E4 awaits an explicit request. Summaries and tags remain deferred. Database-local IDs are disposable. Preserve the native editor, automatic saving before navigation/lifecycle actions, explicit ⌘S, file safety, and existing image support.

For Phase 3.1, read `docs/LOCAL_MODEL_EVALUATION.md`. The dev-only native Swift/MLX tool uses `mlx-community/Qwen3-0.6B-4bit` by default, with configurable model ID/revision or local weights. Model replacement and possible future selection must not require rewriting inference. Keep evaluation diagnostics out of the shipping app. Phase 3.2 now adds app inference and persisted suggestions; read `docs/FILENAME_SUGGESTIONS.md`. Edit `Nts/FilenameModelConfiguration.swift` for production model/prompt/generation settings. Phase 3.3 adds explicit Apply using the existing rename path; inbound/external links are not rewritten.

Users freely manage Markdown outside the app. Startup automatically scans the restored folder; external changes while open use Refresh. Current scans read/hash all supported files, with no watcher or metadata-only fast check. SQLite is disposable; rebuilding assigns fresh IDs. Latest full suite: 145 passing tests including E3 worker coverage; see IMPLEMENTATION_STATUS.md for build results. Real-model in-app download/inference acceptance and interactive desktop checks remain outstanding.

Work one small feature at a time. E1–E3 embedding support is implemented; do
not start E4 projection or later search/map UI without an explicit request. Do
not implement other AI, text/screenshot search, or additional Markdown rendering
without an explicit request. Future screenshot search must support pasted/dropped
image queries and individual matched images, not just captions. Keep unresolved
architecture choices open.

Identify the smallest sensible next task and state the design approach before implementing the requested slice. Explain how to build/run/verify it, report only checks actually run, and summarize changed files and limitations. Do not automatically start another feature.


Save policy (2026-10-17, latest correction): ⌘S with edits to an existing file
only saves text, without generating or applying a filename. Clean ⌘S accepts a
ready filename preview; without a candidate it is a silent no-op. First save of a
nonempty new draft saves a timestamp file and requests a preview. ⌘⇧S explicitly
regenerates, saving edits first if needed. Apply also accepts a preview. Empty new
drafts do nothing. Automatic saves do not request filenames.
Opt-in E3 embeddings run on every successful changed save via
`NoteStore.onSaved`, independently of naming. Clean regeneration/acceptance and
failed saves do not trigger them. Folder reconciliation discovers external edits.

Current keyboard controls: ⌘1 sidebar focus, ⌘2 editor focus, ⌘3 sidebar visibility;
⌘F current-note Find, ⌘G/⌘⇧G next/previous match. Two distinct ⌘D presses within
one second in the sidebar trash the selected note without confirmation; sidebar
⌘Z restores it, including a captured unsaved draft. Editor ⌘Z/⌘⇧Z use native
text undo/redo, with normal typing coalescing. Each visited note now retains its
native editor and undo/redo history across switches within the app session,
including first saves, app renames, and deletion restoration. Reopened external
text changes reset stale history for that note. Histories are memory-only and
grow with visited notes; renames/navigation have no undo, and deletion restore
has no redo.
Read the root README shortcut table and the current-controls summary at the top
of IMPLEMENTATION_STATUS.md; its later milestone sections are historical.

Holding ⌘K displays the translucent shortcut reference; releasing K or Command
hides it. The overlay must not take focus or insert repeated K characters.

Appearance settings are available via Settings → Appearance (⌘,): a translucency
toggle, Toolbar tint, independent editor/sidebar opacity, and Restore Defaults. Changes
apply live and persist in UserDefaults. AppearanceConfiguration.swift keeps factory
defaults and source-only material/base tint; user overrides take precedence. The
native window-control backdrop and text remain opaque. One native unified compact
toolbar now combines the three controls with the sidebar toggle,
view mode, folder, refresh, and new-note actions. There is no separate header row;
the old header opacity preference is retained as Toolbar tint. Preserve the macOS Reduce Transparency solid-background fallback.
