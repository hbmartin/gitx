#!/bin/bash
# Canonical build, test, analysis, and archive entry point for GitX.

set -uo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
support="$root/scripts/verification_support.py"
cd "$root" || exit 2

usage() {
	cat <<'USAGE'
Usage:
  scripts/xcodebuild.sh build [--configuration Debug|Release] [--stage-app]
  scripts/xcodebuild.sh archive [--configuration Release]
  scripts/xcodebuild.sh smoke
  scripts/xcodebuild.sh analyze
  scripts/xcodebuild.sh test correctness|ui|address-undefined|thread-sanitizer|performance|core|forgekit
  scripts/xcodebuild.sh raw -- <xcodebuild arguments>

Global options:
  --configuration NAME
  --destination SPEC
  --developer-dir PATH
  --run-id ID
  --raw-output
  --stage-app

Every invocation uses a new artifacts/verification/<run-id> directory and emits receipt.json.
USAGE
}

config() {
	python3 "$support" config "$1"
}

configuration=Debug
configuration_explicit=0
destination=$(config destination) || exit 2
developer_dir=
requested_run_id=
stage_app=0
use_xcbeautify=1
command=
command_arguments=()

while (( $# )); do
	case "$1" in
		--configuration|-configuration)
			(( $# >= 2 )) || { echo "$1 requires a value" >&2; exit 2; }
			configuration=$2
			configuration_explicit=1
			shift 2
			;;
		--destination|-destination)
			(( $# >= 2 )) || { echo "$1 requires a value" >&2; exit 2; }
			destination=$2
			shift 2
			;;
		--developer-dir)
			(( $# >= 2 )) || { echo "$1 requires a value" >&2; exit 2; }
			developer_dir=$2
			shift 2
			;;
		--run-id)
			(( $# >= 2 )) || { echo "$1 requires a value" >&2; exit 2; }
			requested_run_id=$2
			shift 2
			;;
		--stage-app)
			stage_app=1
			shift
			;;
		--raw|--raw-output)
			# --raw was the original wrapper's spelling for unformatted output.
			use_xcbeautify=0
			shift
			;;
		-h|--help)
			usage
			exit 0
			;;
		*)
			command=$1
			shift
			command_arguments=("$@")
			break
			;;
	esac
done

if [[ -z "$command" ]]; then
	usage >&2
	exit 2
fi

if [[ "$command" != "raw" ]]; then
	filtered_arguments=()
	index=0
	while (( index < ${#command_arguments[@]} )); do
		argument=${command_arguments[$index]}
		case "$argument" in
			--configuration|-configuration)
				(( index + 1 < ${#command_arguments[@]} )) || { echo "$argument requires a value" >&2; exit 2; }
				configuration=${command_arguments[$((index + 1))]}
				configuration_explicit=1
				index=$((index + 2))
				;;
			--destination|-destination)
				(( index + 1 < ${#command_arguments[@]} )) || { echo "$argument requires a value" >&2; exit 2; }
				destination=${command_arguments[$((index + 1))]}
				index=$((index + 2))
				;;
			--developer-dir)
				(( index + 1 < ${#command_arguments[@]} )) || { echo "$argument requires a value" >&2; exit 2; }
				developer_dir=${command_arguments[$((index + 1))]}
				index=$((index + 2))
				;;
			--run-id)
				(( index + 1 < ${#command_arguments[@]} )) || { echo "$argument requires a value" >&2; exit 2; }
				requested_run_id=${command_arguments[$((index + 1))]}
				index=$((index + 2))
				;;
			--stage-app)
				stage_app=1
				index=$((index + 1))
				;;
			--raw|--raw-output)
				use_xcbeautify=0
				index=$((index + 1))
				;;
			*)
				filtered_arguments+=("$argument")
				index=$((index + 1))
				;;
		esac
	done
	command_arguments=(${filtered_arguments[@]+"${filtered_arguments[@]}"})
fi

if [[ "$command" == "archive" && "$configuration_explicit" == 0 ]]; then
	configuration=Release
fi

if [[ -z "$developer_dir" ]]; then
	developer_dir=$(python3 "$support" developer-dir) || exit $?
fi
export DEVELOPER_DIR="$developer_dir"
xcodebuild="$developer_dir/usr/bin/xcodebuild"
xcrun=$(command -v xcrun)

run_id=$(python3 "$support" run-id "$requested_run_id") || exit $?
artifact_root=$(config artifactRoot) || exit 2
source_package_cache=$(config sourcePackageCache) || exit 2
run_dir="$root/$artifact_root/$run_id"
if [[ -e "$run_dir" ]]; then
	echo "Verification run already exists: $run_dir" >&2
	exit 2
fi
logs="$run_dir/Logs"
results="$run_dir/Results"
products="$run_dir/Products"
derived_data="$run_dir/DerivedData"
mkdir -p "$logs" "$results" "$products" "$derived_data" "$root/$source_package_cache"
receipt="$run_dir/receipt.json"

signing_mode=ad-hoc
for argument in ${command_arguments[@]+"${command_arguments[@]}"}; do
	case "$argument" in
		CODE_SIGNING_ALLOWED=NO|CODE_SIGNING_REQUIRED=NO)
			signing_mode=disabled
			;;
	esac
done

preset=$command
if [[ -n "${command_arguments[0]:-}" ]]; then
	preset="$preset:${command_arguments[0]}"
fi
python3 "$support" receipt-init \
	--run-id "$run_id" \
	--preset "$preset" \
	--configuration "$configuration" \
	--destination "$destination" \
	--developer-dir "$developer_dir" \
	--signing-mode "$signing_mode" \
	"$receipt" \
	-- ${command_arguments[@]+"${command_arguments[@]}"} || exit 2

overall_status=failed
interrupted=0
finish_receipt() {
	exit_code=$?
	trap - EXIT INT TERM
	if (( interrupted )); then
		overall_status=interrupted
	elif (( exit_code == 0 )); then
		overall_status=passed
	fi
	python3 "$support" receipt-finish "$receipt" --status "$overall_status" --exit-code "$exit_code" >/dev/null 2>&1 || true
	echo "Verification receipt: $receipt"
	exit "$exit_code"
}
trap finish_receipt EXIT
trap 'interrupted=1; exit 130' INT TERM

elapsed_seconds() {
	python3 -c 'import sys, time; print(f"{time.time() - float(sys.argv[1]):.3f}")' "$1"
}

record_step() {
	name=$1
	status=$2
	exit_code=$3
	duration=$4
	log_path=$5
	result_path=$6
	shift 6
	python3 "$support" receipt-step \
		--name "$name" --status "$status" --exit-code "$exit_code" \
		--duration "$duration" --log "$log_path" --xcresult "$result_path" \
		"$receipt" \
		-- "$@" >/dev/null
}

run_step() {
	step_name=$1
	log_path=$2
	result_path=$3
	shift 3
	started=$(python3 -c 'import time; print(time.time())')
	if (( use_xcbeautify )) && command -v xcbeautify >/dev/null 2>&1 && [[ "$1" == "$xcodebuild" ]]; then
		"$@" 2>&1 | tee "$log_path" | xcbeautify --disable-logging
		step_status=${PIPESTATUS[0]}
	else
		"$@" 2>&1 | tee "$log_path"
		step_status=${PIPESTATUS[0]}
	fi
	duration=$(elapsed_seconds "$started")
	if (( step_status == 0 )); then
		step_result=passed
	else
		step_result=failed
	fi
	record_step "$step_name" "$step_result" "$step_status" "$duration" "$log_path" "$result_path" "$@"
	return "$step_status"
}

doctor_mode=build
case "$command" in
	test)
		if [[ "${command_arguments[0]:-}" != "core" && "${command_arguments[0]:-}" != "forgekit" ]]; then
			doctor_mode="test"
		fi
		if [[ "${command_arguments[0]:-}" == "ui" ]]; then
			doctor_mode=ui
		fi
		;;
	analyze|archive|smoke|build|raw)
		;;
	*)
		echo "Unknown verification command: $command" >&2
		usage >&2
		exit 2
		;;
esac

doctor_log="$logs/doctor.log"
started=$(python3 -c 'import time; print(time.time())')
"$root/scripts/doctor.sh" --mode "$doctor_mode" --developer-dir "$developer_dir" 2>&1 | tee "$doctor_log"
doctor_status=${PIPESTATUS[0]}
duration=$(elapsed_seconds "$started")
if (( doctor_status == 0 )); then
	doctor_result=passed
else
	doctor_result=blocked
	overall_status=blocked
fi
record_step doctor "$doctor_result" "$doctor_status" "$duration" "$doctor_log" "" "$root/scripts/doctor.sh" --mode "$doctor_mode"
(( doctor_status == 0 )) || exit "$doctor_status"

workspace=$(config workspace)
scheme=$(config scheme)
deployment_target=$(config macOSDeploymentTarget)
common=(
	-workspace "$workspace"
	-scheme "$scheme"
	-destination "$destination"
	-derivedDataPath "$derived_data"
	-clonedSourcePackagesDirPath "$root/$source_package_cache"
	-configuration "$configuration"
	MACOSX_DEPLOYMENT_TARGET="$deployment_target"
)

reject_managed_paths() {
	for argument in "$@"; do
		case "$argument" in
			-derivedDataPath|-resultBundlePath|-clonedSourcePackagesDirPath|-archivePath)
				echo "$argument is managed by scripts/xcodebuild.sh" >&2
				return 2
				;;
		esac
	done
}

xcode_test() {
	test_preset=$1
	plan=$2
	result="$results/$plan.xcresult"
	shift 2
	run_step "test:$test_preset" "$logs/$plan.log" "$result" \
		"$xcodebuild" "${common[@]}" test -testPlan "$plan" -resultBundlePath "$result" \
		CODE_SIGN_IDENTITY=- "$@"
}

stage_built_app() {
	built_app=
	while IFS= read -r candidate; do
		if [[ -z "$built_app" ]]; then
			built_app=$candidate
		else
			echo "More than one GitX.app was produced; refusing to stage an ambiguous bundle." >&2
			return 3
		fi
	done < <(find "$derived_data/Build/Products" -maxdepth 3 -type d -name GitX.app -print 2>/dev/null)
	if [[ -z "$built_app" || ! -x "$built_app/Contents/MacOS/GitX" ]]; then
		echo "Could not locate a valid GitX.app in $derived_data" >&2
		return 3
	fi
	/usr/bin/codesign --verify --deep --strict "$built_app" || return 3
	staged="$root/build/GitX.app"
	running_pids=$(pgrep -x GitX 2>/dev/null || true)
	if [[ -n "$running_pids" ]]; then
		echo "GitX is running; stop it before replacing $staged." >&2
		return 3
	fi
	mkdir -p "$root/build"
	if [[ -e "$staged" ]]; then
		mv "$staged" "$run_dir/previous-GitX.app" || return 3
	fi
	temporary="$root/build/.GitX.app.$run_id"
	if ! ditto "$built_app" "$temporary"; then
		[[ ! -e "$run_dir/previous-GitX.app" ]] || mv "$run_dir/previous-GitX.app" "$staged"
		return 3
	fi
	if ! mv "$temporary" "$staged"; then
		mv "$temporary" "$run_dir/failed-staged-GitX.app" 2>/dev/null || true
		[[ ! -e "$run_dir/previous-GitX.app" ]] || mv "$run_dir/previous-GitX.app" "$staged"
		return 3
	fi
	echo "Staged app: $staged"
}

case "$command" in
	build)
		reject_managed_paths ${command_arguments[@]+"${command_arguments[@]}"} || exit $?
		run_step build "$logs/build.log" "" "$xcodebuild" "${common[@]}" build CODE_SIGN_IDENTITY=- ${command_arguments[@]+"${command_arguments[@]}"} || exit $?
		if (( stage_app )); then
			stage_built_app || exit $?
		fi
		;;
	smoke)
		reject_managed_paths ${command_arguments[@]+"${command_arguments[@]}"} || exit $?
		run_step smoke "$logs/smoke.log" "" "$xcodebuild" "${common[@]}" build \
			CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO COMPILER_INDEX_STORE_ENABLE=NO \
			${command_arguments[@]+"${command_arguments[@]}"} || exit $?
		;;
	archive)
		reject_managed_paths ${command_arguments[@]+"${command_arguments[@]}"} || exit $?
		archive_path="$products/GitX.xcarchive"
		run_step archive "$logs/archive.log" "" "$xcodebuild" "${common[@]}" archive \
			-archivePath "$archive_path" ${command_arguments[@]+"${command_arguments[@]}"} || exit $?
		echo "Archive: $archive_path"
		;;
	analyze)
		reject_managed_paths ${command_arguments[@]+"${command_arguments[@]}"} || exit $?
		analyzer_log="$logs/analyze.log"
		run_step analyze "$analyzer_log" "" "$xcodebuild" "${common[@]}" analyze \
			ARCHS=arm64 CLANG_STATIC_ANALYZER_MODE_ON_ANALYZE_ACTION=deep \
			CLANG_WARN_NULLABILITY_COMPLETENESS=YES CLANG_WARN_NULLABILITY_COMPLETENESS_ON_ARRAYS=YES \
			CODE_SIGN_IDENTITY=- \
			${command_arguments[@]+"${command_arguments[@]}"} || exit $?
		run_step analyzer-policy "$logs/analyzer-policy.log" "" python3 scripts/check_analyzer_diagnostics.py "$analyzer_log" || exit $?
		run_step swiftlint-analyze "$logs/swiftlint-analyze.log" "" scripts/run_pinned_tool.sh swiftlint analyze --strict --config .swiftlint.yml --baseline .swiftlint-baseline.json --compiler-log-path "$analyzer_log" || exit $?
		;;
	test)
		test_preset=${command_arguments[0]:-}
		extra=("${command_arguments[@]:1}")
		# Compatibility with the original wrapper's `test -testPlan NAME` form.
		if [[ "$test_preset" == "-testPlan" && -n "${command_arguments[1]:-}" ]]; then
			plan_name=${command_arguments[1]}
			extra=("${command_arguments[@]:2}")
			case "$plan_name" in
				GitX) test_preset=correctness ;;
				GitXUI) test_preset=ui ;;
				GitXAddressUndefined) test_preset=address-undefined ;;
				GitXThreadSanitizer) test_preset=thread-sanitizer ;;
				GitXPerformance) test_preset=performance ;;
				*) echo "Unknown test plan: $plan_name" >&2; exit 2 ;;
			esac
		fi
		reject_managed_paths ${extra[@]+"${extra[@]}"} || exit $?
		case "$test_preset" in
			correctness)
				plan=$(config testPlans.correctness)
				xcode_test correctness "$plan" -enableCodeCoverage YES ${extra[@]+"${extra[@]}"} || exit $?
				proposal="$results/coverage-proposal.json"
				run_step coverage "$logs/coverage.log" "" scripts/check_coverage.py \
					"$results/$plan.xcresult" --propose-improvements "$proposal" || exit $?
				;;
			ui)
				preflight=$(config testPlans.ui-preflight)
				plan=$(config testPlans.ui)
				xcode_test ui-preflight "$preflight" ${extra[@]+"${extra[@]}"} || exit $?
				xcode_test ui "$plan" ${extra[@]+"${extra[@]}"} || exit $?
				;;
			address-undefined|thread-sanitizer|performance)
				plan=$(config "testPlans.$test_preset")
				xcode_test "$test_preset" "$plan" ${extra[@]+"${extra[@]}"} || exit $?
				;;
			core)
				package=$(config packages.core)
				scratch="$products/GitXCoreBuild"
				run_step test:core "$logs/core.log" "" "$xcrun" swift test --package-path "$package" --scratch-path "$scratch" --enable-code-coverage ${extra[@]+"${extra[@]}"} || exit $?
				codecov=$("$xcrun" swift test --package-path "$package" --scratch-path "$scratch" --show-codecov-path) || exit $?
				run_step coverage:core "$logs/core-coverage.log" "$codecov" python3 scripts/check_core_coverage.py "$codecov" || exit $?
				;;
			forgekit)
				package=$(config packages.forgekit)
				scratch="$products/ForgeKitBuild"
				combined="$results/ForgeKitCombinedCoverage.json"
				run_step test:forgekit "$logs/forgekit.log" "" "$xcrun" swift test --package-path "$package" --scratch-path "$scratch" --build-system swiftbuild --enable-code-coverage ${extra[@]+"${extra[@]}"} || exit $?
				run_step coverage:forgekit "$logs/forgekit-coverage.log" "$combined" python3 scripts/check_forgekit_coverage.py --swiftpm-scratch-path "$scratch" --combined-output "$combined" || exit $?
				;;
			*)
				echo "Unknown test preset: ${test_preset:-<missing>}" >&2
				usage >&2
				exit 2
				;;
		esac
		;;
	raw)
		use_xcbeautify=0
		extra=(${command_arguments[@]+"${command_arguments[@]}"})
		if [[ "${extra[0]:-}" == "--" ]]; then
			extra=("${extra[@]:1}")
		fi
		(( ${#extra[@]} )) || { echo "raw requires xcodebuild arguments" >&2; exit 2; }
		reject_managed_paths "${extra[@]}" || exit $?
		result_path=
		for argument in "${extra[@]}"; do
			if [[ "$argument" == "test" || "$argument" == "test-without-building" ]]; then
				result_path="$results/raw.xcresult"
				extra+=( -resultBundlePath "$result_path" )
				break
			fi
		done
		run_step raw "$logs/raw.log" "$result_path" "$xcodebuild" "${common[@]}" "${extra[@]}" || exit $?
		;;
esac

overall_status=passed
