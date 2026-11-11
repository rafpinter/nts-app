import contextlib
import io
import json
from pathlib import Path
import tempfile
import unittest

from title_eval.execution import execute_run, normalize_title, register_model, verify_local_model


class ExecutionTests(unittest.TestCase):
    def run_config(self):
        return {"id": "synthetic-run", "name": "synthetic", "model": {"name": "fixture", "model_id": "fixture", "revision": "a" * 40}, "seed": 17, "generation": {"temperature": 0.5, "top_p": 0.9, "top_k": None, "max_attempts": 3, "max_input_characters": 100, "max_output_tokens": 32, "enable_thinking": False}}

    def records(self):
        return [{"note_id": "n1", "text": "Fixture text never printed", "source": "synthetic", "language": "en", "source_group": "group1", "reference_titles": ["Fixture Reference"], "synthetic_outputs": ["../../bad", "Useful Fixture Title"]}, {"note_id": "n2", "text": "Another fixture", "source": "synthetic", "source_group": "group2", "synthetic_outputs": ["bad\noutput"]}]

    def test_retries_exhaustion_resume_and_private_diagnostics(self):
        with tempfile.TemporaryDirectory() as root:
            out = Path(root)
            stdout, stderr = io.StringIO(), io.StringIO()
            with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
                manifest = execute_run(self.run_config(), self.records(), out, {"system": "Name the note"}, backend="synthetic")
            self.assertEqual(stdout.getvalue() + stderr.getvalue(), "")
            self.assertEqual(manifest["status"], "complete")
            session = manifest["resource_sessions"][0]
            self.assertGreater(session["total"]["wall_seconds"], 0)
            self.assertEqual(set(session["phases"]), {"load", "warmup", "evaluation"})
            self.assertGreater(session["total"]["process_peak_rss_bytes"], 0)
            attempts = [json.loads(line) for line in (out / "attempts.jsonl").read_text().splitlines()]
            self.assertEqual(len(attempts), 5)
            for attempt in attempts:
                self.assertGreaterEqual(attempt["cpu_seconds"], 0)
                self.assertAlmostEqual(attempt["cpu_seconds"], attempt["cpu_user_seconds"] + attempt["cpu_system_seconds"])
            from title_eval.scoring import score_run
            summary = score_run(out)
            self.assertGreater(summary["metrics"]["total_wall_seconds"], 0)
            self.assertGreater(summary["metrics"]["attempts_per_second"], 0)
            self.assertIsNone(summary["metrics"]["generation_tokens_per_second"])
            self.assertAlmostEqual(summary["metrics"]["cpu_seconds_total"], sum(a["cpu_seconds"] for a in attempts))
            self.assertEqual([a["terminal"] for a in attempts], [False, True, False, False, True])
            self.assertTrue(attempts[1]["accepted"])
            self.assertFalse(attempts[-1]["accepted"])
            contents = (out / "attempts.jsonl").read_bytes()
            resumed = execute_run(self.run_config(), self.records(), out, {"system": "Name the note"}, backend="synthetic")
            self.assertEqual(resumed["resource_sessions"], manifest["resource_sessions"])
            self.assertEqual(contents, (out / "attempts.jsonl").read_bytes())
            self.assertEqual((out / "attempts.jsonl").stat().st_mode & 0o777, 0o600)
            changed = self.records(); changed[0]["text"] += "change"
            with self.assertRaisesRegex(ValueError, "resume_identity_mismatch"):
                execute_run(self.run_config(), changed, out, {"system": "Name the note"}, backend="synthetic")

    def test_resume_partial_and_duplicate_keys(self):
        with tempfile.TemporaryDirectory() as root:
            out = Path(root)
            execute_run(self.run_config(), self.records(), out, {}, backend="synthetic")
            path = out / "attempts.jsonl"
            rows = path.read_text().splitlines()
            path.write_text(rows[0] + "\n")
            manifest_path = out / "manifest.json"
            manifest = json.loads(manifest_path.read_text()); manifest["status"] = "running"
            manifest_path.write_text(json.dumps(manifest))
            execute_run(self.run_config(), self.records(), out, {}, backend="synthetic")
            self.assertEqual(len(path.read_text().splitlines()), 5)
            path.write_text(path.read_text() + path.read_text().splitlines()[0] + "\n")
            with self.assertRaisesRegex(ValueError, "invalid_resume_attempts"):
                execute_run(self.run_config(), self.records(), out, {}, backend="synthetic")

    def test_resource_units_and_multicore_cpu(self):
        from unittest.mock import patch
        from types import SimpleNamespace
        from title_eval.execution import resource_snapshot, resource_delta
        usage = SimpleNamespace(ru_utime=3.0, ru_stime=1.0, ru_maxrss=200)
        with patch("title_eval.execution.resource.getrusage", return_value=usage), patch("title_eval.execution.time.perf_counter", return_value=10.0):
            with patch("title_eval.execution.sys.platform", "darwin"):
                self.assertEqual(resource_snapshot()["rss"], 200)
            with patch("title_eval.execution.sys.platform", "linux"):
                self.assertEqual(resource_snapshot()["rss"], 200 * 1024)
            result = resource_delta({"wall": 9.0, "user": 1.0, "system": 0.0})
            self.assertEqual(result["cpu_seconds"], 3.0)
            self.assertEqual(result["cpu_percent_one_core"], 300.0)

    def test_normalizer_app_examples(self):
        valid = {"Title: 'Natural Note Title.md'": "natural-note-title.md", "Título: Café com Leite": "café-com-leite.md", "One": "one.md", "hello--world": "hello-world.md", "`hello world`": "hello-world.md"}
        for raw, filename in valid.items():
            self.assertEqual(normalize_title(raw)[1], filename)
        for raw in ("../note", "title\nreason", "-title", "title-", "one two three four five six seven", "code.py", "💡 title", "```hello```", "a" * 181):
            with self.subTest(raw=raw), self.assertRaises(ValueError):
                normalize_title(raw)

    def test_local_model_registration_and_tampering(self):
        with tempfile.TemporaryDirectory() as root:
            local = Path(root)
            (local / "config.json").write_text('{"quantization": {"bits": 4}}')
            (local / "model.safetensors").write_bytes(b"synthetic weights")
            result = register_model(local, "fixture/model", "a" * 40)
            self.assertEqual(result["provenance"], "user_attested_local_snapshot")
            model = {"local_path": str(local), "model_id": "fixture/model", "revision": "a" * 40}
            self.assertEqual(verify_local_model(model)[0], local.resolve())
            (local / "model.safetensors").write_bytes(b"changed")
            with self.assertRaisesRegex(ValueError, "checksum_mismatch"):
                verify_local_model(model)

    def test_missing_model_is_safe_failure_no_import(self):
        with tempfile.TemporaryDirectory() as root:
            result = execute_run(self.run_config(), self.records(), Path(root), {}, backend="mlx")
            self.assertEqual(result["status"], "failed")
            self.assertEqual(result["error_code"], "local_model_missing")


if __name__ == "__main__":
    unittest.main()
