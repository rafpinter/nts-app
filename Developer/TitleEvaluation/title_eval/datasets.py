"""Purpose-bound input auditing. Errors contain no row values or file names."""
from __future__ import annotations

import gzip
import hashlib
import json
from collections import Counter
from pathlib import Path


class DatasetError(ValueError):
    pass


def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, ensure_ascii=False,
                                     separators=(",", ":")).encode()).hexdigest()


def _rows(path):
    opener = gzip.open if path.suffix == ".gz" else open
    try:
        with opener(path, "rt", encoding="utf-8") as stream:
            for line in stream:
                if line.strip():
                    row = json.loads(line)
                    if not isinstance(row, dict):
                        raise DatasetError("invalid_record")
                    yield row
    except DatasetError:
        raise
    except Exception:
        raise DatasetError("dataset_read_failed") from None


def _check_path(path, allow_private=False):
    path = Path(path).resolve()
    # Selection is always explicit; original vaults and arbitrary Markdown folders
    # are never a supported dataset input. Protected copies require a separate flag.
    if path.suffix not in {".jsonl", ".gz"}:
        raise DatasetError("normalized_jsonl_required")
    if any(p.casefold() in {"private", "obsidian"} for p in path.parts[2:]) and not allow_private:
        raise DatasetError("private_dataset_not_enabled")
    return path


def load_dataset(config):
    """Validate selected normalized input internally; callers expose only audit."""
    path = _check_path(config["path"], config.get("allow_private", False))
    manifest_path = config.get("manifest_path")
    if manifest_path:
        try:
            manifest = json.loads(Path(manifest_path).read_text())
            if manifest.get("status") != "complete":
                raise DatasetError("snapshot_not_complete")
        except DatasetError:
            raise
        except Exception:
            raise DatasetError("snapshot_manifest_invalid") from None
    selected = []
    ids, hashes, groups = set(), set(), set()
    splits = set()
    slices = Counter()
    for row in _rows(path):
        required = ("note_id", "text", "source", "language", "source_group", "split")
        if not all(isinstance(row.get(k), str) and row[k].strip() for k in required):
            raise DatasetError("invalid_record_schema")
        if row["split"] != config["split"]:
            raise DatasetError("unexpected_dataset_split")
        refs = row.get("reference_titles", [])
        if not isinstance(refs, list) or not all(isinstance(r, str) and r.strip() for r in refs):
            raise DatasetError("invalid_references")
        content_hash = hashlib.sha256(row["text"].encode()).hexdigest()
        if row.get("content_sha256", content_hash) != content_hash:
            raise DatasetError("content_hash_mismatch")
        if row["note_id"] in ids or content_hash in hashes:
            raise DatasetError("duplicate_dataset_input")
        ids.add(row["note_id"])
        hashes.add(content_hash)
        groups.add(row["source_group"])
        splits.add(row["split"])
        slices[(row["source"], row["language"])] += 1
        normalized = dict(row)
        normalized["reference_type"] = row.get("reference_type", row.get("reference_kind", "unknown"))
        normalized["content_sha256"] = content_hash
        selected.append(normalized)
    if not selected:
        raise DatasetError("empty_dataset")
    for other_path in config.get("holdout_paths", []):
        other_path = _check_path(other_path, config.get("allow_private", False))
        for row in _rows(other_path):
            if not isinstance(row.get("text"), str) or not isinstance(row.get("source_group"), str):
                raise DatasetError("invalid_holdout_record")
            if (row.get("note_id") in ids or row["source_group"] in groups or
                    hashlib.sha256(row["text"].encode()).hexdigest() in hashes):
                raise DatasetError("cross_split_overlap")
    dataset_hash = digest(selected)
    if config.get("expected_sha256") and dataset_hash != config["expected_sha256"]:
        raise DatasetError("dataset_identity_changed")
    maximum = config.get("max_records")
    if maximum is not None and len(selected) > maximum:
        raise DatasetError("dataset_exceeds_explicit_budget")
    # No row IDs, labels or contents in this allowlisted return object.
    audit = {"schema_version": 1, "status": "passed", "dataset_hash": dataset_hash,
             "records": len(selected), "groups": len(groups),
             "split": config["split"], "reference_records": sum(bool(r.get("reference_titles")) for r in selected),
             "holdout_files_checked": len(config.get("holdout_paths", [])),
             "limitations": ["Near-duplicate and cross-language alignment not established by this audit.",
                              "Reference labels are not human-approved app titles."]}
    return selected, audit


def synthetic_records():
    """Only these developer-authored inputs are used by the smoke command."""
    return [{"note_id": f"synthetic-{i}", "text": text, "reference_titles": [title],
             "source": "synthetic", "language": language, "source_group": f"group-{i // 2}",
             "split": "development", "reference_type": "synthetic"}
            for i, (text, title, language) in enumerate([
                ("Discuss SQLite indexes and query performance.", "SQLite Query Performance", "en"),
                ("Review migration rollback and database recovery.", "Database Recovery Plan", "en"),
                ("Planejar tarefas da equipe para a próxima semana.", "Planejamento da Equipe", "pt"),
                ("Organizar listas e prioridades para o projeto.", "Prioridades do Projeto", "pt"),
            ])]
