#!/usr/bin/env python3
"""Coordinate authoritative local verification, work ownership and review evidence."""
from __future__ import annotations

import argparse
import contextlib
import json
import math
import os
import pathlib
import sys
import time
import uuid

# A preview must not populate Python bytecode caches in the checkout either.
if sys.argv[1:3] == ["cleanup", "preview"] or "--dry-run" in sys.argv:
    sys.dont_write_bytecode = True

import workflow_records as records
import workflow_session as session
import workflow_cleanup as cleanup
import workflow_feedback as feedback


def full_profile(root):
    scripts = pathlib.Path(root) / "scripts"
    xcode = str(scripts / "xcodebuild.sh")
    return [("static", [str(scripts / "verify_static.sh")]),
            ("interop", [sys.executable, str(scripts / "check_test_build_contracts.py")]),
            ("debug-test-build", [xcode, "--configuration", "Debug", "build-tests"]),
            ("release-test-build", [xcode, "--configuration", "Release", "build-tests"]),
            ("release-contracts", [xcode, "--configuration", "Release", "test", "correctness", "-only-testing:GitXTests/GitXInteropContractTests"]),
            *[(name, [xcode, "test", name]) for name in ("correctness", "core", "forgekit", "address-undefined", "thread-sanitizer", "ui")],
            ("performance", [xcode, "--configuration", "Release", "test", "performance"]),
            ("analyze", [xcode, "analyze"]),
            ("stage-debug", [xcode, "--configuration", "Debug", "--stage-app", "build"])]


def read_child_receipt(path):
    value = json.loads(pathlib.Path(path).read_text())
    if not isinstance(value, dict) or any(not isinstance(value.get(key, {}), dict) for key in ("evidence", "buildPaths", "invocation")) or \
            not isinstance(value.get("steps", []), list) or any(not isinstance(step, dict) for step in value.get("steps", [])):
        raise ValueError("Malformed child receipt: " + str(path))
    evidence = value.get("evidence", {})
    if any(not isinstance(evidence.get(key, {}), dict) for key in ("results", "analysisArtifacts", "inputsAfter")):
        raise ValueError("Malformed child evidence: " + str(path))
    return value


def reuse_problem(step, current, command, mutable_caches=None, toolchain=None):
    if step.get("status") != "passed" or step.get("evidenceStatus") != "valid":
        return "prior-check-or-evidence-not-passed"
    if not session.command_matches(step, command):
        return "command-changed"
    if session.changed_inputs(step.get("inputsAfter", {}), current):
        return "inputs-changed:" + ",".join(session.changed_inputs(step.get("inputsAfter", {}), current))
    if step.get("toolchain") != (toolchain if toolchain is not None else session.cache_paths()["toolchain"]):
        return "toolchain-changed"
    receipt_path = step.get("receipt")
    if receipt_path:
        path = pathlib.Path(receipt_path)
        if not path.is_file():
            return "receipt-missing"
        try:
            receipt = read_child_receipt(path)
        except (OSError, ValueError):
            return "receipt-unreadable"
        evidence = receipt.get("evidence", {})
        if receipt.get("status") != "passed" or evidence.get("status") != "valid":
            return "child-check-or-evidence-not-passed"
        try:
            problems = session.receipt_artifact_problems(receipt, session.ROOT, mutable_caches)
        except (OSError, ValueError, TypeError, KeyError) as error:
            return "artifacts-unreadable:" + str(error)
        if problems:
            return "artifacts-changed:" + "; ".join(problems)
    try:
        if any(session.tree_identity(path) != identity for path, identity in step.get("outputs", {}).items()):
            return "workflow-output-changed"
    except (OSError, ValueError, TypeError) as error:
        return "workflow-output-unreadable:" + str(error)
    return None


def reusable(step, current, command, mutable_caches=None):
    return reuse_problem(step, current, command, mutable_caches) is None


def selected_commands(args, root):
    commands = full_profile(root)
    selection = {"profile": args.profile, "deliveryEligible": args.profile == "full" and not args.check}
    if args.profile == "feedback":
        base, paths = feedback.changed_paths(root, getattr(args, "base_ref", None))
        names, reasons = feedback.select_checks(paths, [name for name, _ in commands])
        full_selection = names == [name for name, _ in commands]
        selection.update(base=base, changedPaths=paths, reasons=reasons)
        commands = [(name, command) for name, command in commands if name in names]
        commands = [(name, ([command[0], base] if full_selection else
                            [str(root / "scripts/verify_static.sh"), "--feedback", "--base-ref", base]) if name == "static" else command)
                    for name, command in commands]
        if "whitespace" in names:
            commands.append(("whitespace", [sys.executable, str(root / "scripts/workflow_feedback.py"), "whitespace", "--base-ref", base]))
    if args.check:
        available = dict(full_profile(root))
        if any(name not in available for name in args.check):
            raise ValueError("Unknown check; use " + ", ".join(available))
        commands = [(name, command) for name, command in full_profile(root) if name in args.check]
        selection.update(manualChecks=list(args.check), deliveryEligible=False)
    selectors = getattr(args, "only_testing", None)
    if selectors and selection["deliveryEligible"]:
        raise ValueError("Focused tests require --profile feedback or an explicit partial --check")
    commands = feedback.focus_commands(commands, selectors)
    selection.update(selectedChecks=[name for name, _ in commands], testSelectors=selectors or [])
    return commands, selection


def resources_for(commands, directory, root, details=None):
    resources = [str(directory)]
    toolchain = None
    for _, command in commands:
        entry = pathlib.Path(command[0]).name
        arguments = command[1:]
        if entry == "verify_static.sh":
            continue
        if entry.endswith(".sh") or (len(command) > 1 and pathlib.Path(command[1]).name == "check_test_build_contracts.py"):
            if not entry.endswith(".sh"):
                entry, arguments = pathlib.Path(command[1]).name, command[2:]
            values, paths = session.entry_resources(entry, arguments, root, toolchain=toolchain)
            toolchain = paths.get("toolchain", toolchain)
            resources.extend(value for value in values if not value.startswith("desktop:"))
    if details is not None:
        details["toolchain"] = toolchain or "not-required"
    return resources


@contextlib.contextmanager
def selected_leases(args, root, directory, owner):
    wait = getattr(args, "wait_for_resources", 0)
    if not math.isfinite(wait) or wait < 0:
        raise ValueError("Resource wait must be finite and nonnegative")
    deadline = time.monotonic() + wait
    while True:
        commands, selection = selected_commands(args, root)
        details = {}
        resources = resources_for(commands, directory, root, details)
        with session.Leases(resources, owner, wait_seconds=max(0, deadline - time.monotonic())) as leases:
            refreshed, refreshed_selection = selected_commands(args, root)
            refreshed_details = {}
            if set(resources_for(refreshed, directory, root, refreshed_details)) != set(resources) or details != refreshed_details:
                if time.monotonic() >= deadline:
                    raise session.ResourceDefinitionError("Inputs kept changing while waiting; retry with a stable snapshot",
                                                          "resource-definition-changed")
            else:
                refreshed_selection.update(refreshed_details)
                yield leases, refreshed, refreshed_selection
                return
        time.sleep(min(.2, max(0, deadline - time.monotonic())))


def previous_cache_snapshots(payload, root):
    children = {}
    for step in session.active_workflow_steps(payload):
        if step.get("receipt"):
            path = pathlib.Path(step["receipt"])
            path = path if path.is_absolute() else root / path
            try:
                children[path] = read_child_receipt(path)
            except (OSError, ValueError, TypeError):
                # An unavailable prior child rejects reuse. Its selected check
                # can still recover by executing with fresh evidence.
                return None
    derived = session.workflow_cache_snapshots(payload, root, receipt_reader=children.__getitem__)
    return derived if not session.final_cache_problems(payload, root, derived=derived) else None


def finish_invalid(path, payload, problems, attempt_started):
    for key in ("category", "problem", "owner", "resource"):
        payload.pop(key, None)
    payload.update(status="invalid", evidenceStatus="invalid", deliveryEligible=False, exitCode=76,
                   evidenceProblems=problems, finishedAt=records.now(),
                   attemptDurationSeconds=round(time.monotonic() - attempt_started, 3))
    session.atomic_json(path, payload)
    print(f"Verification evidence is invalid. Receipt: {path}", file=sys.stderr)
    return 76


def verify(args):
    root = session.ROOT
    commands, selection = selected_commands(args, root)
    if getattr(args, "dry_run", False):
        print(json.dumps(selection, indent=2, sort_keys=True))
        return 0
    attempt_started = time.monotonic()
    run_id = args.resume if args.resume is not None else args.run_id if args.run_id is not None else "workflow-" + uuid.uuid4().hex[:12]
    if not session.valid_run_id(run_id):
        raise ValueError("Invalid run ID")
    directory = session.verification_artifact_root(root) / run_id
    path = directory / "workflow.json"
    if args.resume:
        if not path.is_file():
            raise ValueError("Resume requires a workflow receipt; historical receipts cannot be reused")
        payload = json.loads(path.read_text())
        if payload.get("schemaVersion") != 2:
            raise ValueError("Historical workflow receipts lack reuse evidence")
    else:
        if path.exists():
            raise ValueError("Run already exists; use --resume or a fresh run ID")
        payload = {"schemaVersion": 2, "runId": run_id, "startedAt": records.now(), "profile": args.profile,
                   "steps": [], "status": "running", "inputsBefore": session.inputs(root)}
    owner = {"runId": run_id, "pid": os.getpid(), "receipt": str(path), "producer": session.producer_identity()}
    previous_caches = None
    owned_directory = False
    try:
        with selected_leases(args, root, directory, owner) as (leases, commands, selection):
            owned_directory = True
            if args.resume:
                # A previous producer may have finished while this attempt
                # waited. Read and mutate its receipt only after ownership.
                payload = json.loads(path.read_text())
                if payload.get("schemaVersion") != 2:
                    raise ValueError("Historical workflow receipts lack reuse evidence")
                previous_payload = dict(payload)
                payload["resumeHistory"] = payload.get("resumeHistory", []) + [{"resumedAt": records.now(), "previousInputs": payload.get("inputsBefore")}]
            elif path.exists():
                raise ValueError("Run already exists; use --resume or a fresh run ID")
            env = leases.environment() | {"GITX_SESSION_ID": run_id, "GITX_COMMAND_TIMEOUT": str(args.timeout),
                                          "GITX_RESOURCE_WAIT_SECONDS": str(getattr(args, "wait_for_resources", 0))}
            for key in ("category", "problem", "owner", "resource", "exitCode", "finishedAt", "evidenceProblems"):
                payload.pop(key, None)
            payload.update(status="running", deliveryEligible=False, profile=args.profile, producer=owner["producer"], resources=sorted(leases.held),
                           scope="full" if selection["deliveryEligible"] else "partial", selection=selection,
                           selectedChecks=selection["selectedChecks"], inputsBefore=session.inputs(root),
                           resourceWaitSeconds=round(leases.wait_seconds, 3), executedChecks=[], reusedChecks=[])
            session.atomic_json(path, payload)
            if args.resume and previous_payload.get("status") == "passed":
                try:
                    previous_caches = previous_cache_snapshots(previous_payload, root)
                except (OSError, ValueError, TypeError, KeyError) as error:
                    payload["finalCacheProducts"] = {}
                    return finish_invalid(path, payload, ["Prior cache ownership cannot be validated: " + str(error)], attempt_started)
            previous = {step["name"]: step for step in payload["steps"]}
            for name, command in commands:
                current = session.inputs(root)
                prior = previous.get(name)
                reason = "no-prior-evidence" if prior is None else reuse_problem(prior, current, command, previous_caches, selection["toolchain"])
                if args.resume and prior and reason is None:
                    print(f"Reuse {name}: passed evidence and inputs still match.", flush=True)
                    payload["reusedChecks"].append(name)
                    prior["lastAttempt"] = {"action": "reused", "reason": "matching-passed-evidence"}
                    continue
                previous_caches = None
                print(f"Verify {name}; owning run {run_id}; receipt {path}", flush=True)
                attempt = uuid.uuid4().hex[:8]
                child_id = f"{run_id}-{name}-{attempt}"
                actual = command + (["--run-id", child_id] if pathlib.Path(command[0]).name == "xcodebuild.sh" else [])
                if args.resume and name == "analyze" and prior and prior.get("receipt"):
                    prior_receipt = pathlib.Path(prior["receipt"])
                    try:
                        evidence = read_child_receipt(prior_receipt)
                        inner = evidence.get("evidence", {})
                        if session.valid_run_id(evidence.get("runId")) and inner.get("status") == "valid" and isinstance(inner.get("analyzerScratch"), dict) and inner["analyzerScratch"].get("path") and isinstance(inner.get("inputsAfter"), dict) and not session.changed_inputs(inner["inputsAfter"], current) and \
                                any(step.get("name") == "analyze" and step.get("status") == "passed" for step in evidence.get("steps", [])):
                            actual += ["--resume-analysis", evidence["runId"], "--fresh-on-stale-analysis"]
                        else:
                            reason = "analyzer-recovery-unavailable"
                    except (OSError, ValueError, TypeError):
                        reason = "analyzer-recovery-receipt-unreadable"
                step_started = time.monotonic()
                status = session.supervise(actual, timeout=args.timeout, directory=directory / "Diagnostics" / name,
                                           env=env | {"GITX_SESSION_ID": child_id}, pass_fds=leases.descriptors())
                after = session.inputs(root)
                step = {"name": name, "command": command, "commandIdentity": session.command_identity(command), "status": "passed" if status == 0 else "failed", "exitCode": status,
                        "inputsBefore": current, "inputsAfter": after, "toolchain": selection["toolchain"], "finishedAt": records.now(),
                        "evidenceStatus": "invalid" if session.changed_inputs(current, after) else "valid", "outputs": {},
                        "durationSeconds": round(time.monotonic() - step_started, 3),
                        "executionReason": reason or "requested-fresh-check",
                        "lastAttempt": {"action": "executed", "reason": reason or "requested-fresh-check"}}
                payload["executedChecks"].append(name)
                child_path = session.verification_artifact_root(root) / child_id / "receipt.json"
                if not child_path.is_file():
                    child_path = session.verification_artifact_root(root) / "Coordination" / (child_id + ".json")
                if child_path.is_file():
                    step["receipt"] = str(child_path)
                    try:
                        child_receipt = read_child_receipt(child_path)
                    except (OSError, ValueError):
                        child_receipt = {}
                    if child_receipt.get("evidence", {}).get("status") != "valid":
                        step["evidenceStatus"] = "invalid"
                if name == "stage-debug" and status == 0:
                    try:
                        step["outputs"][str(root / "build/GitX.app")] = session.tree_identity(root / "build/GitX.app")
                    except (OSError, ValueError, TypeError) as error:
                        step["outputs"][str(root / "build/GitX.app")] = None
                        step["evidenceStatus"] = "invalid"
                        step["evidenceProblems"] = ["Workflow output cannot be captured: " + str(error)]
                payload["steps"] = [s for s in payload["steps"] if s["name"] != name] + [step]
                if step["evidenceStatus"] == "invalid" and status == 0:
                    status = 76
                payload.update(status="failed" if status else "running", inputsAfter=after, updatedAt=records.now())
                session.atomic_json(path, payload)
                if status:
                    if status == 76 and step["evidenceStatus"] == "invalid":
                        return finish_invalid(path, payload, step.get("evidenceProblems", ["Check evidence is invalid: " + name]), attempt_started)
                    payload["attemptDurationSeconds"] = round(time.monotonic() - attempt_started, 3)
                    session.atomic_json(path, payload)
                    print(f"Verification stopped at {name} (exit {status}). Receipt: {path}")
                    return status
            payload.update(status="passed", finishedAt=records.now(), inputsAfter=session.inputs(root))
            if session.changed_inputs(payload["inputsBefore"], payload["inputsAfter"]):
                return finish_invalid(path, payload, ["Verification inputs changed during the attempt"], attempt_started)
            payload["evidenceStatus"] = "valid"
            payload["deliveryEligible"] = selection["deliveryEligible"]
            try:
                payload["finalCacheProducts"] = session.workflow_cache_snapshots(payload, root)
                problems = session.final_cache_problems(payload, root, derived=payload["finalCacheProducts"])
            except (OSError, ValueError, TypeError, KeyError) as error:
                payload["finalCacheProducts"] = {}
                problems = ["Final cache ownership cannot be validated: " + str(error)]
            for step in session.active_workflow_steps(payload):
                if step.get("receipt"):
                    try:
                        child = read_child_receipt(step["receipt"])
                        problems.extend(session.receipt_artifact_problems(child, root, payload["finalCacheProducts"]))
                    except (OSError, ValueError, TypeError, KeyError) as error:
                        problems.append("Child receipt cannot be validated: " + str(error))
                for output, identity in step.get("outputs", {}).items():
                    try:
                        if identity is None or session.tree_identity(output) != identity:
                            problems.append("Workflow output missing or changed: " + output)
                    except (OSError, ValueError, TypeError) as error:
                        problems.append("Workflow output cannot be validated: " + output + ": " + str(error))
            if problems:
                return finish_invalid(path, payload, problems, attempt_started)
            session.atomic_json(path, payload)
            payload["attemptDurationSeconds"] = round(time.monotonic() - attempt_started, 3)
            session.atomic_json(path, payload)
            print(f"Checks: {len(payload['executedChecks'])} executed, {len(payload['reusedChecks'])} reused; "
                  f"{payload['attemptDurationSeconds']:.1f}s; delivery eligible: {payload['deliveryEligible']}")
            print(f"Local verification passed. Receipt: {path}")
    except (session.ResourceBusy, session.ResourceDefinitionError) as error:
        busy = isinstance(error, session.ResourceBusy)
        status = 75 if busy else 2
        if not owned_directory and (args.resume or path.exists() or
                (busy and session.canonical_resource(error.resource) == session.canonical_resource(str(directory)))):
            blocker = session.verification_artifact_root(root) / "Coordination" / f"{run_id}-{uuid.uuid4().hex[:8]}.json"
            blocked = owner | {"schemaVersion": 2, "receipt": str(blocker), "entry": str(root / "scripts/dev_workflow.py"),
                "workflowReceipt": str(path), "status": "blocked", "exitCode": status,
                "category": "resource-busy" if busy else error.category, "problem": str(error),
                "selectedChecks": selection["selectedChecks"], "resources": [], "deliveryEligible": False,
                "startedAt": records.now(), "finishedAt": records.now(),
                "attemptDurationSeconds": round(time.monotonic() - attempt_started, 3)}
            if busy:
                blocked.update(owner=error.owner, resource=error.resource)
            session.atomic_json(blocker, blocked)
            print(f"{error}\nBlocker receipt: {blocker}", file=sys.stderr)
            return status
        payload.update(status="blocked", exitCode=status, category="resource-busy" if busy else error.category,
                       problem=str(error), producer=owner["producer"], deliveryEligible=False,
                       finishedAt=records.now(), attemptDurationSeconds=round(time.monotonic() - attempt_started, 3))
        if busy:
            payload.update(owner=error.owner, resource=error.resource)
        session.atomic_json(path, payload)
        print(error, file=sys.stderr)
        return status
    if payload["deliveryEligible"]:
        try:
            report = cleanup.preview(root) if args.cleanup_mode == "preview" else cleanup.run_cleanup(root, path)
            print(f"Cleanup: {report['status']}; reclaimed {report.get('reclaimedBytes', 0)} bytes.", flush=True)
            if report["status"] == "partial":
                print(f"Cleanup warning: some candidates were skipped or failed; cleanup stays pending. Report: {report.get('report')}", file=sys.stderr)
        except Exception as error:
            # Cleanup is maintenance after immutable verification has passed.
            # Unexpected cleanup failures must not misreport a test failure.
            print(f"Cleanup warning: {error}; verification remains passed; cleanup stays pending.", file=sys.stderr)
    return 0

def work(args):
    with records.Ledger() as ledger:
        if args.action == "inventory":
            result = ledger.inventory()
            session.atomic_json(args.output, result)
        elif args.action == "register":
            result = ledger.register(args.id, args.purpose, args.owner, args.chat, args.branch, args.worktree, args.base)
        elif args.action == "update":
            result = ledger.update(args.id, json.loads(args.changes.read_text()), args.owner)
        elif args.action == "seed":
            ledger.seed(args.manifest)
            result = ledger.inventory()
        elif args.action == "export":
            result = ledger.export(args.output)
        elif args.action == "import":
            ledger.import_export(args.source)
            result = {"status": "imported", "ledger": str(ledger.path)}
        print(json.dumps(result, indent=2, sort_keys=True))
    return 0


def review(args):
    path = args.output if args.action == "prepare" else args.record
    owner = {"runId": "review", "pid": os.getpid(), "receipt": str(path)}
    with session.Leases([str(path)], owner):
        if args.action == "prepare":
            result = records.prepare_review(session.ROOT, args.source, args.output, args.target, args.pasted)
        else:
            decisions = json.loads(args.decisions.read_text()) if args.decisions else None
            result = records.reconcile_review(session.ROOT, args.record, decisions, args.refresh)
    print(json.dumps(result, indent=2, sort_keys=True))
    return 3 if result["status"] == "needs-target" else 0


def clean(args):
    if args.action == "install-hook":
        result = cleanup.install_hook(session.ROOT)
    elif args.action == "queue":
        result = cleanup.queue_commit(session.ROOT)
    elif args.action == "preview":
        result = cleanup.preview(session.ROOT)
    else:
        result = cleanup.run_cleanup(session.ROOT, args.receipt)
    print(json.dumps(result, indent=2, sort_keys=True))
    return 2 if result.get("status") == "partial" else 0


def parser():
    result = argparse.ArgumentParser(description=__doc__)
    groups = result.add_subparsers(dest="group", required=True)
    verification = groups.add_parser("verify")
    verification.add_argument("--profile", choices=["full", "feedback"], default="full")
    verification.add_argument("--base-ref")
    verification.add_argument("--only-testing", action="append")
    verification.add_argument("--dry-run", action="store_true")
    verification.add_argument("--wait-for-resources", type=float, default=0)
    verification.add_argument("--resume")
    verification.add_argument("--run-id")
    verification.add_argument("--timeout", type=float, default=7200)
    verification.add_argument("--cleanup-mode", choices=["auto", "preview"], default="auto")
    verification.add_argument("--check", action="append", help="Run only a named check while iterating; not a full delivery profile")
    verification.set_defaults(handler=verify)
    cleaning = groups.add_parser("cleanup", help="Commit-triggered retention of verification output")
    actions = cleaning.add_subparsers(dest="action", required=True)
    actions.add_parser("install-hook")
    actions.add_parser("queue", help=argparse.SUPPRESS)
    actions.add_parser("preview", help="Read-only inventory and retention proposal")
    prune = actions.add_parser("run", help="Prune only after valid full post-commit verification")
    prune.add_argument("--receipt", required=True, type=pathlib.Path)
    cleaning.set_defaults(handler=clean)
    working = groups.add_parser("work")
    actions = working.add_subparsers(dest="action", required=True)
    inventory = actions.add_parser("inventory")
    inventory.add_argument("--output", type=pathlib.Path, default=session.ROOT / "artifacts/verification/work-inventory.json")
    register = actions.add_parser("register")
    register.add_argument("id")
    register.add_argument("--purpose", required=True)
    for flag in ("owner", "chat", "branch", "base"):
        register.add_argument("--" + flag)
    register.add_argument("--worktree", type=pathlib.Path)
    update = actions.add_parser("update")
    update.add_argument("id")
    update.add_argument("--changes", type=pathlib.Path, required=True)
    update.add_argument("--owner")
    seed = actions.add_parser("seed")
    seed.add_argument("manifest", type=pathlib.Path)
    export = actions.add_parser("export")
    export.add_argument("--output", type=pathlib.Path, required=True)
    imported = actions.add_parser("import")
    imported.add_argument("source", type=pathlib.Path)
    working.set_defaults(handler=work)
    reviewing = groups.add_parser("review")
    actions = reviewing.add_subparsers(dest="action", required=True)
    preparation = actions.add_parser("prepare")
    preparation.add_argument("source", type=pathlib.Path)
    preparation.add_argument("--output", type=pathlib.Path, required=True)
    preparation.add_argument("--target")
    preparation.add_argument("--pasted", action="store_true")
    reconciliation = actions.add_parser("reconcile")
    reconciliation.add_argument("record", type=pathlib.Path)
    reconciliation.add_argument("--decisions", type=pathlib.Path)
    reconciliation.add_argument("--refresh", action="store_true")
    reviewing.set_defaults(handler=review)
    return result


def main(argv=None):
    args = parser().parse_args(argv)
    try:
        return args.handler(args)
    except session.ResourceBusy as error:
        print(error, file=sys.stderr)
        return 75
    except (OSError, ValueError, KeyError) as error:
        print(error, file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
