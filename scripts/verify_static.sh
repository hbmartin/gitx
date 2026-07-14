#!/bin/bash

set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"

base_ref=${1:-}
if [[ -n "$base_ref" ]] && ! git rev-parse --verify "$base_ref^{commit}" >/dev/null 2>&1; then
	base_ref=
fi
if [[ -z "$base_ref" ]] && git rev-parse --verify origin/master >/dev/null 2>&1; then
    base_ref=origin/master
fi
if [[ -z "$base_ref" ]]; then
    base_ref=HEAD~1
fi

merge_base=$(git merge-base "$base_ref" HEAD)
changed_files=$(
	{
		git diff --diff-filter=ACMR --name-only "$merge_base"
		git ls-files --others --exclude-standard
	} | sort -u
)
echo "Checking formatting against $merge_base"
xcrun clang-format -dump-config -style=file Classes/main.m >/dev/null

objc_files=()
swift_files=()
while IFS= read -r file; do
    [[ -f "$file" ]] || continue
    case "$file" in
		Classes/*.h)
			if [[ "$file" != "Classes/iTerm2GeneratedScriptingBridge.h" ]]; then
				objc_files+=("$file")
            fi
            ;;
		Classes/*.m|Classes/*.mm|GitXTests/*.m|GitXUITests/*.m)
            objc_files+=("$file")
            ;;
		Classes/*.swift|GitXTests/*.swift)
            swift_files+=("$file")
            ;;
    esac
done <<< "$changed_files"

if (( ${#objc_files[@]} )); then
	python3 scripts/check_changed_format.py "$merge_base" "${objc_files[@]}"
fi
if (( ${#swift_files[@]} )); then
	scripts/run_pinned_tool.sh swiftformat --lint "${swift_files[@]}"
fi
scripts/run_pinned_tool.sh swiftlint lint --strict --config .swiftlint.yml --baseline .swiftlint-baseline.json

python3 scripts/check_header_interop.py "$merge_base"

find Resources -name '*.plist' -print0 | xargs -0 -n1 plutil -lint
find Resources -name '*.xib' -print0 | while IFS= read -r -d '' xib; do
    xcrun ibtool --warnings --errors --output-format human-readable-text "$xib" >/dev/null
done
find GitXTests -maxdepth 1 -name '*.xctestplan' -print0 | xargs -0 -n1 jq empty
find .github -name '*.yml' -print0 | xargs -0 ruby -e 'require "yaml"; ARGV.each { |path| YAML.safe_load_file(path, aliases: true) }'

PYTHONPYCACHEPREFIX="${TMPDIR:-/tmp}/gitx-pycache" python3 -m py_compile scripts/*.py scripts/tests/*.py
PYTHONPYCACHEPREFIX="${TMPDIR:-/tmp}/gitx-pycache" python3 -m unittest discover -s scripts/tests -v
for script in scripts/*.sh; do
    bash -n "$script"
done
if command -v shellcheck >/dev/null 2>&1; then
    shellcheck scripts/*.sh
fi
if command -v actionlint >/dev/null 2>&1; then
	actionlint
fi

git diff --check "$merge_base"
echo "Static verification passed."
