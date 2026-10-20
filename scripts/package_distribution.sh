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
publication_pending=false
published_names=()
backup_names=()
rollback_artifacts()
{
	local name restored=true
	for name in ${published_names[@]+"${published_names[@]}"}; do
		if ! rm -f "$output_directory/$name"; then restored=false; fi
	done
	for name in ${backup_names[@]+"${backup_names[@]}"}; do
		if ! mv "$staging/previous/$name" "$output_directory/$name"; then restored=false; fi
	done
	[[ "$restored" == true ]]
}
find_mount()
{
	hdiutil info -plist >"$staging/mounts.plist" || return $?
	python3 - "$staging/mounts.plist" "$mount_point" "$staging/$distribution_dmg_name" <<'PY'
import os, plistlib, sys
with open(sys.argv[1], "rb") as source:
    info = plistlib.load(source)
if not isinstance(info, dict) or not isinstance(info.get("images"), list):
    raise ValueError("Malformed attached-image inventory")
images = info["images"]
owned = []
for image in images:
    if not isinstance(image, dict) or not isinstance(image.get("image-path"), str) or not image["image-path"].strip() or not isinstance(image.get("system-entities"), list):
        raise ValueError("Malformed attached-image record")
    entities = image["system-entities"]
    if any(not isinstance(entity, dict) for entity in entities):
        raise ValueError("Malformed attached-image device")
    # Every mountpoint matters: an unrelated image may occupy our staging directory.
    if any("mount-point" in entity and (not isinstance(entity["mount-point"], str) or not entity["mount-point"].strip()) for entity in entities):
        raise ValueError("Malformed attached-image mountpoint")
    matches = os.path.realpath(image["image-path"]) == os.path.realpath(sys.argv[3])
    occupied = any(isinstance(entity.get("mount-point"), str) and os.path.realpath(entity["mount-point"]) == os.path.realpath(sys.argv[2]) for entity in entities)
    if occupied and not matches:
        raise ValueError("Staging mountpoint belongs to an unidentified image")
    if not matches:
        continue
    # Device metadata grants detach authority only for this exact distribution image.
    if any("dev-entry" in entity and (not isinstance(entity["dev-entry"], str) or not entity["dev-entry"].strip()) for entity in entities):
        raise ValueError("Malformed owned-image device identity")
    owned.append(entities)
if len(owned) > 1:
    raise ValueError("Distribution image has ambiguous attachment ownership")
for entities in owned:
    mounted_devices = {entity["dev-entry"] for entity in entities if entity.get("mount-point") and os.path.realpath(entity["mount-point"]) == os.path.realpath(sys.argv[2]) and entity.get("dev-entry")}
    if len(mounted_devices) > 1:
        raise ValueError("Staging mountpoint has conflicting device identities")
    for entity in entities:
        if entity.get("mount-point") and os.path.realpath(entity["mount-point"]) == os.path.realpath(sys.argv[2]) and entity.get("dev-entry"):
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
	if [[ "$publication_pending" == true ]] && ! rollback_artifacts; then
		echo "[gitx-package] Could not restore the previous artifact set; retained $staging" >&2
		if (( status == 0 )); then status=1; fi
		return "$status"
	fi
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
		if [[ -n "$mounted_device" ]]; then
			if ! mounted_device=$(find_mount) || [[ -n "$mounted_device" ]]; then
				echo "[gitx-package] Image absence could not be confirmed after detach; retained $staging" >&2
				if (( status == 0 )); then status=1; fi
				return "$status"
			fi
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
mounted_device=$(find_mount)
[[ -z "$mounted_device" ]] || { echo "[gitx-package] Image remains attached after detach; retained $staging" >&2; exit 1; }
attachment_attempted=false
(
	cd "$staging"
	shasum -a 256 "$distribution_zip_name" "$distribution_dmg_name" >"$distribution_checksum_name"
)
artifact_names=("$distribution_zip_name" "$distribution_dmg_name" "$distribution_checksum_name")
mkdir "$staging/previous"
for name in "${artifact_names[@]}"; do
	if [[ -e "$output_directory/$name" || -L "$output_directory/$name" ]]; then
		[[ -f "$output_directory/$name" && ! -L "$output_directory/$name" ]] || { echo "[gitx-package] Existing artifact is not a regular file: $name" >&2; exit 1; }
	fi
done
publication_pending=true
for name in "${artifact_names[@]}"; do
	if [[ -e "$output_directory/$name" ]]; then
		mv "$output_directory/$name" "$staging/previous/$name"
		backup_names+=("$name")
	fi
	mv "$staging/$name" "$output_directory/$name"
	published_names+=("$name")
done
if [[ -n "$outputs_file" ]]; then
	printf 'zip_path=%s\ndmg_path=%s\nchecksum_path=%s\n' "$output_directory/$distribution_zip_name" "$output_directory/$distribution_dmg_name" "$output_directory/$distribution_checksum_name" >>"$outputs_file"
fi
echo "[gitx-package] Published verified ZIP, DMG and checksums in $output_directory"
publication_pending=false
