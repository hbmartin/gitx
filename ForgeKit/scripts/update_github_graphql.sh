#!/bin/bash

set -euo pipefail

SCRIPT_DIRECTORY="$(cd "$(dirname "$0")" && pwd)"
readonly SCRIPT_DIRECTORY
FORGEKIT_DIRECTORY="$(cd "$SCRIPT_DIRECTORY/.." && pwd)"
readonly FORGEKIT_DIRECTORY
readonly SCHEMA_PATH="$FORGEKIT_DIRECTORY/GraphQL/schema.graphqls"
readonly GENERATED_DIRECTORY="$FORGEKIT_DIRECTORY/Sources/GitHubForgeAdapter/Generated"

if [[ "$#" -ne 0 ]]; then
  echo "usage: $0" >&2
  exit 64
fi

BACKUP_ROOT=""
BACKUP_READY=0
UPDATE_COMMITTED=0

restore_previous_revision() {
  local failed_generated="$BACKUP_ROOT/failed-Generated"
  local failed_schema="$BACKUP_ROOT/failed-schema.graphqls"

  if [[ -e "$GENERATED_DIRECTORY" ]]; then
    mv "$GENERATED_DIRECTORY" "$failed_generated"
  fi
  mv "$BACKUP_ROOT/Generated" "$GENERATED_DIRECTORY"

  if [[ -e "$SCHEMA_PATH" ]]; then
    mv "$SCHEMA_PATH" "$failed_schema"
  fi
  mv "$BACKUP_ROOT/schema.graphqls" "$SCHEMA_PATH"
}

backup_is_complete() {
  local candidate=$1
  [[ -s "$candidate/schema.graphqls" ]] || return 1
  grep -Eq '^type Query\b' "$candidate/schema.graphqls" || return 1
  [[ -d "$candidate/Generated" ]] || return 1
  find "$candidate/Generated" -type f -name '*.swift' -print -quit | grep -q .
}

recover_interrupted_update() {
  local backups=()

  shopt -s nullglob
  backups=("$FORGEKIT_DIRECTORY"/.github-schema-backup.*)
  shopt -u nullglob
  if (( ${#backups[@]} == 0 )); then
    return
  fi
  if (( ${#backups[@]} != 1 )); then
    echo "Cannot safely recover an interrupted GitHub schema refresh." >&2
    echo "Expected exactly one backup; found ${#backups[@]}." >&2
    exit 74
  fi
  if ! backup_is_complete "${backups[0]}"; then
    echo "Cannot safely recover an interrupted GitHub schema refresh." >&2
    echo "Backup is incomplete: ${backups[0]}" >&2
    exit 74
  fi

  BACKUP_ROOT="${backups[0]}"
  BACKUP_READY=1
  if ! restore_previous_revision; then
    echo "Could not restore the interrupted GitHub schema refresh." >&2
    echo "Recovery files remain at $BACKUP_ROOT." >&2
    exit 74
  fi
  rm -rf -- "$BACKUP_ROOT"
  BACKUP_ROOT=""
  BACKUP_READY=0
  echo "Recovered schema and generated sources from an interrupted refresh." >&2
}

recover_interrupted_update

if ! command -v gh >/dev/null 2>&1; then
  echo "GitHub CLI is required to refresh the GitHub.com schema." >&2
  exit 69
fi

if ! gh auth status --hostname github.com >/dev/null 2>&1; then
  echo "Authenticate GitHub CLI for github.com before refreshing the schema." >&2
  exit 77
fi

TEMPORARY_SCHEMA="$(mktemp "${TMPDIR:-/tmp}/gitx-github-schema.XXXXXX")"
readonly TEMPORARY_SCHEMA

cleanup() {
  local exit_status=$?
  local restore_status=0
  trap - EXIT

  if [[ "$UPDATE_COMMITTED" -eq 0 && "$BACKUP_READY" -eq 1 ]]; then
    restore_previous_revision || restore_status=$?
  fi
  rm -f -- "$TEMPORARY_SCHEMA"
  if [[ -n "$BACKUP_ROOT" && "$restore_status" -eq 0 ]]; then
    rm -rf -- "$BACKUP_ROOT"
  fi
  if [[ "$restore_status" -ne 0 ]]; then
    echo "Could not restore the previous schema and generated sources." >&2
    echo "Recovery files remain at $BACKUP_ROOT." >&2
    exit "$restore_status"
  fi
  exit "$exit_status"
}
trap cleanup EXIT

gh api \
  --method GET \
  graphql \
  --header "Accept: application/vnd.github.v4.idl" \
  --jq '.data' \
  > "$TEMPORARY_SCHEMA"

python3 - "$TEMPORARY_SCHEMA" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
lines = [line.rstrip() for line in path.read_text().splitlines()]
while lines and not lines[-1]:
    lines.pop()
path.write_text("\n".join(lines) + "\n")
PY

if [[ ! -s "$TEMPORARY_SCHEMA" ]] || ! grep -Eq '^type Query\b' "$TEMPORARY_SCHEMA"; then
  echo "GitHub returned an invalid or empty GraphQL schema." >&2
  exit 65
fi

BACKUP_ROOT="$(mktemp -d "$FORGEKIT_DIRECTORY/.github-schema-backup.XXXXXX")"
cp -p "$SCHEMA_PATH" "$BACKUP_ROOT/schema.graphqls"
cp -R "$GENERATED_DIRECTORY" "$BACKUP_ROOT/Generated"
BACKUP_READY=1
mv "$TEMPORARY_SCHEMA" "$SCHEMA_PATH"
"$SCRIPT_DIRECTORY/generate_graphql.sh" --offline
UPDATE_COMMITTED=1
echo "Refreshed the GitHub.com GraphQL schema and generated Swift sources."
