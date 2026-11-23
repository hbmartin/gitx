"""Validate the narrow exception that carries test evidence across evidence commits."""

from __future__ import annotations

import json
import math
import os
import pathlib
import plistlib
import re
import subprocess
import sys

import workflow_session as session


COVERAGE_POLICY = "scripts/coverage-baseline.json"
CARRIED_CHECKS = {"correctness", "core", "forgekit", "address-undefined", "thread-sanitizer", "ui", "performance", "analyze"}
EVIDENCE_PATH = re.compile(r"(?:CONTEXT\.md|docs/adr/\d{4}-[a-z0-9-]+\.md|docs/diagnostics/[a-zA-Z0-9._-]+\.json|scripts/coverage-baseline\.json)\Z")


def git(root, *args):
    process = subprocess.run(["git", "-C", str(root), *args], env=session.git_environment(),
                             capture_output=True, timeout=30, check=False)
    if process.returncode:
        raise ValueError(process.stderr.decode(errors="replace").strip() or "Cannot validate Git evidence lineage")
    return process.stdout


def validate_floors(old, new):
    def floor(value):
        if type(value) not in (float, int) or not math.isfinite(value) or not 0 <= value <= 1:
            raise ValueError("Coverage floors must be finite fractions")
        return value

    def monotone(previous, current):
        if floor(current) < floor(previous):
            raise ValueError("Coverage floors cannot be lowered")

    if set(old) - {"version", "target", "minimumLineCoverage", "files", "groups"} or set(new) - {
            "version", "target", "minimumLineCoverage", "files", "groups"}:
        raise ValueError("Unrecognized coverage policy fields")
    if old["version"] != 1 or new["version"] != 1 or old["target"] != new["target"]:
        raise ValueError("Coverage target or policy version changed")
    monotone(old["minimumLineCoverage"], new["minimumLineCoverage"])
    for name, value in old.get("files", {}).items():
        if name not in new.get("files", {}):
            raise ValueError("An existing coverage floor was removed")
        monotone(value, new["files"][name])
    for value in new.get("files", {}).values():
        floor(value)
    if old.get("groups", {}).keys() != new.get("groups", {}).keys():
        raise ValueError("Coverage groups changed")
    for name, previous in old.get("groups", {}).items():
        current = new["groups"][name]
        if set(current) != {"minimumLineCoverage", "files"} or previous["files"] != current["files"]:
            raise ValueError("Coverage group membership changed")
        monotone(previous["minimumLineCoverage"], current["minimumLineCoverage"])


def lineage(root, original, current):
    old, new = original["head"], current["head"]
    if original["root"] != str(root) or current["root"] != str(root) or not all(
        re.fullmatch(r"[0-9a-f]{40,64}", sha) for sha in (old, new)
    ) or old == new:
        raise ValueError("Reuse requires a descendant in the original checkout")
    if git(root, "diff", "HEAD", "--binary", "--ignore-submodules=none"):
        raise ValueError("Reuse requires a clean tracked checkout")
    tracked = set(os.fsdecode(path) for path in git(root, "ls-files", "-z").split(b"\0"))
    if set(current["files"]) - tracked:
        raise ValueError("Reuse cannot include untracked build inputs")
    if any(original[key] != current[key] for key in ("dependencies", "plans")):
        raise ValueError("Dependencies or test plans changed")
    commits = git(root, "rev-list", "--reverse", "--ancestry-path", old + ".." + new).decode().splitlines()
    changed = set()
    parent = old
    for commit in commits:
        parents = git(root, "rev-list", "--parents", "-n", "1", commit).decode().split()
        if parents != [commit, parent]:
            raise ValueError("Evidence commits must form a linear chain")
        fields = git(root, "diff-tree", "-r", "--raw", "--no-commit-id", "--no-renames", "-z", parent, commit).split(b"\0")
        for header, raw in zip(fields[0:-1:2], fields[1:-1:2], strict=True):
            name = os.fsdecode(raw)
            old_mode, new_mode, _, _, change = header.decode("ascii")[1:].split()
            if not EVIDENCE_PATH.fullmatch(name) or new_mode != "100644" or not (
                    (change == "A" and old_mode == "000000") or (change == "M" and old_mode == new_mode)):
                raise ValueError("Change requires fresh verification: " + name)
            if name == COVERAGE_POLICY:
                validate_floors(json.loads(git(root, "show", parent + ":" + name)),
                                json.loads(git(root, "show", commit + ":" + name)))
            elif name.endswith(".json"):
                json.loads(git(root, "show", commit + ":" + name))
            changed.add(name)
        parent = commit
    if parent != new or not changed:
        raise ValueError("No admissible evidence-only ancestry")
    before, after = original["files"], current["files"]
    if any(before.get(name) != after.get(name) for name in (before.keys() | after.keys()) - changed):
        raise ValueError("Files outside the approved evidence diff changed")
    for name in changed:
        for inputs, sha in ((before, old), (after, new)):
            identity = inputs.get(name)
            if identity is None:
                if sha == new or git(root, "ls-tree", "-z", sha, "--", name):
                    raise ValueError("Evidence input identity is missing: " + name)
                continue
            if identity.get("sha256") != session.digest(git(root, "show", sha + ":" + name)) or identity.get("mode") != 0o644:
                raise ValueError("Evidence did not execute on the recorded commit: " + name)
    return sorted(changed)


def read_source(root, path, current):
    artifact_root = session.verification_artifact_root(root).resolve()
    path = pathlib.Path(path)
    if path.name != "workflow.json" or not path.resolve().is_relative_to(artifact_root) or path.is_symlink():
        raise ValueError("Evidence must come from a local workflow receipt")
    receipt = json.loads(path.read_text())
    if (receipt.get("schemaVersion") != 2 or receipt.get("status") != "passed" or receipt.get("profile") != "full"
            or receipt.get("scope") != "full" or receipt.get("evidenceStatus") != "valid" or not receipt.get("deliveryEligible")
            or receipt.get("evidenceReuse") or session.changed_inputs(receipt["inputsBefore"], receipt["inputsAfter"])):
        raise ValueError("Evidence reuse requires an original passing full workflow")
    paths = lineage(root, receipt["inputsAfter"], current)
    return receipt, paths


def correctness_result(root, step):
    child = json.loads(pathlib.Path(step["receipt"]).read_text())
    runs = [item for item in child["steps"] if item["name"] == "test:correctness"]
    invocation = child["invocation"]
    if (child["status"] != "passed" or invocation.get("configuration") != "Debug"
            or invocation.get("coverageGate") != "enforced" or len(runs) != 1
            or any(arg.startswith(("-only-testing", "-skip-testing")) for arg in invocation.get("arguments", ()))
            or not runs[0].get("testCounts", {}).get("total") or runs[0].get("status") != "passed"):
        raise ValueError("Complete Debug correctness evidence is required")
    result = root / runs[0]["xcresult"]
    if not result.resolve().is_relative_to(session.verification_artifact_root(root).resolve()):
        raise ValueError("Correctness result is outside the checkout evidence")
    return result


def prepare(root, original_path, current, output, commands, toolchain, caches):
    original, paths = read_source(root, original_path, current)
    source_inputs = original["inputsAfter"]
    steps = {step["name"]: step for step in session.active_workflow_steps(original, require_selected_checks=True)}
    if set(steps) != set(commands) or caches is None:
        raise ValueError("Original workflow is incomplete or its cache products changed")
    carried = []
    for name in sorted(CARRIED_CHECKS):
        step = steps[name]
        child_path = pathlib.Path(step["receipt"])
        if not child_path.resolve().is_relative_to(session.verification_artifact_root(root).resolve()):
            raise ValueError("Reused child receipt is outside the checkout evidence")
        child = json.loads(child_path.read_text())
        evidence = child["evidence"]
        if (not session.command_matches(step, commands[name]) or step["toolchain"] != toolchain
                or step["status"] != "passed" or step["evidenceStatus"] != "valid"
                or child["status"] != "passed" or evidence["status"] != "valid"
                or any(session.changed_inputs(snapshot, source_inputs) for snapshot in
                       (step["inputsBefore"], step["inputsAfter"], evidence["inputsBefore"], evidence["inputsAfter"]))
                or session.receipt_artifact_problems(child, root, caches)):
            raise ValueError("Cannot carry verification evidence for " + name)
        carried.append({**step, "reusedFrom": str(original_path), "receiptIdentity": session.file_identity(child_path),
                        "lastAttempt": {"action": "reused", "reason": "evidence-only-descendant"}})
    result = correctness_result(root, steps["correctness"])
    log = output / "coverage-recheck.log"
    log.parent.mkdir(parents=True, exist_ok=True)
    with log.open("x") as stream:
        subprocess.run([sys.executable, str(root / "scripts/check_coverage.py"), str(result)],
                       cwd=root, stdout=stream, stderr=subprocess.STDOUT, check=True)
    return carried, {"sourceReceipt": str(original_path), "sourceReceiptIdentity": session.file_identity(original_path),
                     "sourceHead": source_inputs["head"], "head": current["head"], "paths": paths,
                     "baseline": session.file_identity(root / COVERAGE_POLICY), "coverageResult": str(result),
                     "coverageLog": str(log), "coverageLogIdentity": session.file_identity(log)}


def validation_inputs(root, workflow, current):
    """Return source inputs only when this current workflow binds them to immutable evidence."""
    relation = workflow.get("evidenceReuse")
    if not relation:
        return {}
    path = pathlib.Path(relation["sourceReceipt"])
    original, paths = read_source(root, path, current)
    if (relation["sourceReceiptIdentity"] != session.file_identity(path) or relation["head"] != current["head"]
            or relation["sourceHead"] != original["inputsAfter"]["head"] or relation["paths"] != paths
            or relation["baseline"] != session.file_identity(root / COVERAGE_POLICY)
            or relation["coverageLogIdentity"] is None or relation["coverageLogIdentity"] != session.file_identity(relation["coverageLog"])):
        raise ValueError("Cross-commit verification evidence changed")
    source_steps = {step["name"]: step for step in session.active_workflow_steps(original, require_selected_checks=True)}
    inputs = original["inputsAfter"]
    eligible = {}
    for step in session.active_workflow_steps(workflow):
        name = step["name"]
        if not step.get("reusedFrom"):
            continue
        if name not in CARRIED_CHECKS or step["reusedFrom"] != str(path) or step["receipt"] != source_steps[name]["receipt"] or (
                step["receiptIdentity"] is None or step["receiptIdentity"] != session.file_identity(step["receipt"])):
            raise ValueError("Workflow step does not bind to the original receipt: " + name)
        eligible[name] = inputs
    if "correctness" not in eligible or relation["coverageResult"] != str(correctness_result(root, source_steps["correctness"])):
        raise ValueError("Coverage recheck does not bind the carried correctness result")
    return eligible


def verify_staged_version(root, head):
    """Evidence from a previous commit cannot authorize a bundle stamped for it."""
    if git(root, "rev-parse", "HEAD").decode().strip() != head:
        raise ValueError("The stage candidate changed")
    description = git(root, "describe", "--tags", "--always", "--dirty=-dirty").decode().strip()
    branch = git(root, "rev-parse", "--abbrev-ref", "HEAD").decode().strip()
    count = git(root, "rev-list", "--count", "HEAD").decode().strip()
    info = plistlib.loads((root / "build/GitX.app/Contents/Info.plist").read_bytes())
    if (info.get("CFBundleBuildVersion") != f"{description}-{branch}"
            or not re.search(r"\." + re.escape(count) + r" \[.+\]$", info.get("CFBundleVersion", ""))):
        raise ValueError("Staged Debug app version does not match the current commit")
