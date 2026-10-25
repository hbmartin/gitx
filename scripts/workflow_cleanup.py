"""Conservative, commit-triggered retention of generated verification output.

Discovery is read-only. Deletion requires a current full verification receipt,
resource leases, and a fresh metadata fingerprint. Historical receipts are never
rewritten; their referenced evidence and recovery sources are protected together.
"""
from __future__ import annotations

import contextlib
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
        def leaf_identity():
            try:
                info = path.lstat()
            except FileNotFoundError:
                return None
            if not stat.S_ISREG(info.st_mode):
                raise ValueError(f"Refusing non-regular cleanup queue: {path}")
            return info.st_dev, info.st_ino, info.st_mode, info.st_size, info.st_mtime_ns, info.st_ctime_ns
        before = leaf_identity()
        try:
            existing = read_json(path)
        except (json.JSONDecodeError, UnicodeDecodeError):
            existing = None
        valid = (isinstance(existing, dict) and existing.get("schemaVersion") == 1 and
                 isinstance(existing.get("checkout"), str) and isinstance(existing.get("head"), str) and
                 isinstance(existing.get("token"), str) and bool(existing["token"]))
        if leaf_identity() != before:
            raise ValueError("Cleanup queue changed while being read")
        if valid and existing.get("checkout") == str(root) and existing.get("head") == head:
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


def overlap(left, right):
    """Ancestry is lexical or established by actual filesystem identity, not case folding."""
    left, right = pathlib.Path(os.path.abspath(left)), pathlib.Path(os.path.abspath(right))
    if left == right or left.is_relative_to(right) or right.is_relative_to(left):
        return True
    def identity(path):
        try:
            info = path.stat()
            value = info.st_dev, info.st_ino
        except FileNotFoundError:
            value = None
        return value
    for object_path, descendant in ((left, right), (right, left)):
        key = identity(object_path)
        if key is not None and any(identity(p) == key for p in (descendant, *descendant.parents)):
            return True
    return False


def reference_paths(value, root):
    """Extract path references, including dictionary keys used for output identities."""
    if not isinstance(value, dict) or not isinstance(value.get("evidence", {}), dict):
        raise ValueError("Diagnostic reference metadata must contain objects")
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
    for key in ("receipt", "reusedFrom", "reusedAnalyzerScratch", "artifacts", "buildPaths", "paths", "outputs", "resources",
                "verificationReceipts", "recoverySources", "integrationEvidence"):
        visit(value.get(key, []))
    for step in value.get("steps", []):
        found.update(reference_paths(step, root))
    visit(value.get("evidence", {}).get("results", {}))
    visit(value.get("evidence", {}).get("analyzerScratch", {}))
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


def provenance_text(path):
    """Expected reference documents are strict; arbitrary binary attachments are not prose."""
    path = pathlib.Path(path)
    if path.suffix.lower() in {".png", ".jpg", ".jpeg", ".gif", ".webp", ".pdf", ".ico"}:
        return None
    data = path.read_bytes()
    required = path.suffix.lower() in {".json", ".md", ".txt", ".rst"}
    if b"\0" in data:
        if required:
            raise ValueError(f"Binary data in textual protection metadata: {path}")
        return None
    try:
        return data.decode("utf-8")
    except UnicodeDecodeError:
        if required:
            raise
        return None


def inline_citation_regions(text):
    """Scan plausible inline spans conservatively, without consuming stray delimiters.

    A stray opener makes equal-length pairings ambiguous, so their plausible
    spans may overlap. Balanced spans leave intervening prose uncited. Unmatched
    openers protect the rest of their paragraph; fences remain separate blocks.
    """
    def scan(paragraph):
        runs = []
        offset = 0
        while offset < len(paragraph):
            if paragraph[offset] != '`':
                offset += 1
                continue
            start = offset
            while offset < len(paragraph) and paragraph[offset] == '`':
                offset += 1
            preceding = start - 1
            while preceding >= 0 and paragraph[preceding] == '\\':
                preceding -= 1
            escaped = (start - preceding - 1) % 2 == 1
            runs.append((start, offset, escaped))
            if escaped and offset - start > 1:
                # An escape consumes only the first backtick. The remaining
                # run can open a span; the whole run can still close one.
                runs.append((start + 1, offset, False))
        next_by_length, next_run = {}, {}
        # Reverse indexing avoids a span-by-delimiter quadratic scan.
        for index in range(len(runs) - 1, -1, -1):
            start, end, _ = runs[index]
            length = end - start
            if length in next_by_length:
                next_run[index] = next_by_length[length]
            next_by_length[length] = index
        intervals, ambiguous_lengths, consumed = [], set(), 0
        for index, (start, end, escaped) in enumerate(runs):
            if start < consumed or escaped:
                continue
            if index in next_run:
                closer, closer_end, _ = runs[next_run[index]]
                intervals.append((end, closer))
                consumed = closer_end
            else:
                ambiguous_lengths.add(end - start)
                intervals.append((end, len(paragraph)))
        # A stray delimiter may have consumed a real opener. Include shifted
        # pairings only for that delimiter length, preserving ordinary prose
        # between complete, unambiguous spans.
        for index, (start, end, escaped) in enumerate(runs):
            if not escaped and end - start in ambiguous_lengths and index in next_run:
                intervals.append((end, runs[next_run[index]][0]))
        # Scan the union once, even when several plausible spans overlap.
        merged = []
        for start, end in sorted(intervals):
            if merged and start <= merged[-1][1]:
                merged[-1] = (merged[-1][0], max(end, merged[-1][1]))
            else:
                merged.append((start, end))
        for start, end in merged:
            yield paragraph[start:end]

    paragraph, fence = [], None
    for line in text.splitlines(keepends=True):
        marker = re.match(r" {0,3}(`{3,}|~{3,})([^\r\n]*)", line)
        if fence is not None:
            if marker and marker[1][0] == fence[0] and len(marker[1]) >= fence[1] and not marker[2].strip():
                fence = None
            continue
        if marker and (marker[1][0] == '~' or '`' not in marker[2]):
            yield from scan(''.join(paragraph))
            paragraph = []
            fence = (marker[1][0], len(marker[1]))
        elif not line.strip():
            yield from scan(''.join(paragraph))
            paragraph = []
        else:
            paragraph.append(line)
    yield from scan(''.join(paragraph))


def cited_run_ids(text, value, aliases, artifact, root):
    found = set()
    def visit(item):
        if isinstance(item, dict):
            for key, child in item.items():
                if key == "runId" and isinstance(child, str):
                    found.add(child)
                elif key in {"runIds", "runs"} and isinstance(child, list):
                    found.update(v for v in child if isinstance(v, str))
                visit(child)
        elif isinstance(item, list):
            for child in item:
                visit(child)
    visit(value)
    for match in re.finditer(r"\brun(?:[ -]ids?)?\s*[:=]\s*([`'\"]?[\w.-]+[`'\"]?(?:\s*,\s*[`'\"]?[\w.-]+[`'\"]?)*)", text, re.IGNORECASE):
        found.update(re.findall(r"[\w.-]+", match[1]))
    # Inline code spans are historical provenance, unlike incidental prose.
    if aliases:
        alias_pattern = re.compile(r"(?<![\w.-])(?:" + '|'.join(re.escape(alias) for alias in sorted(aliases)) + r")(?![\w.-])")
        for span in inline_citation_regions(text):
            found.update(match[0] for match in alias_pattern.finditer(span))
    for run_id in aliases:
        # Paths are explicit citations even when the surrounding prose lacks a run-ID label.
        for prefix in (str(artifact), str(artifact.relative_to(root))):
            if re.search(re.escape(prefix) + r"/(?:Coordination/)?" + re.escape(run_id) + r"(?=/|\.json\b|[\s`'\"]|$)", text):
                found.add(run_id)
    return found & set(aliases)


def protection_token(root, *, referrers=None):
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
    paths = list(dict.fromkeys(paths))
    objects = set()
    def references(paths, source):
        objects.update(paths)
        if referrers is not None:
            for referenced in paths:
                referrers.setdefault(str(referenced), set()).add(source)
    for path in paths:
        if path.suffix == ".json" and path.exists():
            value = read_json(path)
            if path.is_relative_to(root) and str(path.relative_to(root)) in provenance:
                value = {"recoverySources": value}
            if isinstance(value, dict):
                if path.name == "ledger.json":
                    if not isinstance(value.get("items"), dict):
                        raise ValueError("Malformed work ledger")
                    for item in value["items"].values():
                        if not isinstance(item, dict):
                            raise ValueError("Malformed work ledger item")
                        references(reference_paths(item, root), ("file", str(path)))
                else:
                    references(reference_paths(value, root), ("file", str(path)))
    trees, tracked = records.worktrees(root), {}
    for tree in trees:
        checkout = pathlib.Path(tree["worktree"])
        selected = [str(checkout / name) for name in (names if checkout == root else session.git(checkout, "ls-files", "-z").split("\0"))
                    if name and any((checkout / name).is_relative_to(base) for base in (artifact, root / "build"))]
        tracked[str(checkout)] = sorted(selected)
        references({pathlib.Path(name) for name in selected}, ("worktree", str(checkout)))
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
    errors, entry_errors, accounting_errors, unknown, entries, entry_identities = [], [], [], [], {}, set()
    identity_cache = {}
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
    def snapshot(path, category="entry"):
        try:
            return fingerprint(path)
        except (OSError, ValueError) as error:
            target = accounting_errors if category == "accounting" else entry_errors
            target.append({"path": str(path), "reason": str(error)})
            if category != "accounting":
                protected[path] = "unreadable or changing output"
                unknown.append({"paths": [str(path)], "reason": "unknown or unreadable entry: " + str(error)})
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
        referrers = {}
        token = protection_token(root, referrers=referrers)
    except (OSError, ValueError, TypeError, AttributeError, KeyError) as error:
        uncertain(root / ".git", error)
        token = None
        referrers = {}
    def native_registrations(discover):
        try:
            return discover(root)
        except OSError as error:
            uncertain(artifact / "NativeSources", error)
            return []
    native_sources = native_registrations(session.registered_native_sources)
    native_completions = native_registrations(session.registered_native_completions)
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
    current_inputs = None
    def add(path, documents):
        try:
            add_entry(path, documents)
        except (OSError, ValueError, TypeError, AttributeError, KeyError) as error:
            uncertain(path, error)
    def add_entry(path, documents):
        nonlocal current_inputs
        identity = directory_identity(path)
        key = identity["device"], identity["inode"]
        if key in entry_identities:
            return
        entry_identities.add(key)
        refs = set().union(*(reference_paths(d, root) for d in documents))
        resources = {path} | {pathlib.Path(v).resolve() for d in documents for v in
                               (d.get("buildPaths", {}) | d.get("paths", {})).values() if isinstance(v, str) and v}
        resources.update(pathlib.Path(v) for d in documents for v in d.get("resources", []) if isinstance(v, str) and not v.startswith("desktop:"))
        unfinished = [d for d in documents if d.get("status") in {"running", "pending"}]
        abandoned = bool(unfinished) and all(session.producer_state(d.get("producer")) == "abandoned" for d in unfinished)
        live = bool(unfinished) and not abandoned
        snap = None if live else snapshot(path)
        if snap and snap["repositories"]:
            protected[path] = "embedded repository or worktree"
        modified = snap["modified"] if snap else path.lstat().st_mtime
        completed = max(date_value(d.get("finishedAt", d.get("startedAt")), modified) for d in documents)
        entries[path] = {"documents": documents, "snapshot": snap, "refs": refs,
                         "directory": identity, "resources": resources, "completed": completed, "live": live}
        if live:
            protected[path] = "live or uncertain unfinished run"
        resumable = [d for d in documents if d.get("schemaVersion") == 2 and d.get("scope") == "full" and
                     d.get("inputsAfter") and d.get("status") != "passed"]
        if resumable and current_inputs is None:
            current_inputs = session.inputs(root)
        if not abandoned and any(d.get("schemaVersion") == 2 and d.get("scope") == "full" and
                d.get("inputsAfter") and not session.changed_inputs(d["inputsAfter"], current_inputs) and
                any(workflow.reusable(step, d["inputsAfter"], step.get("command")) for step in d.get("steps", []))
                for d in resumable):
            protected[path] = "resumable workflow"
    top = children(artifact)
    print(f"Cleanup inventory: inspecting verification output in {artifact}", file=sys.stderr, flush=True)
    for path in top:
        if path.name in {"Coordination", "diagnostics", "Diagnostics", "NativeSources"} or not path.is_dir():
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
        try:
            if path.name == "Diagnostics" and path.is_dir() and not path.is_symlink():
                continue
            value = metadata(path)
            if (not path.is_symlink() and path.suffix == ".json" and isinstance(value, dict) and
                    isinstance(value.get("runId"), str) and (value["runId"] == path.stem or re.fullmatch(re.escape(value["runId"]) + r"-[0-9a-f]{8}", path.stem)) and value.get("receipt") == str(path) and
                    isinstance(value.get("entry"), str) and pathlib.Path(value["entry"]).resolve().is_relative_to(root / "scripts") and
                    ((value.get("evidence", {}).get("inputsBefore", {}).get("root") == str(root)) or
                     (not value.get("evidence") and value.get("schemaVersion") == 2 and
                      value.get("status") == "blocked" and
                      value.get("category") in session.BLOCKED_RECEIPT_CATEGORIES.get(value.get("exitCode"), set()))) and
                    value.get("status") in {"passed", "failed", "running", "blocked", "invalid"}):
                add(path, [value])
            else:
                unknown.append({"paths": [str(path)], "reason": "unmanaged legacy Coordination receipt"})
        except (OSError, ValueError, TypeError, AttributeError, KeyError) as error:
            uncertain(path, error)
    generic_seen = set()
    def generic(path):
        try:
            generic_entry(path)
        except (OSError, ValueError, TypeError, AttributeError, KeyError) as error:
            uncertain(path, error)
    def generic_entry(path):
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
    # Tracked diagnostics protect explicit paths and structured or labeled run-ID citations.
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
            text = provenance_text(root / name)
            if text is None:
                continue
            value = None
            if name.endswith(".json"):
                value = json.loads(text)
                for path in all_paths(value):
                    protected[path] = "tracked diagnostic provenance"
            cited = cited_run_ids(text, value, aliases, artifact, root)
            for run_id in cited:
                for path in aliases[run_id]:
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
    backups = []
    for run in entries:
        if not run.is_dir():
            continue
        try:
            for path in run.glob("previous-*.app"):
                if path.is_dir() and not path.is_symlink():
                    backups.append((path, entries[run]["completed"], path.stat().st_mtime))
        except OSError as error:
            uncertain(run, error)
    if backups:
        protected[max(backups, key=lambda item: item[1:])[0]] = "newest previous-app backup"
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
    indexed = {(entry["directory"]["device"], entry["directory"]["inode"]): path
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
                    except OSError as error:
                        uncertain(ancestor, error)
                        break
                if other is not None:
                    parents[find(other)] = find(path)
                    break
    groups = {}
    for path in entries:
        groups.setdefault(find(path), []).append(path)
    lexical_nodes, lexical_ancestors, inode_nodes, inode_ancestors = {}, {}, {}, {}
    protection_uncertain = False
    def object_key(path):
        if path not in identity_cache:
            try:
                info = path.stat()
                identity_cache[path] = info.st_dev, info.st_ino
            except FileNotFoundError:
                identity_cache[path] = None
        return identity_cache[path]
    def index_protection(path, reason):
        nonlocal protection_uncertain
        path = pathlib.Path(path)
        lexical_nodes.setdefault(path, set()).add(reason)
        for ancestor in (path, *path.parents):
            lexical_ancestors.setdefault(ancestor, set()).add(reason)
        try:
            key = object_key(path)
            if key is not None:
                inode_nodes.setdefault(key, set()).add(reason)
            for ancestor in (path, *path.parents):
                key = object_key(ancestor)
                if key is not None:
                    inode_ancestors.setdefault(key, set()).add(reason)
        except OSError as error:
            protection_uncertain = True
            uncertain(path, error)
    def protection_reasons(path):
        reasons = set(lexical_ancestors.get(path, set()))
        try:
            key = object_key(path)
            reasons.update(inode_ancestors.get(key, set()))
            for ancestor in (path, *path.parents):
                reasons.update(lexical_nodes.get(ancestor, set()))
                reasons.update(inode_nodes.get(object_key(ancestor), set()))
        except OSError as error:
            uncertain(path, error)
            reasons.add("unreadable protection reference")
        if protection_uncertain:
            reasons.add("unreadable protection reference")
        return reasons
    for path, reason in protected.items():
        index_protection(path, reason)
    changed = True
    while changed:
        changed = False
        for members in groups.values():
            if any(protection_reasons(p) for p in members):
                for path in members:
                    for ref in entries[path]["refs"] | {path}:
                        if ref not in protected:
                            protected[ref] = "protected verification dependency"
                            index_protection(ref, protected[ref])
                            changed = True
    candidates, retained = [], list(unknown)
    def consider(paths, kind, snapshots, resources, age):
        reasons = sorted(set().union(*(protection_reasons(p) for p in paths)))
        # Only candidate output stays owned during removal. Shared products
        # and the ledger are leased separately for the short commit gate.
        resources = {q for q in resources if not str(q).startswith("desktop:") and
                     any(q == p or q.is_relative_to(p) for p in paths)} | set(paths)
        candidate = {"paths": [str(p) for p in paths], "kind": kind,
                     "bytes": sum(s["bytes"] for s in snapshots.values()), "modified": age,
                     "snapshots": {str(p): s for p, s in snapshots.items()}, "resources": sorted(str(p) for p in resources)}
        (retained if reasons else candidates).append(candidate | ({"reason": "; ".join(reasons)} if reasons else {}))
    for members in groups.values():
        if any(entries[p]["snapshot"] is None for p in members):
            retained.append({"paths": [str(p) for p in members], "reason": "protected live or unreadable output"})
            continue
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
    build = root / "build"
    if build.resolve() != build:
        retained.append({"paths": [str(build)], "reason": "non-canonical build root"})
        build_children = []
    else:
        build_children = children(build)
    for path in build_children:
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
        if path.is_symlink() or not path.is_dir():
            retained.append({"paths": [str(path)], "reason": "symlink or non-directory cache"})
            continue
        try:
            identity = directory_identity(path)
        except OSError as error:
            entry_errors.append({"path": str(path), "reason": str(error)})
            retained.append({"paths": [str(path)], "reason": "unknown or unreadable cache"})
            continue
        key = identity["device"], identity["inode"]
        if key in cache_seen:
            continue
        cache_seen.add(key)
        reasons = sorted(protection_reasons(path))
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
    try:
        total = artifact.lstat().st_blocks * 512 if artifact.exists() else 0
    except OSError as error:
        accounting_errors.append({"path": str(artifact), "reason": str(error)})
        total = 0
    for path in top:
        if path in entries:
            snap = entries[path]["snapshot"]
            if snap is None:
                accounting_errors.append({"path": str(path), "reason": "retained output was not recursively counted"})
        else:
            snap = snapshot(path, "accounting")
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
            "protectedDiagnosticBytes": max(0, protected_bytes), "diagnosticBytesComplete": not (errors or entry_errors or accounting_errors),
            "reclaimableDiagnosticBytes": sum(c["bytes"] for c in selected if c["kind"] == "diagnostics"),
            "projectedDiagnosticBytes": remaining, "protectedExcessBytes": max(0, remaining - policy["diagnosticBudgetBytes"]),
            "nativeSources": [{"registration": str(path), "paths": [owner["sourceDirectory"]],
                               "reason": "retained native evidence" if owner.get("retirementState") == "retained" else
                                         "complete archive awaiting validation" if owner.get("collectionComplete") else "protected incomplete native archive",
                               "owner": owner} for path, owner in native_sources],
            "nativeCompletions": [{"registration": str(path), "paths": [str(session.native_completion_path(path))]}
                                  for path, _ in native_completions],
            "candidates": selected, "retained": retained, "discoveryErrors": errors, "entryErrors": entry_errors,
            "accountingErrors": accounting_errors, "protectionToken": token, "protectionReferrers": referrers,
            "protectedPaths": [str(p) for p in protected],
            "estimatedReclaimableBytes": sum(c["bytes"] for c in selected)}


def public_report(report):
    return {key: ([{k: v for k, v in item.items() if k not in {"snapshots", "resources", "modified"}} for item in value]
                  if isinstance(value, list) else value) for key, value in report.items() if key not in {"protectionToken", "protectedPaths", "protectionReferrers"}}


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
    # Local diff preferences must not hide dependency edits from the commit gate.
    if session.git(root, "diff", "HEAD", "--binary", "--ignore-submodules=none"):
        return None, "uncommitted-tracked-changes"
    tracked = set(session.git(root, "ls-files", "-z").split("\0"))
    if set(current["files"]) - tracked:
        return None, "uncommitted-build-inputs"
    expected = dict(workflow.full_profile(root))
    try:
        steps = session.active_workflow_steps(value, require_selected_checks=True)
    except ValueError:
        return None, "incomplete-profile"
    selected = value["selectedChecks"]
    names = [step.get("name") for step in steps]
    if set(selected) != set(expected) or len(selected) != len(expected) or set(names) != set(expected) or len(names) != len(expected):
        return None, "incomplete-profile"
    toolchain = session.cache_paths(root)["toolchain"]
    children, identities = {}, {}
    readers = {"results": session.tree_identity, "products": session.product_identity,
               "packages": session.package_products, "dependencies": session.dependency_products}
    def artifact_identity(kind, path):
        key = kind, os.path.abspath(path)
        if key not in identities:
            identities[key] = readers[kind](path)
        return identities[key]
    def child_receipt(path):
        key = str(pathlib.Path(path).resolve())
        if key not in children:
            children[key] = read_json(path, {})
        return children[key]
    for step in steps:
        command = expected[step["name"]]
        if pathlib.Path(command[0]).name == "xcodebuild.sh" and not step.get("receipt"):
            return None, "missing-child-receipt"
        if step.get("receipt"):
            child_path = pathlib.Path(step["receipt"])
            child_path = child_path if child_path.is_absolute() else root / child_path
            if not child_path.resolve().is_relative_to(artifact.resolve()):
                return None, "child-receipt-outside-checkout"
            child = child_receipt(child_path)
            if not isinstance(child, dict) or child.get("status") != "passed" or child.get("evidence", {}).get("status") != "valid":
                return None, "invalid-child-evidence"
    try:
        caches = session.workflow_cache_snapshots(value, root, receipt_reader=child_receipt)
    except (OSError, ValueError, TypeError, KeyError):
        return None, "final-cache-products-changed"
    if session.final_cache_problems(value, root, derived=caches, identity=artifact_identity):
        return None, "final-cache-products-changed"
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
            child = child_receipt(child_path)
            evidence = child.get("evidence", {})
            if child.get("schemaVersion") != 2 or child.get("status") != "passed" or evidence.get("status") != "valid" or any(
                    session.changed_inputs(evidence.get(key, {}), current) for key in ("inputsBefore", "inputsAfter")):
                return None, "invalid-child-evidence"
            if session.receipt_artifact_problems(child, root, caches, identity=artifact_identity):
                return None, "child-artifacts-changed"
        if any(identity is None or artifact_identity("results", path) != identity for path, identity in step.get("outputs", {}).items()):
            return None, "workflow-output-changed"
    stage = next(step for step in steps if step["name"] == "stage-debug")
    app = root / "build/GitX.app"
    if not app.is_dir() or app.is_symlink() or stage.get("outputs", {}).get(str(app)) != artifact_identity("results", app):
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
    toolchain = session.cache_paths(root)["toolchain"]
    for _, command in workflow.full_profile(root):
        if pathlib.Path(command[0]).suffix == ".sh":
            # Cleanup validates products; it never needs the console session.
            resources.update(r for r in session.entry_resources(pathlib.Path(command[0]).name, command[1:], root, toolchain=toolchain)[0]
                             if not r.startswith("desktop:"))
    return resources


def journal_paths(value, directory):
    if value.get("schemaVersion") != 1 or value.get("state") not in {"prepared", "quarantined", "complete"}:
        raise ValueError("Unrecognized deletion journal")
    original, quarantine = pathlib.Path(value["originalPath"]), pathlib.Path(value["quarantinePath"])
    if (not original.is_absolute() or pathlib.Path(os.path.normpath(original)) != original or
            pathlib.Path(os.path.normpath(quarantine)) != quarantine or original.parent != quarantine.parent or
            not re.fullmatch(r"\.gitx-cleanup-trash-[0-9a-f]{32}", quarantine.name) or
            original.name.startswith(".gitx-cleanup-trash-") or overlap(original, directory)):
        raise ValueError("Invalid deletion journal paths")
    authorization = value.get("authorization", {})
    if not isinstance(authorization, dict) or not authorization.get("head") or not authorization.get("checkout"):
        raise ValueError("Deletion authorization is missing")
    snapshot = authorization.get("snapshot", {})
    identity = value.get("directoryIdentity", {})
    parent = value.get("parentIdentity", {})
    if (not isinstance(snapshot, dict) or not isinstance(identity, dict) or not isinstance(parent, dict) or
            any(type(data.get(key)) is not int for data in (identity, parent) for key in ("device", "inode", "mode", "birthNs")) or
            identity.get("mode") not in {stat.S_IFDIR, stat.S_IFREG} or parent.get("mode") != stat.S_IFDIR or
            snapshot.get("directory") != identity or type(snapshot.get("bytes")) is not int or snapshot["bytes"] < 0 or
            not isinstance(snapshot.get("identity"), str) or not snapshot["identity"] or
            not isinstance(authorization.get("receiptIdentity"), dict) or not authorization["receiptIdentity"].get("sha256") or
            any(not isinstance(authorization.get(key), str) or not authorization[key]
                for key in ("receipt", "pendingToken"))):
        raise ValueError("Deletion journal identities or snapshot are invalid")
    root = pathlib.Path(authorization["checkout"])
    if not root.is_absolute() or state_directory(root) != directory:
        raise ValueError("Deletion journal belongs to another checkout")
    artifact = session.verification_artifact_root(root)
    cache = session.verification_cache_root(root) / session.digest(str(root.resolve()).encode())[:16]
    if not any(original.is_relative_to(base) and original != base for base in (artifact, root / "build", cache)):
        raise ValueError("Deletion journal is outside managed output")
    if overlap(original, root / "build/GitX.app"):
        raise ValueError("Deletion journal targets the staged app")
    digest = authorization.get("protectionDigest")
    if digest is not None and (not isinstance(digest, str) or not re.fullmatch(r"[0-9a-f]{64}", digest)):
        raise ValueError("Invalid deletion protection digest")
    if not any(path.exists() or path.is_symlink() for path in (original, quarantine)):
        # Completing metadata for absent objects cannot delete a redirected parent's contents.
        return original, quarantine
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
    try:
        session.exclusive_native_rename(original, quarantine, sync_parent=True)
    except session.ExclusiveRenameUnavailable as error:
        raise ValueError("This platform cannot guarantee an exclusive quarantine rename") from error


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
                               "snapshot": snapshot, "protectionDigest": protection_digest(protection)}}
    journal = directory / "journals" / (identity + ".json")
    journal_paths(value, directory)
    if directory_identity(path) != snapshot["directory"]:
        raise ValueError("Original object changed before journal preparation")
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


def protection_digest(token):
    return session.digest(json.dumps(token, sort_keys=True, separators=(",", ":")).encode())


class JournalCompletionError(OSError):
    """Removal succeeded, but its durable journal completion could not be published."""
    def __init__(self, journal, reclaimed_bytes, error):
        self.journal = str(journal)
        self.reclaimed_bytes = reclaimed_bytes
        super().__init__("Removal succeeded; journal completion failed: " + str(error))


def finish_journal(journal, value, directory):
    original, quarantine = journal_paths(value, directory)
    if quarantine.is_symlink() or directory_identity(quarantine) != value["directoryIdentity"]:
        raise ValueError("Refusing redirected quarantine")
    if original.exists() or original.is_symlink():
        raise ValueError("Original path reappeared before quarantine removal")
    remaining_bytes = fingerprint(quarantine)["bytes"]
    if value["directoryIdentity"]["mode"] == stat.S_IFDIR:
        shutil.rmtree(quarantine)
    elif value["directoryIdentity"]["mode"] == stat.S_IFREG:
        quarantine.unlink()
    else:
        raise ValueError("Quarantined object is not a directory or regular file")
    if quarantine.exists() or quarantine.is_symlink():
        raise ValueError("Quarantine remains after removal; journal completion refused")
    try:
        if original.exists() or original.is_symlink():
            raise ValueError("Original path reappeared after quarantine removal")
        value.update(state="complete", finishedAt=records.now())
        persist_journal(journal, value)
    except (OSError, ValueError) as error:
        raise JournalCompletionError(journal, remaining_bytes, error) from error
    return remaining_bytes


def protection_matches(expected, current, removed, referrers):
    def removed_path(path):
        return any(pathlib.Path(path).is_relative_to(base) for base in removed)
    def remaining(value):
        return value | {kind: {p: v for p, v in value[kind].items() if not removed_path(p)}
                        for kind in ("files", "objects")}
    expected, current = remaining(expected), remaining(current)
    if {k: v for k, v in expected.items() if k != "objects"} != {k: v for k, v in current.items() if k != "objects"}:
        return False
    if any(path not in expected["objects"] or identity != expected["objects"][path]
           for path, identity in current["objects"].items()):
        return False
    for path in expected["objects"].keys() - current["objects"].keys():
        sources = referrers.get(path, set())
        if not sources or any(kind != "file" or not removed_path(source) for kind, source in sources):
            return False
    return True


def rotate_history(directory, limit, current_report):
    """Bound managed history while retaining every incomplete or unrecognized journal."""
    for folder, key, accepted in (("reports", "status", {"complete", "partial", "failed", "interrupted"}),
                                  ("journals", "state", {"complete"})):
        entries = []
        for path in (directory / folder).glob("*.json"):
            try:
                if path.is_symlink() or not path.is_file():
                    continue
                value = read_json(path)
                if not isinstance(value, dict) or value.get(key) not in accepted:
                    continue
                if folder == "journals" and value.get("schemaVersion") != 1:
                    continue
                if folder == "journals":
                    journal_paths(value, directory)
                info = path.stat()
                finished = date_value(value.get("finishedAt"), info.st_mtime)
                entries.append((path == current_report, finished, info.st_mtime_ns, str(path), path, directory_identity(path)))
            except (OSError, ValueError, TypeError, AttributeError, KeyError):
                continue
        for *_, path, identity in sorted(entries, reverse=True)[limit:]:
            try:
                if not path.is_symlink() and directory_identity(path) == identity:
                    path.unlink()
            except OSError:
                continue


def run_cleanup(root, receipt, inherited=None, *, retry_retained_native=False):
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
        authenticated = dict(outer.inherited) | outer.held
        with session.Leases(proof, owner, inherited=authenticated):
            pending, reason = eligibility(root, receipt)
            if reason:
                return {"status": "deferred", "reason": reason}
        report = inventory(root, receipt)
        report.update(status="complete", committedHead=pending["head"], receipt=str(receipt),
                      deleted=[], recovered=[], skipped=[], failed=[], reclaimedBytes=0, startedAt=records.now())
        removed, removed_originals = set(), set()
        def removed_original_problem():
            return "removed-output-reappeared" if any(path.exists() or path.is_symlink() for path in removed_originals) else None
        def finish_removal(candidate, journal, value):
            failure = None
            try:
                reclaimed = finish_journal(journal, value, directory)
            except JournalCompletionError as error:
                reclaimed, failure = error.reclaimed_bytes, error
            item = candidate | {"paths": [value["originalPath"]], "bytes": reclaimed, "journal": str(journal)}
            report["deleted"].append(item)
            report["reclaimedBytes"] += reclaimed
            print(f"Cleanup removed {item['paths']}: approximately {reclaimed} bytes", flush=True)
            if failure:
                raise failure
        def remaining_candidate(candidate):
            completed = {path for item in report["deleted"] + report["recovered"] for path in item["paths"]}
            paths = [path for path in candidate["paths"] if path not in completed]
            return candidate | {"paths": paths, "bytes": sum(candidate["snapshots"][path]["bytes"] for path in paths)}
        def gate():
            _, reason = eligibility(root, receipt)
            if reason or read_json(pending_path(root)) != pending:
                return reason or "newer commit queued"
            if problem := removed_original_problem():
                return problem
            expected = report["protectionToken"]
            if expected is None:
                return "protection-discovery-incomplete"
            current = protection_token(root)
            if not protection_matches(expected, current, removed, report["protectionReferrers"]):
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
                    selected = next((c for c in report["candidates"] if str(original) in c["paths"]), None)
                    resources = [str(original), str(quarantine)] + (selected["resources"] if selected else [])
                    with session.Leases(resources, owner, inherited=authenticated) as candidate_lease:
                        with session.Leases(proof, owner, inherited=authenticated | candidate_lease.held):
                            reason = gate()
                            if reason:
                                raise ValueError(reason)
                            # A prepared original still needs current retention authorization.
                            # An already-renamed quarantine retains its recovery ownership.
                            if original.exists() or original.is_symlink():
                                if selected is None:
                                    raise ValueError("Original directory is no longer eligible for cleanup")
                                snapshot = selected["snapshots"][str(original)]
                                if fingerprint(original) != snapshot:
                                    raise ValueError("Original directory changed after inventory")
                                value["authorization"].update(head=pending["head"], pendingToken=pending["token"],
                                                              receipt=str(receipt), receiptIdentity=session.tree_identity(receipt),
                                                              snapshot=snapshot, protectionDigest=protection_digest(report["protectionToken"]))
                                value["authorization"].pop("protection", None)
                                persist_journal(journal, value)
                                candidate["bytes"] = snapshot["bytes"]
                            target = quarantine_journal(journal, value, directory)
                            removed.update((original, quarantine))
                            removed_originals.add(original)
                        if target is not None:
                            finish_removal(candidate, journal, value)
                        else:
                            report["recovered"].append(candidate | {"bytes": 0})
                except (OSError, ValueError, KeyError, session.ResourceBusy) as error:
                    paths = [str(journal)] if isinstance(error, JournalCompletionError) else [value.get("originalPath", str(journal))]
                    report["failed"].append({"paths": paths, "journal": str(journal), "reason": str(error)})
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
                            if any(fingerprint(p) != snapshot for p, snapshot in candidate["snapshots"].items()):
                                report["skipped"].append(candidate | {"reason": "directory changed after inventory"})
                                continue
                            for path in candidate["paths"]:
                                # Each rename gets fresh authorization, including within linked groups.
                                reason = gate()
                                if reason:
                                    for remaining in report["candidates"][index:]:
                                        pending_paths = [p for p in remaining["paths"] if pathlib.Path(p) not in removed]
                                        if pending_paths:
                                            report["skipped"].append(remaining | {"paths": pending_paths, "reason": reason})
                                    break
                                journal, value = prepare_journal(path, candidate["snapshots"][path], root, receipt, pending, report["protectionToken"])
                                target = quarantine_journal(journal, value, directory)
                                removed.update((pathlib.Path(path), pathlib.Path(value["quarantinePath"])))
                                removed_originals.add(pathlib.Path(path))
                                prepared.append((journal, value, target))
                        # Product and ledger ownership ends before potentially
                        # expensive recursive removal. Candidate ownership stays.
                        for journal, value, target in prepared:
                            if target is not None:
                                finish_removal(candidate, journal, value)
                            else:
                                report["recovered"].append({"paths": [value["originalPath"]], "bytes": 0, "journal": str(journal)})
                        if reason:
                            break
                except session.ResourceBusy as error:
                    report["skipped"].append(candidate | {"reason": str(error)})
                except (OSError, ValueError, KeyError) as error:
                    failed = remaining_candidate(candidate) | {"reason": str(error)}
                    if isinstance(error, JournalCompletionError):
                        failed["journal"] = error.journal
                        if not failed["paths"]:
                            failed["paths"] = [error.journal]
                    report["failed"].append(failed)
        report["nativeRetirement"] = []
        report["nativeHandoffs"] = []
        def native_protection_reason(paths, protected_reason):
            if any(overlap(candidate, path) for candidate in paths for path in report["protectedPaths"]):
                return protected_reason
            return None
        def native_admission_reason(paths, protected_reason):
            # Refusal needs no cached authority; every accepted mutation still
            # acquires its own current proof below.
            if read_json(pending_path(root)) != pending:
                return "newer commit queued"
            if session.git(root, "rev-parse", "HEAD").strip() != pending["head"]:
                return "commit-or-inputs-changed"
            if report["discoveryErrors"]:
                return "protection-discovery-incomplete"
            return native_protection_reason(paths, protected_reason)
        for item in report.get("nativeSources", []):
            @contextlib.contextmanager
            def authorize_native_retirement():
                with session.Leases(proof, owner, inherited=authenticated):
                    reason = gate()
                    source = pathlib.Path(item["owner"]["sourceDirectory"])
                    completion = session.native_completion_path(item["registration"])
                    reason = reason or native_protection_reason((source, completion), "protected native source")
                    if reason:
                        raise session.NativeRetirementDeferred(reason)
                    yield
            def admit_native_retirement():
                paths = (pathlib.Path(item["owner"]["sourceDirectory"]), session.native_completion_path(item["registration"]))
                return native_admission_reason(paths, "protected native source")
            state, reason, registered = session.retire_registered_native_sources(
                item["registration"], checkout=root, authorize=authorize_native_retirement,
                admit=admit_native_retirement, retry_retained=retry_retained_native)
            report["nativeRetirement"].append({"paths": item["paths"], "state": state, "reason": reason,
                                               "outcome": (registered or {}).get("retirementOutcome")})
            if registered and "handoffCleanup" in registered:
                report["nativeHandoffs"].append({"registration": item["registration"], **registered["handoffCleanup"]})
        for item in report.get("nativeCompletions", []):
            def admit_native_handoff():
                return native_admission_reason((session.native_completion_path(item["registration"]),), "protected native handoff")
            @contextlib.contextmanager
            def authorize_native_handoff():
                with session.Leases(proof, owner, inherited=authenticated):
                    reason = admit_native_handoff() or gate()
                    if reason:
                        raise session.NativeRetirementDeferred(reason)
                    yield
            state, reason, registered = session.retire_registered_native_sources(
                item["registration"], checkout=root, authorize=authorize_native_handoff, admit=admit_native_handoff)
            outcome = (registered or {}).get("handoffCleanup")
            if not isinstance(outcome, dict):
                failure = (registered or {}).get("retirementOutcome")
                outcome = (failure if isinstance(failure, dict) and failure.get("state") in {"deferred", "retained"} else
                           {"state": "deferred", "reason": reason or "retirement-unconfirmed"})
            report["nativeHandoffs"].append({"registration": item["registration"], **outcome})
        reports = directory / "reports"
        output = reports / (dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%S%f") + "-" + uuid.uuid4().hex[:8] + ".json")
        saved = False
        try:
            with session.Leases(proof, owner, inherited=authenticated):
                _, changed = eligibility(root, receipt)
                if read_json(pending_path(root)) != pending:
                    changed = "newer commit queued"
                changed = changed or removed_original_problem()
                native_deferred = any(item["state"] not in {"retired", "retained"} for item in report["nativeRetirement"])
                handoff_deferred = any(item["state"] not in {"removed", "absent", "retained"} for item in report["nativeHandoffs"])
                report["status"] = "partial" if (report["skipped"] or report["failed"] or report["discoveryErrors"] or
                                                 report["entryErrors"] or native_deferred or handoff_deferred or changed) else "complete"
                if changed:
                    report["reason"] = changed
                elif report["failed"]:
                    report["reason"] = report["failed"][0]["reason"]
                elif native_deferred:
                    report["reason"] = "native retirement deferred"
                elif handoff_deferred:
                    report["reason"] = "native handoff cleanup deferred"
                if report["status"] == "complete" and read_json(pending_path(root)) != pending:
                    report.update(status="partial", reason="newer commit queued")
                report["finishedAt"] = records.now()
                # Durable deletion history precedes queue clearing; proof ownership covers both.
                persist_journal(output, public_report(report))
                saved = True
                if report["status"] == "complete":
                    pending_path(root).unlink()
        except (session.ResourceBusy, OSError, ValueError, KeyError) as error:
            report.update(status="partial", reason=str(error), finishedAt=records.now())
            saved = False
        if not saved:
            persist_journal(output, public_report(report))
        rotate_history(directory, report["policy"]["reportLimit"], output)
        return public_report(report) | {"report": str(output)}
