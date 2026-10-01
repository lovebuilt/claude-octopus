#!/usr/bin/env python3
"""Exercise council status updates under locale changes and filesystem races."""

import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

REPO = Path(__file__).resolve().parents[2]
HELPER = REPO / "scripts/helpers/council-run-state.py"
spec = importlib.util.spec_from_file_location("council_run_state", HELPER)
state = importlib.util.module_from_spec(spec)
spec.loader.exec_module(state)


class RunStateTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.pool = Path(self.temporary.name)
        self.current = self.pool / "current"
        self.current.mkdir()

    def test_non_utf8_locale_preserves_existing_supersession(self):
        record = {"run_id": "current", "created_order": 7, "superseded": True,
                  "superseded_by": "newer", "task": "caf\u00e9"}
        (self.current / "run-status.json").write_text(
            json.dumps(record, ensure_ascii=False), encoding="utf-8")
        environment = dict(os.environ, LC_ALL="C", PYTHONUTF8="0",
                           PYTHONCOERCECLOCALE="0")
        result = subprocess.run(
            [sys.executable, str(HELPER), "write", str(self.current)],
            input=b'{"run_id":"current","state":"finished"}',
            capture_output=True, env=environment)
        self.assertEqual(result.returncode, 0, result.stderr)
        saved = json.loads((self.current / "run-status.json").read_text(encoding="utf-8"))
        self.assertEqual(saved["created_order"], 7)
        self.assertTrue(saved["superseded"])
        self.assertEqual(saved["superseded_by"], "newer")

    def test_sibling_beacon_directory_does_not_block_current_write(self):
        broken = self.pool / "broken"
        (broken / "run-status.json").mkdir(parents=True)
        state.write_status(self.current, {"run_id": "current"})
        saved = state.read_record(self.current / "run-status.json")
        self.assertEqual(saved["created_order"], 1)

    def test_unreadable_or_replaced_sibling_beacons_are_skipped(self):
        for error in (PermissionError("unreadable"), NotADirectoryError("replaced"),
                      FileNotFoundError("removed")):
            with self.subTest(error=type(error).__name__):
                with mock.patch.object(Path, "read_text", side_effect=error):
                    self.assertEqual(state.read_record(self.pool / "run-status.json"), {})

    def test_unavailable_pool_scan_is_best_effort(self):
        for error in (FileNotFoundError("removed"), NotADirectoryError("replaced"),
                      PermissionError("unreadable")):
            with self.subTest(error=type(error).__name__):
                with mock.patch.object(Path, "iterdir", side_effect=error):
                    self.assertEqual(list(state.pool_records(self.pool)), [])

    def test_disappearing_pool_scan_keeps_records_already_read(self):
        (self.current / "run-status.json").write_text('{"run_id":"current"}', encoding="utf-8")
        def disappeared(_pool):
            yield self.current
            raise FileNotFoundError("pool removed during enumeration")
        with mock.patch.object(Path, "iterdir", disappeared):
            records = list(state.pool_records(self.pool))
        self.assertEqual([record["run_id"] for _, record in records], ["current"])

    def test_unreadable_sibling_directory_does_not_hide_valid_beacon(self):
        broken = self.pool / "broken"
        broken.mkdir()
        (self.current / "run-status.json").write_text('{"run_id":"current"}', encoding="utf-8")
        original = Path.is_dir
        def inspect(path):
            if path == broken:
                raise PermissionError("sibling inaccessible")
            return original(path)
        with mock.patch.object(Path, "is_dir", inspect):
            records = list(state.pool_records(self.pool))
        self.assertEqual([record["run_id"] for _, record in records], ["current"])

    def test_unreadable_current_metadata_is_not_overwritten(self):
        path = self.current / "run-status.json"
        record = {"created_order": 7, "superseded": True}
        path.write_text(json.dumps(record), encoding="utf-8")
        original = Path.read_text
        def read(candidate, *args, **kwargs):
            if candidate == path:
                raise PermissionError("current beacon unreadable")
            return original(candidate, *args, **kwargs)
        with mock.patch.object(Path, "read_text", read):
            with self.assertRaises(PermissionError):
                state.write_status(self.current, {"run_id": "current"})
        self.assertEqual(json.loads(path.read_text(encoding="utf-8")), record)

    def test_current_write_failure_remains_an_error(self):
        (self.current / "run-status.json").mkdir()
        with self.assertRaises(OSError):
            state.write_status(self.current, {"run_id": "current"})


if __name__ == "__main__":
    unittest.main()
