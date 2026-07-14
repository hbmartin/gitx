#!/bin/bash

set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"

if (( $# == 0 )); then
	echo "Usage: $0 <swiftformat|swiftlint> [arguments...]" >&2
	exit 2
fi

tool=$1
shift

case "$tool" in
	swiftformat)
		expected=0.62.1
		version_arguments=(--version)
		;;
	swiftlint)
		expected=0.63.2
		version_arguments=(version)
		;;
	*)
		echo "Unsupported pinned tool: $tool" >&2
		exit 2
		;;
esac

if command -v mint >/dev/null 2>&1; then
	exec mint run --silent "$tool" "$@"
fi

if command -v "$tool" >/dev/null 2>&1; then
	actual=$($tool "${version_arguments[@]}")
	if [[ "$actual" == "$expected" ]]; then
		exec "$tool" "$@"
	fi
	echo "$tool $actual is installed, but GitX pins $expected" >&2
	exit 1
fi

echo "$tool $expected is required. Install Mint with 'brew install mint'; Mintfile will install the pinned tool." >&2
exit 1
