#!/bin/bash

set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
if [[ -n "${RUNNER_TEMP:-}" ]]; then
    default_temp=$RUNNER_TEMP
else
    default_temp=/tmp
fi
derived_data=${DERIVED_DATA_PATH:-"$default_temp/GitXAnalyze"}
log_path=${ANALYZER_LOG_PATH:-"$default_temp/GitXAnalyze.log"}

cd "$root"
xcodebuild analyze \
    -workspace GitX.xcworkspace \
    -scheme GitX \
    -configuration Debug \
    -destination "platform=macOS,arch=arm64" \
    -derivedDataPath "$derived_data" \
    ARCHS=arm64 \
    CODE_SIGN_IDENTITY="-" \
    2>&1 | tee "$log_path"

python3 scripts/check_analyzer_diagnostics.py "$log_path"
