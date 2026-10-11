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

set_if_changed() {
	local key=$1 value=$2 current
	if current=$(/usr/libexec/PlistBuddy -c "Print :$key" "$info_plist" 2>/dev/null); then
		if [[ "$current" != "$value" ]]; then
			/usr/libexec/PlistBuddy -c "Set :$key $value" "$info_plist"
		fi
	else
		/usr/libexec/PlistBuddy -c "Add :$key string $value" "$info_plist"
	fi
}

set_if_changed CFBundleBuildVersion "$build_version"
set_if_changed CFBundleShortVersionString "$build_version"
set_if_changed CFBundleVersion "$bundle_version"
