#!/usr/bin/env bash
# Package an already-stapled app; publish only after all three payloads pass.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
[[ $# == 3 || ( $# == 5 && "$4" == --outputs ) ]] || { echo "Usage: $0 APP OUTPUT_DIRECTORY ARCHITECTURE [--outputs FILE]" >&2; exit 2; }
app_path=$1
output_directory=$2
artifact_arch=$3
outputs_file=${5:-}
source "$root/scripts/distribution_artifact_names.sh"
distribution_artifact_names "$artifact_arch"
"$root/scripts/verify_distribution_app.sh" "$app_path" "$artifact_arch" input
mkdir -p "$output_directory"
output_directory=$(cd "$output_directory" && pwd -P)
staging=$(mktemp -d "$output_directory/.gitx-package.XXXXXX")
mount_point="$staging/mounted-dmg"
attachment_attempted=false
mounted_device=
find_mount()
{
	hdiutil info -plist >"$staging/mounts.plist" || return $?
	python3 - "$staging/mounts.plist" "$mount_point" "$staging/$distribution_dmg_name" <<'PY'
import plistlib, sys
with open(sys.argv[1], "rb") as source:
    info = plistlib.load(source)
for image in info.get("images", []):
    if image.get("image-path") != sys.argv[3]:
        continue
    entities = image.get("system-entities", [])
    for entity in entities:
        if entity.get("mount-point") == sys.argv[2] and entity.get("dev-entry"):
            print(entity["dev-entry"])
            sys.exit(0)
    # Attachment may have created a device before mounting failed. Its exact
    # image path establishes ownership even without a mounted filesystem.
    for entity in entities:
        if entity.get("dev-entry"):
            print(entity["dev-entry"])
            sys.exit(0)
    raise ValueError("Attached distribution image has no identifiable device")
PY
}
cleanup()
{
	local status=$?
	if [[ "$attachment_attempted" == true ]]; then
		if ! mounted_device=$(find_mount); then
			echo "[gitx-package] Mount state is unknown; retained $staging" >&2
			if (( status == 0 )); then status=1; fi
			return "$status"
		fi
		if [[ -n "$mounted_device" ]] && ! hdiutil detach "$mounted_device" -quiet; then
			echo "[gitx-package] Could not detach $mounted_device; retained $staging" >&2
			if (( status == 0 )); then status=1; fi
			return "$status"
		fi
	fi
	rm -rf "$staging"
	return "$status"
}
trap cleanup EXIT
app_name=$(basename "$app_path")
ditto -c -k --sequesterRsrc --keepParent "$app_path" "$staging/$distribution_zip_name"
mkdir "$staging/zip"
ditto -x -k "$staging/$distribution_zip_name" "$staging/zip"
"$root/scripts/verify_distribution_app.sh" "$staging/zip/$app_name" "$artifact_arch" zip
mkdir "$staging/dmg"
ditto "$app_path" "$staging/dmg/$app_name"
ln -s /Applications "$staging/dmg/Applications"
hdiutil create -fs HFS+ -format UDZO -srcfolder "$staging/dmg" -volname "Half Dark" "$staging/$distribution_dmg_name"
mkdir "$mount_point"
attachment_attempted=true
hdiutil attach -nobrowse -readonly -mountpoint "$mount_point" "$staging/$distribution_dmg_name"
mounted_device=$(find_mount)
[[ -n "$mounted_device" ]] || { echo "[gitx-package] Attachment did not establish the expected mount" >&2; exit 1; }
"$root/scripts/verify_distribution_app.sh" "$mount_point/$app_name" "$artifact_arch" dmg
hdiutil detach "$mounted_device" -quiet
attachment_attempted=false
(
	cd "$staging"
	shasum -a 256 "$distribution_zip_name" "$distribution_dmg_name" >"$distribution_checksum_name"
)
mv "$staging/$distribution_zip_name" "$staging/$distribution_dmg_name" "$staging/$distribution_checksum_name" "$output_directory/"
if [[ -n "$outputs_file" ]]; then
	printf 'zip_path=%s\ndmg_path=%s\nchecksum_path=%s\n' "$output_directory/$distribution_zip_name" "$output_directory/$distribution_dmg_name" "$output_directory/$distribution_checksum_name" >>"$outputs_file"
fi
echo "[gitx-package] Published verified ZIP, DMG and checksums in $output_directory"
