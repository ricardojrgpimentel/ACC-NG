"""Candidate packaging must not announce an unpublished updater release."""
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class BuildTests(unittest.TestCase):
    def test_candidate_metadata_is_separate_until_explicit_publication(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            (root / 'tools').mkdir()
            (root / 'install').mkdir()
            shutil.copyfile(ROOT / 'tools/build_ng.py', root / 'tools/build_ng.py')
            (root / 'module.prop').write_text('version=v0.2.0-ng\nversionCode=2\n')
            (root / 'install/uninstall.sh').write_text('#!/system/bin/sh\nexit 0\n')
            for name in ['install-tarball.sh', 'install-online.sh']:
                (root / name).write_text('#!/system/bin/sh\nexit 0\n')
            published = b'{"version": "v0.1.0-ng", "versionCode": 1}\n'
            (root / 'module.json').write_bytes(published)
            command = ['python3', str(root / 'tools/build_ng.py')]
            subprocess.run(command, check=True, capture_output=True)
            output = root / '_builds/acc_v0.2.0-ng_2'
            archive = output / 'acc_v0.2.0-ng_2.tgz'
            digest = hashlib.sha256(archive.read_bytes()).hexdigest()
            candidate = json.loads((output / 'module.json').read_text())
            self.assertEqual(published, (root / 'module.json').read_bytes())
            self.assertEqual(2, candidate['versionCode'])
            self.assertEqual(digest, candidate['sha256'])
            subprocess.run(command, check=True, capture_output=True)
            self.assertEqual(digest, hashlib.sha256(archive.read_bytes()).hexdigest())
            self.assertEqual(published, (root / 'module.json').read_bytes())
            subprocess.run(command + ['--update-metadata'], check=True, capture_output=True)
            self.assertEqual(candidate, json.loads((root / 'module.json').read_text()))
            self.assertEqual(digest, hashlib.sha256(archive.read_bytes()).hexdigest())
