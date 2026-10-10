#!/usr/bin/env python3
"""Conservative change groups and non-delivery development feedback."""
from __future__ import annotations

import argparse
import json
import os
import pathlib
import re
import shutil
import subprocess
import sys

import workflow_session as session

FILE_LOCAL_RULES = {
    "duplicate_imports", "empty_count", "empty_string", "identical_operands",
    "overridden_super_call", "prohibited_super_call", "redundant_nil_coalescing",
    "unowned_variable_capture", "unused_closure_parameter", "unused_control_flow_label",
    "unused_enumerated", "unused_optional_binding", "unused_setter_value", "weak_delegate", "yoda_condition",
}
BOUNDARIES = (
    "check_gitxcore_boundary.py", "check_flowdelta_boundary.py", "check_forgekit_boundary.py",
    "check_forgekit_exports.py", "check_forge_codegen_drift.py", "check_avatar_boundary.py",
    "check_swift_concurrency_escapes.py",
)


def git(root, *arguments, optional=False):
    result = subprocess.run(["git", "-C", str(root), *arguments], capture_output=True,
                            env=session.git_environment())
    if result.returncode and not optional:
        raise ValueError("Cannot inspect comparison: " + result.stderr.decode(errors="replace").strip())
    return result.stdout if result.returncode == 0 else None


def comparison_base(root, reference=None):
    if reference is None:
        reference = next((candidate for candidate in ("origin/master", "HEAD~1", "HEAD")
                          if git(root, "rev-parse", "--verify", "--end-of-options", candidate + "^{commit}", optional=True)), None)
    if reference is None:
        raise ValueError("Cannot inspect comparison without a committed HEAD")
    commit = git(root, "rev-parse", "--verify", "--end-of-options", reference + "^{commit}").decode().strip()
    return git(root, "merge-base", commit, "HEAD").decode().strip()


def changed_paths(root, reference=None):
    base = comparison_base(root, reference)
    # Disabling rename coalescing includes both paths without parsing quoted names.
    tracked = git(root, "diff", "--name-only", "--no-renames", "-z", base, "--").split(b"\0")
    new = git(root, "ls-files", "--others", "--exclude-standard", "-z").split(b"\0")
    names = [os.fsdecode(name) for name in tracked if name]
    names += [os.fsdecode(name) for name in new if name and session.build_input_path(os.fsdecode(name))]
    return base, sorted({name for name in names if not session.generated_input_path(name)})


def group_for(path):
    if path == "AGENTS.md" or path.startswith((".agents/", ".github/", "GitX.xcodeproj/", "GitX.xcworkspace/", "External/")):
        return "full"
    if path in {"Mintfile", ".gitmodules", ".swiftlint.yml", ".swiftlint-baseline.json", ".swiftformat"} or path.endswith((".h", ".pch", ".modulemap", ".xcconfig", ".entitlements", ".xctestplan", "/Package.swift", "/Package.resolved")):
        return "full"
    if path.startswith("scripts/") and (path.endswith("baseline.json") or path == "scripts/verification-config.json"):
        return "full"
    if path.endswith((".md", ".markdown")) and ("/" not in path or path.startswith(("docs/", "GitXCore/", "ForgeKit/"))):
        return "docs"
    if path.startswith("scripts/"):
        return "scripts"
    if path.startswith("GitXCore/"):
        return "core"
    if path.startswith("ForgeKit/"):
        return "forgekit"
    if path.startswith(("Resources/", "GitXUITests/")):
        return "ui"
    if path.startswith(("Classes/", "GitXTests/")):
        return "ui" if any(word in pathlib.PurePosixPath(path).stem for word in ("Controller", "View", "Window", "Cell")) else "app"
    return "full"


def select_checks(paths, full_names):
    groups = {group_for(path) for path in paths}
    reasons = {path: group_for(path) for path in paths}
    if "full" in groups:
        return list(full_names), reasons
    selected = {"static"} if groups - {"docs"} else {"whitespace"}
    if groups & {"core", "forgekit", "app", "ui"}:
        selected.add("debug-test-build")
    selected.update(groups & {"core", "forgekit"})
    if groups & {"app", "ui"}:
        selected.update(("interop", "correctness"))
    if "ui" in groups:
        selected.add("ui")
    order = ["whitespace", *full_names]
    return [name for name in order if name in selected], reasons


def focus_commands(commands, selectors):
    checks = {"GitXTests": "correctness", "GitXUITests": "ui"}
    names = {name for name, _ in commands}
    filters = {name: [] for name in checks.values()}
    for value in selectors or []:
        parts = value.split("/")
        if len(parts) not in (2, 3) or any(not part or any(c.isspace() for c in part) for part in parts) or parts[0] not in checks:
            raise ValueError("Expected --only-testing GitXTests|GitXUITests/CLASS[/METHOD]")
        check = checks[parts[0]]
        if check not in names:
            raise ValueError("Focused selector requires selected check: " + check)
        filters[check].append("-only-testing:" + value)
    return [(name, command + filters.get(name, [])) for name, command in commands]


def execute(command, root, env=None):
    print("Feedback: " + " ".join(str(value) for value in command), flush=True)
    subprocess.run(command, cwd=root, env=env, check=True)


def lint_rules_are_file_local(root):
    path = root / ".swiftlint.yml"
    if not path.is_file():
        return False
    match = re.search(r"(?m)^only_rules:\s*\n((?:[ \t]+[^\n]*\n)*)", path.read_text())
    rules = set(re.findall(r"(?m)^\s*-\s*([a-z_]+)\s*$", match[1])) if match else set()
    return bool(rules) and rules <= FILE_LOCAL_RULES


def static_feedback(root, reference=None):
    root = pathlib.Path(root)
    base, paths = changed_paths(root, reference)
    if any(group_for(path) == "full" for path in paths):
        execute([str(root / "scripts/verify_static.sh"), base], root)
        return
    existing = [path for path in paths if (root / path).is_file()]
    objc = [path for path in existing if path.endswith((".m", ".mm", ".h")) and path.startswith(("Classes/", "GitXTests/", "GitXUITests/")) and "iTerm2Generated" not in path]
    swift = [path for path in existing if path.endswith(".swift") and path.startswith(("Classes/", "GitXTests/", "GitXUITests/", "GitXCore/", "ForgeKit/")) and not path.startswith("ForgeKit/Sources/GitHubForgeAdapter/Generated/")]
    if objc:
        execute([sys.executable, "scripts/check_changed_format.py", base, *objc], root)
    tool = str(root / "scripts/run_pinned_tool.sh")
    if swift:
        execute([tool, "swiftformat", "--lint", *swift], root)
    lint = [tool, "swiftlint", "lint", "--strict", "--config", str(root / ".swiftlint.yml"), "--baseline", str(root / ".swiftlint-baseline.json")]
    if lint_rules_are_file_local(root):
        if swift:
            env = os.environ | {"SCRIPT_INPUT_FILE_COUNT": str(len(swift))}
            env.update({f"SCRIPT_INPUT_FILE_{index}": str(root / path) for index, path in enumerate(swift)})
            execute([*lint, "--use-script-input-files", "--force-exclude"], root, env)
    else:
        execute(lint, root)
    for script in BOUNDARIES:
        execute([sys.executable, "scripts/" + script], root)
    execute([sys.executable, "scripts/check_header_interop.py", base], root)
    for path in existing:
        if path.startswith("Resources/") and path.endswith(".plist"):
            execute(["plutil", "-lint", path], root)
        elif path.startswith("Resources/") and path.endswith(".xib"):
            execute(["xcrun", "ibtool", "--warnings", "--errors", "--output-format", "human-readable-text", str((root / path).absolute())], root)
        elif path.endswith(".xctestplan"):
            json.loads((root / path).read_text())
    if any(path.startswith("scripts/") for path in paths):
        execute([sys.executable, "-m", "py_compile", *[str(path) for path in sorted((root / "scripts").glob("*.py"))], *[str(path) for path in sorted((root / "scripts/tests").glob("*.py"))]], root,
                os.environ | {"PYTHONPYCACHEPREFIX": str(pathlib.Path(os.environ.get("TMPDIR", "/tmp")) / "gitx-pycache")})
        execute([sys.executable, "-m", "unittest", "discover", "-s", "scripts/tests", "-v"], root)
        for path in sorted((root / "scripts").glob("*.sh")):
            execute(["bash", "-n", str(path)], root)
        if shutil.which("shellcheck"):
            execute(["shellcheck", *[str(path) for path in sorted((root / "scripts").glob("*.sh"))]], root)
    execute(["git", "diff", "--check", base, "--"], root)
    print("Static feedback passed; full delivery verification is still required.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["static", "whitespace"])
    parser.add_argument("--base-ref")
    args = parser.parse_args()
    try:
        if args.command == "static":
            static_feedback(session.ROOT, args.base_ref)
        else:
            execute(["git", "diff", "--check", comparison_base(session.ROOT, args.base_ref), "--"], session.ROOT)
        return 0
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print(error, file=sys.stderr)
        return error.returncode if isinstance(error, subprocess.CalledProcessError) else 2


if __name__ == "__main__":
    raise SystemExit(main())
