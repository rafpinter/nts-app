"""Single-config orchestration with sequential, isolated, content-silent workers."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[3]
SOURCE = Path(__file__).resolve().parents[1]
DEFAULT_CONFIG = ROOT / "benchmarks/title_generation/experiments.yaml"


def _write(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    tmp = path.with_suffix(path.suffix + ".tmp")
    with os.fdopen(os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600), "w") as stream:
        json.dump(value, stream, sort_keys=True, indent=2, allow_nan=False)
        stream.write("\n")
    tmp.replace(path)
    path.chmod(0o600)


def _environment():
    env = dict(os.environ)
    env.update(PYTHONPATH=str(SOURCE), PYTHONDONTWRITEBYTECODE="1",
               HF_HUB_OFFLINE="1", TRANSFORMERS_OFFLINE="1",
               HF_HUB_DISABLE_TELEMETRY="1", MLFLOW_ENABLE_TELEMETRY="false",
               TOKENIZERS_PARALLELISM="false")
    return env


def _isolated(request, directory, timeout):
    directory = Path(directory)
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    request_path = directory / "request.json"
    _write(request_path, request)
    started = time.monotonic()
    # Third-party diagnostics can contain content. They are suppressed rather
    # than copied to console or tracking. The worker emits safe structured state.
    process = subprocess.Popen([sys.executable, "-m", "title_eval", "_worker", str(request_path)],
                               env=_environment(), stdout=subprocess.DEVNULL,
                               stderr=subprocess.DEVNULL, start_new_session=True)
    try:
        code = process.wait(timeout=timeout)
        status = "completed" if code == 0 else "failed"
    except subprocess.TimeoutExpired:
        import signal
        os.killpg(process.pid, signal.SIGKILL)
        process.wait()
        status = "timeout"
    except BaseException:
        import signal
        os.killpg(process.pid, signal.SIGKILL)
        process.wait()
        raise
    result = {"status": status, "elapsed_seconds": time.monotonic() - started}
    if status != "completed" and request["operation"] == "generate":
        manifest_path = directory / "manifest.json"
        try:
            manifest = json.loads(manifest_path.read_text())
        except Exception:
            manifest = {"schema_version": 1, "run": request["run"],
                        "expected_notes": request.get("expected_notes", 0), "completed_notes": 0,
                        "dataset_hash": request.get("dataset_hash")}
        manifest["status"] = status
        manifest["error_code"] = manifest.get("error_code") or "worker_" + status
        _write(manifest_path, manifest)
    _write(directory / (request["operation"] + "-status.json"), result)
    return result


def _worker(path):
    os.umask(0o077)
    request = json.loads(Path(path).read_text())
    operation = request["operation"]
    output = Path(request["output_dir"])
    try:
        error_path = output / (operation + "-error.json")
        if error_path.exists():
            error_path.unlink()
        if operation == "generate":
            from .datasets import load_dataset, synthetic_records
            from .execution import execute_run
            from .datasets import digest
            records = synthetic_records() if request.get("backend") == "synthetic" else load_dataset(request["dataset"])[0]
            if digest(records) != request.get("dataset_hash"):
                raise ValueError("dataset_changed_after_audit")
            result = execute_run(request["run"], records, output, request["prompt"],
                                 backend=request.get("backend", "mlx"), timeout_seconds=request.get("attempt_timeout_seconds", 120))
            if result.get("status") != "complete":
                return 1
        elif operation == "training":
            from .training import prepare_training, train
            prepare_training(request["training"], request["prompt"], output)
            if request.get("execute"):
                if train(request["training"], output).get("status") != "complete":
                    return 1
        elif operation == "score":
            from .scoring import score_run
            result = score_run(output, request.get("scoring", {}))
            if result.get("coverage", {}).get("bertscore", {}).get("status") == "failed":
                return 1
        else:
            raise ValueError("unknown_worker_operation")
        return 0
    except BaseException:
        # Never serialize str(exception), traceback, row IDs or contents.
        _write(output / (operation + "-error.json"), {"status": "failed", "error_code": operation + "_failed"})
        return 1


def _load(path):
    from .config import load_config, expand_runs
    from .production import production_configuration
    config = load_config(path)
    production = production_configuration(ROOT)
    runs = expand_runs(config)
    return config, production, runs


def _safe_output(path):
    path = Path(path).resolve()
    local = (ROOT / "benchmarks/title_generation").resolve()
    if local not in path.parents and path != local:
        # Temporary external directories are useful for verification. Never
        # publish generated artifacts into the tracked source tree.
        if path == ROOT or ROOT in path.parents:
            raise ValueError("output_must_be_outside_tracked_source")
    return path


def _audit(config, output):
    from .datasets import load_dataset
    _, audit = load_dataset(config["dataset"])
    _write(output / "audit.json", audit)
    return audit


def _run(config, production, runs, *, synthetic=False):
    output = _safe_output(config["output_dir"])
    if synthetic:
        from .datasets import digest, synthetic_records
        audit = {"records": len(synthetic_records()), "dataset_hash": digest(synthetic_records())}
    else:
        audit = _audit(config, output)
    maximum = config.get("limits", {}).get("max_attempts_total", 100000)
    if sum(r["generation"]["max_attempts"] for r in runs) * audit["records"] > maximum:
        raise ValueError("attempt_budget_exceeded")
    timeout = config.get("limits", {}).get("timeout_seconds", 3600)
    if not synthetic:
        for job in config.get("training", []):
            if not job.get("enabled", False):
                continue
            job = dict(job)
            # Evaluation and held-out snapshots are always audited against training.
            job["heldout_files"] = sorted(set(job.get("heldout_files", []) +
                [config["dataset"]["path"]] + config["dataset"].get("holdout_paths", [])))
            if isinstance(job.get("model"), str):
                job["model"] = next(m for m in config["models"] if m["name"] == job["model"])
            directory = output / "training" / job["name"]
            result = _isolated({"operation": "training", "training": job, "prompt": production["prompt"],
                                "output_dir": str(directory), "execute": True}, directory, job.get("timeout_seconds", timeout))
            if result["status"] != "completed":
                raise RuntimeError("training_worker_failed")
    outcomes = []
    for run in runs:
        run = dict(run)
        run["production_export_hash"] = production["fingerprint"]
        run["production_source_sha256"] = production["source_sha256"]
        run["dataset_hash"] = audit["dataset_hash"]
        run["implementation_hash"] = hashlib.sha256("".join(
            p.name + hashlib.sha256(p.read_bytes()).hexdigest()
            for p in sorted((SOURCE / "title_eval").glob("*.py"))).encode()).hexdigest()
        # Dataset and prompt changes get a distinct artifact directory even when
        # the selected model/sampling configuration retains its friendly name.
        identity = hashlib.sha256(json.dumps(run, sort_keys=True).encode()).hexdigest()[:16]
        run["id"] = identity
        directory = output / "runs" / identity
        request = {"operation": "generate", "run": run, "dataset": config["dataset"],
                   "dataset_hash": audit["dataset_hash"], "expected_notes": audit["records"],
                   "prompt": production["prompt"], "output_dir": str(directory),
                   "backend": "synthetic" if synthetic else "mlx",
                   "attempt_timeout_seconds": config.get("limits", {}).get("attempt_timeout_seconds", 120)}
        result = _isolated(request, directory, timeout)
        score_result = _isolated({"operation": "score", "output_dir": str(directory),
                                 "scoring": config.get("scoring", {})}, directory, timeout)
        outcomes.append({"run_id": identity, "status": result["status"], "scoring_status": score_result["status"]})
        print(json.dumps(outcomes[-1]), flush=True)
    _write(output / "campaign.json", {"schema_version": 1, "runs": outcomes,
           "synthetic": synthetic, "status": "completed" if all(
               r["status"] == r["scoring_status"] == "completed" for r in outcomes) else "incomplete"})
    return 0 if all(r["status"] == r["scoring_status"] == "completed" for r in outcomes) else 1


def main(argv=None):
    parser = argparse.ArgumentParser(description="Local title experiments from one YAML configuration")
    parser.add_argument("--config", type=Path, default=DEFAULT_CONFIG)
    sub = parser.add_subparsers(dest="command", required=True)
    init = sub.add_parser("init", help="Create the editable working YAML; never overwrite")
    init.add_argument("--destination", type=Path)
    sub.add_parser("dry-run", help="List configured runs without reading datasets or loading models")
    sub.add_parser("audit", help="Validate explicitly selected normalized data; print aggregate status only")
    sub.add_parser("run", help="Run enabled training and evaluations sequentially, score, report and track")
    sub.add_parser("score", help="Rescore retained predictions in isolated workers")
    sub.add_parser("report", help="Rebuild aggregate comparison HTML/CSV/JSON")
    sub.add_parser("track", help="Log aggregate results to local MLflow")
    encoder = sub.add_parser("encoder-digest", help="Fingerprint an explicitly selected local scoring encoder")
    encoder.add_argument("--path", type=Path, required=True)
    smoke = sub.add_parser("smoke", help="End-to-end synthetic-only verification; no models or datasets")
    smoke.add_argument("--output", type=Path, required=True)
    registration = sub.add_parser("register-model", help="Fingerprint a configured existing local model")
    registration.add_argument("--model", required=True)
    worker = sub.add_parser("_worker", help=argparse.SUPPRESS)
    worker.add_argument("request", type=Path)
    args = parser.parse_args(argv)
    os.umask(0o077)
    try:
        if args.command == "_worker":
            return _worker(args.request)
        if args.command == "init":
            target = args.destination or args.config
            target = _safe_output(target)
            target.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
            with target.open("x") as stream:
                stream.write((SOURCE / "experiments.example.yaml").read_text())
            print(json.dumps({"status": "created", "configuration": str(target)}))
            return 0
        if args.command == "encoder-digest":
            from .scoring import _model_digest
            if not args.path.is_dir():
                raise ValueError("local_encoder_directory_required")
            print(json.dumps({"model_sha256": _model_digest(args.path.resolve())}))
            return 0
        if args.command == "smoke":
            from .production import production_configuration
            production = production_configuration(ROOT)
            output = _safe_output(args.output)
            baseline = {"name": "qwen-baseline", "model_id": production["model"]["model_id"],
                        "revision": production["model"]["revision"], "role": "baseline"}
            runs = [{"id": "smoke", "name": "synthetic-control", "baseline": True,
                     "model": baseline, "generation": production["generation"], "seed": 17},
                    {"id": "smoke-alternate", "name": "synthetic-alternate", "baseline": False,
                     "model": baseline, "generation": dict(production["generation"], temperature=0.2), "seed": 17}]
            config = {"output_dir": str(output), "dataset": {}, "limits": {}, "scoring": {}}
            code = _run(config, production, runs, synthetic=True)
            from .reporting import build_report
            build_report(list((output / "runs").iterdir()), output / "report", baseline_name="qwen-baseline")
            print(json.dumps({"status": "passed" if code == 0 else "failed", "synthetic": True,
                              "report": str(output / "report/comparison.html")}))
            return code
        config, production, runs = _load(args.config)
        output = _safe_output(config["output_dir"])
        if args.command == "dry-run":
            # Configurations contain model IDs/settings only, never row contents.
            print(json.dumps({"runs": [{"id": r["id"], "name": r["name"], "model": r["model"]["name"],
                                        "generation": r["generation"], "seed": r["seed"]} for r in runs],
                              "training_jobs": sum(bool(j.get("enabled")) for j in config.get("training", [])),
                              "dataset_read": False}, indent=2))
            return 0
        if args.command == "audit":
            print(json.dumps(_audit(config, output)))
            return 0
        if args.command == "register-model":
            from .execution import register_model
            model = next(m for m in config["models"] if m["name"] == args.model)
            print(json.dumps(register_model(model["local_path"], model["model_id"], model["revision"])))
            return 0
        code = 0
        if args.command == "run":
            code = _run(config, production, runs)
        directories = sorted(p for p in (output / "runs").glob("*") if p.is_dir())
        if not directories:
            raise ValueError("no_saved_runs")
        if args.command == "score":
            for directory in directories:
                result = _isolated({"operation": "score", "output_dir": str(directory),
                                    "scoring": config.get("scoring", {})}, directory,
                                   config.get("limits", {}).get("timeout_seconds", 3600))
                if result["status"] != "completed":
                    code = 1
        if args.command in {"run", "score", "report"}:
            from .reporting import build_report
            build_report(directories, output / "report", baseline_name=next(
                (m["name"] for m in config["models"] if m.get("role") == "baseline"), None))
        if args.command == "track" and not config.get("tracking", {}).get("enabled"):
            raise ValueError("enable_tracking_in_configuration")
        if args.command == "track" or (args.command == "run" and config.get("tracking", {}).get("enabled")):
            from .tracking import track_runs, track_training
            track_training(sorted((output / "training").glob("*")), config["tracking"])
            track_runs(directories, config["tracking"])
        print(json.dumps({"status": "completed" if code == 0 else "incomplete"}))
        return code
    except Exception as error:
        # Only our validation messages and allowlisted codes can be printed.
        from .config import ConfigurationError
        from .datasets import DatasetError
        safe_codes = {"output_must_be_outside_tracked_source", "attempt_budget_exceeded",
                      "training_worker_failed", "no_saved_runs", "enable_tracking_in_configuration",
                      "local_encoder_directory_required", "model_registration_conflict", "invalid_model_registration"}
        code = str(error) if isinstance(error, (ConfigurationError, DatasetError)) or str(error) in safe_codes else "command_failed"
        print(json.dumps({"status": "failed", "error_code": code,
                          "help": "Check configuration and aggregate error/status artifacts; raw exception text is suppressed."}), file=sys.stderr)
        return 1
