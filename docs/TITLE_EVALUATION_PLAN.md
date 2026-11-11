# Python title evaluation and report plan

Original plan: proposed on 2026-11-02; implementation was subsequently requested.
The [implementation README](../Developer/TitleEvaluation/README.md) is the current
operating guide. Configuration, generation/training adapters, scoring, reports and
local MLflow tracking are implemented and synthetically verified. No real model
training/inference or private-data execution has been performed. Historical proposal
sections below remain design context, not claims that every proposed feature ships.

## Purpose and current evidence

Compare local title generators for faithfulness, usefulness, acceptance, latency,
and memory. Produce a reproducible standalone HTML report and machine-readable
results in Python, with local MLflow for experiment comparison. Avoid a composite
quality score until human review establishes that its components are meaningful.

The local preparation [README](../benchmarks/title_generation/README.md) documents
four public sources, six source/language slices, and development/test samples of
600 records each. Those counts are existing documentation, not a fresh dataset
validation. Inference, scoring, and MLflow integration are not implemented.
Private Obsidian contents remain prohibited, including copied contents and local
inference. Evernote is unnecessary for the initial public benchmark; its format,
availability, and permissions have not been established.

The older proposal's temperature 0.2 is obsolete. Current production
[configuration](../Nts/FilenameModelConfiguration.swift) uses Qwen3-0.6B-4bit,
temperature 0.5, top-p 0.9, thinking disabled, 32 output tokens, a 4,000 Swift
Character prefix, and three attempts. Export and fingerprint this configuration
at execution time rather than copying defaults into independent scripts.
The historical Swift evaluator hardcodes another prompt and temperature zero.
Neither its measurements nor future Python measurements establish app quality
or app performance without explicit parity verification.

## Pipeline and implementation boundaries

Proposed stages under the existing ignored `benchmarks/title_generation/`:

1. Audit an explicitly selected public snapshot and freeze an evaluation manifest.
2. Generate locally in Python through a replaceable backend, initially MLX on
   Apple Silicon, retaining every attempt. Run one model in an isolated process.
3. Unload generation models; score saved predictions in a separate process.
4. Import blinded human ratings, aggregate paired comparisons, render HTML and
   machine-readable summaries, and optionally log to local MLflow.
5. Verify finalists through the production Swift runtime on the same public
   inputs before recommending a shipping model.

Proposed commands: `audit`, `generate`, `score`, `review-export`, `review-import`,
`report`, and `track`. Each stage consumes immutable artifacts and records input
hashes. Report generation must work without an MLflow server or loaded model.
A notebook may explore results; reusable modules and CLI commands own computation.
No orchestration service, feature store, or model registry is needed initially.

## Data and experimental design

- Reuse prepared public sources; do not prepare a competing copy implicitly.
  Check manifest completion, checksums, license/provenance, schema, unique IDs,
  nonempty text, reference coverage, grouping, and development/test separation.
- Existing preparation removes exact duplicates and groups articles, but lacks
  near-duplicate detection and WikiLingua cross-language alignment. Audit these
  before freezing a new benchmark version; keep discovered clusters in one split
  and preserve official held-out boundaries. Quarantine ambiguous overlaps.
- Keep references, filenames, tags, and source metadata outside model inputs.
  Record existing leading-reference removal and potential residual leakage.
  Public summaries/headlines/topics/headings are proxy references with different
  quality; report reference type and source separately.
- Pilot approximately 48 public development records, balanced across six slices.
  Use the existing 600-record development sample for tuning and the 600-record
  held-out sample only after configuration selection and leakage audit. These
  sizes are proposals; use pilot variance to decide whether more data are needed.
- Include short/long inputs, code, lists, mixed-language and synthetic adversarial
  cases. Keep synthetic stress tests separate from population estimates.
- Freeze one production-aligned baseline; treat prompt tuning and model-specific
  best configurations as separately labeled experiments. Do not adopt the old
  candidate list without a fresh architecture/tokenizer/license compatibility check.
- Use one fixed seed for screening and three for finalists, with identical notes
  and seed schedules. Seeds do not guarantee identical results across runtimes.
  Store actual rendered chat inputs, truncation policy, tokenizer/template hashes,
  quantization, model commit, dependency lock, hardware/OS, code commit and dirty
  diff fingerprint. Swift grapheme-prefix semantics need explicit Python parity.

## Artifact contracts and failure policy

Use schema-versioned JSONL for attempts and portable Parquet for scored tables.
Store generated artifacts locally outside Git; tracked documentation contains no
note rows. Hash manifests/configuration and retain the exact selected note IDs.

| Artifact | Required fields |
| --- | --- |
| Dataset manifest | Snapshot hash, sample IDs, split/group, source/language, reference type, exclusions, audit version |
| Run manifest | Run ID, backend, model commit, configuration and prompt hashes, seed, runtime/hardware, stage status |
| Attempt table | Run/note/seed/attempt IDs, raw output, parsed title, normalized filename, finish reason, validation/error codes, timing and memory |
| Score table | Attempt or final-result key, scorer/version/hash, values, applicability, missingness/error reason |
| Human ratings | Blinded comparison ID, rater ID, randomized order, rubric/version, dimensions, preference/tie, adjudication |
| Report manifest | Input hashes, score/review versions, aggregation/CI settings, report hash and completion status |

Fail on duplicate keys, incompatible manifests, missing predictions, or changed
inputs during resume. Resume only missing work under the same identity; preserve
failed attempts. Count timeouts, crashes, empty outputs and exhausted retries in
reliability denominators. Never hide them through successful-only reporting.
Scoring failures are missing measurements, not zero similarity. Record coverage
and denominators on every chart/table. Incomplete runs remain visibly incomplete.

## Metric panel

| Dimension | Report and interpretation |
| --- | --- |
| Prompt compliance | Single natural title, no explanations/prefixes/extensions, 2–6 words, language agreement; separate from app acceptance |
| App acceptance | First-attempt and final normalized acceptance; retry counts and reasons; collision behavior under a declared fixed folder fixture |
| Faithfulness/usefulness | Blinded human relevance, unsupported details, natural wording, retrieval usefulness, pairwise preference with ties |
| Reference similarity | BERTScore P/R/F1 against reference titles, with reference coverage/type; supporting evidence only |
| Repetition | Distinct-1/2, duplicate titles across different notes, normalized collisions; controlled note set and lengths |
| Performance | Download/load separately; warm p50/p95, retry-inclusive end-to-end latency, failures/timeouts, peak process RSS and backend memory |

The app normalizer currently accepts some prompt violations, including one-word
titles and removable labels/extensions. Match its implementation through shared
public conformance fixtures before claiming app acceptance. Do not tighten
production validation as a benchmark side effect. Define a versioned Unicode
word segmentation rule for prose metrics and retain the app's separate rule.
Short-title language detection needs an unknown category and human checks.

For BERTScore, provisionally use one pinned multilingual encoder for English and
Portuguese, validated on the reviewed pilot before selection. Pin encoder commit,
layer, tokenizer, package versions, IDF and rescaling settings, multi-reference
aggregation and score hash. Start without IDF or baseline rescaling; do not assume
a supported baseline exists. Do not compare scores from different encoders as a
single scale. Empty/failed generations stay in reliability results; show clearly
whether similarity is conditional on successful outputs. References never become
note text. The implementation supports multiple references and recommends
reporting configuration hashes: [BERTScore](https://github.com/Tiiiger/bert_score).

Optional local LLM judging belongs after human calibration: measure agreement,
position bias, self-preference and failures; randomize order and allow ties.
Use a fixed rubric and judge revision. A judge must see the model-visible input
for primary faithfulness evaluation; label full-document review separately for
truncated inputs. Remote judging is not authorized. Human ratings remain the
primary usefulness evidence; no agent/RAG metric suite is required for this task.

## Statistical comparison and decision rules

Compare paired note outcomes; keep all seeds for a note together. For related
notes, resample source groups rather than treating each row as independent.
Stratify by source/language and report per-slice counts, effects and 95% intervals.
Show equal-slice macro averages separately from sample-weighted averages; neither
represents real app traffic without evidence about its distribution.

Use a seeded paired cluster bootstrap with 10,000 resamples for effect intervals;
record method and handle degenerate/small slices explicitly. SciPy provides
[paired bootstrap primitives](https://docs.scipy.org/doc/scipy/reference/generated/scipy.stats.bootstrap.html),
but cluster construction is our responsibility. Avoid picking winners by tiny
point differences or testing every metric until one is significant.
Predeclare primary comparisons, practical improvement margins, and acceptable
reliability/memory/latency budgets after the pilot and before the held-out run.

Blindly review 60–100 shared notes, stratified by slice, plus a separate targeted
failure sample. Randomize model order; distinguish representative estimates from
failure discovery. Use a second reviewer on an overlapping subset when available,
report agreement, and retain disagreements. A single owner reviewer is acceptable
if explicitly reported. Recommend a model only when usefulness/faithfulness and
reliability pass declared gates within the hardware budget. Show quality/latency/
memory tradeoffs and inconclusive outcomes instead of forcing one winner.

## Report deliverable

A standalone HTML report with embedded plots, local drill-down and filters:

1. Decision and evidence scope: candidates, baseline, completed runs, limitations.
2. Dataset coverage: source/language/reference type, length/truncation, leakage audit.
3. Comparison table: paired effects/intervals, acceptance, retries, human preference,
   BERTScore coverage, latency and memory; flag incomparable configurations.
4. Quality/latency scatter, latency ECDF, failure reasons, and slice comparisons.
5. Blinded review results and local error examples, retaining all failed attempts.
6. Reproduction manifest, scorer versions, environment and data provenance.

Detailed text examples are local public-data artifacts by default; shareable
exports omit row text unless explicitly selected. Render note/model text as escaped
text, never executable HTML. Export aggregate CSV/JSON alongside HTML and static
PNG/SVG figures. A report build must reproduce scores and figures from saved
artifacts without regeneration. Its conclusion must distinguish Python experiment
results, Swift verification, and manually accepted product behavior.

## Tooling and MLflow

Proposed minimal stack: locked Python environment, MLX generation backend,
PyArrow/Polars tables, SciPy statistics, BERTScore/Transformers scoring, Plotly HTML
with static export, and MLflow tracking. Confirm compatible versions at actual
implementation time; this plan does not claim any environment has been tested.

Use local SQLite metadata and local artifacts, explicitly bound to loopback.
MLflow documents SQLite as its default since 3.7:
[self hosting](https://mlflow.org/docs/latest/self-hosting/).
Keep one generation run per model/configuration/seed; separate scoring runs link
to prediction hashes, and comparison runs link to all inputs. Rescoring never
mutates historical generation results. Log dataset/configuration digests,
parameters, aggregate metrics and artifacts; predictions remain usable without MLflow.

Current MLflow provides GenAI evaluation, custom scorers and annotation workflows:
[evaluation documentation](https://mlflow.org/docs/latest/genai/eval-monitor/).
Use custom deterministic scorers only if their UI adds value; keep our scoring
functions independent. Do not mix classic EvaluationMetric APIs with GenAI Scorer
APIs or enable provider-backed judges implicitly. Disable MLflow telemetry using
the documented opt-out before local execution; current versions enable usage
tracking by default: [usage tracking](https://mlflow.org/docs/latest/community/usage-tracking/).

## Proposed reviewable slices and verification

1. Artifact schemas and report built from synthetic predictions. Verify joins,
   missing results, retries, paired calculations, deterministic rendering and
   escaping. Deliver a complete demonstrator without downloading models.
2. Public snapshot audit and frozen pilot manifest. Verify no split leakage,
   declared completion and provenance; preserve existing preparation outputs.
3. Local Python runner and production conformance fixtures. Verify reproducible
   resume, timeout/crash reporting, clean process memory measurements, and exact
   configuration capture using synthetic/public inputs only.
4. Separate scoring and blinded review import. Verify multi-reference handling,
   missingness, scorer caching, rating joins and seeded group bootstrap.
5. Local MLflow adapter, pilot report, and frozen acceptance protocol. Then run
   the held-out comparison only after configurations and gates are selected.
6. Separate Swift verification for finalists; document runtime differences and
   remaining desktop acceptance rather than transferring Python performance claims.

Each slice requires an implementation request. Existing preparation tests and
public validation apply when preparation changes; app regressions/builds apply
when app code changes. Documentation planning needs link, formatting and diff
checks only. This plan does not supply measured results or choose a new model.

## Requested extension: model sweeps and Qwen fine-tuning

User direction, 2026-11-02: baseline is the existing Qwen3-0.6B 4-bit model with
no fine-tuning. Compare it with a locally fine-tuned version and other unfine-tuned
models; make the candidate list and sampling configurations editable. This is a
planning request, not permission to execute experiments now.

### Editable experiment configuration

Propose one `experiments.yaml` under `benchmarks/title_generation/configs/` with
four sections: `models`, `generation`, `training`, and `evaluation`. The file is
the user's place to add/remove candidates and specify revisions. Keep the
existing benchmarks ignore rule; a future tracked configuration template can
live under `Developer/TitleEvaluation/` if requested.

Illustrative schema only, not an executable configuration:

```yaml
models:
  - name: qwen-baseline
    model_id: mlx-community/Qwen3-0.6B-4bit
    revision: 73e3e38d981303bc594367cd910ea6eb48349da8
    adapter: null
    role: baseline
  - name: qwen-adapted
    base: qwen-baseline
    adapter_from: qwen-title-training
    role: fine_tuned
  # Add other model IDs and immutable revisions here; no training by default.
generation:
  production_control: {temperature: 0.5, top_p: 0.9}
  screening:
    temperature: [0.2, 0.5, 0.8]
    top_p: [0.9, 1.0]
    top_k: [null]
  optional_top_k: [20, 50]
  screening_seeds: [17]
  finalist_seeds: [17, 29, 43]
training:
  name: qwen-title-training
  method: qlora
  base: qwen-baseline
  dataset_manifest: REQUIRED_SELECTED_TRAINING_MANIFEST
  loss: assistant_title_only
  hyperparameters: REQUIRED_PILOT_CONFIGURATION
evaluation:
  development_manifest: REQUIRED_FROZEN_DEVELOPMENT_MANIFEST
  test_manifest: REQUIRED_FROZEN_TEST_MANIFEST
  tracking: local_mlflow
```

“Top N” is provisionally interpreted as top-k (retain the k highest-probability
tokens). Top-p is a distinct cumulative-probability threshold. Both are supported
concepts in [generation configuration](https://huggingface.co/docs/transformers/main_classes/text_generation).
Validate support and semantics in the selected MLX version; null means disabled
explicitly, not an unknown backend default. Unsupported controls fail validation.
Greedy decoding is a separate optional control; do not sweep sampling controls
that have no effect in greedy mode.

Before execution, expand a dry-run matrix listing model/configuration/seed,
expected generations and maximum attempts. Six initial sampling combinations per
model are proposed. Explore optional top-k only on finalists, with an explicit
budget, rather than multiplying every training and generation parameter together.
Record the effective settings and model-specific chat template for every run.

### Controlled comparison sequence

1. Freeze data and protocol. Run unfine-tuned Qwen with production settings as
   the permanent anchor, and screen sampling settings on development data.
2. Train Qwen adapters on training records only. Select checkpoints using a
   separate training-validation split; select sampling using development data.
3. Evaluate base and adapted Qwen with exactly the same production settings to
   isolate the adapter's effect. Also show their separately selected best
   development configurations, clearly labeled as tuned comparisons.
4. Evaluate other unfine-tuned models under the same shared controls and their
   separately selected sampling settings. Treat this as a model-selection axis,
   independent of the fine-tuning experiment.
5. Freeze finalists, checkpoints and sampling choices, then evaluate all on the
   same held-out test notes and seed schedule. Never use test scores to choose
   checkpoints or settings. Compare Swift-compatible finalists separately.

### Fine-tuning method and target quality

Prefer local QLoRA adapter training over full-weight training for the 4-bit base.
The official [MLX LM training guide](https://github.com/ml-explore/mlx-lm/blob/main/mlx_lm/LORA.md)
documents LoRA and QLoRA for quantized models. This establishes a candidate method,
not compatibility or memory feasibility for our pinned model/runtime; verify
those with synthetic fixtures first. Keep original weights unchanged and identify
each adapter by base revision, training configuration and checkpoint hash.

Training requires supervised note-to-title pairs. Use existing public training
partitions with references outside the input, not the development/test samples.
Existing headline/topic/heading labels are noisy proxies and often violate the
2–6-word target. Define versioned automated eligibility rules and source/language
balancing before training; report aggregate retention, exclusions and target-length
statistics. Do not silently truncate titles into labels or treat arbitrary
filenames as reviewed targets. Train only on the assistant title tokens with the
same instruction structure and input-prefix policy used for evaluation. Do not
split long notes into fragments that inherit an unsupported whole-note title.

Propose a capped, balanced pilot training subset and one conservative adapter
configuration first. Determine rank, layers, learning rate, batch/accumulation,
sequence cap, update budget and checkpoint cadence after the synthetic memory
check; record all explicitly. A small development-only search may follow. Log
training loss, validation loss, update count, token count, duration and peak memory,
but select for actual title quality as well as loss. Retain failed/OOM runs.
Evaluate training-seed variability separately from inference-seed variability.

### Data use without agent inspection

The user permits planning for automated use of data under benchmarks while
prohibiting agent inspection. Future local code may consume explicitly selected
data for the authorized training/evaluation purpose; the agent must not open,
preview, render or receive raw rows, prompts, titles, predictions, memorized
samples, or content-bearing exception messages. No remote processing is allowed.
This extends the older blanket no-inference boundary only for the future,
explicitly requested automated job; no content use is authorized during planning.

Default to prepared public training data. Private copies are not silently included:
select their scope explicitly before a private-data job. Such a job must not touch
the original vault and must gate on copy completion, usable supervised targets,
and privacy-preserving split validation. Content-based hashes/grouping, if needed,
belong inside the authorized local process; expose only aggregate audit status to
the agent. If target quality cannot be established without prohibited inspection,
exclude that source and report the limitation.

Disable sample printing, row-level autologging, prompt tracing and HTML examples
for these jobs. Expose allowlisted numeric/status summaries only; keep raw training
and prediction artifacts restricted locally for the user's own inspection. Exception
handling must redact content before logs reach agent tools. Private filenames and
reference titles are also excluded from logs. Users may view local detailed results;
that does not authorize the agent to inspect them. Automated content use must be
purpose-bound and must not become permission for ad hoc analysis.

This stricter no-inspection workflow supersedes the earlier optional local example
drill-down and agent-visible blind-review exports for protected jobs. Review remains
possible directly by the user, with only aggregate ratings returned to the agent.

### MLflow comparison layout

One experiment groups the title benchmark. Training runs log aggregate learning
curves, settings and adapter lineage; evaluation runs link to their base/adapter
and frozen dataset/configuration hashes. Comparison runs link to all evaluated
runs. Avoid assuming that nested runs alone express all many-to-many relationships.

The table and HTML report can filter/group by model, fine-tuned status, adapter,
temperature, top-p, top-k, seed, source and language. Show baseline deltas for
acceptance, faithfulness/usefulness, BERTScore, retries, p50/p95 latency and memory.
Provide sampling heatmaps and quality/latency tradeoff plots, distinguishing
production controls from each model's tuned best. Label incomplete runs and missing
scores. Training cost is separate from inference cost; adapter inference and any
fused/requantized export are different evaluated artifacts.

Add implementation slices for configuration validation/dry-run expansion,
protected logging, training-data eligibility/splits, synthetic adapter training,
and finally the requested local pilot. All remain unimplemented. Model additions,
training and sweeps must respect explicit resource budgets and the data boundary.


## Implementation checkpoint — 2026-11-02

- Implemented reviewable source/templates in `Developer/TitleEvaluation/`, preserving
  `/benchmarks/` ignore rules. The working main YAML, datasets and results stay under
  `benchmarks/title_generation/`. One CLI expands enabled model/configuration/seed
  combinations into sequential isolated workers and one shared MLflow experiment.
- Production configuration export, immutable local snapshot registration, adapter
  lineage, protected diagnostics, retries/resume, grouped training validation,
  full exact/group overlap checks, automatic scoring, paired group bootstrap,
  aggregate-only interactive HTML/CSV/JSON and MLflow training/evaluation tracking
  are implemented. Optional BERTScore requires a provisioned local encoder.
- Verification uses synthetic records and mocked MLX APIs, plus real local SQLite
  MLflow integration. The synthetic demo is labeled explicitly and establishes no
  model-quality or runtime-feasibility claims. See the task log for current results.
- Not implemented: human-review import, local judge, Parquet/static image exports,
  near-duplicate/cross-language alignment, automatic best-checkpoint selection,
  private training, model downloads and production Swift finalist verification.
  `adapter_from` evaluates the final adapter. These limits replace broad proposal
  statements above where the initial implementation is narrower.
- Training selects only public normalized data. Protected normalized evaluation
  requires an explicit flag and remains purpose-bound; no protected input was used
  in implementation. Source content is never shown to development agents.


### Evaluation resource instrumentation — 2026-11-02

Python title evaluation now records per-session phase wall/CPU time and process
peak RSS, attempt CPU consumption and retry-inclusive throughput. Aggregate metrics
flow through standalone reports and local MLflow. Resumed sessions retain costs;
missing token counts remain unmeasured. See the
[measurement semantics](../Developer/TitleEvaluation/README.md#resource-measurements).
GPU utilization, energy, FLOPs and scoring-process instrumentation remain outside
this implementation. No real model or private dataset was executed for this change.


## Small-model candidate research — 2026-11-02

See [the sourced candidate assessment](SMALL_TITLE_MODEL_RESEARCH.md) for the user’s
seven proposed models, additional small multilingual candidates and pinned
Python/Swift runtime constraints. The shortlist is a research recommendation; no
models, configurations or production settings were changed or evaluated.
