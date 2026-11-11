import json
from pathlib import Path
import tempfile
import unittest

from title_eval.config import ConfigurationError, expand_runs, load_config

REVISION = '73e3e38d981303bc594367cd910ea6eb48349da8'


def sample():
    return {
        'dataset': {'path':'synthetic.jsonl','split':'synthetic'}, 'output_dir':'results',
        'models':[{'name':'qwen','model_id':'mlx-community/Qwen3-0.6B-4bit','revision':REVISION,'role':'baseline'}],
        'configurations':[{'name':'control','production':True,'baseline':True,'models':['qwen']}],
    }


class ConfigurationTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.path = Path(self.directory.name)/'experiments.yaml'

    def load(self, config):
        self.path.write_text(json.dumps(config))  # JSON is a YAML subset.
        return load_config(self.path)

    def test_production_control_and_relative_paths(self):
        config = self.load(sample())
        self.assertEqual(config['dataset']['path'],str((self.path.parent/'synthetic.jsonl').resolve()))
        run = expand_runs(config)[0]
        self.assertEqual(run['generation']['temperature'],0.5)
        self.assertEqual(run['generation']['top_p'],0.9)
        self.assertTrue(run['baseline'])
        self.assertEqual(run['id'],expand_runs(self.load(sample()))[0]['id'])

    def test_grid_expands_models_settings_and_seeds(self):
        config = sample()
        config['models'].append({'name':'candidate','model_id':'other/model','revision':'a'*40})
        config['configurations'].append({'name':'sweep','models':['candidate'],
            'generation':{'temperature':[0.2,0.8],'top_p':[0.9,1.0],'top_k':[None,20]},'seeds':[17,43]})
        runs = expand_runs(self.load(config))
        self.assertEqual(len(runs),17)
        self.assertEqual(len({r['id'] for r in runs}),17)

    def test_duplicate_keys_rejected(self):
        self.path.write_text('dataset: {}\ndataset: {}\n')
        with self.assertRaises(ConfigurationError):
            load_config(self.path)

    def test_invalid_values_rejected(self):
        for values in ({'temperature':True},{'temperature':float('nan')},{'top_p':0},
                       {'top_k':0},{'max_attempts':6},{'unknown':0.5}):
            config = sample()
            config['configurations'].append({'name':'bad','generation':values})
            with self.subTest(values=values), self.assertRaises(ConfigurationError):
                self.load(config)

    def test_unknown_keys_and_references_rejected(self):
        config = sample(); config['typo'] = True
        with self.assertRaises(ConfigurationError): self.load(config)
        config = sample(); config['configurations'][0]['models']=['unknown']
        with self.assertRaises(ConfigurationError): self.load(config)
        config = sample(); config['models'][0]['revision']='main'
        with self.assertRaises(ConfigurationError): self.load(config)

    def test_duplicate_effective_runs_and_resource_limits(self):
        config = sample(); config['configurations'].append({'name':'another','production':True})
        with self.assertRaises(ConfigurationError): self.load(config)
        config = sample(); config['limits']={'max_runs':1}
        config['configurations'].append({'name':'sweep','generation':{'temperature':0.8}})
        with self.assertRaises(ConfigurationError): self.load(config)

    def test_baseline_cannot_be_adapted_or_changed(self):
        config = sample(); config['models'][0]['adapter']='adapter'
        with self.assertRaises(ConfigurationError): self.load(config)
        config = sample(); config['configurations'][0].pop('production')
        config['configurations'][0]['generation']={'temperature':0.8}
        with self.assertRaises(ConfigurationError): self.load(config)

    def test_remote_tracking_rejected(self):
        for uri in ['https://example.org','file:///tmp/mlflow','http://localhost.evil.org:5000']:
            config=sample(); config['tracking']={'uri':uri}
            with self.subTest(uri=uri),self.assertRaises(ConfigurationError):self.load(config)

    def test_unsupported_bertscore_settings(self):
        config=sample();config['scoring']={'bertscore':{'idf':True}}
        with self.assertRaises(ConfigurationError):self.load(config)
        config=sample();config['scoring']={'bertscore':{'enabled':True,'model_path':'encoder'}}
        with self.assertRaises(ConfigurationError):self.load(config)

    def test_adapter_training_link(self):
        config=sample()
        config['training']=[{'name':'train','model':'qwen','enabled':False}]
        config['models'].append({'name':'trained','model_id':'mlx-community/Qwen3-0.6B-4bit',
            'revision':REVISION,'role':'fine_tuned','adapter_from':'train'})
        config['configurations'].append({'name':'trained-control','models':['trained'],'production':True})
        loaded=self.load(config);run=expand_runs(loaded)[1]
        self.assertEqual(run['model']['adapter'],str((self.path.parent/'results/training/train/adapter').resolve()))

    def test_template_loads_without_data(self):
        path=Path(__file__).resolve().parents[1]/'experiments.example.yaml'
        config=load_config(path)
        self.assertEqual(len(expand_runs(config)),1)


if __name__ == '__main__':
    unittest.main()
