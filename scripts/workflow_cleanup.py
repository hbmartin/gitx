"""Conservative, commit-triggered retention of generated verification output.

Discovery is read-only. Deletion requires a current full verification receipt,
resource leases, and a fresh metadata fingerprint. Historical receipts are never
rewritten; their referenced evidence and recovery sources are protected together.
"""
from __future__ import annotations

import ctypes
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
    common = records.common_directory(root)
    common = common.parent.resolve() / common.name
    directory = common / "cleanup" / session.digest(str(pathlib.Path(root).resolve()).encode())[:16]
    for path in (common, common / "cleanup", directory, directory / "reports", directory / "journals"):
        if path.is_symlink():
            raise ValueError(f"Refusing symlink cleanup state: {path}")
    return directory


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
        existing = read_json(path)
        if existing and existing.get("checkout") == str(root) and existing.get("head") == head:
            return existing | {"status": "queued"}
        session.atomic_json(path, value)
    return value | {"status": "queued"}


def hook_content(name):
    return ('#!/bin/sh\n# GitX commit-triggered cleanup v2\n# hook: ' + name + '\n' +
            ('cat >/dev/null\n' if name == 'post-rewrite' else '') +
            'checkout=$(git rev-parse --show-toplevel) || exit 0\n'
            'if [ -f "$checkout/scripts/workflow_cleanup.py" ] && [ -f "$checkout/scripts/dev_workflow.py" ]; then\n'
            '    python3 "$checkout/scripts/dev_workflow.py" cleanup queue >/dev/null ||\n'
            '        echo "GitX: cleanup could not be queued; the commit is preserved." >&2\n'
            'fi\nexit 0\n')


def recognized_hook(content, name):
    if content == hook_content(name):
        return True
    if name != "post-commit" or not content.startswith('#!/bin/sh\n# GitX commit-triggered cleanup v1\n'):
        return False
    lines = content.splitlines(keepends=True)
    if len(lines) != 8:
        return False
    try:
        words = shlex.split(lines[4])
    except ValueError:
        return False
    if len(words) != 6 or not words[0].startswith('/') or words[1:] != ['$checkout/scripts/dev_workflow.py', 'cleanup', 'queue', '>/dev/null', '||']:
        return False
    lines[1] = '# GitX commit-triggered cleanup v2\n# hook: post-commit\n'
    lines[4] = '    python3 "$checkout/scripts/dev_workflow.py" cleanup queue >/dev/null ||\n'
    return ''.join(lines) == hook_content(name)


def install_hook(root):
    root = pathlib.Path(root).resolve()
    common = records.common_directory(root).parent
    if session.git(root, "config", "--get", "core.hooksPath"):
        raise ValueError("An existing core.hooksPath is configured; integrate cleanup queue into that hook explicitly")
    paths = [common / "hooks" / name for name in ("post-commit", "post-merge", "post-applypatch", "post-rewrite")]
    owner = {"runId": "cleanup-hooks", "pid": os.getpid(), "receipt": str(common)}
    with session.Leases([str(p) for p in paths], owner):
        for path in paths:
            if path.is_symlink() or (path.exists() and not recognized_hook(path.read_text(), path.name)):
                raise ValueError(f"Refusing to replace existing {path.name} hook: {path}")
        for path in paths:
            path.parent.mkdir(parents=True, exist_ok=True)
            before = directory_identity(path) if path.exists() else None
            temporary = path.with_name(path.name + ".gitx-" + uuid.uuid4().hex)
            try:
                with temporary.open("x") as stream:
                    stream.write(hook_content(path.name)); stream.flush(); os.fsync(stream.fileno())
                temporary.chmod(0o755)
                if before is None:
                    os.link(temporary, path)
                else:
                    if path.is_symlink() or directory_identity(path) != before or not recognized_hook(path.read_text(), path.name):
                        raise ValueError(f"Hook changed during installation: {path}")
                    os.replace(temporary, path)
            finally:
                temporary.unlink(missing_ok=True)
    return {"status": "installed", "hook": str(paths[0]), "hooks": [str(p) for p in paths]}


def directory_identity(path):
    info = pathlib.Path(path).lstat()
    return {"device": info.st_dev, "inode": info.st_ino, "mode": stat.S_IFMT(info.st_mode),
            "birthNs": getattr(info, "st_birthtime_ns", int(getattr(info, "st_birthtime", 0) * 1e9))}


def fingerprint(path):
    """Walk directory descriptors without following replaced paths or symlinks."""
    path = pathlib.Path(path)
    hasher, size, newest, seen, repositories = hashlib.sha256(), 0, 0.0, set(), []
    def key(info):
        return info.st_dev, info.st_ino, info.st_mode, info.st_size, info.st_mtime_ns, info.st_ctime_ns
    def visit(name, relative, parent=None):
        nonlocal size, newest
        before = os.stat(name, dir_fd=parent, follow_symlinks=False)
        hasher.update(str((relative, *key(before))).encode())
        newest = max(newest, before.st_mtime)
        identity = before.st_dev, before.st_ino
        if identity not in seen:
            size += before.st_blocks * 512
            seen.add(identity)
        if pathlib.Path(relative).name == ".git":
            repositories.append(relative)
        if stat.S_ISDIR(before.st_mode):
            descriptor = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=parent)
            try:
                if key(os.fstat(descriptor)) != key(before):
                    raise ValueError("Directory changed during discovery: " + str(path / relative))
                for child in sorted(os.listdir(descriptor)):
                    visit(child, str(pathlib.Path(relative) / child), descriptor)
                if key(os.fstat(descriptor)) != key(before):
                    raise ValueError("Directory changed during discovery: " + str(path / relative))
            finally:
                os.close(descriptor)
        if key(os.stat(name, dir_fd=parent, follow_symlinks=False)) != key(before):
            raise ValueError("Entry changed during discovery: " + str(path / relative))
    visit(str(path), ".")
    return {"bytes": size, "modified": newest, "identity": hasher.hexdigest(),
            "directory": directory_identity(path), "repositories": repositories}


def overlap(left, right, identities=None):
    """Ancestry is lexical or established by actual filesystem identity, not case folding."""
    left, right = pathlib.Path(os.path.abspath(left)), pathlib.Path(os.path.abspath(right))
    if left == right or left.is_relative_to(right) or right.is_relative_to(left):
        return True
    def identity(path):
        if identities is not None and path in identities:
            return identities[path]
        try:
            info = path.stat()
            value = info.st_dev, info.st_ino
        except FileNotFoundError:
            value = None
        if identities is not None:
            identities[path] = value
        return value
    for object_path, descendant in ((left, right), (right, left)):
        key = identity(object_path)
        if key is not None and any(identity(p) == key for p in (descendant, *descendant.parents)):
            return True
    return False


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


def protection_token(root):
    """Small protection inputs can be revalidated without holding discovery leases."""
    root = pathlib.Path(root)
    names = session.git(root, "ls-files", "-z").split("\0")
    provenance = [name for name in names if name and
                  (name.startswith("docs/diagnostics/") or pathlib.Path(name).name in
                   {"verification.json", "runtime.json", "provenance.json", "REVIEW.md"})]
    paths = [records.common_directory(root) / "ledger.json"] + [root / n for n in provenance]
    artifact = session.verification_artifact_root(root)
    if artifact.exists():
        for entry in artifact.iterdir():
            if entry.is_dir() and not entry.is_symlink():
                if entry.name == "Coordination":
                    paths.extend(entry.glob("*.json"))
                else:
                    paths.extend(entry / n for n in ("receipt.json", "workflow.json", "runtime.json", "diagnostic-owner.json"))
        paths.append(artifact / "latest.json")
        scanned = set()
        for container in (artifact / "diagnostics", artifact / "Diagnostics", artifact / "Coordination/Diagnostics"):
            if not container.exists() or container.is_symlink():
                continue
            info = container.stat()
            key = info.st_dev, info.st_ino
            if key in scanned:
                continue
            scanned.add(key)
            for parent, directories, files in os.walk(container, followlinks=False):
                directories[:] = sorted(name for name in directories if not (pathlib.Path(parent) / name).is_symlink())
                if "diagnostic-owner.json" in files:
                    paths.append(pathlib.Path(parent) / "diagnostic-owner.json")
    objects = set()
    for path in paths:
        if path.suffix == ".json" and path.exists():
            value = read_json(path)
            if isinstance(value, dict):
                if path.is_relative_to(root) and str(path.relative_to(root)) in provenance:
                    value = {"recoverySources": value}
                if path.name == "ledger.json":
                    if not isinstance(value.get("items"), dict):
                        raise ValueError("Malformed work ledger")
                    for item in value["items"].values():
                        if not isinstance(item, dict):
                            raise ValueError("Malformed work ledger item")
                        objects.update(reference_paths(item, root))
                else:
                    objects.update(reference_paths(value, root))
    trees, tracked = records.worktrees(root), {}
    for tree in trees:
        checkout = pathlib.Path(tree["worktree"])
        selected = [str(checkout / name) for name in session.git(checkout, "ls-files", "-z").split("\0")
                    if name and any((checkout / name).is_relative_to(base) for base in (artifact, root / "build"))]
        tracked[str(checkout)] = sorted(selected)
        objects.update(pathlib.Path(name) for name in selected)
    identities = {}
    for path in objects:
        try:
            info = path.stat()
            identities[str(path)] = [info.st_dev, info.st_ino, stat.S_IFMT(info.st_mode),
                                     getattr(info, "st_birthtime_ns", int(getattr(info, "st_birthtime", 0) * 1e9))]
        except FileNotFoundError:
            identities[str(path)] = None
    return {"worktrees": trees, "worktreeTracked": tracked, "repository": directory_identity(root / ".git"),
            "files": {str(p): session.tree_identity(p) for p in paths}, "objects": identities}


def inventory(root, receipt=None, now=None):
    import dev_workflow as workflow
    root = pathlib.Path(root).resolve()
    now = time.time() if now is None else now
    config, policy = configuration(root)
    artifact = root / config["artifactRoot"]
    if artifact.is_symlink() or not artifact.resolve().is_relative_to(root):
        raise ValueError("Artifact root must remain inside the checkout without a symlink")
    errors, unknown, entries, entry_identities = [], [], {}, set()
    identity_cache = {}
    def intersects(left, right):
        try:
            return overlap(left, right, identity_cache)
        except OSError as error:
            uncertain(right, error)
            return True
    protected = {root / "build/GitX.app": "staged Debug app", root / ".git": "repository metadata"}
    def uncertain(path, error):
        errors.append({"path": str(path), "reason": str(error)})
        unknown.append({"paths": [str(path)], "reason": "unknown or unreadable entry: " + str(error)})
    def children(path):
        try:
            return sorted(path.iterdir()) if path.exists() else []
        except OSError as error:
            uncertain(path, error)
            return []
    def snapshot(path):
        try:
            return fingerprint(path)
        except (OSError, ValueError) as error:
            uncertain(path, error)
            return None
    def metadata(path, default=None):
        try:
            return read_json(path, default)
        except (OSError, ValueError, TypeError) as error:
            uncertain(path, error)
            return default
    try:
        trees = records.worktrees(root)
        for tree in trees:
            path = pathlib.Path(tree["worktree"]).resolve()
            # A containing checkout is not itself a foreign descendant. Its
            # tracked files and Git metadata still establish protection below.
            if path != root and not root.is_relative_to(path):
                protected[path] = "registered worktree"
            for name in session.git(path, "ls-files", "-z").split("\0"):
                if name:
                    tracked = path / name
                    if tracked.is_relative_to(artifact) or tracked.is_relative_to(root / "build"):
                        protected[tracked] = "tracked repository file"
        token = protection_token(root)
    except (OSError, ValueError, KeyError) as error:
        uncertain(root / ".git", error)
        token = None
    if receipt:
        protected[pathlib.Path(receipt).resolve().parent] = "current successful verification"
    ledger = metadata(records.common_directory(root) / "ledger.json", {"items": {}})
    if not isinstance(ledger, dict) or not isinstance(ledger.get("items"), dict):
        uncertain(records.common_directory(root) / "ledger.json", "Malformed work ledger")
        ledger = {"items": {}}
    for item in ledger["items"].values():
        if not isinstance(item, dict):
            uncertain(records.common_directory(root) / "ledger.json", "Malformed ledger item")
            continue
        for path in reference_paths(item, root):
            protected[path] = "work ledger or recovery reference"
    toolchain = session.cache_paths(root)["toolchain"]
    for _, command in workflow.full_profile(root):
        paths = session.entry_resources(pathlib.Path(command[0]).name, command[1:], root, toolchain=toolchain)[1]
        for key in ("derivedData", "swiftPM", "sourcePackages"):
            protected[pathlib.Path(paths[key]).resolve()] = "current warm cache"
    for variable in ("GITX_DERIVED_DATA", "GITX_SWIFTPM_BUILD_ROOT", "GITX_SOURCE_PACKAGE_CACHE"):
        if os.environ.get(variable):
            protected[pathlib.Path(os.environ[variable]).expanduser().resolve()] = "individual cache override"
    latest = metadata(artifact / "latest.json", {})
    if isinstance(latest, dict) and latest.get("receipt"):
        protected[(root / latest["receipt"]).resolve().parent] = "latest receipt"
    def add(path, documents):
        snap = snapshot(path)
        if snap is None:
            return
        key = snap["directory"]["device"], snap["directory"]["inode"]
        if key in entry_identities:
            return
        entry_identities.add(key)
        if snap["repositories"]:
            protected[path] = "embedded repository or worktree"
        refs = set().union(*(reference_paths(d, root) for d in documents))
        resources = {path} | {pathlib.Path(v).resolve() for d in documents for v in
                               (d.get("buildPaths", {}) | d.get("paths", {})).values() if isinstance(v, str) and v}
        resources.update(pathlib.Path(v) for d in documents for v in d.get("resources", []) if isinstance(v, str) and not v.startswith("desktop:"))
        completed = max(date_value(d.get("finishedAt", d.get("startedAt")), snap["modified"]) for d in documents)
        unfinished = [d for d in documents if d.get("status") in {"running", "pending"}]
        abandoned = bool(unfinished) and all(session.producer_state(d.get("producer")) == "abandoned" for d in unfinished)
        entries[path] = {"documents": documents, "snapshot": snap, "refs": refs,
                         "resources": resources, "completed": completed}
        if unfinished and not abandoned:
            protected[path] = "live or uncertain unfinished run"
        if not abandoned and any(d.get("schemaVersion") == 2 and d.get("scope") == "full" and
                d.get("inputsAfter") and not session.changed_inputs(d["inputsAfter"], session.inputs(root)) and
                any(workflow.reusable(step, d["inputsAfter"], step.get("command")) for step in d.get("steps", []))
                for d in documents if d.get("status") != "passed"):
            protected[path] = "resumable workflow"
    top = children(artifact)
    print(f"Cleanup inventory: inspecting verification output in {artifact}", file=sys.stderr, flush=True)
    for path in top:
        if path.name in {"Coordination", "diagnostics", "Diagnostics"} or not path.is_dir():
            continue
        if path.is_symlink() or path.name.startswith(".gitx-cleanup-trash-"):
            unknown.append({"paths": [str(path)], "reason": "symlink or quarantined directory"})
            continue
        documents = []
        try:
            for name in ("workflow.json", "receipt.json", "runtime.json"):
                value = read_json(path / name)
                if value is None:
                    continue
                if (not isinstance(value, dict) or type(value.get("schemaVersion")) is not int or
                        value["schemaVersion"] not in {1, 2} or value.get("status") not in
                        {"passed", "failed", "running", "pending", "interrupted", "invalid", "blocked"}):
                    raise ValueError("Unrecognized run metadata")
                documents.append(value)
            if documents:
                add(path, documents)
            else:
                unknown.append({"paths": [str(path)], "reason": "unmanaged legacy directory"})
        except (OSError, ValueError, TypeError, KeyError) as error:
            uncertain(path, error)
        if len(entries) and len(entries) % 100 == 0:
            print(f"Cleanup inventory: inspected {len(entries)} runs", file=sys.stderr, flush=True)
    for path in children(artifact / "Coordination"):
        if path.name == "Diagnostics" and path.is_dir() and not path.is_symlink():
            continue
        value = metadata(path)
        if (not path.is_symlink() and path.suffix == ".json" and isinstance(value, dict) and
                isinstance(value.get("runId"), str) and (value["runId"] == path.stem or re.fullmatch(re.escape(value["runId"]) + r"-[0-9a-f]{8}", path.stem)) and value.get("receipt") == str(path) and
                isinstance(value.get("entry"), str) and pathlib.Path(value["entry"]).resolve().is_relative_to(root / "scripts") and
                value.get("evidence", {}).get("inputsBefore", {}).get("root") == str(root) and
                value.get("status") in {"passed", "failed", "running", "blocked"}):
            add(path, [value])
        else:
            unknown.append({"paths": [str(path)], "reason": "unmanaged legacy Coordination receipt"})
    generic_seen = set()
    def generic(path):
        if path.is_symlink() or not path.is_dir() or path.name.startswith(".gitx-cleanup-trash-"):
            unknown.append({"paths": [str(path)], "reason": "unmanaged diagnostic entry"})
            return
        identity = directory_identity(path)
        key = identity["device"], identity["inode"]
        if key in generic_seen:
            return
        generic_seen.add(key)
        value = metadata(path / "diagnostic-owner.json")
        if (isinstance(value, dict) and value.get("schemaVersion") == 1 and
                value.get("kind") == "gitx-diagnostics" and value.get("checkout") == str(root) and
                value.get("status") in {"passed", "failed", "running"}):
            add(path, [value])
            return
        unknown.append({"paths": [str(path)], "reason": "unmanaged legacy diagnostic directory"})
        for child in children(path):
            if child.is_dir() and not child.is_symlink():
                generic(child)
    for container in (artifact / "diagnostics", artifact / "Diagnostics", artifact / "Coordination/Diagnostics"):
        for path in children(container):
            generic(path)
    # Tracked diagnostics can cite arbitrary JSON paths or exact run IDs in prose.
    aliases = {}
    for path, entry in entries.items():
        for run_id in {path.stem if path.is_file() else path.name} | {d.get("runId") for d in entry["documents"]}:
            if run_id:
                aliases.setdefault(run_id, set()).add(path)
    def all_paths(value):
        return reference_paths({"recoverySources": value}, root)
    for name in session.git(root, "ls-files", "-z").split("\0"):
        if not name or not (name.startswith("docs/diagnostics/") or pathlib.Path(name).name in
                            {"verification.json", "runtime.json", "provenance.json", "REVIEW.md"}):
            continue
        try:
            text = (root / name).read_text()
            if name.endswith(".json"):
                for path in all_paths(json.loads(text)):
                    protected[path] = "tracked diagnostic provenance"
            for run_id, paths in aliases.items():
                if re.search(r"(?<![\w.-])" + re.escape(run_id) + r"(?![\w.-])", text):
                    for path in paths:
                        protected[path] = "tracked exact run-ID citation"
        except (OSError, ValueError) as error:
            uncertain(root / name, error)
    for label, predicate in (
        ("newest successful full verification", lambda d: d.get("scope") == "full" and d.get("status") == "passed" and d.get("deliveryEligible")),
        ("newest failed run", lambda d: d.get("status") in {"failed", "interrupted", "invalid"}),
    ):
        matching = [p for p, entry in entries.items() if any(predicate(d) for d in entry["documents"])]
        if matching:
            protected[max(matching, key=lambda p: entries[p]["completed"])] = label
    backups = [p for run in entries if run.is_dir() for p in run.glob("previous-*.app") if p.is_dir() and not p.is_symlink()]
    if backups:
        protected[max(backups, key=lambda p: (entries[p.parent]["completed"], p.stat().st_mtime))] = "newest previous-app backup"
    parents = {p: p for p in entries}
    def find(path):
        while parents[path] != path:
            path = parents[path]
        return path
    producer_runs = {}
    for path, entry in entries.items():
        for doc in entry["documents"]:
            if doc.get("runId"):
                producer_runs.setdefault(doc["runId"], []).append(path)
    for members in producer_runs.values():
        for path in members[1:]:
            parents[find(path)] = find(members[0])
    indexed = {(entry["snapshot"]["directory"]["device"], entry["snapshot"]["directory"]["inode"]): path
               for path, entry in entries.items()}
    for path, entry in entries.items():
        for ref in entry["refs"]:
            for ancestor in (ref, *ref.parents):
                other = ancestor if ancestor in entries else None
                if other is None:
                    try:
                        info = ancestor.stat()
                        other = indexed.get((info.st_dev, info.st_ino))
                    except FileNotFoundError:
                        pass
                if other is not None:
                    parents[find(other)] = find(path)
                    break
    groups = {}
    for path in entries:
        groups.setdefault(find(path), []).append(path)
    changed = True
    while changed:
        changed = False
        for members in groups.values():
            if any(intersects(p, q) for p in members for q in protected):
                for path in members:
                    for ref in entries[path]["refs"] | {path}:
                        if ref not in protected:
                            protected[ref] = "protected verification dependency"
                            changed = True
    candidates, retained = [], list(unknown)
    def consider(paths, kind, snapshots, resources, age):
        reasons = sorted({reason for q, reason in protected.items() if any(intersects(p, q) for p in paths)})
        # Only candidate output stays owned during removal. Shared products
        # and the ledger are leased separately for the short commit gate.
        resources = {q for q in resources if not str(q).startswith("desktop:") and
                     any(q == p or q.is_relative_to(p) for p in paths)} | set(paths)
        candidate = {"paths": [str(p) for p in paths], "kind": kind,
                     "bytes": sum(s["bytes"] for s in snapshots.values()), "modified": age,
                     "snapshots": {str(p): s for p, s in snapshots.items()}, "resources": sorted(str(p) for p in resources)}
        (retained if reasons else candidates).append(candidate | ({"reason": "; ".join(reasons)} if reasons else {}))
    for members in groups.values():
        consider(members, "diagnostics", {p: entries[p]["snapshot"] for p in members},
                 set().union(*(entries[p]["resources"] for p in members)),
                 max(max(entries[p]["snapshot"]["modified"], entries[p]["completed"]) for p in members))
    cache_directories = []
    cache_checkout = session.verification_cache_root(root) / session.digest(str(root).encode())[:16]
    for toolchain_dir in children(cache_checkout):
        if toolchain_dir.is_symlink() or not toolchain_dir.is_dir() or not re.fullmatch(r"[0-9a-f]{16}", toolchain_dir.name):
            continue
        source = toolchain_dir / "SourcePackages"
        if source.is_dir():
            cache_directories.append(source)
        for configuration_dir in children(toolchain_dir):
            if configuration_dir.name not in {"Debug", "Release"} or configuration_dir.is_symlink():
                continue
            for instrumentation in children(configuration_dir):
                if instrumentation.is_dir() and not instrumentation.is_symlink():
                    cache_directories.extend(p for p in children(instrumentation) if p.name in
                                             {"DerivedData", "SwiftPM"} or p.name.startswith("AnalyzerDerivedData."))
    for path in children(root / "build"):
        if path == root / "build/GitX.app":
            continue
        try:
            info = path / "info.plist"
            valid = path.is_dir() and not path.is_symlink() and not info.is_symlink() and pathlib.Path(
                plistlib.loads(info.read_bytes())["WorkspacePath"]).resolve() == (root / config["workspace"]).resolve()
        except (OSError, ValueError, KeyError, plistlib.InvalidFileException):
            valid = False
        if valid:
            cache_directories.append(path)
        else:
            retained.append({"paths": [str(path)], "reason": "unknown build directory"})
    cache_seen = set()
    for path in cache_directories:
        identity = directory_identity(path)
        key = identity["device"], identity["inode"]
        if key in cache_seen:
            continue
        cache_seen.add(key)
        reasons = sorted({reason for q, reason in protected.items() if intersects(path, q)})
        if reasons:
            retained.append({"paths": [str(path)], "kind": "cache", "reason": "; ".join(reasons)})
            continue
        snap = snapshot(path)
        if snap is not None:
            if snap["repositories"]:
                retained.append({"paths": [str(path)], "reason": "embedded repository or worktree"})
            else:
                resources = {path} | {q for entry in entries.values() for q in entry["resources"] if q.is_relative_to(path)}
                consider([path], "cache", {path: snap}, resources, snap["modified"])
    # Count each top-level tree once; collected top-level snapshots avoid rescans.
    total = artifact.lstat().st_blocks * 512 if artifact.exists() else 0
    for path in top:
        snap = entries[path]["snapshot"] if path in entries else snapshot(path)
        if snap is not None:
            total += snap["bytes"]
    diagnostic_candidates = sum(c["bytes"] for c in candidates if c["kind"] == "diagnostics")
    protected_bytes = total - diagnostic_candidates
    remaining, selected = total, []
    cutoff = now - policy["retentionDays"] * 86400
    for candidate in sorted(candidates, key=lambda c: (c["modified"], c["paths"])):
        expired = candidate["modified"] < cutoff
        over_budget = candidate["kind"] == "diagnostics" and remaining > policy["diagnosticBudgetBytes"]
        if expired or over_budget:
            selected.append(candidate | {"reason": "expired" if expired else "diagnostic budget"})
            if candidate["kind"] == "diagnostics":
                remaining -= candidate["bytes"]
        else:
            retained.append(candidate | {"reason": "recent diagnostics or cache"})
    print(f"Cleanup inventory: inspected {len(entries)} owned entries and {len(cache_directories)} caches", file=sys.stderr, flush=True)
    return {"schemaVersion": 2, "checkout": str(root), "policy": policy, "diagnosticBytes": total,
            "protectedDiagnosticBytes": max(0, protected_bytes), "diagnosticBytesComplete": not errors,
            "reclaimableDiagnosticBytes": sum(c["bytes"] for c in selected if c["kind"] == "diagnostics"),
            "projectedDiagnosticBytes": remaining, "protectedExcessBytes": max(0, remaining - policy["diagnosticBudgetBytes"]),
            "candidates": selected, "retained": retained, "discoveryErrors": errors, "protectionToken": token,
            "protectedPaths": [str(p) for p in protected],
            "estimatedReclaimableBytes": sum(c["bytes"] for c in selected)}


def public_report(report):
    return {key: ([{k: v for k, v in item.items() if k not in {"snapshots", "resources", "modified"}} for item in value]
                  if isinstance(value, list) else value) for key, value in report.items() if key not in {"protectionToken", "protectedPaths"}}


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
    tracked = set(session.git(root, "ls-files", "-z").split("\0"))
    if set(current["files"]) - tracked:
        return None, "uncommitted-build-inputs"
    expected = dict(workflow.full_profile(root))
    steps = value.get("steps", [])
    names = [step.get("name") for step in steps]
    selected = value.get("selectedChecks", [])
    if set(selected) != set(expected) or len(selected) != len(expected) or set(names) != set(expected) or len(names) != len(expected):
        return None, "incomplete-profile"
    toolchain = session.cache_paths(root)["toolchain"]
    for step in steps:
        command = expected[step["name"]]
        if pathlib.Path(command[0]).name == "xcodebuild.sh" and not step.get("receipt"):
            return None, "missing-child-receipt"
        if step.get("receipt"):
            child_path = pathlib.Path(step["receipt"])
            child_path = child_path if child_path.is_absolute() else root / child_path
            if not child_path.resolve().is_relative_to(artifact.resolve()):
                return None, "child-receipt-outside-checkout"
            child = read_json(child_path, {})
            if child.get("status") != "passed" or child.get("evidence", {}).get("status") != "valid":
                return None, "invalid-child-evidence"
    if session.final_cache_problems(value, root):
        return None, "final-cache-products-changed"
    caches = session.workflow_cache_snapshots(value, root)
    for step in steps:
        command = expected[step["name"]]
        if not session.command_matches(step, command) or step.get("status") != "passed" or step.get("evidenceStatus") != "valid" or step.get("toolchain") != toolchain or session.changed_inputs(step.get("inputsAfter", {}), current):
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
            if session.receipt_artifact_problems(child, root, caches):
                return None, "child-artifacts-changed"
        if any(identity is None or session.tree_identity(path) != identity for path, identity in step.get("outputs", {}).items()):
            return None, "workflow-output-changed"
    stage = next(step for step in steps if step["name"] == "stage-debug")
    app = root / "build/GitX.app"
    if not app.is_dir() or app.is_symlink() or stage.get("outputs", {}).get(str(app)) != session.tree_identity(app):
        return None, "staged-app-does-not-match"
    return pending, None


def proof_resources(root, receipt):
    import dev_workflow as workflow
    resources = {str(pathlib.Path(receipt).resolve().parent), str(root / "build/GitX.app"),
                 str(records.common_directory(root) / "ledger.json"), str(pending_path(root))}
    value = read_json(receipt, {})
    for step in value.get("steps", []):
        if step.get("receipt"):
            path = pathlib.Path(step["receipt"])
            resources.add(str((path if path.is_absolute() else root / path).resolve().parent))
    for _, command in workflow.full_profile(root):
        if pathlib.Path(command[0]).suffix == ".sh":
            # Cleanup validates products; it never needs the console session.
            resources.update(r for r in session.entry_resources(pathlib.Path(command[0]).name, command[1:], root)[0]
                             if not r.startswith("desktop:"))
    return resources


def journal_paths(value, directory):
    if value.get("schemaVersion") != 1 or value.get("state") not in {"prepared", "quarantined", "complete"}:
        raise ValueError("Unrecognized deletion journal")
    original, quarantine = pathlib.Path(value["originalPath"]), pathlib.Path(value["quarantinePath"])
    if (not original.is_absolute() or original.parent != quarantine.parent or
            not re.fullmatch(r"\.gitx-cleanup-trash-[0-9a-f]{32}", quarantine.name) or
            original.name.startswith(".gitx-cleanup-trash-") or overlap(original, directory)):
        raise ValueError("Invalid deletion journal paths")
    authorization = value.get("authorization", {})
    if not isinstance(authorization, dict) or not authorization.get("head") or not authorization.get("checkout"):
        raise ValueError("Deletion authorization is missing")
    root = pathlib.Path(authorization["checkout"])
    if not root.is_absolute() or state_directory(root) != directory:
        raise ValueError("Deletion journal belongs to another checkout")
    artifact = session.verification_artifact_root(root)
    cache = session.verification_cache_root(root) / session.digest(str(root.resolve()).encode())[:16]
    if not any(original.is_relative_to(base) and original != base for base in (artifact, root / "build", cache)):
        raise ValueError("Deletion journal is outside managed output")
    if overlap(original, root / "build/GitX.app"):
        raise ValueError("Deletion journal targets the staged app")
    if original.parent.resolve() != original.parent or directory_identity(original.parent) != value["parentIdentity"]:
        raise ValueError("Deletion parent was redirected or replaced")
    return original, quarantine


def persist_journal(path, value):
    session.atomic_json(path, value)
    descriptor = os.open(pathlib.Path(path).parent, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def rename_exclusive(original, quarantine):
    """The destination must remain absent throughout the atomic rename."""
    library = ctypes.CDLL(None, use_errno=True)
    if sys.platform == "darwin":
        rename = library.renamex_np
        rename.argtypes = (ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint)
        arguments = (os.fsencode(original), os.fsencode(quarantine), 0x00000004)  # RENAME_EXCL
    elif hasattr(library, "renameat2"):
        rename = library.renameat2
        rename.argtypes = (ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint)
        arguments = (-100, os.fsencode(original), -100, os.fsencode(quarantine), 1)  # AT_FDCWD, RENAME_NOREPLACE
    else:
        raise ValueError("This platform cannot guarantee an exclusive quarantine rename")
    rename.restype = ctypes.c_int
    if rename(*arguments) != 0:
        error = ctypes.get_errno()
        raise OSError(error, os.strerror(error), str(quarantine))
    descriptor = os.open(pathlib.Path(original).parent, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def prepare_journal(path, snapshot, root, receipt, pending, protection):
    path = pathlib.Path(path)
    directory = state_directory(root)
    identity = uuid.uuid4().hex
    quarantine = path.with_name(".gitx-cleanup-trash-" + identity)
    value = {"schemaVersion": 1, "state": "prepared", "originalPath": str(path),
             "quarantinePath": str(quarantine), "directoryIdentity": snapshot["directory"],
             "parentIdentity": directory_identity(path.parent), "createdAt": records.now(),
             "authorization": {"checkout": str(root), "head": pending["head"], "pendingToken": pending["token"],
                               "receipt": str(receipt), "receiptIdentity": session.tree_identity(receipt),
                               "snapshot": snapshot, "protection": protection}}
    journal = directory / "journals" / (identity + ".json")
    persist_journal(journal, value)
    return journal, value


def quarantine_journal(journal, value, directory):
    original, quarantine = journal_paths(value, directory)
    def matches(path):
        return (not path.is_symlink() and path.exists() and
                directory_identity(path) == value["directoryIdentity"])
    if quarantine.exists() or quarantine.is_symlink():
        if not matches(quarantine) or original.exists() or original.is_symlink():
            raise ValueError("Quarantine or original path was redirected")
    elif original.exists() or original.is_symlink():
        if not matches(original) or fingerprint(original) != value["authorization"]["snapshot"]:
            raise ValueError("Original directory changed before quarantine")
        rename_exclusive(original, quarantine)
        if not matches(quarantine):
            raise ValueError("Quarantine identity changed during rename")
    else:
        value.update(state="complete", finishedAt=records.now())
        persist_journal(journal, value)
        return None
    value["state"] = "quarantined"
    persist_journal(journal, value)
    return quarantine


def finish_journal(journal, value, directory):
    _, quarantine = journal_paths(value, directory)
    if quarantine.is_symlink() or directory_identity(quarantine) != value["directoryIdentity"]:
        raise ValueError("Refusing redirected quarantine")
    if value["directoryIdentity"]["mode"] == stat.S_IFDIR:
        shutil.rmtree(quarantine)
    elif value["directoryIdentity"]["mode"] == stat.S_IFREG:
        quarantine.unlink()
    else:
        raise ValueError("Quarantined object is not a directory or regular file")
    value.update(state="complete", finishedAt=records.now())
    persist_journal(journal, value)


def run_cleanup(root, receipt, inherited=None):
    root = pathlib.Path(root).resolve()
    _, initial_reason = eligibility(root, receipt)
    if initial_reason:
        return {"status": "deferred", "reason": initial_reason}
    directory = state_directory(root)
    proof = proof_resources(root, receipt)
    owner = {"runId": "cleanup-" + uuid.uuid4().hex[:12], "pid": os.getpid(), "receipt": str(receipt),
             "producer": session.producer_identity()}
    # Only cleanup state stays owned during discovery and filesystem removal.
    with session.Leases([str(directory)], owner, inherited=inherited) as outer:
        authenticated = dict(inherited or {}) | outer.held
        with session.Leases(proof, owner, inherited=authenticated):
            pending, reason = eligibility(root, receipt)
            if reason:
                return {"status": "deferred", "reason": reason}
        report = inventory(root, receipt)
        report.update(status="complete", committedHead=pending["head"], receipt=str(receipt),
                      deleted=[], skipped=[], failed=[], reclaimedBytes=0, startedAt=records.now())
        removed = set()
        def gate():
            _, reason = eligibility(root, receipt)
            if reason or read_json(pending_path(root)) != pending:
                return reason or "newer commit queued"
            current = protection_token(root)
            expected = report["protectionToken"]
            if expected is None:
                return "protection-discovery-incomplete"
            def remaining(value):
                return value | {kind: {p: v for p, v in value[kind].items()
                                       if not any(pathlib.Path(p).is_relative_to(q) for q in removed)}
                                for kind in ("files", "objects")}
            expected, current = remaining(expected), remaining(current)
            # Missing metadata belonging to this cleanup's quarantined objects
            # is expected. Other changes invalidate the protection boundary.
            if current != expected:
                return "protection-boundaries-changed"
            return None
        if report["discoveryErrors"]:
            report["skipped"] = [c | {"reason": "protection-discovery-incomplete"} for c in report["candidates"]]
        else:
            journals = []
            for path in sorted((directory / "journals").glob("*.json")):
                try:
                    value = read_json(path)
                    if value.get("state") != "complete":
                        journals.append((path, value))
                except (OSError, ValueError, AttributeError) as error:
                    report["failed"].append({"paths": [str(path)], "reason": str(error)})
            for journal, value in journals:
                try:
                    original, quarantine = journal_paths(value, directory)
                    candidate = {"paths": [str(original)], "bytes": value["authorization"]["snapshot"]["bytes"], "journal": str(journal)}
                    if any(overlap(p, q) for p in (original, quarantine) for q in report["protectedPaths"]):
                        raise ValueError("Quarantined object has a current protection reference")
                    with session.Leases([str(original), str(quarantine)], owner, inherited=authenticated) as candidate_lease:
                        with session.Leases(proof, owner, inherited=authenticated | candidate_lease.held):
                            reason = gate()
                            if reason:
                                raise ValueError(reason)
                            target = quarantine_journal(journal, value, directory)
                            removed.update((original, quarantine))
                        if target is not None:
                            finish_journal(journal, value, directory)
                    report["deleted"].append(candidate)
                    report["reclaimedBytes"] += candidate["bytes"]
                except (OSError, ValueError, KeyError, session.ResourceBusy) as error:
                    report["failed"].append({"paths": [value.get("originalPath", str(journal))], "journal": str(journal), "reason": str(error)})
            for index, candidate in enumerate(report["candidates"]):
                paths = [p for p in candidate["paths"] if pathlib.Path(p) not in removed]
                if not paths:
                    continue
                if len(paths) != len(candidate["paths"]):
                    candidate = candidate | {"paths": paths, "snapshots": {p: candidate["snapshots"][p] for p in paths},
                                             "bytes": sum(candidate["snapshots"][p]["bytes"] for p in paths)}
                try:
                    with session.Leases(candidate["resources"], owner, inherited=authenticated) as candidate_lease:
                        prepared = []
                        with session.Leases(proof, owner, inherited=authenticated | candidate_lease.held):
                            reason = gate()
                            if reason:
                                report["skipped"].extend(c | {"reason": reason} for c in report["candidates"][index:])
                                break
                            if any(fingerprint(p) != snapshot for p, snapshot in candidate["snapshots"].items()):
                                report["skipped"].append(candidate | {"reason": "directory changed after inventory"})
                                continue
                            for path in candidate["paths"]:
                                journal, value = prepare_journal(path, candidate["snapshots"][path], root, receipt, pending, report["protectionToken"])
                                target = quarantine_journal(journal, value, directory)
                                removed.update((pathlib.Path(path), pathlib.Path(value["quarantinePath"])))
                                prepared.append((journal, value, target))
                        # Product and ledger ownership ends before potentially
                        # expensive recursive removal. Candidate ownership stays.
                        for journal, value, target in prepared:
                            if target is not None:
                                finish_journal(journal, value, directory)
                        report["deleted"].append(candidate)
                        report["reclaimedBytes"] += candidate["bytes"]
                        print(f"Cleanup removed {candidate['paths']}: approximately {candidate['bytes']} bytes", flush=True)
                except session.ResourceBusy as error:
                    report["skipped"].append(candidate | {"reason": str(error)})
                except (OSError, ValueError, KeyError) as error:
                    report["failed"].append(candidate | {"reason": str(error)})
        with session.Leases(proof, owner, inherited=authenticated):
            _, changed = eligibility(root, receipt)
            report["status"] = "partial" if report["skipped"] or report["failed"] or report["discoveryErrors"] or changed else "complete"
            if changed:
                report["reason"] = changed
            if report["status"] == "complete":
                if read_json(pending_path(root)) == pending:
                    pending_path(root).unlink()
                else:
                    report.update(status="partial", reason="newer commit queued")
        report["finishedAt"] = records.now()
        reports = directory / "reports"
        output = reports / (dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%S%f") + "-" + uuid.uuid4().hex[:8] + ".json")
        session.atomic_json(output, public_report(report))
        completed = []
        for old in sorted(reports.glob("*.json")):
            try:
                if not old.is_symlink() and read_json(old).get("status") == "complete":
                    completed.append(old)
            except (OSError, ValueError, AttributeError):
                continue
        for old in completed[:-report["policy"]["reportLimit"]]:
            old.unlink()
        return public_report(report) | {"report": str(output)}
