#!/usr/bin/env python3
"""Verify that a GitX app archive gives every embedded bundle a distinct identifier."""

from __future__ import annotations

import argparse
import collections
import pathlib
import plistlib
import sys
from typing import NamedTuple


EXPECTED_ROOT_IDENTIFIER = "net.phere.GitX"
BUNDLE_SUFFIXES = {".app", ".framework", ".xpc"}


class BundleMetadata(NamedTuple):
    relative_path: str
    identifier: str | None
    error: str | None = None


def bundle_paths(app_bundle: pathlib.Path) -> list[pathlib.Path]:
    app_bundle = app_bundle.resolve()
    if not app_bundle.is_dir() or app_bundle.suffix != ".app":
        raise ValueError(f"Expected an application bundle, got {app_bundle}")

    paths = [app_bundle]
    paths.extend(
        path
        for path in app_bundle.rglob("*")
        if path.is_dir() and path.suffix in BUNDLE_SUFFIXES
    )

    unique: dict[pathlib.Path, pathlib.Path] = {}
    for path in paths:
        unique.setdefault(path.resolve(), path)
    return sorted(unique.values(), key=lambda path: str(path.relative_to(app_bundle)))


def info_plist_path(bundle: pathlib.Path) -> pathlib.Path | None:
    candidates = (
        bundle / "Contents" / "Info.plist",
        bundle / "Resources" / "Info.plist",
        bundle / "Versions" / "Current" / "Resources" / "Info.plist",
        bundle / "Info.plist",
    )
    return next((path for path in candidates if path.is_file()), None)


def inspect_bundle_identifiers(app_bundle: pathlib.Path) -> list[BundleMetadata]:
    app_bundle = app_bundle.resolve()
    metadata: list[BundleMetadata] = []
    for bundle in bundle_paths(app_bundle):
        relative_path = "." if bundle == app_bundle else str(bundle.relative_to(app_bundle))
        plist_path = info_plist_path(bundle)
        if plist_path is None:
            metadata.append(BundleMetadata(relative_path, None, "Info.plist is missing"))
            continue

        try:
            with plist_path.open("rb") as plist_file:
                payload = plistlib.load(plist_file)
        except (OSError, plistlib.InvalidFileException) as error:
            metadata.append(
                BundleMetadata(relative_path, None, f"cannot read {plist_path.name}: {error}")
            )
            continue

        identifier = payload.get("CFBundleIdentifier")
        if not isinstance(identifier, str) or not identifier.strip():
            metadata.append(
                BundleMetadata(
                    relative_path,
                    None,
                    "CFBundleIdentifier is missing or empty",
                )
            )
            continue
        metadata.append(BundleMetadata(relative_path, identifier.strip()))
    return metadata


def evaluate_bundle_identifiers(
    metadata: list[BundleMetadata],
    *,
    expected_root_identifier: str = EXPECTED_ROOT_IDENTIFIER,
) -> list[str]:
    failures: list[str] = []
    by_path = {bundle.relative_path: bundle for bundle in metadata}
    root = by_path.get(".")
    if root is None:
        failures.append("The root application bundle was not inspected")
    elif root.identifier != expected_root_identifier:
        actual = root.identifier or "missing"
        failures.append(
            f"Root application identifier is {actual}; expected {expected_root_identifier}"
        )

    embedded = [bundle for bundle in metadata if bundle.relative_path != "."]
    if not embedded:
        failures.append("No embedded .app, .framework, or .xpc bundles were found")

    identifiers: collections.defaultdict[str, list[str]] = collections.defaultdict(list)
    for bundle in metadata:
        if bundle.error is not None:
            failures.append(f"{bundle.relative_path}: {bundle.error}")
        if bundle.identifier is None:
            if bundle.error is None:
                failures.append(f"{bundle.relative_path}: CFBundleIdentifier is missing or empty")
            continue

        identifiers[bundle.identifier].append(bundle.relative_path)
        if (
            bundle.relative_path != "."
            and bundle.identifier == expected_root_identifier
        ):
            failures.append(
                f"{bundle.relative_path}: embedded bundle reuses the root identifier "
                f"{expected_root_identifier}"
            )

    for identifier, paths in sorted(identifiers.items()):
        if len(paths) > 1:
            failures.append(
                f"Duplicate bundle identifier {identifier}: {', '.join(sorted(paths))}"
            )
    return failures


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app_bundle", type=pathlib.Path)
    parser.add_argument(
        "--expected-root-identifier",
        default=EXPECTED_ROOT_IDENTIFIER,
    )
    args = parser.parse_args()

    try:
        metadata = inspect_bundle_identifiers(args.app_bundle)
    except ValueError as error:
        print(error, file=sys.stderr)
        return 1

    for bundle in metadata:
        print(f"{bundle.identifier or 'missing'}\t{bundle.relative_path}")

    failures = evaluate_bundle_identifiers(
        metadata,
        expected_root_identifier=args.expected_root_identifier,
    )
    if failures:
        print("Bundle identifier verification failed:", file=sys.stderr)
        for failure in failures:
            print(f"- {failure}", file=sys.stderr)
        return 1

    print(f"Verified {len(metadata)} distinct bundle identifiers in {args.app_bundle}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
