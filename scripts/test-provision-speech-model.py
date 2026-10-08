#!/usr/bin/env python3
"""Synthetic, network-free tests for the exact-model provisioner."""

import importlib.util
import io
from pathlib import Path
import tempfile
import unittest


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

    def provision(self, opener):
        return speech.provision(self.store, opener=opener, size=3, digest=self.digest)

    def test_provision_and_offline_cold_recheck(self):
        opener = Opener()
        target = self.provision(opener)
        self.assertEqual([call[0] for call in opener.calls], ["HEAD", "GET"])
        self.assertEqual(target.read_bytes(), b"abc")
        self.provision(opener)
        self.assertEqual(len(opener.calls), 2)
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
        target = self.store / speech.NAME
        target.symlink_to(Path(self.tmp.name) / "absent")
        with self.assertRaises(speech.ProvisionError):
            self.provision(Opener())


if __name__ == "__main__":
    unittest.main()
