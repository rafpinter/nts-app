"""Content-free standalone comparison reports; no external assets or model access."""
from __future__ import annotations

import csv
import hashlib
import html
import json
import math
from pathlib import Path
import random
import statistics
from collections import defaultdict

from .scoring import _number, _write_json, percentile


def _read(path):
    try:
        return json.loads(path.read_text())
    except Exception:
        raise ValueError("invalid_report_input") from None


def _public_run(run):
    model, generation = run.get("model", {}), run.get("generation", {})
    return {"run_id": run["id"], "run_name": run.get("name", run["id"]),
            "model": model.get("name", model.get("model_id", "unknown")),
            "model_id": model.get("model_id"), "revision": model.get("revision"),
            "fine_tuned": bool(model.get("adapter") or model.get("adapter_from") or model.get("role") == "fine_tuned"),
            "temperature": generation.get("temperature"), "top_p": generation.get("top_p"),
            "top_k": generation.get("top_k"), "seed": run.get("seed")}


def _score_rows(path):
    try:
        rows = [json.loads(line) for line in path.read_text().splitlines() if line.strip()]
        if len({r["note_id"] for r in rows}) != len(rows):
            raise ValueError
        return rows
    except Exception:
        raise ValueError("invalid_score_artifact") from None


def paired_comparison(candidate, baseline, candidate_rows, baseline_rows, resamples=10000, seed=17):
    """Resample source groups jointly within source/language strata."""
    if resamples < 1:
        raise ValueError("invalid_bootstrap_resamples")
    required = ("dataset_hash", "scoring_hash")
    if any(not candidate.get(k) or candidate.get(k) != baseline.get(k) for k in required):
        return {"status": "incompatible", "reason": "dataset_or_scorer_mismatch"}
    if candidate.get("status") != "complete" or baseline.get("status") != "complete":
        return {"status": "incompatible", "reason": "incomplete_run"}
    left = {r["note_id"]: r for r in candidate_rows}
    right = {r["note_id"]: r for r in baseline_rows}
    if not left or set(left) != set(right):
        return {"status": "incompatible", "reason": "unpaired_notes"}
    if any((left[k].get("source"), left[k].get("language"), left[k].get("source_group"), left[k].get("seed")) !=
           (right[k].get("source"), right[k].get("language"), right[k].get("source_group"), right[k].get("seed")) for k in left):
        return {"status": "incompatible", "reason": "group_or_seed_mismatch"}
    result = {"status": "complete", "notes": len(left), "method": "paired_stratified_group_percentile_bootstrap",
              "confidence_level": .95, "resamples": resamples, "seed": seed, "metrics": {}}
    for metric in ("final_accepted", "first_accepted", "prompt_compliant", "latency_seconds", "bertscore_f1"):
        strata = defaultdict(lambda: defaultdict(list))
        for note_id in sorted(left):
            a, b = left[note_id], right[note_id]
            av, bv = a.get(metric), b.get(metric)
            if isinstance(av, bool):
                av = float(av)
            if isinstance(bv, bool):
                bv = float(bv)
            if not _number(av) or not _number(bv):
                continue
            strata[(a.get("source"), a.get("language"))][a.get("source_group") or note_id].append(av - bv)
        groups = [list(s.values()) for s in strata.values()]
        values = [v for s in groups for g in s for v in g]
        if not values:
            result["metrics"][metric] = {"delta": None, "ci_low": None, "ci_high": None, "paired_notes": 0, "status": "missing"}
            continue
        # Average group draws back into each stratum and retain its original note weight.
        stratum_sizes = [sum(len(g) for g in s) for s in groups]
        rng = random.Random(seed)
        draws = []
        for _ in range(resamples):
            weighted = 0
            for stratum, size in zip(groups, stratum_sizes):
                sample = [v for _ in stratum for v in rng.choice(stratum)]
                weighted += statistics.mean(sample) * size
            draws.append(weighted / len(values))
        degenerate = all(len(s) == 1 for s in groups)
        result["metrics"][metric] = {"delta": statistics.mean(values),
                                    "ci_low": percentile(draws, .025) if not degenerate else None,
                                    "ci_high": percentile(draws, .975) if not degenerate else None,
                                    "paired_notes": len(values), "groups": sum(len(s) for s in groups),
                                    "status": "insufficient_independent_groups" if degenerate else "complete"}
    return result


def build_report(run_dirs: list[Path], output_dir: Path, baseline_name: str | None = None) -> Path:
    output_dir = Path(output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)
    entries, private = [], {}
    for directory in map(Path, run_dirs):
        manifest = _read(directory / "manifest.json")
        run = manifest["run"]
        public = _public_run(run)
        public["backend"] = manifest.get("backend", "unknown")
        if public["run_id"] in private:
            raise ValueError("duplicate_report_run")
        summary = _read(directory / "summary.json") if (directory / "summary.json").exists() else None
        if summary and summary.get("run_id") != run["id"]:
            raise ValueError("summary_run_mismatch")
        if summary and summary.get("prediction_hash"):
            prediction_path = directory / "attempts.jsonl"
            if not prediction_path.exists() or hashlib.sha256(prediction_path.read_bytes()).hexdigest() != summary["prediction_hash"]:
                raise ValueError("stale_scores")
        if summary and summary.get("scores_hash"):
            score_path = directory / "scores.jsonl"
            if not score_path.exists() or hashlib.sha256(score_path.read_bytes()).hexdigest() != summary["scores_hash"]:
                raise ValueError("stale_score_table")
        public.update({"status": summary.get("status") if summary else "unscored",
                       "expected_notes": manifest.get("expected_notes", 0),
                       "completed_notes": summary.get("completed_notes", 0) if summary else manifest.get("completed_notes", 0),
                       "dataset_hash": manifest.get("dataset_hash"), "metrics": summary.get("metrics", {}) if summary else {},
                       "slices": summary.get("slices", []) if summary else [],
                       "failure_reasons": summary.get("failure_reasons", {}) if summary else {},
                       "limitations": summary.get("limitations", []) if summary else ["Run has not been scored."],
                       "comparison": None})
        entries.append(public)
        private[run["id"]] = {"manifest": manifest, "summary": summary, "directory": directory}
    baselines = [entry for entry in entries
                 if private[entry["run_id"]]["manifest"]["run"].get("baseline") is True
                 and (not baseline_name or baseline_name in (entry["run_name"], entry["model"], entry["run_id"]))]
    for entry in entries:
        candidates = [b for b in baselines if b["seed"] == entry["seed"]]
        exact = [b for b in candidates if all(b[k] == entry[k] for k in ("temperature", "top_p", "top_k"))]
        candidates = exact or candidates
        if len(candidates) != 1:
            entry["comparison"] = {"status": "unavailable", "reason": "baseline_not_unique_for_seed"}
            continue
        baseline = candidates[0]
        a, b = private[entry["run_id"]], private[baseline["run_id"]]
        if not a["summary"] or not b["summary"]:
            entry["comparison"] = {"status": "unavailable", "reason": "unscored_run"}
            continue
        ma, mb = a["manifest"], b["manifest"]
        if ma.get("backend") != mb.get("backend") or ma["run"].get("generation", {}).get("max_input_characters") != mb["run"].get("generation", {}).get("max_input_characters"):
            entry["comparison"] = {"status": "incompatible", "reason": "backend_or_input_limit_mismatch"}
            continue
        if not ma.get("prompt_hash") or ma.get("prompt_hash") != mb.get("prompt_hash"):
            entry["comparison"] = {"status": "incompatible", "reason": "prompt_mismatch_or_unknown"}
            continue
        settings = a["summary"].get("bootstrap", {})
        result = paired_comparison(a["summary"], b["summary"], _score_rows(a["directory"] / "scores.jsonl"),
                                   _score_rows(b["directory"] / "scores.jsonl"),
                                   settings.get("resamples", 10000), settings.get("seed", 17))
        result["baseline_run_id"] = baseline["run_id"]
        entry["comparison"] = result
    artifact = {"schema_version": 1, "runs": entries,
                "limitations": ["Aggregate-only report: no note content, titles or row identifiers.",
                                "No model recommendation is inferred from automatic metrics alone.",
                                "Confidence intervals group related notes; repeated seeds are separate paired comparisons.",
                                "Language agreement and human usefulness are unmeasured unless reviewed separately."]}
    _write_json(output_dir / "comparison.json", artifact)
    metric_keys = sorted({k for entry in entries for k in entry["metrics"]})
    config_keys = ["run_id", "run_name", "backend", "model", "fine_tuned", "temperature", "top_p", "top_k", "seed", "status", "expected_notes", "completed_notes"]
    with (output_dir / "comparison.csv").open("w", newline="") as stream:
        writer = csv.DictWriter(stream, fieldnames=config_keys + metric_keys)
        writer.writeheader()
        for entry in entries:
            writer.writerow({**{k: entry[k] for k in config_keys}, **entry["metrics"]})
    # Encode data for a non-executable JSON script, preventing closing-tag injection.
    encoded = json.dumps(artifact, ensure_ascii=True, allow_nan=False).replace("<", "\\u003c").replace(">", "\\u003e").replace("&", "\\u0026")
    page = '''<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width">
<title>Title experiment comparison</title><style>
body{background:#242933;color:#eceff4;font:15px ui-monospace,monospace;margin:2rem}h1{font-size:1.5rem}label{display:inline-block;margin:.5rem}select,input{font:inherit;padding:.4rem;background:#3b4252;color:#eceff4;border:1px solid #81a1c1}table{border-collapse:collapse;width:100%;font-size:13px}td,th{padding:.6rem;border-bottom:1px solid #4c566a;text-align:left}th{color:#88c0d0}svg{background:#2e3440;max-width:100%;height:auto}.scroll{overflow:auto}.muted{color:#aeb8c7}details{margin:1rem 0}pre{white-space:pre-wrap;overflow-wrap:anywhere}.chart{margin:1rem 0}circle{fill:#88c0d0}text{fill:#eceff4;font-size:12px}.incomplete,.unscored{color:#ebcb8b}
</style><h1>Title experiment comparison</h1><p id="evidence"></p><p>Python benchmark results. All attempts count toward reliability. No dataset contents are included.</p>
<label>Filter runs <input id="filter" placeholder="Model or run name"></label>
<label>Source / language <select id="slice"><option value="">All slices</option></select></label>
<label>Metric <select id="metric"></select></label>
<div class="chart" id="chart"></div><div class="scroll"><table><thead id="head"></thead><tbody id="body"></tbody></table></div>
<div id="details"></div><p class="muted">CSV and JSON exports accompany this file. Blank metrics are unmeasured, never zero-filled. Paired intervals use saved group-level outcomes; incomplete or incompatible runs are excluded from paired comparisons.</p>
<script type="application/json" id="report-data">__DATA__</script><script>
'use strict';const data=JSON.parse(document.getElementById('report-data').textContent),$=id=>document.getElementById(id);
$('evidence').textContent=data.runs.some(r=>r.backend==='synthetic')?'SYNTHETIC DEMONSTRATION INCLUDED — synthetic runs do not evaluate model quality or performance.':'Backend evidence: '+[...new Set(data.runs.map(r=>r.backend))].join(', ');
const format=v=>v===null||v===undefined?'—':typeof v==='number'?(Number.isInteger(v)?String(v):v.toFixed(4)):String(v);
const metricKeys=[...new Set(data.runs.flatMap(r=>Object.keys(r.metrics)))].sort();
for(const key of metricKeys){const o=document.createElement('option');o.value=key;o.textContent=key;$('metric').append(o)}
if(metricKeys.includes('final_acceptance'))$('metric').value='final_acceptance';
for(const key of [...new Set(data.runs.flatMap(r=>r.slices.map(s=>JSON.stringify([s.source,s.language]))))].sort()){const o=document.createElement('option');o.value=key;o.textContent=JSON.parse(key).join(' / ');$('slice').append(o)}
function cell(row,value,tag='td'){const c=document.createElement(tag);c.textContent=format(value);row.append(c);return c}
function metrics(r){const key=$('slice').value;return key?(r.slices.find(s=>JSON.stringify([s.source,s.language])===key)||{}).metrics||{}:r.metrics}
function draw(){const query=$('filter').value.toLowerCase(),metric=$('metric').value;const runs=data.runs.filter(r=>(r.run_name+' '+r.model).toLowerCase().includes(query));
$('head').replaceChildren();$('body').replaceChildren();$('details').replaceChildren();const h=document.createElement('tr');for(const k of ['Run','Backend','Model','Adapted','Temperature','Top-p','Top-k','Seed','Status','Completed / expected',metric,'Paired Δ (all slices)'])cell(h,k,'th');$('head').append(h);
for(const r of runs){const tr=document.createElement('tr');tr.className=r.status;let delta='—';const map={final_acceptance:'final_accepted',first_attempt_acceptance:'first_accepted',prompt_compliance:'prompt_compliant',bertscore_f1_mean:'bertscore_f1'};const comparison=r.comparison||{},v=(comparison.metrics||{})[map[metric]];if(v&&v.delta!==null)delta=format(v.delta)+' ['+format(v.ci_low)+', '+format(v.ci_high)+']';
for(const v of [r.run_name,r.backend,r.model,r.fine_tuned,r.temperature,r.top_p,r.top_k,r.seed,r.status,r.completed_notes+' / '+r.expected_notes,metrics(r)[metric],delta])cell(tr,v);$('body').append(tr);
const d=document.createElement('details'),s=document.createElement('summary'),p=document.createElement('pre');s.textContent=r.run_name+' — provenance, coverage and comparison';p.textContent=JSON.stringify({revision:r.revision,dataset_hash:r.dataset_hash,failure_reasons:r.failure_reasons,limitations:r.limitations,comparison:r.comparison},null,2);d.append(s,p);$('details').append(d)}
const ns='http://www.w3.org/2000/svg',svg=document.createElementNS(ns,'svg');svg.setAttribute('viewBox','0 0 900 360');svg.setAttribute('role','img');svg.setAttribute('aria-label','Selected metric by run');const valid=runs.filter(r=>typeof metrics(r)[metric]==='number');let max=Math.max(1,...valid.map(r=>Math.abs(metrics(r)[metric])));valid.forEach((r,i)=>{const x=50+(i+.5)*800/Math.max(valid.length,1),v=metrics(r)[metric],y=290-v/max*230;const c=document.createElementNS(ns,'circle');c.setAttribute('cx',x);c.setAttribute('cy',y);c.setAttribute('r',7);const title=document.createElementNS(ns,'title');title.textContent=r.run_name+': '+format(v);c.append(title);svg.append(c);const t=document.createElementNS(ns,'text');t.setAttribute('x',x);t.setAttribute('y',320);t.setAttribute('text-anchor','middle');t.textContent=String(i+1);svg.append(t)});const caption=document.createElementNS(ns,'text');caption.setAttribute('x',30);caption.setAttribute('y',25);caption.textContent=metric+' (hover points for run and value)';svg.append(caption);$('chart').replaceChildren(svg)}
for(const id of ['filter','metric','slice'])$(id).addEventListener('input',draw);draw();
</script></html>'''.replace("__DATA__", encoded)
    path = output_dir / "comparison.html"
    path.write_text(page)
    _write_json(output_dir / "report-manifest.json", {"schema_version": 1, "report_sha256": hashlib.sha256(page.encode()).hexdigest(),
                "comparison_sha256": hashlib.sha256((output_dir / "comparison.json").read_bytes()).hexdigest(), "run_count": len(entries)})
    return path
