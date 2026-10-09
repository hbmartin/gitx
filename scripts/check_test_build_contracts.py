#!/usr/bin/env python3
"""Validate effective Xcode test-action settings and shared source/plan membership."""
from __future__ import annotations

import json
import os
import pathlib
import subprocess
import sys
import xml.etree.ElementTree as ET

import verification_support as verification
import workflow_session as session


def validate_membership(root):
    project_path = root / "GitX.xcodeproj/project.pbxproj"
    project = json.loads(subprocess.check_output(["plutil", "-convert", "json", "-o", "-", str(project_path)]))["objects"]
    targets = {value["name"]: value for value in project.values() if value.get("isa") == "PBXNativeTarget"}
    for name in ("GitX", "GitXTests", "GitXUITests"):
        if name not in targets:
            raise ValueError(f"Missing real target {name}")
    for name in ("GitXTests", "GitXUITests"):
        sources = [project[phase] for phase in targets[name]["buildPhases"] if project[phase]["isa"] == "PBXSourcesBuildPhase"]
        members = {project[project[entry]["fileRef"]].get("path") for phase in sources for entry in phase["files"]}
        app_sources = [project[phase] for phase in targets["GitX"]["buildPhases"] if project[phase]["isa"] == "PBXSourcesBuildPhase"]
        app_members = {project[project[entry]["fileRef"]].get("path") for phase in app_sources for entry in phase["files"]}
        for path in (root / name).glob("*"):
            allowed = members if "import XCTest" in path.read_text(errors="replace") else members | app_members
            if path.suffix in {".swift", ".m"} and path.name not in allowed:
                raise ValueError(f"Missing source membership: {name}/{path.name}")
    scheme = ET.parse(root / "GitX.xcodeproj/xcshareddata/xcschemes/GitX.xcscheme")
    references = {entry.attrib["reference"].removeprefix("container:") for entry in scheme.findall(".//TestPlanReference")}
    for path in (root / "GitXTests").glob("*.xctestplan"):
        if str(path.relative_to(root)) not in references:
            raise ValueError(f"Shared plan missing from scheme: {path.name}")
        payload = json.loads(path.read_text())
        for target in payload["testTargets"]:
            if target["target"]["name"] not in targets:
                raise ValueError(f"Plan {path.name} references an unavailable target")


def validate_settings(settings, root):
    found = {}
    for target in settings:
        name = target.get("target")
        values = target["buildSettings"]
        found[name] = values
        if name in {"GitX", "GitXTests"}:
            headers = values.get("HEADER_SEARCH_PATHS", "")
            if "External/objective-git/External/libgit2/include" not in headers:
                raise ValueError(f"import-path: {name} lost inherited libgit2 headers; restore $(inherited)")
        if name in {"GitX", "GitXTests", "GitXCore", "ForgeKit", "GitHubForgeAdapter"} and values.get("ENABLE_TESTABILITY") != "YES":
            raise ValueError(f"testability: {name} is unavailable to compiled test consumers")
    if not {"GitX", "GitXTests", "GitXUITests"}.issubset(found):
        raise ValueError("Test build must include the actual app, unit-test and UI-test targets")


def dependency_checks(root):
    checks = []
    status = session.git(root, "submodule", "status", "--recursive")
    missing = [line for line in status.splitlines() if line.startswith("-")]
    checks.append({"name": "submodules", "status": "failed" if missing else "passed",
                   "detail": "Run git submodule update --init --recursive in this checkout: " + "; ".join(missing) if missing else "Initialized dependency commits recorded in receipt."})
    dependency = root / "External/objective-git"
    if dependency.exists() and not missing:
        libraries = [dependency / "External" / name for name in ("libgit2.a", "libssh2.a", "libcrypto.a")]
        absent = [str(path) for path in libraries if not path.is_file()]
        checks.append({"name": "generated-libraries", "status": "warning" if absent else "passed",
                       "detail": "Missing generated archives: " + ", ".join(absent) + ". Inspect External/objective-git/script/bootstrap prerequisites; prepare existing dependencies explicitly. Do not copy unverified archives from another checkout." if absent else "Existing archives: " + json.dumps({str(p): session.file_identity(p) for p in libraries})})
        if absent:
            import shutil
            unavailable = [name for name in ("cmake", "pkg-config", "autoconf", "automake", "libtool") if not shutil.which(name)]
            checks.append({"name": "build-prerequisites", "status": "failed" if unavailable else "passed",
                           "detail": "Unavailable prerequisites: " + ", ".join(unavailable) + "; prepare them explicitly before running the dependency bootstrap (which may invoke installers)." if unavailable else "Existing build prerequisites available; the canonical build will generate missing libraries."})
        header = dependency / "External/libgit2/include/git2.h"
        checks.append({"name": "dependency-import-path", "status": "passed" if header.is_file() else "failed",
                       "detail": str(header) if header.is_file() else "libgit2 header unavailable; initialize the nested submodule before compiling."})
    return checks


def main():
    root = session.ROOT
    developer = verification.resolve_developer_dir(verification.load_config())
    if not developer:
        raise ValueError("Supported local Xcode unavailable")
    validate_membership(root)
    for configuration in ("Debug", "Release"):
        paths = session.cache_paths(configuration=configuration, developer=str(developer))
        command = [str(developer / "usr/bin/xcodebuild"), "-workspace", "GitX.xcworkspace", "-scheme", "GitX",
                   "-configuration", configuration, "-derivedDataPath", paths["derivedData"], "-clonedSourcePackagesDirPath", paths["sourcePackages"],
                   "-showBuildSettings", "-json", "ENABLE_TESTABILITY=YES", "CODE_SIGN_IDENTITY=-"]
        command.extend(["build-for-testing", "-testPlan", "GitX"])
        result = subprocess.run(command, cwd=root, text=True, capture_output=True, timeout=120)
        if result.returncode:
            raise ValueError(result.stderr.strip())
        validate_settings(json.loads(result.stdout), root)
        print(f"{configuration} effective headers, testability and target membership passed.")
    return 0


if __name__ == "__main__":
    if os.environ.get("GITX_GUARDED_ENTRY") != str(pathlib.Path(__file__).resolve()):
        raise SystemExit(session.guard(__file__, sys.argv[1:]))
    os.environ.pop("GITX_GUARDED_ENTRY", None)
    try:
        raise SystemExit(main())
    except (ValueError, OSError, subprocess.SubprocessError) as error:
        print(error, file=sys.stderr)
        raise SystemExit(1)
