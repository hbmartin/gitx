#!/usr/bin/env python3
"""Repeat the native fixtures implicated by a change or a previous failure."""

from __future__ import annotations

import argparse
import datetime as dt
import fnmatch
import json
import os
import pathlib
import subprocess
import sys
import uuid

import workflow_feedback as feedback
import workflow_session as session


DISCOVERY = {
    "GitXTests/GitBinaryReliabilityTests/testCancelledAndExpiredQueueEntriesImmediatelyReleaseAdmissionCapacity",
}
WORKTREE = {
    "GitXTests/WorktreeAppKitTests/" + method for method in (
        "testLockRemovalAndPruneSheetsRequireTheirOwnConfirmation",
        "testHiddenWindowRetainsCompletedPrunePreviewUntilTheUserReturns",
        "testMissingGitfileRepairRequiresSeparateDefaultCancelReclaimConsent",
        "testMovedWorktreeWithManagedGitfileSymlinkRequiresManualRepairAndBlocksPrune",
    )
}
REPLACEMENT = {
    "GitXTests/RepositoryDocumentScriptingCharacterizationTests/testRepairOfferAfterAnOverriddenRepositoryChangeBelongsToTheNewRepository",
}
QUIT = {
    "GitXTests/NativeTerminationIntegrationTests/testActualApplicationQuitProtectsRecoveryAndKeepEditingReopensAdmission",
    "GitXTests/NativeTerminationIntegrationTests/testPendingQuitRejectsNativeIndexAndRecoveryWritersButAllowsReads",
    "GitXTests/NativeTerminationIntegrationTests/testCancelQuitReopensTheActualForgeLifecycleWithoutCancellingItsMutation",
    "GitXTests/NativeRecoverySessionTests/testMenuQuitEndsASavedRecoverySheetBeforeForwardingToAppKit",
}
QUIT_UI = {
    "GitXUITests/Milestone2WorkflowUITests/testNativeQuitProtectsDetachedRecoveryAfterARealCoordinatedMove",
    "GitXUITests/Milestone2WorkflowUITests/testNativeQuitWaitsForRealLocalBranchCreationAndCancelQuitKeepsItRunning",
}
GROUPS = {
    "discovery": (("Classes/git/GitBinaryDiscovery.swift", "Classes/git/GitDiscoveryProbe.swift", "Classes/git/PBGitBinary.*",
                   "GitXTests/GitBinaryReliabilityTests.swift", "GitXTests/GitBinaryTestIsolation.swift"),
                  DISCOVERY, ("correctness", "address-undefined", "thread-sanitizer")),
    "worktrees": (("Classes/Controllers/PBGitWindowController+Worktrees.swift", "Classes/git/RepositoryWorktreeService.swift",
                   "GitXCore/Sources/GitXCore/Worktree*.swift", "GitXTests/WorktreeAppKitTests.swift"),
                  WORKTREE, ("correctness", "address-undefined", "thread-sanitizer")),
    "replacement": (("Classes/Controllers/PBGitRepositoryDocument.*", "Classes/Controllers/RepositoryDocumentScripting.swift",
                     "Classes/Controllers/PBGitWindowController.swift", "GitXTests/GitBinaryTests.swift"),
                    REPLACEMENT, ("correctness", "address-undefined")),
    "quit": (("Classes/Controllers/ApplicationController.*", "Classes/Controllers/RepositoryTerminationCoordinator.swift",
              "Classes/Controllers/ForgeMutationQuitCoordinator.swift", "Classes/Controllers/RepositoryPullRequestRecoverySession.swift",
              "Classes/Controllers/RepositoryPullRequestUIController.swift", "Classes/Controllers/Milestone2UITestHarness.swift",
              "Classes/git/RepositoryLocalMutationRegistry.swift", "Resources/en.lproj/MainMenu.xib", "GitXTests/NativeTerminationIntegrationTests.swift",
              "GitXTests/NativeRecoverySessionTests.swift", "GitXTests/NativePullRequestCompletionTests.swift",
              "GitXTests/NativeRecoveryMoveTests.swift", "GitXTests/NativeLocalMutationLifetimeTests.swift",
              "GitXUITests/Milestone2WorkflowUITests.swift"), QUIT, ("correctness", "thread-sanitizer")),
}
SHARED = ("GitXTests/GitXTestGitFixture.swift", "GitXUITests/GitXUITestFixtureWorkspace.swift", "GitXTests/*.xctestplan")


def select(paths, explicit=(), failed=()):
    groups = set(explicit)
    if any(fnmatch.fnmatchcase(path, pattern) for path in paths for pattern in SHARED):
        groups.update(GROUPS)
    result = {}
    for name, (patterns, selectors, presets) in GROUPS.items():
        if name in groups or selectors.intersection(failed) or (
                name == "quit" and QUIT_UI.intersection(failed)) or any(
                    fnmatch.fnmatchcase(path, pattern) for path in paths for pattern in patterns):
            for preset in presets:
                result.setdefault(preset, set()).update(selectors)
            if name == "quit":
                result.setdefault("ui", set()).update(QUIT_UI)
    if DISCOVERY.intersection(failed):
        for selectors in result.values():
            if selectors.intersection(DISCOVERY):
                selectors.difference_update(DISCOVERY)
                selectors.add("GitXTests/GitBinaryReliabilityTests")
    return {preset: sorted(result[preset]) for preset in ("correctness", "address-undefined", "thread-sanitizer", "ui") if preset in result}


def observed_tests(root, receipt, receipt_path):
    import regression_guardrails as guardrails

    for step in receipt.get("steps", []):
        bundle = step.get("xcresult")
        if not bundle or not step.get("name", "").startswith("test:"):
            continue
        path = session.owned_result_path(root, receipt_path, bundle)
        for test in guardrails.collect_test_outcomes(guardrails.report_xcresult.run_xcresulttool(path, "tests")):
            yield test["identifier"], test["result"].lower()


def failed_tests(root, prior):
    path = session.workflow_receipt_path(root, prior, workflow=True)
    workflow = json.loads(path.read_text())
    for step in session.active_workflow_steps(workflow):
        if step.get("name") not in session.FIXTURE_PRESETS or step.get("status") != "failed" or not step.get("receipt"):
            continue
        try:
            receipt_path = session.workflow_receipt_path(root, step["receipt"])
            receipt = json.loads(receipt_path.read_text())
            if not isinstance(receipt, dict):
                raise ValueError("Native receipt must be an object")
            yield from (name for name, status in observed_tests(root, receipt, receipt_path) if status == "failed")
        except (OSError, ValueError, TypeError, KeyError, AttributeError, RuntimeError, subprocess.SubprocessError):
            print(f"Prior {step['name']} diagnostic receipt unavailable: {step['receipt']!r}", file=sys.stderr)


def verify_pass(root, run_id, selectors):
    path = session.workflow_receipt_path(root, session.verification_artifact_root(root) / run_id / "receipt.json")
    receipt = json.loads(path.read_text())
    if receipt.get("status") != "passed" or receipt.get("evidence", {}).get("status") != "valid":
        raise ValueError(f"Fixture pass lacks valid evidence: {path}")
    observations = list(observed_tests(root, receipt, path))
    for selector in selectors:
        matches = [status for name, status in observations if name == selector or name.startswith(selector + "/")]
        if not matches or any(status != "passed" for status in matches):
            raise ValueError(f"Fixture selector did not pass: {selector} in {path}")
    return session.file_identity(path)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base-ref")
    parser.add_argument("--group", choices=GROUPS, action="append", default=[])
    parser.add_argument("--after", type=pathlib.Path, help="A failed local workflow receipt for fixture failure selection")
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()
    root = session.ROOT
    entry = str(pathlib.Path(__file__).resolve())
    if not args.dry_run and os.environ.get("GITX_GUARDED_ENTRY") != entry:
        return session.guard(entry, sys.argv[1:])
    try:
        _, paths = feedback.changed_paths(root, args.base_ref)
        failed = list(failed_tests(root, args.after)) if args.after else []
        selected = select(paths, args.group, failed)
        print(json.dumps(selected, indent=2), flush=True)
        if args.dry_run:
            return 0
        parent = os.environ.get("GITX_SESSION_ID", "fixture-stability-" + uuid.uuid4().hex[:8])
        if not session.valid_run_id(parent):
            raise ValueError("Invalid fixture run ID")
        receipt = session.workflow_receipt_path(root, session.verification_artifact_root(root) / parent / "receipt.json")
        if receipt.exists():
            raise ValueError("Fixture run receipt already exists")
        before = session.inputs(root)
        began = dt.datetime.now(dt.timezone.utc).isoformat()
        runs = []
        for preset, selectors in selected.items():
            for repetition in session.FIXTURE_REPETITIONS:
                run_id = f"{parent}-{preset}-{repetition}"
                command = [str(root / "scripts/xcodebuild.sh"), "--run-id", run_id, "test", preset,
                           *["-only-testing:" + selector for selector in selectors]]
                result = subprocess.run(command, cwd=root, check=False)
                if result.returncode:
                    return result.returncode
                runs.append({"runId": run_id, "preset": preset, "selectors": selectors,
                             "receiptIdentity": verify_pass(root, run_id, selectors)})
        after = session.inputs(root)
        if session.changed_inputs(before, after):
            raise ValueError("Inputs changed during fixture stability checks")
        session.atomic_json(receipt, {"schemaVersion": 2, "artifactProofVersion": session.ARTIFACT_PROOF_VERSION,
                            "runId": parent, "entry": entry,
                            "producer": session.producer_identity(), "receipt": str(receipt),
                            "startedAt": began, "finishedAt": dt.datetime.now(dt.timezone.utc).isoformat(),
                            "status": "passed", "exitCode": 0, "selectedFixtures": selected, "fixtureRuns": runs,
                            "fixtureOutcome": "passed" if selected else "no-fixtures-selected",
                            "verificationReceipts": [str(receipt.parent.parent / run["runId"] / "receipt.json") for run in runs],
                            "evidence": {"status": "valid", "inputsBefore": before, "inputsAfter": after}})
        return 0
    except (OSError, ValueError, TypeError, KeyError, AttributeError, subprocess.SubprocessError) as error:
        print(error, file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
