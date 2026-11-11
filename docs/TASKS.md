## 20261110-018 — Initialize private v0.1 repository

- **Status:** In progress
- **Objective:** Publish a cleaned committed-HEAD snapshot as a private personal GitHub repository with fresh history and a v0.1 tag.
- **Scope:** Create the separate local project folder, remove only the user-approved generated/placeholder files, preserve app version 0.1.0, initialize a new Git history, and publish to `rafpinter/nts-app`.
- **Progress (2026-11-10):** Source commit `2d193e02f281e2240936ea93280049b3a6b45d15` was copied to `/Users/rafaelapinter/Documents/github/nts-app-v0.1`; original checkout remains untouched. User approved removing `.DS_Store`, `Untitled.swift`, and the empty `test-llm.xcworkspace/` from the new copy.
- **Verification:** Pending cleanup, clean-tree/build checks, push, and repository visibility/tag verification.
- **Remaining work:** Finish and verify the private repository creation.

## 20261110-017 — Stabilize map orientation across updates

- **Status:** Completed
- **Objective:** Reduce whole-map rotation/reflection changes when regenerating the embedding map.
- **Scope:** Align new PCA coordinates to the previous stored layout using shared note IDs; add reducer/map tests and update map documentation. Do not change embeddings, semantic distances, or map interaction.
- **Progress (2026-11-10):** Confirmed PCA canonicalizes component signs but does not resolve axis swaps or rotations near repeated eigenvalues. The plan explicitly records this limitation.
- **Progress (2026-11-10):** Added overlap-based 2D rotation/reflection alignment to the prior persisted coordinates and carried the same transform into the stored basis. Legacy PCA layouts remain readable as anchors; new fingerprints identify the policy.
- **Verification:** `sh Tests/run.sh` passed 203 tests, including synthetic reflected-layout alignment, basis-coordinate consistency, legacy-layout alignment, and map-update integration. Debug Xcode app build succeeded; `git diff --check` passed.
- **Remaining work:** None. Real-library visual acceptance remains manual.

## 20261110-016 — Correct filename suggestion link warning

- **Status:** Completed
- **Objective:** Remove the stale warning shown beside generated filename suggestions.
- **Scope:** Remove only the obsolete warning; preserve filename application behavior and other UI guidance.
- **Progress (2026-11-10):** Removed the warning without replacing it with new copy.
- **Verification:** Source search found no remaining stale warning; `git diff --check` passed.
- **Remaining work:** None.

## 20261110-015 — Preserve open editor buffers during rename

- **Status:** Completed
- **Objective:** Allow renaming an open note while safely propagating wiki links without discarding open editor drafts.
- **Scope:** Rebase retained sessions independently from validated on-disk files; add synthetic regressions and update rename documentation.
- **Progress (2026-11-10):** Removed the disk-equality/dirty-editor rejection. Rename now computes link edits separately for retained live buffers, applies them after disk commit, preserves the selected draft against the committed saved baseline, and verifies the fresh plan's resulting bytes before writing.
- **Verification:** `sh Tests/run.sh` passed 202 tests, including open target/self-link, dirty source, selection, undo, and existing recovery/conflict coverage. Debug Xcode app build succeeded; `git diff --check` passed; code/docs search found no obsolete dirty-editor rejection.
- **Remaining work:** None. Interactive IME/focus and desktop acceptance remain manual.

## 20261110-013 — Remove routine rename success message

- **Status:** Completed
- **Objective:** Keep successful note renames and wiki-link updates silent instead of displaying a changed-note count.
- **Scope:** Remove the routine success status from the editor; preserve rename failures and existing pre-action wiki-link guidance.
- **Progress (2026-11-10):** Removed the success-only published status and editor label. Updated the rename plan and implementation status to document silent success. Existing uncommitted rename implementation is preserved.
- **Verification:** `sh Tests/run.sh` passed 199 tests; Debug Xcode app build succeeded; `git diff --check` passed; app-source search found no remaining `renameStatus` or old success message.
- **Remaining work:** None.

## 20261110-012 — Implement wiki-link rename propagation

- **Status:** Completed
- **Objective:** Implement the accepted [wiki-link rename plan](WIKI_LINK_RENAME_PLAN.md).
- **Scope:** Shared parsing/resolution, disposable link index, recoverable file updates, editor integration, synthetic tests and documentation.
- **Progress (2026-11-10):** Plan accepted. Inspected shared rename callers, retained editor sessions, scanner and migration structure. Existing planning edits preserved; private content remains excluded.
- **Progress (2026-11-10):** Implemented shared parsing/resolution, schema 7 link indexing, journaled rename/recovery, both UI entry points, retained-session edits and changed-content notifications. Added synthetic failure/restart, case-only rename, code exclusion, alias, Unicode, undo and index coverage.
- **Verification:** Passed 199 native tests, signed Debug Xcode integration build (exit 0; output includes ARM64), documentation target checks and `git diff --check`. Sandbox macro/network failures required normal escalation. Build emitted existing dependency/architecture warnings; no app launch or private-data access occurred.
- **Remaining work:** Implementation and automated verification complete. Interactive IME/focus/VoiceOver and desktop acceptance remain manual. Final revalidation/writes are synchronous and may briefly pause large folders; unsupported link forms remain deferred as documented.

## 20261110-011 — Plan wiki-link updates on rename

- **Status:** Completed
- **Objective:** Plan safe inbound `[[...]]` updates and assess a SQLite link index before implementation.
- **Scope:** Repository inspection and planning documentation only; supersedes immediate implementation work in task 20261110-010 for this turn.
- **Progress (2026-11-10):** Verified shared rename path, flat-folder resolver, code-aware wiki-link parsing, disposable registry, and existing session preservation. No app changes or private content access.
- **Verification:** Reviewed plan against implementation; documentation target exists and `git diff --check` passed. No app tests/build or private-content access.
- **Remaining work:** Planning complete in [the proposal](WIKI_LINK_RENAME_PLAN.md). Implementation remains pending plan review. Proposed database and file behavior are not implemented.

## 20261104-007 — Resume incomplete private snapshot copy

- **Status:** Completed
- **Objective:** Complete the authorized metadata-only copy of selected private Obsidian files and report whether the snapshot is complete.
- **Scope:** Use the existing preparation script to resume copying bytes through the operating system; inspect only paths and filesystem metadata. Do not read, parse, hash, render, or summarize private contents.

### Progress

- 2026-11-04: Reviewed repository guidance, current task history, snapshot preparation instructions, and script behavior. Existing unrelated work is preserved.
- 2026-11-04: Resumed the existing snapshot copy from the iCloud vault. The updated aggregate summary reports all 754 selected files copied (250 notes and 504 attachments), zero pending iCloud items, and complete status.

### Verification

- Passed: preparation script returned exit code 0; metadata-only summary reports `complete`, 754/754 copied, zero pending iCloud files, and zero recorded failures (no private filenames or contents inspected). `git diff --check` passed.

### Remaining work

- None.

## 20261110-010 — Update note links when applying a generated filename

- **Status:** Completed
- **Objective:** Update links to a note when its generated filename is applied.
- **Scope:** Safe app-managed Markdown link updates during generated-filename application, synthetic verification, and affected documentation. Do not inspect private notes.

### Progress

- 2026-11-10: Inspected filename application, rename safeguards, link navigation, and current work. Existing behavior moves the file without changing inbound references.
- 2026-11-10: Confirmed the editor recognizes wiki links and Markdown links while excluding code, and that applying a suggestion requires a clean selected note. Updating multiple files also needs conflict checks, handling for links in the open note, and a recoverable partial-failure strategy that preserves editor undo and saved-content baselines.
- 2026-11-10: User explicitly requested implementation. Further inspection confirmed visited notes retain native undo sessions, and rewriting a visited note without updating its session would discard undo history on reopening. The current filesystem rename and save operations do not provide a multi-file transaction or rollback mechanism.

### Verification

- Superseded by accepted wiki-only scope and verified in task 20261110-012 (199 native tests and Debug build).

### Remaining work

- Wiki-link implementation completed under the accepted plan in 20261110-012. Ordinary Markdown-link rewriting was explicitly deferred by that plan.

## 20261110-009 — Simplify Map status and actions

- **Status:** Completed
- **Objective:** Show only useful Map status and relevant actions, reducing redundant counts and controls.
- **Scope:** Map status presentation and documentation; preserve indexing, error recovery, and explicit layout updates.

### Progress

- 2026-11-10: Reviewed indexing and projection states. Index retry and layout update do different work; the current interface shows both even when neither is needed and repeats successful status messages alongside four counters.
- 2026-11-10: Replaced counters and routine success messages with a single state summary. Enable, Retry, and Update map are shown according to the current state; errors and download progress remain visible. Updated user and feature documentation.

### Verification

- Passed: 190 native tests, final ARM64 Debug app build, and `git diff --check`. Interactive Map state and accessibility review remains outstanding.

### Remaining work

- Manual confirmation after relaunch remains.

## 20261110-008 — Refresh the graph interface

- **Status:** Completed
- **Objective:** Give the note graph a more distinctive, polished appearance.
- **Scope:** Native Map presentation and related documentation. Preserve graph positioning, note navigation, accessibility, and dot-sized interaction areas.

### Progress

- 2026-11-10: Reviewed the existing Map canvas, status controls, Nord design system, implementation status, and repository state. The plot uses a plain panel and flat points; rendering and hit testing share a diameter.
- 2026-11-10: Added a layered Nord canvas, faint decorative grid, inset point detail, refined hover cards, a status icon, and a clearer empty state. Preserved the shared point diameter and graph behavior; updated Map documentation.

### Verification

- Passed: 190 native tests, ARM64 Debug Xcode build after the final visual change, and `git diff --check`. Interactive visual and accessibility review remains outstanding.

### Remaining work

- Manual visual review after relaunch remains.

## 20261110-007 — Match graph selection to dot size

- **Status:** Completed
- **Objective:** Make graph note hover and click areas match the displayed dot, including after future dot size changes.
- **Scope:** Map point rendering and interaction geometry, with related documentation.

### Progress

- 2026-11-10: Inspected the map: dots are drawn at 10 points while their controls occupy 30 points. Both geometries must use one diameter.
- 2026-11-10: Introduced one point diameter for drawing and circular control hit testing, including overlapping-note menus; updated map documentation.

### Verification

- Passed: 190 native tests, ARM64 Debug Xcode build, and `git diff --check`. Interactive graph hit testing has not been checked in a desktop window.

### Remaining work

- Manual confirmation after relaunch remains.

## 20261110-006 — Restore new draft title editing

- **Status:** Completed
- **Objective:** Let users focus and edit the title of an unsaved new note.
- **Scope:** Draft title and editor focus coordination; preserve the existing save and naming behavior.

### Progress

- 2026-11-10: The draft title lacks focus coordination with the AppKit editor, whose standing focus request can reclaim the first responder during title edits.
- 2026-11-10: Bound the draft title's focus and suppressed the editor focus request while it is active, clearing the editor and sidebar focus states on entry.

### Verification

- Passed: ARM64 Debug Xcode build, 190 native tests, and `git diff --check`. Interactive title entry has not been verified in a desktop window.

### Remaining work

- Manual confirmation after relaunch remains.

## 20261110-005 — Rename from the note title

- **Status:** Completed
- **Objective:** Allow clicking the current note filename above the editor to rename it inline.
- **Scope:** Native title-row interaction, existing safe rename path, and related documentation.

### Progress

- 2026-11-10: Inspected the existing sidebar rename, editor focus handling, file service, and current uncommitted work. Reuse the existing rename operation while preserving unsaved text.
- 2026-11-10: Added an editable filename in the editor title row, with Return to apply, Escape or focus loss to cancel, and inline errors. Reused the existing rename and editor-session handling. Updated the user guide and filename/status documentation.

### Verification

- Passed: 190 existing native tests, `git diff --check`, and an ARM64 Debug Xcode build. The first sandboxed build could not resolve Swift packages; the out-of-sandbox build exposed a SwiftUI type-check limit, fixed by extracting the title row, and the subsequent build passed.

### Remaining work

- Interactive desktop confirmation remains pending; the automated suite does not exercise the title-row focus interaction.

## 20261110-004 — Keep context-menu rename field open

- **Status:** Completed
- **Objective:** Fix inline rename being dismissed immediately after choosing Rename from a note’s context menu.
- **Scope:** Sidebar rename activation/focus and focused verification; preserve save and filename rules.

### Progress

- 2026-11-10: Traced dismissal to the view’s unconditional focus-loss handler, which cancels rename while the context menu is closing and focus is transferring to the newly mounted text field. The current focus request runs synchronously from `onAppear`.
- 2026-11-10: Deferred the initial focus request until the context menu has closed and guarded the activation transition from focus-loss cancellation. Normal focus loss after activation still dismisses rename.
- 2026-11-10: User confirmed that did not fix the issue. Further trace found the sidebar’s Return key handler can run during the context-menu-to-field focus handoff and request editor focus, which cancels rename. Disabled sidebar keyboard shortcuts and navigation/Return handlers as soon as rename mode starts, before field focus is established.
- 2026-11-10: User confirmed the second attempt also failed. Reopened investigation of the editor's first-responder requests.
- 2026-11-10: Found the Markdown editor retains a focus request and asynchronously calls `makeFirstResponder` on view updates. Beginning rename now clears editor/sidebar focus and suppresses editor focus requests until rename ends, preventing it from taking focus back from the field.

### Verification

- Passed: `sh Tests/run.sh` completed with 190 tests and zero failures after the focus fix. The earlier sandboxed run was blocked by SwiftUI macro plugin restrictions; the approved out-of-sandbox run passed.
- Passed: `git diff --check` and focused source review.

### Remaining work

- None for code changes. Interactive macOS confirmation remains pending user retest.

## 20261110-002 — Simplify new note title placeholder

- **Status:** Completed
- **Objective:** Keep the new note title field’s existing style and remove “(optional)” from its placeholder.
- **Scope:** Placeholder text and this task record only.

### Progress

- 2026-11-10: Changed the placeholder from “Title (optional)” to “Title”; styling is unchanged.

### Verification

- Passed: `git diff --check`; reviewed the focused one-line UI diff.

### Remaining work

- None.

## 20261110-003 — Match new title field font size

- **Status:** Completed
- **Objective:** Make the new note title field use the same font size as the prior title-row text.
- **Scope:** Remove the added font override and verify the diff.

### Progress

- 2026-11-10: Removed the explicit larger title font so the field inherits the same font as the previous header text.

### Verification

- Passed: `git diff --check`; confirmed the title field has no explicit font override.

### Remaining work

- None.

# Task log

## 20261104-006 — Locate other Qwen MLX models

- **Status:** Completed
- **Objective:** Point to current places to find Qwen models converted for MLX.
- **Scope:** Web research and task record only; no downloads, model runs, or dataset access.

### Progress

- 2026-11-04: Checked Hugging Face's MLX Community Qwen3 collection and representative Qwen model cards, including an official Qwen-published MLX conversion.

### Verification

- Confirmed current Hugging Face model and collection pages through web search. No model files were downloaded.

### Remaining work

- None.

## 20261104-005 — Confirm local MLX model downloads

- **Status:** Completed
- **Objective:** Confirm whether the configured title-generation models are present locally and are MLX-format models.
- **Scope:** Documentation and filesystem metadata only; do not inspect datasets, notes, model weights, or run inference.

### Progress

- 2026-11-04: Checked the configured model IDs, prior download/evaluation records, and local model-directory/file names. Confirmed the Swift app cache contains Qwen; the Python evaluation workspace contains Qwen, SmolLM2 Q8 MLX, and Gemma 3 270M 4-bit snapshots.

### Verification

- Confirmed expected model files and configuration/tokenizer filenames exist in all four directories using path metadata only. No model weights or private content were opened; no inference or tests were run.

### Remaining work

- None.

## 20261104-004 — Set the debug notebook example input

- **Status:** Completed
- **Objective:** Configure the Gemma debug notebook to use one existing example note.
- **Scope:** Notebook configuration plus this task record. Inspect filename metadata only; do not read note contents or run inference.

### Progress

- 2026-11-04: Found the notebook still selects generic Python 3 and uses a placeholder note path. The notebook metadata now names the registered MLX evaluation kernel. Located one Markdown example by path metadata only.
- 2026-11-04: Set `NOTE_PATH` to a Markdown example in the local snapshot, added a path existence check, and cleared stale notebook outputs.

### Verification

- Passed notebook JSON and code-cell syntax checks, verified the registered kernel metadata and example path using filesystem metadata, and passed `git diff --check`. No note contents read and no inference run.

### Remaining work

- None. Restart or refresh Jupyter if the registered kernel is still absent from its picker.

## 20261104-003 — Explain benchmark virtual environments

- **Status:** Completed
- **Objective:** Explain how to use the Python virtual environment(s) under `benchmarks/`.
- **Scope:** Repository guidance only; no environment activation, package installation, dataset access, or inference.

### Progress

- 2026-11-04: Checked current benchmark READMEs, task log, Git status, and environment directory metadata. Found separate preparation and evaluation environments; preserved existing working changes.
- 2026-11-04: Provided the correct invocation patterns and clarified that the preparation environment is not the MLX evaluation environment.

### Verification

- Confirmed `benchmarks/title_generation/.venv` exists from filesystem metadata. Did not inspect data or run either environment.

### Remaining work

- None.

Record each task here at the start of work, before implementation, including
planning, research, and documentation-only work. Update its entry as work progresses and before handing
it back to the user. Log user-level tasks, not every tool call.

Use these statuses:

- **Planned:** recorded, with implementation not started.
- **In progress:** actively being worked on.
- **Blocked:** cannot proceed; record the concrete blocker and what would resolve it.
- **Completed:** requested work and appropriate verification are finished.

Each entry must include an ID, objective, scope, status, dated progress,
verification evidence, and remaining work. Update the entry when scope changes,
a blocker appears, meaningful progress occurs, or the task finishes. Preserve
completed entries as history. Historical test results are not current validation.
Keep private note content, sensitive filenames, and dataset rows out of this log.

## 20261102-001 — Repository agent guidance and task logging

- **Status:** Completed
- **Objective:** Capture the working practices established in the conversation and
  require agents to keep Markdown task records current.
- **Scope:** Root `AGENTS.md`, this task log, and links from the documentation index.
  Documentation only; no app, benchmark, or dataset behavior changes.

### Progress

- 2026-11-02: Inspected existing agent instructions, the documentation index,
  implementation status, benchmark preparation documentation, and Git status.
  No root agent guidance or task log existed. Older milestone summaries contain
  historical state and must not be treated as fresh verification.
- 2026-11-02: Created this entry before implementing the guidance.
- 2026-11-02: Added root `AGENTS.md` with mandatory task logging, repository
  orientation, private-data restrictions, native editor/file safety, Python
  benchmark practices, reproducibility, and verification/reporting rules.
  Linked both new documents from `docs/README.md`.
- 2026-11-02: Reviewed the guidance against existing instructions and the approved
  scope. Preserved historical documentation and current ignore rules; completed
  the checks below and marked this documentation task complete.

### Verification

- Passed: Python documentation check over `AGENTS.md`, `docs/TASKS.md`, and
  `docs/README.md`; all 28 relative links resolve to repository files, headings
  have blank-line separation, and files have no trailing whitespace or missing
  final newline. Confirmed the standard root `AGENTS.md` entrypoint exists.
- Passed: `git diff --check` and scope review. Git status shows only the two new
  Markdown files and the documentation index change. Neither new file is ignored.
- App tests, builds, dataset validation, and model inference are not needed for
  this documentation-only task and have not been run.
- Private note contents have not been accessed.

### Remaining work

- None for this task. Future tasks must add their own entries and verification.

## 20261102-002 — Python title-evaluation report plan

- **Status:** Completed
- **Objective:** Plan a reproducible Python evaluation and reporting workflow using current primary-source guidance.
- **Scope:** Research and planning documentation only; no implementation, dependency installation, data/model downloads, inference, or private-content access.

### Progress

- 2026-11-02: Reviewed repository guidance, current preparation README, production title settings, and historical Swift evaluator. Public preparation already exists; inference/scoring/MLflow do not. The supplied older proposal uses obsolete production sampling settings and assumes data preparation is still pending. Existing public preparation lacks near-duplicate and cross-language grouping. Existing unrelated documentation edits are preserved.

- 2026-11-02: Researched current official MLflow evaluation/self-hosting/telemetry guidance, BERTScore implementation, and SciPy paired bootstrap documentation. Added [the proposed plan](TITLE_EVALUATION_PLAN.md) and index link. Plan separates Python experiments from Swift app verification and preserves private-data restrictions.

### Verification

- Passed documentation relative-link, whitespace, final-newline and diff checks. Scope reviewed; only task log, plan and index changed for this task. No private contents read, dependencies installed, models downloaded, inference executed, or app tests/builds run.

### Remaining work

- None for planning. All implementation slices, model selection, pilot execution and acceptance thresholds remain proposed and require a subsequent request.

## 20261102-003 — Model sweeps and Qwen fine-tuning experiment plan

- **Status:** Completed
- **Objective:** Extend the Python plan with configurable models/sampling, the unfine-tuned Qwen baseline, and local adapter training comparisons.
- **Scope:** Planning/documentation only. No training, inference, installations, or data inspection. Future automated use of selected data must not expose contents to the agent.

### Progress

- 2026-11-02: Reviewed existing plan and preparation README; researched official MLX LM adapter-training and generation-parameter documentation. Interpreting “top N” provisionally as top-k; retain top-p as a separate control.

### Verification

- Passed relative-link, whitespace, final-newline and git diff checks. Reviewed documentation-only scope; no data contents accessed or training/inference executed.

### Remaining work

- Planning complete in [the extension](TITLE_EVALUATION_PLAN.md#requested-extension-model-sweeps-and-qwen-fine-tuning). Execution, exact training scope, resource budgets and runtime compatibility remain for a subsequent implementation request.

## 20261102-004 — Implement configurable Python title experiments

- **Status:** Completed
- **Objective:** Implement one editable experiment configuration, sequential local model/adapter execution, scoring, comparison reports and local MLflow tracking.
- **Scope:** Parallel implementation with synthetic verification; no existing dataset-content inspection, real training/inference, model downloads or app changes. Preserve the complete `/benchmarks/` ignore rule: reviewable source/templates live in `Developer/TitleEvaluation/`, with the working configuration and all data/results under `benchmarks/title_generation/`.

### Progress

- 2026-11-02: Reviewed the plan, repository status, existing preparation scripts and privacy boundary. User explicitly authorized parallel implementation. Existing unrelated documentation edits remain intact.
- 2026-11-02: Implemented strict single-YAML model/configuration/seed expansion and production settings export. Created the working YAML with only the unchanged Qwen baseline enabled. Dry-run verifies the matrix without dataset/model access.
- 2026-11-02: Added local-only snapshot registration/loading, isolated sequential workers, retries/resume and protected artifacts. Added public training-source selection, group-based validation, full exact/group split checks, masked-title QLoRA worker, numeric learning curves and adapter lineage/integrity checks.
- 2026-11-02: Added validity/diversity/latency/memory metrics, optional provisioned-local BERTScore, paired group-bootstrap comparisons, aggregate-only interactive HTML/CSV/JSON and local MLflow evaluation/training tracking. Synthetic reports identify their backend prominently.
- 2026-11-02: Real SQLite integration exposed MLflow 3.7 incompatibility with SQLAlchemy 2.1. Pinned SQLAlchemy 2.0.44, verified logging and idempotent reimport, and recorded the resolved core/tracking environment. Core/tracking dependencies were installed only in a temporary verification environment after the sandbox network failure and normal escalation; no MLX/BERTScore models were installed or run.
- 2026-11-02: Updated the operating guide, feature-plan checkpoint, preparation README, documentation index and implementation status. Extended ignore rules only for new Python source caches; the existing benchmarks exclusion is preserved.

### Verification

- Passed: all 58 focused Python tests using the temporary Python 3.13.16 environment, including real SQLite/MLflow evaluation and training-metric integration, repeat-import idempotency, synthetic end-to-end CLI, mocked MLX inference/training boundaries, data leakage failures, protected logging, retry/resume and baseline comparisons.
- Passed: main-file initialization and dry-run with `dataset_read: false`; a two-configuration synthetic smoke generated the local `results/synthetic-demo-v1/report/comparison.html` demonstration. These are synthetic results, not measured Qwen quality.
- Passed: Python source parse, new/changed documentation link and whitespace checks, `git diff --check`, and scope/private-material review. Historical illustrative links in older status sections were excluded from the new-content link check.
- No existing public/private dataset records were opened by the agent or used in execution. No real training/inference, model/encoder download, app tests/builds or interactive desktop acceptance performed. Existing preparation code is unchanged; public dataset validation was not run.

### Remaining work

- None for this implementation scope. Real model/runtime feasibility and title quality remain unverified. Models/encoders must be provisioned explicitly before actual runs; training sources and resource budgets must be selected in the main file.
- Broader planned capabilities remain explicitly unimplemented: human-review import, local judge, near-duplicate/cross-language alignment, Parquet/static figure export, automatic best-checkpoint selection, private training and native Swift finalist verification. Current training evaluates the final adapter. See [the operating guide](../Developer/TitleEvaluation/README.md) for commands and limitations.

## 20261102-005 — Keep unfinished list markers from styling preceding text as a heading

- **Status:** Completed
- **Objective:** Fix heading size/color applied to the first line while typing `feijoada` followed by an empty hyphen list item.
- **Scope:** Markdown decoration planning and focused native editor regressions; preserve Markdown bytes, selection and undo. No benchmark or private-data access.

### Progress

- 2026-11-02: Reproduced the cause in the Setext heading regex: a single hyphen with optional trailing whitespace is accepted as a heading underline before list parsing. Give the single-hyphen editing state to list/plain-text styling while preserving multi-character Setext underlines.

- 2026-11-02: Restricted hyphen Setext underlines to two or more characters. Added a native regression for font/color, Unicode/CRLF, selection, transitions from a heading, and undo. Updated README and implementation status.

### Verification

- Passed: full native runner, 188 tests, including the new presentation/selection/undo regression. The first sandboxed attempt could not load the SwiftUI macro plugin; rerun through normal escalation passed.
- Passed: signed Debug app integration build using `Nts.xcodeproj`/`Nts`; Xcode returned exit status 0 with dependency/build-system warnings. Required normal escalation after sandbox package resolution failed. An initial command used an obsolete project name; corrected it before the successful build.
- Passed: changed-file formatting, `git diff --check` and scoped diff review. Existing benchmark/documentation edits preserved; no private data accessed.

### Remaining work

- None for implementation/automated verification. Manual confirmation after relaunch remains: type the reported text and confirm the first line stays at its normal size/color.

## 20261102-006 — Evaluation resource measurements

- **Status:** Completed
- **Objective:** Track time, memory and compute-related diagnostics for title evaluation experiments.
- **Scope:** Extend local Python evaluation instrumentation and aggregate reporting; synthetic tests only, no dataset access or model execution.

### Progress

- 2026-11-02: Inspected existing evaluation, scoring and tracking. Existing attempt latency/RSS/MLX memory are implemented; CPU consumption, phase resource summaries and throughput are missing. Preserve unrelated working edits.

- 2026-11-02: Added evaluation phase/session and attempt CPU/resource measurements, retry-inclusive throughput and aggregate report/MLflow metrics. Documented semantics and unmeasured diagnostics in the operating guide and feature/status docs.

### Verification

- Passed: all 59 focused Python tests, including real local MLflow integration, synthetic retry/resume aggregation, missing-token throughput and deterministic CPU/RSS unit checks.
- Passed: documentation formatting/operating-guide links, `git diff --check` and scope review. No datasets, model inference or app builds/tests used.

### Remaining work

- None for this scope. GPU utilization, energy/FLOPs and scoring-process instrumentation remain unmeasured; real-model performance remains unverified.

## 20261102-007 — Research small title-generation models

- **Status:** Completed
- **Objective:** Assess the user's seven model candidates and a focused alternative shortlist for local multilingual note-title generation.
- **Scope:** Primary-source research and documentation only. No dependency/model downloads, inference, configuration changes or dataset-content access.

### Progress

- 2026-11-02: Inspected production Qwen3-0.6B configuration, Python MLX-LM 0.31.1 pin and experiment interfaces. Separate Python compatibility from the native pinned runtime; model cards and general benchmarks cannot establish title quality.

- 2026-11-02: Documented all seven candidates plus focused alternatives, effective-versus-total parameter caveat, model-card license/language evidence, separate Python/Swift compatibility and proposed controlled comparison. Added index/plan references without changing models or configurations.

### Verification

- Verified author model cards/configuration and pinned upstream runtime source; distinguished architecture presence, actual loading and title-quality evidence.
- Passed documentation formatting, local-link checks, `git diff --check` and scope review. No app tests/builds or model runs required for research.

### Remaining work

- Research complete in [the candidate assessment](SMALL_TITLE_MODEL_RESEARCH.md). Downloads, compatibility execution, experiments and production changes require separate authorization.

## 20261102-008 — Add SmolLM and smallest Gemma candidates

- **Status:** Completed
- **Objective:** Add one SmolLM candidate and the smallest Gemma instruction model to the evaluation configuration and research shortlist.
- **Scope:** Disabled, revision-pinned candidate entries in the tracked template and working YAML; documentation and configuration checks. No downloads, inference or dataset access.

### Progress

- 2026-11-02: Selected SmolLM2-1.7B-Instruct and verified Gemma 3 270M IT exists, correcting the earlier shortlist's omission of the smaller Gemma. Checking conversion identities/revisions before editing configuration.

- 2026-11-02: Added disabled SmolLM2-1.7B-Instruct author-published Q8 MLX and Gemma 3 270M IT 4-bit MLX entries to template/working YAML and shared-control selection. Updated operating guide, research and implementation status; preserved other pending research edits.

### Verification

- Passed: 11 focused configuration tests; working-file dry-run (`dataset_read: false`); both YAML files validated with baseline-only defaults and three expected runs after in-memory candidate/shared-profile activation.
- Passed: documentation formatting/local links, `git diff --check` and scoped review. Public revision metadata required normal network escalation after sandbox DNS failure; fetched metadata only.

### Remaining work

- Configuration addition complete. Snapshots are not provisioned; actual loading and title quality remain unverified.

## 20261102-009 — Evaluation debug run

- **Status:** Completed
- **Objective:** Execute a bounded evaluation debug run and inspect aggregate outcomes/resource diagnostics.
- **Scope:** Begin with the existing synthetic end-to-end smoke command; clarify real-inference scope separately. Preserve working configuration; no private content access or implicit model downloads.

### Progress

- 2026-11-02: Inspected CLI and working YAML. Existing smoke command exercises isolated generation/scoring/reporting with synthetic records and two sampling configurations. Working evaluation virtual environment is absent; temporary verified core/tracking environment remains available. Asked whether a real-inference follow-up is intended while proceeding with the independent pipeline check.

- 2026-11-02: Executed fresh synthetic smoke and separately verified aggregate resource logging to an isolated local MLflow SQLite store; working YAML is unchanged. Metadata-only checks confirmed configured snapshots are absent.

### Verification

- Passed: fresh smoke campaign at `benchmarks/title_generation/results/debug-20261102-001`, two configurations × four synthetic notes, isolated generation/scoring and standalone HTML/CSV/JSON outputs.
- Passed: aggregate assertions for completion, wall/CPU time, peak RSS and attempt throughput; unavailable synthetic token throughput remains null. Two local SQLite MLflow runs finished and retained resource metrics.
- Passed: `git diff --check` and scope review. No existing dataset contents accessed or model inference performed.

### Remaining work

- Synthetic debug check complete. Actual model inference is not tested: MLX/MLX-LM are absent from the available environment, and all three configured snapshot directories are missing. A real-model follow-up needs provisioning and a chosen synthetic/public input scope; the clarification question remains available.

## 20261102-010 — Full evaluation run instructions

- **Status:** Completed
- **Objective:** Give reproducible setup, model provisioning, configuration, execution and result-viewing steps for the current evaluator.
- **Scope:** Instructions/documentation only. No installations, model downloads, training/inference or dataset-content access.

### Progress

- 2026-11-02: Reviewed actual CLI, operating guide, dependency pins, selected model entries and training controls. Full execution requires provisioning; smoke success does not establish real MLX compatibility. Separate the three-model evaluation from optional adapter training and BERTScore.

- 2026-11-02: Added three-model provisioning/registration/configuration workflow, tracking/report instructions and separate optional sweep/QLoRA/BERTScore prerequisites.

### Verification

- Verified commands against the current CLI, configuration names/revisions and official Hugging Face download documentation.
- Passed Markdown formatting/local-link checks, shell syntax validation of guide command blocks and `git diff --check`. No setup/download/inference commands were executed.

### Remaining work

- Instructions complete in the operating guide. Actual MLX environment compatibility, snapshots and real model execution remain unverified.

## 20261102-011 — Execute three-model public evaluation

- **Status:** Completed
- **Objective:** Provision and execute Qwen baseline, SmolLM2 and minimum Gemma evaluation with local resource metrics/reporting and MLflow.
- **Scope:** User authorized the previously documented full three-model workflow: install evaluation dependencies, download pinned snapshots, audit selected public inputs, local inference and aggregate-only results. Training/BERTScore remain disabled. No private note/dataset-content inspection or model-output inspection by the agent.

### Progress

- 2026-11-02: Confirmed Apple Silicon, available disk space and working configuration; preserve pending source/documentation edits. Proceed with isolated local environment and revision-pinned snapshots, then public audit and sequential workers.
- 2026-11-02: Installed pinned evaluation/tracking dependencies; `pip check` and all 59 Python tests passed in the actual environment. Downloaded and registered all three pinned snapshots; saved the resolved environment locally. Enabled the three candidates/shared-control and local tracking. Public audit passed for 600 development records and held-out overlap checks.
- 2026-11-02: Sandbox denied Metal device access during synthetic real-model preflight. Using normal escalation for GPU access before full evaluation; no private data involved.
- 2026-11-02: Escalated synthetic preflight loaded/generated/unloaded all three actual models successfully. Launched the three-model public campaign with Metal access and offline model loading; baseline generation is in progress.
- 2026-11-02: Qwen baseline completed generation/scoring for all 600 public development notes; SmolLM2 is running. Aggregate baseline acceptance is 55.17% first attempt / 73.17% after retries; this is mechanical validity, not quality acceptance.
- 2026-11-02: SmolLM2 completed generation/scoring for all 600 records: 35.5% first-attempt / 58.5% retry-inclusive filename acceptance. Gemma 270M generation started; no settings changed during comparison.
- 2026-11-04: Gemma 3 270M completed all 600 records, but none passed title validation after retries. All three runs completed with scoring and local MLflow logging; the aggregate report and campaign manifest were generated.
- 2026-11-04: Verified the three pinned model snapshots, 600/600 coverage for each model, resource metrics, report hashes and three finished MLflow runs. Started the local MLflow dashboard on `127.0.0.1:5000` after generation finished.

### Verification

- Passed: pinned dependency environment (`pip check`) and all 59 Python tests; three model snapshots registered and loaded in synthetic preflight; public-data audit passed for the configured 600-note development sample.
- Passed: Qwen, SmolLM2 and Gemma 3 270M completed 600 records each; local scoring/report generation and MLflow tracking completed. Aggregate verification confirms resource metrics, exact coverage, verified report hashes, snapshot integrity and three finished MLflow runs.
- Outcome: retry-inclusive mechanical title acceptance is Qwen 73.17%, SmolLM2 58.5%, and Gemma 0%. Invalid-title failure counts are 161, 249 and 600 respectively. Results do not measure title usefulness or faithfulness.

### Remaining work

- No remaining work for the authorized run. Training, BERTScore, human review and further prompt/model tuning were outside scope and were not performed.

## 20261104-001 — Gemma single-file Jupyter debug notebook

- **Status:** Completed
- **Objective:** Create a quick local notebook that loads the Gemma 3 270M snapshot and generates a title for a user-selected Markdown/text file using the exact production prompt and generation settings.
- **Scope:** One notebook only, plus this mandatory task record. Do not execute it against dataset or private note content; no other documentation changes.

### Progress

- 2026-11-04: Confirmed the canonical prompt and generation settings come from `Nts/FilenameModelConfiguration.swift`; the Python evaluator has helpers to export that configuration and render model messages identically.
- 2026-11-04: Added a five-cell notebook that reads a selected UTF-8 file, loads the local Gemma 3 270M snapshot and prints its raw generated title using the exported production prompt, chat-template formatting and generation settings.

### Verification

- Passed: notebook JSON and all four code cells parse; production configuration export reports `title-v2` and 32 output tokens; `git diff --check` passed.
- No model inference or note-file access was performed while creating or validating the notebook.

### Remaining work

- Notebook is ready at `Developer/TitleEvaluation/gemma_single_file_debug.ipynb`. Set `NOTE_PATH` in the notebook before running it in the prepared MLX environment.

## 20261104-002 — Register title evaluation Jupyter kernel

- **Status:** Completed
- **Objective:** Make the Gemma debug notebook selectable in Jupyter with the prepared MLX evaluation environment.
- **Scope:** Install `ipykernel` into the ignored evaluation virtualenv, register a user Jupyter kernelspec, and update notebook kernel metadata. No note access or inference.

### Progress

- 2026-11-04: Diagnosed the mismatch: notebook metadata selected generic `python3` (system Python 3.9.6), while the evaluation virtualenv has MLX but lacks `ipykernel` and a registered kernelspec.
- 2026-11-04: Installed `ipykernel` in the evaluation virtualenv, registered `title-eval` at the user Jupyter kernels directory, and updated notebook metadata to select `Python (Title Evaluation MLX)`.

### Verification

- Passed: registered kernelspec points to `benchmarks/title_generation/.eval-venv/bin/python`; notebook kernel name/display name match; `ipykernel`, `mlx_lm` and `mlx` are installed in that environment; `git diff --check` passed.
- A direct MLX import check was blocked by the sandbox's unavailable Metal device; no model was loaded or inference run for this setup fix.

### Remaining work

- Kernel is registered. In Jupyter, choose **Python (Title Evaluation MLX)** as the notebook kernel.
## 20261110-001 — Use new note titles as filenames

- **Status:** Completed
- **Objective:** Let users enter an optional title for a new note and use it as the Markdown filename on first save.
- **Scope:** Native note draft/save flow, focused regressions, and relevant filename documentation/status. Keep existing note filenames stable and keep title text separate from Markdown content.

### Progress

- 2026-11-10: Reviewed repository guidance, task history, filename suggestion contract, current note creation/save code, and Git status. New drafts currently have no title field and first save always creates a timestamp filename.
- 2026-11-10: Added the optional draft title field, safe normalized title filenames with numeric collision suffixes, title-only saving, regression coverage, and updated save-flow documentation. Title entry stays in memory until a content autosave or explicit save, so autosaving cannot close the title field while the user is typing it.

### Verification

- Passed: `sh Tests/run.sh` completed with 190 tests and zero failures, including title-only saving, Unicode filename normalization, and collision safety. The sandboxed attempt failed before compilation due to SwiftUI macro plugin restrictions; the approved out-of-sandbox run passed.
- Passed: `git diff --check` after trimming an extra trailing blank line; scoped diff review confirms only note title flow, tests, and related docs changed.

### Remaining work

- None.
