"""Regression checks for CI release selection; no network access required."""

import json
from pathlib import Path
import subprocess
import sys
import unittest

from eglotx_matrix import minimum_emacs, select_versions


def manifest(*names):
    return {"root": "packages", "nodes": {"packages": {"inputs": dict.fromkeys(names)}}}


class MatrixTests(unittest.TestCase):
    def test_reads_package_minimum(self):
        source = ';; Package-Requires: ((emacs "29.1") (eglot "1.24"))'
        self.assertEqual(minimum_emacs(source), (29, 1))
        self.assertEqual(minimum_emacs(source.replace("29.1", "32.2")), (32, 2))
        with self.assertRaisesRegex(ValueError, "Package-Requires"):
            minimum_emacs(';; Version: 29.1')

    def test_sorts_numerically_and_excludes_prereleases(self):
        lock = manifest("emacs-28-2", "emacs-30-2", "emacs-29-4", "emacs-29-1",
                        "emacs-30-10", "emacs-31-1", "emacs-31-0-90",
                        "emacs-32-1-rc1", "emacs-release-snapshot", "emacs-snapshot")
        self.assertEqual(select_versions(lock, (29, 1)),
                         ["29.4", "30.10", "31.1", "snapshot"])

    def test_follows_new_releases_and_supported_minimum(self):
        lock = manifest("emacs-29-4", "emacs-30-2", "emacs-31-1", "emacs-snapshot")
        self.assertEqual(select_versions(lock, (29, 1)),
                         ["29.4", "30.2", "31.1", "snapshot"])
        lock["nodes"]["packages"]["inputs"].update({"emacs-31-2": None, "emacs-32-1": None})
        self.assertEqual(select_versions(lock, (29, 1)),
                         ["29.4", "30.2", "31.2", "32.1", "snapshot"])
        self.assertEqual(select_versions(lock, (31, 2)), ["31.2", "32.1", "snapshot"])

    def test_rejects_incomplete_upstream_data(self):
        with self.assertRaisesRegex(ValueError, "No supported stable"):
            select_versions(manifest("emacs-28-2", "emacs-snapshot"), (29, 1))
        with self.assertRaisesRegex(ValueError, "snapshot"):
            select_versions(manifest("emacs-31-1"), (29, 1))
        with self.assertRaises(KeyError):
            select_versions({}, (29, 1))

    def test_command_emits_a_single_json_matrix(self):
        script = Path(__file__).with_name("eglotx_matrix.py")
        lock = manifest("emacs-29-4", "emacs-30-2", "emacs-31-1", "emacs-snapshot")
        result = subprocess.run([sys.executable, str(script)], input=json.dumps(lock),
                                text=True, capture_output=True, check=True)
        self.assertEqual(result.stdout.count("\n"), 1)
        self.assertEqual(json.loads(result.stdout),
                         {"emacs-version": ["29.4", "30.2", "31.1", "snapshot"]})


if __name__ == "__main__":
    unittest.main()
