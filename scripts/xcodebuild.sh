#!/bin/bash
#
# Canonical xcodebuild entry point for GitX.
#
# Every build in this repository must go through this wrapper. It pins three
# things that agents and terminals otherwise get wrong:
#
#   1. DEVELOPER_DIR. The selected Xcode may be a beta that cannot build this
#      workspace. CI pins 26.6, so local builds pin the same stable Xcode.
#   2. -derivedDataPath. Ad-hoc per-session derived data directories turn every
#      build into a cold build and leak gigabytes. One shared path keeps the
#      cache warm across worktrees and sessions.
#   3. Output shaping. Raw xcodebuild output is unreadable; xcbeautify renders
#      it while the full log is still written to disk for grepping.
#
# Usage:
#   scripts/xcodebuild.sh build
#   scripts/xcodebuild.sh test -testPlan GitX
#   scripts/xcodebuild.sh --stage-app build
#   scripts/xcodebuild.sh --raw analyze
#
# Defaults injected only when absent from the caller's arguments:
#   -workspace GitX.xcworkspace
#   -scheme GitX
#   -destination "platform=macOS,arch=arm64"
#   -derivedDataPath build/DerivedData
#   -resultBundlePath build/Logs/last-test.xcresult   (test actions only)
#
# Environment overrides:
#   GITX_DEVELOPER_DIR   alternate Xcode developer directory
#   GITX_DERIVED_DATA    alternate derived data path

set -uo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root" || exit 2

default_developer_dir=/Applications/Xcode.app/Contents/Developer
developer_dir=${GITX_DEVELOPER_DIR:-$default_developer_dir}

if [[ ! -d "$developer_dir" ]]; then
	cat >&2 <<-MESSAGE
		GitX builds require a stable Xcode at:
		  $developer_dir
		Install it, or point GITX_DEVELOPER_DIR at another Xcode developer directory.
	MESSAGE
	exit 2
fi
export DEVELOPER_DIR="$developer_dir"

derived_data=${GITX_DERIVED_DATA:-$root/build/DerivedData}
log_dir=$root/build/Logs
raw_log=$log_dir/last-xcodebuild.log
default_result_bundle=$log_dir/last-test.xcresult

stage_app=0
use_xcbeautify=1
passthrough=()

for argument in "$@"; do
	case "$argument" in
		--stage-app)
			stage_app=1
			;;
		--raw)
			use_xcbeautify=0
			;;
		*)
			passthrough+=("$argument")
			;;
	esac
done

if (( ${#passthrough[@]} == 0 )); then
	echo "Usage: $0 [--stage-app] [--raw] <xcodebuild arguments...>" >&2
	exit 2
fi

joined=" ${passthrough[*]} "
settings=()

if [[ "$joined" != *" -workspace "* && "$joined" != *" -project "* ]]; then
	settings+=(-workspace GitX.xcworkspace)
fi
if [[ "$joined" != *" -scheme "* ]]; then
	settings+=(-scheme GitX)
fi
if [[ "$joined" != *" -destination "* ]]; then
	settings+=(-destination "platform=macOS,arch=arm64")
fi
if [[ "$joined" != *" -derivedDataPath "* ]]; then
	settings+=(-derivedDataPath "$derived_data")
fi

is_test_action=0
for argument in "${passthrough[@]}"; do
	case "$argument" in
		test|test-without-building)
			is_test_action=1
			;;
	esac
done

result_bundle=
if (( is_test_action )) && [[ "$joined" != *" -resultBundlePath "* ]]; then
	result_bundle=$default_result_bundle
	settings+=(-resultBundlePath "$result_bundle")
elif (( is_test_action )); then
	# Remember the caller's bundle so the failure-report hint points at it.
	previous=
	for argument in "${passthrough[@]}"; do
		if [[ "$previous" == "-resultBundlePath" ]]; then
			result_bundle=$argument
			break
		fi
		previous=$argument
	done
fi

mkdir -p "$log_dir"
if [[ -n "$result_bundle" && -e "$result_bundle" ]]; then
	# xcodebuild refuses to overwrite an existing result bundle, so a leftover
	# one must be removed first. Deletion is gated on the .xcresult suffix: a
	# mistyped -resultBundlePath (say, plain "build") must never recursively
	# delete a real directory.
	if [[ "$result_bundle" == *.xcresult ]]; then
		rm -rf "$result_bundle"
	else
		echo "-resultBundlePath $result_bundle exists and is not an .xcresult bundle; refusing to delete it." >&2
		exit 2
	fi
fi

if (( use_xcbeautify )) && ! command -v xcbeautify >/dev/null 2>&1; then
	use_xcbeautify=0
fi

# The settings array is empty when the caller supplies every default, and
# macOS ships bash 3.2, where `set -u` treats expanding an empty array as an
# unbound-variable error. The ${settings[@]+...} form expands to nothing there.
if (( use_xcbeautify )); then
	xcodebuild ${settings[@]+"${settings[@]}"} "${passthrough[@]}" 2>&1 \
		| tee "$raw_log" \
		| xcbeautify --disable-logging
	status=${PIPESTATUS[0]}
else
	xcodebuild ${settings[@]+"${settings[@]}"} "${passthrough[@]}" 2>&1 | tee "$raw_log"
	status=${PIPESTATUS[0]}
fi

if (( status != 0 )); then
	echo >&2
	echo "xcodebuild failed (exit $status). Full log: $raw_log" >&2
	if [[ -n "$result_bundle" && -d "$result_bundle" ]]; then
		echo "Failing tests: scripts/report_xcresult.py $result_bundle" >&2
	fi
	exit "$status"
fi

if (( stage_app )); then
	products_dir=$(
		xcodebuild ${settings[@]+"${settings[@]}"} "${passthrough[@]}" -showBuildSettings 2>/dev/null \
			| awk -F' = ' '/ BUILT_PRODUCTS_DIR = /{print $2; exit}'
	)
	if [[ -z "$products_dir" || ! -d "$products_dir/GitX.app" ]]; then
		echo "Could not locate GitX.app to stage from build settings." >&2
		exit 3
	fi
	staged_bundle=$root/build/GitX.app
	# Swapping the bundle out from under a running instance invalidates its
	# code signature mid-flight; macOS can kill the process and observation
	# becomes ambiguous.
	running_pids=$(
		pgrep -x GitX 2>/dev/null | while read -r pid; do
			# The leading "(" keeps bash 3.2's $() parser from tripping on the
			# pattern's unbalanced ")".
			case "$(ps -p "$pid" -o comm= 2>/dev/null)" in
				("$staged_bundle"/*) printf '%s ' "$pid" ;;
			esac
		done
	)
	if [[ -n "${running_pids// /}" ]]; then
		echo "GitX is still running from $staged_bundle (pid(s): $running_pids)." >&2
		echo "Stop it first (scripts/run_app.sh --stop), then re-run --stage-app." >&2
		exit 3
	fi
	rm -rf "$staged_bundle"
	# ditto preserves the bundle's symlinks and extended attributes; cp -R does not.
	ditto "$products_dir/GitX.app" "$staged_bundle"
	echo "Staged app: $staged_bundle"
fi

if [[ -n "$result_bundle" && -d "$result_bundle" ]]; then
	echo "Result bundle: $result_bundle"
fi
