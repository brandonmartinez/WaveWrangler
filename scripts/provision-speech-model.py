#!/usr/bin/env python3
"""Provision the reviewed whisper.cpp model off-repository; never used by inference."""

import argparse
from contextlib import contextmanager
import ctypes
import hashlib
import os
from pathlib import Path
import stat
import sys
import tempfile
import urllib.error
import urllib.parse
import urllib.request


NAME = "ggml-base.en.bin"
REVISION = "5359861c739e955e79d9a303bcbc70fb988958b1"
SOURCE = f"https://huggingface.co/ggerganov/whisper.cpp/resolve/{REVISION}/{NAME}"
SIZE = 147_964_211
SHA256 = "a03779c86df3323075f5e796cb2ce5029f00ec8869eee3fdfb897afe36c6d002"
CDN_HOST = "us.aws.cdn.hf.co"
SF_DATALESS = 0x40000000
IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES = 3
IOPOL_SCOPE_PROCESS = 0
IOPOL_SCOPE_THREAD = 1
IOPOL_MATERIALIZE_DATALESS_FILES_OFF = 1


class ProvisionError(Exception):
    pass


def _policy_functions():
    if sys.platform != "darwin":
        raise ProvisionError("macOS dataless-file policy is required")
    try:
        libc = ctypes.CDLL(None, use_errno=True)
        get_policy = libc.getiopolicy_np
        set_policy = libc.setiopolicy_np
    except (OSError, AttributeError) as error:
        raise ProvisionError("macOS dataless-file policy is unavailable") from error
    get_policy.argtypes = (ctypes.c_int, ctypes.c_int)
    get_policy.restype = ctypes.c_int
    set_policy.argtypes = (ctypes.c_int, ctypes.c_int, ctypes.c_int)
    set_policy.restype = ctypes.c_int
    return get_policy, set_policy


@contextmanager
def without_materializing_dataless():
    get_policy, set_policy = _policy_functions()
    previous = get_policy(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD)
    if previous < 0:
        raise ProvisionError("Cannot read macOS dataless-file policy")
    if set_policy(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD,
                  IOPOL_MATERIALIZE_DATALESS_FILES_OFF) != 0:
        raise ProvisionError("Cannot disable macOS dataless-file materialization")
    try:
        if get_policy(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD) != (
                IOPOL_MATERIALIZE_DATALESS_FILES_OFF):
            raise ProvisionError("macOS dataless-file policy did not take effect")
        yield
    finally:
        if set_policy(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD,
                      previous) != 0:
            raise ProvisionError("Cannot restore macOS dataless-file policy")


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, fp, code, msg, headers, newurl):
        return None


def private_directory(directory):
    directory = Path(os.path.abspath(directory))
    for parent in reversed((directory, *directory.parents)):
        if parent.exists() or parent.is_symlink():
            info = parent.lstat()
            if not stat.S_ISDIR(info.st_mode):
                raise ProvisionError("Asset store has a non-directory or symlinked parent")
        else:
            parent.mkdir(mode=0o700)
    info = directory.lstat()
    if info.st_uid != os.getuid() or info.st_mode & 0o077:
        raise ProvisionError("Asset store must be owner-private")
    if info.st_dev != os.stat("/private/tmp").st_dev:
        raise ProvisionError("Asset store must be on the local staging volume")
    return directory


def check_file(path, size=SIZE, digest=SHA256):
    with without_materializing_dataless():
        _check_file(path, size, digest)


def _identity(info):
    return (info.st_dev, info.st_ino, info.st_mode, info.st_uid, info.st_nlink,
            info.st_size, info.st_mtime_ns, info.st_ctime_ns,
            getattr(info, "st_flags", 0))


def _parent_identities(path):
    identities = []
    for parent in path.parents:
        try:
            info = os.lstat(parent)
        except OSError as error:
            raise ProvisionError("Model parent disappeared during verification") from error
        if not stat.S_ISDIR(info.st_mode):
            raise ProvisionError("Model has a symlinked or non-directory parent")
        identities.append((info.st_dev, info.st_ino))
    return identities


def _check_file(path, size, digest, owner_private=True):
    path = Path(os.path.abspath(path))
    parents_before = _parent_identities(path)
    try:
        pathname_before = os.lstat(path)
    except OSError as error:
        raise ProvisionError("Model absent or not a regular local file") from error
    if (not stat.S_ISREG(pathname_before.st_mode)
            or getattr(pathname_before, "st_flags", 0) & SF_DATALESS
            or pathname_before.st_nlink != 1):
        raise ProvisionError("Model is dataless, linked or not a regular local file")
    try:
        fd = os.open(path, os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW | os.O_NONBLOCK)
    except OSError as error:
        raise ProvisionError("Model absent or not a regular local file") from error
    try:
        before = os.fstat(fd)
        if (not stat.S_ISREG(before.st_mode) or before.st_uid != os.getuid()
                or (owner_private and before.st_mode & 0o077) or before.st_size != size
                or before.st_nlink != 1 or getattr(before, "st_flags", 0) & SF_DATALESS
                or before.st_dev != os.stat("/private/tmp").st_dev
                or _identity(pathname_before) != _identity(before)):
            raise ProvisionError("Model ownership, size or locality mismatch")
        sha = hashlib.sha256()
        with os.fdopen(os.dup(fd), "rb") as stream:
            for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                sha.update(chunk)
        after = os.fstat(fd)
        try:
            pathname = os.lstat(path)
        except OSError as error:
            raise ProvisionError("Model disappeared during verification") from error
        if (_identity(before) != _identity(after)
                or _identity(after) != _identity(pathname)
                or parents_before != _parent_identities(path)):
            raise ProvisionError("Model changed during verification")
        if sha.hexdigest() != digest:
            raise ProvisionError("Model SHA-256 mismatch")
    finally:
        os.close(fd)


def provision(directory, opener=None, source=SOURCE, size=SIZE, digest=SHA256,
              cdn_host=CDN_HOST):
    with without_materializing_dataless():
        return _provision(directory, opener, source, size, digest, cdn_host)


def _provision(directory, opener, source, size, digest, cdn_host):
    directory = private_directory(directory)
    target = directory / NAME
    if target.exists() or target.is_symlink():
        _check_file(target, size, digest)
        return target
    opener = opener or urllib.request.build_opener(NoRedirect)
    try:
        try:
            head = opener.open(urllib.request.Request(source, method="HEAD"), timeout=30)
        except urllib.error.HTTPError as error:
            if error.code != 302:
                raise
            head = error
        with head:
            if head.status != 302:
                raise ProvisionError("Publisher resolver did not return the reviewed redirect")
            linked_size = head.headers.get("X-Linked-Size")
            linked_etag = head.headers.get("X-Linked-Etag", "").strip('"')
            location = head.headers.get("Location", "")
            url = urllib.parse.urlsplit(location)
            if (linked_size != str(size) or linked_etag != digest
                    or url.scheme != "https" or url.hostname != cdn_host
                    or url.username or url.password or url.port or not url.path):
                raise ProvisionError("Publisher asset metadata or redirect differs from reviewed pin")
        with opener.open(urllib.request.Request(location, method="GET"), timeout=120) as body:
            if body.status != 200 or body.headers.get("Content-Length") != str(size):
                raise ProvisionError("CDN response differs from reviewed size")
            fd, temporary = tempfile.mkstemp(prefix=".speech-model-", dir=directory)
            try:
                written = 0
                sha = hashlib.sha256()
                with os.fdopen(fd, "wb") as output:
                    while chunk := body.read(1024 * 1024):
                        written += len(chunk)
                        if written > size:
                            raise ProvisionError("Model body exceeds reviewed size")
                        sha.update(chunk)
                        output.write(chunk)
                    output.flush()
                    os.fsync(output.fileno())
                    staged = os.fstat(output.fileno())
                if written != size or sha.hexdigest() != digest:
                    raise ProvisionError("Downloaded model size or SHA-256 mismatch")
                if target.exists() or target.is_symlink():
                    raise ProvisionError("Model appeared during provisioning")
                if _identity(os.lstat(temporary)) != _identity(staged) or staged.st_nlink != 1:
                    raise ProvisionError("Staged model changed during provisioning")
                os.link(temporary, target, follow_symlinks=False)
                linked = os.lstat(target)
                if (linked.st_dev, linked.st_ino) != (staged.st_dev, staged.st_ino):
                    raise ProvisionError("Staged model changed during adoption")
                os.unlink(temporary)
                _check_file(target, size, digest)
            finally:
                if os.path.lexists(temporary):
                    os.unlink(temporary)
    except (urllib.error.URLError, TimeoutError, OSError) as error:
        raise ProvisionError("Secure publisher fetch or local write failed") from error
    return target


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="Rehash installed asset with no network access")
    args = parser.parse_args()
    directory = Path.home() / "Library/Application Support/WaveWrangler/SpeechModels"
    try:
        if args.check:
            with without_materializing_dataless():
                _check_file(private_directory(directory) / NAME, SIZE, SHA256)
        else:
            provision(directory)
    except ProvisionError as error:
        parser.exit(1, f"Speech asset refused: {error}\n")
    print("Pinned speech model verified (offline preflight)" if args.check else "Pinned speech model provisioned and verified")


if __name__ == "__main__":
    main()
