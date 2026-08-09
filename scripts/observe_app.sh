#!/bin/bash
#
# Observe the GitX instance started by scripts/run_app.sh.
#
# Window targeting is deliberately done by CoreGraphics window id rather than
# by title. GitX rewrites its window title as commits load ("repo (branch: main)"
# becomes "repo (branch: main) - 3 commits loaded"), so a title match resolved a
# moment earlier is already stale by the time a capture runs. Ids are stable for
# the lifetime of the window.
#
# Usage:
#   scripts/observe_app.sh image              # screenshot the repository window
#   scripts/observe_app.sh see                # annotated snapshot + element ids
#   scripts/observe_app.sh tree               # accessibility hierarchy as text
#   scripts/observe_app.sh logs [pattern]     # tail or grep the captured os_log
#   scripts/observe_app.sh id                 # print the window id only
#
# Options:
#   --out PATH    where to write the image (default build/Logs/run-app/window.png)
#   --welcome     target the Welcome window instead of the repository window

set -uo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root" || exit 2

session_dir=$root/build/Logs/run-app
session_file=$session_dir/session.txt

command_name=${1:-image}
if [[ "$command_name" != -* ]]; then
	shift || true
else
	command_name=image
fi

output=$session_dir/window.png
target_welcome=0
pattern=

while (( $# )); do
	case "$1" in
		--out)
			output=${2:-}
			shift 2 || exit 2
			;;
		--welcome)
			target_welcome=1
			shift
			;;
		-h|--help)
			# Print the header comment block, however long it grows.
			awk 'NR == 1 { next } /^#/ { sub(/^#[[:space:]]?/, ""); print; next } { exit }' "$0"
			exit 0
			;;
		*)
			pattern=$1
			shift
			;;
	esac
done

if [[ ! -f "$session_file" ]]; then
	echo "No running session. Start one with scripts/run_app.sh" >&2
	exit 2
fi

app_pid=$(awk -F= '/^app_pid=/{print $2}' "$session_file")
repository=$(awk -F= '/^repository=/{print $2}' "$session_file")
os_log=$(awk -F= '/^os_log=/{print $2}' "$session_file")
stdout_log=$(awk -F= '/^stdout=/{print $2}' "$session_file")

if [[ "$command_name" == "logs" ]]; then
	# GitX logs through two channels: os_log (Logger/os_log call sites) and
	# stderr (the remaining NSLog call sites). Searching only one hides half
	# the runtime story, so both are always consulted. This path deliberately
	# skips the liveness gate below: captured logs matter most after the app
	# has exited or crashed.
	for source in "$os_log" "$stdout_log"; do
		[[ -f "$source" ]] || continue
		echo "--- $(basename "$source") ---"
		if [[ -n "$pattern" ]]; then
			grep -i -- "$pattern" "$source"
		else
			tail -n 25 "$source"
		fi
	done
	exit 0
fi

if [[ -z "$app_pid" ]] || ! kill -0 "$app_pid" 2>/dev/null; then
	echo "GitX is not running. Start it with scripts/run_app.sh" >&2
	echo "Logs from the ended session stay readable: scripts/observe_app.sh logs" >&2
	exit 2
fi

if (( target_welcome )); then
	match="Welcome to GitX"
else
	match=$(basename "$repository")
fi

resolve_window_id() {
	peekaboo list windows --app "PID:$app_pid" 2>/dev/null \
		| grep -m1 -F "$match" \
		| sed -E 's/.*ID: ([0-9]+).*/\1/'
}

window_id=$(resolve_window_id)

if [[ -z "$window_id" ]]; then
	echo "No window matching '$match' for pid $app_pid." >&2
	peekaboo list windows --app "PID:$app_pid" >&2
	exit 1
fi

# A window exists before AppKit has published its accessibility tree, so a
# snapshot taken the instant the window appears can legitimately contain zero
# elements. Re-resolve and retry rather than reporting an empty UI.
snapshot_elements() {
	local payload count
	for _ in 1 2 3 4 5; do
		payload=$(peekaboo see --pid "$app_pid" --window-id "$window_id" --json 2>/dev/null)
		count=$(
			printf '%s' "$payload" \
				| python3 -c 'import json,sys
try:
    data = json.load(sys.stdin)
except Exception:
    print(0)
else:
    print(len((data.get("data") or data).get("ui_elements") or []))' 2>/dev/null
		)
		if [[ "${count:-0}" -gt 0 ]]; then
			printf '%s' "$payload"
			return 0
		fi
		window_id=$(resolve_window_id)
		[[ -z "$window_id" ]] && return 1
	done
	if [[ -n "$(pgrep -x GitX 2>/dev/null | sed -n '2p')" ]]; then
		echo "More than one GitX process is running, which makes Peekaboo's" >&2
		echo "bundle-identifier lookup ambiguous. Quit the other instance." >&2
	fi
	printf '%s' "$payload"
}

case "$command_name" in
	id)
		echo "$window_id"
		;;
	image)
		mkdir -p "$(dirname "$output")"
		# Remove any previous capture first: a stale PNG surviving a failed
		# capture would be read as fresh evidence of the current UI state.
		rm -f "$output"
		if ! capture_output=$(peekaboo image --app "PID:$app_pid" --window-id "$window_id" --path "$output" 2>&1) \
			|| [[ ! -s "$output" ]]; then
			echo "Screenshot capture failed for window id $window_id." >&2
			[[ -n "$capture_output" ]] && echo "$capture_output" >&2
			exit 1
		fi
		echo "$output"
		;;
	see)
		mkdir -p "$(dirname "$output")"
		peekaboo see --pid "$app_pid" --window-id "$window_id" --annotate --path "$output"
		;;
	tree)
		snapshot_elements \
			| python3 -c '
import json, sys

pattern = (sys.argv[1] if len(sys.argv) > 1 else "").lower()

try:
    payload = json.load(sys.stdin)
except json.JSONDecodeError:
    sys.exit("Peekaboo did not return JSON; run: scripts/observe_app.sh see")

data = payload.get("data", payload)
elements = data.get("ui_elements") or []
title = data.get("window_title", "")
print(f"# {title} - {len(elements)} elements")
print("# ref\trole\taccessibility identifier\tlabel")
for element in elements:
    row = "\t".join(
        (
            element.get("id", "?"),
            element.get("role", ""),
            element.get("identifier", ""),
            element.get("label") or element.get("title") or "",
        )
    )
    if not element.get("is_actionable"):
        continue
    if pattern and pattern not in row.lower():
        continue
    print(row)
' "$pattern"
		;;
	*)
		echo "Unknown command: $command_name" >&2
		exit 2
		;;
esac
