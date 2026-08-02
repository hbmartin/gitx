#!/bin/bash

set -euo pipefail

SCRIPT_DIRECTORY="$(cd "$(dirname "$0")" && pwd)"
readonly SCRIPT_DIRECTORY
FORGEKIT_DIRECTORY="$(cd "$SCRIPT_DIRECTORY/.." && pwd)"
readonly FORGEKIT_DIRECTORY
readonly EXPECTED_APOLLO_VERSION="2.3.0"
readonly CODEGEN_CONFIG="$FORGEKIT_DIRECTORY/apollo-codegen-config.json"
readonly GENERATED_DIRECTORY="$FORGEKIT_DIRECTORY/Sources/GitHubForgeAdapter/Generated"
GENERATED_PARENT_DIRECTORY="$(dirname "$GENERATED_DIRECTORY")"
readonly GENERATED_PARENT_DIRECTORY

if [[ "${1:-}" != "--offline" || "$#" -ne 1 ]]; then
  echo "usage: $0 --offline" >&2
  exit 64
fi

recover_interrupted_swap() {
  local backup_directories=()
  local backup
  local recoverable_backup=""

  shopt -s nullglob
  backup_directories=("$GENERATED_PARENT_DIRECTORY"/.graphql-backup.*)
  shopt -u nullglob
  if (( ${#backup_directories[@]} == 0 )); then
    return
  fi

  if [[ -e "$GENERATED_DIRECTORY" ]]; then
    for backup in "${backup_directories[@]}"; do
      rm -rf -- "$backup"
    done
    return
  fi

  if (( ${#backup_directories[@]} == 1 )) && [[ -d "${backup_directories[0]}/Generated" ]]; then
    recoverable_backup="${backup_directories[0]}"
    mv "$recoverable_backup/Generated" "$GENERATED_DIRECTORY"
    rmdir "$recoverable_backup"
    echo "Recovered generated GraphQL sources from an interrupted swap." >&2
    return
  fi

  echo "Cannot safely recover interrupted generated GraphQL output." >&2
  echo "Inspect $GENERATED_PARENT_DIRECTORY/.graphql-backup.* before retrying." >&2
  exit 74
}

recover_interrupted_swap

resolve_apollo_cli() {
  if [[ -n "${APOLLO_IOS_CLI:-}" ]]; then
    printf '%s\n' "$APOLLO_IOS_CLI"
    return
  fi

  if [[ -x "$FORGEKIT_DIRECTORY/apollo-ios-cli" ]]; then
    printf '%s\n' "$FORGEKIT_DIRECTORY/apollo-ios-cli"
    return
  fi

  local cached_cli="$FORGEKIT_DIRECTORY/.build/gitx-apollo-cli-$EXPECTED_APOLLO_VERSION/apollo-ios-cli"
  if [[ -x "$cached_cli" ]]; then
    printf '%s\n' "$cached_cli"
    return
  fi

  local archive="$FORGEKIT_DIRECTORY/.build/checkouts/apollo-ios/CLI/apollo-ios-cli.tar.gz"
  if [[ -f "$archive" ]]; then
    mkdir -p "$(dirname "$cached_cli")"
    tar -xzf "$archive" -C "$(dirname "$cached_cli")"
    printf '%s\n' "$cached_cli"
    return
  fi

  if command -v apollo-ios-cli >/dev/null 2>&1; then
    command -v apollo-ios-cli
    return
  fi

  echo "Apollo iOS CLI $EXPECTED_APOLLO_VERSION is unavailable." >&2
  echo "Set APOLLO_IOS_CLI or resolve ForgeKit dependencies before offline generation." >&2
  exit 69
}

APOLLO_CLI="$(resolve_apollo_cli)"
readonly APOLLO_CLI
if [[ ! -x "$APOLLO_CLI" ]]; then
  echo "Apollo CLI is not executable: $APOLLO_CLI" >&2
  exit 69
fi

ACTUAL_APOLLO_VERSION="$("$APOLLO_CLI" --version)"
readonly ACTUAL_APOLLO_VERSION
if [[ "$ACTUAL_APOLLO_VERSION" != "$EXPECTED_APOLLO_VERSION" ]]; then
  echo "Apollo CLI version mismatch: expected $EXPECTED_APOLLO_VERSION, got $ACTUAL_APOLLO_VERSION" >&2
  exit 65
fi

# Apollo 2.3.0's pruning can alternate the namespace file when regenerating in
# place. Generate into an adjacent staging tree, then swap only after Apollo and
# normalization succeed. A failed run therefore leaves checked-in output intact.
mkdir -p "$GENERATED_PARENT_DIRECTORY"
STAGING_ROOT="$(mktemp -d "$GENERATED_PARENT_DIRECTORY/.graphql-codegen.XXXXXX")"
readonly STAGING_ROOT
readonly STAGED_GENERATED_DIRECTORY="$STAGING_ROOT/Generated"
TEMPORARY_CONFIG="$(mktemp "$FORGEKIT_DIRECTORY/.apollo-codegen.XXXXXX.json")"
readonly TEMPORARY_CONFIG
BACKUP_ROOT=""

cleanup() {
  local exit_status=$?
  trap - EXIT

  if [[ -n "$BACKUP_ROOT" && -d "$BACKUP_ROOT/Generated" && ! -e "$GENERATED_DIRECTORY" ]]; then
    mv "$BACKUP_ROOT/Generated" "$GENERATED_DIRECTORY"
  fi

  rm -f -- "$TEMPORARY_CONFIG"
  rm -rf -- "$STAGING_ROOT"
  if [[ -n "$BACKUP_ROOT" ]]; then
    rm -rf -- "$BACKUP_ROOT"
  fi

  exit "$exit_status"
}
trap cleanup EXIT

python3 - "$CODEGEN_CONFIG" "$TEMPORARY_CONFIG" "$STAGED_GENERATED_DIRECTORY" <<'PY'
import json
from pathlib import Path
import sys

config = json.loads(Path(sys.argv[1]).read_text())
config["output"]["schemaTypes"]["path"] = sys.argv[3]
Path(sys.argv[2]).write_text(json.dumps(config, indent=2) + "\n")
PY

cd "$FORGEKIT_DIRECTORY"
"$APOLLO_CLI" generate --path "$TEMPORARY_CONFIG"

# Apollo emits an @_exported import for embedded schema modules. GitX keeps
# Apollo private to the adapter target, so normalize that generated import.
python3 - "$STAGED_GENERATED_DIRECTORY" <<'PY'
from pathlib import Path
import sys

root = Path(sys.argv[1])
for path in sorted(root.rglob("*.swift")):
    source = path.read_text()
    normalized = source.replace("@_exported import ApolloAPI\n", "import ApolloAPI\n")
    if not normalized.endswith("\n"):
        normalized += "\n"
    if normalized != source:
        path.write_text(normalized)
PY

if ! find "$STAGED_GENERATED_DIRECTORY" -type f -name '*.swift' -print -quit | grep -q .; then
  echo "Apollo did not generate any Swift sources." >&2
  exit 65
fi

BACKUP_ROOT="$(mktemp -d "$GENERATED_PARENT_DIRECTORY/.graphql-backup.XXXXXX")"
if [[ -e "$GENERATED_DIRECTORY" ]]; then
  mv "$GENERATED_DIRECTORY" "$BACKUP_ROOT/Generated"
fi
mv "$STAGED_GENERATED_DIRECTORY" "$GENERATED_DIRECTORY"
rm -rf -- "$BACKUP_ROOT"
BACKUP_ROOT=""
