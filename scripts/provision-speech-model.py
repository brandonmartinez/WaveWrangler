#!/usr/bin/env python3
"""Provision the reviewed whisper.cpp model off-repository; never used by inference."""

import argparse
import hashlib
import os
from pathlib import Path
import stat
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


class ProvisionError(Exception):
    pass


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
    try:
        fd = os.open(path, os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW | os.O_NONBLOCK)
    except OSError as error:
        raise ProvisionError("Model absent or not a regular local file") from error
    try:
        before = os.fstat(fd)
        if (not stat.S_ISREG(before.st_mode) or before.st_uid != os.getuid()
                or before.st_mode & 0o077 or before.st_size != size
                or getattr(before, "st_flags", 0) & 0x40000000):
            raise ProvisionError("Model ownership, size or locality mismatch")
        sha = hashlib.sha256()
        with os.fdopen(os.dup(fd), "rb") as stream:
            for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                sha.update(chunk)
        after = os.fstat(fd)
        pathname = os.lstat(path)
        if (before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns, before.st_ctime_ns) != (
                after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns, after.st_ctime_ns
        ) or (after.st_dev, after.st_ino) != (pathname.st_dev, pathname.st_ino):
            raise ProvisionError("Model changed during verification")
        if sha.hexdigest() != digest:
            raise ProvisionError("Model SHA-256 mismatch")
    finally:
        os.close(fd)


def provision(directory, opener=None, source=SOURCE, size=SIZE, digest=SHA256,
              cdn_host=CDN_HOST):
    directory = private_directory(directory)
    target = directory / NAME
    if target.exists() or target.is_symlink():
        check_file(target, size, digest)
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
                if written != size or sha.hexdigest() != digest:
                    raise ProvisionError("Downloaded model size or SHA-256 mismatch")
                if target.exists() or target.is_symlink():
                    raise ProvisionError("Model appeared during provisioning")
                os.link(temporary, target, follow_symlinks=False)
                check_file(target, size, digest)
            finally:
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
            check_file(private_directory(directory) / NAME)
        else:
            provision(directory)
    except ProvisionError as error:
        parser.exit(1, f"Speech asset refused: {error}\n")
    print("Pinned speech model verified (offline preflight)" if args.check else "Pinned speech model provisioned and verified")


if __name__ == "__main__":
    main()
