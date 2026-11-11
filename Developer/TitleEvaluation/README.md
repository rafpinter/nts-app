# Configurable local title experiments

Edit **`benchmarks/title_generation/experiments.yaml`**, then launch one command.
Every enabled model × sampling configuration × seed becomes an MLflow run under
one experiment, with a standalone comparison report alongside it. The unchanged
Qwen3-0.6B 4-bit model is the fixed baseline. Optional QLoRA training creates a
separate adapter; the base weights remain unchanged.

Reviewable Python source/templates are here because the repository intentionally
ignores all `/benchmarks/`. Working configuration, data, environments, adapters,
and results stay under `benchmarks/title_generation/`; nothing there is force-added.
The [feature plan](../../docs/TITLE_EVALUATION_PLAN.md) records design and remaining scope.

## Setup and first use

Python 3.11+ is required; MLX additionally requires compatible Apple Silicon/macOS.
Run from the repository root. Keep the preparation environment separate:

```sh
python3 -m venv benchmarks/title_generation/.eval-venv
benchmarks/title_generation/.eval-venv/bin/python -m pip install \
  -r Developer/TitleEvaluation/requirements-mlx.txt \
  -r Developer/TitleEvaluation/requirements-tracking.txt

# Already initialized in this workspace. On a new checkout only:
benchmarks/title_generation/.eval-venv/bin/python Developer/TitleEvaluation/run.py init

# Reads configuration and production Swift source, never dataset/model contents.
benchmarks/title_generation/.eval-venv/bin/python Developer/TitleEvaluation/run.py dry-run
```

`init` refuses to overwrite an existing file. `--config PATH` before the command
selects another main file. All YAML paths resolve relative to its location.
Direct dependency versions are pinned; they are not a universal lockfile. The
verified core/tracking environment is recorded in
[requirements-verified-tracking.txt](requirements-verified-tracking.txt).
MLX and BERTScore runtime environments have not been resolved or model-tested.

Put an already downloaded, immutable model snapshot at `models[].local_path`,
set its actual repository commit in `revision`, and register its checksums:

```sh
benchmarks/title_generation/.eval-venv/bin/python Developer/TitleEvaluation/run.py \
  register-model --model qwen-baseline
```

Registration is a user attestation of local provenance, not proof that files
came from that remote commit. It never downloads files. Execution verifies the
complete registered file set and hashes; changed model files fail validation.
Models needing remote Python code are unsupported. No automatic model discovery
or model downloads occur.

## Run all three selected models

This is the first real evaluation workflow, separate from `smoke`. It requires
installing the MLX/tracking environment above and provisioning model snapshots;
those steps have not been executed or runtime-verified in this workspace.

1. In `benchmarks/title_generation/experiments.yaml`, enable models
   `qwen-baseline`, `smollm2-1.7b` and `gemma3-270m`; enable profiles
   `production-control` and `shared-control`; set `tracking.enabled: true`.
   Keep `qwen-adapted`, all training jobs and `sampling-screen` disabled for the
   initial three-model comparison. Preserve `dataset.allow_private: false`.
2. Provision each exact revision into its configured local path. For example,
   run these **once before registration**, from the repository root:

```sh
benchmarks/title_generation/.eval-venv/bin/hf download \
  mlx-community/Qwen3-0.6B-4bit \
  --revision 73e3e38d981303bc594367cd910ea6eb48349da8 \
  --local-dir benchmarks/title_generation/models/qwen3-0.6b-4bit
benchmarks/title_generation/.eval-venv/bin/hf download \
  HuggingFaceTB/SmolLM2-1.7B-Instruct-Q8-mlx \
  --revision 2bb0b4cebf6f2e93b23779a44f8b93e185609046 \
  --local-dir benchmarks/title_generation/models/smollm2-1.7b-instruct-q8-mlx
benchmarks/title_generation/.eval-venv/bin/hf download \
  mlx-community/gemma-3-270m-it-4bit \
  --revision ff1143e3a10547c9f2129e94ca37059b096b23f4 \
  --local-dir benchmarks/title_generation/models/gemma-3-270m-it-4bit

for candidate in qwen-baseline smollm2-1.7b gemma3-270m; do
  benchmarks/title_generation/.eval-venv/bin/python \
    Developer/TitleEvaluation/run.py register-model --model "$candidate" || break
done
```

The download command follows the official
[Hugging Face download guide](https://huggingface.co/docs/huggingface_hub/guides/download).
Complete all downloads and registrations successfully before proceeding. Downloads
may require model access/login; keep credentials out of the YAML. Registration
hashes the entire directory, including download metadata: do not redownload into
or modify registered directories during an experiment. A new artifact needs a
separately selected snapshot location and identity.

3. Run `dry-run` and confirm exactly three evaluations and zero training jobs.
   Run `audit`, then `run`, using the commands below. The default input is the
   existing public development sample, not the private snapshot. `max_records`
   rejects oversized inputs; it does not take a smaller sample.
4. Open the comparison report, and start the loopback MLflow server as shown
   below. The run includes automatic validity/diversity/resource scoring;
   BERTScore requires a separately provisioned encoder and remains optional.

For a sampling sweep, update `sampling-screen.models` to the three selected
names before enabling the profile: its initial list only targets baseline and
adapted Qwen. Avoid duplicate effective configurations with shared controls and
check the expanded matrix before execution. Additional Qwen models from the
research shortlist have not been configured.

To include QLoRA, explicitly select public `training[].source_files`, enable the
training job and `qwen-adapted`, and keep the adapter in shared-control. This adds
training before generation and evaluates the final adapter. The initial training
source list is empty, so enabling training alone is insufficient. The training
hyperparameters are an unmeasured pilot; see the training section before running.

## The main YAML

- `models`: named candidates, immutable revisions, local paths, role, and enabled flags.
- `configurations`: enabled model selections and sampling values/grids.
- `seeds`: repeated generation seeds, overridable per configuration.
- `training`: optional named QLoRA jobs; disabled initially.
- `dataset`: explicit normalized development/test JSONL, snapshot manifest and held-out files.
- `scoring`: automatic panel and optional pinned local BERTScore encoder.
- `tracking`: one local MLflow experiment name, SQLite URI and artifact directory.
- `limits`: maximum runs/attempts, per-attempt timeout, and total worker timeout.

The initial file enables only the production baseline. Turn on `tracking.enabled`
for MLflow. To add another model, add its entry, enable it and include its name in
`shared-control` or a new configuration. To evaluate an adapter, enable
`qwen-adapted`, its shared control, and the corresponding training job (or use
`adapter` with an existing compatible adapter directory instead of `adapter_from`).

The template and current working file also include disabled `smollm2-1.7b`
(author-published SmolLM2-1.7B-Instruct MLX, **8-bit**) and `gemma3-270m`
(Gemma 3 270M IT MLX, **4-bit**) candidates pinned to immutable revisions.
Provision the exact snapshots at their configured local paths and register them
before enabling the model flags and `shared-control`. Neither has been load-tested
here. SmolLM2 is primarily English; assess Portuguese separately. See the
[selected artifacts](../../docs/SMALL_TITLE_MODEL_RESEARCH.md#user-selected-additions--2026-11-02).

An example sweep profile:

```yaml
- name: sampling-screen
  enabled: true
  models: [qwen-baseline, qwen-adapted]
  generation:
    temperature: [0.2, 0.8]
    top_p: [0.9, 1.0]
    top_k: [null, 20, 50]
  seeds: [17]
```

This expands to 12 configurations per enabled selected model and seed. Top-k
means the number of candidate tokens; top-p is a cumulative probability threshold.
`null` disables top-k. Duplicate effective runs and oversized matrices fail.
Temperature zero is a separate greedy configuration with top-p 1/top-k null.
Keep the `production-control` anchor enabled; other Qwen sweeps do not replace it.
Production prompt/settings are exported from the Swift configuration at execution
time, with a source hash. This is a Python export fingerprint, not the Swift
Codable fingerprint or a claim of full app-runtime parity.

## Train without contaminating evaluation

For a training job, set `source_files` to selected prepared public normalized
corpora, for example `data/public/2026-10-26/normalized/dialogsum_en.jsonl.gz`.
Only rows marked `train` are eligible. A seeded source-group split creates
training validation from those training groups; existing development/test rows
are excluded from gradient updates. Alternatively supply explicit separate
`train_files` and `validation_files`; do not combine both selection modes.

`heldout_files` must include evaluation development and test samples. The runner
also automatically adds its selected evaluation file and holdout paths. It
checks full IDs, exact text hashes and source groups across partitions before
sampling/filtering. Near-duplicate and cross-language alignment remain limitations.
Choose reviewed/legal training sources; dataset licenses are not interchangeable.

Targets are separate reference titles, filtered for usable 2–6-word titles and
balanced by source/language under explicit caps. These are unreviewed proxy labels;
filtering does not prove title quality. Long sequences fail rather than truncating
away the target. Assistant-title-only loss and a no-thinking chat template are used.
The template's hyperparameters are a conservative pilot proposal, not measured
recommendations for this machine. The final adapter is evaluated; automatic
best-checkpoint selection is not implemented. Validation curves and checkpoints
remain available for subsequent selection without consulting test results.

The initial release prepares/trains only selected **public normalized files**.
Private source files and Obsidian snapshots are rejected by training even if
`allow_private` is set. The original vault is never a supported input. Evaluation
of a normalized protected copy requires explicit `dataset.allow_private: true`;
this switch does not authorize the agent to inspect it or launch it automatically.
No protected dataset has been executed during implementation.

## Execute and compare

After selecting data/models/settings and enabling tracking if desired:

```sh
benchmarks/title_generation/.eval-venv/bin/python Developer/TitleEvaluation/run.py audit
benchmarks/title_generation/.eval-venv/bin/python Developer/TitleEvaluation/run.py run
```

`run` executes enabled training jobs first, then evaluates configurations
sequentially in fresh processes, scores after unloading, writes reports and logs
aggregate results to MLflow when enabled. Downloads are never included implicitly.
Failed notes remain in reliability denominators; failures and incomplete runs
remain visible. A failed worker is not a successful benchmark. Separate stage
commands are `score`, `report` and `track`; they reuse saved predictions.

Open `results/title-experiments/report/comparison.html` under the benchmark
folder for interactive metric/run/source-language filters, configuration tables,
paired baseline differences and group-bootstrap intervals. CSV/JSON exports are
beside the HTML. The report has no CDN or external assets. Scores are stored as
JSONL; Parquet/static figure exports and human-review import are not implemented.
Human usefulness, faithfulness and language agreement remain unmeasured, rather
than being inferred from reference similarity or word counts.

To view local MLflow, run from `benchmarks/title_generation/` using the paths in
the default YAML (keep this server in your terminal):

```sh
MLFLOW_DISABLE_TELEMETRY=true DO_NOT_TRACK=true .eval-venv/bin/mlflow server \
  --host 127.0.0.1 --port 5000 \
  --backend-store-uri sqlite:///results/title-experiments/mlflow.db \
  --default-artifact-root ./results/title-experiments/mlflow-artifacts
```

Visit `http://127.0.0.1:5000`, select `title-generation`, filter `stage=evaluation`,
select runs and use Compare to plot metrics against temperature, top-p, top-k or
model. Training runs have `stage=training` with numeric learning curves and
adapter lineage. Each configuration/seed is a run within this shared experiment.
Only loopback/SQLite tracking and local artifact stores are accepted.

## Resource measurements

Every new evaluation records wall time, process CPU user/system seconds and
process peak resident memory for loading, warmup, evaluation and the whole worker
session (including unload). Resumed sessions retain their measurements; totals
sum sessions, while memory uses their maximum. Completed resume is a no-op.
Loading here includes local snapshot verification; `load_seconds` retains the
narrower backend import/weight-loading timer. Downloads are never timed implicitly.
Failed or interrupted phases can be missing; incomplete measurements stay blank.

Attempts retain latency, CPU time and process peak RSS, including failed attempts
and retries. Reports and local MLflow expose these aggregates automatically, along
with attempts/second and generation tokens/second when token counts are available.
Throughput divides all generated tokens (including retries) by full attempt time,
including prompt processing and output validation; it is not decode-only speed.
Synthetic backends have no token throughput. Old artifacts remain unmeasured.

CPU percent uses one core as 100% and may exceed 100% with multiple CPU threads.
It excludes GPU work and child processes. RSS is a process-lifetime high-water mark,
including earlier phases, not a phase allocation or instantaneous sample. MLX peak
bytes remain the runtime allocator's cumulative peak; do not add them to RSS on
unified-memory Macs. GPU utilization, FLOPs, power/energy, system memory pressure,
and scoring-process resource measurements are not collected. These Python worker
measurements do not establish native app performance. Training retains its existing
runtime duration, RSS/MLX peaks and learning-curve throughput metrics.

## Optional BERTScore

Install `requirements-scoring.txt`, explicitly provision a local multilingual
encoder, and use `encoder-digest --path LOCAL_ENCODER` to obtain its file digest.
Set `scoring.bertscore.enabled`, `model_path`, `model_sha256`, and `num_layers`.
The digest covers sorted relative filenames followed by file bytes. This utility
is for model files, never dataset paths. No encoder downloads are performed.
IDF and baseline rescaling are unsupported. Scores compare generated titles with
reference titles, conditional on accepted outputs with references; coverage and
missingness are reported. A missing/failed encoder never becomes a zero score.

## Privacy, artifacts and reproducibility

CLI stdout contains allowlisted aggregate/status/configuration information only.
Raw attempts and rendered prompts stay in restricted local run artifacts. SDK
output is suppressed; training logs are restricted local files which may contain
content and must not be opened by the agent. MLflow receives no notes, references,
raw predictions, prompts or protected paths. Reports also exclude row contents
and identifiers. This boundary applies to development agents as well.

Run manifests include dataset/prompt/configuration identities, model and adapter
hashes, tokenizer/template hashes, package environment and source implementation
hash. Resume accepts only identical inputs and validates attempt sequences; data
mutation after the audit fails. A completed training job verifies adapter hashes
before reuse. Failed training requires a new named job/output directory rather
than silently continuing from an uncertain checkpoint.

Normalized acceptance follows the app's lexical filename rules on synthetic
fixtures. No live filesystem collision fixture is applied; the report measures
cross-note normalized collisions separately. Unicode/runtime differences and
interactive Swift behavior still require native verification. Python timing and
memory measurements do not measure app performance. BERTScore and automatic
validity do not establish usefulness or faithfulness.

## Verification

Core synthetic tests need only `requirements-core.txt`; the real SQLite
integration test runs when `requirements-tracking.txt` is installed:

```sh
PYTHONDONTWRITEBYTECODE=1 PYTHONPATH=Developer/TitleEvaluation \
  benchmarks/title_generation/.eval-venv/bin/python -m unittest discover \
  -s Developer/TitleEvaluation/tests -v

benchmarks/title_generation/.eval-venv/bin/python Developer/TitleEvaluation/run.py \
  smoke --output benchmarks/title_generation/results/synthetic-demo
```

The smoke command uses only developer-authored synthetic inputs and a synthetic
backend; it ignores the selected dataset, does not import MLX and does not train.
Its report is prominently labeled as a demonstration. No actual model quality,
QLoRA memory feasibility or Swift acceptance is established by these checks.
