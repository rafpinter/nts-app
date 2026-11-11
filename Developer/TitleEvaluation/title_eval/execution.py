"""Local-only generation. Content stays in restricted artifacts, never diagnostics."""
from __future__ import annotations

import contextlib
import hashlib
import importlib.metadata
import json
import os
from pathlib import Path
import platform
import re
import resource
import signal
import sys
import time
import unicodedata


def resource_snapshot():
    usage = resource.getrusage(resource.RUSAGE_SELF)
    return {"wall": time.perf_counter(), "user": usage.ru_utime, "system": usage.ru_stime,
            "rss": int(usage.ru_maxrss if sys.platform == "darwin" else usage.ru_maxrss * 1024)}


def resource_delta(start):
    end = resource_snapshot()
    wall = max(0.0, end["wall"] - start["wall"])
    user, system = max(0.0, end["user"] - start["user"]), max(0.0, end["system"] - start["system"])
    return {"wall_seconds": wall, "cpu_user_seconds": user, "cpu_system_seconds": system,
            "cpu_seconds": user + system,
            "cpu_percent_one_core": 100 * (user + system) / wall if wall else None,
            "process_peak_rss_bytes": end["rss"]}


def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, ensure_ascii=False, separators=(",", ":")).encode()).hexdigest()


def restricted_json(path: Path, value):
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    temporary = path.with_suffix(path.suffix + ".tmp")
    fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as stream:
        json.dump(value, stream, ensure_ascii=False, sort_keys=True, indent=2)
        stream.write("\n")
    temporary.replace(path)
    path.chmod(0o600)


def normalize_title(raw: str):
    """Port of app lexical rules; folder collisions are a separate fixture policy."""
    title = raw.strip()
    for label in ("Title:", "Filename:", "Título:", "Titre:"):
        if title.lower().startswith(label.lower()):
            title = title[len(label):].strip(" \t")
            break
    for quote in ('"', "'", "`"):
        if len(title) >= 2 and title.startswith(quote) and title.endswith(quote):
            title = title[1:-1]
            break
    if title.lower().endswith(".md"):
        title = title[:-3]
    natural_title = unicodedata.normalize("NFC", title.strip(" \t"))
    title = unicodedata.normalize("NFC", natural_title.lower())
    words = re.split(r"[\s-]+", title)
    words = [word for word in words if word]
    if (not title or any(c in title for c in "\n\r\v\f\x85\u2028\u2029")
            or title.startswith("-") or title.endswith("-") or not 1 <= len(words) <= 6
            or any(not (unicodedata.category(c)[0] in {"L", "M"} or unicodedata.category(c) == "Nd" or c.isspace() or c == "-") for c in title)):
        raise ValueError("invalid_title")
    filename = "-".join(words)
    if len(filename.encode()) > 180:
        raise ValueError("invalid_title")
    return natural_title, filename + ".md"


def prefix_characters(text: str, count: int):
    # regex \X follows Unicode grapheme clusters; this matches Swift Character
    # prefix semantics substantially better than slicing Python code points.
    try:
        import regex
    except ImportError:
        if text.isascii():
            return text[:count]
        raise ValueError("unicode_segmentation_dependency_required") from None
    return "".join(regex.findall(r"\X", text)[:count])


def messages_for(text: str, prompt: dict, generation: dict):
    text = prefix_characters(text, generation.get("max_input_characters", 4000))
    system = prompt.get("system", prompt.get("system_prompt", prompt.get("systemPrompt", "")))
    prefix = prompt.get("user_prefix", prompt.get("user_prompt_prefix", prompt.get("userPromptPrefix", "Generate a title for this note:\n\n<note>\n")))
    suffix = prompt.get("user_suffix", prompt.get("user_prompt_suffix", prompt.get("userPromptSuffix", "\n</note>")))
    user = prefix + text + suffix
    if prompt.get("use_system_role", prompt.get("useSystemRole", True)):
        return [{"role": "system", "content": system}, {"role": "user", "content": user}]
    return [{"role": "user", "content": system + "\n" + user}]


def verify_local_model(model: dict):
    """Require explicit immutable provenance, and hash every selected model file."""
    local = Path(model.get("local_path") or "__missing_local_model__").resolve()
    if not local.is_dir() or not (local / "config.json").is_file():
        raise ValueError("local_model_missing")
    snapshot_path = local / "snapshot.json"
    if not snapshot_path.is_file():
        raise ValueError("model_snapshot_manifest_required")
    snapshot = json.loads(snapshot_path.read_text())
    revision = model.get("revision", "")
    if not re.fullmatch(r"[a-fA-F0-9]{40}", revision) or snapshot.get("revision") != revision or snapshot.get("model_id") != model.get("model_id"):
        raise ValueError("model_snapshot_identity_mismatch")
    files = snapshot.get("files", {})
    if not files or "config.json" not in files or not any(name.endswith(".safetensors") for name in files):
        raise ValueError("model_snapshot_files_missing")
    actual = {str(p.relative_to(local)) for p in local.rglob("*") if p.is_file() and p.name != "snapshot.json"}
    if set(files) != actual:
        raise ValueError("model_snapshot_file_set_mismatch")
    for name, expected in files.items():
        path = (local / name).resolve()
        if local not in path.parents or not path.is_file():
            raise ValueError("invalid_model_snapshot_path")
        with path.open("rb") as stream:
            checksum = hashlib.file_digest(stream, "sha256").hexdigest()
        if checksum != expected:
            raise ValueError("model_snapshot_checksum_mismatch")
    return local, digest(snapshot)


class SyntheticBackend:
    def __init__(self, run):
        self.run = run
        self.load_seconds = 0.0
        self.warmup_seconds = 0.0
        self.model_hash = "synthetic"

    def generate(self, record, attempt, messages):
        if record.get("source") != "synthetic":
            raise ValueError("synthetic_records_required")
        outputs = record.get("synthetic_outputs", ["Synthetic Note Title"])
        output = outputs[min(attempt - 1, len(outputs) - 1)]
        if not isinstance(output, str):
            raise ValueError("synthetic_generation_failure")
        return output, {"finish_reason": "synthetic", "mlx_peak_bytes": None}

    def close(self):
        pass


class MLXBackend:
    def __init__(self, run):
        os.environ.update(HF_HUB_OFFLINE="1", TRANSFORMERS_OFFLINE="1", HF_HUB_DISABLE_TELEMETRY="1")
        local, self.model_hash = verify_local_model(run["model"])
        adapter = run["model"].get("adapter")
        if adapter:
            adapter = Path(adapter).resolve()
            metadata = json.loads((adapter / "lineage.json").read_text())
            if metadata.get("base_model_id") != run["model"]["model_id"] or metadata.get("base_revision") != run["model"]["revision"] or metadata.get("status") != "complete":
                raise ValueError("adapter_lineage_mismatch")
            self.adapter_hash = digest({str(p.relative_to(adapter)): hashlib.sha256(p.read_bytes()).hexdigest() for p in adapter.rglob("*") if p.is_file() and p.name != "lineage.json"})
            if metadata.get("adapter_hash") != self.adapter_hash:
                raise ValueError("adapter_lineage_mismatch")
        started = time.perf_counter()
        import mlx.core as mx
        from mlx_lm import load
        from mlx_lm.sample_utils import make_sampler
        self.mx = mx
        self.model, self.tokenizer = load(str(local), adapter_path=str(adapter) if adapter else None, tokenizer_config={"trust_remote_code": False})
        mx.eval(self.model.parameters())
        self.load_seconds = time.perf_counter() - started
        self.tokenizer_hash = digest({name: checksum for name, checksum in json.loads((local / "snapshot.json").read_text())["files"].items() if "token" in name or "template" in name})
        self.chat_template_hash = digest(getattr(self.tokenizer, "chat_template", None))
        self.generation = run["generation"]
        self.seed = run["seed"]
        self.sampler = make_sampler(temp=self.generation["temperature"], top_p=self.generation["top_p"], top_k=self.generation.get("top_k") or 0)
        self.warmup_seconds = None

    def generate(self, record, attempt, messages):
        from mlx_lm import stream_generate
        seed = int(digest([self.seed, record["note_id"], attempt])[:8], 16)
        self.mx.random.seed(seed)
        rendered = self.tokenizer.apply_chat_template(messages, tokenize=False, add_generation_prompt=True, enable_thinking=self.generation.get("enable_thinking", False))
        chunks, last = [], None
        for chunk in stream_generate(self.model, self.tokenizer, prompt=rendered, max_tokens=self.generation["max_output_tokens"], sampler=self.sampler):
            chunks.append(chunk.text)
            last = chunk
        return "".join(chunks), {"rendered_input": rendered, "rendered_input_sha256": hashlib.sha256(rendered.encode()).hexdigest(), "finish_reason": getattr(last, "finish_reason", None) or "unknown", "mlx_peak_bytes": int(self.mx.get_peak_memory()), "prompt_tokens": getattr(last, "prompt_tokens", None), "generation_tokens": getattr(last, "generation_tokens", None)}

    def close(self):
        self.model = None
        self.tokenizer = None
        self.mx.clear_cache()


@contextlib.contextmanager
def attempt_timeout(seconds):
    if not hasattr(signal, "setitimer"):
        yield
        return
    def expired(_signum, _frame):
        raise TimeoutError("generation_timeout")
    previous = signal.signal(signal.SIGALRM, expired)
    signal.setitimer(signal.ITIMER_REAL, seconds)
    try:
        yield
    finally:
        signal.setitimer(signal.ITIMER_REAL, 0)
        signal.signal(signal.SIGALRM, previous)


def execute_run(run: dict, records: list[dict], output_dir: Path, prompt: dict, backend="mlx", timeout_seconds=120):
    """Execute or resume one exact run. Call in a dedicated process for RSS isolation."""
    output_dir = Path(output_dir)
    output_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
    output_dir.chmod(0o700)
    if backend not in {"mlx", "synthetic"}:
        raise ValueError("unknown_backend")
    if not records or len({r["note_id"] for r in records}) != len(records):
        raise ValueError("empty_or_duplicate_records")
    identity = digest({"run": run, "records": records, "prompt": prompt, "backend": backend})
    manifest_path, attempts_path = output_dir / "manifest.json", output_dir / "attempts.jsonl"
    previous = json.loads(manifest_path.read_text()) if manifest_path.exists() else None
    if previous and previous.get("identity") != identity:
        raise ValueError("resume_identity_mismatch")
    old = []
    if attempts_path.exists():
        if previous is None:
            raise ValueError("orphaned_attempts")
        old = [json.loads(line) for line in attempts_path.read_text().splitlines() if line.strip()]
    expected_ids = {r["note_id"] for r in records}
    keys = {(a["note_id"], a["attempt"]) for a in old}
    if len(keys) != len(old) or any(a["note_id"] not in expected_ids for a in old):
        raise ValueError("invalid_resume_attempts")
    for note_id in expected_ids:
        rows = [a for a in old if a["note_id"] == note_id]
        if [a["attempt"] for a in rows] != list(range(1, len(rows) + 1)) or any(a.get("terminal") for a in rows[:-1]):
            raise ValueError("invalid_resume_sequence")
        if rows and (rows[-1]["attempt"] > run["generation"]["max_attempts"] or (rows[-1]["attempt"] == run["generation"]["max_attempts"] and not rows[-1].get("terminal")) or any(bool(a.get("accepted")) and not a.get("terminal") for a in rows)):
            raise ValueError("invalid_resume_sequence")
    completed = {a["note_id"] for a in old if a.get("terminal")}
    if previous and previous.get("status") == "complete" and completed == expected_ids:
        return previous
    versions = {}
    for name in ("mlx", "mlx-lm", "regex", "transformers"):
        try:
            versions[name] = importlib.metadata.version(name)
        except importlib.metadata.PackageNotFoundError:
            versions[name] = None
    manifest = {"schema_version": 1, "identity": identity, "id": run["id"], "run": run, "backend": backend, "status": "running", "expected_notes": len(records), "completed_notes": len(completed), "prompt_hash": digest(prompt), "dataset_hash": digest(records), "runtime": {"python": platform.python_version(), "platform": platform.platform(), "machine": platform.machine(), "packages": versions}, "load_seconds": None, "warmup_seconds": None, "error_code": None, "implementation_hash": digest({p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(Path(__file__).parent.glob("*.py"))}), "environment": {d.metadata["Name"]: d.version for d in importlib.metadata.distributions() if d.metadata.get("Name")}}
    restricted_json(manifest_path, manifest)
    generator = None
    session_start = resource_snapshot()
    phases = {}
    manifest["resource_sessions"] = list((previous or {}).get("resource_sessions", []))
    try:
        with open(os.devnull, "w") as quiet, contextlib.redirect_stdout(quiet), contextlib.redirect_stderr(quiet):
            phase_start = resource_snapshot()
            generator = (MLXBackend if backend == "mlx" else SyntheticBackend)(run)
            phases["load"] = resource_delta(phase_start)
            manifest.update(load_seconds=generator.load_seconds, model_snapshot_hash=generator.model_hash)
            phase_start = resource_snapshot()
            if backend == "mlx":
                warmup_start = time.perf_counter()
                with attempt_timeout(timeout_seconds):
                    generator.generate({"note_id": "warmup", "text": "Synthetic warmup note."}, 1, messages_for("Synthetic warmup note.", prompt, run["generation"]))
                manifest["warmup_seconds"] = time.perf_counter() - warmup_start
                manifest["adapter_hash"] = getattr(generator, "adapter_hash", None)
                manifest["tokenizer_hash"] = generator.tokenizer_hash
                manifest["chat_template_hash"] = generator.chat_template_hash
            else:
                manifest["warmup_seconds"] = 0.0
            phases["warmup"] = resource_delta(phase_start)
            phase_start = resource_snapshot()
            fd = os.open(attempts_path, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
            with os.fdopen(fd, "a", encoding="utf-8") as stream:
                for record in records:
                    if record["note_id"] in completed:
                        continue
                    first = max((a["attempt"] for a in old if a["note_id"] == record["note_id"]), default=0) + 1
                    for attempt in range(first, run["generation"]["max_attempts"] + 1):
                        attempt_resources = resource_snapshot()
                        started = time.perf_counter()
                        row = {"schema_version": 1, "run_id": run["id"], "note_id": record["note_id"], "seed": run["seed"], "attempt": attempt, "raw_output": None, "title": None, "normalized_filename": None, "accepted": False, "error_code": None, "finish_reason": None, "mlx_peak_bytes": None, "reference_titles": record.get("reference_titles", []), "source": record.get("source", "unknown"), "language": record.get("language", "unknown"), "source_group": record.get("source_group", record["note_id"]), "reference_type": record.get("reference_type", record.get("reference_kind", "unknown")), "source_content_hash": hashlib.sha256(record["text"].encode()).hexdigest()}
                        try:
                            messages = messages_for(record["text"], prompt, run["generation"])
                            with attempt_timeout(timeout_seconds):
                                raw, details = generator.generate(record, attempt, messages)
                            row.update(details)
                            row["raw_output"] = raw
                            row["title"], row["normalized_filename"] = normalize_title(raw)
                            row["accepted"] = True
                        except TimeoutError:
                            row["error_code"] = "generation_timeout"
                        except ValueError as error:
                            row["error_code"] = "invalid_title" if str(error) == "invalid_title" else "generation_failure"
                        except Exception:
                            row["error_code"] = "generation_failure"
                        row["latency_seconds"] = time.perf_counter() - started
                        measured = resource_delta(attempt_resources)
                        row.update({key: value for key, value in measured.items() if key != "wall_seconds"})
                        row["terminal"] = row["accepted"] or attempt == run["generation"]["max_attempts"]
                        stream.write(json.dumps(row, ensure_ascii=False, sort_keys=True) + "\n")
                        stream.flush()
                        os.fsync(stream.fileno())
                        if row["terminal"]:
                            completed.add(record["note_id"])
                            manifest["completed_notes"] = len(completed)
                            restricted_json(manifest_path, manifest)
                            break
            phases["evaluation"] = resource_delta(phase_start)
            manifest["status"] = "complete" if completed == expected_ids else "incomplete"
    except Exception as error:
        manifest["status"] = "failed"
        # Only stable allowlisted codes leave this layer. Exception text may contain data.
        safe = {"local_model_missing", "model_snapshot_manifest_required", "model_snapshot_identity_mismatch", "model_snapshot_files_missing", "model_snapshot_file_set_mismatch", "invalid_model_snapshot_path", "model_snapshot_checksum_mismatch", "adapter_lineage_mismatch"}
        manifest["error_code"] = str(error) if str(error) in safe else "backend_initialization_failure"
    finally:
        if generator:
            with open(os.devnull, "w") as quiet, contextlib.redirect_stdout(quiet), contextlib.redirect_stderr(quiet):
                try:
                    generator.close()
                except Exception:
                    manifest.update(status="failed", error_code="backend_unload_failure")
        manifest["resource_sessions"].append({"phases": phases, "total": resource_delta(session_start)})
        restricted_json(manifest_path, manifest)
    return manifest


def register_model(local_path, model_id, revision):
    """Record user-selected local model provenance; never fetch remote files."""
    local = Path(local_path).resolve()
    if not re.fullmatch(r"[a-fA-F0-9]{40}", revision) or not model_id or not (local / "config.json").is_file():
        raise ValueError("invalid_model_registration")
    files = {}
    for path in sorted(local.rglob("*")):
        if path.is_file() and path.name != "snapshot.json":
            resolved = path.resolve()
            if local not in resolved.parents:
                raise ValueError("model_symlink_outside_snapshot")
            with path.open("rb") as stream:
                files[str(path.relative_to(local))] = hashlib.file_digest(stream, "sha256").hexdigest()
    if not any(name.endswith(".safetensors") for name in files):
        raise ValueError("model_weights_missing")
    value = {"schema_version": 1, "model_id": model_id, "revision": revision, "files": files, "provenance": "user_attested_local_snapshot"}
    if (local / "snapshot.json").exists():
        if json.loads((local / "snapshot.json").read_text()) != value:
            raise ValueError("model_registration_conflict")
    else:
        restricted_json(local / "snapshot.json", value)
    return {"status": "registered", "file_count": len(files), "snapshot_hash": digest(value), "provenance": value["provenance"]}
