# Project Context and Confirmed Decisions

## Product philosophy

**A frictionless, local-first note dump: “Just write. The app helps organize it later.”** It is not intended to demand knowledge-management work from the user. Capture must be immediate; no mandatory note titles, filenames, folders or tags. Organization and rediscovery happen as support functions.

Influences: Obsidian's portable Markdown, local images, and pleasing editing feel. Visual preferences: **minimal dark macOS design, Obsidian Nord-inspired colors, terminal-like monospace typography, restrained but colorful Markdown source styling**. The editor, not the sidebar or semantic map, should be the focus.

## Confirmed choices

- **Platform:** native macOS, Swift + SwiftUI, developed in Xcode with Codex assistance.
- **Workflow:** small, reviewable features only. Phase 2.1 SQLite foundation with system SQLite3 is implemented. Phase 2.2 filesystem indexing is implemented with disposable database-local IDs. Phase 2.3 date metadata is implemented; read `docs/NOTE_METADATA.md`. Phase 3.1 has a dev-only MLX evaluator and Phase 3.2 in-app filename suggestions are implemented; safe application (3.3) is implemented. Scoped note-embedding/map slices E1 (encoder evaluation), E2 (SQLite persistence), and E3 (opt-in production worker) are implemented; E4–E6 remain in `docs/NOTE_EMBEDDINGS_AND_MAP_PLAN.md`. Summaries are deferred; tags are in `FUTURE_IDEAS.md`. Continue only the explicitly requested feature slice.
- **Editing now:** native NSTextView with source/live-preview toggle, Markdown decorations, checkboxes, local images, and list continuation. Preserve typing, selection, undo, and input methods; additional rendering work needs a separate request.
- **Core filesystem actions:** create, open, edit, explicit save, delete, list sorted by creation date; paste/drop local images is implemented.
- **Notes:** each persisted note is a real `.md` file, independently readable/editable in other tools; notes folder is user-selected; no manual filenames required. Launch starts with an in-memory draft.
- **External file freedom:** users can create, edit, rename, and delete Markdown outside the app. Startup automatically scans the remembered folder; while open, Refresh reconciles changes. Scans currently read/hash all supported files; no watcher or metadata-only fast check is implemented.
- **Temporary filenames:** collision-safe timestamp-based filenames until a local LLM can suggest safe filenames.
- **Images:** stored in `<notes-root>/imgs/`, referenced from Markdown using **relative links**.
- **SQLite interface:** system SQLite3, selected by the user; no third-party wrapper.
- **SQLite:** separate metadata/index database in the app’s own macOS **Application Support** directory, not the user’s Markdown directory; never canonical storage for note content. Database initialization and migrations must be automatic; end users need no Python, SQLite CLI, Homebrew, or other installed developer tools.
- **Initial local model:** `mlx-community/Qwen3-0.6B-4bit`, configurable for future replacement/model selection. Phase 3.1 has a separate Swift/MLX dev evaluator; diagnostics stay out of the shipping product. See `LOCAL_MODEL_EVALUATION.md`. Phase 3.2 adds opt-in app model loading and explicit filename suggestions; see `FILENAME_SUGGESTIONS.md`. Production settings live in `Nts/FilenameModelConfiguration.swift`.
- **AI:** later, fully local on-save processing: suggested filenames, tiny summaries, tags, image descriptions.
- **Search:** eventual **both text queries and pasted/dropped screenshot queries**; exact/phrase search, semantic text search, visually similar image retrieval, and notes linked to matched images.
- **Discovery:** later an interactive **2D semantic proximity map**, not Obsidian's explicit hyperlink network graph. Similarity remains based on original vectors, not 2D distances.
- **Hardware/privacy:** should work offline on Apple Silicon with **8–16 GB RAM**; private user notes do not leave the device by default.

## Design guardrails

- Aim for a beautiful app shell first. A prior conceptual layout is **not an approved final design**.
- Sidebar supports browsing; writing must remain the principal visual task.
- Syntax highlighting is optional until it can preserve selection, caret, undo, Unicode input, and stability.
- Do not make note creation conditional on AI or database availability.
- Real notes and images should live outside the Git source repository.
- Explicit app renames update matching wiki links with visible UI guidance and recoverable writes; external renames do not rewrite references. See `WIKI_LINK_RENAME_PLAN.md`.

## Feature progression

See `ROADMAP.md`. Phase 1: shell → files → editor polish → image assets → hardening. Phase 2: SQLite foundation → filesystem sync → date metadata (implemented). Phase 3: local model → filename generation → safe filename application → summaries → attachment registry → image descriptions. Tags are deferred to `FUTURE_IDEAS.md`. Phase 4: multimodal search and semantic map. Source/live-preview modes are implemented; additional rendering work needs a separate request.

## SQLite/search architecture

See `SQLITE_AND_SEARCH_SPEC.md` for intended logical records, hard constraints, recovery caveats, and future search support. It is **not** a command to implement that schema today.

**Confirmed recovery policy (2026-10-14):** SQLite is disposable. Note IDs need not survive database loss; rescan Markdown/images and recompute descriptions/embeddings using fresh IDs. No identity frontmatter, manifest, or database backup system is required. Inline Markdown hashtags remain the preferred direction for durable manual tags. Phase 2.2 can rebuild the file index with fresh IDs; descriptions/embeddings and their recomputation remain future work.

**Unresolved architecture decisions:** attachment sharing, screenshot OCR, and
the eventual text/image embedding-space choice. The opt-in text-map pipeline
currently uses the E1-selected E5 model; the current implementation targets
macOS 14 and uses sandboxed user-selected folder access with security-scoped
bookmarks.

**Unresolved UI decisions:** app name, finalized palette/layout/fonts, future editor decoration/rendering and refinements to keyboard UX. The current editor is a native NSTextView wrapper; existing keyboard commands are documented in the root README. Don't convert suggestions into user-approved requirements.


Save policy (2026-11-10 update): a new draft has an optional separate title
field. Its first save uses that title as a normalized `.md` filename; empty or
unusable titles keep timestamp naming. Title-only drafts can be saved. Collisions
receive numeric suffixes. After first save, the filename is fixed unless the user
explicitly renames or applies a filename suggestion. ⌘S with edits to an existing file
only saves text, without generating or applying a filename. Clean ⌘S accepts a
ready filename preview; without a candidate it is a silent no-op. First explicit
save of a new draft also requests a preview. ⌘⇧S explicitly
regenerates, saving edits first if needed. Apply also accepts a preview. Empty new
drafts do nothing. Automatic saves do not request filenames.
Opt-in embeddings run on successful changed saves via `NoteStore.onSaved`,
independently of naming. Clean saves, clean regeneration/acceptance, and failed
saves do not trigger inference; folder reconciliation also catches external
changes. E1–E3 provide the evaluated encoder contract, source-bound storage, and
production worker without changing this save boundary. The projection and Map
are not implemented.

Sidebar keyboard policy (2026-10-17): ⌘1 focuses the sidebar (including an empty
list), ⌘2 focuses writing. Two distinct ⌘D presses within one second trash the
selected sidebar note without confirmation. Sidebar ⌘Z restores deletions in
reverse order within the current folder/app session, including unsaved edits;
existing destination files are never overwritten. The ordinary Trash actions
retain confirmation. Editor undo is independent.

Current-note Find (2026-10-17): ⌘F opens the native AppKit find bar in the
Markdown editor, including from the sidebar; ⌘G/⌘⇧G navigate matches. Escape
closes the bar. Find targets Markdown text within the current note, in source
and live preview modes. Library-wide lexical/semantic search remains Phase 4.

Sidebar visibility shortcut (2026-10-17): ⌘3 toggles the sidebar; it replaces ⌘⌥S. ⌘1/⌘2 still focus the sidebar/editor.

Undo scope (2026-10-17): native text undo/redo uses normal typing coalescing,
including restoration of erased text through standard responder actions. Sidebar
deletion snapshots are a separate session history. Each visited note retains
its native text history/selection across switches, first saves, app renames, and
deletion restoration during this app session. Reopening externally changed text
resets only that note's stale history. Histories are memory-only and grow with
visited notes; rename/navigation undo and deletion redo are not implemented. See README for verification and known limits.

Shortcut reference (2026-10-17): holding ⌘K shows a compact translucent panel
over the current window without moving focus. Releasing K or Command, switching
windows, or deactivating the app hides it. It is a momentary overlay, not a toggle.

Window chrome (2026-10-17): one native unified compact toolbar contains the
traffic-light controls, sidebar toggle, view mode, folder, refresh,
and new note. The toggle/title sit immediately after the native controls; actions
are trailing. The separate app header row is removed. Native title text is hidden.

Settings → Appearance (⌘,) controls a global translucency toggle, Toolbar tint,
Editor opacity, and Sidebar opacity live, saved in UserDefaults. Toolbar tint uses
the existing header preference. Native window controls keep a solid backdrop;
text remains opaque. Reduce Transparency uses solid content backgrounds.
AppearanceConfiguration.swift keeps factory defaults and source-only material/
base tint. Native toolbar spacing/window dragging remain controlled by macOS.

Toolbar styling: title and icon groups have no persistent rounded/glass capsule
backgrounds. Hide native shared backgrounds on macOS 26+, preserving older macOS
support and the standard window controls.
