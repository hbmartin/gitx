#!/bin/bash
#
# Launch GitX for real-world inspection and leave it running.
#
# This is the manual counterpart to the XCUITest harness: it reproduces the
# same deterministic launch environment the UI tests use, so what you observe
# by hand matches what CI observes. It also starts an os_log stream before the
# app launches, so startup logging is never missed.
#
# The generated fixture repository and the isolated preferences home both live
# under $TMPDIR. That is deliberate: $TMPDIR is not a TCC-protected location,
# so a debug-signed build never triggers a consent prompt. Pointing --repo at a
# path on an external volume, the Desktop, or Documents re-introduces prompts.
#
# Usage:
#   scripts/run_app.sh                          # build, launch on a fresh fixture
#   scripts/run_app.sh --no-build               # relaunch without rebuilding
#   scripts/run_app.sh --m3 review              # deterministic Milestone 3 journey
#   scripts/run_app.sh --repo /tmp/some-repo    # open an existing repository
#   scripts/run_app.sh --stop                   # terminate app and log stream
#
# Milestone 2 scenarios: push-create, existing-pull-request, exact-checkout,
#                        deep-link, deep-link-no-checkout, staging-create, sync-fork
# Milestone 3 scenarios: review, suggested-change, lifecycle, merge,
#                        queue-delete, post-merge

set -uo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root" || exit 2

app_bundle=$root/build/GitX.app
session_dir=$root/build/Logs/run-app
log_file=
stdout_file=
app_pid_file=$session_dir/app.pid
log_pid_file=$session_dir/logstream.pid
session_file=$session_dir/session.txt
last_session_file=$session_dir/last-session.txt
temporary_root=${TMPDIR:-/tmp}
temporary_root=${temporary_root%/}
[[ -n "$temporary_root" ]] || temporary_root=/

repository=
fixture_name=gitx-fixture
milestone2_scenario=
milestone3_scenario=
should_build=1
reset_tcc=0
stop_only=0
log_level=info
ready_timeout=30

while (( $# )); do
	case "$1" in
		--repo)
			repository=${2:-}
			shift 2 || exit 2
			;;
		--fixture)
			if (( $# < 2 )); then
				echo "--fixture requires a fixture name." >&2
				exit 2
			fi
			fixture_name=$2
			shift 2
			;;
		--m2)
			milestone2_scenario=${2:-}
			shift 2 || exit 2
			;;
		--m3)
			milestone3_scenario=${2:-}
			shift 2 || exit 2
			;;
		--log-level)
			log_level=${2:-}
			shift 2 || exit 2
			;;
		--timeout)
			ready_timeout=${2:-}
			shift 2 || exit 2
			;;
		--no-build)
			should_build=0
			shift
			;;
		--reset-tcc)
			reset_tcc=1
			shift
			;;
		--stop)
			stop_only=1
			shift
			;;
		-h|--help)
			# Print the header comment block, however long it grows.
			awk 'NR == 1 { next } /^#/ { sub(/^#[[:space:]]?/, ""); print; next } { exit }' "$0"
			exit 0
			;;
		*)
			echo "Unknown option: $1" >&2
			exit 2
			;;
	esac
done

# A pid file can outlive its process, and the kernel reuses pids, so only a
# pid whose executable and start time still match what this script started may
# be killed.
# Waits for the process to exit so a relaunch never races the dying instance.
process_start_time() {
	local pid=$1
	ps -p "$pid" -o lstart= 2>/dev/null | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
}

write_pid_file() {
	local pid_file=$1 pid=$2 start_time
	start_time=$(process_start_time "$pid") || return 1
	[[ -n "$start_time" ]] || return 1
	printf '%s\t%s\n' "$pid" "$start_time" >"$pid_file"
}

stop_pid_file() {
	local pid_file=$1 expected=$2 pid recorded_start_time executable current_start_time
	[[ -f "$pid_file" ]] || return 4
	IFS=$'\t' read -r pid recorded_start_time <"$pid_file" || return 3
	if [[ ! "$pid" =~ ^[0-9]+$ ]]; then
		echo "Cannot verify malformed process identity in $pid_file." >&2
		return 3
	fi
	if ! kill -0 "$pid" 2>/dev/null; then
		if ps -p "$pid" -o pid= 2>/dev/null | grep -q '[0-9]'; then
			echo "Cannot verify whether process $pid can be stopped." >&2
			return 3
		fi
		return 1
	fi
	if [[ -z "$recorded_start_time" ]]; then
		echo "Ignoring legacy PID-only record $pid_file; process identity cannot be verified." >&2
		return 3
	fi
	executable=$(ps -p "$pid" -o comm= 2>/dev/null)
	[[ -n "$executable" ]] || return 3
	case "$executable" in
		"$expected" | */"$expected") ;;
		*) return 1 ;;
	esac
	current_start_time=$(process_start_time "$pid") || return 3
	[[ -n "$current_start_time" ]] || return 3
	if [[ "$current_start_time" != "$recorded_start_time" ]]; then
		return 1
	fi
	kill "$pid" 2>/dev/null || return 2
	for _ in {1..20}; do
		if ! kill -0 "$pid" 2>/dev/null || [[ "$(ps -p "$pid" -o stat= 2>/dev/null)" == *Z* ]]; then
			return 0
		fi
		sleep 0.25
	done
	echo "Process $pid ($expected) did not exit after SIGTERM; leaving $pid_file for retry." >&2
	return 2
}

process_is_absent() {
	local pid=$1 process_state
	[[ "$pid" =~ ^[0-9]+$ ]] || return 1
	if kill -0 "$pid" 2>/dev/null; then
		process_state=$(ps -p "$pid" -o stat= 2>/dev/null) || return 1
		[[ "$process_state" == *Z* ]]
		return
	fi
	if ps -p "$pid" -o pid= 2>/dev/null | grep -q '[0-9]'; then return 1; fi
	return 0
}

recorded_process_is_absent() {
	local key=$1 pid
	[[ -f "$session_file" ]] || return 0
	if ! pid=$(awk -F= -v wanted="$key" '$1 == wanted { print $2; found = 1; exit } END { if (!found) exit 1 }' "$session_file"); then
		if [[ "$key" == log_pid ]]; then
			return 0
		fi
		echo "Cannot verify GitX without an app_pid in $session_file." >&2
		return 1
	fi
	if [[ ! "$pid" =~ ^[0-9]+$ ]]; then
		echo "Cannot verify malformed $key in $session_file." >&2
		return 1
	fi
	if ! process_is_absent "$pid"; then
		echo "Cannot verify the recorded $key process $pid is stopped." >&2
		return 1
	fi
	return 0
}

recorded_isolated_home() {
	[[ -f "$session_file" ]] || return 1
	awk '
		index($0, "isolated_home=") == 1 {
			print substr($0, length("isolated_home=") + 1)
			found = 1
			exit
		}
		END { if (!found) exit 1 }
	' "$session_file"
}

remove_isolated_home() {
	local candidate=$1 parent name
	[[ -n "$candidate" ]] || return 1
	parent=$(dirname "$candidate")
	name=$(basename "$candidate")
	if [[ "$parent" != "$temporary_root" || ! "$name" =~ ^gitx-run-app-home\.[A-Za-z0-9._-]+$ ]]; then
		echo "Refusing to remove unvalidated runtime home: $candidate" >&2
		return 1
	fi
	rm -rf -- "$candidate" || {
		echo "Could not remove validated runtime home: $candidate" >&2
		return 2
	}
}

stop_session() {
	local stopped=0 failed=0 result isolated_home
	if stop_pid_file "$app_pid_file" GitX; then
		stopped=1
	else
		result=$?
		case "$result" in
			1) recorded_process_is_absent app_pid || failed=1 ;;
			4) recorded_process_is_absent app_pid || failed=1 ;;
			*) failed=1 ;;
		esac
	fi
	if stop_pid_file "$log_pid_file" log; then
		stopped=1
	else
		result=$?
		case "$result" in
			1) recorded_process_is_absent log_pid || failed=1 ;;
			4) recorded_process_is_absent log_pid || failed=1 ;;
			*) failed=1 ;;
		esac
	fi
	if (( stopped )); then
		echo "Stopped the previous GitX session."
	fi
	recorded_process_is_absent app_pid || failed=1
	recorded_process_is_absent log_pid || failed=1
	if (( failed == 0 )); then
		if isolated_home=$(recorded_isolated_home); then
			remove_isolated_home "$isolated_home"
			result=$?
			(( result == 2 )) && failed=1
		fi
		if (( failed == 0 )); then
			if [[ -f "$session_file" ]]; then
				cp "$session_file" "$last_session_file" || failed=1
			fi
			if (( failed == 0 )); then
				rm -f -- "$session_file" "$app_pid_file" "$log_pid_file" || failed=1
			fi
		fi
	fi
	(( failed == 0 ))
}

stop_session
stop_status=$?
if (( stop_status != 0 )); then
	exit "$stop_status"
fi
if (( stop_only )); then
	exit 0
fi

mkdir -p "$session_dir"

if (( should_build )); then
	echo "Building GitX (Debug)..."
	if ! "$root/scripts/xcodebuild.sh" build --configuration Debug --stage-app; then
		echo "Build failed; not launching." >&2
		exit 1
	fi
fi

if [[ ! -d "$app_bundle" ]]; then
	echo "No app bundle at $app_bundle. Run without --no-build first." >&2
	exit 2
fi

app_binary=$app_bundle/Contents/MacOS/GitX
if [[ ! -x "$app_binary" ]]; then
	echo "No executable at $app_binary." >&2
	exit 2
fi

bundle_identifier=$(
	/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$app_bundle/Contents/Info.plist" 2>/dev/null
)
bundle_identifier=${bundle_identifier:-net.phere.GitX}

# Peekaboo resolves targets by bundle identifier, so a second GitX process makes
# window lookups ambiguous and `see` returns an empty element list even when the
# correct window id is supplied. Leftover debug instances are the usual cause,
# and launching alongside one produces a session that cannot be observed, so
# this refuses rather than warns.
existing=$(pgrep -x GitX 2>/dev/null)
if [[ -n "$existing" ]]; then
	echo "GitX is already running (pid(s): $(echo "$existing" | tr '\n' ' '))." >&2
	echo "A second instance makes UI observation report an empty element list." >&2
	echo "Quit it first (or: kill $(echo "$existing" | head -1)), then re-run." >&2
	exit 2
fi

if (( reset_tcc )); then
	# Clears any previous Allow *or* Don't Allow decision for this bundle id.
	# Use this to recover from a stale "Don't Allow", which otherwise denies
	# access silently and forever. The next protected access will prompt again.
	for service in SystemPolicyRemovableVolumes SystemPolicyDocumentsFolder \
		SystemPolicyDesktopFolder SystemPolicyDownloadsFolder SystemPolicyNetworkVolumes; do
		tccutil reset "$service" "$bundle_identifier" >/dev/null 2>&1
	done
	echo "Reset TCC decisions for $bundle_identifier."
fi

make_fixture() {
	local target=$1
	rm -rf "$target"
	mkdir -p "$target"
	(
		# Any failing command must fail the fixture: without set -e the
		# subshell's status is that of the final printf, and GitX would launch
		# on a half-built repository.
		set -e
		cd "$target"
		export GIT_CONFIG_GLOBAL=/dev/null
		export GIT_CONFIG_NOSYSTEM=1
		export GIT_AUTHOR_NAME="GitX Fixture"
		export GIT_AUTHOR_EMAIL="fixture@gitx.invalid"
		export GIT_COMMITTER_NAME="GitX Fixture"
		export GIT_COMMITTER_EMAIL="fixture@gitx.invalid"
		export GIT_AUTHOR_DATE="2026-01-01T09:00:00Z"
		export GIT_COMMITTER_DATE="2026-01-01T09:00:00Z"
		git init --quiet --initial-branch main
		printf 'GitX fixture repository\n' >README.md
		git add README.md
		git commit --quiet -m "Add the fixture readme"
		printf 'let answer = 41\n' >Answer.swift
		git add Answer.swift
		git commit --quiet -m "Add an answer that is off by one"
		git checkout --quiet -b topic
		printf 'let answer = 42\n' >Answer.swift
		git commit --quiet -am "Correct the answer"
		git checkout --quiet main
		# Leave uncommitted work so the Staging Pane has content on launch.
		printf 'let pending = true\n' >Pending.swift
		printf 'GitX fixture repository, edited\n' >README.md
	) || return 1
}

if [[ -z "$repository" ]]; then
	if [[ -z "$fixture_name" || ! "$fixture_name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
		echo "Invalid fixture name '$fixture_name': use only letters, numbers, dots, underscores, and hyphens, starting with a letter or number." >&2
		exit 2
	fi
	repository=${TMPDIR:-/tmp}/$fixture_name
	echo "Creating fixture repository at $repository"
	if ! make_fixture "$repository"; then
		echo "Could not create the fixture repository." >&2
		exit 1
	fi
elif ! git -C "$repository" rev-parse --git-dir >/dev/null 2>&1; then
	# rev-parse accepts what a bare `.git` directory test rejects: linked
	# worktrees and submodules keep a `.git` file, and GitX opens both.
	echo "Not a git repository: $repository" >&2
	exit 2
fi

isolated_home=$(mktemp -d "$temporary_root/gitx-run-app-home.XXXXXX") || {
	echo "Could not create an isolated runtime home." >&2
	exit 1
}
session_recorded=0
launch_finished=0
log_pid=
app_pid=
write_session_record() {
	{
		echo "app_pid=$app_pid"
		echo "log_pid=$log_pid"
		echo "bundle_identifier=$bundle_identifier"
		echo "repository=$repository"
		echo "isolated_home=$isolated_home"
		echo "os_log=$log_file"
		echo "stdout=$stdout_file"
	} >"$session_file"
}
# shellcheck disable=SC2329 # Invoked indirectly by the EXIT trap below.
cleanup_unfinished_launch() {
	local exit_status=$?
	trap - EXIT
	if (( ! launch_finished )); then
		if [[ -n "$app_pid" ]] && (( ! session_recorded )); then
			if write_session_record; then session_recorded=1; fi
		fi
		if (( session_recorded )); then
			stop_session || echo "Launch cleanup could not verify GitX; preserving session and isolated home for retry." >&2
		else
			local app_stopped=1 log_stopped=1 result
			if [[ -f "$app_pid_file" ]]; then
				stop_pid_file "$app_pid_file" GitX
				result=$?
				case "$result" in
					0) ;;
					1) [[ -z "$app_pid" ]] || process_is_absent "$app_pid" || app_stopped=0 ;;
					*) app_stopped=0 ;;
				esac
			elif [[ -n "$app_pid" ]] && ! process_is_absent "$app_pid"; then
				app_stopped=0
			fi
			if [[ -f "$log_pid_file" ]]; then
				stop_pid_file "$log_pid_file" log
				result=$?
				case "$result" in
					0) ;;
					1) [[ -z "$log_pid" ]] || process_is_absent "$log_pid" || log_stopped=0 ;;
					*) log_stopped=0 ;;
				esac
			elif [[ -n "$log_pid" ]]; then
				log_stopped=0
			fi
			if [[ -n "$app_pid" ]] && ! process_is_absent "$app_pid"; then
				app_stopped=0
			fi
			if [[ -n "$log_pid" ]] && ! process_is_absent "$log_pid"; then
				log_stopped=0
			fi
			if (( app_stopped && log_stopped )); then
				remove_isolated_home "$isolated_home" || true
				rm -f -- "$app_pid_file" "$log_pid_file"
			else
				echo "Launch cleanup could not verify both processes stopped; preserving isolated home: $isolated_home" >&2
			fi
		fi
	fi
	exit "$exit_status"
}
trap cleanup_unfinished_launch EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
mkdir -p "$isolated_home/Library/Preferences"

# -ApplePersistenceIgnoreState redirects saved window state into $TMPDIR rather
# than disabling it, so it survives between runs and AppKit restores windows from
# the previous launch. A launch that inherits the last run's windows is not the
# deterministic launch this harness promises.
rm -rf "${TMPDIR:-/tmp}/${bundle_identifier}.savedState"

environment=(
	"CFFIXED_USER_HOME=$isolated_home"
	"CFPREFERENCES_AVOID_DAEMON=1"
	"GCM_INTERACTIVE=never"
	"GIT_ASKPASS=/usr/bin/false"
	"GIT_CONFIG_GLOBAL=/dev/null"
	"GIT_CONFIG_NOSYSTEM=1"
	"GIT_TERMINAL_PROMPT=0"
	"GITX_UITEST_FORGE_STORAGE_ROOT=$isolated_home/Library/Application Support/GitX/Forge"
	"GITX_UITEST_REPO=$repository"
)

if [[ -n "$milestone2_scenario" ]]; then
	environment+=("GITX_M2_UITEST=1" "GITX_M2_SCENARIO=$milestone2_scenario")
fi
if [[ -n "$milestone3_scenario" ]]; then
	environment+=("GITX_M3_UITEST=1" "GITX_M3_SCENARIO=$milestone3_scenario")
fi

arguments=(
	-ApplePersistenceIgnoreState YES
	-AppleLanguages "(en)"
	-AppleLocale en_US_POSIX
	-NSAutomaticWindowAnimationsEnabled NO
	-PBAutoFetchScope 0
	"-Suppressed Dialog Warnings" "()"
)

# Start streaming before launch so application startup logging is captured.
run_identifier="$(date +%Y%m%d%H%M%S)-$$"
log_file=$session_dir/gitx-oslog-$run_identifier.txt
stdout_file=$session_dir/gitx-stdout-$run_identifier.txt
printf 'os_log=%s\nstdout=%s\n' "$log_file" "$stdout_file" >"$last_session_file"
: >"$log_file"
log stream \
	--predicate 'subsystem BEGINSWITH "com.gitx"' \
	--style compact \
	--level "$log_level" \
	>>"$log_file" 2>&1 &
log_pid=$!
if ! write_pid_file "$log_pid_file" "$log_pid"; then
	echo "Could not record the log stream process identity." >&2
	exit 1
fi

: >"$stdout_file"
env "${environment[@]}" "$app_binary" "${arguments[@]}" >>"$stdout_file" 2>&1 &
app_pid=$!
if ! write_session_record; then
	echo "Could not record the GitX session." >&2
	exit 1
fi
session_recorded=1
if ! write_pid_file "$app_pid_file" "$app_pid"; then
	echo "Could not record the GitX process identity." >&2
	exit 1
fi

# Wait for the repository window rather than sleeping a fixed interval. Any
# window is not good enough: GitX activates before the deferred document open
# runs, so the Welcome window can appear first and would satisfy a loose check.
# Without peekaboo the window cannot be verified at all; watch liveness briefly
# to catch an immediate crash, then report the uncertainty instead of success.
repository_name=$(basename "$repository")
ready=0
can_observe=1
if ! command -v peekaboo >/dev/null 2>&1; then
	can_observe=0
fi
if (( can_observe )); then
	deadline=$(( SECONDS + ready_timeout ))
else
	deadline=$(( SECONDS + 3 ))
fi
while (( SECONDS < deadline )); do
	if ! kill -0 "$app_pid" 2>/dev/null; then
		echo "GitX exited during launch. See $stdout_file" >&2
		exit 1
	fi
	if (( can_observe )) && peekaboo list windows --app "PID:$app_pid" 2>/dev/null \
		| grep -qF "$repository_name"; then
		ready=1
		break
	fi
	sleep 0.5
done

launch_status=0
if (( ready )); then
	echo "GitX is running (pid $app_pid) with the repository window open."
elif (( ! can_observe )); then
	echo "GitX is running (pid $app_pid). peekaboo is not installed, so the"
	echo "repository window cannot be verified; check $stdout_file if it is missing."
else
	echo "GitX started (pid $app_pid) but no window titled '$repository_name'" >&2
	echo "appeared within ${ready_timeout}s. Check $stdout_file and $log_file." >&2
	launch_status=1
fi
launch_finished=1

cat <<-SUMMARY

	Repository : $repository
	os_log     : $log_file
	stdout     : $stdout_file
	Session    : $session_file

	Observe : scripts/observe_app.sh see
	Screens : scripts/observe_app.sh image
	Tree    : scripts/observe_app.sh tree [pattern]
	Logs    : scripts/observe_app.sh logs [pattern]
	Stop    : scripts/run_app.sh --stop
SUMMARY

exit "$launch_status"
