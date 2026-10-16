#!/usr/bin/env bash
# Package a verified, already-stapled app and validate both distributed payloads.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
[[ $# == 3 ]] || { echo "Usage: $0 APP OUTPUT_DIRECTORY ARCHITECTURE" >&2; exit 2; }
app_path=$1
output_directory=$2
artifact_arch=$3
[[ "$artifact_arch" =~ ^[[:alnum:]_]+$ ]] || { echo "Invalid architecture" >&2; exit 2; }
"$root/scripts/verify_distribution_app.sh" "$app_path" "$artifact_arch"

mkdir -p "$output_directory"
output_directory=$(cd "$output_directory" && pwd -P)
staging=$(mktemp -d "$output_directory/.gitx-package.XXXXXX")
mounted_dmg=
cleanup()
{
	local status=$?
	if [[ -n "$mounted_dmg" ]] && ! hdiutil detach "$mounted_dmg" -quiet; then
		echo "[gitx-package] Could not detach $mounted_dmg; retained $staging" >&2
		return 1
	fi
	rm -rf "$staging"
	return "$status"
}
trap cleanup EXIT

app_name=$(basename "$app_path")
zip_name="HalfDark-$artifact_arch.zip"
dmg_name="HalfDark-$artifact_arch.dmg"
ditto -c -k --sequesterRsrc --keepParent "$app_path" "$staging/$zip_name"
mkdir "$staging/zip"
ditto -x -k "$staging/$zip_name" "$staging/zip"
"$root/scripts/verify_distribution_app.sh" "$staging/zip/$app_name" "$artifact_arch"

mkdir "$staging/dmg"
ditto "$app_path" "$staging/dmg/$app_name"
ln -s /Applications "$staging/dmg/Applications"
hdiutil create -fs HFS+ -format UDZO -srcfolder "$staging/dmg" -volname "Half Dark" "$staging/$dmg_name"
mounted_dmg="$staging/mounted-dmg"
mkdir "$mounted_dmg"
hdiutil attach -nobrowse -readonly -mountpoint "$mounted_dmg" "$staging/$dmg_name"
"$root/scripts/verify_distribution_app.sh" "$mounted_dmg/$app_name" "$artifact_arch"
hdiutil detach "$mounted_dmg" -quiet
mounted_dmg=

(
	cd "$staging"
	shasum -a 256 "$zip_name" "$dmg_name" >"HalfDark-$artifact_arch.sha256"
)
mv "$staging/$zip_name" "$staging/$dmg_name" "$staging/HalfDark-$artifact_arch.sha256" "$output_directory/"
echo "[gitx-package] Published verified ZIP, DMG and checksums in $output_directory"
