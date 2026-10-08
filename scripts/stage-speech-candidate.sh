#!/usr/bin/env bash
# Stage the already-provisioned, reviewed speech closure without a shell read of its assets.
set -euo pipefail
exec /usr/bin/python3 "$(dirname "$0")/stage-speech-candidate.py" "$@"
