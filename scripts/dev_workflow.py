#!/usr/bin/env python3
"""Coordinate authoritative local verification, work ownership and review evidence."""
from __future__ import annotations

import argparse
import json
import os
import pathlib
import sys
import uuid

import workflow_records as records
import workflow_session as session


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


def reusable(step, current, command, mutable_caches=None):
    if step.get("status") != "passed" or step.get("evidenceStatus") != "valid" or not session.command_matches(step, command):
        return False
    if session.changed_inputs(step.get("inputsAfter", {}), current):
        return False
    if step.get("toolchain") != session.cache_paths()["toolchain"]:
        return False
    receipt_path = step.get("receipt")
    if receipt_path:
        path = pathlib.Path(receipt_path)
        if not path.is_file():
            return False
        receipt = json.loads(path.read_text())
        evidence = receipt.get("evidence", {})
        if receipt.get("status") != "passed" or evidence.get("status") != "valid":
            return False
        if session.receipt_artifact_problems(receipt, session.ROOT, mutable_caches):
            return False
    if any(session.tree_identity(path) != identity for path, identity in step.get("outputs", {}).items()):
        return False
    return True


def verify(args):
    root = session.ROOT
    run_id = args.resume or args.run_id or "workflow-" + uuid.uuid4().hex[:12]
    if any(c not in "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-" for c in run_id):
        raise ValueError("Invalid run ID")
    directory = root / "artifacts/verification" / run_id
    path = directory / "workflow.json"
    if args.resume:
        if not path.is_file():
            raise ValueError("Resume requires a workflow receipt; historical receipts cannot be reused")
        payload = json.loads(path.read_text())
        if payload.get("schemaVersion") != 2:
            raise ValueError("Historical workflow receipts lack reuse evidence")
        payload["resumeHistory"] = payload.get("resumeHistory", []) + [{"resumedAt": records.now(), "previousInputs": payload.get("inputsBefore")}]
        payload["inputsBefore"] = session.inputs(root)
    else:
        if path.exists():
            raise ValueError("Run already exists; use --resume or a fresh run ID")
        payload = {"schemaVersion": 2, "runId": run_id, "startedAt": records.now(), "profile": args.profile,
                   "steps": [], "status": "running", "inputsBefore": session.inputs(root)}
    commands = full_profile(root)
    if args.check:
        commands = [(name, command) for name, command in commands if name in args.check]
        if len(commands) != len(set(args.check)):
            raise ValueError("Unknown check; use " + ", ".join(name for name, _ in full_profile(root)))
    payload["scope"] = "partial" if args.check else "full"
    payload["selectedChecks"] = [name for name, _ in commands]
    resources = []
    for name, command in commands:
        entry = pathlib.Path(command[0]).name
        if entry.endswith(".sh"):
            resources.extend(session.entry_resources(entry, command[1:], root)[0])
    owner = {"runId": run_id, "pid": os.getpid(), "receipt": str(path)}
    previous_caches = None
    if args.resume and payload.get("status") == "passed" and not session.final_cache_problems(payload, root):
        previous_caches = payload.get("finalCacheProducts", session.workflow_cache_snapshots(payload, root))
    with session.Leases(resources, owner) as leases:
        env = leases.environment() | {"GITX_SESSION_ID": run_id, "GITX_COMMAND_TIMEOUT": str(args.timeout)}
        payload["status"] = "running"
        session.atomic_json(path, payload)
        previous = {step["name"]: step for step in payload["steps"]}
        for name, command in commands:
            current = session.inputs(root)
            prior = previous.get(name)
            if args.resume and prior and reusable(prior, current, command, previous_caches):
                print(f"Reuse {name}: passed evidence and inputs still match.", flush=True)
                continue
            previous_caches = None
            print(f"Verify {name}; owning run {run_id}; receipt {path}", flush=True)
            attempt = uuid.uuid4().hex[:8]
            child_id = f"{run_id}-{name}-{attempt}"
            actual = command + (["--run-id", child_id] if pathlib.Path(command[0]).name == "xcodebuild.sh" else [])
            status = session.supervise(actual, timeout=args.timeout, directory=directory / "Diagnostics" / name,
                                       env=env, pass_fds=leases.descriptors())
            after = session.inputs(root)
            step = {"name": name, "command": command, "commandIdentity": session.command_identity(command), "status": "passed" if status == 0 else "failed", "exitCode": status,
                    "inputsBefore": current, "inputsAfter": after, "toolchain": session.cache_paths()["toolchain"], "finishedAt": records.now(),
                    "evidenceStatus": "invalid" if session.changed_inputs(current, after) else "valid", "outputs": {}}
            child_path = root / "artifacts/verification" / child_id / "receipt.json"
            if child_path.is_file():
                step["receipt"] = str(child_path)
                child_receipt = json.loads(child_path.read_text())
                if child_receipt.get("evidence", {}).get("status") != "valid":
                    step["evidenceStatus"] = "invalid"
            if name == "stage-debug" and status == 0:
                step["outputs"][str(root / "build/GitX.app")] = session.tree_identity(root / "build/GitX.app")
            payload["steps"] = [s for s in payload["steps"] if s["name"] != name] + [step]
            if step["evidenceStatus"] == "invalid" and status == 0:
                status = 76
            payload.update(status="failed" if status else "running", inputsAfter=after, updatedAt=records.now())
            session.atomic_json(path, payload)
            if status:
                print(f"Verification stopped at {name} (exit {status}). Receipt: {path}")
                return status
        payload.update(status="passed", finishedAt=records.now(), inputsAfter=session.inputs(root))
        if session.changed_inputs(payload["inputsBefore"], payload["inputsAfter"]):
            payload.update(status="invalid", evidenceStatus="invalid")
            session.atomic_json(path, payload)
            return 76
        payload["evidenceStatus"] = "valid"
        payload["deliveryEligible"] = not args.check
        payload["finalCacheProducts"] = session.workflow_cache_snapshots(payload, root)
        if session.final_cache_problems(payload, root):
            payload.update(status="invalid", evidenceStatus="invalid", deliveryEligible=False)
            session.atomic_json(path, payload)
            return 76
        session.atomic_json(path, payload)
        print(f"Local verification passed. Receipt: {path}")
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


def parser():
    result = argparse.ArgumentParser(description=__doc__)
    groups = result.add_subparsers(dest="group", required=True)
    verification = groups.add_parser("verify")
    verification.add_argument("--profile", choices=["full"], default="full")
    verification.add_argument("--resume")
    verification.add_argument("--run-id")
    verification.add_argument("--timeout", type=float, default=7200)
    verification.add_argument("--check", action="append", help="Run only a named check while iterating; not a full delivery profile")
    verification.set_defaults(handler=verify)
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
