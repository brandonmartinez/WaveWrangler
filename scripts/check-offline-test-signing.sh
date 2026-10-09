#!/usr/bin/env bash
# Check effective signatures of built Products, not just source entitlement plists.
set -euo pipefail

PRODUCTS="${1:?usage: scripts/check-offline-test-signing.sh <Products directory>}"
/usr/bin/python3 - "$PRODUCTS" <<'PY'
import plistlib
import subprocess
import sys
from pathlib import Path

products = Path(sys.argv[1])


def signed_entitlements(name):
    path = products / "Debug" / name
    subprocess.run(
        ["/usr/bin/codesign", "--verify", "--deep", "--strict", str(path)],
        check=True,
    )
    result = subprocess.run(
        ["/usr/bin/codesign", "-d", "--entitlements", ":-", str(path)],
        check=True,
        capture_output=True,
    )
    return plistlib.loads(result.stdout)


app = signed_entitlements("WaveWrangler.app")
runner = signed_entitlements("WaveWranglerUITests-Runner.app")


def require(condition, message):
    if not condition:
        raise SystemExit(message)


require(app.get("com.apple.security.app-sandbox") is True, "signed app is not sandboxed")
for key in ("com.apple.security.network.client", "com.apple.security.network.server"):
    require(key not in app, f"signed app unexpectedly has {key}")
require(runner.get("com.apple.security.app-sandbox") is True, "signed test runner is not sandboxed")
require(runner.get("com.apple.security.network.client") is True, "test runner cannot reach local peers")
require(runner.get("com.apple.security.network.server") is True, "test runner cannot bind local peers")
print("Signed app has no network entitlements; signed UI runner can bind local synthetic peers.")
PY
