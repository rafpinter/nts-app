"""Strict, content-free experiment configuration and deterministic matrix expansion."""
from __future__ import annotations

from copy import deepcopy
import hashlib
import itertools
import json
import math
from pathlib import Path
import re
from urllib.parse import urlparse

from .production import production_configuration


class ConfigurationError(ValueError):
    pass


def _mapping(value, label, allowed):
    if not isinstance(value, dict) or any(not isinstance(k, str) for k in value):
        raise ConfigurationError(f'{label} must be a mapping')
    if set(value) - set(allowed):
        raise ConfigurationError(f'{label} contains unsupported keys')
    return value


def _integer(value, label, minimum=1, maximum=None):
    if type(value) is not int or value < minimum or (maximum is not None and value > maximum):
        raise ConfigurationError(f'{label} must be an integer within its documented limits')
    return value


def _number(value, label, low, high):
    if type(value) not in (int, float) or not math.isfinite(value) or not low <= value <= high:
        raise ConfigurationError(f'{label} must be a finite number within its documented limits')
    return value


def _boolean(value, label):
    if type(value) is not bool:
        raise ConfigurationError(f'{label} must be true or false')
    return value


def _name(value, label):
    if not isinstance(value, str) or not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.-]{0,79}', value):
        raise ConfigurationError(f'{label} must be a simple name of at most 80 characters')
    return value


def _path(value, parent):
    if not isinstance(value, str) or not value.strip():
        raise ConfigurationError('Paths must be nonempty strings')
    return str((parent / Path(value).expanduser()).resolve())


def _paths(values, parent):
    if not isinstance(values, list):
        raise ConfigurationError('File selections must be lists')
    return [_path(value, parent) for value in values]


def _safe_load(path):
    try:
        import yaml
    except ImportError:
        raise ConfigurationError('Install requirements-core.txt to read experiments.yaml') from None

    class UniqueLoader(yaml.SafeLoader):
        pass

    def mapping(loader, node, deep=False):
        result = {}
        for key_node, value_node in node.value:
            key = loader.construct_object(key_node, deep=deep)
            if not isinstance(key, str) or key in result:
                raise ConfigurationError('YAML contains duplicate or unsupported mapping keys')
            result[key] = loader.construct_object(value_node, deep=deep)
        return result

    UniqueLoader.add_constructor(yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG, mapping)
    try:
        return yaml.load(path.read_text(encoding='utf-8'), Loader=UniqueLoader)
    except ConfigurationError:
        raise
    except (yaml.YAMLError, OSError, UnicodeError):
        raise ConfigurationError('Unable to read valid experiment YAML') from None


def _generation(values, allow_lists=False):
    allowed = {'temperature', 'top_p', 'top_k', 'max_output_tokens', 'max_input_characters', 'max_attempts', 'enable_thinking'}
    _mapping(values, 'generation', allowed)
    for key, value in values.items():
        items = value if isinstance(value, list) and allow_lists else [value]
        if not items:
            raise ConfigurationError('Sampling grids cannot be empty')
        for item in items:
            if key == 'temperature':
                _number(item, key, 0, 2)
            elif key == 'top_p':
                _number(item, key, 0.000001, 1)
            elif key == 'top_k':
                if item is not None:
                    _integer(item, key, 1)
            elif key == 'max_output_tokens':
                _integer(item, key, 1, 512)
            elif key == 'max_input_characters':
                _integer(item, key, 1, 16000)
            elif key == 'max_attempts':
                _integer(item, key, 1, 5)
            else:
                _boolean(item, key)
    return values


def _seeds(values):
    if not isinstance(values, list) or not values or len(set(map(str, values))) != len(values):
        raise ConfigurationError('seeds must be a nonempty unique list')
    return [_integer(value, 'seed', 0, 2**32 - 1) for value in values]


def load_config(path: Path) -> dict:
    path = Path(path).resolve()
    config = _safe_load(path)
    _mapping(config, 'configuration', {'schema_version','dataset','output_dir','models','configurations','seeds','training','scoring','tracking','limits'})
    if config.get('schema_version', 1) != 1 or type(config.get('schema_version', 1)) is not int:
        raise ConfigurationError('Unsupported configuration schema version')
    for required in ('dataset','output_dir','models','configurations'):
        if required not in config:
            raise ConfigurationError(f'Missing required section: {required}')
    parent = path.parent
    result = deepcopy(config)
    result['schema_version'] = 1
    result['config_path'] = str(path)
    result['output_dir'] = _path(config['output_dir'], parent)
    dataset = _mapping(result['dataset'], 'dataset', {'path','split','allow_private','manifest_path','holdout_paths','expected_sha256','max_records'})
    if 'path' not in dataset:
        raise ConfigurationError('dataset.path is required')
    dataset['path'] = _path(dataset['path'], parent)
    dataset.setdefault('split', 'development')
    if dataset['split'] not in ('development','test','synthetic'):
        raise ConfigurationError('dataset.split must be development, test or synthetic')
    dataset['allow_private'] = _boolean(dataset.get('allow_private', False), 'dataset.allow_private')
    if dataset.get('manifest_path') is not None:
        dataset['manifest_path'] = _path(dataset['manifest_path'], parent)
    dataset['holdout_paths'] = _paths(dataset.get('holdout_paths', []), parent)
    if dataset.get('expected_sha256') is not None and not re.fullmatch(r'[0-9a-f]{64}', str(dataset['expected_sha256'])):
        raise ConfigurationError('dataset.expected_sha256 must be a lowercase SHA256 digest')
    if dataset.get('max_records') is not None:
        _integer(dataset['max_records'], 'dataset.max_records')
    result['seeds'] = _seeds(config.get('seeds', [17]))
    production = production_configuration(Path(__file__).resolve().parents[3])
    result['production'] = production
    models = result['models']
    if not isinstance(models, list) or not models:
        raise ConfigurationError('models must be a nonempty list')
    names = set()
    for model in models:
        _mapping(model, 'model', {'name','enabled','model_id','revision','local_path','adapter','role','quantization','adapter_from'})
        name = _name(model.get('name'), 'model.name')
        if name in names:
            raise ConfigurationError('Model names must be unique')
        names.add(name)
        model['enabled'] = _boolean(model.get('enabled', True), 'model.enabled')
        model.setdefault('role', 'candidate')
        if model['role'] not in ('baseline','candidate','fine_tuned'):
            raise ConfigurationError('Unsupported model role')
        if not isinstance(model.get('model_id'), str) or not model['model_id'].strip():
            raise ConfigurationError('model.model_id is required')
        if not isinstance(model.get('revision'), str) or not re.fullmatch(r'[0-9a-f]{40}', model['revision']):
            raise ConfigurationError('Every model requires an immutable 40-character commit revision')
        for field in ('local_path','adapter'):
            if model.get(field) is not None:
                model[field] = _path(model[field], parent)
        if model.get('adapter') and model['role'] != 'fine_tuned':
            raise ConfigurationError('Adapter models must use the fine_tuned role')
        if model.get('adapter_from') is not None:
            if model['role'] != 'fine_tuned' or model.get('adapter'):
                raise ConfigurationError('adapter_from requires fine_tuned role and no explicit adapter')
            _name(model['adapter_from'], 'model.adapter_from')
    enabled = {m['name'] for m in models if m['enabled']}
    if not enabled:
        raise ConfigurationError('Enable at least one model')
    profiles = result['configurations']
    if not isinstance(profiles, list) or not profiles:
        raise ConfigurationError('configurations must be a nonempty list')
    profile_names = set()
    for profile in profiles:
        _mapping(profile, 'configuration profile', {'name','enabled','models','generation','grid','seeds','baseline','production'})
        name = _name(profile.get('name'), 'configuration.name')
        if name in profile_names:
            raise ConfigurationError('Configuration names must be unique')
        profile_names.add(name)
        profile['enabled'] = _boolean(profile.get('enabled', True), 'configuration.enabled')
        profile['baseline'] = _boolean(profile.get('baseline', False), 'configuration.baseline')
        profile['production'] = _boolean(profile.get('production', False), 'configuration.production')
        selected = profile.get('models', sorted(enabled))
        if not isinstance(selected, list) or not selected or any(not isinstance(m, str) or m not in names for m in selected) or len(set(selected)) != len(selected):
            raise ConfigurationError('Configuration model selections must be unique known model names')
        profile['models'] = selected
        profile['seeds'] = _seeds(profile.get('seeds', result['seeds']))
        profile['generation'] = _generation(profile.get('generation', {}), True)
        profile['grid'] = _generation(profile.get('grid', {}), True)
        if set(profile['generation']) & set(profile['grid']):
            raise ConfigurationError('A generation key cannot also appear in grid')
        if profile['production'] and (profile['generation'] or profile['grid']):
            raise ConfigurationError('Production controls cannot override generation settings')
    training = result.get('training', [])
    if not isinstance(training, list):
        raise ConfigurationError('training must be a list of named jobs')
    train_names = set()
    for job in training:
        _mapping(job, 'training job', {'enabled','name','model','train_files','validation_files','heldout_files','max_train_records','max_validation_records','seed','hyperparameters','max_input_characters','timeout_seconds','method','allow_private','source_files','validation_fraction','max_validation_records'})
        name = _name(job.get('name'), 'training.name')
        if name in train_names:
            raise ConfigurationError('Training names must be unique')
        train_names.add(name)
        job['enabled'] = _boolean(job.get('enabled', False), 'training.enabled')
        if job.get('model') not in names:
            raise ConfigurationError('Training job refers to unknown model')
        job['model_name'] = job['model']
        job['model'] = deepcopy(next(m for m in models if m['name'] == job['model_name']))
        if job['model']['role'] == 'fine_tuned':
            raise ConfigurationError('Training must start from an unadapted base model')
        for field in ('train_files','validation_files','heldout_files','source_files'):
            job[field] = _paths(job.get(field, []), parent)
        if job['source_files'] and (job['train_files'] or job['validation_files']):
            raise ConfigurationError('Choose training source_files or explicit train_files/validation_files')
        if job['enabled'] and not (job['source_files'] or (job['train_files'] and job['validation_files'])):
            raise ConfigurationError('Enabled training requires source_files or training and validation files')
        if job['enabled'] and not job['heldout_files']:
            raise ConfigurationError('Enabled training requires explicit held-out files')
        job['validation_fraction'] = _number(job.get('validation_fraction',0.1),'training.validation_fraction',0.01,0.5)
        job['max_validation_records'] = _integer(job.get('max_validation_records',120),'training.max_validation_records')
        job['seed'] = _integer(job.get('seed', 17), 'training.seed', 0, 2**32-1)
        job['max_input_characters'] = _integer(job.get('max_input_characters', production['generation']['max_input_characters']), 'training.max_input_characters', 1, 16000)
        job['max_train_records'] = _integer(job.get('max_train_records', 1000), 'training.max_train_records')
        job['max_validation_records'] = _integer(job.get('max_validation_records', 120), 'training.max_validation_records')
        job['allow_private'] = _boolean(job.get('allow_private', False), 'training.allow_private')
        job['timeout_seconds'] = _integer(job.get('timeout_seconds', 3600), 'training.timeout_seconds')
        job['method'] = job.get('method', 'qlora')
        if job['method'] != 'qlora':
            raise ConfigurationError('Only qlora training is implemented')
        _mapping(job.setdefault('hyperparameters', {}), 'training.hyperparameters', {'batch_size','num_layers','iters','learning_rate','steps_per_report','steps_per_eval','val_batches','save_every','max_seq_length','grad_accumulation_steps','lora_rank','lora_scale','lora_dropout','gradient_checkpoint'})
        for key, value in job['hyperparameters'].items():
            if key in ('learning_rate','lora_scale'):
                _number(value,key,0.000000001,100)
            elif key == 'lora_dropout':
                _number(value,key,0,0.99)
            elif key == 'gradient_checkpoint':
                _boolean(value,key)
            else:
                _integer(value,key)
    result['training'] = training
    for model in models:
        if model.get('adapter_from') is not None:
            if model.get('adapter') or model['role'] != 'fine_tuned':
                raise ConfigurationError('adapter_from requires fine_tuned role and no explicit adapter')
            if model['adapter_from'] not in train_names:
                raise ConfigurationError('Model adapter_from refers to unknown training job')
            job = next(j for j in training if j['name'] == model['adapter_from'])
            if any(model[k] != job['model'][k] for k in ('model_id','revision')):
                raise ConfigurationError('Adapter training base must match evaluation model')
    scoring = _mapping(result.setdefault('scoring', {}), 'scoring', {'bertscore','bootstrap_resamples','bootstrap_seed'})
    scoring.setdefault('bootstrap_resamples', 10000)
    scoring.setdefault('bootstrap_seed', 17)
    _integer(scoring['bootstrap_resamples'],'scoring.bootstrap_resamples',1,1000000)
    _integer(scoring['bootstrap_seed'],'scoring.bootstrap_seed',0,2**32-1)
    bert = _mapping(scoring.setdefault('bertscore', {}), 'scoring.bertscore', {'enabled','model_path','model_revision','num_layers','idf','rescale_with_baseline','batch_size','model_sha256','device'})
    bert['enabled'] = _boolean(bert.get('enabled', False),'bertscore.enabled')
    for key in ('idf','rescale_with_baseline'):
        bert[key] = _boolean(bert.get(key,False),key)
        if bert[key]:
            raise ConfigurationError('BERTScore IDF and rescaling are not supported by this scorer')
    if bert.get('model_path'):
        bert['model_path'] = _path(bert['model_path'],parent)
    if bert['enabled'] and (not bert.get('model_path') or not re.fullmatch(r'[0-9a-f]{64}',str(bert.get('model_sha256',''))) or 'num_layers' not in bert):
        raise ConfigurationError('BERTScore requires a local model path, model_sha256 and num_layers')
    if 'num_layers' in bert:
        _integer(bert['num_layers'],'bertscore.num_layers')
    bert['batch_size'] = _integer(bert.get('batch_size',16),'bertscore.batch_size')
    tracking = _mapping(result.setdefault('tracking', {}),'tracking',{'enabled','uri','experiment_name','artifact_root'})
    tracking['enabled'] = _boolean(tracking.get('enabled',False),'tracking.enabled')
    tracking.setdefault('experiment_name','title-generation')
    if not isinstance(tracking['experiment_name'],str) or not tracking['experiment_name'].strip():
        raise ConfigurationError('tracking.experiment_name must be nonempty')
    uri = tracking.get('uri', 'sqlite:///' + str(Path(result['output_dir']) / 'mlflow.db'))
    if not isinstance(uri,str):
        raise ConfigurationError('tracking.uri must be a local URI')
    if uri.startswith('sqlite:///'):
        uri = 'sqlite:///' + _path(uri[len('sqlite:///'):],parent)
    else:
        parsed = urlparse(uri)
        if parsed.scheme not in ('http','https') or parsed.hostname not in ('localhost','127.0.0.1','::1') or parsed.username or parsed.password:
            raise ConfigurationError('MLflow tracking must use local SQLite or a loopback server')
    tracking['uri'] = uri
    if tracking.get('artifact_root'):
        tracking['artifact_root'] = _path(tracking['artifact_root'],parent)
    limits = _mapping(result.setdefault('limits', {}),'limits',{'max_runs','max_attempts_total','timeout_seconds','attempt_timeout_seconds'})
    limits['max_runs'] = _integer(limits.get('max_runs',100),'limits.max_runs')
    limits['max_attempts_total'] = _integer(limits.get('max_attempts_total',100000),'limits.max_attempts_total')
    limits['timeout_seconds'] = _integer(limits.get('timeout_seconds',3600),'limits.timeout_seconds')
    limits['attempt_timeout_seconds'] = _integer(limits.get('attempt_timeout_seconds',120),'limits.attempt_timeout_seconds')
    expand_runs(result)
    return result


def expand_runs(config: dict) -> list[dict]:
    """Expand enabled combinations; no dataset/model content is accessed."""
    defaults = config['production']['generation']
    result = []
    seen = set()
    for profile in config['configurations']:
        if not profile.get('enabled', True):
            continue
        generation = deepcopy(defaults)
        generation.update(profile.get('generation', {}))
        generation.update(profile.get('grid', {}))
        keys = sorted(generation)
        combinations = itertools.product(*(generation[key] if isinstance(generation[key],list) else [generation[key]] for key in keys))
        for values in combinations:
            effective = dict(zip(keys,values))
            if effective['temperature'] == 0 and (effective['top_p'] != 1 or effective['top_k'] is not None):
                raise ConfigurationError('Greedy temperature zero requires top_p 1 and top_k null')
            for model in config['models']:
                if not model.get('enabled',True) or model['name'] not in profile['models']:
                    continue
                for seed in profile['seeds']:
                    effective_model = deepcopy(model)
                    if effective_model.get('adapter_from'):
                        effective_model['adapter'] = str(Path(config['output_dir']) / 'training' / effective_model['adapter_from'] / 'adapter')
                    identity = {'model':{k:v for k,v in effective_model.items() if k != 'enabled'},'generation':effective,'seed':seed,
                                'prompt_fingerprint':config['production']['fingerprint']}
                    digest = hashlib.sha256(json.dumps(identity,sort_keys=True,separators=(',',':')).encode()).hexdigest()
                    if digest in seen:
                        raise ConfigurationError('Enabled profiles contain duplicate effective runs')
                    seen.add(digest)
                    label = f"{model['name']}-{profile['name']}-t{effective['temperature']}-p{effective['top_p']}-k{effective['top_k'] or 'off'}-s{seed}"
                    run = {'id':digest[:16],'name':label,'model':effective_model,'generation':deepcopy(effective),'seed':seed,
                           'configuration_name':profile['name'],'baseline':profile.get('baseline',False)}
                    if run['baseline'] and (model['model_id'] != config['production']['model']['model_id'] or model['revision'] != config['production']['model']['revision'] or model['role'] != 'baseline' or model.get('adapter') or model.get('adapter_from') or effective != defaults):
                        raise ConfigurationError('Baseline control must be an unadapted baseline model at production settings')
                    result.append(run)
                    if len(result) > config.get('limits', {}).get('max_runs', 100):
                        raise ConfigurationError('Expanded matrix exceeds limits.max_runs')
    if not result:
        raise ConfigurationError('Enable at least one runnable configuration')
    if len(result)>config.get('limits',{}).get('max_runs',100):
        raise ConfigurationError('Expanded matrix exceeds limits.max_runs')
    baselines = [r for r in result if r['baseline']]
    if not baselines:
        raise ConfigurationError('Enable a production baseline control')
    if len({r['model']['name'] for r in baselines}) != 1:
        raise ConfigurationError('Baseline control must use one baseline model')
    return result
