#!/usr/bin/env python3
"""Keep FlowDelta imports inside GitX's explicit adapter seams and its package pin exact and remote."""

from __future__ import annotations

import argparse
import json
import pathlib
import re
import sys


ALLOWED_FILES = {
    pathlib.Path("Controllers/FlowDeltaAdapters.swift"),
    pathlib.Path("Controllers/FlowDeltaReviewCommands.swift"),
    pathlib.Path("Controllers/HistoryFlowRevisionProvider.swift"),
}
# The FlowDelta products GitX links. Layout, the CLI and the reference app stay out of the app.
APPROVED_PRODUCTS = ("FlowDeltaCore", "FlowDeltaAnalysis", "FlowDeltaGit", "FlowDeltaUI", "FlowDeltaExport")
PROJECT = pathlib.Path("GitX.xcodeproj/project.pbxproj")
WORKSPACE = pathlib.Path("GitX.xcworkspace/contents.xcworkspacedata")
RESOLVED_FILES = (
    pathlib.Path("GitX.xcworkspace/xcshareddata/swiftpm/Package.resolved"),
    pathlib.Path("GitX.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"),
)
REMOTE_REFERENCE = re.compile(
    r"(?P<id>[0-9A-Fa-f]+) /\* XCRemoteSwiftPackageReference \"FlowDelta\" \*/ = \{(?P<body>.*?)\n\t\t\};",
    re.DOTALL,
)
PRODUCT_DEPENDENCY = re.compile(
    r"isa = XCSwiftPackageProductDependency;\s*package = (?P<package>[0-9A-Fa-f]+) [^;]*;\s*"
    r"productName = (?P<name>[A-Za-z0-9_]+);"
)
LOCAL_REFERENCE = re.compile(r"isa = XCLocalSwiftPackageReference;\s*relativePath = \"?(?P<path>[^\";]+)\"?;")
WORKSPACE_REFERENCE = re.compile(r'location = "(?P<location>[^"]+)"')
FLOWDELTA_IMPORT = re.compile(
    r"^\s*(?:(?:@[A-Za-z_][A-Za-z0-9_]*(?:\([^)]*\))?|"
    r"public|package|internal|fileprivate|private)\s+)*"
    r"import\s+(?:(?:typealias|struct|class|enum|protocol|let|var|func)\s+)?"
    r"FlowDelta[A-Za-z0-9_]*\b",
    re.MULTILINE,
)


def boundary_failures(source_root: pathlib.Path) -> list[str]:
    failures: list[str] = []
    swift_files = sorted(source_root.rglob("*.swift"))
    relative_files = {path.relative_to(source_root) for path in swift_files}

    for required in sorted(ALLOWED_FILES):
        if required not in relative_files:
            failures.append(f"Missing FlowDelta integration seam {required}")

    for path in swift_files:
        relative = path.relative_to(source_root)
        if relative not in ALLOWED_FILES and FLOWDELTA_IMPORT.search(path.read_text()):
            failures.append(f"{relative}: imports FlowDelta outside an approved integration seam")
    return failures


def dependency_failures(repository_root: pathlib.Path) -> list[str]:
    """Checks that GitX consumes one exact, remote FlowDelta release and links only the approved products."""
    failures: list[str] = []
    project = (repository_root / PROJECT).read_text()

    pinned_version: str | None = None
    reference = REMOTE_REFERENCE.search(project)
    if reference is None:
        failures.append("GitX.xcodeproj has no remote FlowDelta package reference")
    else:
        kind = re.search(r"kind = (\w+);", reference["body"])
        version = re.search(r"\bversion = ([^;]+);", reference["body"])
        if kind is None or kind[1] != "exactVersion":
            failures.append(f"FlowDelta must be pinned with exactVersion, not {kind[1] if kind else 'no requirement'}")
        elif version is None:
            failures.append("FlowDelta's exactVersion requirement has no version")
        else:
            pinned_version = version[1].strip().strip('"')

    for local in LOCAL_REFERENCE.finditer(project):
        if pathlib.PurePosixPath(local["path"]).name == "FlowDelta":
            failures.append(f"GitX.xcodeproj references a local FlowDelta package at {local['path']}")
    workspace = repository_root / WORKSPACE
    if workspace.is_file():
        for location in WORKSPACE_REFERENCE.finditer(workspace.read_text()):
            if pathlib.PurePosixPath(location["location"].split(":", 1)[-1]).name == "FlowDelta":
                failures.append(f"GitX.xcworkspace references a local FlowDelta checkout at {location['location']}")

    if reference is not None:
        linked = [match["name"] for match in PRODUCT_DEPENDENCY.finditer(project) if match["package"] == reference["id"]]
        failures += [f"GitX links unapproved FlowDelta product {name}" for name in linked if name not in APPROVED_PRODUCTS]
        failures += [
            f"GitX does not link required FlowDelta product {name}" for name in APPROVED_PRODUCTS if name not in linked
        ]

    for index, relative in enumerate(RESOLVED_FILES):
        path = repository_root / relative
        if not path.is_file():
            if index == 0:
                failures.append(f"{relative} is missing")
            continue
        pins = json.loads(path.read_text()).get("pins", [])
        pin = next((pin for pin in pins if pin.get("identity") == "flowdelta"), None)
        if pin is None:
            if index == 0:
                failures.append(f"{relative} does not pin FlowDelta")
            continue
        resolved = pin.get("state", {}).get("version")
        if pinned_version is None:
            failures.append(f"Package.resolved pins FlowDelta {resolved} but the project has no exact version")
        elif resolved != pinned_version:
            failures.append(
                f"Package.resolved pins FlowDelta {resolved} but the project requires exactly {pinned_version}"
            )
    return failures


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "source_root",
        nargs="?",
        type=pathlib.Path,
        default=pathlib.Path(__file__).resolve().parent.parent / "Classes",
    )
    parser.add_argument(
        "--repository-root",
        type=pathlib.Path,
        default=pathlib.Path(__file__).resolve().parent.parent,
    )
    args = parser.parse_args()

    failures = boundary_failures(args.source_root) + dependency_failures(args.repository_root)
    if failures:
        print("FlowDelta boundary check failed:", file=sys.stderr)
        for failure in failures:
            print(f"- {failure}", file=sys.stderr)
        return 1
    print(f"FlowDelta boundary check passed ({args.source_root})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
