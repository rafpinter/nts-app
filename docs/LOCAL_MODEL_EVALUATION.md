# Phase 3.1 — Development-only local model evaluation

The initial model selected by the user is `mlx-community/Qwen3-0.6B-4bit`.
It is a configurable starting point, not a permanent product requirement. Model
selection UI may come later. Evaluation metrics are development diagnostics;
they are not product analytics or a shipping UI requirement.

## Scope and architecture

This section records the Phase 3.1 evaluation tool. Phase 3.2 subsequently added
app integration; see [FILENAME_SUGGESTIONS.md](FILENAME_SUGGESTIONS.md). Production
settings are in `Nts/FilenameModelConfiguration.swift`; this evaluator's
CLI options are independent.


`Developer/LocalModelEval` is an independent native Swift package/workspace.
The Phase 3.1 slice did not link MLX into the app, acquire network entitlements,
or add AI tables or app UI. Phase 3.2 adds those separately.
The evaluator never writes or renames notes. Filename output is raw experimental
text; safe naming/source-version persistence are now in 3.2, and applying it remains 3.3.

- `EvaluationConfiguration` supplies model ID/revision or local weights,
  generation limits, and chat-template thinking preference. `--model` can change
  the model without editing the backend. Model compatibility still requires an
  architecture/tokenizer supported by MLX; an arbitrary repository is not enough.
- `LocalTextGenerator` exposes load/generate/unload using plain Swift values.
  `MLXTextGenerator` contains all MLX factory, tokenizer, and model-container use.
  This boundary is available to carry into future app integration; there is no
  provider registry, settings UI, or speculative persistence schema.
- The command-line caller runs cases sequentially; each uses fresh generation
  context with the loaded weights reused. It bounds note input by a configurable
  character prefix and caps generated tokens. This is not production chunking.
- Thinking defaults off through the Qwen chat-template option `enable_thinking`;
  `--thinking` can compare behavior. Other models may ignore that option.
- Metrics use a monotonic wall clock, MLX completion timings/allocator statistics,
  and process peak RSS. Memory peaks are cumulative for the process and allocator
  figures are not total machine memory. MLX's streaming completion token count
  is decoded-chunk based in this pinned version; treat it as approximate.

The evaluator pins MLX Swift LM **2.29.3**, a macOS-14-compatible API line, rather
than adopting its breaking 3.x API during this experiment. Package lockfiles
record resolved dependencies. This runtime choice can be revisited separately
from the model ID. Xcode is required to compile Metal shaders; plain `swift run`
is insufficient. Apple Silicon is required for this evaluation path.

## Run during development

From the repository root, with Xcode selected:

```sh
# First build compiles the MLX Metal kernels and can take several minutes.
sh Developer/LocalModelEval/run.sh --help

# Explicitly allow downloading weights and tokenizer; runs synthetic notes only.
sh Developer/LocalModelEval/run.sh --download --repeats 2

# Change the model or pin a Hugging Face commit when comparing results.
sh Developer/LocalModelEval/run.sh --download --model mlx-community/Qwen3-0.6B-4bit --revision main

# Local-only loading: use the directory containing config/tokenizer/safetensors.
sh Developer/LocalModelEval/run.sh --model-directory /absolute/path/to/model --repeats 2

# Optionally evaluate one real note read-only; output is visible in your terminal.
sh Developer/LocalModelEval/run.sh --model-directory /absolute/path/to/model --note /absolute/path/to/note.md
```

`--download` permits Hugging Face requests for weights/configuration/tokenizer;
notes and prompts are processed on-device and are not request payloads. The pinned
loader caches downloads under the user's Library/Caches/models/OWNER/MODEL.
Use that full model directory for `--model-directory` and local-only inference.
`--download` may contact Hugging Face again even with cached files. Local-only
mode loads configuration/tokenizer directly from the supplied directory.

The tool reports load time (including any download), per-case raw outputs,
prompt/generation and total times, approximate completion counts, and memory
before/after generation and unload. Empty supplied notes fail before loading.
The synthetic cases cover English meeting notes, technical text, Portuguese,
and instructions quoted inside note content. Manually assess relevance, brevity,
language, and whether it follows the filename-only instruction. No automatic
quality score or acceptance threshold is asserted.

For a failure check, supply a missing local model directory; the tool should
report an error with a nonzero exit status. Launch Nts separately to verify
editing remains usable without the evaluator or model. For offline evaluation,
use `--model-directory` with networking disabled after the explicit download.

Build products, model files, and local results directories are ignored. Keep
personal notes and downloaded weights out of source control. The package is
built in Release for useful performance comparisons despite being a dev-only
tool; running a Debug-optimized model would distort latency measurements.

## Verification

Checked on 2026-10-15 on this Apple Silicon development Mac:

- Xcode Release build with Metal resources passed; `--help` passed.
- Selected Qwen model downloaded and ran all four synthetic cases twice.
- A fresh process with `sandbox-exec` denying all network access loaded the cached
  model and ran all four cases successfully. Local model load took about 0.40 s.
- Initial load including download took 11.86 s. In the two-repeat run, generation
  wall times were 0.058–0.578 s for these short inputs. Peak MLX allocator use was
  461 MiB and peak process RSS was 549 MiB. After unload, active MLX memory was
  about 0.003 MiB and its cache was zero; process peak RSS does not reset.
- Four failure checks passed before loading: no download opt-in, invalid token
  limit, missing local config, and empty note. Each exited with status 1.
- `git diff --check` passed. No new app regression/build run was needed for
  this isolated tool; the previously recorded app checks remain historical.

| Synthetic case | Raw filename output (same across both repeats) | Assessment |
| --- | --- | --- |
| Meeting | `bookstore-event-stem` | Related subject, but includes an unnecessary “stem” suffix |
| Technical | `sqlite-rebuild-idx` | Relevant, somewhat abbreviated |
| Portuguese | `cartas-2023` | Invents a year absent from the source; quality issue |
| Quoted instructions | `prompt-injection` | Follows the summarizing task in this fixture |

These are smoke measurements on one development machine, not a benchmark of
8–16 GB Macs or an approval of filename quality. No personal notes were used.
Long-note behavior, broad quality evaluation, cancellation during download,
and model-switch comparisons remain unverified. The initial model is retained
as requested; prompt/quality refinement belongs to the filename feature slice.

References: [MLX Swift LM 2.29.3](https://github.com/ml-explore/mlx-swift-lm/tree/2.29.3),
[MLX Metal build instructions](https://github.com/ml-explore/mlx-swift/blob/0.29.1/README.md#xcodebuild),
and the [selected model](https://huggingface.co/mlx-community/Qwen3-0.6B-4bit).
