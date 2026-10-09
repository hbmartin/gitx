"""Conservative, commit-triggered retention of generated verification output.

Discovery is read-only. Deletion requires a current full verification receipt,
resource leases, and a fresh metadata fingerprint. Historical receipts are never
rewritten; their referenced evidence and recovery sources are protected together.
"""
from __future__ import annotations

import datetime as dt
import fcntl
import hashlib
import json
import os
import pathlib
import plistlib
import re
import shlex
import shutil
import stat
import sys
import time
import uuid

import workflow_records as records
import workflow_session as session


def configuration(root):
    value = json.loads((pathlib.Path(root) / "scripts/verification-config.json").read_text())
    policy = value.get("cleanup", {})
    days = policy.get("retentionDays", 7)
    budget = policy.get("diagnosticBudgetBytes", 10 * 1024**3)
    limit = policy.get("reportLimit", 20)
    if any(isinstance(v, bool) or not isinstance(v, int) or v <= 0 for v in (days, budget, limit)):
        raise ValueError("Cleanup retention, budget, and report limit must be positive integers")
    return value, {"retentionDays": days, "diagnosticBudgetBytes": budget, "reportLimit": limit}


def state_directory(root):
    return records.common_directory(root) / "cleanup" / session.digest(str(pathlib.Path(root).resolve()).encode())[:16]


def pending_path(root):
    return state_directory(root) / "pending.json"


def read_json(path, default=None):
    path = pathlib.Path(path)
    if path.is_symlink():
        raise ValueError(f"Refusing symlink metadata: {path}")
    if not path.exists():
        return default
    return json.loads(path.read_text())


def queue_commit(root):
    root = pathlib.Path(root).resolve()
    head = session.git(root, "rev-parse", "HEAD")
    if not head:
        raise ValueError("Cleanup queue requires a committed checkout")
    path = pending_path(root)
    owner = {"runId": "cleanup-queue", "pid": os.getpid(), "receipt": str(path)}
    with session.Leases([str(path)], owner):
        value = {"schemaVersion": 1, "checkout": str(root), "head": head,
                 "queuedAt": records.now(), "token": uuid.uuid4().hex}
        session.atomic_json(path, value)
    return value | {"status": "queued"}


def install_hook(root):
    root = pathlib.Path(root).resolve()
    common = records.common_directory(root).parent
    configured = session.git(root, "config", "--get", "core.hooksPath")
    if configured:
        raise ValueError("An existing core.hooksPath is configured; integrate cleanup queue into that hook explicitly")
    path = common / "hooks/post-commit"
    content = ('#!/bin/sh\n# GitX commit-triggered cleanup v1\n'
               'checkout=$(git rev-parse --show-toplevel) || exit 0\n'
               'if [ -f "$checkout/scripts/workflow_cleanup.py" ] && [ -f "$checkout/scripts/dev_workflow.py" ]; then\n'
               '    ' + shlex.quote(sys.executable) + ' "$checkout/scripts/dev_workflow.py" cleanup queue >/dev/null ||\n'
               '        echo "GitX: cleanup could not be queued; the commit is preserved." >&2\n'
               'fi\nexit 0\n')
    if path.is_symlink() or (path.exists() and path.read_text() != content):
        raise ValueError(f"Refusing to replace existing post-commit hook: {path}")
    path.parent.mkdir(parents=True, exist_ok=True)
    if not path.exists():
        # Exclusive creation also protects an unrelated hook installed concurrently.
        with path.open("x") as stream:
            stream.write(content)
    path.chmod(0o755)
    return {"status": "installed", "hook": str(path)}


def fingerprint(path):
    """Allocated bytes, latest modification, and a stat-only identity; no links followed."""
    path = pathlib.Path(path)
    hasher = hashlib.sha256()
    size = 0
    newest = 0.0
    seen = set()
    stack = [path]
    while stack:
        item = stack.pop()
        info = item.lstat()
        identity = (info.st_dev, info.st_ino)
        hasher.update(str((str(item.relative_to(path)), info.st_dev, info.st_ino,
                           info.st_mode, info.st_size, info.st_mtime_ns, info.st_ctime_ns)).encode())
        newest = max(newest, info.st_mtime)
        if identity not in seen:
            size += info.st_blocks * 512
            seen.add(identity)
        if stat.S_ISDIR(info.st_mode):
            stack.extend(sorted(item.iterdir(), reverse=True))
    return {"bytes": size, "modified": newest, "identity": hasher.hexdigest()}


def overlap(left, right):
    # This runs for many run/reference pairs; constructing Path.parents here
    # makes a large inventory needlessly quadratic in path-object allocations.
    a, b = str(left), str(right)
    return a == b or a.startswith(b.rstrip("/") + "/") or b.startswith(a.rstrip("/") + "/")


def reference_paths(value, root):
    """Extract path references, including dictionary keys used for output identities."""
    found = set()
    def visit(item):
        if isinstance(item, str) and ("/" in item or item.endswith((".json", ".xcresult", ".app"))):
            p = pathlib.Path(item).expanduser()
            absolute = pathlib.Path(os.path.abspath(p if p.is_absolute() else root / p))
            found.update((absolute, absolute.resolve()))
        elif isinstance(item, dict):
            for key, child in item.items():
                if "/" in key:
                    visit(key)
                visit(child)
        elif isinstance(item, list):
            for child in item:
                visit(child)
    for key in ("receipt", "artifacts", "buildPaths", "paths", "outputs", "resources",
                "verificationReceipts", "recoverySources", "integrationEvidence"):
        visit(value.get(key, []))
    for step in value.get("steps", []):
        found.update(reference_paths(step, root))
    visit(value.get("evidence", {}).get("results", {}))
    return found


def date_value(value, fallback):
    try:
        return dt.datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp()
    except (ValueError, TypeError, AttributeError):
        return fallback


def busy_resource(resources):
    # Preview must not create or modify locks, directories, receipts, or state.
    for resource in resources:
        canonical = session.canonical_resource(str(resource))
        path = session.LOCK_ROOT / (session.digest(canonical.encode()) + ".lock")
        if not path.exists():
            continue
        with path.open("r") as stream:
            try:
                fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                return canonical
            finally:
                fcntl.flock(stream, fcntl.LOCK_UN)
    return None


def inventory(root, receipt=None, now=None):
    import dev_workflow as workflow
    root = pathlib.Path(root).resolve()
    now = time.time() if now is None else now
    config, policy = configuration(root)
    artifact = root / config["artifactRoot"]
    if artifact.is_symlink() or not artifact.resolve().is_relative_to(root):
        raise ValueError("Artifact root must remain inside the checkout without a symlink")
    protected = {root / "build/GitX.app": "staged Debug app"}
    for tree in records.worktrees(root):
        path = pathlib.Path(tree["worktree"]).resolve()
        if path != root:
            protected[path] = "registered worktree"
    for name in session.git(root, "ls-files", "-z").split("\0"):
        if name:
            p = root / name
            if p.is_relative_to(artifact) or p.is_relative_to(root / "build"):
                protected[p] = "tracked repository file"
    if receipt:
        protected[pathlib.Path(receipt).resolve().parent] = "current successful verification"
    ledger = read_json(records.common_directory(root) / "ledger.json", {"items": {}})
    for item in ledger["items"].values():
        for p in reference_paths(item, root):
            protected[p] = "work ledger or recovery reference"
    toolchain = session.cache_paths(root)["toolchain"]
    for _, command in workflow.full_profile(root):
        paths = session.entry_resources(pathlib.Path(command[0]).name, command[1:], root, toolchain=toolchain)[1]
        for key in ("derivedData", "swiftPM", "sourcePackages"):
            protected[pathlib.Path(paths[key]).resolve()] = "current warm cache"
    for variable in ("GITX_DERIVED_DATA", "GITX_SWIFTPM_BUILD_ROOT", "GITX_SOURCE_PACKAGE_CACHE"):
        if os.environ.get(variable):
            protected[pathlib.Path(os.environ[variable]).expanduser().resolve()] = "individual cache override"
    latest = read_json(artifact / "latest.json", {})
    if latest.get("receipt"):
        protected[(root / latest["receipt"]).resolve().parent] = "latest receipt"
    entries = {}
    unknown = []
    if artifact.exists():
        print(f"Cleanup inventory: inspecting verification runs in {artifact}", file=sys.stderr, flush=True)
        for p in sorted(artifact.iterdir()):
            if not p.is_dir() or p.name in {"Coordination", "diagnostics", "Diagnostics"}:
                continue
            if p.is_symlink():
                unknown.append({"paths": [str(p)], "reason": "symlink directory"})
                continue
            documents = []
            try:
                for name in ("workflow.json", "receipt.json", "runtime.json"):
                    value = read_json(p / name)
                    if isinstance(value, dict):
                        documents.append(value)
                    elif value is not None:
                        raise ValueError("Run metadata must be an object")
            except (ValueError, OSError):
                documents = []
            if not documents:
                unknown.append({"paths": [str(p)], "reason": "unknown or unreadable run metadata"})
                continue
            if (p / ".git").exists():
                protected[p] = "embedded repository or worktree"
            snapshot = fingerprint(p)
            refs = set().union(*(reference_paths(d, root) for d in documents))
            resources = {p} | {q for q in refs if any(overlap(q, pathlib.Path(v))
                         for d in documents for v in (d.get("buildPaths", {}) | d.get("paths", {})).values() if v)}
            completed = max(date_value(d.get("finishedAt", d.get("startedAt")), snapshot["modified"]) for d in documents)
            entries[p] = {"documents": documents, "snapshot": snapshot, "refs": refs,
                          "resources": resources, "completed": completed}
            if len(entries) % 100 == 0:
                print(f"Cleanup inventory: inspected {len(entries)} runs", file=sys.stderr, flush=True)
            if any(d.get("status") in {"running", "pending"} for d in documents):
                protected[p] = "unfinished run"
            if any(d.get("schemaVersion") == 2 and d.get("scope") == "full" and
                   d.get("inputsAfter") and not session.changed_inputs(d["inputsAfter"], session.inputs(root)) and
                   any(workflow.reusable(s, d["inputsAfter"], s.get("command")) for s in d.get("steps", []))
                   for d in documents if d.get("status") != "passed"):
                protected[p] = "resumable workflow"
    for label, predicate in (
        ("newest successful full verification", lambda d: d.get("scope") == "full" and d.get("status") == "passed" and d.get("deliveryEligible")),
        ("newest failed run", lambda d: d.get("status") in {"failed", "interrupted", "invalid"}),
    ):
        matching = [p for p, e in entries.items() if any(predicate(d) for d in e["documents"])]
        if matching:
            protected[max(matching, key=lambda p: entries[p]["completed"])] = label
    backups = [p for run in entries for p in run.glob("previous-*.app") if p.is_dir() and not p.is_symlink()]
    if backups:
        protected[max(backups, key=lambda p: (entries[p.parent]["completed"], p.stat().st_mtime))] = "newest previous-app backup"
    # Union workflows, their child receipts, and cross-run evidence into indivisible groups.
    parents = {p: p for p in entries}
    def find(p):
        while parents[p] != p:
            p = parents[p]
        return p
    for p, entry in entries.items():
        for ref in entry["refs"]:
            if ref.is_relative_to(artifact):
                parts = ref.relative_to(artifact).parts
                other = artifact / parts[0] if parts else None
                if other in entries:
                    parents[find(other)] = find(p)
    groups = {}
    for p in entries:
        groups.setdefault(find(p), []).append(p)
    # Protect all dependencies of a protected group, recursively.
    changed = True
    while changed:
        changed = False
        for members in groups.values():
            if any(overlap(p, q) for p in members for q in protected):
                for p in members:
                    for q in entries[p]["refs"] | {p}:
                        if q not in protected:
                            protected[q] = "protected verification dependency"
                            changed = True
    candidates = []
    retained = list(unknown)
    cutoff = now - policy["retentionDays"] * 86400
    def consider(paths, kind, snapshots, resources, age):
        reasons = sorted({reason for q, reason in protected.items() if any(overlap(p, q) for p in paths)})
        candidate = {"paths": [str(p) for p in paths], "kind": kind,
                     "bytes": sum(s["bytes"] for s in snapshots.values()), "modified": age,
                     "snapshots": {str(p): s for p, s in snapshots.items()},
                     "resources": sorted(str(p) for p in resources)}
        if reasons:
            retained.append(candidate | {"reason": "; ".join(reasons)})
        else:
            candidates.append(candidate)
    for members in groups.values():
        consider(members, "diagnostics", {p: entries[p]["snapshot"] for p in members},
                 set().union(*(entries[p]["resources"] for p in members)),
                 max(max(entries[p]["snapshot"]["modified"], entries[p]["completed"]) for p in members))
    build = root / "build"
    cache_checkout = session.verification_cache_root(root) / session.digest(str(root).encode())[:16]
    cache_directories = []
    if cache_checkout.exists() and not cache_checkout.is_symlink():
        for toolchain in cache_checkout.iterdir():
            if toolchain.is_symlink() or not toolchain.is_dir() or not re.fullmatch(r"[0-9a-f]{16}", toolchain.name):
                continue
            source = toolchain / "SourcePackages"
            if source.is_dir():
                cache_directories.append(source)
            for configuration_dir in toolchain.iterdir():
                if configuration_dir.name not in {"Debug", "Release"} or configuration_dir.is_symlink():
                    continue
                for instrumentation in configuration_dir.iterdir():
                    if not instrumentation.is_dir() or instrumentation.is_symlink():
                        continue
                    cache_directories.extend(p for p in instrumentation.iterdir()
                                             if p.name in {"DerivedData", "SwiftPM"} or p.name.startswith("AnalyzerDerivedData."))
    if build.exists() and not build.is_symlink():
        for p in build.iterdir():
            if not p.is_dir() or p.is_symlink():
                continue
            try:
                info = plistlib.loads((p / "info.plist").read_bytes())
                valid = isinstance(info, dict) and isinstance(info.get("WorkspacePath"), str) and pathlib.Path(info["WorkspacePath"]).resolve() == (root / config["workspace"]).resolve()
            except (OSError, ValueError, plistlib.InvalidFileException):
                valid = False
            if valid:
                cache_directories.append(p)
            elif p != root / "build/GitX.app":
                retained.append({"paths": [str(p)], "reason": "unknown build directory"})
    for p in cache_directories:
        if p.is_symlink() or not p.is_dir():
            retained.append({"paths": [str(p)], "reason": "symlink or unknown cache"})
            continue
        reasons = sorted({reason for q, reason in protected.items() if overlap(p, q)})
        if reasons:
            # Warm caches have no size cap. Walking their compiler intermediates
            # cannot change eligibility and is especially costly on external disks.
            retained.append({"paths": [str(p)], "kind": "cache", "reason": "; ".join(reasons)})
            continue
        snapshot = fingerprint(p)
        resources = {p} | {q for e in entries.values() for q in e["resources"] if q.is_relative_to(p)}
        resources.update(p / name for name in ("SourcePackages", "SwiftPM", "DerivedData") if (p / name).exists())
        consider([p], "cache", {p: snapshot}, resources, snapshot["modified"])
    print(f"Cleanup inventory: inspected {len(entries)} runs and {len(cache_directories)} cache directories", file=sys.stderr, flush=True)
    # Reuse the run snapshots already collected. A second complete traversal
    # doubled the cost of inspecting large legacy analyzer/result inventories.
    total = sum(entry["snapshot"]["bytes"] for entry in entries.values())
    if artifact.exists():
        total += artifact.lstat().st_blocks * 512
        total += sum(fingerprint(p)["bytes"] for p in artifact.iterdir() if p not in entries)
    remaining = total
    selected = []
    for c in sorted(candidates, key=lambda c: (c["modified"], c["paths"])):
        expired = c["modified"] < cutoff
        over_budget = c["kind"] == "diagnostics" and remaining > policy["diagnosticBudgetBytes"]
        if expired or over_budget:
            selected.append(c | {"reason": "expired" if expired else "diagnostic budget"})
            if c["kind"] == "diagnostics":
                remaining -= c["bytes"]
        else:
            retained.append(c | {"reason": "recent diagnostics or cache"})
    return {"schemaVersion": 1, "checkout": str(root), "policy": policy, "diagnosticBytes": total,
            "projectedDiagnosticBytes": remaining, "protectedExcessBytes": max(0, remaining - policy["diagnosticBudgetBytes"]),
            "candidates": selected, "retained": retained, "estimatedReclaimableBytes": sum(c["bytes"] for c in selected)}


def public_report(report):
    return {key: ([{k: v for k, v in item.items() if k not in {"snapshots", "resources", "modified"}} for item in value]
                  if isinstance(value, list) else value) for key, value in report.items()}


def preview(root, now=None):
    report = inventory(root, now=now)
    for candidate in report["candidates"]:
        busy = busy_resource(candidate["resources"])
        if busy:
            candidate["reason"] += f"; busy resource: {busy} (will skip)"
    return public_report(report) | {"status": "preview"}


def eligibility(root, receipt):
    import dev_workflow as workflow
    root = pathlib.Path(root).resolve()
    pending = read_json(pending_path(root))
    if not pending:
        return None, "no-pending-commit"
    path = pathlib.Path(receipt).resolve()
    artifact = root / configuration(root)[0]["artifactRoot"]
    if not path.is_relative_to(artifact.resolve()) or path.name != "workflow.json":
        return None, "receipt-is-not-a-local-workflow"
    value = read_json(path)
    if not value or value.get("schemaVersion") != 2 or value.get("status") != "passed" or value.get("evidenceStatus") != "valid" or not value.get("deliveryEligible") or value.get("scope") != "full" or value.get("profile") != "full":
        return None, "full-successful-verification-required"
    current = session.inputs(root)
    if pending.get("checkout") != str(root) or pending.get("head") != current["head"] or value.get("inputsAfter", {}).get("root") != str(root) or any(
            session.changed_inputs(value.get(key, {}), current) for key in ("inputsBefore", "inputsAfter")):
        return None, "commit-or-inputs-changed"
    if session.git(root, "diff", "HEAD", "--binary"):
        return None, "uncommitted-tracked-changes"
    expected = workflow.full_profile(root)
    if value.get("selectedChecks") != [name for name, _ in expected] or len(value.get("steps", [])) != len(expected):
        return None, "incomplete-profile"
    toolchain = session.cache_paths(root)["toolchain"]
    products, packages = {}, {}
    dependencies = None
    for (name, command), step in zip(expected, value["steps"]):
        if step.get("name") != name or step.get("command") != command or step.get("status") != "passed" or step.get("evidenceStatus") != "valid" or step.get("toolchain") != toolchain or session.changed_inputs(step.get("inputsAfter", {}), current):
            return None, "verification-evidence-no-longer-reusable"
        if pathlib.Path(command[0]).name == "xcodebuild.sh" and not step.get("receipt"):
            return None, "missing-child-receipt"
        if step.get("receipt"):
            child_path = pathlib.Path(step["receipt"])
            if not child_path.is_absolute():
                child_path = root / child_path
            if not child_path.resolve().is_relative_to(artifact.resolve()):
                return None, "child-receipt-outside-checkout"
            child = read_json(child_path, {})
            evidence = child.get("evidence", {})
            if child.get("schemaVersion") != 2 or child.get("status") != "passed" or evidence.get("status") != "valid" or any(
                    session.changed_inputs(evidence.get(key, {}), current) for key in ("inputsBefore", "inputsAfter")):
                return None, "invalid-child-evidence"
            if not isinstance(evidence.get("dependencyProducts"), dict):
                return None, "invalid-child-evidence"
            dependencies = evidence["dependencyProducts"]
            for result, identity in evidence.get("results", {}).items():
                if session.tree_identity(root / result) != identity:
                    return None, "test-results-changed"
            paths = child.get("buildPaths", {})
            temporary_analyzer = name == "analyze" and child.get("invocation", {}).get("preset") == "analyze"
            if paths.get("derivedData") and "products" in evidence and not temporary_analyzer:
                products[paths["derivedData"]] = evidence["products"]
            if paths.get("swiftPM") and "packageProducts" in evidence:
                packages[paths["swiftPM"]] = evidence["packageProducts"]
        if any(session.tree_identity(path) != identity for path, identity in step.get("outputs", {}).items()):
            return None, "workflow-output-changed"
    # Later checks intentionally reuse and update earlier compilation products.
    # Validate the last snapshot of each mutable cache, and every immutable result.
    if dependencies is not None and dependencies != session.dependency_products(root):
        return None, "dependency-products-changed"
    if any(session.product_identity(path) != identity for path, identity in products.items()) or any(
            session.package_products(path) != identity for path, identity in packages.items()):
        return None, "final-cache-products-changed"
    app = root / "build/GitX.app"
    if not app.is_dir() or value["steps"][-1].get("outputs", {}).get(str(app)) != session.tree_identity(app):
        return None, "staged-app-does-not-match"
    return pending, None


def run_cleanup(root, receipt, inherited=None):
    import dev_workflow as workflow
    root = pathlib.Path(root).resolve()
    pending, reason = eligibility(root, receipt)
    if reason:
        return {"status": "deferred", "reason": reason}
    verification = read_json(receipt)
    verified_inputs = verification["inputsAfter"]
    resources = {str(pathlib.Path(receipt).resolve().parent), str(root / "build/GitX.app")}
    resources.update(str((root / s["receipt"]).resolve().parent) for s in verification["steps"] if s.get("receipt"))
    toolchain = session.cache_paths(root)["toolchain"]
    for _, command in workflow.full_profile(root):
        if pathlib.Path(command[0]).suffix == ".sh":
            resources.update(session.entry_resources(pathlib.Path(command[0]).name, command[1:], root, toolchain=toolchain)[0])
    directory = state_directory(root)
    ledger_path = records.common_directory(root) / "ledger.json"
    owner = {"runId": "cleanup-" + uuid.uuid4().hex[:12], "pid": os.getpid(), "receipt": str(receipt)}
    report = None
    resources.update((str(records.common_directory(root) / "cleanup"), str(ledger_path)))
    with session.Leases(resources, owner, inherited=inherited):
        # Manual cleanup holds the same product leases as automatic cleanup.
        # Ledger references and managed verification output cannot change while
        # discovery scans the potentially large historical diagnostic tree.
        _, reason = eligibility(root, receipt)
        if reason or read_json(pending_path(root)) != pending:
            return {"status": "deferred", "reason": reason or "newer commit queued"}
        report = inventory(root, receipt)
        report.update(status="complete", committedHead=pending["head"], receipt=str(receipt),
                      deleted=[], skipped=[], failed=[], reclaimedBytes=0, startedAt=records.now())
        _, reason = eligibility(root, receipt)
        for index, candidate in enumerate(report["candidates"]):
            try:
                with session.Leases(candidate["resources"], owner, inherited=inherited):
                    current_pending = read_json(pending_path(root))
                    if reason or current_pending != pending or session.changed_inputs(verified_inputs, session.inputs(root)):
                        stop_reason = reason or ("newer commit queued" if current_pending != pending else "commit-or-inputs-changed")
                        report["skipped"].extend(c | {"reason": stop_reason} for c in report["candidates"][index:])
                        break
                    if any(fingerprint(p) != snapshot for p, snapshot in candidate["snapshots"].items()):
                        report["skipped"].append(candidate | {"reason": "directory changed after inventory"})
                        continue
                    for p in candidate["paths"]:
                        if pathlib.Path(p).is_symlink():
                            raise ValueError(f"Directory became a symlink: {p}")
                        shutil.rmtree(p)
                    report["deleted"].append(candidate)
                    report["reclaimedBytes"] += candidate["bytes"]
                    print(f"Cleanup removed {candidate['paths']}: approximately {candidate['bytes']} bytes", flush=True)
            except session.ResourceBusy as error:
                report["skipped"].append(candidate | {"reason": str(error)})
            except (OSError, ValueError) as error:
                report["failed"].append(candidate | {"reason": str(error)})
        _, changed = eligibility(root, receipt)
        report["status"] = "partial" if report["skipped"] or report["failed"] or changed else "complete"
        if changed:
            report["reason"] = changed
        report["finishedAt"] = records.now()
        reports = directory / "reports"
        output = reports / (dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%S") + "-" + uuid.uuid4().hex[:8] + ".json")
        session.atomic_json(output, public_report(report))
        for old in sorted(reports.glob("*.json"))[:-report["policy"]["reportLimit"]]:
            if not old.is_symlink():
                old.unlink()
        if report["status"] == "complete":
            with session.Leases([str(pending_path(root))], owner, inherited=inherited):
                if read_json(pending_path(root)) == pending:
                    pending_path(root).unlink()
                else:
                    report["status"] = "partial"
                    report["reason"] = "newer commit queued"
                    session.atomic_json(output, public_report(report))
        return public_report(report) | {"report": str(output)}
