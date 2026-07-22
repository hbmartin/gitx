#!/usr/bin/env python3
"""Enforce GitX's GitHub Actions trust and credential boundaries."""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path


PINNED_ACTION = re.compile(r"^[0-9a-f]{40}$")
USES_LINE = re.compile(r"^\s*-?\s*uses:\s*([^\s#]+)")


def _top_level_block(contents: str, key: str) -> list[str]:
    lines = contents.splitlines()
    start = next(
        (index for index, line in enumerate(lines) if line.rstrip() == f"{key}:"),
        None,
    )
    if start is None:
        return []

    block: list[str] = []
    for line in lines[start + 1 :]:
        if line and not line[0].isspace():
            break
        block.append(line)
    return block


def _job_blocks(contents: str) -> dict[str, list[str]]:
    jobs = _top_level_block(contents, "jobs")
    result: dict[str, list[str]] = {}
    current_name: str | None = None
    for line in jobs:
        match = re.match(r"^  ([A-Za-z0-9_-]+):\s*$", line)
        if match:
            current_name = match.group(1)
            result[current_name] = []
        elif current_name is not None:
            result[current_name].append(line)
    return result


def _has_pull_request_trigger(contents: str) -> bool:
    return any(
        re.match(r"^\s{2}pull_request(?:_target)?:", line)
        for line in _top_level_block(contents, "on")
    )


def _trusted_self_hosted_condition(job: list[str]) -> bool:
    condition = " ".join(
        line.strip()[3:].strip()
        for line in job
        if line.lstrip().startswith("if:")
    )
    if not condition or "pull_request" in condition:
        return False
    return "github.event_name == 'schedule'" in condition or (
        "github.event_name == 'workflow_dispatch'" in condition
    )


def _checkout_blocks(contents: str) -> list[list[str]]:
    lines = contents.splitlines()
    blocks: list[list[str]] = []
    for index, line in enumerate(lines):
        match = USES_LINE.match(line)
        if not match or not match.group(1).startswith("actions/checkout@"):
            continue
        indent = len(line) - len(line.lstrip())
        block = [line]
        for following in lines[index + 1 :]:
            following_indent = len(following) - len(following.lstrip())
            starts_next_step = following.lstrip().startswith("- ") and following_indent <= indent
            if following.strip() and (following_indent < indent or starts_next_step):
                break
            block.append(following)
        blocks.append(block)
    return blocks


def check_workflow(contents: str, display_path: str = "workflow") -> list[str]:
    failures: list[str] = []
    if not re.search(r"(?m)^permissions:\s*(?:\{\})?\s*$", contents):
        failures.append(f"{display_path}: missing explicit top-level permissions")

    pull_request_enabled = _has_pull_request_trigger(contents)
    if pull_request_enabled:
        for name, job in _job_blocks(contents).items():
            if any("self-hosted" in line for line in job) and not _trusted_self_hosted_condition(job):
                failures.append(
                    f"{display_path}: pull-request workflow job '{name}' uses an untrusted self-hosted runner"
                )

    for line in contents.splitlines():
        match = USES_LINE.match(line)
        if not match:
            continue
        action = match.group(1)
        if action.startswith("./") or action.startswith("docker://"):
            continue
        reference = action.rsplit("@", 1)[-1]
        if not PINNED_ACTION.fullmatch(reference):
            failures.append(f"{display_path}: action is not pinned to a full commit SHA: {action}")

    for block in _checkout_blocks(contents):
        if not any("persist-credentials: false" in line for line in block):
            failures.append(f"{display_path}: checkout persists Git credentials")

    return failures


def check_paths(paths: list[Path]) -> list[str]:
    failures: list[str] = []
    for path in paths:
        failures.extend(check_workflow(path.read_text(), str(path)))
    return failures


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("paths", nargs="+", type=Path)
    args = parser.parse_args()
    failures = check_paths(args.paths)
    if failures:
        print("\n".join(failures), file=sys.stderr)
        return 1
    print(f"Workflow security policy passed for {len(args.paths)} file(s).")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
