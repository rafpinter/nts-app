# Nts development

This guide covers building, testing, and working on Nts. For user-facing
features and workflows, see the [main README](../README.md).

## Requirements

- macOS 14 or later
- Xcode 27 with the macOS SDK
- Swift 6.4, as required by the current package lockfile
- Apple Silicon for local MLX inference and the optional model evaluators

Xcode resolves the app's native MLX Swift packages automatically.

## Build and run

1. Open `Nts.xcodeproj` in Xcode.
2. Select the shared **Nts** scheme and **My Mac** destination.
3. Press **⌘R** to build and launch.

If Xcode requests a signing team, choose **Sign to Run Locally** under the Nts
target's **Signing & Capabilities** settings.

For a locally signed command-line build:

```sh
xcodebuild -project Nts.xcodeproj -scheme Nts \
  -configuration Debug -derivedDataPath .build/DerivedData \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES build
open ".build/DerivedData/Build/Products/Debug/Nts.app"
```

The bundle identifier is `app.nts.notes`. This creates a fresh app
container and database; the previous Nord Notes container is left untouched.
Choose the existing notes folder again on first launch so Nts can rebuild its
index from the Markdown files. Distribution signing is not configured.

## Tests

Run the macOS test suite from the repository root:

```sh
sh Tests/run.sh
```

The script compiles the app's testable sources and test files with the selected
Xcode toolchain, then runs the test executable from a temporary directory.

## Project structure

- `Nts/` contains the SwiftUI app, editor, Markdown rendering, note/file
  services, SQLite metadata store, and local MLX integrations.
- `Tests/` contains the Swift test suite and `run.sh`, its command-line runner.
- `Developer/LocalModelEval/` contains a separate MLX filename-generation
  evaluator; it is not part of the shipping app.
- `Developer/LocalEmbeddingEval/` contains a separate embedding evaluator.
- `Developer/TitleEvaluation/` contains offline tooling for title-model
  experiments; its setup and usage are documented in
  [`Developer/TitleEvaluation/README.md`](../Developer/TitleEvaluation/README.md).

## Development status and implementation notes

The app's core Markdown editing, SQLite metadata foundation, filesystem
indexing, note metadata, filename suggestions, and saved-note embeddings are
implemented. The Notes / Map view and persisted 2D projection are implemented.
Summaries, tags, and whole-library search are not.

The metadata database is stored in app-owned Application Support at the stable
relative path `com.<your-username>.Nts/metadata.sqlite`. The database tracks
selected folders, saved Markdown files, content hashes, sync state, and
embedding persistence. It is not required for editing: if it fails, Nts reports
the problem while keeping Markdown editing and saving available. Existing
database files are preserved.

The filesystem index is reconciled at startup and when a folder is selected;
successful app file operations update it in the background. **Refresh** scans
for external changes. Scans preserve unsaved drafts. The current implementation
reads and hashes each supported Markdown file; it does not use a filesystem
watcher or a metadata-only fast path. If the database is lost, the index can be
rebuilt from files with fresh internal IDs.

The file list contains regular, non-hidden `.md` files directly inside the
selected folder. Subfolders and symbolic links are excluded. Saving replaces
files atomically and preserves creation dates and permissions. If a file
changed externally, save and delete operations are refused rather than
overwriting the external content.

### Appearance

`Nts/AppearanceConfiguration.swift` contains factory defaults and source-only
material/base-tint settings. Saved in-app preferences take precedence, so source
changes to these defaults require a rebuild. The desktop appearance should be
checked against different backgrounds and with macOS **Reduce Transparency**
enabled.

### Filename suggestions

Filename suggestions use `mlx-community/Qwen3-0.6B-4bit` by default. Change
model/revision, prompt, generation settings, and limits in
[`Nts/FilenameModelConfiguration.swift`](../Nts/FilenameModelConfiguration.swift).
Prompt changes reuse downloaded weights; changing model or revision requires
downloading that model again. The default automatic retry limit is three,
capped at five. Exhaustion leaves a retryable inline error and preserves the
saved note.

In Debug builds, raw model output is printed in the Xcode console between
`[Filename Model] Raw output BEGIN` and `END`, before validation. The console
also reports the effective prompt, model settings, and normalized filename.
For behavior and manual verification details, refer to the implementation and
tests in `Nts/FilenameSuggestionController.swift` and
`Tests/FilenameSuggestionTests.swift`.

### Local filename model evaluation

The development evaluator requires an Apple Silicon Mac and full Xcode selected
as the developer toolchain (`xcode-select -p` should point inside Xcode). Run
from the repository root. The script builds a separate Swift/MLX evaluator in
Release mode, including Metal shaders; the first build can take several minutes.

```sh
# Build, download the default model, and evaluate synthetic notes twice.
sh Developer/LocalModelEval/run.sh --download --repeats 2

# Show options without downloading or loading a model.
sh Developer/LocalModelEval/run.sh --help
```

Downloads go to `~/Library/Caches/models/mlx-community/Qwen3-0.6B-4bit`.
After downloading, run local-only inference using the cached directory:

```sh
sh Developer/LocalModelEval/run.sh \
  --model-directory "$HOME/Library/Caches/models/mlx-community/Qwen3-0.6B-4bit"

# Evaluate a UTF-8 note read-only instead of synthetic examples.
sh Developer/LocalModelEval/run.sh \
  --model-directory "$HOME/Library/Caches/models/mlx-community/Qwen3-0.6B-4bit" \
  --note "/absolute/path/to/note.md"

# Select another supported MLX model and optionally pin its revision.
sh Developer/LocalModelEval/run.sh \
  --download --model "owner/model-id" --revision main
```

`--download` permits Hugging Face requests for model files; inference runs
locally. Using `--model-directory` avoids model downloads, though the build may
still need network access to resolve Swift dependencies. The evaluator never
renames notes, and its diagnostics stay outside the app.

## UI verification

When changing layout, resize the window, drag the sidebar divider, and toggle
the sidebar with its button or **⌘3**. Check empty states at the minimum window
size and with VoiceOver. Use the SwiftUI preview in `Nts/ContentView.swift` to
iterate on layout. Colors, typography, and spacing are centralized in
`Nts/DesignSystem.swift`.

For editor changes, verify source and preview modes (**⌘E**), selection and
undo/redo behavior, keyboard focus, and interactions with existing Markdown
features. For appearance changes, also verify the app with macOS **Reduce
Transparency** enabled.
