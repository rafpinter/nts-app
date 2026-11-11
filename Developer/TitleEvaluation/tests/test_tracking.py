import json
import os
from pathlib import Path
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from title_eval.tracking import track_runs, track_training, validate_tracking_uri
from title_eval.scoring import score_run
from test_scoring import fixture


class FakeClient:
    experiment = None
    calls = []
    existing = []
    def __init__(self, **kwargs):
        self.calls.append(("client", kwargs))
    def get_experiment_by_name(self, name):
        return self.experiment
    def create_experiment(self, name, artifact_location):
        type(self).experiment = SimpleNamespace(experiment_id="e", artifact_location=artifact_location)
        return "e"
    def get_experiment(self, eid):
        return self.experiment
    def search_runs(self, *args, **kwargs):
        return self.existing
    def create_run(self, *args, **kwargs):
        self.calls.append(("create", kwargs))
        return SimpleNamespace(info=SimpleNamespace(run_id="r"))
    def log_param(self, *args):
        self.calls.append(("param", args))
    def log_metric(self, *args, **kwargs):
        self.calls.append(("metric", args, kwargs))
    def log_artifact(self, rid, path):
        self.calls.append(("artifact", Path(path).read_text()))
    def set_terminated(self, *args, **kwargs):
        self.calls.append(("terminated", kwargs))


class TrackingTests(unittest.TestCase):
    def setUp(self):
        FakeClient.experiment = None
        FakeClient.calls = []
        FakeClient.existing = []

    def test_only_loopback_or_sqlite_allowed(self):
        for uri in ("sqlite:////tmp/test.db", "http://127.0.0.1:5000", "http://localhost:5000", "http://[::1]:5000"):
            self.assertEqual(validate_tracking_uri(uri), uri)
        for uri in ("https://example.com", "databricks", "http://localhost.evil:5000", "http://u:p@localhost:5000", "sqlite:///:memory:", "file:///tmp/mlruns", "http://localhost/proxy"):
            with self.assertRaises(ValueError):
                validate_tracking_uri(uri)

    def test_aggregate_only_and_telemetry_disabled(self):
        with tempfile.TemporaryDirectory() as temp, patch.dict(sys.modules, {"mlflow": SimpleNamespace(MlflowClient=FakeClient)}):
            root = Path(temp)
            fixture(root/"run")
            score_run(root/"run")
            result = track_runs([root/"run"], {"enabled":True, "uri": "sqlite:///"+str(root/"mlflow.db"), "experiment_name":"test"})
            self.assertEqual(result["logged"], 1)
            self.assertEqual(os.environ["MLFLOW_DISABLE_TELEMETRY"], "true")
            text = json.dumps(FakeClient.calls)
            self.assertNotIn("Useful Note", text)
            self.assertNotIn("Reference Title", text)
            self.assertNotIn("raw_output", text)
            self.assertIn("final_acceptance", text)
            self.assertIn("temperature", text)

    def test_finished_identity_is_idempotent(self):
        with tempfile.TemporaryDirectory() as temp, patch.dict(sys.modules, {"mlflow": SimpleNamespace(MlflowClient=FakeClient)}):
            root = Path(temp)
            fixture(root/"run")
            score_run(root/"run")
            FakeClient.existing = [SimpleNamespace(info=SimpleNamespace(status="FINISHED"))]
            result = track_runs([root/"run"], {"enabled":True,"uri":"sqlite:///"+str(root/"tracking.db")})
            self.assertEqual(result["skipped"],1)
            self.assertFalse(any(call[0]=="create" for call in FakeClient.calls))

    def test_remote_artifact_store_rejected(self):
        with tempfile.TemporaryDirectory() as temp, patch.dict(sys.modules, {"mlflow": SimpleNamespace(MlflowClient=FakeClient)}):
            root=Path(temp)
            fixture(root/"run")
            score_run(root/"run")
            FakeClient.experiment=SimpleNamespace(experiment_id="e",artifact_location="s3://remote/data")
            with self.assertRaisesRegex(ValueError,"local_mlflow_tracking_failed"):
                track_runs([root/"run"],{"enabled":True,"uri":"http://localhost:5000"})

    def test_training_logs_numeric_curves_and_lineage_only(self):
        with tempfile.TemporaryDirectory() as temp, patch.dict(sys.modules, {"mlflow": SimpleNamespace(MlflowClient=FakeClient)}):
            root=Path(temp)
            (root/"training.json").write_text(json.dumps({"identity":"train123", "status":"complete", "base_model_id":"qwen", "base_revision":"commit", "preparation_hash":"prepared", "adapter_hash":"adapter", "training_options":{"learning_rate":1e-5,"model":"SECRET_MODEL_PATH","data":"SECRET_DATA_PATH","batch_size":1}, "duration_seconds":12., "curves":[{"iteration":10,"train_loss":.9,"raw_text":"SECRET_CONTENT"},{"iteration":20,"val_loss":.8}]}))
            result=track_training([root],{"enabled":True,"uri":"sqlite:///"+str(root/"tracking.db")})
            self.assertEqual(result["logged"],1)
            calls=json.dumps(FakeClient.calls)
            self.assertNotIn("SECRET",calls)
            self.assertIn("train_loss",calls)
            self.assertIn("adapter_hash",calls)
            self.assertTrue(any(call[0]=="metric" and call[2].get("step")==10 for call in FakeClient.calls))

    def test_disabled_does_not_import_mlflow(self):
        self.assertEqual(track_runs([],{"enabled":False})["status"],"disabled")

class LocalSQLiteIntegrationTests(unittest.TestCase):
    @unittest.skipUnless(__import__('importlib').util.find_spec('mlflow'), 'optional MLflow environment not installed')
    def test_real_sqlite_tracking_and_idempotent_reimport(self):
        from title_eval.datasets import synthetic_records
        from title_eval.execution import execute_run
        from title_eval.scoring import score_run
        from title_eval.tracking import track_runs
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            run = {'id': 'sqlite-synthetic', 'name': 'sqlite-synthetic', 'seed': 17,
                   'model': {'name': 'synthetic-baseline', 'model_id': 'synthetic', 'revision': 'a' * 40},
                   'generation': {'temperature': 0.5, 'top_p': 0.9, 'top_k': None, 'max_attempts': 2,
                                  'max_input_characters': 100, 'max_output_tokens': 32, 'enable_thinking': False}}
            directory = root / 'run'
            execute_run(run, synthetic_records(), directory, {'system': 'Synthetic prompt'}, backend='synthetic')
            score_run(directory)
            config = {'enabled': True, 'uri': 'sqlite:///' + str(root / 'mlflow.db'),
                      'experiment_name': 'synthetic-integration', 'artifact_root': str(root / 'artifacts')}
            first = track_runs([directory], config)
            second = track_runs([directory], config)
            self.assertEqual(first['logged'], 1)
            self.assertEqual(second['skipped'], 1)
            from mlflow import MlflowClient
            client = MlflowClient(tracking_uri=config['uri'])
            experiment = client.get_experiment_by_name(config['experiment_name'])
            saved = client.search_runs([experiment.experiment_id])
            self.assertEqual(len(saved), 1)
            self.assertEqual(saved[0].data.metrics['expected_notes'], 4)
            self.assertEqual(saved[0].data.params['backend'], 'synthetic')
            training = root / 'training'
            training.mkdir()
            (training / 'training.json').write_text(json.dumps({
                'identity': 'synthetic-training', 'status': 'complete',
                'base_model_id': 'synthetic', 'base_revision': 'a' * 40,
                'preparation_hash': 'synthetic', 'adapter_hash': 'synthetic',
                'training_options': {'batch_size': 1, 'learning_rate': 1e-5},
                'duration_seconds': 1.0, 'curves': [{'iteration': 10, 'train_loss': 0.9}]}))
            self.assertEqual(track_training([training], config)['logged'], 1)
            self.assertEqual(track_training([training], config)['skipped'], 1)
            for artifact in (root / 'artifacts').rglob('*.json'):
                text = artifact.read_text()
                self.assertNotIn('Discuss SQLite', text)
                self.assertNotIn('Synthetic Note Title', text)


if __name__ == "__main__":
    unittest.main()
