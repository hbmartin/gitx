#!/usr/bin/env bash
# Keep the established entry point; orchestration retains structured diagnostics.
set -euo pipefail
root=$(cd "$(dirname "$0")" && pwd)
exec python3 "$root/notarize_distribution.py" "$@"
