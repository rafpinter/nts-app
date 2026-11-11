from pathlib import Path
import tempfile
import unittest
from title_eval.production import ProductionConfigurationError, character_prefix, production_configuration

ROOT = Path(__file__).resolve().parents[3]


class ProductionTests(unittest.TestCase):
    def test_exports_current_contract(self):
        config = production_configuration(ROOT)
        self.assertEqual(config['model']['model_id'],'mlx-community/Qwen3-0.6B-4bit')
        self.assertEqual(config['generation']['max_input_characters'],4000)
        self.assertEqual(config['generation']['max_attempts'],3)
        self.assertEqual(config['prompt']['user_prefix'],'Generate a title for this note:\n\n<note>\n')
        self.assertTrue(config['prompt']['system'].startswith('Generate a short, natural title'))
        self.assertFalse(config['prompt']['system'].endswith('\n'))
        self.assertEqual(len(config['source_sha256']),64)
        self.assertEqual(config['fingerprint_kind'],'benchmark-export-v1-not-swift-codable')

    def test_changed_expression_fails_closed(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);(root/'Nts').mkdir()
            source=(ROOT/'Nts/FilenameModelConfiguration.swift').read_text()
            source=source.replace('var temperature: Float = 0.5','var temperature: Float = defaults.temperature')
            (root/'Nts/FilenameModelConfiguration.swift').write_text(source)
            with self.assertRaises(ProductionConfigurationError):production_configuration(root)

    def test_grapheme_prefix(self):
        self.assertEqual(character_prefix('a\u0301👨‍👩‍👧‍👦z',2),'a\u0301👨‍👩‍👧‍👦')
        self.assertEqual(character_prefix('🇧🇷hello',1),'🇧🇷')
        self.assertEqual(character_prefix('abc',0),'')
        with self.assertRaises(ValueError):character_prefix('abc',True)


if __name__ == '__main__':unittest.main()
