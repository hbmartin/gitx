#!/bin/bash
# Canonical build, test, analysis, and archive entry point for GitX.

set -uo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
if [[ "${GITX_GUARDED_ENTRY:-}" != "$root/scripts/xcodebuild.sh" ]]; then
	exec python3 "$root/scripts/workflow_session.py" guard "$root/scripts/xcodebuild.sh" "$@"
fi
unset GITX_GUARDED_ENTRY
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

Every invocation emits a receipt under artifacts/verification/<run-id> while
reusing caches under ~/Library/Caches/GitX/Verification. GITX_DERIVED_DATA,
GITX_SWIFTPM_BUILD_ROOT and GITX_SOURCE_PACKAGE_CACHE override resolved paths.
GITX_VERIFICATION_CACHE_ROOT relocates the partitioned cache hierarchy.
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
if [[ "$command" == "raw" ]]; then
	for (( index=0; index < ${#command_arguments[@]}; index++ )); do
		case "${command_arguments[$index]}" in
			-configuration) configuration=${command_arguments[$((index + 1))]:-$configuration} ;;
			-configuration=*) configuration=${command_arguments[$index]#*=} ;;
			-destination) destination=${command_arguments[$((index + 1))]:-$destination} ;;
			-destination=*) destination=${command_arguments[$index]#*=} ;;
		esac
	done
fi

if [[ -z "$developer_dir" ]]; then
	developer_dir=$(python3 "$support" developer-dir) || exit $?
fi
developer_dir=$(python3 "$support" normalize-developer-dir "$developer_dir") || exit $?
export DEVELOPER_DIR="$developer_dir"
xcodebuild="$developer_dir/usr/bin/xcodebuild"
xcrun=$(command -v xcrun)

run_id=$(python3 "$support" run-id "$requested_run_id") || exit $?
artifact_root=$(config artifactRoot) || exit 2
source_package_cache=$(config sourcePackageCache) || exit 2
derived_data_cache=$(config derivedDataCache) || exit 2
swiftpm_build_cache=$(config swiftPMBuildCache) || exit 2
run_dir="$root/$artifact_root/$run_id"
if [[ -e "$run_dir" ]]; then
	echo "Verification run already exists: $run_dir" >&2
	exit 2
fi
logs="$run_dir/Logs"
results="$run_dir/Results"
products="$run_dir/Products"
analyzer_derived_data=
mkdir -p "$root/build"
if [[ "$command" == "analyze" ]]; then
	mkdir -p "${GITX_DERIVED_DATA%/*}"
	analyzer_derived_data=$(mktemp -d "${GITX_DERIVED_DATA%/*}/AnalyzerDerivedData.XXXXXX") || exit 2
	derived_data="$analyzer_derived_data"
else
	derived_data=${GITX_DERIVED_DATA:-"$root/$derived_data_cache"}
fi
swiftpm_build_root=${GITX_SWIFTPM_BUILD_ROOT:-"$root/$swiftpm_build_cache"}
source_package_cache=${GITX_SOURCE_PACKAGE_CACHE:-"$root/$source_package_cache"}
export GITX_DERIVED_DATA="$derived_data" GITX_SWIFTPM_BUILD_ROOT="$swiftpm_build_root" GITX_SOURCE_PACKAGE_CACHE="$source_package_cache"
mkdir -p "$logs" "$results" "$products" "$derived_data" "$swiftpm_build_root" "$source_package_cache"
echo "Build paths: DerivedData=$derived_data; SwiftPM=$swiftpm_build_root; SourcePackages=$source_package_cache"
receipt="$run_dir/receipt.json"

signing_allowed=YES
signing_required=YES
signing_identity=
case "$command" in
	smoke|analyze)
		signing_allowed=NO
		signing_required=NO
		;;
	build)
		signing_identity=-
		;;
	test)
		case "${command_arguments[0]:-}" in
			core|forgekit) signing_mode=not-applicable ;;
			*) signing_identity=- ;;
		esac
		;;
	archive|raw)
		;;
esac
if [[ -z "${signing_mode:-}" ]]; then
	for argument in ${command_arguments[@]+"${command_arguments[@]}"}; do
		case "$argument" in
			CODE_SIGNING_ALLOWED=*) signing_allowed=${argument#*=} ;;
			CODE_SIGNING_REQUIRED=*) signing_required=${argument#*=} ;;
			CODE_SIGN_IDENTITY=*) signing_identity=${argument#*=} ;;
		esac
	done
	if [[ "$signing_allowed" == "NO" || "$signing_required" == "NO" ]]; then
		signing_mode=disabled
	elif [[ "$signing_identity" == "-" ]]; then
		signing_mode=ad-hoc
	else
		signing_mode=project
	fi
fi

preset=$command
if [[ "$command" == "test" ]]; then
	case "${command_arguments[0]:-}" in
			correctness|host-preflight|ui|address-undefined|thread-sanitizer|performance|core|forgekit)
			preset="test:${command_arguments[0]}"
			;;
		-testPlan)
			preset="test:${command_arguments[1]:-unknown}"
			;;
	esac
fi
# Concurrent readers can corrupt ordinary instrumentation counters, including
# producing wrapped branch counts. Correctness uses atomic updates in both the
# host probe and suite. Record these effective flags before receipt creation.
coverage_mode=$(python3 "$root/scripts/workflow_session.py" coverage-mode "$command" ${command_arguments[@]+"${command_arguments[@]}"}) || exit $?
if [[ "$coverage_mode" == "atomic" ]]; then
	coverage_arguments=()
	swift_flags="\$(inherited)"
	c_flags="\$(inherited)"
	for argument in ${command_arguments[@]+"${command_arguments[@]}"}; do
		case "$argument" in
			OTHER_SWIFT_FLAGS=*) swift_flags=${argument#*=} ;;
			OTHER_CFLAGS=*) c_flags=${argument#*=} ;;
			*) coverage_arguments+=("$argument") ;;
		esac
	done
	coverage_arguments+=("OTHER_SWIFT_FLAGS=$swift_flags -Xllvm -instrprof-atomic-counter-update-all"
		"OTHER_CFLAGS=$c_flags -fprofile-update=atomic")
	command_arguments=("${coverage_arguments[@]}")
fi

coverage_gate=not-applicable
if [[ "$command" == "test" ]]; then
	case "${command_arguments[0]:-}" in
		correctness) coverage_gate=enforced ;;
		-testPlan)
			[[ "${command_arguments[1]:-}" == "GitX" ]] && coverage_gate=enforced
			;;
	esac
	if [[ "$coverage_gate" == "enforced" ]]; then
		for argument in ${command_arguments[@]+"${command_arguments[@]}"}; do
			case "$argument" in
                -only-testing|-only-testing:*|-only-testing=*|-skip-testing|-skip-testing:*|-skip-testing=*) coverage_gate=not-applicable-focused-selection ;;
			esac
		done
	fi
fi
python3 "$support" receipt-init \
	--run-id "$run_id" \
	--preset "$preset" \
	--configuration "$configuration" \
	--destination "$destination" \
	--developer-dir "$developer_dir" \
	--signing-mode "$signing_mode" \
	--coverage-gate "$coverage_gate" \
	"$receipt" \
	-- ${command_arguments[@]+"${command_arguments[@]}"} || {
		receipt_status=$?
		[[ -z "$analyzer_derived_data" ]] || rm -rf -- "$analyzer_derived_data"
		exit "$receipt_status"
	}

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
	python3 "$support" receipt-finish "$receipt" --status "$overall_status" --exit-code "$exit_code"
	evidence_status=$?
	if (( exit_code == 0 && evidence_status != 0 )); then exit_code=$evidence_status; fi
	if [[ -n "$analyzer_derived_data" && -d "$analyzer_derived_data" ]]; then
		rm -rf -- "$analyzer_derived_data" || true
	fi
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
		python3 "$root/scripts/workflow_session.py" run --diagnostics "$run_dir/Diagnostics/$step_name" -- "$@" 2>&1 | tee "$log_path" | xcbeautify --disable-logging
		step_status=${PIPESTATUS[0]}
	else
		python3 "$root/scripts/workflow_session.py" run --diagnostics "$run_dir/Diagnostics/$step_name" -- "$@" 2>&1 | tee "$log_path"
		step_status=${PIPESTATUS[0]}
	fi
	duration=$(elapsed_seconds "$started")
	if (( step_status == 0 )); then
		step_result=passed
	else
		step_result=failed
	fi
	record_step "$step_name" "$step_result" "$step_status" "$duration" "$log_path" "$result_path" "$@"
	receipt_step_status=$?
	if (( step_status == 0 && receipt_step_status != 0 )); then step_status=$receipt_step_status; fi
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
	raw)
		for argument in ${command_arguments[@]+"${command_arguments[@]}"}; do
			case "$argument" in test|test-without-building) doctor_mode="test" ;; esac
		done
		;;
	analyze|archive|smoke|build|build-tests)
		;;
	*)
		echo "Unknown verification command: $command" >&2
		usage >&2
		exit 2
		;;
esac

doctor_scope=app
if [[ "$command" == "test" ]]; then
    case "${command_arguments[0]:-}" in
        core|forgekit) doctor_scope=${command_arguments[0]} ;;
    esac
fi
doctor_log="$logs/doctor.log"
started=$(python3 -c 'import time; print(time.time())')
"$root/scripts/doctor.sh" --mode "$doctor_mode" --scope "$doctor_scope" --developer-dir "$developer_dir" --destination "$destination" 2>&1 | tee "$doctor_log"
doctor_status=${PIPESTATUS[0]}
duration=$(elapsed_seconds "$started")
if (( doctor_status == 0 )); then
	doctor_result=passed
else
	doctor_result=blocked
	overall_status=blocked
fi
record_step doctor "$doctor_result" "$doctor_status" "$duration" "$doctor_log" "" "$root/scripts/doctor.sh" --mode "$doctor_mode" --scope "$doctor_scope" --developer-dir "$developer_dir" --destination "$destination"
(( doctor_status == 0 )) || exit "$doctor_status"

workspace=$(config workspace)
scheme=$(config scheme)
deployment_target=$(config macOSDeploymentTarget)
common=(
	-workspace "$workspace"
	-scheme "$scheme"
	-destination "$destination"
	-derivedDataPath "$derived_data"
	-clonedSourcePackagesDirPath "$source_package_cache"
	-configuration "$configuration"
	MACOSX_DEPLOYMENT_TARGET="$deployment_target"
)

reject_managed_paths() {
	for argument in "$@"; do
		case "$argument" in
			-workspace|-workspace=*|-project|-project=*|-scheme|-scheme=*|-testPlan|-testPlan=*|\
			-derivedDataPath|-derivedDataPath=*|-resultBundlePath|-resultBundlePath=*|\
			-clonedSourcePackagesDirPath|-clonedSourcePackagesDirPath=*|-archivePath|-archivePath=*)
				echo "$argument is managed by scripts/xcodebuild.sh" >&2
				return 2
				;;
		esac
	done
}

# Xcode rejects duplicate singleton options. Inherit an explicit suite option
# first; add a plan-derived probe default only when the caller supplied none.
ensure_probe_option() {
	local option=$1 value=$2 argument
	for argument in ${probe_arguments[@]+"${probe_arguments[@]}"}; do
		[[ "$argument" == "$option" || "$argument" == "$option="* ]] && return 0
	done
	probe_arguments+=("$option" "$value")
}

xcode_test() {
	local test_preset=$1
	local plan=$2
	local result="$results/$plan.xcresult"
	shift 2
	if [[ "$test_preset" != "ui-preflight" && "$test_preset" != "ui" ]]; then
		local probe_arguments=() index=0
		local arguments=("$@")
		while (( index < ${#arguments[@]} )); do
			case "${arguments[$index]}" in
				-only-testing|-skip-testing) index=$((index + 2)) ;;
				-only-testing:*|-skip-testing:*|-only-testing=*|-skip-testing=*) index=$((index + 1)) ;;
				*) probe_arguments+=("${arguments[$index]}"); index=$((index + 1)) ;;
			esac
		done
		case "$test_preset" in
			correctness) ensure_probe_option -enableCodeCoverage YES ;;
			address-undefined) ensure_probe_option -enableAddressSanitizer YES; ensure_probe_option -enableUndefinedBehaviorSanitizer YES ;;
			thread-sanitizer) ensure_probe_option -enableThreadSanitizer YES ;;
		esac
		run_step compile:host-preflight "$logs/$plan-host-build.log" "" \
			"$xcodebuild" "${common[@]}" build-for-testing -testPlan GitXHostPreflight \
			CODE_SIGN_IDENTITY=- ENABLE_TESTABILITY=YES ENABLE_HARDENED_RUNTIME=NO ${probe_arguments[@]+"${probe_arguments[@]}"} || return $?
	fi
	# Compile before starting host deadlines, preserving suite instrumentation.
	run_step "compile:$test_preset" "$logs/$plan-build.log" "" \
		"$xcodebuild" "${common[@]}" build-for-testing -testPlan "$plan" \
		CODE_SIGN_IDENTITY=- ENABLE_TESTABILITY=YES ENABLE_HARDENED_RUNTIME=NO "$@" || return $?
	run_step signatures "$logs/$plan-signatures.log" "" python3 "$root/scripts/workflow_session.py" signatures "$derived_data" || return $?
	local snapshot="$results/$plan-inputs.json"
	python3 "$root/scripts/workflow_session.py" snapshot "$snapshot" --products "$derived_data" || return $?
	if [[ "$test_preset" != "ui-preflight" && "$test_preset" != "ui" ]]; then
		run_step host-preflight "$logs/$plan-host.log" "$results/$plan-host.xcresult" \
			python3 "$root/scripts/workflow_session.py" run --timeout 120 --desktop --diagnostics "$run_dir/Diagnostics/host" -- \
			"$xcodebuild" "${common[@]}" test-without-building -testPlan GitXHostPreflight \
			-only-testing:GitXTests/GitXHostStartTests/testHostStarts \
			-resultBundlePath "$results/$plan-host.xcresult" CODE_SIGN_IDENTITY=- ENABLE_TESTABILITY=YES ENABLE_HARDENED_RUNTIME=NO \
			${probe_arguments[@]+"${probe_arguments[@]}"} || return $?
	fi
	run_step "test:$test_preset" "$logs/$plan.log" "$result" \
		python3 "$root/scripts/workflow_session.py" run --startup-timeout 120 --desktop --diagnostics "$run_dir/Diagnostics/$plan" -- \
		"$xcodebuild" "${common[@]}" test-without-building -testPlan "$plan" -resultBundlePath "$result" \
		CODE_SIGN_IDENTITY=- ENABLE_TESTABILITY=YES ENABLE_HARDENED_RUNTIME=NO "$@"
	local test_status=$?
	run_step evidence "$logs/$plan-evidence.log" "" python3 "$root/scripts/workflow_session.py" validate "$snapshot"
	local evidence_status=$?
	(( test_status == 0 )) || return "$test_status"
	return "$evidence_status"
}

stage_built_app() {
	built_products_dir=$(
		"$xcodebuild" "${common[@]}" -showBuildSettings "$@" 2>/dev/null \
			| awk -F' = ' '/ BUILT_PRODUCTS_DIR = /{print $2; exit}'
	)
	built_app="$built_products_dir/Half Dark.app"
	if [[ -z "$built_app" || ! -x "$built_app/Contents/MacOS/GitX" ]]; then
		echo "Could not locate a valid Half Dark.app in $derived_data" >&2
		return 3
	fi
	/usr/bin/codesign --verify --deep --strict "$built_app" || return 3
	staged="$root/build/GitX.app"
	running_pids=$(
		pgrep -x GitX 2>/dev/null | while read -r pid; do
			case "$(ps -p "$pid" -o comm= 2>/dev/null)" in
				("$staged"/*) printf '%s ' "$pid" ;;
			esac
		done
	)
	if [[ -n "$running_pids" ]]; then
		echo "GitX is running; stop it before replacing $staged." >&2
		return 3
	fi
	mkdir -p "$root/build"
	if [[ -e "$staged" ]]; then
		mv "$staged" "$run_dir/previous-Half Dark.app" || return 3
	fi
	temporary="$root/build/.Half Dark.app.$run_id"
	ditto "$built_app" "$temporary"
	copy_status=$?
	if (( copy_status != 0 )); then
		[[ ! -e "$run_dir/previous-Half Dark.app" ]] || mv "$run_dir/previous-Half Dark.app" "$staged"
		return "$copy_status"
	fi
	if ! mv "$temporary" "$staged"; then
		mv "$temporary" "$run_dir/failed-staged-Half Dark.app" 2>/dev/null || true
		[[ ! -e "$run_dir/previous-Half Dark.app" ]] || mv "$run_dir/previous-Half Dark.app" "$staged"
		return 3
	fi
	echo "Staged app: $staged"
}

case "$command" in
	build-tests)
		reject_managed_paths ${command_arguments[@]+"${command_arguments[@]}"} || exit $?
		run_step build-tests "$logs/build-tests.log" "" "$xcodebuild" "${common[@]}" build-for-testing \
			-testPlan GitX CODE_SIGN_IDENTITY=- ENABLE_TESTABILITY=YES ENABLE_HARDENED_RUNTIME=NO \
			${command_arguments[@]+"${command_arguments[@]}"} || exit $?
		;;
	build)
		reject_managed_paths ${command_arguments[@]+"${command_arguments[@]}"} || exit $?
		run_step build "$logs/build.log" "" "$xcodebuild" "${common[@]}" build CODE_SIGN_IDENTITY=- ${command_arguments[@]+"${command_arguments[@]}"} || exit $?
		if (( stage_app )); then
			stage_built_app ${command_arguments[@]+"${command_arguments[@]}"} || exit $?
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
		analyzer_output="$results/Analyzer"
		mkdir -p "$analyzer_output"
		run_step analyze "$analyzer_log" "" "$xcodebuild" "${common[@]}" analyze \
			ARCHS=arm64 CLANG_STATIC_ANALYZER_MODE_ON_ANALYZE_ACTION=deep \
			"CLANG_ANALYZER_OUTPUT_DIR=$analyzer_output" \
			CLANG_WARN_NULLABILITY_COMPLETENESS=YES CLANG_WARN_NULLABILITY_COMPLETENESS_ON_ARRAYS=YES \
			CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO COMPILER_INDEX_STORE_ENABLE=NO \
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
			host-preflight)
				xcode_test host-preflight GitXHostPreflight ${extra[@]+"${extra[@]}"} || exit $?
				;;
			correctness)
				plan=$(config testPlans.correctness)
				xcode_test correctness "$plan" -enableCodeCoverage YES ${extra[@]+"${extra[@]}"} || exit $?
				if [[ "$coverage_gate" == "enforced" ]]; then
					proposal="$results/coverage-proposal.json"
					run_step coverage "$logs/coverage.log" "" scripts/check_coverage.py \
						"$results/$plan.xcresult" --propose-improvements "$proposal" || exit $?
				fi
				;;
			ui)
				preflight=$(config testPlans.ui-preflight)
				plan=$(config testPlans.ui)
				preflight_extra=()
				index=0
				while (( index < ${#extra[@]} )); do
					argument=${extra[$index]}
					case "$argument" in
						-only-testing|-skip-testing|\
						-test-timeouts-enabled|-default-test-execution-time-allowance|\
						-maximum-test-execution-time-allowance)
							(( index + 1 < ${#extra[@]} )) || { echo "$argument requires a value" >&2; exit 2; }
							index=$((index + 2))
							;;
						-only-testing:*|-skip-testing:*|\
						-test-timeouts-enabled=*|-default-test-execution-time-allowance=*|\
						-maximum-test-execution-time-allowance=*)
							index=$((index + 1))
							;;
						*)
							preflight_extra+=("$argument")
							index=$((index + 1))
							;;
					esac
				done
				xcode_test ui-preflight "$preflight" \
					-test-timeouts-enabled YES \
					-default-test-execution-time-allowance 60 \
					-maximum-test-execution-time-allowance 90 \
					${preflight_extra[@]+"${preflight_extra[@]}"} || exit $?
				xcode_test ui "$plan" ${extra[@]+"${extra[@]}"} || exit $?
				;;
			address-undefined|thread-sanitizer|performance)
				plan=$(config "testPlans.$test_preset")
				xcode_test "$test_preset" "$plan" ${extra[@]+"${extra[@]}"} || exit $?
				;;
			core)
				package=$(config packages.core)
				scratch="$swiftpm_build_root/GitXCore"
				run_step test:core "$logs/core.log" "" "$xcrun" swift test --package-path "$package" --scratch-path "$scratch" --enable-code-coverage ${extra[@]+"${extra[@]}"} || exit $?
				codecov=$("$xcrun" swift test --package-path "$package" --scratch-path "$scratch" --show-codecov-path) || exit $?
				run_step coverage:core "$logs/core-coverage.log" "$codecov" python3 scripts/check_core_coverage.py "$codecov" || exit $?
				;;
			forgekit)
				package=$(config packages.forgekit)
				scratch="$swiftpm_build_root/ForgeKit"
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
		has_workspace=0
		has_project=0
		has_scheme=0
		has_destination=0
		has_configuration=0
		has_derived_data=0
		has_package_cache=0
		has_result_bundle=0
		is_test_action=0
		is_test_build=0
		for argument in "${extra[@]}"; do
			case "$argument" in
				-workspace|-workspace=*) has_workspace=1 ;;
				-project|-project=*) has_project=1 ;;
				-scheme|-scheme=*) has_scheme=1 ;;
				-destination|-destination=*) has_destination=1 ;;
				-configuration|-configuration=*) has_configuration=1 ;;
				-derivedDataPath|-derivedDataPath=*) has_derived_data=1 ;;
				-clonedSourcePackagesDirPath|-clonedSourcePackagesDirPath=*) has_package_cache=1 ;;
				-resultBundlePath|-resultBundlePath=*) has_result_bundle=1 ;;
				test|test-without-building) is_test_action=1; is_test_build=1 ;;
				build-for-testing) is_test_build=1 ;;
			esac
		done
		raw_common=()
		# Release Swift packages also need testable interfaces for app-hosted
		# XCTest imports; ordinary release builds retain their normal settings.
		(( is_test_build )) && raw_common+=( ENABLE_TESTABILITY=YES )
		# Local ad hoc test hosts cannot use Release library validation with
		# third-party signed frameworks. Production build/archive stays intact.
		if (( is_test_build )) && [[ "$signing_mode" == "ad-hoc" ]]; then
			raw_common+=( ENABLE_HARDENED_RUNTIME=NO )
		fi
		(( has_workspace || has_project )) || raw_common+=( -workspace "$workspace" )
		(( has_scheme )) || raw_common+=( -scheme "$scheme" )
		(( has_destination )) || raw_common+=( -destination "$destination" )
		(( has_configuration )) || raw_common+=( -configuration "$configuration" )
		(( has_derived_data )) || raw_common+=( -derivedDataPath "$derived_data" )
		(( has_package_cache )) || raw_common+=( -clonedSourcePackagesDirPath "$source_package_cache" )
		result_path=
		if (( is_test_action && ! has_result_bundle )); then
			result_path="$results/raw.xcresult"
			raw_common+=( -resultBundlePath "$result_path" )
		fi
		if (( is_test_action )); then
			# Raw test actions use the same desktop/provenance protections while
			# retaining explicit project, scheme, paths, signing and test options.
			suite_arguments=() compile_arguments=() probe_arguments=()
			raw_arguments=("${raw_common[@]}" "MACOSX_DEPLOYMENT_TARGET=$deployment_target" "${extra[@]}")
			raw_plan=GitX
			for ((index=0; index < ${#raw_arguments[@]}; index++)); do
				argument=${raw_arguments[$index]}
				case "$argument" in
					test|test-without-building) continue ;;
					-resultBundlePath)
						result_path=${raw_arguments[$((index + 1))]}
						suite_arguments+=("$argument" "$result_path")
						index=$((index + 1)); continue ;;
					-resultBundlePath=*)
						result_path=${argument#*=}; suite_arguments+=("$argument"); continue ;;
				esac
				suite_arguments+=("$argument")
				compile_arguments+=("$argument")
				case "$argument" in
					-testPlan)
						raw_plan=${raw_arguments[$((index + 1))]}
						suite_arguments+=("$raw_plan"); compile_arguments+=("$raw_plan")
						index=$((index + 1)) ;;
					-testPlan=*) raw_plan=${argument#*=} ;;
					-only-testing|-skip-testing)
						suite_arguments+=("${raw_arguments[$((index + 1))]}")
						compile_arguments+=("${raw_arguments[$((index + 1))]}")
						index=$((index + 1)) ;;
					-only-testing:*|-skip-testing:*|-only-testing=*|-skip-testing=*) ;;
					*) probe_arguments+=("$argument") ;;
				esac
			done
			case "$raw_plan" in
				GitX) ensure_probe_option -enableCodeCoverage YES ;;
				GitXAddressUndefined) ensure_probe_option -enableAddressSanitizer YES; ensure_probe_option -enableUndefinedBehaviorSanitizer YES ;;
				GitXThreadSanitizer) ensure_probe_option -enableThreadSanitizer YES ;;
			esac
			run_step compile:host-preflight "$logs/raw-host-build.log" "" "$xcodebuild" build-for-testing \
				"${probe_arguments[@]}" -testPlan GitXHostPreflight || exit $?
			run_step compile:raw "$logs/raw-build.log" "" "$xcodebuild" build-for-testing "${compile_arguments[@]}" || exit $?
			run_step signatures "$logs/raw-signatures.log" "" python3 "$root/scripts/workflow_session.py" signatures "$derived_data" || exit $?
			snapshot="$results/raw-inputs.json"
			python3 "$root/scripts/workflow_session.py" snapshot "$snapshot" --products "$derived_data" || exit $?
			run_step host-preflight "$logs/raw-host.log" "$results/raw-host.xcresult" \
				python3 "$root/scripts/workflow_session.py" run --timeout 120 --desktop --diagnostics "$run_dir/Diagnostics/host" -- \
				"$xcodebuild" test-without-building "${probe_arguments[@]}" -testPlan GitXHostPreflight \
				-only-testing:GitXTests/GitXHostStartTests/testHostStarts -resultBundlePath "$results/raw-host.xcresult" || exit $?
			run_step raw "$logs/raw.log" "$result_path" \
				python3 "$root/scripts/workflow_session.py" run --startup-timeout 120 --desktop --diagnostics "$run_dir/Diagnostics/raw" -- \
				"$xcodebuild" test-without-building "${suite_arguments[@]}"
			raw_status=$?
			run_step evidence "$logs/raw-evidence.log" "" python3 "$root/scripts/workflow_session.py" validate "$snapshot"
			evidence_status=$?
			(( raw_status == 0 )) || exit "$raw_status"
			(( evidence_status == 0 )) || exit "$evidence_status"
		else
			run_step raw "$logs/raw.log" "$result_path" "$xcodebuild" \
				${raw_common[@]+"${raw_common[@]}"} \
				MACOSX_DEPLOYMENT_TARGET="$deployment_target" \
				${extra[@]+"${extra[@]}"} || exit $?
		fi
		;;
esac

overall_status=passed
