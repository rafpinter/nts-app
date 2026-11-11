"""Optional local MLflow adapter. Only allowlisted configuration and aggregate metrics."""
from __future__ import annotations

import contextlib
import hashlib
import ipaddress
import json
import math
import os
from pathlib import Path
import re
import tempfile
from urllib.parse import urlsplit

from .scoring import _number


def validate_tracking_uri(uri: str) -> str:
    if not isinstance(uri, str):
        raise ValueError("invalid_tracking_uri")
    if uri.startswith("sqlite:///"):
        database = uri[len("sqlite:///"):]
        if not database or "?" in database or "#" in database or database == ":memory:":
            raise ValueError("tracking_requires_persistent_local_database")
        return uri
    parsed = urlsplit(uri)
    if parsed.scheme not in ("http", "https") or parsed.username or parsed.password or parsed.query or parsed.fragment:
        raise ValueError("tracking_requires_local_sqlite_or_loopback_server")
    host = parsed.hostname
    if host != "localhost":
        try:
            if not ipaddress.ip_address(host).is_loopback:
                raise ValueError
        except (ValueError, TypeError):
            raise ValueError("tracking_requires_local_sqlite_or_loopback_server") from None
    if parsed.path not in ("", "/"):
        raise ValueError("tracking_server_path_not_supported")
    return uri


def _local_artifact_uri(value):
    parsed = urlsplit(value)
    if parsed.scheme in ("", "file") and parsed.netloc in ("", "localhost"):
        return True
    # MLflow's proxy artifact scheme uses the explicitly loopback tracking server.
    return parsed.scheme == "mlflow-artifacts" and not parsed.netloc


def track_runs(run_dirs: list[Path], tracking_config: dict) -> dict:
    if not tracking_config.get("enabled", False):
        return {"status": "disabled", "logged": 0, "skipped": 0}
    uri = validate_tracking_uri(tracking_config.get("uri", ""))
    experiment_name = tracking_config.get("experiment_name", "title-generation")
    if not isinstance(experiment_name, str) or not experiment_name.strip():
        raise ValueError("invalid_mlflow_experiment_name")
    os.environ.update(MLFLOW_DISABLE_TELEMETRY="true", DO_NOT_TRACK="true", HF_HUB_DISABLE_TELEMETRY="1")
    items = []
    for directory in map(Path, run_dirs):
        try:
            manifest = json.loads((directory / "manifest.json").read_text())
            summary = json.loads((directory / "summary.json").read_text())
            if summary["run_id"] != manifest["run"]["id"]:
                raise ValueError
            if summary.get("prediction_hash") and hashlib.sha256((directory / "attempts.jsonl").read_bytes()).hexdigest() != summary["prediction_hash"]:
                raise ValueError
            items.append((manifest, summary))
        except Exception:
            raise ValueError("tracking_requires_current_scored_run") from None
    logged, skipped = 0, 0
    try:
        with open(os.devnull, "w") as sink, contextlib.redirect_stdout(sink), contextlib.redirect_stderr(sink):
            from mlflow import MlflowClient
            client = MlflowClient(tracking_uri=uri)
            experiment = client.get_experiment_by_name(experiment_name)
            if experiment is None:
                root = tracking_config.get("artifact_root")
                if root:
                    root_path = Path(root).expanduser().resolve()
                elif uri.startswith("sqlite:///"):
                    root_path = Path(uri[len("sqlite:///"):]).expanduser().resolve().parent / "mlflow-artifacts"
                else:
                    raise ValueError("loopback_tracking_requires_explicit_local_artifact_root")
                root_path.mkdir(parents=True, exist_ok=True)
                experiment_id = client.create_experiment(experiment_name, artifact_location=root_path.as_uri())
                experiment = client.get_experiment(experiment_id)
            if not _local_artifact_uri(experiment.artifact_location):
                raise ValueError("remote_artifact_storage_prohibited")
            for manifest, summary in items:
                run = manifest["run"]
                identity = hashlib.sha256(json.dumps({"run_id": run["id"], "scoring_hash": summary.get("scoring_hash"),
                                                     "prediction_hash": summary.get("prediction_hash"), "summary": summary}, sort_keys=True).encode()).hexdigest()
                existing = client.search_runs([experiment.experiment_id], filter_string=f"tags.title_eval_identity = '{identity}'", max_results=1)
                if existing and existing[0].info.status == "FINISHED":
                    skipped += 1
                    continue
                tags = {"title_eval_identity": identity, "title_eval_run_id": str(run["id"]),
                        "dataset_hash": str(manifest.get("dataset_hash", "unknown")), "stage": "evaluation",
                        "scoring_hash": str(summary.get("scoring_hash", "unknown")), "backend": manifest.get("backend", "unknown"),
                        "source_status": summary.get("status", "unknown"), "privacy": "aggregate_only"}
                result = client.create_run(experiment.experiment_id, tags=tags, run_name=run.get("name", run["id"]))
                run_id = result.info.run_id
                try:
                    params = {"backend": manifest.get("backend", "unknown"), "seed": run.get("seed"), "model": run.get("model", {}).get("model_id"),
                              "model_name": run.get("model", {}).get("name"), "revision": run.get("model", {}).get("revision"),
                              "fine_tuned": bool(run.get("model", {}).get("adapter") or run.get("model", {}).get("adapter_from")),
                              "adapter_sha256": manifest.get("adapter_hash"), "prompt_hash": manifest.get("prompt_hash")}
                    for key, value in run.get("generation", {}).items():
                        if key in {"temperature", "top_p", "top_k", "max_output_tokens", "max_input_characters", "max_attempts", "enable_thinking"}:
                            params[key] = value
                    for key, value in params.items():
                        client.log_param(run_id, key, "null" if value is None else str(value))
                    for key, value in summary.get("metrics", {}).items():
                        if _number(value):
                            client.log_metric(run_id, key, value)
                    client.log_metric(run_id, "expected_notes", summary["expected_notes"])
                    client.log_metric(run_id, "completed_notes", summary["completed_notes"])
                    for index, section in enumerate(summary.get("slices", [])):
                        for key, value in section.get("metrics", {}).items():
                            if _number(value):
                                client.log_metric(run_id, f"slice_{index}.{key}", value)
                    # No attempt rows, references, prompts, model output, or dataset paths.
                    public_artifact = {"schema_version": 1, "run_id": run["id"], "parameters": params,
                                       "status": summary.get("status"), "metrics": summary.get("metrics", {}),
                                       "slices": summary.get("slices", []), "coverage": summary.get("coverage", {}),
                                       "limitations": summary.get("limitations", [])}
                    with tempfile.TemporaryDirectory(prefix="title-eval-tracking-") as temp:
                        artifact = Path(temp) / "aggregate.json"
                        artifact.write_text(json.dumps(public_artifact, sort_keys=True, allow_nan=False))
                        client.log_artifact(run_id, str(artifact))
                    client.set_terminated(run_id, status="FINISHED")
                    logged += 1
                except Exception:
                    client.set_terminated(run_id, status="FAILED")
                    raise
    except ImportError:
        raise ValueError("mlflow_not_installed") from None
    except Exception:
        raise ValueError("local_mlflow_tracking_failed") from None
    return {"status": "complete", "logged": logged, "skipped": skipped}


def track_training(training_dirs: list[Path], tracking_config: dict) -> dict:
    """Track only numeric learning curves and allowlisted adapter/base lineage."""
    if not tracking_config.get("enabled", False):
        return {"status": "disabled", "logged": 0, "skipped": 0}
    uri = validate_tracking_uri(tracking_config.get("uri", ""))
    os.environ.update(MLFLOW_DISABLE_TELEMETRY="true", DO_NOT_TRACK="true")
    numeric_options = {"num_layers", "batch_size", "iters", "val_batches", "learning_rate", "steps_per_report",
                       "steps_per_eval", "save_every", "max_seq_length", "grad_accumulation_steps", "lora_rank",
                       "lora_scale", "lora_dropout", "grad_checkpoint", "gradient_checkpoint", "seed"}
    curve_keys = {"train_loss", "val_loss", "val_time", "learning_rate", "iterations_per_second", "tokens_per_second", "trained_tokens", "peak_memory"}
    items = []
    for directory in map(Path, training_dirs):
        try:
            raw = json.loads((directory/"training.json").read_text())
            if not raw.get("identity") or raw.get("status") not in {"complete", "failed", "running"}:
                raise ValueError
            params = {key: value for key, value in raw.get("training_options", {}).items()
                      if key in numeric_options and (_number(value) or isinstance(value, bool))}
            for key in ("base_model_id", "base_revision", "model_snapshot_hash", "preparation_hash", "adapter_hash"):
                if raw.get(key) is not None:
                    params[key] = str(raw[key])
            curves = []
            for index, point in enumerate(raw.get("curves", [])):
                step = point.get("iteration", index)
                if not _number(step) or step < 0:
                    raise ValueError
                curves.append({"step": int(step), **{key: val for key, val in point.items() if key in curve_keys and _number(val)}})
            metrics = {key: raw[key] for key in ("duration_seconds", "process_peak_rss_bytes", "mlx_peak_bytes") if _number(raw.get(key))}
            items.append({"identity": raw["identity"], "status": raw["status"], "parameters": params, "metrics": metrics, "curves": curves})
        except Exception:
            raise ValueError("invalid_training_tracking_artifact") from None
    logged = skipped = 0
    try:
        with open(os.devnull, "w") as sink, contextlib.redirect_stdout(sink), contextlib.redirect_stderr(sink):
            from mlflow import MlflowClient
            client = MlflowClient(tracking_uri=uri)
            name = tracking_config.get("experiment_name", "title-generation")
            experiment = client.get_experiment_by_name(name)
            if experiment is None:
                root = tracking_config.get("artifact_root")
                if root:
                    root_path = Path(root).expanduser().resolve()
                elif uri.startswith("sqlite:///"):
                    root_path = Path(uri[len("sqlite:///"):]).expanduser().resolve().parent/"mlflow-artifacts"
                else:
                    raise ValueError
                root_path.mkdir(parents=True, exist_ok=True)
                eid = client.create_experiment(name, artifact_location=root_path.as_uri())
                experiment = client.get_experiment(eid)
            if not _local_artifact_uri(experiment.artifact_location):
                raise ValueError
            for item in items:
                identity = hashlib.sha256(json.dumps(item, sort_keys=True).encode()).hexdigest()
                existing = client.search_runs([experiment.experiment_id], filter_string=f"tags.title_eval_identity = '{identity}'", max_results=1)
                terminal_status = "FINISHED" if item["status"] == "complete" else "FAILED" if item["status"] == "failed" else "KILLED"
                if existing and existing[0].info.status == terminal_status:
                    skipped += 1
                    continue
                result = client.create_run(experiment.experiment_id, tags={"title_eval_identity": identity, "stage": "training",
                                           "training_identity": item["identity"], "source_status": item["status"], "privacy": "aggregate_only"},
                                           run_name="qwen-training-"+item["identity"][:12])
                rid = result.info.run_id
                try:
                    for key, value in item["parameters"].items():
                        client.log_param(rid, key, str(value))
                    for key, value in item["metrics"].items():
                        client.log_metric(rid, key, value)
                    for point in item["curves"]:
                        for key, value in point.items():
                            if key != "step":
                                client.log_metric(rid, key, value, step=point["step"])
                    with tempfile.TemporaryDirectory(prefix="title-eval-training-tracking-") as temp:
                        artifact = Path(temp)/"training-aggregate.json"
                        artifact.write_text(json.dumps(item, sort_keys=True, allow_nan=False))
                        client.log_artifact(rid, str(artifact))
                    client.set_terminated(rid, status=terminal_status)
                    logged += 1
                except Exception:
                    client.set_terminated(rid, status="FAILED")
                    raise
    except ImportError:
        raise ValueError("mlflow_not_installed") from None
    except Exception:
        raise ValueError("local_mlflow_training_tracking_failed") from None
    return {"status": "complete", "logged": logged, "skipped": skipped}
