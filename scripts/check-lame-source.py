#!/usr/bin/env python3
"""Verify the bundled encoder/header bytes against the pinned full upstream source."""
import hashlib
import io
from pathlib import Path
import tarfile

root = Path(__file__).resolve().parents[1]
package = root / "Packages/WaveWranglerKit"
archive = package / "ThirdParty/lame-3.100.tar.gz"
expected = "ddfe36cab873794038ae2c1210557ad34857a4b6bdc515785d1da9e175b1da1e"
data = archive.read_bytes()
if hashlib.sha256(data).hexdigest() != expected:
    raise SystemExit("LAME source archive SHA-256 mismatch")
upstream = package / "Sources/WWLameNative/upstream"
checked = 0
with tarfile.open(fileobj=io.BytesIO(data), mode="r:gz") as source:
    for path in sorted(upstream.rglob("*")):
        if not path.is_file():
            continue
        member = source.extractfile(f"lame-3.100/{path.relative_to(upstream).as_posix()}")
        if member is None or member.read() != path.read_bytes():
            raise SystemExit(f"LAME source differs from upstream: {path.relative_to(upstream)}")
        checked += 1
for name in ("COPYING", "LICENSE"):
    resource = package / f"Sources/WWExport/Licenses/{name}"
    if resource.read_bytes() != (upstream / name).read_bytes():
        raise SystemExit(f"Bundled LAME notice differs: {name}")
print(f"LAME 3.100: pinned archive, {checked} unchanged source files, bundled notices verified")
