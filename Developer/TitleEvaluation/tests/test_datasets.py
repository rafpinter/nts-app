import hashlib
import json
from pathlib import Path
import tempfile
import unittest

from title_eval.datasets import DatasetError, load_dataset, synthetic_records


class DatasetTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name) / 'rows.jsonl'
        self.rows = synthetic_records()
        self.write(self.path, self.rows)

    def write(self, path, rows):
        path.write_text(''.join(json.dumps(r) + '\n' for r in rows))

    def config(self, **kwargs):
        return dict(path=str(self.path), split='development', **kwargs)

    def test_schema_audit_no_content_and_digest_change(self):
        rows, audit = load_dataset(self.config())
        self.assertEqual(len(rows), 4)
        self.assertNotIn('text', json.dumps(audit))
        self.assertNotIn('note_id', json.dumps(audit))
        previous = audit['dataset_hash']
        self.rows[0]['reference_titles'] = ['Another Reference']
        self.write(self.path, self.rows)
        self.assertNotEqual(load_dataset(self.config())[1]['dataset_hash'], previous)
        with self.assertRaisesRegex(DatasetError, 'dataset_identity_changed'):
            load_dataset(self.config(expected_sha256=previous))

    def test_duplicates_split_and_budget_fail_closed(self):
        self.write(self.path, self.rows + [self.rows[0]])
        with self.assertRaisesRegex(DatasetError, 'duplicate_dataset_input'):
            load_dataset(self.config())
        self.write(self.path, self.rows)
        with self.assertRaisesRegex(DatasetError, 'explicit_budget'):
            load_dataset(self.config(max_records=2))
        with self.assertRaisesRegex(DatasetError, 'unexpected_dataset_split'):
            load_dataset(dict(path=str(self.path), split='test'))

    def test_cross_split_overlap_and_manifest_completion(self):
        other = self.path.with_name('heldout.jsonl')
        self.write(other, [dict(self.rows[0], note_id='other', split='test')])
        with self.assertRaisesRegex(DatasetError, 'cross_split_overlap'):
            load_dataset(self.config(holdout_paths=[str(other)]))
        manifest = self.path.with_name('manifest.json')
        manifest.write_text('{"status":"incomplete"}')
        with self.assertRaisesRegex(DatasetError, 'snapshot_not_complete'):
            load_dataset(self.config(manifest_path=str(manifest)))

    def test_protected_path_rejected_before_open_and_redacted_errors(self):
        protected = self.path.parent / 'private' / 'not-a-real-dataset.jsonl'
        with self.assertRaisesRegex(DatasetError, '^private_dataset_not_enabled$'):
            load_dataset(dict(path=str(protected), split='development'))
        self.path.write_text('{"secret-value": broken json}')
        with self.assertRaisesRegex(DatasetError, '^dataset_read_failed$'):
            load_dataset(self.config())

    def test_content_hash_checked(self):
        self.rows[0]['content_sha256'] = '0' * 64
        self.write(self.path, self.rows)
        with self.assertRaisesRegex(DatasetError, '^content_hash_mismatch$'):
            load_dataset(self.config())
