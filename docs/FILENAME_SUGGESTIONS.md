# Phases 3.2–3.3 — Local filename suggestions and Apply

Implemented 2026-10-15. Phase 3.2 added schema version 4 with only `filename_suggestions`; Phase 3.3 reuses it.
This is a production app feature; the Phase 3.1 evaluation tool remains separate.

## Use

1. Build and run the **Nts** scheme in Xcode on an Apple Silicon Mac.
   Swift packages resolve automatically; the first Metal build can take minutes.
2. Request a filename suggestion with **⌘⇧S / File → Regenerate Filename** or
   **Local AI → Generate Filename Suggestion**. The configured model/tokenizer
   downloads automatically on the first request if needed; the app does not
   download it just because it launched. The Local AI menu also offers an explicit
   download-and-enable action to prefetch the model, with download progress shown
   in the menu.
3. **⌘S** saves text. On the first save of a nonempty new draft, it also requests
   a filename preview and downloads the model if needed. For an existing file
   with edits, it only saves text without generating or applying a name. Clean
   ⌘S accepts a ready preview, or silently does nothing when none is pending.
4. **⌘⇧S / File → Regenerate Filename** saves pending edits if any and generates
   a new preview, even for unchanged notes. Repeat until you like the candidate.
   Use clean **⌘S** or **Apply** to accept a preview. Local AI → Generate Filename Suggestion
   is another way to request a preview. Navigation/lifecycle saves do not name notes.
5. **Local AI → Disable Filename Suggestions** stops scheduling and cancels
   ongoing inference, and suppresses automatic re-enabling on later requests.
   Use the download-and-enable action to resume. Queued/interrupted jobs can
   resume after re-enabling.
   An in-flight model download may finish caching files, but disabling prevents
   its completion from enabling suggestions again.

Use **⌘S** with no unsaved edits or click **Apply** beside a ready suggestion to rename the saved note. The button is
available only while the note has no unsaved edits; typing during validation
stops the operation and keeps the draft. Once applied, the suggestion row hides
when it matches the actual filename. No files are renamed automatically.

**Link policy:** matching inbound `[[wiki links]]` in the selected notes folder
are updated, preserving aliases. Ordinary Markdown links and external-tool
references remain unchanged. The UI explains this before Apply. Relative image
links inside the note stay intact because the file remains in the same folder.
There is no product model picker or performance/telemetry panel.

### Inspect the raw response in Xcode

Debug builds print every raw model response in the Xcode console between
`[Filename Model] Raw output BEGIN` and `[Filename Model] Raw output END`,
before filename validation. The console also prints the effective prompt (or separate
system/user messages), model/revision, configuration fingerprint, temperature,
top-p, output-token limit, thinking/role options, and the normalized filename on success.
The text is printed as returned, including whitespace,
reasoning tags, or Markdown fences; an empty response leaves an empty block.
Rebuild the Debug scheme, show Xcode's debug console (⌘⇧Y), and generate again.
There is no raw-response display in the app or persistence in SQLite. Release
builds omit this diagnostic. Previously discarded responses cannot be recovered.

## Where to change the model and prompts

**Edit [`Nts/FilenameModelConfiguration.swift`](../Nts/FilenameModelConfiguration.swift).**
It contains the model ID, revision, system prompt, user prompt wrapper,
temperature, top-p, system-message format, thinking option, input/output limits, prompt version,
and MLX cache limit. The initial model is `mlx-community/Qwen3-0.6B-4bit`, pinned
to the evaluated commit `73e3e38d981303bc594367cd910ea6eb48349da8`.
When changing models, also choose that model's revision/commit. A fixed commit
keeps results reproducible; a mutable `main` revision can change on later downloads.

The complete configuration is fingerprinted and recorded with each output.
Changing prompts or generation settings hides old outputs and reprocesses a note
on its next explicit regeneration. Model weights use a separate cache key
based only on model ID/revision, so prompt tuning reuses the download. Changing
model/revision requires the explicit download command again. The shipping app's
configuration is independent of the development evaluator's CLI options.

The small Qwen model defaults to a combined user message containing the system
instructions and note, matching the Phase 3.1 template. Set `useSystemRole = true`
for a separate system chat role when evaluating another model. The system prompt
is configurable in either format. A separate system-role experiment produced
invalid/repetitive stems; a few-shot variant copied example names, so neither is
the production default.

## Architecture and processing policy

- `FilenameGenerating` is the plain Swift backend interface; `MLXFilenameGenerator`
  owns all MLX and tokenizer types. The controller accepts configuration/backend
  injection, allowing a later model selector without coupling notes to Qwen.
- `FilenameSuggestionController` holds one worker, coalesces queued saves by
  folder/path, preserves security-scoped folder access while working, and keeps
  failures outside the synchronous Markdown save operation. Generation never
  changes the editor text, selection, undo state, or file path.
- Filename suggestions start inactive, and their enabled state survives restart.
  A direct request automatically enables the feature and downloads the model if
  needed, unless the user explicitly disabled it. The menu action can prefetch
  the model. Downloaded files live under
  Foundation's app-owned Caches directory in `FilenameModels/<model-key>/models/…`
  (inside the app's sandbox when running the app). The sandbox network-client
  entitlement permits explicit Hugging Face model downloads. Notes/prompts are
  used locally, never included in a network request by this backend. Inference
  loads the local model directory and does not download anything.
- Only first explicit saves of new drafts, Regenerate Filename (⌘⇧S), and the explicit Generate command queue new naming work.
  Existing library files are not automatically sent through the model. Refresh
  observes external changes and invalidates outdated results without generating
  new names. After startup/folder reconciliation, queued/interrupted jobs for
  that accessible folder and the current configuration resume; error jobs wait
  for an explicit retry. Inaccessible folders wait until reopened.
- Records include source hash, complete configuration/fingerprint, model ID and
  requested revision, prompt version, state, attempt count, generated filename,
  error, and generation time. States are queued/processing/ready/error/stale.
  Unchanged ready work is idempotent; explicit Generate forces regeneration.
- Before inference and before publishing a completion, the database actor checks
  saved bytes and registry state. A newer save, external edit, missing file, or
  different configuration cannot receive an older result. Reconciliation marks
  invalid outputs stale. Visible results are cleared while refresh/save updates
  are pending and hidden while the editor has unsaved changes.
- Generated text may be one short natural title or a hyphenated stem, with an
  optional `.md` suffix. It is normalized to lowercase hyphen-separated words.
  Common single-line title labels and matching quotes are accepted. Paths, other
  extensions, multiline replies, reasoning blocks, and existing target filenames
  are refused. This is format validation, not a semantic check for explanatory prose.
  This guards filesystem safety, not factual quality. A file move requires explicit Apply.
- Disabling cancels inference without committing its result, retains resumable
  jobs, and unloads the model. Weights are also unloaded when a batch finishes.
  Model loss, inference errors, or database downtime never roll back Markdown.

Database loss discards suggestions/jobs. A rebuilt registry plus a save or
explicit Generate recreates them; existing Markdown remains authoritative.
App renames can retain registry identity, but work interrupted by a rename may
become stale and need a new generation. Apply uses the link policy stated above.

## Apply validation and recovery (3.3)

Apply rechecks the exact clicked filename, ready state, model configuration, and
indexed source hash on the database actor, then reads the current saved bytes.
It validates the stem and checks for a new destination collision. After the
actor await it checks that the same clean note/editor is still selected and AI
has not been disabled. The existing rename service rechecks those bytes inside
`NSFileCoordinator` immediately before moving and refuses destination overwrites.
Detected external edits, missing sources, stale/replaced outputs, and collisions
leave files untouched and show the existing file-operation alert.

The existing `NoteStore.rename` path preserves editor identity/text and the save
conflict baseline; successful reconciliation carries the note ID, preserved date,
and suggestion provenance to the new relative path. Schema 7 adds rebuildable wiki-link relationships. Apply uses the shared
recoverable rename flow; it makes no network request. Rewritten content follows
the existing changed-save path for opt-in embeddings.

If the filesystem move succeeds but indexing fails, the selected file remains at
its new path and stays readable/savable. The existing metadata error and Retry
flow recover the disposable index. A recovery scan may assign a fresh ID and
recover dates from the filesystem; do not claim metadata continuity across that
failure. A failed filesystem move keeps the original path; clearing a collision
allows the same suggestion to be retried. Uncoordinated external writers can
still race with filesystem operations, as documented for ordinary saves/renames.

## Verification and remaining checks

Regression tests cover output/path/collision rejection, configuration changes,
repeated and rapid saves, stale completions, external edits/deletion, processing
recovery after reopening the database, migration from schema 3, inference errors
and retry, disabled inference, draft preservation, and failed-save isolation.

Run `sh Tests/run.sh`.

Final checks on 2026-10-15:

- All **90 tests passed**, including 11 filename tests.
- Locally signed Debug app build passed with the packaged MLX Metal resources.
  The app contains arm64/x86_64 slices; Xcode emitted linker warnings while
  ignoring arm64-only package objects for the unused Intel MLX backend. Intel
  runtime behavior was not tested. Signed entitlements include sandbox,
  user-selected folder/bookmark access, and outgoing network-client access.
- A temporary command-line harness compiled the actual production backend,
  configuration, and filename validator against the app's package objects.
  Model download succeeded. The final cached-backend run returned valid stems
  for all four synthetic cases: `bookstore-staffing-display`, `sqlite-rebuild-idx`,
  `cartas-2023`, and `prompt-injection`. This is backend validation outside the GUI,
  not a signed sandbox interaction test. The Portuguese result invents a year;
  syntactically safe output is not necessarily a good name.
- `git diff --check` passed. Current package resolution includes a dependency
  requiring Swift 6.4; builds were run using Xcode 27/Swift 6.4.

Desktop checks still needed: use the signed app to download/enable, save and
navigate while inference runs, force a new suggestion, edit a file externally
then Refresh, quit/relaunch during work, and disable during generation/setup.
Confirm the editor stays responsive and filenames stay unchanged. Cached model
files are disposable: removing them should produce a setup instruction on the
next generation, and explicit download should recover.

The model can still produce poor or invented names. Input uses a bounded prefix,
not whole-document chunking. Image-only notes are not interpreted by a vision
model. The MLX backend is enabled on Apple Silicon; Intel notes/editing remain
available with the backend reporting unsupported hardware. Intel builds and
interactive sandbox download behavior require separate verification.


Phase 3.3 verification on 2026-10-15:

- All **96 tests passed**, including 17 filename tests. Six new Apply cases cover
  editor identity/dates/contents and unchanged inbound/image links, stale source
  and model configuration, collision/refusal/retry, dirty or missing sources,
  the second byte check during rename, and filesystem success followed by index
  failure/recovery. Applying the already-current name is a harmless no-op.
- The locally signed Debug app build passed. `git diff --check` passed.
- Interactive Apply button, keyboard focus/caret, and VoiceOver checks remain
  manual: save a disposable note, generate a suggestion, click Apply, and confirm
  the title/sidebar/Finder name change while its contents and image links remain.
  Edit and save again to verify the new path. Create a collision after generation
  and confirm Apply refuses to overwrite it. Matching wiki links now update (2026-11-10); ordinary Markdown links retain
  their old target.


### Prompt/validator compatibility fix — 2026-10-17

The purpose-focused prompt asks for natural titles with `.md` (for example,
`Grocery Shopping List.md`). The old stem-only validator rejected those spaces
and the extension. The prompt was not lost: the complete configuration is
fingerprinted and persisted, and runtime input includes the edited instructions.
The normalizer now converts that output to `grocery-shopping-list.md`; it does
not change the user's prompt text. Prompt edits require rebuilding/relaunching
because configuration is compiled Swift, not a live text file read from SQLite.

All 100 tests passed, including the five prompt examples, quoted/labeled titles,
unsafe and multiline outputs, normalized collisions, and prompt assembly/JSON
round-trip preservation. The production-backend smoke used the unchanged edited
prompt and cached model on four synthetic notes:

| Raw output | Normalized filename |
| --- | --- |
| `Bookstore Launch and Staffing Plan.md` | `bookstore-launch-and-staffing-plan.md` |
| `SQLite Recovery.md` | `sqlite-recovery.md` |
| `Loja e Torneio de Cartas.md` | `loja-e-torneio-de-cartas.md` |
| `Prompt Injection Research.md` | `prompt-injection-research.md` |

These fixtures confirm format compatibility; they do not guarantee the model's
quality on every note. The signed Debug build, signature verification, and
`git diff --check` passed. Raw output and effective prompt diagnostics stay in the
Debug console. To verify in the app: rebuild/run the Debug scheme, open Xcode's
console (⌘⇧Y), and choose Local AI → Generate Filename Suggestion. Check the
printed prompt matches your edit and compare raw output to normalized filename.


### Current save and filename workflow — 2026-10-17

1. New draft → optional **Title** field supplies the first-save filename; an
   empty title uses a timestamp filename. The title remains separate from Markdown
   content. Existing names get a numeric suffix instead of being overwritten.
   First explicit ⌘S also generates a preview when filename suggestions are enabled.
2. Existing file with edits → ⌘S: save changes only; no naming request or rename.
3. Clean file → ⌘S: accept its ready preview; no candidate means a silent no-op.
4. ⌘⇧S: save pending edits and explicitly regenerate without applying.
5. Apply: accept a validated current preview. Escape: cancel/dismiss it.

Saving edits invalidates an old preview. Automatic lifecycle saves remain plain
saves. Applying a name does not rerun inference or rewrite Markdown; stale-source,
configuration, collision, and typing checks remain in place.

The title field is available only while a note is a new draft. Once first saved,
the filename is shown in the title row; editing the note body never renames it.
Click the filename to edit it, press Return to rename, or press Escape or click
away to cancel. The sidebar rename and filename suggestion Apply actions also
change a saved note's name. Matching wiki links are updated; ordinary Markdown links remain unchanged.

The default production sampling temperature is now 0.7, with top-p 0.9, in
`FilenameModelConfiguration.swift`. Temperature zero previously selected the
same output on repeated prompts. Sampling permits variation, but can still repeat
or produce an invalid title; all candidates pass the normal safety validation.
Prompt text and the model choice are unchanged by this workflow update.

Future embeddings must run after **every successful changed-content save** via
`NoteStore.onSaved`, whether explicit or automatic. Clean regeneration and
accepting a name must not trigger embeddings. Embeddings are not implemented.

Manual check: save a new draft, review or regenerate its preview, then Apply.
Edit the existing file and ⌘S: only text should change, without any model call.
With an explicit preview ready, clean ⌘S applies it without running the model.


### Automatic validation and retry — 2026-10-17

Every generation attempt validates its response before it can become a preview.
Malformed/empty responses, filename collisions, and recoverable inference errors
retry automatically up to `maxGenerationAttempts` (default 3, clamped to 1...5).
The backend unloads after a failed attempt before retrying; model/tokenizer work
stays off the UI thread. The existing attempt counter records each attempt.

Saved bytes, registry state, cancellation, enabled state, and session identity
are checked again between attempts. Changed/deleted notes and cancellation stop
processing rather than generating a result for stale input. An empty source note
is reported directly without asking the model to invent a title.

When the budget is exhausted, the error stays inline and includes the attempt
count. Regenerate can be requested again, including on unchanged text. Model
output exhaustion does not throw into the file-operation alert or undo a save.
The Debug console logs attempt numbers, raw responses, and failure reasons.
No response bypasses validation, and retries never apply or overwrite a filename.

Invalid numeric generation settings now produce a recoverable settings error
before entering MLX; configuration fingerprinting no longer force-unwraps JSON
encoding. This handles thrown generation/validation errors; it does not claim
process isolation from fatal failures inside third-party native/GPU code.

All **116 tests passed**, covering invalid→invalid→valid responses, transient
inference recovery, collision→valid recovery, bounded exhaustion without losing
saved text, explicit recovery afterward, and invalid configuration values.
The signed Debug build and `git diff --check` passed. Interactive checks remain
manual; no new real-model quality benchmark was run for this control-flow change.


Escape cancels active filename generation or dismisses the current note's preview.
It clears that saved suggestion, leaves note text/current filename unchanged, and
discards late output from the canceled request without showing a failure alert.
Clean ⌘S cannot accept the dismissed name; ⌘⇧S requests a fresh preview. Text
already saved before generation stays saved. Inline manual rename retains its
own Escape-to-cancel behavior. Inference cancellation is cooperative; model work
may take time to unwind, but its abandoned output cannot be applied.

See [wiki-link rename recovery](WIKI_LINK_RENAME_PLAN.md) for dirty-editor checks,
conflict handling, restart recovery, supported syntax and performance limits.
