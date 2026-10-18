#!/usr/bin/env bash
# Validate the actual app payload before packaging and after extraction/mounting.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
[[ $# == 2 || $# == 3 ]] || { echo "Usage: $0 APP ARCHITECTURE [STAGE]" >&2; exit 2; }
app_path=$1
expected_arch=$2
stage=${3:-input}
executable_path="$app_path/Contents/MacOS/GitX"
check()
{
	local name=$1
	shift
	echo "[gitx-package] $stage: $name ($expected_arch): $app_path"
	if "$@"; then
		return 0
	else
		local status=$?
		echo "[gitx-package] $stage: $name failed ($status): $app_path" >&2
		return "$status"
	fi
}
check executable test -x "$executable_path"
check signature codesign --verify --deep --strict --verbose=2 "$app_path"
if signature_details=$(codesign --display --verbose=4 "$app_path" 2>&1); then
	:
else
	status=$?
	echo "[gitx-package] $stage: signature authority failed ($status): $app_path: $signature_details" >&2
	exit "$status"
fi
if ! grep -q '^Authority=Developer ID Application:' <<<"$signature_details"; then
	echo "[gitx-package] $stage: $app_path is not signed with a Developer ID Application certificate" >&2
	exit 1
fi
check notarization-ticket xcrun stapler validate "$app_path"
check gatekeeper spctl --assess --type execute --verbose=4 "$app_path"
check bundle-identifiers python3 "$root/scripts/check_bundle_identifiers.py" "$app_path"
if actual_archs=$(lipo -archs "$executable_path"); then
	:
else
	status=$?
	echo "[gitx-package] $stage: architecture inspection failed ($status): $app_path" >&2
	exit "$status"
fi
if [[ "$actual_archs" != "$expected_arch" ]]; then
	echo "[gitx-package] $stage: $app_path must contain only $expected_arch; found $actual_archs" >&2
	exit 1
fi
echo "[gitx-package] $stage: verified signed, stapled $expected_arch payload: $app_path"
