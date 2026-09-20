#!/bin/bash
#
# Inspect the GitX instance launched by scripts/run_app.sh.
#
# Usage:
#   scripts/observe_app.sh logs [pattern]
#   scripts/observe_app.sh id
#   scripts/observe_app.sh image [output.png]
#   scripts/observe_app.sh see [output.png]
#   scripts/observe_app.sh tree [pattern]

set -uo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
session_dir=$root/build/Logs/run-app
session_file=$session_dir/session.txt
app_pid_file=$session_dir/app.pid

usage() {
	awk 'NR == 1 { next } /^#/ { sub(/^#[[:space:]]?/, ""); print; next } { exit }' "$0"
}

load_session() {
	[[ -f "$session_file" ]] || {
		echo "No run-app session found at $session_file." >&2
		return 1
	}
	app_pid=
	repository=
	os_log=
	stdout=
	while IFS='=' read -r key value; do
		case "$key" in
		app_pid) app_pid=$value ;;
		repository) repository=$value ;;
		os_log) os_log=$value ;;
		stdout) stdout=$value ;;
		esac
	done <"$session_file"
}

process_start_time() {
	local pid=$1
	ps -p "$pid" -o lstart= 2>/dev/null | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
}

validate_app_identity() {
	local recorded_pid recorded_start_time executable current_start_time
	load_session || return 1
	[[ -f "$app_pid_file" ]] || {
		echo "The run-app session has no recorded GitX process identity." >&2
		return 1
	}
	IFS=$'\t' read -r recorded_pid recorded_start_time <"$app_pid_file" || return 1
	if [[ ! "$recorded_pid" =~ ^[0-9]+$ ]] || [[ "$app_pid" != "$recorded_pid" ]]; then
		echo "The run-app session and process identity do not match." >&2
		return 1
	fi
	if [[ -z "$recorded_start_time" ]] || ! kill -0 "$app_pid" 2>/dev/null; then
		echo "The recorded GitX process is no longer running." >&2
		return 1
	fi
	executable=$(ps -p "$app_pid" -o comm= 2>/dev/null)
	case "$executable" in
		GitX | */GitX) ;;
		*) echo "PID $app_pid is not the recorded GitX executable." >&2; return 1 ;;
	esac
	current_start_time=$(process_start_time "$app_pid") || return 1
	if [[ "$current_start_time" != "$recorded_start_time" ]]; then
		echo "PID $app_pid was reused after the run-app session started." >&2
		return 1
	fi
}

require_peekaboo() {
	command -v peekaboo >/dev/null 2>&1 || {
		echo "peekaboo is required for live GitX inspection." >&2
		return 1
	}
}

repository_window() {
	local windows repository_name
	repository_name=$(basename "$repository")
	windows=$(peekaboo list windows --pid "$app_pid" --include-details ids --json 2>/dev/null) || {
		echo "Could not list windows for GitX pid $app_pid." >&2
		return 1
	}
	printf '%s' "$windows" | python3 -c '
import json
import sys

repository = sys.argv[1]
try:
    payload = json.load(sys.stdin)
except json.JSONDecodeError as error:
    raise SystemExit(f"Invalid peekaboo window response: {error}")
windows = payload.get("data", {}).get("windows", [])
matches = [window for window in windows if repository in str(window.get("title", ""))]
matches.sort(key=lambda window: (
    not bool(window.get("isMainWindow")),
    int(window.get("index", 2**31 - 1)),
    int(window.get("windowID", 2**31 - 1)),
))
if not matches:
    raise SystemExit(f"No GitX window contains repository name {repository!r}.")
window = matches[0]
title = str(window.get("title", "")).replace("\t", " ").replace("\n", " ")
print("{}\t{}".format(window["windowID"], title))
' "$repository_name"
}

show_logs() {
	local pattern=${1:-} found=0 file label
	load_session || return 1
	for label in os_log stdout; do
		if [[ "$label" == os_log ]]; then file=$os_log; else file=$stdout; fi
		[[ -n "$file" && -f "$file" ]] || continue
		found=1
		echo "== $label: $file =="
		if [[ -n "$pattern" ]]; then
			grep -iF -- "$pattern" "$file" || true
		else
			cat "$file"
		fi
	done
	if (( ! found )); then
		echo "The run-app session has no readable log files." >&2
		return 1
	fi
}

element_count() {
	printf '%s' "$1" | python3 -c '
import json
import sys

try:
    payload = json.load(sys.stdin)
except json.JSONDecodeError:
    print(0)
    raise SystemExit

collection_keys = {"elements", "ui_elements", "uielements", "annotations"}
identity_keys = {"elementid", "element_id", "axrole", "role"}

def count(value):
    if isinstance(value, list):
        return sum(count(item) for item in value)
    if not isinstance(value, dict):
        return 0
    total = sum(
        len(item)
        for key, item in value.items()
        if key.lower() in collection_keys and isinstance(item, list)
    )
    if any(key.lower() in identity_keys for key in value):
        total += 1
    return total + sum(count(item) for item in value.values())

print(count(payload))
'
}

command=${1:-}
if [[ -z "$command" || "$command" == "-h" || "$command" == "--help" ]]; then
	usage
	exit 0
fi
shift

case "$command" in
	logs)
		(( $# <= 1 )) || { usage >&2; exit 2; }
		show_logs "${1:-}"
		;;
	id | image | see | tree)
		validate_app_identity || exit 1
		require_peekaboo || exit 1
		window=$(repository_window) || exit 1
		IFS=$'\t' read -r window_id window_title <<<"$window"
		case "$command" in
		id)
			(( $# == 0 )) || { usage >&2; exit 2; }
			printf 'pid=%s\nwindow_id=%s\nwindow_title=%s\nrepository=%s\n' \
				"$app_pid" "$window_id" "$window_title" "$repository"
			;;
		image)
			(( $# <= 1 )) || { usage >&2; exit 2; }
			output=${1:-$session_dir/gitx-window.png}
			rm -f "$output"
			if ! peekaboo image --pid "$app_pid" --window-id "$window_id" --path "$output"; then
				rm -f "$output"
				exit 1
			fi
			[[ -s "$output" ]] || { echo "peekaboo did not create $output." >&2; exit 1; }
			echo "$output"
			;;
		see)
			(( $# <= 1 )) || { usage >&2; exit 2; }
			output=${1:-$session_dir/gitx-ui.png}
			response=
			for attempt in 1 2 3; do
				rm -f "$output"
				response=$(peekaboo see --pid "$app_pid" --window-id "$window_id" \
					--annotate --json --path "$output" 2>/dev/null) || response=
				count=$(element_count "$response")
				if [[ -s "$output" && "$count" =~ ^[0-9]+$ ]] && (( count > 0 )); then
					printf '%s\n' "$response"
					echo "Annotated image: $output" >&2
					exit 0
				fi
				(( attempt == 3 )) || sleep "0.$(( attempt * 2 ))"
			done
			rm -f "$output"
			echo "peekaboo did not return observable UI elements after 3 attempts." >&2
			exit 1
			;;
		tree)
			(( $# <= 1 )) || { usage >&2; exit 2; }
			response=$(peekaboo inspect-ui --app-target "PID:$app_pid" --json) || exit 1
			printf '%s' "$response" | python3 -c '
import json
import sys

payload = json.load(sys.stdin)
formatted = json.dumps(payload, indent=2, sort_keys=True)
pattern = sys.argv[1].casefold()
lines = formatted.splitlines()
if pattern:
    lines = [line for line in lines if pattern in line.casefold()]
    if not lines:
        raise SystemExit(1)
print("\\n".join(lines))
' "${1:-}"
			;;
		esac
		;;
	*)
		echo "Unknown command: $command" >&2
		usage >&2
		exit 2
		;;
esac
