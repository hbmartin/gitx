#!/usr/bin/env python3
"""Coordinate authoritative local verification, work ownership and review evidence."""
from __future__ import annotations

import argparse
import contextlib
import json
import math
import os
import pathlib
import signal
import subprocess
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
import workflow_evidence_reuse as evidence_reuse


def full_profile(root):
    scripts = pathlib.Path(root) / "scripts"
    xcode = str(scripts / "xcodebuild.sh")
    return [("static", [str(scripts / "verify_static.sh")]),
            ("interop", [sys.executable, str(scripts / "check_test_build_contracts.py")]),
            ("debug-test-build", [xcode, "--configuration", "Debug", "build-tests"]),
            ("release-test-build", [xcode, "--configuration", "Release", "build-tests"]),
            ("fixture-stability", [sys.executable, str(scripts / "check_fixture_stability.py")]),
            ("release-contracts", [xcode, "--configuration", "Release", "test", "correctness", "-only-testing:GitXTests/GitXInteropContractTests"]),
            *[(name, [xcode, "test", name]) for name in ("correctness", "core", "forgekit", "address-undefined", "thread-sanitizer", "ui")],
            ("performance", [xcode, "--configuration", "Release", "test", "performance"]),
            ("analyze", [xcode, "analyze"]),
            ("version-contract", [xcode, "test", "version-contract"]),
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
    if not receipt_path and pathlib.Path(command[0]).name == "xcodebuild.sh":
        return "receipt-missing"
    if receipt_path:
        try:
            path = session.workflow_receipt_path(session.ROOT, receipt_path)
            if not path.is_file():
                return "receipt-missing"
            receipt = read_child_receipt(path)
            session.validate_evidence_paths(session.ROOT, path, receipt, step.get("toolchain"))
        except (OSError, ValueError, TypeError, RuntimeError):
            return "receipt-unreadable"
        evidence = receipt.get("evidence", {})
        if receipt.get("status") != "passed" or evidence.get("status") != "valid":
            return "child-check-or-evidence-not-passed"
        try:
            if step.get("name") == "fixture-stability":
                proof = {"artifactProofVersion": session.ARTIFACT_PROOF_VERSION, "steps": [step]}
                children = (child for _, _, child in session.workflow_child_receipts(
                    proof, session.ROOT, lambda child_path: receipt if path == child_path else read_child_receipt(child_path)))
            else:
                children = (receipt,)
            problems = [problem for child in children
                        for problem in session.receipt_artifact_problems(child, session.ROOT, mutable_caches)]
        except (OSError, ValueError, TypeError, KeyError, AttributeError, RuntimeError) as error:
            return "artifacts-unreadable:" + str(error)
        if problems:
            return "artifacts-changed:" + "; ".join(problems)
    if step.get("name") == "stage-debug" and pathlib.Path(command[0]).name == "xcodebuild.sh":
        if not receipt_path or not staged_debug_matches(step, receipt, path):
            return "debug-staging-evidence-missing-or-changed"
    try:
        if any(session.tree_identity(path) != identity for path, identity in session.workflow_outputs(session.ROOT, step)):
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
        deferred = [name for name in names if name in feedback.INTEGRATION_ONLY]
        names = [name for name in names if name not in feedback.INTEGRATION_ONLY]
        selection.update(base=base, changedPaths=paths, reasons=reasons, deferredToIntegration=deferred)
        if not full_selection and any(path.startswith("scripts/") for path in paths):
            selection["scriptTestPatterns"] = feedback.script_test_patterns(paths, root)
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
    if args.profile == "feedback" and not args.check and not selectors and not full_selection:
        selectors = feedback.test_file_selectors(root, paths)
        if selectors:
            groups = {"correctness" if value.startswith("GitXTests/") else "ui" for value in selectors}
            commands = [(name, command) for name, command in commands if name == "static"] + [
                (name, command) for name, command in full_profile(root) if name in groups]
            selection["testSelectionReason"] = "changed-test-classes"
        elif not any(path.startswith(("GitXTests/", "GitXUITests/")) for path in paths):
            names_in_feedback = {name for name, _ in commands}
            discovered = feedback.contract_selectors(root, paths) if names_in_feedback & {"correctness", "ui"} else []
            by_target = {"GitXTests": "correctness", "GitXUITests": "ui"}
            covered_checks = {by_target[value.split("/")[0]] for value in discovered}
            if names_in_feedback & {"correctness", "ui"} <= covered_checks:
                selectors = [value for value in discovered if by_target[value.split("/")[0]] in names_in_feedback]
                if selectors:
                    selection["testSelectionReason"] = "affected-regression-contracts"
    if selectors and selection["deliveryEligible"]:
        raise ValueError("Focused tests require --profile feedback or an explicit partial --check")
    commands = feedback.focus_commands(commands, selectors)
    selection.update(selectedChecks=[name for name, _ in commands], testSelectors=selectors or [], jobs=getattr(args, "jobs", 1))
    return commands, selection


def resources_for(commands, directory, root, details=None):
    resources = [str(directory)]
    toolchain = None
    for _, command in commands:
        entry = pathlib.Path(command[0]).name
        arguments = command[1:]
        if entry == "verify_static.sh":
            continue
        if len(command) > 1 and pathlib.Path(command[1]).name == "check_fixture_stability.py":
            toolchain = toolchain or session.toolchain_identity()
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
        parallel = getattr(args, "jobs", 1) == 2
        selected_resources = [str(directory)] if parallel else resources
        origin = getattr(args, "reuse_evidence", None)
        if origin:
            selected_resources = [*selected_resources, str(directory.parent / origin)]
        with session.Leases(selected_resources, owner, wait_seconds=max(0, deadline - time.monotonic())) as leases:
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

    def read(path):
        if path not in children:
            children[path] = read_child_receipt(path)
        return children[path]

    try:
        derived = session.workflow_cache_snapshots(payload, root, receipt_reader=read)
        return derived if not session.final_cache_problems(payload, root, derived=derived) else None
    except (OSError, ValueError, TypeError, KeyError, AttributeError):
        # An unavailable prior child rejects reuse. Verify the check again.
        return None


def finish_invalid(path, payload, problems, attempt_started):
    for key in ("category", "problem", "owner", "resource"):
        payload.pop(key, None)
    payload.update(status="invalid", evidenceStatus="invalid", deliveryEligible=False, exitCode=76,
                   evidenceProblems=problems, finishedAt=records.now(),
                   attemptDurationSeconds=round(time.monotonic() - attempt_started, 3))
    session.atomic_json(path, payload)
    print(f"Verification evidence is invalid. Receipt: {path}", file=sys.stderr)
    return 76


@contextlib.contextmanager
def admitted_failure_receipt(path, payload_getter, producer, attempt_started):
    """Publish blocked state before the enclosing directory lease is released."""
    try:
        yield
    except KeyboardInterrupt:
        finish_stopped(path, payload_getter(), 130, None, attempt_started)
        raise
    except (session.ResourceBusy, session.ResourceDefinitionError) as error:
        payload = payload_getter()
        payload.update(session.resource_failure_fields(error), producer=producer,
                       attemptDurationSeconds=round(time.monotonic() - attempt_started, 3))
        session.atomic_json(path, payload)
        print(f"{error}\nBlocked receipt under directory lease: {path}", file=sys.stderr)
        raise


def check_reuse_reason(name, prior, current, command, caches, toolchain, history):
    if name == "fixture-stability" and any(
            history.get(check, {}).get("status") == "failed"
            for check in ("correctness", "address-undefined", "thread-sanitizer", "ui")):
        return "check-fixtures-after-native-failure"
    if prior is None:
        return "no-prior-evidence"
    if name == "fixture-stability" and not (prior.get("receipt") and prior.get("fixtureReceiptIdentity")):
        return "fixture-manifest-missing"
    return reuse_problem(prior, current, command, caches, toolchain)


def prepare_check(root, path, run_id, name, command, current, reason, prior, resume):
    print(f"Verify {name}; owning run {run_id}; receipt {path}", flush=True)
    attempt = uuid.uuid4().hex[:8]
    child_id = f"{run_id}-{name}-{attempt}"
    actual = command + (["--run-id", child_id] if pathlib.Path(command[0]).name == "xcodebuild.sh" else [])
    if resume and name == "fixture-stability":
        actual += ["--after", str(session.verification_artifact_root(root) / run_id / "workflow.json")]
    if resume and name == "analyze" and prior and prior.get("receipt"):
        try:
            prior_receipt = session.workflow_receipt_path(root, prior["receipt"])
            evidence = read_child_receipt(prior_receipt)
            inner = evidence.get("evidence", {})
            if session.valid_run_id(evidence.get("runId")) and inner.get("status") == "valid" and isinstance(inner.get("analyzerScratch"), dict) and inner["analyzerScratch"].get("path") and isinstance(inner.get("inputsAfter"), dict) and not session.changed_inputs(inner["inputsAfter"], current) and \
                    any(step.get("name") == "analyze" and step.get("status") == "passed" for step in evidence.get("steps", [])):
                actual += ["--resume-analysis", evidence["runId"], "--fresh-on-stale-analysis"]
            else:
                reason = "analyzer-recovery-unavailable"
        except (OSError, ValueError, TypeError):
            reason = "analyzer-recovery-receipt-unreadable"
    return actual, child_id, reason


def staged_debug_matches(step, child, receipt_path):
    invocation = child.get("invocation", {})
    identities = list(step.get("outputs", {}).values())
    return (pathlib.Path(receipt_path).name == "receipt.json"
            and child.get("runId") == pathlib.Path(receipt_path).parent.name
            and child.get("status") == "passed"
            and invocation.get("configuration") == "Debug" and invocation.get("preset") == "build"
            and len(identities) == 1 and identities[0] is not None
            and child.get("evidence", {}).get("stagedApp") == identities[0])


def record_check(root, path, payload, name, command, current, toolchain, reason, child_id, step_started, status, *, after=None):
    if after is None:
        after = session.inputs(root)
    outcome = status_for_exit(status)
    step = {"name": name, "command": command, "commandIdentity": session.command_identity(command), "status": outcome, "exitCode": status,
            "inputsBefore": current, "inputsAfter": after, "toolchain": toolchain, "finishedAt": records.now(),
            "evidenceStatus": "invalid" if session.changed_inputs(current, after) else "valid", "outputs": {},
            "durationSeconds": round(time.monotonic() - step_started, 3),
            "executionReason": reason or "requested-fresh-check",
            "lastAttempt": {"action": "executed", "reason": reason or "requested-fresh-check"}}
    payload["executedChecks"].append(name)
    child_receipt = {}
    child_path = session.verification_artifact_root(root) / child_id / "receipt.json"
    if not child_path.is_file():
        child_path = session.verification_artifact_root(root) / "Coordination" / (child_id + ".json")
    coordination = session.verification_artifact_root(root) / "Coordination" / (child_id + ".json")
    if coordination.is_file():
        try:
            coordination_receipt = json.loads(coordination.read_text())
            step["resourceWaitSeconds"] = coordination_receipt.get("resourceWaitSeconds", 0)
            step["startedAt"] = coordination_receipt.get("startedAt")
        except (OSError, ValueError, AttributeError):
            pass
    if child_path.is_file():
        step["receipt"] = str(child_path)
        try:
            child_path = session.workflow_receipt_path(root, child_path)
            child_receipt = read_child_receipt(child_path)
        except (OSError, ValueError, RuntimeError):
            child_receipt = {}
        if child_receipt.get("evidence", {}).get("status") != "valid":
            step["evidenceStatus"] = "invalid"
    if status == 0 and pathlib.Path(command[0]).name == "xcodebuild.sh" and not child_path.is_file():
        step["evidenceStatus"] = "invalid"
        step["evidenceProblems"] = ["Missing Xcode receipt for " + name]
    if name == "fixture-stability" and status == 0:
        if child_path.name != "receipt.json" or not child_receipt.get("runId") == child_id:
            step["evidenceStatus"] = "invalid"
            step["evidenceProblems"] = ["Fixture manifest is missing"]
        else:
            step["fixtureReceiptIdentity"] = session.file_identity(child_path)
            step["fixtureOutcome"] = child_receipt.get("fixtureOutcome")
    if name == "stage-debug" and status == 0:
        try:
            step["outputs"][str(root / "build/GitX.app")] = session.tree_identity(root / "build/GitX.app")
        except (OSError, ValueError, TypeError) as error:
            step["outputs"][str(root / "build/GitX.app")] = None
            step["evidenceStatus"] = "invalid"
            step["evidenceProblems"] = ["Workflow output cannot be captured: " + str(error)]
        if pathlib.Path(command[0]).name == "xcodebuild.sh" and not staged_debug_matches(step, child_receipt, child_path):
            step["evidenceStatus"] = "invalid"
            step.setdefault("evidenceProblems", []).append("Staged app does not match the Debug build receipt")
    if status == 75:
        step["category"] = "resource-busy"
    payload["steps"] = [s for s in payload["steps"] if s["name"] != name] + [step]
    if step["evidenceStatus"] == "invalid" and status == 0:
        status = 76
    if status:
        payload.setdefault("firstFailureAt", step["finishedAt"])
    if not payload.get("firstFailureAt") or payload["firstFailureAt"] == step["finishedAt"]:
        payload["status"] = status_for_exit(status) if status else "running"
    payload.update(inputsAfter=after, updatedAt=records.now())
    session.atomic_json(path, payload)
    return status, step


def offscreen_environment(root, name, toolchain):
    partition = "analysis" if name == "analyze" else "packages"
    paths = session.cache_paths(root, instrumentation=partition, toolchain=toolchain)
    packages = pathlib.Path(paths["sourcePackages"])
    return {
        "GITX_DERIVED_DATA": paths["derivedData"],
        "GITX_SWIFTPM_BUILD_ROOT": paths["swiftPM"],
        "GITX_SOURCE_PACKAGE_CACHE": os.environ.get("GITX_SOURCE_PACKAGE_CACHE", str(packages.with_name(packages.name + "-" + partition))),
    }


OFFSCREEN_CHECKS = {"static", "whitespace", "core", "forgekit", "analyze"}
OFFSCREEN_BUILDS = {"core", "forgekit", "analyze"}
EXCLUSIVE_CHECKS = {"performance", "stage-debug"}
EARLY_CHECKS = {"interop", "debug-test-build", "release-test-build"}


def permitted_check(name, running, pending):
    if name in EXCLUSIVE_CHECKS:
        return not running and not (set(pending) - EXCLUSIVE_CHECKS) and (name != "stage-debug" or "performance" not in pending)
    if set(running) & EXCLUSIVE_CHECKS:
        return False
    if name in OFFSCREEN_CHECKS:
        if name == "analyze" and (set(running) | set(pending)) & EARLY_CHECKS:
            return False
        if name in OFFSCREEN_BUILDS and any(key in os.environ for key in ("GITX_DERIVED_DATA", "GITX_SWIFTPM_BUILD_ROOT", "GITX_SOURCE_PACKAGE_CACHE")):
            return not running and not (set(pending) - OFFSCREEN_CHECKS - EXCLUSIVE_CHECKS)
        return not set(running) & OFFSCREEN_CHECKS
    return not (set(running) - OFFSCREEN_CHECKS)


def parallel_inputs(root, run_id, wait):
    owner = {"runId": run_id, "pid": os.getpid(), "producer": session.producer_identity()}
    with session.Leases([session.shared_xcode_build_resource(root)], owner, wait_seconds=wait):
        return session.inputs(root)


def execute_parallel(root, path, payload, args, commands, selection, env, prior_steps, previous_caches):
    """Each supervisor owns its process tree. Only the coordinator writes the workflow receipt."""
    directory = path.parent
    pending = dict(commands)
    running = {}
    completed = {}
    stopped = 0
    observed_failure = None
    snapshot_wait = None
    last_failure = None
    cancelled = None
    sent_interrupt = False
    originals = {}

    def interrupt(signum, _frame):
        nonlocal cancelled
        cancelled = signum

    def snapshot():
        nonlocal snapshot_wait
        try:
            current = parallel_inputs(root, payload["runId"], 0)
        except session.ResourceBusy as error:
            children = {prepared[4] for _, prepared in running.values()}
            owner = error.owner.get("runId")
            internal = any(owner == child or (owner or "").startswith(child + "-") for child in children)
            if snapshot_wait is None or snapshot_wait[0] != owner:
                snapshot_wait = (owner, time.monotonic())
            budget = args.timeout if internal else getattr(args, "wait_for_resources", 0)
            if not cancelled and time.monotonic() - snapshot_wait[1] >= budget:
                raise
            return None
        snapshot_wait = None
        return current

    for signum in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        originals[signum] = signal.signal(signum, interrupt)
    try:
        while pending or running or completed:
            for name, (process, prepared) in list(running.items()):
                status = process.poll()
                if status is None:
                    continue
                del running[name]
                status = 128 - status if status < 0 else status
                completed[name] = (prepared, status)
                if status and not observed_failure and not sent_interrupt:
                    observed_failure = (status, {"name": name})
            if cancelled and not sent_interrupt:
                sent_interrupt = True
                for process, _ in running.values():
                    if process.poll() is None:
                        process.terminate()

            if completed:
                # A child can finish while its peer still holds the build lease.
                # Keep the exit status, but publish proof only from a coherent snapshot.
                try:
                    after = snapshot()
                except session.ResourceBusy:
                    if observed_failure:
                        return (stopped, last_failure) if stopped else observed_failure
                    raise
                if after is not None:
                    for name, (prepared, status) in completed.items():
                        status, step = record_check(root, path, payload, name, *prepared, status, after=after)
                        if status and not stopped and (not cancelled or (observed_failure and name == observed_failure[1]["name"])):
                            stopped, last_failure = status, step
                    completed.clear()
            if cancelled:
                if stopped:
                    return stopped, last_failure
                return observed_failure or (128 + cancelled, None)
            if stopped and not running:
                return stopped, last_failure
            if not stopped and not completed and not observed_failure:
                # Start analysis before offscreen packages once the compiler prerequisites settle.
                priority = sorted(pending, key=lambda name: name != "analyze")
                for name in priority:
                    if len(running) == 2:
                        break
                    if not permitted_check(name, running, pending):
                        continue
                    current = snapshot()
                    if current is None:
                        break
                    command = pending.pop(name)
                    if session.changed_inputs(payload["inputsBefore"], current):
                        stopped = 76
                        last_failure = {"evidenceStatus": "invalid", "evidenceProblems": ["Verification inputs changed before " + name]}
                        break
                    prior = prior_steps.get(name)
                    reason = check_reuse_reason(name, prior, current, command, previous_caches, selection["toolchain"], prior_steps)
                    if args.resume and prior and reason is None:
                        payload["reusedChecks"].append(name)
                        prior["lastAttempt"] = {"action": "reused", "reason": "matching-passed-evidence"}
                        continue
                    previous_caches = None
                    actual, child_id, reason = prepare_check(root, path, payload["runId"], name, command, current, reason, prior, args.resume)
                    child_env = env | {"GITX_SESSION_ID": child_id}
                    if name in OFFSCREEN_BUILDS:
                        child_env.update(offscreen_environment(root, name, selection["toolchain"]))
                    supervisor = [sys.executable, str(root / "scripts/workflow_session.py"), "run", "--timeout", str(args.timeout),
                                  "--diagnostics", str(directory / "Diagnostics" / name), "--", *actual]
                    if cancelled:
                        break
                    started = time.monotonic()
                    process = subprocess.Popen(supervisor, env=os.environ | child_env, cwd=root, start_new_session=True)
                    running[name] = (process, (command, current, selection["toolchain"], reason, child_id, started))
            if running or completed or (pending and not stopped):
                time.sleep(.15)
        return stopped or (128 + cancelled if cancelled else 0), last_failure
    finally:
        for process, _ in running.values():
            if process.poll() is None:
                process.terminate()
        for process, _ in running.values():
            process.wait()
        for signum, handler in originals.items():
            signal.signal(signum, handler)


def status_for_exit(status):
    if status == 0:
        return "passed"
    if status == 75:
        return "blocked"
    if status in {129, 130, 143}:
        return "interrupted"
    return "failed"


def finish_stopped(path, payload, status, step, attempt_started):
    if status == 76 and step and step.get("evidenceStatus") == "invalid":
        return finish_invalid(path, payload, step.get("evidenceProblems", ["Check evidence is invalid"]), attempt_started)
    if status == 75:
        payload["category"] = "resource-busy"
    payload.update(status=status_for_exit(status), finishedAt=records.now(), deliveryEligible=False,
                   exitCode=status, attemptDurationSeconds=round(time.monotonic() - attempt_started, 3))
    session.atomic_json(path, payload)
    if step:
        print(f"Verification stopped at {step.get('name', 'check')} (exit {status}). Receipt: {path}")
    return status


def verify(args):
    root = session.ROOT
    commands, selection = selected_commands(args, root)
    origin = getattr(args, "reuse_evidence", None)
    if origin and (args.resume or not selection["deliveryEligible"] or not session.valid_run_id(origin)):
        raise ValueError("--reuse-evidence requires a separate full workflow and a valid source run ID")
    if origin:
        selection["reuseEvidence"] = origin
    if getattr(args, "dry_run", False):
        print(json.dumps(selection, indent=2, sort_keys=True))
        return 0
    attempt_started = time.monotonic()
    started_at = records.now()
    run_id = args.resume if args.resume is not None else args.run_id if args.run_id is not None else "workflow-" + uuid.uuid4().hex[:12]
    if not session.valid_run_id(run_id):
        raise ValueError("Invalid run ID")
    directory = session.verification_artifact_root(root) / run_id
    path = session.workflow_receipt_path(root, directory / "workflow.json", workflow=True)
    if origin == run_id:
        raise ValueError("Evidence reuse requires a new run ID")
    if args.resume:
        if not path.is_file():
            raise ValueError("Resume requires a workflow receipt; historical receipts cannot be reused")
        payload = json.loads(path.read_text())
        session.require_current_workflow(root, path, payload)
    else:
        if path.exists():
            raise ValueError("Run already exists; use --resume or a fresh run ID")
        payload = {"schemaVersion": 2, "runId": run_id, "startedAt": records.now(), "profile": args.profile,
                   "steps": [], "status": "running"}
    owner = {"runId": run_id, "pid": os.getpid(), "receipt": str(path), "producer": session.producer_identity()}
    previous_caches = None
    owned_directory = False
    try:
        with selected_leases(args, root, directory, owner) as (leases, commands, selection), \
                admitted_failure_receipt(path, lambda: payload, owner["producer"], attempt_started):
            owned_directory = True
            if args.resume:
                # A previous producer may have finished while this attempt
                # waited. Read and mutate its receipt only after ownership.
                payload = json.loads(path.read_text())
                session.require_current_workflow(root, path, payload)
                if payload.get("evidenceReuse"):
                    raise ValueError("Retry a cross-commit attempt with a fresh run ID")
                previous_payload = dict(payload)
                payload["resumeHistory"] = payload.get("resumeHistory", []) + [{"resumedAt": records.now(), "previousInputs": payload.get("inputsBefore")}]
            elif path.exists():
                raise ValueError("Run already exists; use --resume or a fresh run ID")
            env = leases.environment() | {"GITX_SESSION_ID": run_id, "GITX_COMMAND_TIMEOUT": str(args.timeout),
                                          "GITX_RESOURCE_WAIT_SECONDS": str(getattr(args, "wait_for_resources", 0))}
            for key in ("category", "problem", "owner", "resource", "exitCode", "finishedAt", "evidenceProblems", "firstFailureAt"):
                payload.pop(key, None)
            payload.update(status="running", deliveryEligible=False, profile=args.profile, producer=owner["producer"],
                           artifactProofVersion=session.ARTIFACT_PROOF_VERSION, resources=sorted(leases.held),
                           scope="full" if selection["deliveryEligible"] else "partial", selection=selection,
                           selectedChecks=selection["selectedChecks"],
                           resourceWaitSeconds=round(leases.wait_seconds, 3), executedChecks=[], reusedChecks=[])
            payload["inputsBefore"] = (parallel_inputs(root, run_id, getattr(args, "wait_for_resources", 0))
                                       if getattr(args, "jobs", 1) == 2 else session.inputs(root))
            session.atomic_json(path, payload)
            if origin:
                origin_path = directory.parent / origin / "workflow.json"
                try:
                    source_workflow, _ = evidence_reuse.read_source(root, origin_path, payload["inputsBefore"])
                    with session.Leases(cleanup.proof_resources(root, origin_path), owner, inherited=leases.held,
                                        wait_seconds=getattr(args, "wait_for_resources", 0)):
                        caches = previous_cache_snapshots(source_workflow, root)
                        carried, relation = evidence_reuse.prepare(root, origin_path, payload["inputsBefore"], directory,
                                                                   dict(commands), selection["toolchain"], caches)
                    payload.update(steps=carried, evidenceReuse=relation, reusedChecks=[step["name"] for step in carried])
                    session.atomic_json(path, payload)
                except (OSError, ValueError, TypeError, KeyError, subprocess.SubprocessError) as error:
                    return finish_invalid(path, payload, [str(error)], attempt_started)
            if args.resume and previous_payload.get("status") == "passed":
                try:
                    previous_caches = previous_cache_snapshots(previous_payload, root)
                except (OSError, ValueError, TypeError, KeyError) as error:
                    payload["finalCacheProducts"] = {}
                    return finish_invalid(path, payload, ["Prior cache ownership cannot be validated: " + str(error)], attempt_started)
            try:
                session.active_workflow_steps(payload)
            except ValueError as error:
                return finish_invalid(path, payload, [str(error)], attempt_started)
            previous = {step["name"]: step for step in payload["steps"]}
            parallel = getattr(args, "jobs", 1) == 2
            to_execute = [(name, command) for name, command in commands if name not in payload["reusedChecks"]]
            stage = [(name, command) for name, command in to_execute if name == "stage-debug"]
            if parallel:
                work = [(name, command) for name, command in to_execute if name != "stage-debug"]
                status, step = execute_parallel(root, path, payload, args, work, selection, env, previous, previous_caches)
                if status:
                    return finish_stopped(path, payload, status, step, attempt_started)
                if payload["executedChecks"]:
                    previous_caches = None
            else:
                stage = to_execute
            proof_paths = resources_for(commands, directory, root) if parallel else []
            if parallel:
                proof_paths.append(session.shared_xcode_build_resource(root))
                for name in OFFSCREEN_BUILDS & dict(commands).keys():
                    proof_paths += list(offscreen_environment(root, name, selection["toolchain"]).values())
            proof_lease = session.Leases(proof_paths, owner, inherited=leases.held,
                                         wait_seconds=getattr(args, "wait_for_resources", 0)) if parallel else contextlib.nullcontext(leases)
            with proof_lease as proof:
                if session.changed_inputs(payload["inputsBefore"], session.inputs(root)):
                    return finish_invalid(path, payload, ["Verification inputs changed before final proof"], attempt_started)
                stage_env = proof.environment()
                for name, command in stage:
                    current = session.inputs(root)
                    prior = previous.get(name)
                    reason = check_reuse_reason(name, prior, current, command, previous_caches, selection["toolchain"], previous)
                    if args.resume and prior and reason is None:
                        print(f"Reuse {name}: passed evidence and inputs still match.", flush=True)
                        payload["reusedChecks"].append(name)
                        prior["lastAttempt"] = {"action": "reused", "reason": "matching-passed-evidence"}
                        continue
                    previous_caches = None
                    actual, child_id, reason = prepare_check(root, path, run_id, name, command, current, reason, prior, args.resume)
                    step_started = time.monotonic()
                    status = session.supervise(actual, timeout=args.timeout, directory=directory / "Diagnostics" / name,
                                               env=stage_env | env | {"GITX_RESOURCE_LEASES": stage_env.get("GITX_RESOURCE_LEASES", "{}"),
                                                                      "GITX_SESSION_ID": child_id}, pass_fds=proof.descriptors())
                    status, step = record_check(root, path, payload, name, command, current, selection["toolchain"],
                                                reason, child_id, step_started, status)
                    if status:
                        return finish_stopped(path, payload, status, step, attempt_started)
                payload.update(status="passed", finishedAt=records.now(), inputsAfter=session.inputs(root))
                if session.changed_inputs(payload["inputsBefore"], payload["inputsAfter"]):
                    return finish_invalid(path, payload, ["Verification inputs changed during the attempt"], attempt_started)
                payload["evidenceStatus"] = "valid"
                payload["deliveryEligible"] = selection["deliveryEligible"]
                active = session.active_workflow_steps(payload)
                names = [step["name"] for step in active]
                expected = [name for name, _ in commands]
                if set(names) != set(expected) or len(names) != len(expected) or any(
                        step.get("status") != "passed" or step.get("evidenceStatus") != "valid" for step in active):
                    return finish_invalid(path, payload, ["Active verification profile is incomplete, duplicated, or invalid"], attempt_started)
                try:
                    payload["finalCacheProducts"] = session.workflow_cache_snapshots(payload, root)
                    problems = session.final_cache_problems(payload, root, derived=payload["finalCacheProducts"])
                except (OSError, ValueError, TypeError, KeyError, RuntimeError) as error:
                    payload["finalCacheProducts"] = {}
                    problems = ["Final cache ownership cannot be validated: " + str(error)]
                if origin:
                    try:
                        evidence_reuse.validation_inputs(root, payload, payload["inputsAfter"])
                        evidence_reuse.verify_staged_version(root, payload["inputsAfter"]["head"])
                    except (OSError, ValueError, TypeError, KeyError, subprocess.SubprocessError) as error:
                        problems.append("Final evidence reuse validation failed: " + str(error))
                try:
                    for _, _, child in session.workflow_child_receipts(payload, root, read_child_receipt):
                        problems.extend(session.receipt_artifact_problems(child, root, payload["finalCacheProducts"]))
                except (OSError, ValueError, TypeError, KeyError, AttributeError) as error:
                    problems.append("Child receipt cannot be validated: " + str(error))
                for step in active:
                    try:
                        for output, identity in session.workflow_outputs(root, step):
                            if identity is None or session.tree_identity(output) != identity:
                                problems.append("Workflow output missing or changed: " + str(output))
                    except (OSError, ValueError, TypeError, RuntimeError) as error:
                        problems.append("Workflow output cannot be validated: " + str(error))
                if problems:
                    return finish_invalid(path, payload, problems, attempt_started)
                payload["attemptDurationSeconds"] = round(time.monotonic() - attempt_started, 3)
                session.atomic_json(path, payload)
                print(f"Checks: {len(payload['executedChecks'])} executed, {len(payload['reusedChecks'])} reused; "
                      f"{payload['attemptDurationSeconds']:.1f}s; delivery eligible: {payload['deliveryEligible']}")
                print(f"Local verification passed. Receipt: {path}")
    except KeyboardInterrupt:
        return 130
    except (session.ResourceBusy, session.ResourceDefinitionError) as error:
        failure = session.resource_failure_fields(error)
        status = failure["exitCode"]
        if not owned_directory:
            blocker = session.verification_artifact_root(root) / "Coordination" / session.workflow_blocker_name(run_id, uuid.uuid4().hex[:8])
            blocked = owner | failure | {"schemaVersion": 2, "receipt": str(blocker), "entry": str(root / "scripts/dev_workflow.py"),
                "workflowReceipt": str(path),
                "selectedChecks": selection["selectedChecks"], "resources": [],
                "startedAt": started_at,
                "attemptDurationSeconds": round(time.monotonic() - attempt_started, 3)}
            session.atomic_json(blocker, blocked)
            print(f"{error}\nBlocker receipt: {blocker}", file=sys.stderr)
            return status
        # The inner context already published while the directory was leased.
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
        result = cleanup.run_cleanup(session.ROOT, args.receipt, retry_retained_native=getattr(args, 'retry_retained_native', False))
    print(json.dumps(result, indent=2, sort_keys=True))
    return 2 if result.get("status") == "partial" else 0


def parser():
    result = argparse.ArgumentParser(description=__doc__)
    groups = result.add_subparsers(dest="group", required=True)
    verification = groups.add_parser("verify")
    verification.add_argument("--jobs", type=int, choices=(1, 2), default=1)
    verification.add_argument("--profile", choices=["full", "feedback"], default="full")
    verification.add_argument("--base-ref")
    verification.add_argument("--only-testing", action="append")
    verification.add_argument("--dry-run", action="store_true")
    verification.add_argument("--wait-for-resources", type=float, default=0)
    verification.add_argument("--resume")
    verification.add_argument("--reuse-evidence", metavar="RUN-ID")
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
    prune.add_argument("--retry-retained-native", action="store_true",
                       help="Revalidate retained native evidence; run cleanup queue first after completed cleanup; a current full receipt is required")
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
