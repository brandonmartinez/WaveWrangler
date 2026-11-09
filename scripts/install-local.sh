#!/usr/bin/env bash
# Build, verify, and install an ad-hoc signed app for local manual testing.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIGURATION="${1:-Debug}"
if [[ $# -gt 1 || "$CONFIGURATION" != Debug && "$CONFIGURATION" != Release ]]; then
  echo "Usage: scripts/install-local.sh [Debug|Release]" >&2
  exit 2
fi

INSTALL_DIR="${WW_INSTALL_DIR:-/Applications}"
if [[ ! -d "$INSTALL_DIR" || ! -w "$INSTALL_DIR" ]]; then
  echo "error: installation directory must exist and be writable: $INSTALL_DIR" >&2
  echo "Use WW_INSTALL_DIR=\"\$HOME/Applications\" for a user-owned installation; do not run the build with sudo." >&2
  exit 1
fi
INSTALL_DIR="$(cd "$INSTALL_DIR" && pwd -P)"
DESTINATION="$INSTALL_DIR/WaveWrangler.app"
LOCK="$INSTALL_DIR/.WaveWrangler.install.lock"
STAGING=""
INSTALLED=0
PUBLISHING=0
BUNDLE_ID="com.brandonmartinez.wavewrangler"

check_not_running() {
  local status
  if pgrep -x WaveWrangler >/dev/null; then
    echo "error: quit WaveWrangler before installing; no running app will be replaced or terminated." >&2
    return 1
  else
    status=$?
    if [[ "$status" -ne 1 ]]; then
      echo "error: could not determine whether WaveWrangler is running (pgrep exit $status)." >&2
      return 1
    fi
  fi
}

verify_app() {
  local app="$1" identity
  codesign --verify --deep --strict "$app"
  identity=$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - "$app/Contents/Info.plist")
  if [[ "$identity" != "$BUNDLE_ID" ]]; then
    echo "error: unexpected bundle identifier at $app: $identity" >&2
    return 1
  fi
}

check_destination() {
  local identity
  if [[ -L "$DESTINATION" || -e "$DESTINATION" && ! -d "$DESTINATION" ]]; then
    echo "error: refusing to replace a symlink or non-directory: $DESTINATION" >&2
    return 1
  fi
  if [[ -d "$DESTINATION" ]]; then
    identity=$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - "$DESTINATION/Contents/Info.plist")
    if [[ "$identity" != "$BUNDLE_ID" ]]; then
      echo "error: refusing to replace another app: $DESTINATION" >&2
      return 1
    fi
  fi
}

check_not_running
check_destination
if ! mkdir "$LOCK"; then
  echo "error: another installer may be active. If interrupted, inspect and remove only the empty lock: $LOCK" >&2
  exit 1
fi

cleanup() {
  local status=$?
  trap - EXIT INT TERM
  if [[ -n "$STAGING" ]]; then
    if [[ "$INSTALLED" -eq 0 && -d "$STAGING/previous.app" ]]; then
      if [[ -e "$DESTINATION" ]]; then
        mv "$DESTINATION" "$STAGING/failed.app" || {
          echo "error: rollback failed; previous app preserved at $STAGING/previous.app" >&2
          rmdir "$LOCK"
          exit 1
        }
      fi
      mv "$STAGING/previous.app" "$DESTINATION" || {
        echo "error: rollback failed; previous app preserved at $STAGING/previous.app" >&2
        rmdir "$LOCK"
        exit 1
      }
    elif [[ "$INSTALLED" -eq 0 && "$PUBLISHING" -eq 1 && ! -e "$STAGING/WaveWrangler.app" && -d "$DESTINATION" ]]; then
      mv "$DESTINATION" "$STAGING/failed.app"
    fi
    rm -rf "$STAGING"
  fi
  rmdir "$LOCK"
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

export WW_DERIVED_DATA="${WW_DERIVED_DATA:-$ROOT/.build/LocalInstallDerivedData}"
if [[ "$WW_DERIVED_DATA" != /* ]]; then
  export WW_DERIVED_DATA="$ROOT/$WW_DERIVED_DATA"
fi
bash "$ROOT/scripts/build.sh" "$CONFIGURATION"
APP="$WW_DERIVED_DATA/Build/Products/$CONFIGURATION/WaveWrangler.app"
verify_app "$APP"

STAGING="$(mktemp -d "$INSTALL_DIR/.WaveWrangler.install.XXXXXX")"
ditto "$APP" "$STAGING/WaveWrangler.app"
verify_app "$STAGING/WaveWrangler.app"
diff -qr "$APP" "$STAGING/WaveWrangler.app"
check_not_running
check_destination
if [[ -e "$DESTINATION" ]]; then
  mv "$DESTINATION" "$STAGING/previous.app"
fi
PUBLISHING=1
mv "$STAGING/WaveWrangler.app" "$DESTINATION"
verify_app "$DESTINATION"
diff -qr "$APP" "$DESTINATION"
INSTALLED=1

VERSION=$(/usr/bin/plutil -extract CFBundleShortVersionString raw -o - "$DESTINATION/Contents/Info.plist")
BUILD=$(/usr/bin/plutil -extract CFBundleVersion raw -o - "$DESTINATION/Contents/Info.plist")
printf '\nInstalled WaveWrangler %s (build %s)\nApp: %s\n' "$VERSION" "$BUILD" "$DESTINATION"
