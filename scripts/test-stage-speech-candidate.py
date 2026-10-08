#!/usr/bin/env python3
"""Synthetic staging tests: no private model bytes, media, downloads or inference."""

import importlib.util
import os
from pathlib import Path
import shutil
import socket
import stat
import subprocess
import tempfile
from types import SimpleNamespace
import unittest
from unittest import mock


spec = importlib.util.spec_from_file_location(
    "speech_stage", Path(__file__).with_name("stage-speech-candidate.py")
)
speech = importlib.util.module_from_spec(spec)
spec.loader.exec_module(speech)


def marked_dataless(info):
    fields = ("st_dev", "st_ino", "st_mode", "st_uid", "st_nlink", "st_size",
              "st_mtime_ns", "st_ctime_ns")
    return SimpleNamespace(**{name: getattr(info, name) for name in fields},
                           st_flags=speech.policy.SF_DATALESS)


class StageTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(dir="/private/tmp")
        self.addCleanup(self.tmp.cleanup)
        root = Path(self.tmp.name)
        self.model = root / "model"
        self.model.write_bytes(b"abc")
        self.model.chmod(0o600)
        self.native = root / "native"
        self.native.write_bytes(b"bin")
        self.native.chmod(0o755)
        self.digest = speech.hashlib.sha256(b"abc").hexdigest()
        native_digest = speech.hashlib.sha256(b"bin").hexdigest()
        self.assets = ((str(self.native), "bin/whisper-cli", 3, native_digest,
                        3, native_digest),)
        model = ("", "model/ggml-base.en.bin", 3, self.digest, 3, self.digest)
        patcher = mock.patch.object(speech, "MODEL", model)
        patcher.start()
        self.addCleanup(patcher.stop)
        self.current_policy = 0
        self.events = []

        def get_policy(kind, scope):
            return self.current_policy

        def set_policy(kind, scope, value):
            self.current_policy = value
            self.events.append(("policy", value))
            return 0

        patcher = mock.patch.object(speech.policy, "_policy_functions",
                                    return_value=(get_policy, set_policy))
        patcher.start()
        self.addCleanup(patcher.stop)

    def run_stage(self, transform=lambda _: None):
        return speech.stage(str(self.model), assets=self.assets, transform=transform)

    def test_complete_stage_copies_exact_bytes_with_policy_and_no_network(self):
        real_open = os.open

        def observed_open(*args, **kwargs):
            self.assertEqual(self.current_policy, speech.policy.IOPOL_MATERIALIZE_DATALESS_FILES_OFF)
            self.events.append(("open", Path(args[0])))
            return real_open(*args, **kwargs)

        with mock.patch.object(speech.os, "open", side_effect=observed_open), \
                mock.patch.object(socket, "create_connection") as network:
            result = self.run_stage()
        self.addCleanup(shutil.rmtree, result)
        network.assert_not_called()
        self.assertEqual((result / "model/ggml-base.en.bin").read_bytes(), b"abc")
        self.assertEqual((result / "bin/whisper-cli").read_bytes(), b"bin")
        self.assertEqual(stat.S_IMODE(result.stat().st_mode), 0o700)
        self.assertTrue(self.events[0] == ("policy", 1))
        self.assertTrue(self.events[-1] == ("policy", 0))
        self.assertEqual(self.current_policy, 0)

    def test_dataless_at_admission_refuses_without_open_stage_or_network(self):
        actual = os.lstat(self.model)
        fake = marked_dataless(actual)
        real_lstat = os.lstat
        with mock.patch.object(speech.os, "lstat", side_effect=lambda path: (
                fake if Path(path) == self.model else real_lstat(path))), \
                mock.patch.object(speech.os, "open") as open_file, \
                mock.patch.object(speech.tempfile, "mkdtemp") as make_stage, \
                mock.patch.object(socket, "create_connection") as network:
            with self.assertRaisesRegex(speech.policy.ProvisionError, "dataless"):
                self.run_stage()
        open_file.assert_not_called()
        make_stage.assert_not_called()
        network.assert_not_called()
        self.assertEqual(self.current_policy, 0)

    def test_dataless_appearing_after_admission_refuses_without_copy(self):
        real_lstat = os.lstat
        seen = 0

        def changed(path):
            nonlocal seen
            info = real_lstat(path)
            if Path(path) == self.native:
                seen += 1
                if seen >= 4:
                    return marked_dataless(info)
            return info

        stages = []
        real_mkdtemp = tempfile.mkdtemp

        def make_stage(*args, **kwargs):
            result = real_mkdtemp(*args, **kwargs)
            stages.append(result)
            return result

        with mock.patch.object(speech.os, "lstat", side_effect=changed), \
                mock.patch.object(speech.tempfile, "mkdtemp", side_effect=make_stage), \
                mock.patch.object(speech.os, "open", wraps=os.open) as open_file, \
                mock.patch.object(socket, "create_connection") as network:
            with self.assertRaisesRegex(speech.policy.ProvisionError, "dataless"):
                self.run_stage()
        self.assertEqual(len(stages), 1)
        self.assertFalse(Path(stages[0]).exists())
        self.assertEqual(sum(str(call.args[0]) == str(self.native)
                             for call in open_file.call_args_list), 1)
        network.assert_not_called()
        self.assertEqual(self.current_policy, 0)

    def test_replacement_and_relink_during_copy_remove_partial_stage(self):
        replacement = Path(self.tmp.name) / "replacement"
        replacement.write_bytes(b"bin")
        replacement.chmod(0o755)
        real_open = os.open
        native_opens = 0
        stages = []
        real_mkdtemp = tempfile.mkdtemp

        def make_stage(*args, **kwargs):
            result = real_mkdtemp(*args, **kwargs)
            stages.append(result)
            return result

        def replaced(path, flags, *args, **kwargs):
            nonlocal native_opens
            if str(path) == str(self.native):
                native_opens += 1
                if native_opens == 2:
                    replacement.replace(self.native)
            return real_open(path, flags, *args, **kwargs)

        with mock.patch.object(speech.tempfile, "mkdtemp", side_effect=make_stage), \
                mock.patch.object(speech.os, "open", side_effect=replaced):
            with self.assertRaisesRegex(speech.policy.ProvisionError, "changed"):
                self.run_stage()
        self.assertFalse(Path(stages[0]).exists())
        self.assertEqual(self.current_policy, 0)

        replacement.write_bytes(b"bin")
        replacement.chmod(0o755)
        real_lstat = os.lstat
        seen = 0

        def relinked(path):
            nonlocal seen
            if Path(path) == self.native:
                seen += 1
                if seen == 6:
                    self.native.unlink()
                    self.native.symlink_to(replacement)
            return real_lstat(path)

        with mock.patch.object(speech.tempfile, "mkdtemp", side_effect=make_stage), \
                mock.patch.object(speech.os, "lstat", side_effect=relinked):
            with self.assertRaisesRegex(speech.policy.ProvisionError, "changed"):
                self.run_stage()
        self.assertFalse(Path(stages[1]).exists())
        self.assertEqual(self.current_policy, 0)

    def test_same_bytes_replacement_after_admission_refuses(self):
        replacement = Path(self.tmp.name) / "replacement"
        replacement.write_bytes(b"bin")
        replacement.chmod(0o755)
        real_mkdtemp = tempfile.mkdtemp
        stages = []

        def make_stage(*args, **kwargs):
            result = real_mkdtemp(*args, **kwargs)
            stages.append(Path(result))
            replacement.replace(self.native)
            return result

        with mock.patch.object(speech.tempfile, "mkdtemp", side_effect=make_stage), \
                mock.patch.object(speech.os, "open", wraps=os.open) as open_file:
            with self.assertRaisesRegex(speech.policy.ProvisionError, "identity changed"):
                self.run_stage()
        self.assertEqual(sum(str(call.args[0]) == str(self.native)
                             for call in open_file.call_args_list), 1)
        self.assertFalse(stages[0].exists())
        self.assertEqual(self.current_policy, 0)

    def test_same_bytes_replacement_after_copy_refuses(self):
        replacement = Path(self.tmp.name) / "replacement"
        replacement.write_bytes(b"bin")
        replacement.chmod(0o755)
        stages = []

        def replace_source(path):
            stages.append(path)
            replacement.replace(self.native)

        with self.assertRaisesRegex(speech.policy.ProvisionError, "identity changed"):
            self.run_stage(transform=replace_source)
        self.assertFalse(stages[0].exists())
        self.assertEqual(self.current_policy, 0)

    def test_policy_failure_is_closed_before_open_or_network(self):
        for get, set_ in ((lambda *_: -1, lambda *_: 0),
                          (lambda *_: 0, lambda *_: -1)):
            with self.subTest(get=get):
                with mock.patch.object(speech.policy, "_policy_functions",
                                       return_value=(get, set_)), \
                        mock.patch.object(speech.os, "open") as open_file, \
                        mock.patch.object(speech.tempfile, "mkdtemp") as make_stage, \
                        mock.patch.object(socket, "create_connection") as network:
                    with self.assertRaises(speech.policy.ProvisionError):
                        self.run_stage()
                open_file.assert_not_called()
                make_stage.assert_not_called()
                network.assert_not_called()

    def test_transform_failure_removes_complete_stage(self):
        stages = []

        def failing_transform(path):
            stages.append(path)
            raise speech.policy.ProvisionError("transform failed")

        with self.assertRaisesRegex(speech.policy.ProvisionError, "transform failed"):
            self.run_stage(transform=failing_transform)
        self.assertFalse(stages[0].exists())
        self.assertEqual(self.current_policy, 0)

    def test_full_synthetic_closure_and_protected_subprocesses(self):
        root = Path(self.tmp.name)
        assets = []
        for index, (_, target, _, _, _, _) in enumerate(speech.ASSETS):
            source = root / f"native-{index}"
            data = f"synthetic-{index}".encode()
            source.write_bytes(data)
            source.chmod(0o755)
            digest = speech.hashlib.sha256(data).hexdigest()
            assets.append((str(source), target, len(data), digest, len(data), digest))

        def observed_run(args, **kwargs):
            self.assertEqual(self.current_policy, 1)
            self.assertIs(kwargs["preexec_fn"], speech._child_policy)
            self.assertEqual(kwargs["timeout"], 120)
            self.assertIn(args[0], ("/usr/bin/install_name_tool", "/usr/bin/codesign"))
            self.assertTrue(str(args[-1]).startswith("/private/tmp/ww-speech-"))

        with mock.patch.object(speech.subprocess, "run", side_effect=observed_run) as run, \
                mock.patch.object(socket, "create_connection") as network:
            result = speech.stage(str(self.model), assets=tuple(assets))
        self.addCleanup(shutil.rmtree, result)
        self.assertEqual(run.call_count, 18)
        self.assertEqual(len(list(result.rglob("*"))), 14)  # four directories, ten files
        network.assert_not_called()
        self.assertEqual(self.current_policy, 0)

    def test_modified_staged_asset_is_not_published(self):
        stages = []

        def altered(path):
            stages.append(path)
            (path / "bin/whisper-cli").write_bytes(b"bad")

        with self.assertRaises(speech.policy.ProvisionError):
            self.run_stage(transform=altered)
        self.assertFalse(stages[0].exists())
        self.assertEqual(self.current_policy, 0)

    def test_policy_restore_failure_removes_stage(self):
        stages = []
        real_mkdtemp = tempfile.mkdtemp

        def make_stage(*args, **kwargs):
            result = real_mkdtemp(*args, **kwargs)
            stages.append(Path(result))
            return result

        current = 0

        def get_policy(*_):
            return current

        def set_policy(*args):
            nonlocal current
            if args[-1] == 0:
                return -1
            current = args[-1]
            return 0

        with mock.patch.object(speech.policy, "_policy_functions",
                               return_value=(get_policy, set_policy)), \
                mock.patch.object(speech.tempfile, "mkdtemp", side_effect=make_stage):
            with self.assertRaisesRegex(speech.policy.ProvisionError, "Cannot restore"):
                self.run_stage()
        self.assertEqual(len(stages), 1)
        self.assertFalse(stages[0].exists())

    def test_child_policy_failure_refuses_before_executable(self):
        with mock.patch.object(speech.policy, "_policy_functions",
                               return_value=(lambda *_: 0, lambda *_: -1)):
            with self.assertRaisesRegex(speech.policy.ProvisionError, "Cannot protect"):
                speech._child_policy()
            with self.assertRaises(subprocess.SubprocessError):
                speech._run("/usr/bin/true")


class MacOSChildPolicyTests(unittest.TestCase):
    def test_shell_entrypoint_preserves_invalid_argument_exit(self):
        script = Path(__file__).with_name("stage-speech-candidate.sh")
        for args in ((), ("relative/model.bin",)):
            with self.subTest(args=args):
                result = subprocess.run((str(script), *args), capture_output=True, text=True)
                self.assertEqual(result.returncode, 2)
                self.assertEqual(result.stdout, "")
                self.assertIn("Expected one absolute", result.stderr)

    def test_process_policy_survives_exec_without_altering_parent(self):
        get_policy, _ = speech.policy._policy_functions()
        kind = speech.policy.IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES
        previous = get_policy(kind, 0)
        result = subprocess.run(
            ["/usr/bin/python3", "-c",
             "import ctypes; print(ctypes.CDLL(None).getiopolicy_np(3, 0))"],
            preexec_fn=speech._child_policy, capture_output=True, text=True, check=True,
        )
        self.assertEqual(result.stdout.strip(), "1")
        self.assertEqual(get_policy(kind, 0), previous)


if __name__ == "__main__":
    unittest.main()
