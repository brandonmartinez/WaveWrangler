#!/usr/bin/env python3
"""Small, synthetic-only fail-closed tests for the WW-026 qualification runner."""

import importlib.util
import json
import subprocess
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

SOURCE = Path(__file__).with_name("speech-qualification.py")
SPEC = importlib.util.spec_from_file_location("speech_qualification", SOURCE)
qualification = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(qualification)


class QualificationTests(unittest.TestCase):
    def test_word_error_rate_counts_substitutions_and_deletions(self):
        self.assertEqual(qualification.word_error_rate("A blue folder.", "A red folder"), 1 / 3)
        self.assertEqual(qualification.word_error_rate("A blue folder", "blue folder"), 1 / 3)

    def test_model_rejects_unpinned_body(self):
        with tempfile.TemporaryDirectory() as directory:
            model = Path(directory) / "ggml-base.en.bin"
            model.write_bytes(b"not a model")
            with self.assertRaisesRegex(qualification.QualificationError, "size or SHA-256"):
                qualification.inspect_model(model)
            with patch.object(qualification, "MODEL_BYTES", len(b"not a model")):
                with self.assertRaisesRegex(qualification.QualificationError, "size or SHA-256"):
                    qualification.inspect_model(model)

    def test_network_probe_rejects_socket_success_and_other_failures(self):
        with patch.object(qualification, "guarded", return_value=subprocess.CompletedProcess([], 0, "", "")):
            with self.assertRaisesRegex(qualification.QualificationError, "unexpectedly"):
                qualification.no_egress_control()
        with patch.object(qualification, "guarded", return_value=subprocess.CompletedProcess([], 1, "", "syntax error")):
            with self.assertRaisesRegex(qualification.QualificationError, "other than sandbox"):
                qualification.no_egress_control()

    def test_runtime_rejects_same_version_with_unpinned_binary(self):
        with tempfile.TemporaryDirectory() as directory:
            executable = Path(directory) / "whisper-cli"
            executable.write_bytes(b"not the pinned runtime")
            response = subprocess.CompletedProcess([], 0, "whisper.cpp version: 1.9.4\n", "")
            with patch.object(qualification, "guarded", return_value=response):
                with self.assertRaisesRegex(qualification.QualificationError, "SHA-256 differs"):
                    qualification.check_runtime(executable)
            response = subprocess.CompletedProcess([], 0, "whisper.cpp version: 1.9.4-extra\n", "")
            with patch.object(qualification, "guarded", return_value=response):
                with self.assertRaisesRegex(qualification.QualificationError, "not the pinned"):
                    qualification.check_runtime(executable)

    def test_missing_or_malformed_whisper_output_refuses(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "result.json"
            with self.assertRaisesRegex(qualification.QualificationError, "absent or malformed"):
                qualification.parse_whisper(output)
            output.write_text(json.dumps({"transcription": [{"text": "hello"}]}))
            transcript, timing = qualification.parse_whisper(output)
            self.assertEqual(transcript, "hello")
            self.assertEqual(timing, {"timedSegments": 0, "segments": 1})
            output.write_text(json.dumps({"transcription": []}))
            with self.assertRaisesRegex(qualification.QualificationError, "no English words"):
                qualification.parse_whisper(output)

    def test_missing_resource_measurement_refuses(self):
        with self.assertRaisesRegex(qualification.QualificationError, "resource observer"):
            qualification.peak_rss("no measurement")
        self.assertEqual(qualification.peak_rss(" 12345  maximum resident set size\n"), 12345)

    def test_missing_boot_marker_refuses(self):
        returned = subprocess.CompletedProcess([], 0, "unexpected", "")
        with patch.object(qualification, "run", return_value=returned):
            with self.assertRaisesRegex(qualification.QualificationError, "boot session"):
                qualification.boot_epoch()

    def test_native_supported_is_not_installed(self):
        with tempfile.TemporaryDirectory() as directory:
            binary = Path(directory) / "native"
            binary.touch()
            returned = subprocess.CompletedProcess([], 0, '{"availability":"supportedOnly"}', "")
            with patch.object(qualification, "guarded", return_value=returned):
                self.assertEqual(qualification.inspect_native(binary)["availability"], "supportedOnly")
            returned = subprocess.CompletedProcess([], 0, '{"availability":"supported"}', "")
            with patch.object(qualification, "guarded", return_value=returned):
                with self.assertRaisesRegex(qualification.QualificationError, "unknown status"):
                    qualification.inspect_native(binary)

    def test_installed_native_asset_still_blocks_unobserved_service_inference(self):
        with (
            tempfile.TemporaryDirectory() as directory,
            patch.object(qualification.platform, "system", return_value="Darwin"),
            patch.object(qualification.platform, "machine", return_value="arm64"),
            patch.object(qualification, "no_egress_control"),
            patch.object(qualification, "inspect_model", return_value={}),
            patch.object(qualification, "check_runtime", return_value={"executableSHA256": "stable"}),
            patch.object(qualification, "inspect_native", return_value={"availability": "installed"}),
            patch.object(qualification, "create_pcm", return_value=(Path("/tmp/synthetic.wav"), 2.0)),
            patch.object(qualification, "observe_whisper", return_value={"rtf": 1.0}),
            patch.object(qualification, "boot_epoch", return_value=123),
            patch.object(qualification, "sha256", return_value="stable"),
            patch.object(qualification, "run", return_value=subprocess.CompletedProcess([], 0, "1024", "")),
        ):
            model, cli = Path(directory) / "model", Path(directory) / "cli"
            model.touch()
            cli.touch()
            report = qualification.qualify(
                SimpleNamespace(model=model, whisper_cli=cli, native_probe=None)
            )
        self.assertEqual(len(report["cases"]), 2)
        self.assertTrue(all(case["native"]["state"] == "BLOCKED" for case in report["cases"]))


if __name__ == "__main__":
    unittest.main()
