import json
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from title_eval.scoring import score_run, words, prompt_compliant


def fixture(path, run_id="baseline", attempts=None, expected=3):
    manifest = {"schema_version": 1, "run": {"id": run_id, "name": run_id, "seed": 17, "baseline": run_id == "baseline",
                "model": {"name": run_id, "model_id": "synthetic", "revision": "synthetic", "role": "baseline" if run_id == "baseline" else "candidate"},
                "generation": {"temperature": .5, "top_p": .9, "top_k": None}},
                "status": "complete", "expected_notes": expected, "completed_notes": expected, "dataset_hash": "dataset", "prompt_hash": "prompt"}
    path.mkdir(parents=True, exist_ok=True)
    (path / "manifest.json").write_text(json.dumps(manifest))
    if attempts is None:
        attempts = [attempt("one", 1, "Useful Note", True), attempt("two", 1, "bad\noutput", False, terminal=False),
                    attempt("two", 2, "Useful Note", True), attempt("three", 1, "", False)]
    (path / "attempts.jsonl").write_text("".join(json.dumps(a) + "\n" for a in attempts))
    return manifest


def attempt(note, number, raw, accepted, terminal=True):
    return {"note_id": note, "attempt": number, "raw_output": raw, "title": raw,
            "normalized_filename": "useful-note.md" if accepted else None, "accepted": accepted,
            "error_code": None if accepted else "invalid_output", "latency_seconds": 1.,
            "terminal": terminal, "source": "synthetic", "language": "en", "source_group": note,
            "reference_type": "synthetic", "reference_titles": ["Reference Title"],
            "process_peak_rss_bytes": 100, "mlx_peak_bytes": 50}


class ScoringTests(unittest.TestCase):
    def test_failures_retries_and_duplicate_denominators(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp)
            fixture(path)
            summary = score_run(path)
            metrics = summary["metrics"]
            self.assertAlmostEqual(metrics["final_acceptance"], 2/3)
            self.assertAlmostEqual(metrics["first_attempt_acceptance"], 1/3)
            self.assertAlmostEqual(metrics["retry_rate"], 1/3)
            self.assertEqual(metrics["latency_p50_seconds"], 1)
            self.assertAlmostEqual(metrics["latency_p95_seconds"], 1.9)
            self.assertEqual(metrics["normalized_collision_rate"], .5)
            self.assertEqual(metrics["bertscore_f1_mean"], None)
            self.assertEqual(summary["failure_reasons"], {"invalid_output": 1})
            self.assertNotIn("Reference Title", (path/"scores.jsonl").read_text())
            self.assertNotIn("Useful Note", (path/"summary.json").read_text())

    def test_missing_predictions_count_as_failure_not_completion(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp)
            fixture(path, attempts=[attempt("one", 1, "Useful Note", True)], expected=3)
            summary = score_run(path)
            self.assertEqual(summary["status"], "incomplete")
            self.assertEqual(summary["coverage"]["missing_notes"], 2)
            self.assertAlmostEqual(summary["metrics"]["final_acceptance"], 1/3)

    def test_partial_note_is_not_final_success(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp)
            fixture(path, attempts=[attempt("one", 1, "", False, terminal=False)], expected=1)
            summary = score_run(path)
            self.assertEqual(summary["completed_notes"], 0)
            self.assertEqual(summary["metrics"]["final_acceptance"], 0)

    def test_duplicate_or_noncontiguous_attempt_rejected_without_content(self):
        for rows in ([attempt("one", 1, "SECRET", False)] * 2, [attempt("one", 2, "SECRET", False)]):
            with self.subTest(rows=len(rows)), tempfile.TemporaryDirectory() as temp:
                path = Path(temp)
                fixture(path, attempts=rows)
                with self.assertRaises(ValueError) as error:
                    score_run(path)
                self.assertNotIn("SECRET", str(error.exception))

    def test_no_attempt_after_terminal(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp)
            fixture(path, attempts=[attempt("one", 1, "Useful Note", True), attempt("one", 2, "Other Note", True)])
            with self.assertRaisesRegex(ValueError, "attempt_after_terminal"):
                score_run(path)

    def test_unicode_and_prompt_compliance(self):
        self.assertEqual(words("Reunião sobre ação técnica"), ["Reunião", "sobre", "ação", "técnica"])
        self.assertEqual(words("cafe\u0301 d’água SQL-42"), ["café", "d’água", "SQL", "42"])
        self.assertTrue(prompt_compliant("Useful Note"))
        for text in ["One", "Title: Useful Note", "Useful Note.md", '"Useful Note"', "two\nlines"]:
            self.assertFalse(prompt_compliant(text))

    def test_bertscore_requires_pinned_local_encoder(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp)
            fixture(path)
            with self.assertRaisesRegex(ValueError, "pinned_local_encoder"):
                score_run(path, {"bertscore": {"enabled": True, "model_path": temp}})

    def test_slice_denominators_and_unavailable_latency(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp)
            rows = [attempt("one", 1, "Useful Note", True), attempt("two", 1, "", False)]
            rows[1].update(language="pt", latency_seconds=None)
            fixture(path, attempts=rows, expected=2)
            summary = score_run(path)
            self.assertEqual(len(summary["slices"]), 2)
            self.assertIsNone(summary["slices"][1]["metrics"]["latency_p50_seconds"])
            self.assertEqual(summary["metrics"]["latency_p50_seconds"], 1)


if __name__ == "__main__":
    unittest.main()
