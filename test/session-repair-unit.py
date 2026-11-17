#!/usr/bin/env python3
import hashlib
import importlib.machinery
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
loader = importlib.machinery.SourceFileLoader('repair', str(Path(__file__).resolve().parents[1] / 'bin/cornice-session-repair'))
spec = importlib.util.spec_from_loader(loader.name, loader)
repair = importlib.util.module_from_spec(spec)
loader.exec_module(repair)

class RepairTests(unittest.TestCase):
    def test_archive_members(self):
        for value in ('usr/lib/liba.so.14', 'usr/lib/libb.so.0.5.1'):
            self.assertTrue(repair.checked_member(value))
        for value in ('/usr/lib/liba.so', '../usr/lib/liba.so', 'usr/lib/../../liba.so', 'usr/bin/evil', 'usr/lib/sub/liba.so'):
            self.assertFalse(repair.checked_member(value))
    def test_snapshot_identity(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            (root / 'file').write_text('original')
            (root / 'manifest.json').write_text(json.dumps({'hashes': {'file': hashlib.sha256(b'original').hexdigest()}}))
            repair.verify_candidate(root)
            (root / 'file').write_text('modified')
            with self.assertRaisesRegex(RuntimeError, 'Snapshot changed'):
                repair.verify_candidate(root)
    def test_snapshot_escape(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            (root / 'manifest.json').write_text(json.dumps({'hashes': {'../outside': 'irrelevant'}}))
            with self.assertRaisesRegex(RuntimeError, 'escapes'):
                repair.verify_candidate(root)

unittest.main()
