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
	CLANG_STATIC_ANALYZER_MODE_ON_ANALYZE_ACTION=deep \
	CLANG_WARN_NULLABILITY_COMPLETENESS=YES \
	CLANG_WARN_NULLABILITY_COMPLETENESS_ON_ARRAYS=YES \
	CODE_SIGN_IDENTITY="-" \
    2>&1 | tee "$log_path"

python3 scripts/check_analyzer_diagnostics.py "$log_path"
scripts/run_pinned_tool.sh swiftlint analyze --strict --config .swiftlint.yml --baseline .swiftlint-baseline.json --compiler-log-path "$log_path"
