# Nts

A native macOS Markdown notes app, built incrementally with Swift and SwiftUI.
**Phase 1.1–1.5 is complete**, and
**2.1 SQLite foundation**, **2.2 filesystem indexing**, and **2.3 note metadata** are implemented.
**3.1 local model evaluation** is available as a separate development tool;
**3.2 in-app filename suggestions** and **3.3 explicit Apply** are implemented.
The scoped note-embedding/map plan has completed E1–E3, including opt-in
production inference and saved-note indexing; projection and Map UI remain next.

The shell includes a Nord-inspired dark palette, monospace typography, a
resizable notes sidebar, minimal icon-only empty states, and a left-aligned
sidebar toggle (⌘3).
Choose a local folder, create and edit portable Markdown notes, explicitly save,
and move unwanted notes to Trash.
Note titles omit `.md` in the interface; files retain their Markdown extension.

## Build and run

Requires macOS 14 or later. The current package lockfile requires Swift 6.4;
builds are verified with Xcode 27 and its macOS SDK. Xcode resolves the native
MLX Swift packages automatically. Local filename generation requires Apple
Silicon; note editing works independently of model availability. The optional
[development evaluator](docs/LOCAL_MODEL_EVALUATION.md) remains separate.

1. Open `Nts.xcodeproj` in Xcode.
2. Select the shared **Nts** scheme and **My Mac** destination.
3. Press **⌘R** to build and launch.

If Xcode requests a signing team, choose **Sign to Run Locally** under the
Nts target's **Signing & Capabilities** settings.

For a locally signed command-line build:

```sh
xcodebuild -project Nts.xcodeproj -scheme Nts \
  -configuration Debug -derivedDataPath .build/DerivedData \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES build
open ".build/DerivedData/Build/Products/Debug/Nts.app"
```

The bundle identifier is `com.rafaelapinter.Nts`. This creates a fresh app
container and database; the previous Nord Notes container is left untouched.
Choose the existing notes folder again on first launch so Nts can rebuild its
index from the Markdown files. Distribution signing remains deferred.

## Appearance settings

Open **Nts → Settings… → Appearance** or press **⌘,**. Changes apply
immediately and are remembered across launches:

- Toggle **Translucent backgrounds** for the content areas.
- Adjust **Toolbar tint**, **Editor**, and **Sidebar** independently. Lower
  editor/sidebar values reveal more blurred background; 100% gives a solid Nord
  surface. Toolbar tint controls the Nord overlay on the native unified bar.
- **Restore Defaults** returns subtle editor/sidebar translucency and the default
  toolbar tint. The prior header preference is retained as the toolbar tint.

The window controls, sidebar toggle, view mode, folder, refresh,
and new-note buttons share one native compact toolbar. The toggle starts directly
after the three window controls; the other actions remain on the right. The name
and action icons use plain styling without rounded group backgrounds.
The native window-control backdrop stays opaque. Text also stays
opaque. macOS **Reduce Transparency** overrides the effect with solid backgrounds.

[`AppearanceConfiguration.swift`](Nts/AppearanceConfiguration.swift) still
holds factory defaults plus source-only material/base-tint settings. Saved in-app
preferences take precedence over those defaults; changing material or base tint
in source requires a rebuild. The desktop effect still needs visual verification
against different backgrounds and with Reduce Transparency enabled.

## Local filename suggestions in the app

1. Run **Nts** in Xcode. The filename model downloads automatically the first
   time you request a filename suggestion; opening the app does not download it.
   You can also use **Local AI → Download Model and Enable Suggestions…** to
   download it in advance.
2. Write a new note, then **⌘S** for its first save and filename suggestion. The
   current filename stays unchanged while you review it.
3. Press **⌘⇧S / File → Regenerate Filename** to try again, even without text edits.
   Regeneration never applies a name. If you edited the note, it saves first.
4. With no unsaved edits, **⌘S** accepts the ready suggestion; **Apply** does too.
   With edits to an existing file, **⌘S** only saves text, without generating or
   applying a filename. Clean **⌘S** without a candidate is a silent no-op.
5. Choose **Local AI → Disable Filename Suggestions** to stop background generation.

The initial model is `mlx-community/Qwen3-0.6B-4bit`. Edit
[`Nts/FilenameModelConfiguration.swift`](Nts/FilenameModelConfiguration.swift)
to change the model/revision, system prompt, temperature, top-p, thinking mode,
and input/output limits. Prompt tuning reuses weights; changing model/revision
requires the download command again. `maxGenerationAttempts` controls automatic
retries (default 3, capped at 5). Invalid responses, collisions, and recoverable
inference errors regenerate automatically. Exhaustion leaves a retryable inline
error and keeps the saved note intact. A model picker can be added later.

The `title-v2` prompt requests natural titles with spaces, matching its examples;
the filename normalizer adds hyphens and `.md`. Generation uses a separate system
message, temperature 0.2, a 32-token output limit, and thinking disabled. These
defaults favor consistency; prompt tuning still needs evaluation on actual notes.

Model downloads are explicit; note content and inference stay local. Suggestions
are stored in SQLite; files are renamed only with clean **⌘S** or **Apply**. Model failures leave
saving and editing usable. See [Filename suggestions](docs/FILENAME_SUGGESTIONS.md)
for processing/retry rules and manual checks. In Debug builds, every raw model response is printed in the Xcode console
between `[Filename Model] Raw output BEGIN` and `END`, before validation.
The console also shows the effective prompt, model settings, and normalized
filename. Rebuild and generate again to inspect it. In-app errors remain concise.
Single titles such as `Grocery Shopping List.md` are normalized to
`grocery-shopping-list.md`; paths and multiline responses are rejected.

## Run local model evaluation (development only)

Requires an Apple Silicon Mac and full Xcode selected as the developer toolchain
(`xcode-select -p` should point inside Xcode). Run these commands from the
repository root. The script builds the separate Swift/MLX evaluator in Release
mode, including Metal shaders; the first build can take several minutes.

```sh
# Build, download the default Qwen3-0.6B-4bit model, and evaluate synthetic notes twice.
sh Developer/LocalModelEval/run.sh --download --repeats 2

# Show all options without downloading or loading a model.
sh Developer/LocalModelEval/run.sh --help
```

The output includes raw filename suggestions, load/generation times, and memory
use. Downloads go to `~/Library/Caches/models/mlx-community/Qwen3-0.6B-4bit`.
After the first download, use the cached directory for local-only inference:

```sh
sh Developer/LocalModelEval/run.sh \
  --model-directory "$HOME/Library/Caches/models/mlx-community/Qwen3-0.6B-4bit"

# Evaluate a UTF-8 note read-only instead of the synthetic examples.
sh Developer/LocalModelEval/run.sh \
  --model-directory "$HOME/Library/Caches/models/mlx-community/Qwen3-0.6B-4bit" \
  --note "/absolute/path/to/note.md"

# Select another supported MLX model; optionally pin its revision/commit.
sh Developer/LocalModelEval/run.sh \
  --download --model "owner/model-id" --revision main
```

`--download` permits Hugging Face requests for model files; inference runs
locally. `--model-directory` loads existing files without model downloads;
the build step may still need network access to resolve Swift dependencies.
The evaluator never renames notes. Its diagnostics stay outside the shipping
app. See [Local model evaluation](docs/LOCAL_MODEL_EVALUATION.md) for architecture,
measured results, and quality limitations.

## Review the interface

Resize the window, drag the sidebar divider, and toggle the sidebar with its
button or ⌘3. The sidebar starts at 220 points on launch; divider adjustments
last for the current session. Check the empty states at the minimum window size and with
VoiceOver. Use the SwiftUI preview in `ContentView.swift` to iterate on layout.
Colors, typography, and spacing are centralized in `DesignSystem.swift`.
The editor uses 15-point monospace text, a Nord-colored caret and selection,
soft wrapping, and transient overlay scrollbars. Smart quotes/dashes, automatic
text replacement, spelling correction, and link detection are disabled so
Markdown and code stay as typed. The editor retains native selection, undo/redo,
and input-method behavior. The native editor supports source and live-preview
modes (⌘E), including Markdown decorations, checkboxes, and local images.
Use `**bold**`, `<u>underlined</u>`, and `~~strikethrough~~` for inline formatting,
and `---` on its own line for a horizontal rule. Underline uses HTML tags because
Markdown has no standard underline syntax. Move the cursor into formatted text
to reveal its source markers.

Live preview also supports:

- Pipe tables with a header and separator row (`| --- | ---: |`), including left,
  center, and right alignment. Click a table to edit its Markdown source.
- Numbered lists (`1.` or `1)`) with hanging indentation for wrapped items.
  Tab starts a nested sequence at 1, or continues an existing nested sequence;
  Shift+Tab resumes the parent sequence. Both support multiple selected items.
- Blockquotes (`>`) with indentation and a vertical accent bar.
- Links (`[label](https://example.com)` or `[note](other.md)`). Command-click to
  open the destination; ordinary clicks keep editing the label. Relative links
  resolve against the notes folder. Select text and paste a web URL or `mailto:`
  address to turn it into a link. Pasting inside code remains ordinary text.
- Footnotes (`Text[^note]` and `[^note]: Explanation`). Command-click a reference
  to jump to its definition, or the definition label to return to its first reference.
- Note links (`[[Note title]]`, `[[Note title.md]]`, or `[[Note title|Display label]]`).
  Command-click to open an existing note in the current folder, saving current edits
  through the usual navigation flow. Exact names take priority; otherwise a unique
  case-insensitive match is accepted. Missing or ambiguous notes show an error.
- Setext headings: a title followed by `===` (level 1) or `---` (level 2).
  Leave a blank line before `---` when you want a divider rather than a heading.
  A lone `-` (with or without trailing whitespace) stays an unfinished list marker
  and does not style the preceding paragraph as a heading.
- Local syntax highlighting for fenced code with a language tag: Swift,
  JavaScript/TypeScript, Python, JSON, Bash, SQL, CSS, HTML/XML, C/C++, C#,
  Java, Kotlin, Rust, Go, Ruby, and YAML. Highlighting identifies keywords,
  strings, numbers, and comments; unknown languages retain plain code styling.

These previews preserve the saved Markdown, native selection, and undo history.

## Use notes

- Autosave is enabled by default and saves after one second without typing. Turn
  it off in **Settings → General → Enable autosave**; the preference is remembered. Choose a notes folder
  first; autosave never opens a folder picker. It saves new, nonempty drafts with
  timestamped filenames and preserves existing names, without generating or applying
  AI filename suggestions. Autosave waits for input-method composition to finish.
  External changes or write failures keep the draft dirty and show an error instead
  of overwriting the file. Save-on-navigation and explicit ⌘S remain available.
- Click the **folder** button and choose a notes directory outside this repository.
  Use **New Folder** in the picker to create a directory before selecting it.
  macOS grants access to that folder; a security-scoped bookmark remembers it
  across launches. If the folder becomes unavailable, choose it again.
- The app opens with a focused, unsaved note: start typing immediately, even
  before choosing a folder. **+** or **⌘N** starts another unsaved note.
  Empty drafts create no files. The first save creates a safe temporary
  `yyyy-MM-dd-HHmmss.md`; the first explicit ⌘S also generates a filename preview.
  Clean ⌘S or Apply accepts it. Later ⌘S with edits saves only text, keeping the filename. If naming fails, the timestamp file keeps your text;
  collisions add `-1`, `-2`, and so on. If no folder is configured, saving asks
  you to choose one; cancelling preserves your draft.
- Select a note in the sidebar, edit its Markdown source, and press **⌘S**
  or use **File → Save**. The small circle indicates unsaved changes.
  Editor scrollbars overlay the text area while scrolling and fade afterward.
  Switching notes/folders, creating another note, closing, or quitting saves
  unsaved changes automatically. A failed save blocks the action and keeps
  your draft open with an error. ⌘S still saves explicitly at any time.
- Click **Trash** and confirm to move the selected file to macOS Trash.
  You can also right-click any note in the sidebar and choose **Move to Trash**;
  deleting a different note preserves your current selection and draft.
  Unsaved edits are discarded only after successful deletion.
- Click **Refresh** after adding, renaming, or removing files in Finder.
  Refresh updates the list and preserves the current draft. To reload an
  externally edited note, select another note and then return to it.
- Click the filename above the editor, or right-click a sidebar note and choose
  **Rename…**. Edit its name, then press **Return** to confirm or **Escape** to cancel.
  Leaving the filename field cancels editing. Errors appear below the field.
  `.md` is added if omitted. Existing filenames and invalid names are rejected.
  Renaming the open note preserves its unsaved edits. Links referencing the old
  filename in other notes are not rewritten.

## Images

The app creates an **imgs** subfolder in your selected notes folder when
you choose or reopen that folder. Open a note, then drop local image files
into the editor or paste a copied image/screenshot with **⌘V**.
The image is copied into `imgs`, and the editor inserts a portable link such as
`![image](imgs/photo.png)`. Paste inserts at the caret or replaces selected text;
drop inserts at the drop position. Multiple image files insert multiple links.

Safe filenames and collision suffixes prevent overwrites. Image bytes and the
original files are preserved; the extension reflects the detected format.
Supported formats include PNG, JPEG, GIF, TIFF, HEIC, and BMP. Clipboard image
data uses PNG/TIFF; local image files copied in Finder are supported too.
Pasted screenshots use `screenshot-yyyy-MM-dd-HHmmss.png` (or the detected
format), using local paste time because clipboard images have no reliable
capture timestamp. Same-second collisions add numeric suffixes.
Unsupported/damaged files and import errors leave the note unchanged.
`imgs` must be a real folder, not a file or symbolic link.

Images are copied immediately; save links with ⌘S or let automatic saving run
when you leave the note. Undo removes inserted links without deleting images,
which may be shared by other notes. Removing a note doesn't delete its images.
To move/share notes, keep the Markdown files and `imgs` folder together.
Live preview renders local images; source mode keeps their Markdown links visible.

## Keyboard shortcuts

| Action | Shortcut |
| --- | --- |
| New note | ⌘N |
| Open a note in the selected folder | ⌘O |
| Choose notes folder | ⌘⇧O |
| Save edits; when clean, accept a ready filename preview | ⌘S |
| Regenerate a filename preview (save pending edits first) | ⌘⇧S |
| Cancel filename generation / dismiss its preview | Esc |
| Move selected note to Trash (with confirmation) | ⌘⇧⌫ |
| Delete selected note in sidebar, without confirmation | ⌘D, ⌘D (within one second) |
| Restore last deleted note in sidebar | ⌘Z |
| Previous / next note | ⌘⌥↑ / ⌘⌥↓ |
| Focus notes list | ⌘1 |
| Focus editor | ⌘2 |
| Toggle sidebar | ⌘3 |
| Appearance settings | ⌘, |
| Show shortcut panel while held | Hold ⌘K |
| Find in current note | ⌘F |
| Next / previous match | ⌘G / ⌘⇧G |
| Undo / redo | ⌘Z / ⌘⇧Z |

Hold **⌘K** to show a small translucent shortcut panel over the note. Release
**K** or **⌘** to hide it. The panel leaves typing focus and selection intact;
switching windows/apps also hides it.

**⌘F** opens the native find bar for the current note, including from the sidebar.
Type a query to highlight matches; **⌘G / ⌘⇧G** navigate them. **Escape** closes
the find bar. Find searches the Markdown text in this note, including source
syntax, in either editing mode. Whole-library search remains future work.

Use **File** and **Navigate** menus to discover the commands. New/open require
a selected notes folder. The Open picker accepts notes directly inside that
folder; to work in another folder, choose it first. Note navigation stops at
the list boundaries and saves the current draft before switching notes.
While the notes list is focused, **↑/↓** select notes and **Return** enters the
editor. Ordinary arrows and ⌘⌫ keep their normal text-editing behavior inside
the editor; the separate ⌘⇧⌫ shortcut requests confirmed note deletion.
New/open focus the editor, and keyboard-selected notes scroll into view.
Escape cancels a pending filename request or dismisses its preview without renaming
the file or undoing saved text. A late model result is discarded; ⌘⇧S starts a new
request. Escape while editing a filename inline keeps its existing cancel behavior.

Press ⌘1 before the delete sequence; holding D does not count as two presses.
Sidebar ⌘Z restores deletions in reverse order for the current folder, including
unsaved edits. Restoration refuses to overwrite an existing filename. Undo history
lasts for this app session; the saved file also remains in macOS Trash. Restoration
recreates the file from an in-memory snapshot, leaving the Trash copy available.
Editor ⌘Z undoes the last text edit (including erasure); ⌘⇧Z redoes it.
macOS groups continuous typing into undo steps; undo is not letter by letter.
Both commands target the native editor's own undo history. Inline filename
editing keeps normal text shortcuts. Text focus takes priority over sidebar undo,
even while SwiftUI focus state is catching up.

Each visited note keeps its own text undo/redo history while the app stays open,
including when you switch away and return. Saving, filename previews, accepted
renames, and restoring an app-deleted note preserve that history and selection.
Sidebar deletion restore is a separate history; there is no single chronological
history across all app actions, and renames/navigation are not undoable actions.

Returning to a note reads its saved file as usual. If its text changed externally,
that note's old text history is reset to avoid undoing against a different version.
Histories live in memory, grow with visited notes, and disappear when the app quits.
External renames are treated as a different path; app renames preserve history.

To verify: edit a disposable note, press ⌘1, then ⌘D twice. It should disappear
without confirmation. Press ⌘Z to restore it and its draft, then ⌘2 to resume writing.

The list includes regular, non-hidden `.md` files directly inside the chosen
folder, with newest creation dates first (modification date is the fallback).
Subfolders and symbolic links are excluded. Notes must use UTF-8 text.
Saving replaces files atomically while preserving their creation dates and
permissions. If the on-disk content changed or disappeared, saving/deletion
is refused and the draft stays in the editor. Copy a conflicted draft somewhere
safe before resolving the on-disk conflict. Automatic saving never silently
overwrites external changes.

## Check milestone 1.2

1. Choose a disposable folder outside the repo. Add a UTF-8 `.md` file in Finder,
   refresh, and open it. Non-Markdown files should stay out of the list.
2. Create two notes quickly, type Markdown and Unicode, save, and verify their
   contents in another text editor. Saving should not reorder older notes.
3. Edit without saving, then switch notes, change folders, close, and quit.
   Verify each action saves the draft without a confirmation popup.
4. Modify an open note in another editor, then try saving in Nts.
   Check that an error appears, the external file stays intact, and the draft remains.
5. Cancel a Trash confirmation, then confirm it for a disposable note and
   verify the file can be restored from Finder's Trash.
6. Quit and relaunch; the notes folder should reopen without another picker.
   Rename/move that folder while the app is closed and check recovery via the picker.

## Check milestone 1.3

1. Create/open notes with ⌘N/⌘O, type immediately, and save with ⌘S.
   Check the unsaved circle clears without moving the caret or selection.
2. Paste a long Markdown document with emoji, combining characters, Japanese,
   and Arabic. Scroll, resize, select across lines, insert/delete text in the
   middle, and use undo/redo. Quotes, `--`, links, and code should stay as typed.
3. Use a Japanese or Chinese input method. Check marked text, candidate
   selection, and committing a phrase, including after saving or renaming.
4. Use ⌘1, ↑/↓, and Return; use ⌘⌥↑/↓ from the editor. Check list boundaries,
   automatic scrolling, and automatic saving when the current note is dirty.
   Change its file externally and verify a failed save prevents switching/closing.
5. Rename an open dirty note inline, then continue typing and undo/redo.
   Check the draft remains and saving targets its new filename.
6. Try ⌘⇧⌫ on a disposable note, cancel, then confirm. Check ⌘⌫ inside text
   continues editing text. Check keyboard focus and VoiceOver at minimum width.

## Check milestone 1.4

1. Choose a disposable notes folder and verify `imgs` is created. Open a note,
   drop PNG/JPEG files at different positions, and verify links and copied files.
2. Copy a screenshot/image and press ⌘V in the editor. Check selection replacement,
   undo/redo, and ordinary text paste. Repeat an image import to check suffixes.
3. Drop an unsupported file or broken image; check the error and unchanged draft.
4. Save the note and open it in another Markdown editor; relative images should
   resolve. Copy the note and `imgs` together to another folder and check again.
5. Erase a paragraph in A, switch to B and edit it, then return to A. ⌘Z should
   restore A's paragraph; ⌘⇧Z should erase it again. Return to B and verify its
   undo is independent. Repeat after saving and an app rename. Change A externally
   while viewing B: returning to A should show external text with its old history reset.

Run the SQLite, filesystem, navigation, native editor, and image tests with Xcode selected as
your developer directory:

```sh
sh Tests/run.sh
```

Tests use temporary fixtures and never move files into your personal Trash.
The test runner compiles the relevant source directly using Xcode's XCTest
libraries. The latest run passed all **133 tests**, including filename processing,
native find-bar visibility, standard Undo/Redo routing, deletion restoration,
file indexing, draft-safe reconciliation,
folder scoping, database rebuilding, and SQLite setup/migrations/rollback,
foreign keys, corruption/newer-schema preservation, lock timeout/retry,
and long Unicode text/selection,
native typing undo/redo, marked-text preservation, image validation/copying,
portable links, clipboard command validation, selection replacement, and undo isolation.
They require no dependencies or app launch. Interactive keyboard focus, native
picker/menu behavior, real Finder drops/screenshot paste in the signed app,
and input-method sessions still need manual verification.

SQLite foundation and filesystem indexing are implemented; automatic folder
watching and AI remain deferred. File operations currently run synchronously;
large folders/files may take longer. Content checks and macOS file coordination
protect against detected external changes; uncoordinated concurrent writes by
other tools can still race with a save.

## SQLite and file indexing

The app automatically opens its metadata database in app-owned Application
Support. Foundation resolves the sandbox container; the stable relative path is
`com.rafaelapinter.Nts/metadata.sqlite`. No setup or extra software is needed.
Index schema version 4 tracks selected folders and saved Markdown files, with
relative paths, content hashes, and sync state. Overall database schema v5 adds
embedding persistence. The Notes / Map view and persisted 2D projection are
implemented; summaries, tags, and search are not. Opening Map for the first time
downloads the embedding model automatically, while startup alone does not.
Choosing **Local AI → Disable Map Indexing** prevents automatic re-enabling.
The Map shows a short status and offers **Retry** when indexing needs attention.
When newly indexed notes require a new layout, **Update map** places them on the
graph. Empty notes are not placed.
See [the implementation plan](docs/NOTE_EMBEDDINGS_AND_MAP_PLAN.md).
A database failure displays a retry notice while Markdown editing and saving
remain available. Existing database files are preserved.

See [SQLite foundation](docs/SQLITE_FOUNDATION.md) for implementation policies
and manual verification. [Filesystem indexing](docs/FILESYSTEM_INDEX.md) describes
Phase 2.2: startup/folder scans, background updates after successful file actions,
and explicit Refresh for external changes. Scans preserve unsaved drafts.
If the database is lost, the file index can be rebuilt with fresh internal IDs.

Users can freely create, modify, rename, or delete Markdown files outside the
app. On launch, the remembered folder is scanned automatically in the background;
while the app remains open, click **Refresh** to reconcile external changes.
The current implementation reads and hashes every supported Markdown file.
There is no watcher or fast metadata-only change check yet; no separate script
is required. Indexing never replaces unsaved editor text.

## Project context

- [Implementation tracker](docs/IMPLEMENTATION_STATUS.md)
- [Roadmap](docs/ROADMAP.md)
- [Future SQLite and search architecture](docs/SQLITE_AND_SEARCH_SPEC.md)
- [Product decisions](docs/PROJECT_CONTEXT.md)
- [Development instructions](docs/CODEX_INSTRUCTIONS.md)
- [Session handoff](docs/README.md)
