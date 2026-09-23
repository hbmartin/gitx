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

Every invocation emits a receipt under artifacts/verification/<run-id> while
reusing the ignored build caches under build/.
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
	analyzer_derived_data=$(mktemp -d "$root/build/AnalyzerDerivedData.XXXXXX") || exit 2
	derived_data="$analyzer_derived_data"
else
	derived_data=${GITX_DERIVED_DATA:-"$root/$derived_data_cache"}
fi
swiftpm_build_root="$root/$swiftpm_build_cache"
mkdir -p "$logs" "$results" "$products" "$derived_data" "$swiftpm_build_root" "$root/$source_package_cache"
receipt="$run_dir/receipt.json"

signing_allowed=YES
signing_required=YES
signing_identity=
case "$command" in
	smoke)
		signing_allowed=NO
		signing_required=NO
		;;
	build|analyze)
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
		correctness|ui|address-undefined|thread-sanitizer|performance|core|forgekit)
			preset="test:${command_arguments[0]}"
			;;
		-testPlan)
			preset="test:${command_arguments[1]:-unknown}"
			;;
	esac
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
				-only-testing|-only-testing:*|-skip-testing|-skip-testing:*) coverage_gate=not-applicable-focused-selection ;;
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
	python3 "$support" receipt-finish "$receipt" --status "$overall_status" --exit-code "$exit_code" >/dev/null 2>&1 || true
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
"$root/scripts/doctor.sh" --mode "$doctor_mode" --developer-dir "$developer_dir" --destination "$destination" 2>&1 | tee "$doctor_log"
doctor_status=${PIPESTATUS[0]}
duration=$(elapsed_seconds "$started")
if (( doctor_status == 0 )); then
	doctor_result=passed
else
	doctor_result=blocked
	overall_status=blocked
fi
record_step doctor "$doctor_result" "$doctor_status" "$duration" "$doctor_log" "" "$root/scripts/doctor.sh" --mode "$doctor_mode" --developer-dir "$developer_dir" --destination "$destination"
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
			-workspace|-workspace=*|-project|-project=*|-scheme|-scheme=*|-testPlan|-testPlan=*|\
			-derivedDataPath|-derivedDataPath=*|-resultBundlePath|-resultBundlePath=*|\
			-clonedSourcePackagesDirPath|-clonedSourcePackagesDirPath=*|-archivePath|-archivePath=*)
				echo "$argument is managed by scripts/xcodebuild.sh" >&2
				return 2
				;;
		esac
	done
}

xcode_test() {
	local test_preset=$1
	local plan=$2
	local result="$results/$plan.xcresult"
	shift 2
	run_step "test:$test_preset" "$logs/$plan.log" "$result" \
		"$xcodebuild" "${common[@]}" test -testPlan "$plan" -resultBundlePath "$result" \
		CODE_SIGN_IDENTITY=- "$@"
}

stage_built_app() {
	built_products_dir=$(
		"$xcodebuild" "${common[@]}" -showBuildSettings "$@" 2>/dev/null \
			| awk -F' = ' '/ BUILT_PRODUCTS_DIR = /{print $2; exit}'
	)
	built_app="$built_products_dir/GitX.app"
	if [[ -z "$built_app" || ! -x "$built_app/Contents/MacOS/GitX" ]]; then
		echo "Could not locate a valid GitX.app in $derived_data" >&2
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
		mv "$staged" "$run_dir/previous-GitX.app" || return 3
	fi
	temporary="$root/build/.GitX.app.$run_id"
	ditto "$built_app" "$temporary"
	copy_status=$?
	if (( copy_status != 0 )); then
		[[ ! -e "$run_dir/previous-GitX.app" ]] || mv "$run_dir/previous-GitX.app" "$staged"
		return "$copy_status"
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
				test|test-without-building) is_test_action=1 ;;
			esac
		done
		raw_common=()
		(( has_workspace || has_project )) || raw_common+=( -workspace "$workspace" )
		(( has_scheme )) || raw_common+=( -scheme "$scheme" )
		(( has_destination )) || raw_common+=( -destination "$destination" )
		(( has_configuration )) || raw_common+=( -configuration "$configuration" )
		(( has_derived_data )) || raw_common+=( -derivedDataPath "$derived_data" )
		(( has_package_cache )) || raw_common+=( -clonedSourcePackagesDirPath "$root/$source_package_cache" )
		result_path=
		if (( is_test_action && ! has_result_bundle )); then
			result_path="$results/raw.xcresult"
			raw_common+=( -resultBundlePath "$result_path" )
		fi
		run_step raw "$logs/raw.log" "$result_path" "$xcodebuild" \
			${raw_common[@]+"${raw_common[@]}"} \
			MACOSX_DEPLOYMENT_TARGET="$deployment_target" \
			${extra[@]+"${extra[@]}"} || exit $?
		;;
esac

overall_status=passed
