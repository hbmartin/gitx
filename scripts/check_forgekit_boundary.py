#!/usr/bin/env python3
"""Keep Apollo and generated GraphQL types inside GitHubForgeAdapter."""

from __future__ import annotations

import pathlib
import re
import sys


ROOT = pathlib.Path(__file__).resolve().parents[1]
FORGEKIT_ROOT = pathlib.PurePosixPath("ForgeKit")
ADAPTER_ROOT = pathlib.PurePosixPath("ForgeKit/Sources/GitHubForgeAdapter")
GENERATED_ROOT = pathlib.PurePosixPath(
    "ForgeKit/Sources/GitHubForgeAdapter/Generated"
)
FIRST_PARTY_ROOTS = (
    "Classes",
    "GitXTests",
    "GitXUITests",
    "GitXCore/Package.swift",
    "GitXCore/Sources",
    "GitXCore/Tests",
    "ForgeKit/Package.swift",
    "ForgeKit/Sources",
    "ForgeKit/Tests",
)
IMPORT_DECLARATION = re.compile(
    r"^\s*(?:(?:@[A-Za-z_][A-Za-z0-9_]*(?:\([^)]*\))?|"
    r"public|package|internal|fileprivate|private)\s+)*"
    r"import\s+(?:(?:class|struct|enum|protocol|func|var|let|typealias)\s+)?"
    r"([A-Za-z_][A-Za-z0-9_]*)",
    re.MULTILINE,
)
TOP_LEVEL_DECLARATION = re.compile(
    r"^(?:(?:public|package|internal|fileprivate|private|open|final|indirect|"
    r"nonisolated)\s+)*(?:class|struct|enum|protocol|actor|typealias)\s+"
    r"([A-Za-z_][A-Za-z0-9_]*)\b",
    re.MULTILINE,
)
DIRECT_GENERATED_PATH_REFERENCE = re.compile(
    r"(?:GitHubForgeAdapter/Generated|Sources/GitHubForgeAdapter/Generated|"
    r"Generated/[A-Za-z_][A-Za-z0-9_.-]*\.swift)"
)


def is_relative_to(path: pathlib.PurePosixPath, parent: pathlib.PurePosixPath) -> bool:
    try:
        path.relative_to(parent)
        return True
    except ValueError:
        return False


def first_party_swift_files(repository_root: pathlib.Path) -> list[pathlib.Path]:
    files: set[pathlib.Path] = set()
    for name in FIRST_PARTY_ROOTS:
        path = repository_root / name
        if path.is_file() and path.suffix == ".swift":
            files.add(path)
        elif path.is_dir():
            files.update(path.rglob("*.swift"))
    return sorted(files)


def generated_type_names(repository_root: pathlib.Path) -> set[str]:
    generated_root = repository_root / pathlib.Path(GENERATED_ROOT)
    names: set[str] = set()
    if not generated_root.is_dir():
        return names
    for path in sorted(generated_root.rglob("*.swift")):
        names.update(TOP_LEVEL_DECLARATION.findall(path.read_text(errors="replace")))
    return names


def referenced_generated_names(source: str, names: set[str]) -> set[str]:
    return {
        name
        for name in names
        if re.search(rf"\b{re.escape(name)}\b", source)
    }


def boundary_failures(repository_root: pathlib.Path) -> list[str]:
    failures: list[str] = []
    generated_names = generated_type_names(repository_root)
    for path in first_party_swift_files(repository_root):
        relative = pathlib.PurePosixPath(path.relative_to(repository_root).as_posix())
        source = path.read_text(errors="replace")
        inside_adapter = is_relative_to(relative, ADAPTER_ROOT)
        if not inside_adapter:
            for module in sorted(set(IMPORT_DECLARATION.findall(source))):
                if module.startswith("Apollo"):
                    failures.append(
                        f"{relative}: imports {module} outside GitHubForgeAdapter"
                    )
            if DIRECT_GENERATED_PATH_REFERENCE.search(source):
                failures.append(
                    f"{relative}: references the generated GraphQL source location "
                    "outside GitHubForgeAdapter"
                )
            for name in sorted(referenced_generated_names(source, generated_names)):
                failures.append(
                    f"{relative}: references generated GraphQL type {name} "
                    "outside GitHubForgeAdapter"
                )
    return failures


def main() -> int:
    if not (ROOT / pathlib.Path(FORGEKIT_ROOT)).exists():
        print("ForgeKit boundary check skipped until the ForgeKit package is present.")
        return 0
    failures = boundary_failures(ROOT)
    if failures:
        print("ForgeKit dependency boundary check failed:", file=sys.stderr)
        for failure in failures:
            print(f"- {failure}", file=sys.stderr)
        return 1
    print("ForgeKit dependency boundary check passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
