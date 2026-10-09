#!/usr/bin/env bash
# Verify the signed-product check fails closed even when Python assertions are disabled.
# Usage: scripts/test-offline-test-signing.sh <Products directory>
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PRODUCTS="${1:?usage: scripts/test-offline-test-signing.sh <Products directory>}"
CHECK="$ROOT/scripts/check-offline-test-signing.sh"

bash "$CHECK" "$PRODUCTS"
PYTHONOPTIMIZE=1 bash "$CHECK" "$PRODUCTS"

mkdir -p "$ROOT/.build"
fixture="$(mktemp -d "$ROOT/.build/offline-signing-test.XXXXXX")"
trap 'rm -R -- "$fixture"' EXIT
mkdir -p "$fixture/Debug"
ditto "$PRODUCTS/Debug/WaveWrangler.app" "$fixture/Debug/WaveWrangler.app"
ditto "$PRODUCTS/Debug/WaveWranglerUITests-Runner.app" "$fixture/Debug/WaveWranglerUITests-Runner.app"
cat > "$fixture/incorrect-app-entitlements.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.app-sandbox</key>
    <true/>
    <key>com.apple.security.network.client</key>
    <true/>
</dict>
</plist>
PLIST
codesign --force --sign - --entitlements "$fixture/incorrect-app-entitlements.plist" "$fixture/Debug/WaveWrangler.app"

check_rejected() {
    local label="$1"
    local expected="$2"
    local output
    for optimize in 0 1; do
        if output="$(PYTHONOPTIMIZE="$optimize" bash "$CHECK" "$fixture" 2>&1)"; then
            echo "$label passed with PYTHONOPTIMIZE=$optimize" >&2
            exit 1
        fi
        if ! grep -Fqx "$expected" <<< "$output"; then
            echo "$label failed for the wrong reason with PYTHONOPTIMIZE=$optimize: $output" >&2
            exit 1
        fi
    done
}

check_rejected "Incorrectly entitled signed app" "signed app unexpectedly has com.apple.security.network.client"
codesign --force --sign - --entitlements "$ROOT/WaveWrangler/WaveWrangler.entitlements" "$fixture/Debug/WaveWrangler.app"
cat > "$fixture/incorrect-runner-entitlements.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.app-sandbox</key>
    <true/>
    <key>com.apple.security.network.client</key>
    <true/>
</dict>
</plist>
PLIST
codesign --force --sign - --entitlements "$fixture/incorrect-runner-entitlements.plist" "$fixture/Debug/WaveWranglerUITests-Runner.app"
check_rejected "Runner without network.server" "test runner cannot bind local peers"
echo "Incorrect app and runner signatures rejected with and without Python optimization."
