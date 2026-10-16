#!/usr/bin/env bash
# Validate the actual app payload before packaging and after extraction/mounting.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
[[ $# == 2 ]] || { echo "Usage: $0 APP ARCHITECTURE" >&2; exit 2; }
app_path=$1
expected_arch=$2
executable_path="$app_path/Contents/MacOS/GitX"
[[ -x "$executable_path" ]] || { echo "GitX executable is missing from $app_path" >&2; exit 1; }

codesign --verify --deep --strict --verbose=2 "$app_path"
signature_details=$(codesign --display --verbose=4 "$app_path" 2>&1)
if ! grep -q '^Authority=Developer ID Application:' <<<"$signature_details"; then
	echo "$app_path is not signed with a Developer ID Application certificate" >&2
	exit 1
fi
xcrun stapler validate "$app_path"
spctl --assess --type execute --verbose=4 "$app_path"
python3 "$root/scripts/check_bundle_identifiers.py" "$app_path"
actual_archs=$(lipo -archs "$executable_path")
if [[ "$actual_archs" != "$expected_arch" ]]; then
	echo "$app_path must contain only $expected_arch; found $actual_archs" >&2
	exit 1
fi
echo "[gitx-package] Verified signed, stapled $expected_arch app payload"
