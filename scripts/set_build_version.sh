#!/bin/bash

# Generate the app's Info.plist input before Xcode processes and signs it.

set -o errexit
set -o nounset

git_command="$(xcrun -find git)"
readonly git_command
readonly template=$1 output=$2
info_plist="$(mktemp "${output}.XXXXXX")"
readonly info_plist
trap 'rm -f -- "$info_plist"' EXIT
cp -- "$template" "$info_plist"

# Build version: closest tag or commit, dirty marker, and branch name.
build_version="$("$git_command" describe --tags --always --dirty=-dirty)-$("$git_command" rev-parse --abbrev-ref HEAD)"
readonly build_version

# Tagged builds use the latest v-prefixed release. Tagless forks use 0.0 so
# their bundle version remains valid and deterministic instead of failing.
latest_tag="$("$git_command" describe --tags --abbrev=0 2>/dev/null || true)"
latest_tag="${latest_tag##v}"
readonly short_version="${latest_tag:-0.0}"
architecture="$(uname -p)"
readonly architecture
commit_count="$("$git_command" rev-list --count HEAD)"
readonly commit_count
readonly bundle_version="${short_version}.${commit_count} [${architecture}]"

echo "BUILD VERSION: $build_version"
echo "SHORT VERSION: $short_version"
echo "BUNDLE VERSION: $bundle_version"

/usr/libexec/PlistBuddy -x \
	-c "Delete :CFBundleShortVersionString" \
	-c "Add :CFBundleShortVersionString string $build_version" \
	-c "Delete :CFBundleVersion" \
	-c "Add :CFBundleVersion string $bundle_version" \
	-c "Add :CFBundleBuildVersion string $build_version" "$info_plist"

# Leave the existing input untouched when neither its template nor its version changed.
if ! cmp -s "$info_plist" "$output"; then
	mv -f -- "$info_plist" "$output"
fi
