"""Dev-only offline PyTorch parity check for the evaluator's synthetic report."""
import argparse
import json
import os
from pathlib import Path
import time

os.environ['HF_HUB_OFFLINE'] = '1'
os.environ['TRANSFORMERS_OFFLINE'] = '1'
os.environ['TOKENIZERS_PARALLELISM'] = 'false'

import numpy as np
import torch
from transformers import AutoModel, AutoTokenizer


def check(report_path: Path):
    report = json.loads(report_path.read_text())
    config = report['configuration']
    directory = Path(report['artifactDirectory'])
    provenance = json.loads((directory / 'embedding-artifact.json').read_text())
    assert provenance['revision'] == config['revision']
    torch.set_num_threads(2)
    started = time.perf_counter()
    tokenizer = AutoTokenizer.from_pretrained(directory, local_files_only=True)
    model = AutoModel.from_pretrained(directory, local_files_only=True, dtype=torch.float32).eval()
    max_error = 0.0
    min_cosine = 1.0
    compared = 0
    for result in report['results']:
        text = result['fixture']['text']
        prefix = tokenizer.encode(config['prefix'].rstrip(), add_special_tokens=False)
        complete = tokenizer.encode(config['prefix'] + text, add_special_tokens=False)
        assert complete[:len(prefix)] == prefix
        content = complete[len(prefix):]
        assert content == result['embedding']['contentIDs'], f"Content tokenizer mismatch: {result['fixture']['name']}"
        assert prefix == result['embedding']['prefixIDs'], 'Prefix tokenizer mismatch'
        accumulated = np.zeros(config['dimensions'], dtype=np.float64)
        chunks = result['embedding']['chunks']
        expected_count = (len(content) + config['contentTokensPerChunk'] - 1) // config['contentTokensPerChunk']
        assert len(chunks) == expected_count
        for index, chunk in enumerate(chunks):
            offset = index * config['contentTokensPerChunk']
            part = content[offset:offset + config['contentTokensPerChunk']]
            ids = [tokenizer.bos_token_id] + prefix + part + [tokenizer.eos_token_id]
            assert ids == chunk['inputIDs'], 'Token windows or special-token wrapping differ'
            assert len(part) == chunk['contentTokens']
            if expected_count == 1:
                assert ids == tokenizer.encode(config['prefix'] + text), 'Prefix concatenation differs from the model-card recipe'
            assert len(ids) <= config['maximumSequenceTokens']
            inputs = torch.tensor([ids], dtype=torch.long)
            mask = torch.ones_like(inputs)
            with torch.inference_mode():
                hidden = model(input_ids=inputs, attention_mask=mask).last_hidden_state
                pooled = (hidden * mask.unsqueeze(-1)).sum(1) / mask.sum(1, keepdim=True)
                normalized = torch.nn.functional.normalize(pooled, p=2, dim=1)[0].numpy()
            swift = np.array(chunk['vector'], dtype=np.float32)
            error = float(np.max(np.abs(swift - normalized)))
            cosine = float(np.dot(swift, normalized) / (np.linalg.norm(swift) * np.linalg.norm(normalized)))
            max_error = max(max_error, error)
            min_cosine = min(min_cosine, cosine)
            assert error < 2e-4 and cosine > 0.99999, f'Pooling/model parity failed: {error=}, {cosine=}'
            accumulated += normalized.astype(np.float64) * len(part)
            compared += 1
        expected = (accumulated / np.linalg.norm(accumulated)).astype(np.float32)
        actual = np.array(result['embedding']['vector'], dtype=np.float32)
        error = float(np.max(np.abs(expected - actual)))
        max_error = max(max_error, error)
        assert error < 2e-4, f"File aggregation mismatch: {result['fixture']['name']}"
    summary = dict(passed=True, configurationHash=report['configurationHash'],
                   modelRevision=config['revision'], comparedChunks=compared,
                   cases=len(report['results']), maxAbsoluteError=max_error,
                   minimumCosine=min_cosine, seconds=time.perf_counter()-started,
                   torch=torch.__version__, transformers=__import__('transformers').__version__)
    output = report_path.with_name(report_path.stem + '-parity.json')
    output.write_text(json.dumps(summary, indent=2) + '\n')
    print(json.dumps(summary, indent=2))
    print(f'Result: {output}')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('report', type=Path)
    check(parser.parse_args().report)
