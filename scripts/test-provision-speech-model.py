#!/usr/bin/env python3
"""Synthetic, network-free tests for the exact-model provisioner."""

import importlib.util
import io
import os
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest import mock


spec = importlib.util.spec_from_file_location(
    "speech_provision", Path(__file__).with_name("provision-speech-model.py")
)
speech = importlib.util.module_from_spec(spec)
spec.loader.exec_module(speech)


class Response(io.BytesIO):
    def __init__(self, data=b"", *, status=200, headers=None):
        super().__init__(data)
        self.status = status
        self.headers = headers or {}


class Opener:
    def __init__(self, content=b"abc", host="us.aws.cdn.hf.co", size="3", etag=None,
                 get_status=200):
        self.content = content
        self.host = host
        self.size = size
        self.etag = etag or speech.hashlib.sha256(b"abc").hexdigest()
        self.get_status = get_status
        self.calls = []

    def open(self, request, timeout):
        self.calls.append((request.get_method(), request.full_url.split("?")[0]))
        if request.get_method() == "HEAD":
            return Response(status=302, headers={
                "Location": f"https://{self.host}/pinned-model?private-query",
                "X-Linked-Size": self.size,
                "X-Linked-Etag": f'"{self.etag}"',
            })
        return Response(self.content, status=self.get_status,
                        headers={"Content-Length": str(len(self.content))})


class ProvisionTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(dir="/private/tmp")
        self.addCleanup(self.tmp.cleanup)
        self.store = Path(self.tmp.name) / "private"
        self.digest = speech.hashlib.sha256(b"abc").hexdigest()
        self.policy = 0
        self.events = []

        def get_policy(policy_type, scope):
            return self.policy

        def set_policy(policy_type, scope, value):
            self.events.append(("policy", value))
            self.policy = value
            return 0

        patcher = mock.patch.object(speech, "_policy_functions",
                                    return_value=(get_policy, set_policy))
        patcher.start()
        self.addCleanup(patcher.stop)

    def provision(self, opener):
        return speech.provision(self.store, opener=opener, size=3, digest=self.digest)

    def test_provision_and_offline_cold_recheck(self):
        opener = Opener()
        target = self.provision(opener)
        self.assertEqual([call[0] for call in opener.calls], ["HEAD", "GET"])
        self.assertEqual(target.read_bytes(), b"abc")
        self.provision(opener)
        self.assertEqual(len(opener.calls), 2)
        self.assertEqual(self.policy, 0)
        speech.check_file(target, 3, self.digest)
        target.write_bytes(b"abd")
        with self.assertRaises(speech.ProvisionError):
            self.provision(opener)
        self.assertEqual(len(opener.calls), 2)

    def test_missing_wrong_size_and_digest(self):
        speech.private_directory(self.store)
        with self.assertRaises(speech.ProvisionError):
            speech.check_file(self.store / speech.NAME, 3, self.digest)
        for data in (b"ab", b"abd"):
            (self.store / speech.NAME).write_bytes(data)
            (self.store / speech.NAME).chmod(0o600)
            with self.assertRaises(speech.ProvisionError):
                speech.check_file(self.store / speech.NAME, 3, self.digest)

    def test_redirect_and_linked_metadata_fail_before_get(self):
        for opener in (Opener(host="unreviewed.example"), Opener(size="4"),
                       Opener(etag="0" * 64)):
            with self.subTest(opener=opener):
                with self.assertRaises(speech.ProvisionError):
                    self.provision(opener)
                self.assertEqual(len(opener.calls), 1)
                self.assertFalse((self.store / speech.NAME).exists())

    def test_truncated_or_modified_body_never_installs(self):
        for data, status in ((b"ab", 200), (b"abd", 200), (b"abcd", 200),
                             (b"abc", 302)):
            with self.subTest(data=data, status=status):
                with self.assertRaises(speech.ProvisionError):
                    self.provision(Opener(content=data, get_status=status))
                self.assertFalse((self.store / speech.NAME).exists())

    def test_parent_symlink_and_asset_symlink_refused(self):
        speech.private_directory(self.store)
        link = Path(self.tmp.name) / "alias"
        link.symlink_to(self.store, target_is_directory=True)
        with self.assertRaises(speech.ProvisionError):
            speech.private_directory(link)
        (self.store / speech.NAME).write_bytes(b"abc")
        with self.assertRaisesRegex(speech.ProvisionError, "symlinked"):
            speech.check_file(link / speech.NAME, 3, self.digest)
        target = self.store / speech.NAME
        target.unlink()
        target.symlink_to(Path(self.tmp.name) / "absent")
        with self.assertRaises(speech.ProvisionError):
            self.provision(Opener())

    def test_dataless_refused_before_open_or_network(self):
        speech.private_directory(self.store)
        target = self.store / speech.NAME
        target.write_bytes(b"abc")
        real_lstat = os.lstat
        actual = real_lstat(target)
        fake = SimpleNamespace(st_mode=actual.st_mode, st_flags=speech.SF_DATALESS,
                               st_nlink=actual.st_nlink)
        with mock.patch.object(speech.os, "lstat", side_effect=lambda path: (
                fake if Path(path) == target else real_lstat(path))), \
                mock.patch.object(speech.os, "open") as open_file:
            with self.assertRaisesRegex(speech.ProvisionError, "dataless"):
                speech.check_file(target, 3, self.digest)
            opener = Opener()
            with self.assertRaisesRegex(speech.ProvisionError, "dataless"):
                self.provision(opener)
        open_file.assert_not_called()
        self.assertEqual(opener.calls, [])
        self.assertEqual(self.policy, 0)

    def test_policy_is_installed_before_open_and_restored_after_failure(self):
        speech.private_directory(self.store)
        target = self.store / speech.NAME
        target.write_bytes(b"abd")
        target.chmod(0o600)
        real_open = os.open

        def observed_open(*args, **kwargs):
            self.assertEqual(self.policy, speech.IOPOL_MATERIALIZE_DATALESS_FILES_OFF)
            self.events.append(("open", Path(args[0])))
            return real_open(*args, **kwargs)

        with mock.patch.object(speech.os, "open", side_effect=observed_open):
            with self.assertRaisesRegex(speech.ProvisionError, "SHA-256"):
                speech.check_file(target, 3, self.digest)
        self.assertEqual([kind for kind, _ in self.events if kind == "open"], ["open"])
        self.assertEqual(self.policy, 0)

    def test_policy_failure_refuses_before_file_or_network(self):
        speech.private_directory(self.store)
        target = self.store / speech.NAME
        target.write_bytes(b"abc")
        for get_failure, set_failure in ((True, False), (False, True)):
            with self.subTest(get_failure=get_failure):
                get_policy = lambda *_: -1 if get_failure else 0
                set_policy = lambda *_: -1 if set_failure else 0
                opener = Opener()
                with mock.patch.object(speech, "_policy_functions",
                                       return_value=(get_policy, set_policy)), \
                        mock.patch.object(speech.os, "open") as open_file:
                    with self.assertRaises(speech.ProvisionError):
                        speech.check_file(target, 3, self.digest)
                    with self.assertRaises(speech.ProvisionError):
                        self.provision(opener)
                open_file.assert_not_called()
                self.assertEqual(opener.calls, [])
        target.unlink()
        opener = Opener()
        with mock.patch.object(speech, "_policy_functions",
                               side_effect=speech.ProvisionError("policy unavailable")):
            with self.assertRaisesRegex(speech.ProvisionError, "policy unavailable"):
                self.provision(opener)
        self.assertEqual(opener.calls, [])

    def test_ineffective_policy_refuses_and_restores(self):
        current = 0
        changes = []

        def get_policy(*_):
            return 0

        def set_policy(*args):
            nonlocal current
            current = args[-1]
            changes.append(current)
            return 0

        with mock.patch.object(speech, "_policy_functions",
                               return_value=(get_policy, set_policy)), \
                mock.patch.object(speech.os, "open") as open_file:
            with self.assertRaisesRegex(speech.ProvisionError, "did not take effect"):
                speech.check_file(self.store / speech.NAME, 3, self.digest)
        open_file.assert_not_called()
        self.assertEqual(changes, [speech.IOPOL_MATERIALIZE_DATALESS_FILES_OFF, 0])
        self.assertEqual(current, 0)

    def test_restore_failure_is_explicit(self):
        policies = iter((0, 1))

        def set_policy(*args):
            return -1 if args[-1] == 0 else 0

        with mock.patch.object(speech, "_policy_functions",
                               return_value=(lambda *_: next(policies), set_policy)):
            with self.assertRaisesRegex(speech.ProvisionError, "Cannot restore"):
                speech.check_file(self.store / speech.NAME, 3, self.digest)

    def test_replacement_during_open_or_hash_refused(self):
        speech.private_directory(self.store)
        target = self.store / speech.NAME
        replacement = self.store / "replacement"
        target.write_bytes(b"abc")
        target.chmod(0o600)
        replacement.write_bytes(b"abc")
        replacement.chmod(0o600)
        real_open = os.open

        def replaced_open(path, flags):
            self.assertEqual(self.policy, speech.IOPOL_MATERIALIZE_DATALESS_FILES_OFF)
            replacement.replace(target)
            return real_open(path, flags)

        with mock.patch.object(speech.os, "open", side_effect=replaced_open):
            with self.assertRaisesRegex(speech.ProvisionError, "mismatch"):
                speech.check_file(target, 3, self.digest)
        self.assertEqual(self.policy, 0)
        replacement.write_bytes(b"abc")
        replacement.chmod(0o600)
        real_lstat = os.lstat
        calls = 0

        def replaced_after_hash(path):
            nonlocal calls
            if Path(path) == target:
                calls += 1
                if calls == 2:
                    replacement.replace(target)
            return real_lstat(path)

        with mock.patch.object(speech.os, "lstat", side_effect=replaced_after_hash):
            with self.assertRaisesRegex(speech.ProvisionError, "changed"):
                speech.check_file(target, 3, self.digest)
        self.assertEqual(self.policy, 0)

    def test_symlink_substituted_during_open_refused(self):
        speech.private_directory(self.store)
        target = self.store / speech.NAME
        target.write_bytes(b"abc")
        target.chmod(0o600)
        real_open = os.open

        def substituted_open(path, flags):
            self.assertEqual(self.policy, speech.IOPOL_MATERIALIZE_DATALESS_FILES_OFF)
            target.unlink()
            target.symlink_to(self.store / "absent")
            return real_open(path, flags)

        with mock.patch.object(speech.os, "open", side_effect=substituted_open):
            with self.assertRaisesRegex(speech.ProvisionError, "not a regular"):
                speech.check_file(target, 3, self.digest)
        self.assertEqual(self.policy, 0)

    def test_hardlink_refused_before_open_and_staged_adoption_checks_identity(self):
        speech.private_directory(self.store)
        target = self.store / speech.NAME
        target.write_bytes(b"abc")
        alias = self.store / "alias"
        os.link(target, alias)
        with mock.patch.object(speech.os, "open") as open_file:
            with self.assertRaisesRegex(speech.ProvisionError, "linked"):
                speech.check_file(target, 3, self.digest)
        open_file.assert_not_called()
        alias.unlink()
        target.unlink()

        real_link = os.link

        def swapped_link(source, destination, **kwargs):
            result = real_link(source, destination, **kwargs)
            Path(destination).unlink()
            Path(destination).write_bytes(b"abc")
            return result

        opener = Opener()
        with mock.patch.object(speech.os, "link", side_effect=swapped_link):
            with self.assertRaisesRegex(speech.ProvisionError, "adoption"):
                self.provision(opener)
        self.assertEqual(self.policy, 0)


class MacOSPolicyTests(unittest.TestCase):
    def test_actual_thread_policy_restores_after_scope(self):
        get_policy, _ = speech._policy_functions()
        previous = get_policy(speech.IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES,
                              speech.IOPOL_SCOPE_THREAD)
        with speech.without_materializing_dataless():
            self.assertEqual(get_policy(speech.IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES,
                                        speech.IOPOL_SCOPE_THREAD),
                             speech.IOPOL_MATERIALIZE_DATALESS_FILES_OFF)
        self.assertEqual(get_policy(speech.IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES,
                                    speech.IOPOL_SCOPE_THREAD), previous)

    def test_provision_and_recheck_with_actual_policy(self):
        with tempfile.TemporaryDirectory(dir="/private/tmp") as root:
            opener = Opener()
            digest = speech.hashlib.sha256(b"abc").hexdigest()
            target = speech.provision(Path(root) / "private", opener=opener,
                                      size=3, digest=digest)
            speech.check_file(target, 3, digest)
            speech.provision(target.parent, opener=opener, size=3, digest=digest)
            self.assertEqual([call[0] for call in opener.calls], ["HEAD", "GET"])


if __name__ == "__main__":
    unittest.main()
