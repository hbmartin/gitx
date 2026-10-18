#!/usr/bin/env bash
# shellcheck disable=SC2034 # Function outputs are consumed by the sourcing release and packaging scripts.
# Shared release filenames. Call after sourcing; never infer names in consumers.
distribution_artifact_names()
{
	[[ $# == 1 && "$1" =~ ^[[:alnum:]_]+$ ]] || { echo "Invalid distribution architecture" >&2; return 2; }
	distribution_prefix="HalfDark-$1"
	distribution_zip_name="$distribution_prefix.zip"
	distribution_dmg_name="$distribution_prefix.dmg"
	distribution_checksum_name="$distribution_prefix.sha256"
}
