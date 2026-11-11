import contextlib
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import subprocess
import types

from title_eval.training import prepare_training, _training_options, train, _worker
from title_eval.execution import register_model


class TrainingTests(unittest.TestCase):
    def setup_files(self, root):
        config = {"name": "fixture-training", "max_train_records": 3, "max_validation_records": 2, "max_input_characters": 100, "seed": 17}
        for name, split in (("train", "train"), ("validation", "development"), ("heldout", "test")):
            path = root / (name + ".jsonl")
            rows = [{"note_id": name + str(i), "source_group": name + str(i), "text": name + " fixture " + str(i), "source": "synthetic", "language": "en", "split": split, "reference_titles": ["Useful Fixture Title"]} for i in range(4)]
            path.write_text("".join(json.dumps(r) + "\n" for r in rows))
            config[{"train": "train_files", "validation": "validation_files", "heldout": "heldout_files"}[name]] = [str(path)]
        return config

    def test_prepare_bounded_masked_messages_and_resume(self):
        with tempfile.TemporaryDirectory() as root:
            root = Path(root); config = self.setup_files(root)
            out = root / "output"
            stdout = io.StringIO()
            with contextlib.redirect_stdout(stdout):
                result = prepare_training(config, {"system": "Name note"}, out)
            self.assertEqual(stdout.getvalue(), "")
            self.assertEqual(result["train_records"], 3)
            self.assertEqual(result["validation_records"], 2)
            rows = [json.loads(line) for line in (out / "data/train.jsonl").read_text().splitlines()]
            self.assertTrue(all(r["messages"][-1]["role"] == "assistant" for r in rows))
            self.assertEqual(result, prepare_training(config, {"system": "Name note"}, out))
            (out / "data/train.jsonl").write_text("changed")
            with self.assertRaisesRegex(ValueError, "preparation_changed"):
                prepare_training(config, {"system": "Name note"}, out)

    def test_groups_and_content_cannot_cross_splits(self):
        for field in ("text", "source_group", "note_id"):
            with self.subTest(field=field), tempfile.TemporaryDirectory() as root:
                root = Path(root); config = self.setup_files(root)
                path = Path(config["validation_files"][0]); rows = [json.loads(l) for l in path.read_text().splitlines()]
                train_first = json.loads(Path(config["train_files"][0]).read_text().splitlines()[0])
                rows[0][field] = train_first[field]
                path.write_text("".join(json.dumps(r) + "\n" for r in rows))
                with self.assertRaisesRegex(ValueError, "training_split_leakage"):
                    prepare_training(config, {}, root / "out")

    def test_private_paths_rejected_before_read(self):
        with tempfile.TemporaryDirectory() as root:
            root = Path(root); config = self.setup_files(root)
            config["train_files"] = [str(root / "private/never-open.jsonl")]
            with self.assertRaisesRegex(ValueError, "private_training_not_selected"):
                prepare_training(config, {}, root / "out")

    def test_unsafe_targets_excluded_and_training_options_mask_prompt(self):
        with tempfile.TemporaryDirectory() as root:
            root = Path(root); config = self.setup_files(root)
            path = Path(config["train_files"][0]); rows = [json.loads(l) for l in path.read_text().splitlines()]
            rows[0]["reference_titles"] = ["One"]
            path.write_text("".join(json.dumps(r) + "\n" for r in rows))
            result = prepare_training(config, {}, root / "out")
            self.assertEqual(result["counts"]["train_files_ineligible_target"], 1)
            options = _training_options({"hyperparameters": {"iters": 10, "gradient_checkpoint": True}}, root, root / "out")
            self.assertTrue(options["mask_prompt"])
            self.assertFalse(options["test"])
            self.assertEqual(options["fine_tune_type"], "lora")
            self.assertEqual(options["iters"], 10)
            self.assertTrue(options["grad_checkpoint"])
            with self.assertRaisesRegex(ValueError, "required_or_unknown"):
                _training_options({"hyperparameters": {"arbitrary_code": 1}}, root, root)


    def test_training_child_logs_are_protected_and_adapter_resume_detects_tamper(self):
        with tempfile.TemporaryDirectory() as root:
            root = Path(root)
            config = self.setup_files(root)
            local = root / "model"; local.mkdir()
            (local / "config.json").write_text('{"quantization": {"bits": 4}}')
            (local / "model.safetensors").write_bytes(b"fake local weights")
            register_model(local, "fixture/model", "a" * 40)
            config.update(model={"model_id": "fixture/model", "revision": "a" * 40, "local_path": str(local)}, hyperparameters={"iters": 1})
            out = root / "out"
            prepare_training(config, {}, out)
            def fake_process(command, **kwargs):
                self.assertEqual(kwargs["env"]["HF_HUB_OFFLINE"], "1")
                self.assertIn("PYTHONPATH", kwargs["env"])
                kwargs["stdout"].write("protected synthetic diagnostic")
                adapter = out / "adapter"; adapter.mkdir()
                (adapter / "adapters.safetensors").write_bytes(b"synthetic adapter")
                (adapter / "adapter_config.json").write_text("{}")
                return subprocess.CompletedProcess(command, 0)
            with patch("title_eval.training.subprocess.run", side_effect=fake_process):
                result = train(config, out)
            self.assertEqual(result["status"], "complete")
            self.assertEqual((out / "protected-training.log").stat().st_mode & 0o777, 0o600)
            self.assertEqual(train(config, out), result)
            (out / "adapter/adapters.safetensors").write_bytes(b"tampered")
            with self.assertRaisesRegex(ValueError, "training_adapter_changed"):
                train(config, out)

    def test_training_worker_failure_does_not_expose_log_contents(self):
        with tempfile.TemporaryDirectory() as root:
            root = Path(root); config = self.setup_files(root)
            local = root / "model"; local.mkdir()
            (local / "config.json").write_text('{"quantization": {"bits": 4}}')
            (local / "model.safetensors").write_bytes(b"fake local weights")
            register_model(local, "fixture/model", "a" * 40)
            config.update(model={"model_id": "fixture/model", "revision": "a" * 40, "local_path": str(local)}, hyperparameters={"iters": 1})
            out = root / "out"; prepare_training(config, {}, out)
            with patch("title_eval.training.subprocess.run", side_effect=RuntimeError("sensitive synthetic content")):
                result = train(config, out)
            self.assertEqual(result["error_code"], "training_process_failed")
            self.assertNotIn("sensitive", json.dumps(result))


    def mixed_files(self, root):
        rows = []
        for group in range(50):
            for part in range(2):
                rows.append({"note_id": f"train-{group}-{part}", "source_group": f"group-{group}", "text": f"Training content {group} part {part}", "source": "synthetic", "language": "en", "split": "train", "reference_titles": ["Useful Target Title"]})
        rows += [{"note_id": "dev1", "source_group": "devgroup", "text": "Development fixture", "source": "synthetic", "split": "development", "reference_titles": ["Development Target"]}, {"note_id": "test1", "source_group": "testgroup", "text": "Test fixture", "source": "synthetic", "split": "test", "reference_titles": ["Test Target"]}]
        source = root / "mixed.jsonl"
        source.write_text("".join(json.dumps(r) + "\n" for r in rows))
        heldout = root / "heldout.jsonl"
        heldout.write_text(json.dumps(rows[-1]) + "\n")
        return {"source_files": [str(source)], "heldout_files": [str(heldout)], "validation_fraction": 0.3, "seed": 17, "max_train_records": 20, "max_validation_records": 10}

    def test_mixed_sources_filter_train_and_hold_groups_together(self):
        with tempfile.TemporaryDirectory() as root:
            root = Path(root); config = self.mixed_files(root); out = root / "out"
            result = prepare_training(config, {}, out)
            self.assertEqual(result["source_splits"]["counts"]["excluded_nontrain"], 2)
            train_rows = [json.loads(line) for line in (out / "source-train.jsonl").read_text().splitlines()]
            valid_rows = [json.loads(line) for line in (out / "source-validation.jsonl").read_text().splitlines()]
            self.assertEqual(len(train_rows) + len(valid_rows), 100)
            self.assertFalse({r["source_group"] for r in train_rows} & {r["source_group"] for r in valid_rows})
            self.assertTrue(all(r["split"] == "train" for r in train_rows))
            self.assertEqual(result, prepare_training(config, {}, out))
            self.assertEqual(result["config"], config)
            self.assertEqual(result["train_records"], 20)
            self.assertEqual(result["validation_records"], 10)

    def test_mixed_sources_detect_source_and_external_heldout_leakage(self):
        for internal in (True, False):
            with self.subTest(internal=internal), tempfile.TemporaryDirectory() as root:
                root = Path(root); config = self.mixed_files(root)
                source = Path(config["source_files"][0]); rows = [json.loads(line) for line in source.read_text().splitlines()]
                leaked = dict(rows[0], split="test", note_id="new-id")
                if internal:
                    source.write_text(source.read_text() + json.dumps(leaked) + "\n")
                    expected = "training_source_split_leakage"
                else:
                    Path(config["heldout_files"][0]).write_text(json.dumps(leaked) + "\n")
                    expected = "training_split_leakage"
                with self.assertRaisesRegex(ValueError, expected):
                    prepare_training(config, {}, root / "out")

    def test_mixed_source_changes_cannot_silently_resume(self):
        with tempfile.TemporaryDirectory() as root:
            root = Path(root); config = self.mixed_files(root); out = root / "out"
            prepare_training(config, {}, out)
            source = Path(config["source_files"][0]); source.write_text(source.read_text() + "\n")
            with self.assertRaisesRegex(ValueError, "training_source_identity_changed"):
                prepare_training(config, {}, out)


    def test_worker_uses_safe_local_load_exact_template_and_numeric_callbacks(self):
        with tempfile.TemporaryDirectory() as root:
            root = Path(root); data = root / "data"; data.mkdir()
            messages = [{"role": "user", "content": "Synthetic fixture"}, {"role": "assistant", "content": "Useful Target"}]
            for name in ("train.jsonl", "valid.jsonl"):
                (data / name).write_text(json.dumps({"messages": messages}) + "\n")
            config = {"model": str(root / "fixture-model"), "data": str(data), "mask_prompt": True, "max_seq_length": 100, "seed": 17}
            config_path = root / "trainer-config.json"; config_path.write_text(json.dumps(config))
            calls = {}
            class Tokenizer:
                chat_template = "fixture template"
                def apply_chat_template(self, rows, tokenize=True):
                    calls["template"] = self.chat_template
                    return [1, 2, 3]
            tokenizer = Tokenizer()
            def local_tokenizer(path, **kwargs):
                calls["tokenizer_options"] = kwargs
                return tokenizer
            def load(path, **kwargs):
                calls["load_options"] = kwargs
                return "synthetic-model", None
            def load_dataset(args, actual_tokenizer):
                self.assertTrue(args.mask_prompt)
                self.assertIs(actual_tokenizer, tokenizer)
                return [messages], [messages], []
            def train_model(args, model, train_rows, valid_rows, callback):
                calls["trained"] = True
                callback.on_train_loss_report({"iteration": 1, "train_loss": 0.5, "sensitive": "never logged"})
                callback.on_val_loss_report({"iteration": 1, "val_loss": 0.7})
            core = types.ModuleType("mlx.core"); core.random = types.SimpleNamespace(seed=lambda value: None); core.get_peak_memory = lambda: 128
            mlx = types.ModuleType("mlx"); mlx.__path__ = []; mlx.core = core
            lora = types.ModuleType("mlx_lm.lora"); lora.CONFIG_DEFAULTS = {"mask_prompt": False}; lora.train_model = train_model
            lm = types.ModuleType("mlx_lm"); lm.__path__ = []; lm.lora = lora; lm.load = load
            tuner = types.ModuleType("mlx_lm.tuner"); tuner.__path__ = []
            datasets = types.ModuleType("mlx_lm.tuner.datasets"); datasets.load_dataset = load_dataset
            numpy = types.ModuleType("numpy"); numpy.random = types.SimpleNamespace(seed=lambda value: None)
            transformers = types.ModuleType("transformers"); transformers.AutoTokenizer = types.SimpleNamespace(from_pretrained=local_tokenizer)
            modules = {"mlx": mlx, "mlx.core": core, "mlx_lm": lm, "mlx_lm.lora": lora, "mlx_lm.tuner": tuner, "mlx_lm.tuner.datasets": datasets, "numpy": numpy, "transformers": transformers}
            with patch.dict("sys.modules", modules):
                _worker(config_path)
            self.assertTrue(calls["trained"])
            self.assertEqual(calls["load_options"]["tokenizer_config"], {"trust_remote_code": False})
            self.assertTrue(calls["tokenizer_options"]["local_files_only"])
            self.assertTrue(calls["template"].startswith("{% set enable_thinking = false %}"))
            curves = (root / "curves.jsonl").read_text()
            self.assertNotIn("sensitive", curves)
            self.assertNotIn("never logged", curves)
            self.assertEqual(json.loads((root / "worker-summary.json").read_text())["mlx_peak_bytes"], 128)


if __name__ == "__main__":
    unittest.main()
