import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[3]
ENTRY = ROOT / 'Developer/TitleEvaluation/run.py'


class CLITests(unittest.TestCase):
    def call(self, *args):
        return subprocess.run([sys.executable, str(ENTRY), *map(str, args)], capture_output=True, text=True)

    def test_init_no_overwrite_and_dry_run_does_not_need_data(self):
        with tempfile.TemporaryDirectory() as temporary:
            config = Path(temporary) / 'experiments.yaml'
            initialized = self.call('init', '--destination', config)
            self.assertEqual(initialized.returncode, 0, initialized.stderr)
            second = self.call('init', '--destination', config)
            self.assertNotEqual(second.returncode, 0)
            result = self.call('--config', config, 'dry-run')
            self.assertEqual(result.returncode, 0, result.stderr)
            data = json.loads(result.stdout)
            self.assertFalse(data['dataset_read'])
            self.assertGreater(len(data['runs']), 0)

    def test_synthetic_pipeline_and_report(self):
        with tempfile.TemporaryDirectory() as temporary:
            result = self.call('smoke', '--output', temporary)
            self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
            self.assertNotIn('Discuss SQLite', result.stdout + result.stderr)
            campaign = json.loads((Path(temporary) / 'campaign.json').read_text())
            self.assertEqual(campaign['status'], 'completed')
            reports = list((Path(temporary) / 'report').glob('*.html'))
            self.assertTrue(reports)
            self.assertNotIn('Discuss SQLite', reports[0].read_text())
            for directory in (Path(temporary) / 'runs').iterdir():
                summary = json.loads((directory / 'summary.json').read_text())
                self.assertEqual(summary['expected_notes'], 4)

    def test_timeout_retains_failure_manifest(self):
        from unittest.mock import patch
        from title_eval.cli import _isolated
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            request = {'operation': 'generate', 'run': {'id': 'x', 'name': 'x'},
                       'expected_notes': 4, 'dataset_hash': 'test'}
            class Process:
                pid = 123
                calls = 0
                def wait(self, timeout=None):
                    if timeout is not None:
                        raise subprocess.TimeoutExpired('worker', timeout)
                    return -9
            with patch('title_eval.cli.subprocess.Popen', return_value=Process()), patch('os.killpg'):
                result = _isolated(request, directory, 0.01)
            self.assertEqual(result['status'], 'timeout')
            manifest = json.loads((directory / 'manifest.json').read_text())
            self.assertEqual(manifest['expected_notes'], 4)
            self.assertEqual(manifest['status'], 'timeout')
