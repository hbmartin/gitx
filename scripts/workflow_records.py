"""Repository-local work inventory and review provenance; no network writes."""
from __future__ import annotations

import datetime as dt
import hashlib
import json
import os
import pathlib
import re
import subprocess
import uuid

import workflow_session as session


def now():
    return dt.datetime.now(dt.timezone.utc).isoformat()


def common_directory(root):
    value = session.git(root, "rev-parse", "--path-format=absolute", "--git-common-dir")
    if not value:
        raise ValueError(f"Not a Git repository: {root}")
    return pathlib.Path(value) / "gitx-workflow"


def resolve(root, target):
    if not target:
        return None
    return session.git(root, "rev-parse", "--verify", f"{target}^{{commit}}") or None


def patch_id(root, base, head):
    diff = subprocess.run(["git", "-C", str(root), "diff", base, head], capture_output=True, env=session.git_environment())
    if diff.returncode or not diff.stdout:
        return None
    result = subprocess.run(["git", "patch-id", "--stable"], input=diff.stdout, capture_output=True, env=session.git_environment())
    return result.stdout.decode().split()[0] if result.stdout.split() else None


def worktrees(root):
    records = []
    for block in session.git(root, "worktree", "list", "--porcelain").split("\n\n"):
        record = {}
        for line in block.splitlines():
            key, _, value = line.partition(" ")
            record[key] = value
        if "worktree" in record:
            records.append(record)
    return records


class Ledger:
    def __init__(self, root=session.ROOT):
        self.root = pathlib.Path(root).resolve()
        self.path = common_directory(root) / "ledger.json"
        self.lease = None

    def __enter__(self):
        owner = {"runId": "ledger-" + uuid.uuid4().hex[:12], "pid": os.getpid(), "receipt": str(self.path)}
        self.lease = session.Leases([str(self.path)], owner)
        self.lease.__enter__()
        self.data = json.loads(self.path.read_text()) if self.path.exists() else {
            "schemaVersion": 1, "repository": str(self.root), "items": {}, "scans": []}
        if self.data.get("schemaVersion") != 1:
            raise ValueError("Unsupported ledger version")
        return self

    def __exit__(self, *_):
        self.lease.__exit__()

    def save(self):
        self.data["updatedAt"] = now()
        session.atomic_json(self.path, self.data)

    def register(self, identity, purpose, owner=None, chat=None, branch=None, worktree=None, base=None):
        if identity in self.data["items"]:
            raise ValueError(f"Work item already registered: {identity}; use update")
        path = pathlib.Path(worktree or self.root).resolve()
        head = resolve(path, "HEAD")
        self.data["items"][identity] = {
            "id": identity, "purpose": purpose, "owner": owner, "chat": chat,
            "branch": branch or session.git(path, "branch", "--show-current"),
            "worktree": str(path), "base": resolve(self.root, base) if base else head,
            "head": head, "lifecycle": "active", "verificationReceipts": [],
            "recoverySources": [], "integrationEvidence": [], "conclusions": {"featureEquivalence": "needs-review"}}
        self.save()
        return self.data["items"][identity]

    def update(self, identity, changes, owner=None):
        item = self.data["items"][identity]
        if item.get("owner") and owner != item["owner"]:
            raise ValueError(f"Work is owned by {item['owner']}; supply that owner to update its conclusions")
        allowed = {"purpose", "owner", "chat", "branch", "worktree", "base", "lifecycle",
                   "verificationReceipts", "recoverySources", "integrationEvidence", "conclusions"}
        if set(changes) - allowed:
            raise ValueError("Observed Git facts cannot be supplied as human conclusions")
        item.update(changes)
        self.save()
        return item

    def seed(self, manifest):
        manifest = pathlib.Path(manifest).resolve()
        payload = json.loads(manifest.read_text())
        for record in payload.get("records", []):
            identity = "recovery-" + session.digest(record["path"].encode())[:16]
            if identity in self.data["items"] or record.get("action") == "retained":
                continue
            archive = manifest.parent / record["archive"] if record.get("archive") else None
            sources = [{"path": str(manifest), "identity": session.file_identity(manifest)}]
            if archive:
                sources.append({"path": str(archive), "sha256": record.get("archive_sha256"), "exists": archive.exists()})
            report = manifest.parent / "review-2026-10-06/review.html"
            if report.exists():
                sources.append({"path": str(report), "identity": session.file_identity(report), "role": "prior-review"})
            self.data["items"][identity] = {"id": identity, "purpose": "Archived work requiring integration review",
                "owner": None, "chat": None, "branch": record.get("saved_ref"), "worktree": record["path"],
                "base": None, "head": record.get("head"), "lifecycle": "archived", "verificationReceipts": [],
                "recoverySources": sources, "integrationEvidence": [], "conclusions": {"featureEquivalence": "needs-review"}}
        self.save()

    def inventory(self):
        head = resolve(self.root, "HEAD")
        previous = self.data.get("scans", [])[-1].get("observations", {}) if self.data.get("scans") else {}
        for tree in worktrees(self.root):
            path = str(pathlib.Path(tree["worktree"]).resolve())
            if any(item.get("worktree") == path and item.get("lifecycle") != "archived" for item in self.data["items"].values()):
                continue
            identity = "checkout-" + session.digest(path.encode())[:16]
            if identity not in self.data["items"]:
                self.register(identity, "Existing checkout; ownership needs review", worktree=path)
        observations = {}
        for identity, item in self.data["items"].items():
            path = pathlib.Path(item["worktree"])
            exists = path.is_dir() and bool(resolve(path, "HEAD"))
            observed_head = resolve(path, "HEAD") if exists else resolve(self.root, item.get("head"))
            base = item.get("base") or (session.git(self.root, "merge-base", head, observed_head) if observed_head else None)
            ancestry = False
            if observed_head:
                ancestry = subprocess.run(["git", "-C", str(self.root), "merge-base", "--is-ancestor", observed_head, head], capture_output=True, env=session.git_environment()).returncode == 0
            facts = {"exists": exists, "head": observed_head, "branch": session.git(path, "branch", "--show-current") if exists else item.get("branch"),
                     "dirtyState": session.git(path, "status", "--porcelain=v1", "--untracked-files=all") if exists else None,
                     "ancestorOfCurrentHead": ancestry,
                     "patchId": patch_id(self.root, base, observed_head) if base and observed_head else None}
            observations[identity] = facts
            item["observed"] = facts
        duplicates = []
        ids = list(observations)
        for index, identity in enumerate(ids):
            for other in ids[index + 1:]:
                a, b = observations[identity], observations[other]
                if a["head"] and a["head"] == b["head"]:
                    duplicates.append({"items": [identity, other], "fact": "identical-commit"})
                elif a["patchId"] and a["patchId"] == b["patchId"]:
                    duplicates.append({"items": [identity, other], "fact": "patch-equivalent", "featureEquivalence": "needs-review"})
        scan = {"scannedAt": now(), "head": head, "observations": observations, "duplicates": duplicates,
                "changedSincePrevious": [identity for identity in observations.keys() | previous.keys()
                                         if observations.get(identity) != previous.get(identity)]}
        self.data["scans"] = (self.data.get("scans", []) + [scan])[-20:]
        self.save()
        return scan

    def export(self, path):
        evidence = {}
        for item in self.data["items"].values():
            for reference in item.get("verificationReceipts", []) + item.get("recoverySources", []):
                reference = reference if isinstance(reference, dict) else {"path": reference}
                source = pathlib.Path(reference["path"])
                # Archive hashes were validated by cleanup; do not reread huge
                # archives during every inventory. Mark recorded hashes as such.
                evidence[str(source)] = {"exists": source.exists(), "identity": reference.get("identity") or
                    ({"sha256": reference["sha256"], "origin": "cleanup-manifest"} if reference.get("sha256") else session.tree_identity(source))}
        payload = {"schemaVersion": 1, "exportedAt": now(), "ledger": self.data, "evidence": evidence}
        session.atomic_json(path, payload)
        return payload

    def import_export(self, path):
        payload = json.loads(pathlib.Path(path).read_text())
        if payload.get("schemaVersion") != 1 or payload.get("ledger", {}).get("schemaVersion") != 1:
            raise ValueError("Unsupported export version")
        for identity, item in payload["ledger"]["items"].items():
            if identity not in self.data["items"]:
                self.data["items"][identity] = item
            elif self.data["items"][identity] != item:
                raise ValueError(f"Import conflicts with local ownership/evidence: {identity}")
        self.save()


def comments_from_json(payload):
    if isinstance(payload, list):
        return payload
    if "comments" in payload and isinstance(payload["comments"], list):
        return payload["comments"]
    comments = []
    def visit(value):
        if isinstance(value, dict):
            if "body" in value and ("id" in value or "url" in value) and not any(key in value for key in ("reviewThreads", "comments", "reviews")):
                comments.append(value)
            else:
                for nested in value.values():
                    visit(nested)
        elif isinstance(value, list):
            for nested in value:
                visit(nested)
    visit(payload)
    return comments


def comment_target(comment):
    # originalCommit is the commit on which the comment was created; commit
    # may be GitHub's remapped current location after pushes.
    for key in ("originalCommit", "original_commit_id", "commit", "commit_id", "review_target_sha"):
        value = comment.get(key)
        if isinstance(value, dict):
            value = value.get("oid")
        if value:
            return value
    return None


def prepare_review(root, source, output, target=None, pasted=False):
    root, source, output = pathlib.Path(root), pathlib.Path(source), pathlib.Path(output)
    comments = [{"id": "pasted-" + session.digest(source.read_bytes())[:16], "body": source.read_text()}] if pasted else comments_from_json(json.loads(source.read_text()))
    if not comments:
        raise ValueError("No review comments found")
    explicit = resolve(root, target)
    candidates = {comment_target(c) for c in comments if comment_target(c)}
    if target:
        candidates.add(target)
        if not explicit and re.fullmatch(r"[0-9a-fA-F]{4,40}", target):
            candidates.update(session.git(root, "rev-parse", "--disambiguate=" + target).splitlines())
    if pasted:
        candidates.update(re.findall(r"\b[0-9a-fA-F]{7,40}\b", source.read_text()))
    candidates = sorted(candidates)
    records, groups = [], {}
    for index, comment in enumerate(comments):
        raw_target = target or comment_target(comment)
        sha = explicit or resolve(root, raw_target)
        identity = str(comment.get("id") or comment.get("url") or f"comment-{index}")
        path = comment.get("path")
        line = comment.get("originalLine") or comment.get("original_line") or comment.get("line")
        key = session.digest(json.dumps([sha, path, line, comment.get("body", "")], sort_keys=True).encode())
        duplicate_of = groups.get(key)
        groups.setdefault(key, identity)
        records.append({"id": identity, "body": comment.get("body", ""), "url": comment.get("url") or comment.get("html_url"),
            "originalLocation": {"path": path, "line": line, "diffHunk": comment.get("diffHunk") or comment.get("diff_hunk")},
            "targetCandidate": raw_target, "reviewedSHA": sha, "duplicateOf": duplicate_of,
            "validityAtTarget": "unverified", "currentActionability": "needs-target" if not sha else "unverified",
            "evidence": [], "disposition": None, "implementingCommit": None})
    payload = {"schemaVersion": 1, "id": "review-" + uuid.uuid4().hex[:12], "preparedAt": now(),
               "source": str(source.resolve()), "sourceIdentity": session.file_identity(source),
               "currentHEAD": resolve(root, "HEAD"), "status": "needs-target" if any(not c["reviewedSHA"] for c in records) else "prepared",
               "recoverableCandidates": [{"candidate": c, "resolved": resolve(root, c)} for c in candidates], "comments": records}
    session.atomic_json(output, payload)
    return payload


def reconcile_review(root, path, decisions=None, refresh=False):
    path = pathlib.Path(path)
    payload = json.loads(path.read_text())
    if payload["status"] == "needs-target" or any(not c.get("reviewedSHA") for c in payload["comments"]):
        raise ValueError("needs-target: supply the exact reviewed commit with review prepare --target; classification is paused")
    current = resolve(root, "HEAD")
    if current != payload["currentHEAD"]:
        payload.update(status="stale", observedHEAD=current)
        if not refresh:
            session.atomic_json(path, payload)
            raise ValueError("HEAD changed; reconcile --refresh and supply refreshed decisions before presenting results as current")
        payload["previousHEAD"] = payload["currentHEAD"]
        payload["currentHEAD"] = current
        for comment in payload["comments"]:
            comment.update(currentActionability="unverified", disposition=None, implementingCommit=None, evidence=[])
    supplied = {str(c["id"]): c for c in decisions or []}
    for comment in payload["comments"]:
        sha = resolve(root, comment["reviewedSHA"])
        if sha != comment["reviewedSHA"]:
            raise ValueError(f"Reviewed target no longer resolvable: {comment['id']}")
        source_path = comment["originalLocation"].get("path")
        if source_path:
            target_source = session.git(root, "show", f"{sha}:{source_path}")
            current_source = session.git(root, "show", f"{current}:{source_path}")
            comment["sourceEvidence"] = {"reviewed": session.digest(target_source.encode()), "current": session.digest(current_source.encode()),
                                          "changed": target_source != current_source}
        decision = supplied.get(comment["id"])
        if decision:
            if decision.get("reviewedSHA") != sha or decision.get("currentHEAD") != current:
                raise ValueError("Decision provenance does not match frozen reviewed SHA and current HEAD")
            if decision.get("validityAtTarget") not in {"confirmed", "partial", "invalid", "unverified"}:
                raise ValueError("Invalid target validity")
            if decision.get("currentActionability") not in {"fix-now", "already-fixed", "obsolete", "not-applicable", "unverified"}:
                raise ValueError("Invalid current actionability")
            if not decision.get("evidence"):
                raise ValueError("Classification requires evidence")
            implementing = decision.get("implementingCommit")
            if implementing and not resolve(root, implementing):
                raise ValueError("Implementing commit is not resolvable")
            for key in ("validityAtTarget", "currentActionability", "evidence", "disposition", "implementingCommit"):
                comment[key] = decision.get(key)
    # Source availability is evidence, never an automatic semantic conclusion.
    payload["status"] = "reconciled" if all(c.get("disposition") and c["currentActionability"] != "unverified" for c in payload["comments"]) else "awaiting-classification"
    payload["reconciledAt"] = now()
    if resolve(root, "HEAD") != current:
        raise ValueError("HEAD changed during reconciliation; refresh required")
    session.atomic_json(path, payload)
    return payload
