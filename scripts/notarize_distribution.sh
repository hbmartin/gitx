#!/usr/bin/env bash
# Retain diagnostics before deciding whether a notarization submission succeeded.
set -euo pipefail
[[ $# == 2 ]] || { echo "Usage: $0 ZIP LOG_DIRECTORY" >&2; exit 2; }
archive_path=$1
log_directory=$2
mkdir -p "$log_directory"
submission="$log_directory/notary-submission.json"
submission_errors="$log_directory/notary-submission.stderr"
details="$log_directory/notary-details.json"
credentials=(--apple-id "${APPLE_ID:?}" --team-id "${TEAM_ID:?}" --password "${APPLE_PASSWORD:?}")
submission_status=0
xcrun notarytool submit "$archive_path" "${credentials[@]}" --output-format json --wait >"$submission" 2>"$submission_errors" || submission_status=$?
cat "$submission" "$submission_errors"
submission_id=$(python3 - "$submission" <<'PY'
import json, sys
try:
    value = json.load(open(sys.argv[1]))
    identifier = value.get("id", "")
    print(identifier if isinstance(identifier, str) else "")
except (OSError, ValueError, AttributeError):
    pass
PY
)
if [[ -n "$submission_id" ]]; then
	if xcrun notarytool log "$submission_id" "${credentials[@]}" "$details"; then
		cat "$details"
	else
		echo "[gitx-notary] Could not fetch the detailed log for $submission_id" >&2
	fi
fi
if (( submission_status != 0 )); then
	echo "[gitx-notary] Submission failed with exit status $submission_status; diagnostics: $log_directory" >&2
	exit "$submission_status"
fi
python3 - "$submission" <<'PY'
import json, sys
try:
    result = json.load(open(sys.argv[1]))
    if (not isinstance(result, dict) or result.get("status") != "Accepted"
            or not isinstance(result.get("id"), str) or not result["id"].strip()):
        raise ValueError("submission was not accepted: " + str(result))
except (OSError, ValueError) as error:
    print("[gitx-notary] " + str(error), file=sys.stderr)
    sys.exit(1)
PY
