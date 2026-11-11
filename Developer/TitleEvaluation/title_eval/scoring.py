"""Offline scoring of retained attempts. No row contents are printed or uploaded."""
from __future__ import annotations

import contextlib
import hashlib
import json
import math
import os
from pathlib import Path
import re
import statistics
import unicodedata
from collections import Counter, defaultdict

SCORER_VERSION = "title-panel-v2"


def _digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, ensure_ascii=False).encode()).hexdigest()


def _write_json(path, value):
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(value, ensure_ascii=False, sort_keys=True, indent=2, allow_nan=False) + "\n")
    temporary.replace(path)


def words(text):
    """Version 1: Unicode letters/numbers, internal apostrophes, combining marks."""
    tokens, token = [], []
    for char in unicodedata.normalize("NFC", text):
        category = unicodedata.category(char)
        if category[0] in "LN" or (category[0] == "M" and token):
            token.append(char)
        elif char in "'’" and token:
            token.append(char)
        else:
            if token:
                tokens.append("".join(token).strip("'’"))
                token = []
    if token:
        tokens.append("".join(token).strip("'’"))
    return [token for token in tokens if token]


def prompt_compliant(raw):
    text = raw.strip()
    if not text or "\n" in text or "\r" in text:
        return False
    if re.match(r"(?i)^(title|filename|título|titre)\s*:", text):
        return False
    if text[0] in "\"'`#" or text[-1] in "\"'`" or text.lower().endswith(".md"):
        return False
    return 2 <= len(words(text)) <= 6


def percentile(values, quantile):
    if not values:
        return None
    ordered = sorted(values)
    index = (len(ordered) - 1) * quantile
    lower, upper = math.floor(index), math.ceil(index)
    return ordered[lower] + (ordered[upper] - ordered[lower]) * (index - lower)


def _number(value):
    return isinstance(value, (float, int)) and not isinstance(value, bool) and math.isfinite(value)


def _references(row):
    refs = row.get("reference_titles", [])
    return [x for x in refs if isinstance(x, str) and x.strip()] if isinstance(refs, list) else []


def _read_attempts(path):
    result, keys = [], set()
    if not path.exists():
        return result
    try:
        for line in path.read_text().splitlines():
            if not line.strip():
                continue
            row = json.loads(line)
            key = (row["note_id"], row["attempt"])
            if not isinstance(key[0], str) or type(key[1]) is not int or key[1] < 1 or key in keys:
                raise ValueError
            if type(row.get("accepted")) is not bool or type(row.get("terminal")) is not bool:
                raise ValueError
            keys.add(key)
            result.append(row)
    except Exception:
        raise ValueError("invalid_attempt_artifact") from None
    return result


def aggregate(rows, expected=None, attempts=None):
    expected = len(rows) if expected is None else expected
    successful = [r for r in rows if r["final_accepted"]]
    latencies = [r["latency_seconds"] for r in rows if _number(r.get("latency_seconds"))]
    accepted_titles = [r.get("_title", "") for r in successful]
    tokenized = [words(title.lower()) for title in accepted_titles]
    unigrams = [word for title in tokenized for word in title]
    bigrams = [pair for title in tokenized for pair in zip(title, title[1:])]
    names = [r.get("_filename", "") for r in successful]
    normalized_titles = [" ".join(words(t.lower())) for t in accepted_titles]
    score_rows = [r for r in successful if _number(r.get("bertscore_f1"))]
    denominator = expected or None
    def rate(count):
        return count / denominator if denominator else None
    def excess(values):
        return sum(count - 1 for count in Counter(values).values()) / len(values) if values else None
    metrics = {
        "first_attempt_acceptance": rate(sum(r["first_accepted"] for r in rows)),
        "final_acceptance": rate(len(successful)),
        "prompt_compliance": rate(sum(r["prompt_compliant"] for r in rows)),
        "completion_rate": rate(sum(r["completed"] for r in rows)),
        "retry_rate": rate(sum(r["attempts"] > 1 for r in rows)),
        "mean_attempts_observed": statistics.mean(r["attempts"] for r in rows) if rows else None,
        "mean_word_count_accepted": statistics.mean(r["word_count"] for r in successful) if successful else None,
        "latency_p50_seconds": percentile(latencies, .5),
        "latency_p95_seconds": percentile(latencies, .95),
        "distinct_1": len(set(unigrams)) / len(unigrams) if unigrams else None,
        "distinct_2": len(set(bigrams)) / len(bigrams) if bigrams else None,
        "duplicate_title_rate": excess(normalized_titles),
        "normalized_collision_rate": excess(names),
        "reference_coverage": rate(sum(r["reference_available"] for r in rows)),
        "bertscore_coverage": rate(len(score_rows)),
    }
    for metric in ("bertscore_p", "bertscore_r", "bertscore_f1"):
        values = [r[metric] for r in score_rows if _number(r.get(metric))]
        metrics[metric + "_mean"] = statistics.mean(values) if values else None
    for field in ("process_peak_rss_bytes", "mlx_peak_bytes"):
        values = [a[field] for a in attempts or [] if _number(a.get(field))]
        metrics[field] = max(values) if values else None
    observed = attempts or []
    for field in ("cpu_user_seconds", "cpu_system_seconds", "cpu_seconds", "prompt_tokens", "generation_tokens", "latency_seconds"):
        values = [a[field] for a in observed if _number(a.get(field))]
        metrics[field + "_total"] = sum(values) if values and len(values) == len(observed) else None
    duration = metrics["latency_seconds_total"]
    cpu, tokens = metrics["cpu_seconds_total"], metrics["generation_tokens_total"]
    metrics["cpu_percent_one_core"] = 100 * cpu / duration if cpu is not None and duration else None
    metrics["generation_tokens_per_second"] = tokens / duration if tokens is not None and duration else None
    metrics["attempts_per_second"] = len(observed) / duration if duration else None
    return metrics


def _model_digest(path):
    digest = hashlib.sha256()
    for file in sorted(path.rglob("*")):
        if file.is_file():
            digest.update(str(file.relative_to(path)).encode())
            with file.open("rb") as stream:
                for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                    digest.update(chunk)
    return digest.hexdigest()


def _bertscore(rows, config):
    """Only explicitly provisioned local encoder directories; network disabled."""
    if not config.get("enabled", False):
        return {"status": "disabled", "scored": 0}
    if config.get("idf", False) or config.get("rescale_with_baseline", False):
        raise ValueError("bertscore_idf_and_rescaling_not_supported")
    path = Path(config.get("model_path", "")).expanduser()
    if not path.is_dir() or not config.get("model_sha256") or not config.get("num_layers"):
        raise ValueError("bertscore_requires_pinned_local_encoder_and_layer")
    if _model_digest(path) != config["model_sha256"]:
        raise ValueError("bertscore_encoder_digest_mismatch")
    selected = [r for r in rows if r["final_accepted"] and r["reference_available"]]
    if not selected:
        return {"status": "no_eligible_predictions", "scored": 0}
    os.environ.update(HF_HUB_OFFLINE="1", TRANSFORMERS_OFFLINE="1", HF_HUB_DISABLE_TELEMETRY="1")
    try:
        with open(os.devnull, "w") as sink, contextlib.redirect_stdout(sink), contextlib.redirect_stderr(sink):
            from bert_score import BERTScorer
            scorer = BERTScorer(model_type=str(path.resolve()), num_layers=config["num_layers"],
                                idf=False, rescale_with_baseline=False,
                                device=config.get("device", "cpu"), batch_size=config.get("batch_size", 16))
            precision, recall, f1 = scorer.score([r["_title"] for r in selected], [r["_references"] for r in selected])
            values = list(zip(precision.tolist(), recall.tolist(), f1.tolist()))
            score_hash = scorer.hash
        if len(values) != len(selected) or any(not all(_number(v) for v in vals) for vals in values):
            raise ValueError
        for row, vals in zip(selected, values):
            row.update(zip(("bertscore_p", "bertscore_r", "bertscore_f1"), vals))
        return {"status": "complete", "scored": len(selected), "hash": score_hash}
    except Exception:
        # Exception messages from tokenizers/models may embed original row text.
        return {"status": "failed", "scored": 0, "error_code": "bertscore_execution_failed"}


def score_run(run_dir: Path, scoring_config: dict | None = None) -> dict:
    run_dir = Path(run_dir)
    scoring_config = scoring_config or {}
    try:
        manifest = json.loads((run_dir / "manifest.json").read_text())
        run = manifest["run"]
        expected = manifest["expected_notes"]
        if type(expected) is not int or expected < 0:
            raise ValueError
    except Exception:
        raise ValueError("invalid_run_manifest") from None
    attempts = _read_attempts(run_dir / "attempts.jsonl")
    groups = defaultdict(list)
    for attempt in attempts:
        groups[attempt["note_id"]].append(attempt)
    if len(groups) > expected:
        raise ValueError("unexpected_prediction_count")
    rows = []
    for note_id, note_attempts in sorted(groups.items()):
        note_attempts.sort(key=lambda a: a["attempt"])
        if [a["attempt"] for a in note_attempts] != list(range(1, len(note_attempts) + 1)):
            raise ValueError("noncontiguous_attempts")
        if any(a["terminal"] for a in note_attempts[:-1]) or any(a["accepted"] for a in note_attempts[:-1]):
            raise ValueError("attempt_after_terminal")
        last = note_attempts[-1]
        completed = last["terminal"]
        if last["accepted"] and not completed:
            raise ValueError("accepted_without_terminal")
        title = last.get("title") or last.get("raw_output") or ""
        raw = last.get("raw_output") or ""
        if not isinstance(title, str) or not isinstance(raw, str):
            raise ValueError("invalid_title_type")
        latencies = [a.get("latency_seconds") for a in note_attempts]
        row = {
            "note_id": note_id, "seed": run.get("seed"),
            "source": last.get("source", "unknown"), "language": last.get("language", "unknown"),
            "source_group": last.get("source_group", note_id), "reference_type": last.get("reference_type", "unknown"),
            "completed": completed, "first_accepted": note_attempts[0]["accepted"],
            "final_accepted": completed and last["accepted"], "attempts": len(note_attempts),
            "latency_seconds": sum(latencies) if all(_number(v) and v >= 0 for v in latencies) else None,
            "word_count": len(words(title)), "prompt_compliant": completed and last["accepted"] and prompt_compliant(raw),
            "reference_available": bool(_references(last)),
            "bertscore_p": None, "bertscore_r": None, "bertscore_f1": None,
            "error_code": last.get("error_code"), "_title": title,
            "_filename": last.get("normalized_filename", ""), "_references": _references(last),
        }
        rows.append(row)
    bert = _bertscore(rows, scoring_config.get("bertscore", {}))
    completed_count = sum(r["completed"] for r in rows)
    slices = []
    for source, language in sorted({(r["source"], r["language"]) for r in rows}):
        selected = [r for r in rows if r["source"] == source and r["language"] == language]
        slice_attempts = [a for a in attempts if a.get("source", "unknown") == source and a.get("language", "unknown") == language]
        slices.append({"source": source, "language": language, "notes": len(selected), "metrics": aggregate(selected, attempts=slice_attempts)})
    limits = ["Python measurements do not establish Swift app performance.",
              "BERTScore is reference similarity, not faithfulness or usefulness.",
              "Word compliance is mechanical; language agreement and usefulness require human review.",
              "Latency includes retries for observed notes; report missing-note coverage separately."]
    if completed_count != expected or manifest.get("status") != "complete":
        limits.append("Incomplete run: missing notes remain in acceptance denominators; slice denominators cover observed notes only.")
    summary = {
        "schema_version": 1, "run_id": run["id"], "run_name": run.get("name", run["id"]),
        "status": "complete" if completed_count == expected and manifest.get("status") == "complete" else "incomplete",
        "expected_notes": expected, "completed_notes": completed_count,
        "scoring_status": "failed" if bert.get("status") == "failed" else "complete",
        "dataset_hash": manifest.get("dataset_hash"), "scoring_hash": _digest({"version": SCORER_VERSION, "configuration": scoring_config}),
        "prediction_hash": hashlib.sha256((run_dir / "attempts.jsonl").read_bytes()).hexdigest() if (run_dir / "attempts.jsonl").exists() else None,
        "metrics": aggregate(rows, expected, attempts), "slices": slices,
        "coverage": {"observed_notes": len(rows), "missing_notes": expected - len(rows), "bertscore": bert,
                     "latency_notes": sum(_number(r.get("latency_seconds")) for r in rows)},
        "bootstrap": {"resamples": scoring_config.get("bootstrap_resamples", 10000), "seed": scoring_config.get("bootstrap_seed", 17)},
        "attempt_failure_reasons": dict(Counter(a.get("error_code") or "unknown" for a in attempts if not a["accepted"])),
        "failure_reasons": dict(Counter(r["error_code"] or "unknown" for r in rows if r["completed"] and not r["final_accepted"])),
        "limitations": limits,
    }
    for phase in ("load", "warmup", "evaluation", "total"):
        sessions = manifest.get("resource_sessions", [])
        values = [session.get("total", {}) if phase == "total" else session.get("phases", {}).get(phase, {}) for session in sessions]
        for field in ("wall_seconds", "cpu_seconds", "cpu_user_seconds", "cpu_system_seconds", "process_peak_rss_bytes"):
            measured = [v[field] for v in values if _number(v.get(field))]
            summary["metrics"][phase + "_" + field] = (max(measured) if field == "process_peak_rss_bytes" else sum(measured)) if measured and len(measured) == len(values) else None
    if slices:
        summary["macro_metrics"] = {key: statistics.mean(vals) if vals else None for key in summary["metrics"]
                                    for vals in [[s["metrics"].get(key) for s in slices if _number(s["metrics"].get(key))]]}
    safe_rows = [{k: v for k, v in r.items() if not k.startswith("_")} for r in rows]
    scores = run_dir / "scores.jsonl"
    temporary = scores.with_suffix(".jsonl.tmp")
    temporary.write_text("".join(json.dumps(r, ensure_ascii=False, sort_keys=True, allow_nan=False) + "\n" for r in safe_rows))
    temporary.replace(scores)
    summary["scores_hash"] = hashlib.sha256(scores.read_bytes()).hexdigest()
    _write_json(run_dir / "summary.json", summary)
    return summary
