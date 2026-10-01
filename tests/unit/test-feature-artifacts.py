#!/usr/bin/env python3
"""Behavioral fixtures for portable allocation, publication and recovery."""

import concurrent.futures
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
HELPER = ROOT / 'scripts/helpers/feature-contract.py'
SAFETY = ROOT / 'scripts/helpers/artifact-safety.py'


class Artifacts(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name).resolve() / 'repo'
        self.root.mkdir()
        subprocess.run(['git', 'init', '-q', str(self.root)], check=True)
        self.draft = Path(self.tmp.name).resolve() / 'draft'
        self.draft.write_text('## Purpose\nA bounded feature.\n')

    def tearDown(self):
        self.tmp.cleanup()

    def call(self, *args, success=True):
        result = subprocess.run([sys.executable, str(HELPER), *args, '--root', str(self.root)],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0 if success else 2, result.stderr)
        return json.loads(result.stdout)

    def allocate(self, name='example'):
        return self.call('resolve', '--create', '--name', name)

    def test_concurrent_different_slugs_and_deleted_ordinal(self):
        def create(name):
            return self.allocate(name)
        with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
            results = list(pool.map(create, [f'feature-{n}' for n in range(8)]))
        ordinals = [int(v['feature'].split('/')[1].split('-')[0]) for v in results]
        self.assertEqual(len(set(ordinals)), 8)
        maximum = max(ordinals)
        # Simulate a deleted feature while retaining its portable allocation.
        for value in results:
            feature = self.root / value['feature']
            (feature / 'feature.json').unlink()
            feature.rmdir()
        later = self.allocate('next')
        self.assertEqual(int(later['feature'].split('/')[1].split('-')[0]), maximum + 1)

    def test_allocated_punctuation_slug_is_discoverable(self):
        for name in ['Add v2.0_exports', '___...---', 'Ship CAFÉ exports!']:
            with self.subTest(name=name):
                selected = self.allocate(name)
                self.assertRegex(selected['feature'], r'^specs/[0-9]{3,9}-[a-z0-9][a-z0-9-]{0,79}$')
                self.call('publish', '--feature', selected['feature'], '--kind', 'spec', '--input', str(self.draft))
                resumed = self.call('resume', '--explicit', selected['feature'])
                self.assertEqual(resumed['feature_id'], selected['feature_id'])
                current = self.call('resolve')
                self.assertIn(selected['feature'], current.get('candidates', [current.get('feature')]))

    def test_existing_root_spec_and_legacy_flag(self):
        (self.root / 'spec.md').write_text('Existing specification')
        selected = self.allocate()
        self.assertTrue(selected['legacy'])
        self.assertFalse((self.root / 'specs').exists())
        self.assertIn('migration', selected['reason'])
        legacy = self.call('resolve', '--create', '--layout', 'legacy')
        self.assertEqual(legacy['spec_path'], 'spec.md')

    def test_nongit_and_unsafe_specs_fallback(self):
        plain = Path(self.tmp.name).resolve() / 'plain'
        plain.mkdir()
        result = subprocess.run([sys.executable, str(HELPER), 'resolve', '--root', str(plain), '--create'], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0)
        self.assertTrue(json.loads(result.stdout)['legacy'])
        (self.root / 'specs').symlink_to(plain, target_is_directory=True)
        value = self.allocate()
        self.assertTrue(value['legacy'])
        self.assertEqual(list(plain.iterdir()), [])

    def test_speckit_and_explicit_selection(self):
        (self.root / '.specify').mkdir()
        current = self.root / 'specs/023-login'
        current.mkdir(parents=True)
        (current / 'spec.md').write_text('Spec Kit specification')
        value = self.allocate('login')
        self.assertEqual(value['feature'], 'specs/023-login')
        self.assertFalse((self.root / '.octo').exists())
        explicit = self.call('resolve', '--explicit', 'specs/023-login/spec.md')
        self.assertEqual(explicit['feature'], value['feature'])

    def test_ambiguous_resume_does_not_choose_newest(self):
        for name in ('001-one', '002-two'):
            (self.root / 'specs' / name).mkdir(parents=True)
        recovered = self.call('resume')
        self.assertTrue(recovered['ambiguous'])
        self.assertIsNone(recovered['feature'])

    def test_all_artifact_kinds_withhold_unverifiable_credentials(self):
        feature = self.allocate()['feature']
        self.draft.write_text('SERVICE_PASSWORD="inert-secret-fixture"\n')
        for kind in ('spec', 'plan', 'tasks', 'research', 'decisions'):
            value = self.call('publish', '--feature', feature, '--kind', kind, '--input', str(self.draft), '--run-id', 'run-123')
            self.assertTrue(value['withheld'], kind)
            text = (self.root / value['path']).read_text()
            self.assertNotIn('inert-secret-fixture', text)
            self.assertNotIn(str(self.draft), text)
            self.assertIn('run-123', text)

    def test_redaction_and_research_attribution(self):
        feature = self.allocate()['feature']
        self.draft.write_text('Accepted synthesis.\n-----BEGIN PRIVATE KEY-----\ninert fixture\n-----END PRIVATE KEY-----\nBearer inert-fixture\n')
        value = self.call('publish', '--feature', feature, '--kind', 'research', '--input', str(self.draft),
                          '--provider', 'codex', '--model', 'gpt-6.1-sol', '--run-id', 'probe-exact-1', '--distilled')
        self.assertFalse(value['withheld'])
        text = (self.root / value['path']).read_text()
        self.assertIn('Provider: codex', text)
        self.assertIn('Collected:', text)
        self.assertIn('Runtime run: probe-exact-1', text)
        self.assertNotIn('inert fixture', text)
        self.assertNotIn('Bearer inert', text)

    def test_research_rejects_raw_or_unattributed_input(self):
        feature = self.allocate()['feature']
        value = self.call('publish', '--feature', feature, '--kind', 'research', '--input', str(self.draft))
        self.assertTrue(value['withheld'])

    def test_repository_only_recovery_and_historical_evidence(self):
        feature = self.allocate()['feature']
        for kind in ('spec', 'plan', 'tasks', 'decisions'):
            self.call('publish', '--feature', feature, '--kind', kind, '--input', str(self.draft), '--provider', 'claude', '--model', 'sonnet')
        env = {'PATH': os.environ['PATH'], 'HOME': str(Path(self.tmp.name) / 'fresh-home')}
        result = subprocess.run([sys.executable, str(HELPER), 'resume', '--root', str(self.root)], env=env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0)
        value = json.loads(result.stdout)
        self.assertEqual(value['phase'], 'develop')
        self.assertEqual(set(value['artifacts']), {'spec', 'plan', 'tasks', 'decisions'})
        self.assertTrue(value['historical_completion'])

    def test_manifest_excludes_runtime_snapshot_and_home_paths(self):
        feature = self.allocate()['feature']
        for payload in ({'policy': {'source': 'AGENTS.md', 'digest': 'abc', 'text': 'raw policy'}},
                        {'task_completion': {'path': '/Users/person/private'}}):
            self.draft.write_text(json.dumps(payload))
            value = self.call('update', '--feature', feature, '--input', str(self.draft), success=False)
            self.assertFalse(value['published'])

    def test_symlink_leaf_and_oversized_input(self):
        feature = self.allocate()['feature']
        other = Path(self.tmp.name) / 'other'
        other.write_text('preserve')
        (self.root / feature / 'spec.md').symlink_to(other)
        self.call('publish', '--feature', feature, '--kind', 'spec', '--input', str(self.draft), success=False)
        self.assertEqual(other.read_text(), 'preserve')
        (self.root / feature / 'spec.md').unlink()
        self.draft.write_bytes(b'a' * 1048577)
        value = self.call('publish', '--feature', feature, '--kind', 'spec', '--input', str(self.draft))
        self.assertTrue(value['withheld'])

    def test_unsafe_metadata_cannot_publish_a_partial_artifact(self):
        feature = self.allocate()['feature']
        artifact = self.root / feature / 'spec.md'
        artifact.write_text('Preserve this accepted spec.\n')
        metadata = self.root / feature / 'feature.json'
        value = json.loads(metadata.read_text())
        value['OPENAI_API_KEY'] = 'unknown-inert-value'
        metadata.write_text(json.dumps(value))
        before = artifact.read_bytes()
        self.call('publish', '--feature', feature, '--kind', 'spec', '--input', str(self.draft), success=False)
        self.assertEqual(artifact.read_bytes(), before)
        self.assertEqual(json.loads(metadata.read_text()), value)

    def test_safety_scanner_failure_is_silent(self):
        for text in ('API_KEY=\nsecret-next-line', '-----BEGIN PRIVATE KEY-----\nincomplete', '\x00control',
                     'TOKEN="inert fixture"', 'Authorization: Bearer fixture'):
            result = subprocess.run([sys.executable, str(SAFETY)], input=text, capture_output=True, text=True)
            self.assertEqual(result.returncode, 65)
            self.assertEqual(result.stdout, '')
            self.assertEqual(result.stderr, '')


if __name__ == '__main__':
    unittest.main()
