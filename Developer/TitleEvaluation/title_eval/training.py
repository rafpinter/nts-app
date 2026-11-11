"""Purpose-bound local supervised adapter training; no row-level diagnostics."""
from __future__ import annotations

import collections
import gzip
import hashlib
import heapq
import json
import math
import os
from pathlib import Path
import re
import subprocess
import sys
import time

from .execution import digest, messages_for, normalize_title, restricted_json, verify_local_model


def _records(paths):
    for path in paths:
        original = Path(path)
        if original.is_symlink():
            raise ValueError("training_symlinks_not_allowed")
        path = original.resolve()
        if "private" in path.parts[2:] or "obsidian" in str(path).lower() or path.is_symlink():
            raise ValueError("private_training_not_selected")
        opener = gzip.open if path.suffix == ".gz" else open
        try:
            with opener(path, "rt", encoding="utf-8") as stream:
                for line in stream:
                    if line.strip():
                        yield json.loads(line)
        except Exception:
            raise ValueError("training_input_invalid") from None


def _keys(row):
    if not isinstance(row.get("text"), str) or not row["text"].strip():
        raise ValueError("training_input_invalid")
    if not row.get("note_id") or not row.get("source_group"):
        raise ValueError("training_identity_required")
    return (row["note_id"], hashlib.sha256(row["text"].encode()).hexdigest(), row["source_group"])


def _write_rows(path, rows):
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as stream:
        for row in rows:
            stream.write(json.dumps(row, ensure_ascii=False) + "\n")



def prepare_source_splits(config: dict, output_dir: Path):
    """Stream mixed prepared public corpora into deterministic train/valid groups."""
    output_dir = Path(output_dir)
    sources = config.get("source_files", [])
    fraction = config.get("validation_fraction", 0.1)
    if not sources or not isinstance(fraction, (int, float)) or isinstance(fraction, bool) or not 0 < fraction < 1:
        raise ValueError("training_source_configuration_invalid")
    if config.get("train_files") or config.get("validation_files"):
        raise ValueError("training_source_modes_exclusive")
    hashes = {}
    for value in sources:
        original = Path(value)
        path = original.resolve()
        if original.is_symlink() or "private" in path.parts[2:] or "obsidian" in str(path).lower():
            raise ValueError("private_training_not_selected")
        with path.open("rb") as stream:
            hashes[str(path)] = hashlib.file_digest(stream, "sha256").hexdigest()
    if len(hashes) != len(sources):
        raise ValueError("training_duplicate_source_files")
    identity = digest({"sources": hashes, "seed": config.get("seed", 17), "validation_fraction": fraction})
    metadata_path = output_dir / "source-splits.json"
    paths = {"train": output_dir / "source-train.jsonl", "validation": output_dir / "source-validation.jsonl"}
    if metadata_path.exists():
        metadata = json.loads(metadata_path.read_text())
        if metadata.get("identity") != identity:
            raise ValueError("training_source_identity_changed")
        for name, path in paths.items():
            if hashlib.sha256(path.read_bytes()).hexdigest() != metadata["prepared_hashes"][name]:
                raise ValueError("training_source_splits_changed")
        effective = dict(config, train_files=[str(paths["train"])], validation_files=[str(paths["validation"])])
        effective.pop("source_files", None)
        return effective, metadata
    counts = collections.Counter()
    memberships = {"train": (set(), set(), set()), "nontrain": (set(), set(), set())}
    temporary = {name: path.with_suffix(".building") for name, path in paths.items()}
    handles = {}
    try:
        for name, path in temporary.items():
            fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            handles[name] = os.fdopen(fd, "w", encoding="utf-8")
        for row in _records(sources):
            split = row.get("split")
            if split not in {"train", "valid", "validation", "dev", "development", "test"}:
                raise ValueError("training_source_split_invalid")
            keys = _keys(row)
            kind = "train" if split == "train" else "nontrain"
            for known, key in zip(memberships[kind], keys):
                known.add(key)
            counts["source_records"] += 1
            if split != "train":
                counts["excluded_nontrain"] += 1
                continue
            bucket = int(digest([config.get("seed", 17), row["source_group"]])[:16], 16) / 2**64
            destination = "validation" if bucket < fraction else "train"
            row = dict(row, split="validation" if destination == "validation" else "train")
            handles[destination].write(json.dumps(row, ensure_ascii=False) + "\n")
            counts[destination] += 1
        if any(left & right for left, right in zip(memberships["train"], memberships["nontrain"])):
            raise ValueError("training_source_split_leakage")
        if not counts["train"] or not counts["validation"]:
            raise ValueError("training_source_split_empty")
        for stream in handles.values():
            stream.close()
        for name, path in paths.items():
            if path.exists():
                raise ValueError("orphaned_training_source_splits")
            temporary[name].replace(path)
        metadata = {"schema_version": 1, "identity": identity, "status": "complete", "source_hashes": hashes, "counts": dict(counts), "validation_fraction": fraction, "seed": config.get("seed", 17), "prepared_hashes": {name: hashlib.sha256(path.read_bytes()).hexdigest() for name, path in paths.items()}}
        restricted_json(metadata_path, metadata)
    finally:
        for stream in handles.values():
            if not stream.closed:
                stream.close()
        for path in temporary.values():
            path.unlink(missing_ok=True)
    effective = dict(config, train_files=[str(paths["train"])], validation_files=[str(paths["validation"])])
    effective.pop("source_files", None)
    return effective, metadata


def prepare_training(config: dict, prompt: dict, output_dir: Path):
    """Prepare explicit public split inputs. Never consumes private snapshots."""
    output_dir = Path(output_dir)
    output_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
    output_dir.chmod(0o700)
    requested_config = config
    source_splits = None
    if config.get("source_files"):
        config, source_splits = prepare_source_splits(config, output_dir)
    if not all(config.get(field) for field in ("train_files", "validation_files", "heldout_files")):
        raise ValueError("training_split_files_required")
    for name in ("train_files", "validation_files", "heldout_files"):
        if any(Path(p).is_symlink() for p in config[name]):
            raise ValueError("training_symlinks_not_allowed")
    files = {name: [Path(p).resolve() for p in config[name]] for name in ("train_files", "validation_files", "heldout_files")}
    if len(set(p for paths in files.values() for p in paths)) != sum(map(len, files.values())):
        raise ValueError("training_split_file_overlap")
    split_keys = {}
    chosen = {}
    counts = collections.Counter()
    source_counts = collections.Counter()
    input_hashes = {}
    for name, paths in files.items():
        # All input reading stays inside this process; only aggregate status escapes.
        for path in paths:
            if "private" in path.parts[2:] or "obsidian" in str(path).lower():
                raise ValueError("private_training_not_selected")
            with path.open("rb") as stream:
                input_hashes[str(path)] = hashlib.file_digest(stream, "sha256").hexdigest()
        identities, hashes, groups = set(), set(), set()
        eligible = collections.defaultdict(list)
        cap = config.get("max_train_records", 1200) if name == "train_files" else config.get("max_validation_records", 120)
        if not isinstance(cap, int) or isinstance(cap, bool) or cap < 1:
            raise ValueError("training_cap_invalid")
        for row in _records(paths):
            note_id, content_hash, group = _keys(row)
            if note_id in identities or content_hash in hashes:
                raise ValueError("duplicate_training_records")
            identities.add(note_id)
            hashes.add(content_hash)
            groups.add(group)
            counts[name + "_seen"] += 1
            if name == "heldout_files":
                continue
            allowed_splits = {"train"} if name == "train_files" else {"valid", "validation", "development", "dev"}
            if row.get("split") not in allowed_splits:
                raise ValueError("training_split_label_mismatch")
            refs = row.get("reference_titles", [])
            target = None
            for reference in refs:
                if not isinstance(reference, str):
                    continue
                try:
                    title, _ = normalize_title(reference)
                except ValueError:
                    continue
                # Exclude prompt-format artifacts and one-word proxy labels.
                if 2 <= len(reference.split()) <= 6 and not re.match(r"(?i)^(title|filename|título|titre):", reference.strip()) and not reference.lower().endswith(".md") and reference.strip()[:1] not in {'"', "'", '`'}:
                    target = reference.strip()
                    break
            if target is None:
                counts[name + "_ineligible_target"] += 1
                continue
            messages = messages_for(row["text"], prompt, {"max_input_characters": config.get("max_input_characters", 4000)})
            messages.append({"role": "assistant", "content": target})
            slice_key = (str(row.get("source", "unknown")), str(row.get("language", "unknown")))
            score = int(digest([config.get("seed", 17), note_id]), 16)
            entry = (-score, note_id, {"messages": messages})
            heap = eligible[slice_key]
            if len(heap) < cap:
                heapq.heappush(heap, entry)
            elif entry[:2] > heap[0][:2]:
                heapq.heapreplace(heap, entry)
        split_keys[name] = (identities, hashes, groups)
        cap = config.get("max_train_records", 1200) if name == "train_files" else config.get("max_validation_records", 120)
        if not isinstance(cap, int) or isinstance(cap, bool) or cap < 1:
            raise ValueError("training_cap_invalid")
        # Round-robin source/language slices avoids corpus-size dominance.
        selected = []
        queues = {key: collections.deque(row for _, _, row in sorted(values, key=lambda pair: (-pair[0], pair[1]))) for key, values in eligible.items()}
        while len(selected) < cap and any(queues.values()):
            for key in sorted(queues):
                if queues[key] and len(selected) < cap:
                    selected.append(queues[key].popleft())
                    source_counts[name + ":" + ":".join(key)] += 1
        chosen[name] = selected
    names = list(split_keys)
    for index, name in enumerate(names):
        for other in names[index + 1:]:
            if any(a & b for a, b in zip(split_keys[name], split_keys[other])):
                raise ValueError("training_split_leakage")
    if not chosen["train_files"] or not chosen["validation_files"]:
        raise ValueError("training_eligible_records_missing")
    identity = digest({"config": requested_config, "prompt": prompt, "input_hashes": input_hashes, "source_splits": source_splits})
    manifest_path = output_dir / "preparation.json"
    if manifest_path.exists():
        previous = json.loads(manifest_path.read_text())
        if previous.get("identity") != identity:
            raise ValueError("training_preparation_identity_mismatch")
        for name, expected in previous["prepared_hashes"].items():
            if hashlib.sha256((output_dir / "data" / name).read_bytes()).hexdigest() != expected:
                raise ValueError("training_preparation_changed")
        return previous
    data_dir = output_dir / "data"
    data_dir.mkdir(mode=0o700, exist_ok=True)
    for source, destination in (("train_files", "train.jsonl"), ("validation_files", "valid.jsonl")):
        _write_rows(data_dir / destination, chosen[source])
    prepared_hashes = {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in data_dir.glob("*.jsonl")}
    result = {"schema_version": 1, "identity": identity, "status": "prepared", "input_hashes": input_hashes, "prepared_hashes": prepared_hashes, "counts": dict(counts), "slice_counts": dict(source_counts), "train_records": len(chosen["train_files"]), "validation_records": len(chosen["validation_files"]), "loss": "assistant_title_only", "data_scope": "selected_public_only", "config": requested_config, "effective_config": config, "source_splits": source_splits, "prompt": prompt}
    restricted_json(manifest_path, result)
    return result


_ALLOWED = {"num_layers", "batch_size", "iters", "val_batches", "learning_rate", "steps_per_report", "steps_per_eval", "save_every", "max_seq_length", "grad_accumulation_steps", "lora_rank", "lora_scale", "lora_dropout", "grad_checkpoint", "gradient_checkpoint"}


def _training_options(config, local, output_dir):
    hyper = config.get("hyperparameters", {})
    if not hyper or set(hyper) - _ALLOWED:
        raise ValueError("training_hyperparameters_required_or_unknown")
    defaults = {"num_layers": 4, "batch_size": 1, "iters": 100, "val_batches": -1, "learning_rate": 1e-5, "steps_per_report": 10, "steps_per_eval": 25, "save_every": 25, "max_seq_length": 2048, "grad_accumulation_steps": 4, "lora_rank": 8, "lora_scale": 16.0, "lora_dropout": 0.0, "grad_checkpoint": True}
    defaults.update(hyper)
    if "gradient_checkpoint" in defaults:
        defaults["grad_checkpoint"] = defaults.pop("gradient_checkpoint")
    for key, value in defaults.items():
        if isinstance(value, bool):
            if key != "grad_checkpoint":
                raise ValueError("training_hyperparameter_invalid")
        elif not isinstance(value, (int, float)) or not math.isfinite(value) or (value <= 0 and key not in {"lora_dropout", "val_batches"}):
            raise ValueError("training_hyperparameter_invalid")
    if not 0 <= defaults["lora_dropout"] < 1 or defaults["val_batches"] == 0 or defaults["val_batches"] < -1:
        raise ValueError("training_hyperparameter_invalid")
    options = {"model": str(local), "train": True, "test": False, "fine_tune_type": "lora", "mask_prompt": True, "data": str(output_dir / "data"), "adapter_path": str(output_dir / "adapter"), "seed": config.get("seed", 17), "trust_remote_code": False, "report_to": None}
    options.update({key: value for key, value in defaults.items() if not key.startswith("lora_")})
    options["lora_parameters"] = {"rank": defaults["lora_rank"], "scale": defaults["lora_scale"], "dropout": defaults["lora_dropout"]}
    return options


def train(config: dict, output_dir: Path):
    """Train a local adapter in a child process with all library logs restricted."""
    output_dir = Path(output_dir).resolve()
    prepared = json.loads((output_dir / "preparation.json").read_text())
    if prepared["config"] != config:
        raise ValueError("training_configuration_changed")
    for name, checksum in prepared["prepared_hashes"].items():
        if hashlib.sha256((output_dir / "data" / name).read_bytes()).hexdigest() != checksum:
            raise ValueError("training_preparation_changed")
    local, model_hash = verify_local_model(config["model"])
    model_config = json.loads((local / "config.json").read_text())
    if not model_config.get("quantization") and not model_config.get("quantization_config"):
        raise ValueError("qlora_requires_quantized_base")
    options = _training_options(config, local, output_dir)
    identity = digest({"preparation": prepared["identity"], "model": model_hash, "options": options})
    result_path = output_dir / "training.json"
    if result_path.exists():
        previous = json.loads(result_path.read_text())
        if previous.get("identity") != identity or previous.get("status") != "complete":
            raise ValueError("training_run_exists_choose_new_output")
        adapter = output_dir / "adapter"
        files = {str(p.relative_to(adapter)): hashlib.sha256(p.read_bytes()).hexdigest() for p in adapter.rglob("*") if p.is_file() and p.name != "lineage.json"}
        if not files or digest(files) != previous.get("adapter_hash"):
            raise ValueError("training_adapter_changed")
        return previous
    restricted_json(output_dir / "trainer-config.json", options)
    started = time.perf_counter()
    result = {"schema_version": 1, "identity": identity, "status": "running", "base_model_id": config["model"]["model_id"], "base_revision": config["model"]["revision"], "model_snapshot_hash": model_hash, "preparation_hash": prepared["identity"], "training_options": options, "error_code": None}
    restricted_json(result_path, result)
    env = dict(os.environ, HF_HUB_OFFLINE="1", TRANSFORMERS_OFFLINE="1", HF_HUB_DISABLE_TELEMETRY="1", MLFLOW_ENABLE_SYSTEM_METRICS_LOGGING="false", MLFLOW_DISABLE_TELEMETRY="true", WANDB_DISABLED="true")
    env["PYTHONPATH"] = str(Path(__file__).resolve().parents[1]) + os.pathsep + env.get("PYTHONPATH", "")
    fd = os.open(output_dir / "protected-training.log", os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with os.fdopen(fd, "w") as protected:
            completed = subprocess.run([sys.executable, "-m", "title_eval.training", "--worker", str(output_dir / "trainer-config.json")], stdout=protected, stderr=subprocess.STDOUT, env=env, timeout=config.get("timeout_seconds", 3600), check=False)
        adapter = output_dir / "adapter"
        if completed.returncode != 0 or not (adapter / "adapters.safetensors").is_file():
            result.update(status="failed", error_code="training_process_failed")
        else:
            result["status"] = "complete"
            result["adapter_hash"] = digest({str(p.relative_to(adapter)): hashlib.sha256(p.read_bytes()).hexdigest() for p in adapter.rglob("*") if p.is_file()})
            summary_path = output_dir / "worker-summary.json"
            if summary_path.exists():
                result.update(json.loads(summary_path.read_text()))
            curves_path = output_dir / "curves.jsonl"
            if curves_path.exists():
                result["curves"] = [json.loads(line) for line in curves_path.read_text().splitlines() if line.strip()]
            result["duration_seconds"] = time.perf_counter() - started
            restricted_json(adapter / "lineage.json", result)
    except subprocess.TimeoutExpired:
        result.update(status="failed", error_code="training_timeout")
    except Exception:
        result.update(status="failed", error_code="training_process_failed")
    result["duration_seconds"] = time.perf_counter() - started
    restricted_json(result_path, result)
    return result


def _worker(config_path):
    """Check length and fix no-thinking template before MLX's trainer loads it."""
    import types
    import resource
    import mlx.core as mx
    import numpy as np
    import mlx_lm.lora as lora
    from mlx_lm import load
    from mlx_lm.tuner.datasets import load_dataset
    from transformers import AutoTokenizer
    config = json.loads(Path(config_path).read_text())
    if "mask_prompt" not in lora.CONFIG_DEFAULTS:
        raise ValueError("assistant_only_loss_unavailable")
    tokenizer = AutoTokenizer.from_pretrained(config["model"], trust_remote_code=False, local_files_only=True)
    if not isinstance(tokenizer.chat_template, str):
        raise ValueError("single_chat_template_required")
    tokenizer.chat_template = "{% set enable_thinking = false %}" + tokenizer.chat_template
    for name in ("train.jsonl", "valid.jsonl"):
        for line in (Path(config["data"]) / name).read_text().splitlines():
            row = json.loads(line)
            tokens = tokenizer.apply_chat_template(row["messages"], tokenize=True)
            if len(tokens) > config["max_seq_length"]:
                raise ValueError("training_sequence_exceeds_cap")
    effective = dict(lora.CONFIG_DEFAULTS)
    effective.update(config)
    args = types.SimpleNamespace(**effective)
    mx.random.seed(args.seed)
    np.random.seed(args.seed)
    model, _ = load(args.model, tokenizer_config={"trust_remote_code": False})
    train_set, valid_set, _ = load_dataset(args, tokenizer)
    curves_path = Path(config_path).parent / "curves.jsonl"
    class NumericCallback:
        def _record(self, kind, values):
            allowed = {"iteration", "train_loss", "val_loss", "val_time", "learning_rate", "iterations_per_second", "tokens_per_second", "trained_tokens", "peak_memory"}
            row = {key: float(value) for key, value in values.items() if key in allowed and isinstance(value, (int, float)) and math.isfinite(value)}
            row["kind"] = kind
            fd = os.open(curves_path, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
            with os.fdopen(fd, "a") as stream:
                stream.write(json.dumps(row, sort_keys=True) + "\n")
        def on_train_loss_report(self, values):
            self._record("train", values)
        def on_val_loss_report(self, values):
            self._record("validation", values)
        def on_train_end(self, *args, **kwargs):
            pass
    # lora.run in 0.31.1 enables remote tokenizer code; invoke the lower-level
    # trainer with our safe local model and exact no-thinking tokenizer instead.
    lora.train_model(args, model, train_set, valid_set, NumericCallback())
    rss = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
    restricted_json(Path(config_path).parent / "worker-summary.json", {"process_peak_rss_bytes": int(rss if sys.platform == "darwin" else rss * 1024), "mlx_peak_bytes": int(mx.get_peak_memory()), "chat_template_hash": hashlib.sha256(tokenizer.chat_template.encode()).hexdigest()})


if __name__ == "__main__":
    if len(sys.argv) == 3 and sys.argv[1] == "--worker":
        _worker(sys.argv[2])
    else:
        raise SystemExit("Use the benchmark CLI")
