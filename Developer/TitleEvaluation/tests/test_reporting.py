import json
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from title_eval.reporting import build_report, paired_comparison
from title_eval.scoring import score_run
from test_scoring import fixture, attempt


class ReportingTests(unittest.TestCase):
    def test_report_is_content_free_and_escapes_configuration(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            base = root / "base"
            other = root / "other"
            fixture(base)
            manifest = fixture(other, run_id="candidate")
            manifest["run"]["name"] = '</script><img src=x onerror=alert(1)>'
            (other/"manifest.json").write_text(json.dumps(manifest))
            score_run(base)
            score_run(other)
            path = build_report([base, other], root/"report", "baseline")
            text = path.read_text()
            self.assertNotIn("Useful Note", text)
            self.assertNotIn("Reference Title", text)
            self.assertNotIn("</script><img", text)
            self.assertIn("\\u003c/script", text)
            self.assertIn("addEventListener", text)
            self.assertTrue((root/"report"/"comparison.csv").exists())
            comparison = json.loads((root/"report"/"comparison.json").read_text())["runs"][1]["comparison"]
            self.assertEqual(comparison["status"], "complete")
            self.assertEqual(comparison["metrics"]["final_accepted"]["delta"], 0)

    def test_unscored_and_incomplete_remain_visible(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            fixture(root/"unscored")
            fixture(root/"partial", run_id="partial", attempts=[], expected=3)
            score_run(root/"partial")
            build_report([root/"unscored", root/"partial"], root/"report")
            rows = json.loads((root/"report"/"comparison.json").read_text())["runs"]
            self.assertEqual([r["status"] for r in rows], ["unscored", "incomplete"])
            self.assertEqual(rows[1]["metrics"]["final_acceptance"], 0)

    def test_swept_baseline_model_does_not_replace_fixed_anchor(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            fixture(root/"anchor")
            sweep = fixture(root/"sweep", run_id="swept")
            sweep["run"]["model"].update(name="baseline", role="baseline")
            sweep["run"]["generation"]["temperature"] = .2
            (root/"sweep"/"manifest.json").write_text(json.dumps(sweep))
            candidate = fixture(root/"candidate", run_id="candidate")
            candidate["run"]["generation"]["temperature"] = .2
            (root/"candidate"/"manifest.json").write_text(json.dumps(candidate))
            for name in ("anchor", "sweep", "candidate"):
                score_run(root/name)
            build_report([root/name for name in ("anchor", "sweep", "candidate")], root/"report", "baseline")
            entries = json.loads((root/"report"/"comparison.json").read_text())["runs"]
            self.assertEqual(entries[2]["comparison"]["baseline_run_id"], "baseline")

    def test_changed_predictions_reject_stale_scores(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            fixture(root/"base")
            score_run(root/"base")
            with (root/"base"/"attempts.jsonl").open("a") as f:
                f.write("\n")
            with self.assertRaisesRegex(ValueError, "stale_scores"):
                build_report([root/"base"], root/"report")

    def test_group_bootstrap_deterministic_and_paired(self):
        meta = {"dataset_hash": "same", "scoring_hash": "same", "status": "complete"}
        a, b = [], []
        for i in range(12):
            row = {"note_id": str(i), "source": "s", "language": "en", "source_group": str(i//2), "seed": 17,
                   "final_accepted": True, "first_accepted": True, "prompt_compliant": True, "latency_seconds": i+1., "bertscore_f1": None}
            a.append(row)
            b.append({**row, "final_accepted": i%2 == 0, "latency_seconds": float(i)})
        first = paired_comparison(meta, meta, a, b, 100, 17)
        self.assertEqual(first, paired_comparison(meta, meta, a, b, 100, 17))
        self.assertEqual(first["metrics"]["latency_seconds"]["delta"], 1.)
        self.assertEqual(first["metrics"]["final_accepted"]["groups"], 6)
        self.assertEqual(first["metrics"]["bertscore_f1"]["status"], "missing")
        self.assertEqual(paired_comparison(meta, {**meta,"dataset_hash":"other"}, a,b)["status"], "incompatible")
        self.assertEqual(paired_comparison(meta,meta,a,b[:-1])["status"], "incompatible")

    def test_small_cluster_count_does_not_invent_interval(self):
        meta = {"dataset_hash":"a", "scoring_hash":"a", "status":"complete"}
        row = {"note_id":"one", "source":"s", "language":"en", "source_group":"one", "seed":17, "final_accepted":True}
        result = paired_comparison(meta,meta,[row],[row],10)
        self.assertEqual(result["metrics"]["final_accepted"]["status"], "insufficient_independent_groups")
        self.assertIsNone(result["metrics"]["final_accepted"]["ci_low"])


if __name__ == "__main__":
    unittest.main()
