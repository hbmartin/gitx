#!/usr/bin/env python3
"""Regenerate ForgeKit GraphQL sources offline and reject checked-in drift."""

from __future__ import annotations

import hashlib
import os
import pathlib
import re
import subprocess
import sys


ROOT = pathlib.Path(__file__).resolve().parents[1]
FORGEKIT_ROOT = pathlib.PurePosixPath("ForgeKit")
SCHEMA = pathlib.PurePosixPath("ForgeKit/GraphQL/schema.graphqls")
CONFIG = pathlib.PurePosixPath("ForgeKit/apollo-codegen-config.json")
GENERATOR = pathlib.PurePosixPath("ForgeKit/scripts/generate_graphql.sh")
GENERATED_ROOT = pathlib.PurePosixPath(
    "ForgeKit/Sources/GitHubForgeAdapter/Generated"
)
ADAPTER_ROOT = pathlib.PurePosixPath("ForgeKit/Sources/GitHubForgeAdapter")
APOLLO_IMPORT = re.compile(
    r"^\s*(?:(?:@[A-Za-z_][A-Za-z0-9_]*(?:\([^)]*\))?|"
    r"public|package|internal|fileprivate|private)\s+)*"
    r"import\s+(?:(?:class|struct|enum|protocol|func|var|let|typealias)\s+)?"
    r"Apollo[A-Za-z0-9_]*\b",
    re.MULTILINE,
)
CODEGEN_REFERENCE = re.compile(
    r"\bApollo(?:API)?\.|GitHubForgeAdapter/Generated|"
    r"Sources/GitHubForgeAdapter/Generated"
)


def generated_snapshot(repository_root: pathlib.Path) -> dict[str, str]:
    generated_root = repository_root / pathlib.Path(GENERATED_ROOT)
    if not generated_root.is_dir():
        return {}
    return {
        path.relative_to(generated_root).as_posix(): hashlib.sha256(
            path.read_bytes()
        ).hexdigest()
        for path in sorted(generated_root.rglob("*"))
        if path.is_file()
    }


def required_asset_failures(repository_root: pathlib.Path) -> list[str]:
    failures: list[str] = []
    for relative in (SCHEMA, CONFIG, GENERATOR):
        path = repository_root / pathlib.Path(relative)
        if not path.is_file():
            failures.append(f"missing required ForgeKit codegen asset: {relative}")

    generator = repository_root / pathlib.Path(GENERATOR)
    if generator.is_file() and not os.access(generator, os.X_OK):
        failures.append(f"ForgeKit codegen generator is not executable: {GENERATOR}")

    generated_root = repository_root / pathlib.Path(GENERATED_ROOT)
    if not generated_root.is_dir():
        failures.append(
            f"missing checked-in ForgeKit generated source directory: {GENERATED_ROOT}"
        )
    elif not generated_snapshot(repository_root):
        failures.append(
            f"ForgeKit generated source directory is empty: {GENERATED_ROOT}"
        )
    return failures


def codegen_usage(repository_root: pathlib.Path) -> list[str]:
    usage: list[str] = []
    adapter_root = repository_root / pathlib.Path(ADAPTER_ROOT)
    if adapter_root.is_dir():
        for path in sorted(adapter_root.rglob("*.swift")):
            source = path.read_text(errors="replace")
            if APOLLO_IMPORT.search(source) or CODEGEN_REFERENCE.search(source):
                usage.append(path.relative_to(repository_root).as_posix())
    forgekit_root = repository_root / pathlib.Path(FORGEKIT_ROOT)
    if forgekit_root.is_dir():
        usage.extend(
            path.relative_to(repository_root).as_posix()
            for path in sorted(forgekit_root.rglob("*.graphql"))
        )
    return sorted(set(usage))


def codegen_is_applicable(repository_root: pathlib.Path) -> bool:
    assets = (SCHEMA, CONFIG, GENERATOR)
    if any((repository_root / pathlib.Path(path)).exists() for path in assets):
        return True
    if (repository_root / pathlib.Path(GENERATED_ROOT)).exists():
        return True
    return bool(codegen_usage(repository_root))


def describe_drift(before: dict[str, str], after: dict[str, str]) -> list[str]:
    failures: list[str] = []
    before_paths = set(before)
    after_paths = set(after)
    for path in sorted(after_paths - before_paths):
        failures.append(f"generated GraphQL source was added by codegen: {path}")
    for path in sorted(before_paths - after_paths):
        failures.append(f"generated GraphQL source was removed by codegen: {path}")
    for path in sorted(before_paths & after_paths):
        if before[path] != after[path]:
            failures.append(f"generated GraphQL source changed after codegen: {path}")
    return failures


def codegen_drift_failures(repository_root: pathlib.Path) -> list[str]:
    usage = codegen_usage(repository_root)
    if not codegen_is_applicable(repository_root):
        return []

    failures = required_asset_failures(repository_root)
    if usage and failures:
        failures.append(
            "ForgeKit Apollo/GraphQL usage exists without complete codegen infrastructure: "
            + ", ".join(usage)
        )
    if failures:
        return failures

    before = generated_snapshot(repository_root)
    generator = repository_root / pathlib.Path(GENERATOR)
    environment = os.environ.copy()
    environment["GITX_FORGE_CODEGEN_OFFLINE"] = "1"
    try:
        result = subprocess.run(
            [str(generator), "--offline"],
            cwd=repository_root,
            env=environment,
            capture_output=True,
            text=True,
            check=False,
        )
    except OSError as error:
        return [f"could not execute offline ForgeKit codegen: {error}"]

    if result.returncode != 0:
        detail = result.stderr.strip() or result.stdout.strip()
        suffix = f": {detail}" if detail else ""
        return [
            f"offline ForgeKit codegen exited with status {result.returncode}{suffix}"
        ]

    return describe_drift(before, generated_snapshot(repository_root))


def main() -> int:
    if not (ROOT / pathlib.Path(FORGEKIT_ROOT)).exists():
        print("ForgeKit codegen-drift check skipped until the package is present.")
        return 0

    if not codegen_is_applicable(ROOT):
        print(
            "ForgeKit codegen-drift check passed: not applicable before the first "
            "Apollo/GraphQL operation."
        )
        return 0

    failures = codegen_drift_failures(ROOT)
    if failures:
        print("ForgeKit codegen-drift check failed:", file=sys.stderr)
        for failure in failures:
            print(f"- {failure}", file=sys.stderr)
        return 1

    print("ForgeKit offline codegen is reproducible and checked-in sources are current.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
