# Small models for local note-title generation

Research date: **2026-11-02**. This is a candidate assessment, not measured title
quality or authorization to download, run, fine-tune or replace a model.

The task is a faithful, natural **2–6-word title in the note's language**, including
English and Portuguese, from up to 4,000 input characters. The deployment target
is a native app on 8–16 GB Apple Silicon. Short-output reliability and total
resource cost matter more here than coding/math leaderboard positions.

## Recommendation

Start with the unchanged Qwen3-0.6B 4-bit production baseline, then compare
**Qwen2.5-1.5B-Instruct** and **Qwen3-1.7B with thinking disabled**. These are the
lowest integration-risk additions identified from model documentation and the
pinned native model registry. Include **Gemma 3 1B IT** for a small different-family
candidate after checking its selected tokenizer/template. Investigate
**Qwen3.5-0.8B and 2B** in Python as a second group: the pinned Python library has
architecture code, but the shipping Swift registry does not. This ordering is my
engineering recommendation, not an observed quality ranking.

## User-selected additions — 2026-11-02

Add **SmolLM2-1.7B-Instruct** and **Gemma 3 270M IT** to the comparison list.
The earlier research omitted [Gemma 3 270M IT](https://huggingface.co/google/gemma-3-270m-it):
it is smaller than the suggested 1B checkpoint and supplies the requested minimum
Gemma size. Its `gemma3_text` architecture is present in the pinned runtimes;
actual loading, tokenizer behavior and title quality remain unverified.

Both the tracked experiment template and working YAML now contain disabled,
immutable candidate entries, included in the disabled `shared-control` profile:

| Configuration name | Selected artifact | Revision | Quantization |
| --- | --- | --- | --- |
| `smollm2-1.7b` | [HuggingFaceTB/SmolLM2-1.7B-Instruct-Q8-mlx](https://huggingface.co/HuggingFaceTB/SmolLM2-1.7B-Instruct-Q8-mlx) | `2bb0b4cebf6f2e93b23779a44f8b93e185609046` | 8-bit |
| `gemma3-270m` | [mlx-community/gemma-3-270m-it-4bit](https://huggingface.co/mlx-community/gemma-3-270m-it-4bit) | `ff1143e3a10547c9f2129e94ca37059b096b23f4` | 4-bit |

The SmolLM conversion is published by the upstream model organization. Its 8-bit
cost must remain explicit in comparisons with 4-bit candidates. Revision IDs were
read from public repository metadata; no weights were fetched. This adds two
candidates without implementing the other proposed shortlist entries or changing
the production anchor. Enable each selected model and `shared-control` only after
local provisioning and snapshot registration. Existing research recommendations
below are preserved as the earlier assessment, not the selected configuration.

## Assessment of the supplied list

| Candidate and verified identity | Evidence and fit | Recommendation |
| --- | --- | --- |
| [google/gemma-4-E2B-it](https://huggingface.co/google/gemma-4-E2B-it) | Use the instruction-tuned `-it` variant. Apache-2.0; multilingual family with 140+ languages. E2B means 2.3B effective parameters, **5.1B including embeddings**, with separate modality encoders listed. 128K context. | Interesting later candidate. Do not budget it like a dense 2B model. The pinned Python models directory and Swift LLM registry lack Gemma 4; a runtime change must be scoped and verified separately. |
| [nvidia/AceInstruct-1.5B](https://huggingface.co/nvidia/AceInstruct-1.5B) | Qwen2.5-base instruction fine-tune for general tasks, coding and math. Card tags English and lists **CC-BY-NC-4.0**. Its reported general benchmarks do not establish multilingual title quality. | Optional noncommercial research comparator; deprioritize for a potentially distributed commercial app. Compare against original Qwen2.5-Instruct before assuming this fine-tune helps. |
| [microsoft/phi-2](https://huggingface.co/microsoft/phi-2) | 2.7B, MIT, English, 2,048-token context. Pretrained completion model, rather than the modern instruction-chat variant suited to this interface. The card says it has no RLHF. | Low priority for this multilingual instruction task. Architecture support alone is insufficient: current evaluator requires a usable chat template, which must be checked or explicitly adapted. Tokenize the complete prompt before assessing context fit. |
| [Qwen/Qwen2.5-1.5B-Instruct](https://huggingface.co/Qwen/Qwen2.5-1.5B-Instruct) | Prefer `-Instruct` over the supplied base-model ID. 1.54B, Apache-2.0; 29+ languages explicitly including Portuguese; this checkpoint has 32,768-token context. | First-wave candidate. Qwen2 architecture exists in both pinned runtimes; the native registry explicitly lists an MLX 4-bit conversion. Actual snapshot/tokenizer/load verification is still required. |
| [HuggingFaceTB/SmolLM2-1.7B-Instruct](https://huggingface.co/HuggingFaceTB/SmolLM2-1.7B-Instruct) | Prefer `-Instruct`. Apache-2.0, decoder model using the Llama architecture. Its limitations explicitly say it primarily understands/generates English. | Useful English-focused comparator; less compelling as the main Portuguese/English candidate. Evaluate Portuguese separately rather than assuming English results transfer. |
| [dphn/Dolphin3.0-Qwen2.5-0.5B](https://huggingface.co/dphn/Dolphin3.0-Qwen2.5-0.5B) | The supplied `cognitivecomputations` URL now redirects here. 0.5B Qwen2 fine-tune, Apache-2.0, ChatML. Card tags English and leaves its evaluation section as TBD. | Optional tiny-model experiment. No supplied evidence of better titles or Portuguese performance. Pair it with original Qwen2.5-0.5B-Instruct to isolate the fine-tune's effect. |
| [google/flan-t5-large](https://huggingface.co/google/flan-t5-large) | Approximately 0.8B, Apache-2.0, instruction-tuned encoder–decoder; the card includes Portuguese. Its config is `T5ForConditionalGeneration`, and tokenizer metadata defaults to 512 tokens. | Legitimate small text-to-text baseline, but **requires a separate seq2seq backend**. It cannot be added to the current MLX chat worker by editing YAML alone. A 512-token input experiment would need an explicit, separately reported input policy. |

The license labels above are those published on the linked checkpoints. Preserve
source and conversion provenance; do not assume a quantized derivative removes
the original terms. General benchmark claims have not been used as title-quality
measurements.

## Additional candidates worth considering

| Model | Why it is worth a slot | Limit or dependency |
| --- | --- | --- |
| [Qwen/Qwen3-1.7B](https://huggingface.co/Qwen/Qwen3-1.7B) | Apache-2.0; multilingual instruction model with 100+ languages/dialects. Closest larger same-family comparison with the existing 0.6B baseline. | Disable thinking through the actual chat template, keep the title token cap, and verify no reasoning tags leak into output. Native registry lists the 4-bit conversion. |
| [Qwen/Qwen3.5-0.8B](https://huggingface.co/Qwen/Qwen3.5-0.8B) | Apache-2.0; attractive size for testing a newer small architecture. Card says non-thinking is the default. | Python architecture exists at our pin; native registry lacks it. Verify local text loading, tokenizer and quantization. Author warnings about thinking loops reinforce keeping thinking off for this task. |
| [Qwen/Qwen3.5-2B](https://huggingface.co/Qwen/Qwen3.5-2B) | Apache-2.0; a larger comparison from the same newer family, whose card reports 201 languages/dialects. | Same runtime boundary as 0.8B; model includes vision components, so select and record the exact text-serving artifact. Do not infer title quality from the family benchmark table. |
| [google/gemma-3-1b-it](https://huggingface.co/google/gemma-3-1b-it) | Small different-family instruction candidate, multilingual family training, 32K context for the 1B checkpoint. Native registry lists a QAT 4-bit conversion. | Gemma terms, rather than Apache-2.0. Verify system-message handling, tokenizer, stop tokens and the exact converted artifact. QAT is a distinct artifact, not an interchangeable quantization setting. |
| [meta-llama/Llama-3.2-1B-Instruct](https://huggingface.co/meta-llama/Llama-3.2-1B-Instruct) | Officially supports Portuguese and English; nominal 1B model is 1.23B. Native registry lists a 4-bit conversion. | Custom Llama 3.2 license. Optional alternative if another small family is desired; no measured reason yet to prefer it over the first wave. |
| [HuggingFaceTB/SmolLM3-3B](https://huggingface.co/HuggingFaceTB/SmolLM3-3B) | Apache-2.0; six primary languages explicitly include Portuguese. Thinking can be disabled. More relevant multilingual design than SmolLM2. | Larger cost class. Swift registry has `smollm3`; Python pin/snapshot/tokenizer compatibility remains to be verified. This is its own architecture, not automatically interchangeable with Llama weights. |

## Runtime evidence and actual integration gates

The repository pins Python **MLX-LM 0.31.1** and native **mlx-swift-lm 2.29.3**
at commit `5064b8c5d8ed3b0bbb71385c4124f0fc102e74a2`. They are separate runtimes.

- The [pinned Python models directory](https://github.com/ml-explore/mlx-lm/tree/v0.31.1/mlx_lm/models)
  contains Qwen2, Qwen3, Phi, Llama and Gemma3 code, but no Gemma4 module in the
  inspected listing. Its [Qwen3.5 implementation](https://github.com/ml-explore/mlx-lm/blob/v0.31.1/mlx_lm/models/qwen3_5.py)
  includes text execution and removal of vision weights during sanitization.
- The [pinned Swift factory](https://github.com/ml-explore/mlx-swift-lm/blob/5064b8c5d8ed3b0bbb71385c4124f0fc102e74a2/Libraries/MLXLLM/LLMModelFactory.swift)
  registers Qwen2/Qwen3, Phi, Llama, Gemma3 and SmolLM3. It does not register
  Qwen3.5, Gemma4 or T5. It explicitly names MLX conversions for Qwen2.5-1.5B,
  Qwen3-1.7B, Gemma3-1B QAT and Llama3.2-1B. These are source-level indications,
  not successful load tests.

The current Python worker loads a local model with remote code disabled, applies
`tokenizer.apply_chat_template` with system/user messages and `enable_thinking`,
and streams causal generation. It has no seq2seq branch or per-model prompt
formatter configuration. Validate the exact selected artifact's architecture,
tokenizer/template, accepted roles, thinking control, EOS/stop tokens and
quantization before scheduling experiments. Base checkpoints and multimodal
processors are not automatically compatible. Use immutable conversion revisions
and snapshot registration; upstream IDs in the tables are research references,
not ready-to-run MLX configuration entries.

## Resource budget and comparison protocol

For orientation only, ideal packed 4-bit weights cost **0.5 GB per billion
parameters**: 0.6B ≈ 0.30 GB; 1.5B ≈ 0.75 GB; 1.7B ≈ 0.85 GB; 2B ≈ 1 GB.
These are arithmetic estimates in decimal GB, **not model file sizes or RAM
predictions**. Scales, unquantized tensors, caches, activations, runtime, the app
and macOS add memory. Gemma E2B's embeddings illustrate why effective parameter
counts are insufficient for storage estimates. Training has a different budget.

A proposed first comparison is the existing Qwen3-0.6B baseline plus
Qwen2.5-1.5B-Instruct, Qwen3-1.7B, and Gemma3-1B IT. Screen original
Qwen2.5-0.5B-Instruct if minimum footprint matters; add Qwen3.5 after its Python
compatibility gate. Leave commercial-incompatible, English-focused and
backend-expansion candidates out of the initial matrix unless their specific
comparison is desired.

Keep the same model-visible note prefix, instruction meaning, development split,
seed schedule, output cap and shared sampling controls. Model-native chat
serialization is required and must be recorded. Separately label any sampling
optimization or formatter adaptation; do not silently alter the production anchor.
Vendor generic sampling recommendations are not measured title settings, and
some newer recommended penalties are not currently configurable in this runner.

Compare first-attempt acceptance, retry-inclusive success/time, p50/p95 latency,
peak RSS/MLX memory, CPU time and throughput, with source/language slices. Review
language agreement, unsupported details and title usefulness separately;
BERTScore does not establish these. Compare time per title as well as tokens/sec,
since tokenizers differ. Retain failed/OOM/timeout runs. Finalists need separate
native loading/performance and desktop checks before a production switch.

## Evidence limits

No weights, tokenizers, dependencies or datasets were downloaded; no inference,
training or private-content access occurred. Runtime conclusions are from pinned
source inspection. License/language/parameter statements come from linked author
model cards, supplemented by the original FLAN-T5
[architecture config](https://huggingface.co/google/flan-t5-large/blob/main/config.json)
and [tokenizer metadata](https://huggingface.co/google/flan-t5-large/blob/main/tokenizer_config.json).
Actual speed, memory, faithfulness and title quality remain unmeasured.
