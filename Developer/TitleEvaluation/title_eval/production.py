"""Fail-closed export of the production Swift configuration, without running models.

The Swift source owns prompts/settings. This parser intentionally supports only
literal declarations currently used there; expressions or changed declarations
must be reviewed rather than silently producing stale benchmark settings.
"""
from __future__ import annotations

import hashlib
import json
from pathlib import Path
import re


class ProductionConfigurationError(ValueError):
    pass


def _literal(source: str, name: str):
    pattern = rf'^    var {re.escape(name)}(?:\s*:\s*\w+)?\s*=\s*(.+)$'
    matches = re.findall(pattern, source, re.MULTILINE)
    if len(matches) != 1:
        raise ProductionConfigurationError(f"Unsupported production declaration: {name}")
    value = matches[0].strip()
    if value == '"""':
        multiline = re.search(rf'^    var {re.escape(name)} = """\n(.*?)\n    """\s*$', source, re.MULTILINE | re.DOTALL)
        if multiline is None:
            raise ProductionConfigurationError(f"Unsupported production literal: {name}")
        # Swift trims the closing delimiter's indentation and no terminal newline.
        text = multiline.group(1)
        if '\\' in text:
            raise ProductionConfigurationError(f'Unsupported production multiline escape: {name}')
        for line in text.splitlines():
            if line.strip() and not line.startswith('    '):
                raise ProductionConfigurationError(f"Unsupported production indentation: {name}")
        return '\n'.join(line[4:] if line.startswith('    ') else line for line in text.split('\n'))
    if value.startswith('"'):
        try:
            result = json.loads(value)
        except (ValueError, TypeError):
            raise ProductionConfigurationError(f"Unsupported production literal: {name}") from None
        if not isinstance(result, str):
            raise ProductionConfigurationError(f"Unsupported production literal: {name}")
        return result
    if value in ('true', 'false'):
        return value == 'true'
    if re.fullmatch(r'\d[\d_]*(?:\.\d+)?', value):
        return float(value.replace('_', '')) if '.' in value else int(value.replace('_', ''))
    # Deliberately permit the existing cache expression only, never eval Swift.
    if name == 'cacheLimitBytes' and value == '64 * 1024 * 1024':
        return 64 * 1024 * 1024
    raise ProductionConfigurationError(f"Unsupported production literal: {name}")


def production_configuration(repo_root: Path) -> dict:
    path = Path(repo_root) / 'Nts' / 'FilenameModelConfiguration.swift'
    source_bytes = path.read_bytes()
    source = source_bytes.decode('utf-8')
    names = ('modelID', 'revision', 'temperature', 'topP', 'maxGenerationAttempts',
             'maxOutputTokens', 'maxInputCharacters', 'useSystemRole', 'enableThinking',
             'cacheLimitBytes', 'promptVersion', 'systemPrompt', 'userPromptPrefix', 'userPromptSuffix')
    values = {name: _literal(source, name) for name in names}
    if values['useSystemRole'] is not True:
        raise ProductionConfigurationError('Benchmark requires the production system-role contract')
    exported = {
        'prompt': {'system': values['systemPrompt'], 'user_prefix': values['userPromptPrefix'],
                   'user_suffix': values['userPromptSuffix'], 'version': values['promptVersion']},
        'generation': {'temperature': values['temperature'], 'top_p': values['topP'], 'top_k': None,
                       'max_output_tokens': values['maxOutputTokens'],
                       'max_input_characters': values['maxInputCharacters'],
                       'max_attempts': values['maxGenerationAttempts'], 'enable_thinking': values['enableThinking']},
        'model': {'model_id': values['modelID'], 'revision': values['revision']},
        'cache_limit_bytes': values['cacheLimitBytes'],
        'source_sha256': hashlib.sha256(source_bytes).hexdigest(),
    }
    exported['fingerprint'] = hashlib.sha256(json.dumps(exported, sort_keys=True, separators=(',', ':')).encode()).hexdigest()
    exported['fingerprint_kind'] = 'benchmark-export-v1-not-swift-codable'
    return exported


def character_prefix(text: str, count: int) -> str:
    """Extended grapheme prefix, matching Swift Character semantics on fixtures.

    The regex package's Unicode version is recorded by the runtime; a future
    Swift Unicode-version change still needs conformance verification.
    """
    if type(count) is not int or count < 0:
        raise ValueError('Character count must be a nonnegative integer')
    try:
        import regex
    except ImportError:
        raise RuntimeError('Install requirements-core.txt for Unicode prefix support') from None
    return ''.join(regex.findall(r'\X', text)[:count])
