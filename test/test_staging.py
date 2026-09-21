#!/usr/bin/env python3
"""Network-free integrity and cache tests for runtime staging."""
import gzip
import hashlib
import importlib.util
import io
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("stage_runtime", ROOT / "tools/stage_runtime.py")
stage = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(stage)


class RuntimeStaging(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)
        (self.root / ".deps").mkdir()
        self.target = self.root / ".deps/duckhts.duckdb_extension"
        self.payload = b"test extension bytes"
        self.archive = gzip.compress(self.payload, mtime=0)
        self.pin = {
            "platform": "linux_amd64",
            "url": "https://invalid.example/extension.gz",
            "archive_sha256": hashlib.sha256(self.archive).hexdigest(),
            "archive_bytes": len(self.archive),
            "sha256": hashlib.sha256(self.payload).hexdigest(),
        }
        for target, value in (("ROOT", self.root), ("PACKAGE", {"duckhts_integration": self.pin})):
            replacement = patch.object(stage, target, value)
            replacement.start()
            self.addCleanup(replacement.stop)
        for target, value in (("system", "Linux"), ("machine", "x86_64")):
            replacement = patch.object(stage.platform, target, return_value=value)
            replacement.start()
            self.addCleanup(replacement.stop)

    def test_download_validates_archive_and_payload(self):
        with patch.object(stage, "urlopen", return_value=io.BytesIO(self.archive)) as request:
            stage.duckhts()
            request.assert_called_once_with(self.pin["url"], timeout=120)
        self.assertEqual(self.target.read_bytes(), self.payload)
        self.assertEqual(list(self.target.parent.iterdir()), [self.target])

    def test_valid_cache_requires_no_network(self):
        self.target.write_bytes(self.payload)
        with patch.object(stage, "urlopen", side_effect=AssertionError("network access")):
            stage.duckhts()
        self.assertEqual(self.target.read_bytes(), self.payload)

    def test_archive_failure_preserves_existing_file(self):
        self.target.write_bytes(b"existing file")
        with patch.object(stage, "urlopen", return_value=io.BytesIO(b"corrupt archive")):
            with self.assertRaisesRegex(RuntimeError, "archive checksum mismatch"):
                stage.duckhts()
        self.assertEqual(self.target.read_bytes(), b"existing file")

    def test_payload_failure_does_not_publish(self):
        self.pin["sha256"] = "0" * 64
        with patch.object(stage, "urlopen", return_value=io.BytesIO(self.archive)):
            with self.assertRaisesRegex(RuntimeError, "extension checksum mismatch"):
                stage.duckhts()
        self.assertFalse(self.target.exists())

    def test_wrong_platform_stops_before_download(self):
        with patch.object(stage.platform, "machine", return_value="aarch64"):
            with patch.object(stage, "urlopen", side_effect=AssertionError("network access")):
                with self.assertRaisesRegex(RuntimeError, "targets linux_amd64"):
                    stage.duckhts()


if __name__ == "__main__":
    unittest.main()
