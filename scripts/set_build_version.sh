#!/bin/bash

# Set the built app's version fields from the checked-out Git revision.

set -o errexit
set -o nounset

git_command="$(xcrun -find git)"
readonly git_command
readonly info_plist="${TARGET_BUILD_DIR}/${INFOPLIST_PATH}"

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

/usr/libexec/PlistBuddy -c "Add :CFBundleBuildVersion string $build_version" "$info_plist" 2>/dev/null \
	|| /usr/libexec/PlistBuddy -c "Set :CFBundleBuildVersion $build_version" "$info_plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $build_version" "$info_plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $bundle_version" "$info_plist"
