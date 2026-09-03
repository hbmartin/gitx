#!/bin/bash

set -uo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
exec python3 "$root/scripts/verification_support.py" doctor "$@"
