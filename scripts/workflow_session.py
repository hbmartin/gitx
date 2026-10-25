#!/usr/bin/env python3
"""Process-held resource leases, immutable evidence, and bounded local commands.

Only the standard library is used. Lock files are never unlinked: their inode
is the coordination point. A private local broker authenticates nested owners;
lock descriptors never escape into external tools or their persistent daemons.
"""
from __future__ import annotations

import argparse
import contextlib
import copy
import ctypes
import errno
import datetime as dt
import dataclasses
import fcntl
import hashlib
import json
import os
import pathlib
import platform
import plistlib
import re
import selectors
import shutil
import signal
import socket
import stat
import subprocess
import sys
import tempfile
import time
import math
import threading
import uuid

ROOT = pathlib.Path(__file__).resolve().parent.parent
LOCK_ROOT = pathlib.Path.home() / "Library/Caches/GitX/Verification/Locks"
RUN_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")
PRODUCER_START_FORMAT = "ps-lstart-utc-c-v1"
BLOCKED_RECEIPT_CATEGORIES = {75: {"resource-busy"},
                              2: {"resource-definition-unavailable", "resource-definition-changed"}}


def valid_run_id(value):
    return isinstance(value, str) and RUN_ID.fullmatch(value) is not None


def atomic_json(path, value):
    path = pathlib.Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(fd, "w") as stream:
            json.dump(value, stream, indent=2, sort_keys=True)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def digest(value):
    return hashlib.sha256(value).hexdigest()


def git_environment(environment=None):
    """Inspect the requested checkout while retaining caller configuration."""
    selectors = {"GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_COMMON_DIR", "GIT_OBJECT_DIRECTORY",
                 "GIT_ALTERNATE_OBJECT_DIRECTORIES", "GIT_QUARANTINE_PATH", "GIT_NAMESPACE"}
    return {key: value for key, value in (os.environ if environment is None else environment).items() if key not in selectors}


def git(root, *args):
    result = subprocess.run(["git", "-C", str(root), *args], capture_output=True, env=git_environment())
    return result.stdout.decode(errors="replace").strip() if result.returncode == 0 else ""


def file_identity(path):
    path = pathlib.Path(path)
    if path.is_symlink():
        return {"link": os.readlink(path)}
    if not path.is_file():
        return None
    info = path.stat()
    hasher = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            hasher.update(block)
    checksum = hasher.hexdigest()
    return {"sha256": checksum, "size": info.st_size, "mode": info.st_mode & 0o777,
            "modifiedNs": info.st_mtime_ns, "inode": info.st_ino}


def tree_identity(path):
    path = pathlib.Path(path)
    if path.is_file() or path.is_symlink():
        return file_identity(path)
    if not path.is_dir():
        return None
    files = {str(p.relative_to(path)): file_identity(p)
             for p in sorted(path.rglob("*")) if p.is_file() or p.is_symlink()}
    return {"sha256": digest(json.dumps(files, sort_keys=True).encode()), "files": len(files)}


def inputs(root=ROOT):
    """Identity of source and policy, including tracked and new source files.

    Unrelated untracked research and generated caches are not build inputs.
    Gitlink commits and dirty dependency sources are recorded independently.
    """
    root = pathlib.Path(root).resolve()
    names = git(root, "ls-files", "-z").split("\0")
    new = git(root, "ls-files", "--others", "--exclude-standard", "-z").split("\0")
    names += [p for p in new if build_input_path(p)]
    files = {name: file_identity(root / name) for name in sorted(set(names)) if name and not generated_input_path(name)}
    # The canonical sdp phase regenerates this checked-in bridge header when a
    # new configuration is built. Byte-identical output is still the same
    # compiler input; content and mode changes remain invalidating.
    generated = files.get("Resources/GitX.h")
    if generated:
        generated.pop("modifiedNs", None)
        generated.pop("inode", None)
    dependencies = git(root, "submodule", "status", "--recursive")
    # Include edits in initialized dependencies; gitlinks alone miss dirty source.
    dependency_diffs = []
    for line in dependencies.splitlines():
        fields = line.split()
        if len(fields) > 1 and (root / fields[1]).is_dir():
            dependency_diffs.append([fields[1], git(root / fields[1], "diff", "HEAD", "--binary")])
    plans = {name: value for name, value in files.items()
             if name.endswith((".xctestplan", ".xcscheme", "Package.resolved", "Package.swift"))}
    return {"version": 1, "root": str(root), "head": git(root, "rev-parse", "HEAD"),
            "source": digest(json.dumps(files, sort_keys=True).encode()),
            "dependencies": digest(json.dumps([dependencies, dependency_diffs]).encode()),
            "plans": digest(json.dumps(plans, sort_keys=True).encode()), "files": files}


def generated_input_path(name):
    parts = pathlib.PurePosixPath(name).parts
    return (len(parts) > 1 and parts[0] in {"GitXCore", "ForgeKit"} and
            (parts[1] == ".build" or parts[1:4] == (".swiftpm", "xcode", "xcuserdata")))


def build_input_path(name):
    return not generated_input_path(name) and (name.startswith(("Classes/", "GitXTests/", "GitXUITests/",
        "GitXCore/", "ForgeKit/", "Resources/", "External/", "scripts/", ".agents/skills/", ".github/",
        "GitX.xcodeproj/", "GitX.xcworkspace/")) or name in {"AGENTS.md", "Mintfile", ".gitmodules",
        ".swiftlint.yml", ".swiftformat"} or name.endswith((".xcconfig", ".entitlements")))


def command_identity(command):
    """Known Python scripts depend on their runtime, not its installation path."""
    if len(command) >= 2 and pathlib.Path(command[1]).name == "check_test_build_contracts.py":
        return {"entry": str(pathlib.Path(command[1]).resolve()), "arguments": command[2:],
                "python": [platform.python_implementation(), *sys.version_info[:2]]}
    return {"command": command}


def command_matches(step, command):
    recorded = step.get("command", [])
    expected = command_identity(command)
    identity = step.get("commandIdentity")
    if identity is not None:
        return identity == expected
    # Legacy receipts did not record Python versions. Recognize a relocated
    # interpreter only when it is this runtime (including filesystem aliases).
    if recorded == command:
        return True
    if len(recorded) >= 2 and "python" in expected and recorded[1:] == command[1:]:
        try:
            return os.path.samefile(recorded[0], command[0])
        except OSError:
            return False
    return False


def receipt_artifact_problems(payload, root=ROOT, mutable_caches=None, identity=None):
    """Validate immutable artifacts independently of the final mutable cache owner."""
    root = pathlib.Path(root)
    readers = {"results": tree_identity, "products": product_identity,
               "packages": package_products, "dependencies": dependency_products}
    identity = identity or (lambda kind, path: readers[kind](path))
    evidence, paths = payload.get("evidence", {}), payload.get("buildPaths", {})
    problems = []
    def absolute(value):
        path = pathlib.Path(value)
        return path if path.is_absolute() else root / path
    results = evidence.get("results", {})
    required = {step["xcresult"] for step in payload.get("steps", []) if step.get("xcresult")}
    for value in required | set(results):
        expected = results.get(value)
        if expected is None or expected != identity("results", absolute(value)):
            problems.append("Result artifact missing or changed: " + value)
    analysis = payload.get("invocation", {}).get("preset") == "analyze"
    artifacts = evidence.get("analysisArtifacts", {})
    required_analysis = {step["log"] for step in payload.get("steps", []) if analysis and step.get("log")}
    if analysis and not artifacts:
        problems.append("Durable analyzer diagnostics are missing")
    for value in required_analysis | set(artifacts):
        expected = artifacts.get(value)
        if expected is None or expected != identity("results", absolute(value)):
            problems.append("Analysis artifact missing or changed: " + value)
    if ("invocation" in payload or "dependencyProducts" in evidence) and ("dependencyProducts" not in evidence or (str(root) not in (mutable_caches or {}).get("dependencies", {}) and evidence["dependencyProducts"] != identity("dependencies", root))):
        problems.append("Dependency products are missing or changed")
    package_check = payload.get("invocation", {}).get("preset") in {"test:core", "test:forgekit"}
    if package_check and not paths.get("swiftPM"):
        problems.append("Package products are missing or changed")
    for kind, field, path in (("products", "products", paths.get("derivedData")),
                              ("packages", "packageProducts", paths.get("swiftPM"))):
        if kind == "packages" and not package_check and field not in evidence:
            continue
        if path and (kind != "products" or not analysis):
            if field not in evidence or (path not in (mutable_caches or {}).get(kind, {}) and
                                        evidence[field] != identity(kind, path)):
                problems.append("Build products are missing or changed" if kind == "products" else "Package products are missing or changed")
    return problems


def active_workflow_steps(payload, *, require_selected_checks=False):
    """Retain historical evidence, but validate only the current attempt's checks."""
    selected = payload.get("selectedChecks")
    if require_selected_checks and selected is None:
        raise ValueError("Explicit selected checks required")
    steps = payload.get("steps", [])
    if not isinstance(steps, list) or any(not isinstance(step, dict) for step in steps):
        raise ValueError("Malformed workflow steps")
    if selected is not None and (not isinstance(selected, list) or any(not isinstance(name, str) for name in selected)):
        raise ValueError("Malformed selected checks")
    if selected is not None and any(not isinstance(step.get("name"), str) for step in steps):
        raise ValueError("Malformed workflow step names")
    return [step for step in steps
            if selected is None or step.get("name") in selected]


def workflow_cache_snapshots(payload, root=ROOT, receipt_reader=None):
    """Use completion provenance, never array position, to select each cache owner."""
    candidates = {"products": {}, "packages": {}, "dependencies": {}}
    for step in active_workflow_steps(payload):
        if not step.get("receipt"):
            continue
        path = pathlib.Path(step["receipt"])
        path = path if path.is_absolute() else pathlib.Path(root) / path
        child = receipt_reader(path) if receipt_reader else json.loads(path.read_text())
        if not isinstance(child, dict):
            raise ValueError("Child receipt must be an object: " + str(path))
        paths, evidence = child.get("buildPaths", {}), child.get("evidence", {})
        if not isinstance(paths, dict) or not isinstance(evidence, dict):
            raise ValueError("Child receipt paths and evidence must be objects: " + str(path))
        if not isinstance(child.get("invocation", {}), dict):
            raise ValueError("Child receipt invocation must be an object: " + str(path))
        stamp = child.get("finishedAt") or step.get("finishedAt") or ""
        for kind, field, cache in (("products", "products", paths.get("derivedData")),
                                   ("packages", "packageProducts", paths.get("swiftPM")),
                                   ("dependencies", "dependencyProducts", str(pathlib.Path(root)))):
            if cache and field in evidence and not (kind == "products" and child.get("invocation", {}).get("preset") == "analyze"):
                candidates[kind].setdefault(cache, []).append((stamp, evidence[field]))
    snapshots = {"products": {}, "packages": {}}
    for kind, caches in candidates.items():
        if not caches:
            continue
        snapshots.setdefault(kind, {})
        for cache, owners in caches.items():
            normalized = []
            for stamp, value in owners:
                try:
                    instant = dt.datetime.fromisoformat(stamp.replace("Z", "+00:00"))
                    if instant.tzinfo is None:
                        raise ValueError("Completion time lacks a timezone")
                    normalized.append((instant.timestamp(), value))
                except (ValueError, TypeError, AttributeError):
                    normalized.append((float("-inf"), value))
            owners = normalized
            distinct = {json.dumps(value, sort_keys=True) for _, value in owners}
            if len(distinct) > 1:
                if any(stamp == float("-inf") for stamp, _ in owners):
                    raise ValueError("Final cache ownership is ambiguous: " + cache)
                latest = max(stamp for stamp, _ in owners)
                winners = {json.dumps(value, sort_keys=True) for stamp, value in owners if stamp == latest}
                if len(winners) != 1:
                    raise ValueError("Final cache ownership is ambiguous: " + cache)
            snapshots[kind][cache] = max(owners, key=lambda item: item[0])[1]
    return snapshots


def final_cache_problems(payload, root=ROOT, *, derived=None, identity=None):
    try:
        if derived is None:
            derived = workflow_cache_snapshots(payload, root)
    except (OSError, ValueError, TypeError, KeyError) as error:
        return ["Final cache ownership cannot be validated: " + str(error)]
    snapshots = payload.get("finalCacheProducts", derived)
    if not isinstance(snapshots, dict) or snapshots != derived:
        return ["Final cache ownership is incomplete or ambiguous"]
    problems = []
    readers = {"products": product_identity, "packages": package_products, "dependencies": dependency_products}
    identity = identity or (lambda kind, path: readers[kind](path))
    for kind in readers:
        if not isinstance(snapshots.get(kind, {}), dict):
            return ["Final cache ownership is incomplete or ambiguous"]
        for path, expected in snapshots.get(kind, {}).items():
            if expected is None or identity(kind, path) != expected:
                problems.append("Final cache products changed: " + path)
    return problems


def process_started(pid):
    environment = dict(os.environ) | {"LC_ALL": "C", "LANG": "C", "TZ": "UTC"}
    try:
        result = subprocess.run(["ps", "-p", str(pid), "-o", "lstart="], capture_output=True,
                                text=True, env=environment, timeout=5)
    except (OSError, subprocess.SubprocessError):
        return None
    return result.stdout.strip() if result.returncode == 0 else None


def producer_identity():
    return {"pid": os.getpid(), "started": process_started(os.getpid()), "startedFormat": PRODUCER_START_FORMAT}


def producer_state(producer):
    if not isinstance(producer, dict) or type(producer.get("pid")) is not int or producer["pid"] <= 0 or \
            not isinstance(producer.get("started"), str) or not producer["started"]:
        return "uncertain"
    try:
        os.kill(producer["pid"], 0)
    except ProcessLookupError:
        return "abandoned"
    except (PermissionError, OSError):
        return "uncertain"
    if producer.get("startedFormat") != PRODUCER_START_FORMAT:
        # Legacy lstart strings contain no timezone. A live PID alone cannot
        # establish either ownership or abandonment across caller environments.
        return "uncertain"
    current = process_started(producer["pid"])
    return "uncertain" if not current else "live" if current == producer["started"] else "abandoned"


def changed_inputs(before, after):
    return [key for key in ("head", "source", "dependencies", "plans")
            if before.get(key) != after.get(key)]


def product_identity(derived_data):
    base = pathlib.Path(derived_data) / "Build/Products"
    # Include bundles, test-run descriptions, signatures, and dylibs; do not hash
    # intermediates which Xcode may legitimately update during result collection.
    return {str(p.relative_to(base)): tree_identity(p) for p in sorted(base.glob("**/*"))
            if (p.suffix in {".app", ".xctest", ".framework", ".xctestrun", ".dylib"})
            and not any(parent.suffix in {".app", ".framework", ".xctest"}
                        for parent in p.relative_to(base).parents)}


def dependency_products(root=ROOT):
    base = pathlib.Path(root) / "External/objective-git/External"
    return {str(path): file_identity(path) for name in ("libgit2.a", "libssh2.a", "libcrypto.a", "build/lib/libgit2.a")
            if (path := base / name).exists()}


def package_products(scratch):
    base = pathlib.Path(scratch)
    return {str(path): tree_identity(path) for path in sorted(base.glob("**/*"))
            if path.suffix in {".xctest", ".dylib"} and not any(p.suffix == ".xctest" for p in path.relative_to(base).parents)}


def verification_cache_root(root=ROOT):
    root = pathlib.Path(root).resolve()
    base = pathlib.Path(os.environ.get("GITX_VERIFICATION_CACHE_ROOT",
                                     pathlib.Path.home() / "Library/Caches/GitX/Verification")).expanduser()
    return (base if base.is_absolute() else root / base).resolve()


def native_fallback_root(root=ROOT):
    return pathlib.Path.home() / 'Library/Caches/GitX/Verification' / digest(str(pathlib.Path(root).resolve()).encode())[:16] / 'NativeFallback'


def verification_artifact_root(root=ROOT):
    root = pathlib.Path(root).resolve()
    config = json.loads((root / "scripts/verification-config.json").read_text())
    return root / config["artifactRoot"]


class ResourceDefinitionError(ValueError):
    def __init__(self, message, category="resource-definition-unavailable"):
        self.category = category
        super().__init__(message)


def toolchain_identity(developer=None):
    developer = developer or os.environ.get("GITX_DEVELOPER_DIR") or os.environ.get("DEVELOPER_DIR") or "/Applications/Xcode.app/Contents/Developer"
    try:
        value = subprocess.check_output([str(pathlib.Path(developer) / "usr/bin/xcodebuild"), "-version"], timeout=15).decode().strip()
        match = re.fullmatch(r"Xcode [0-9]+(?:\.[0-9]+)*\nBuild version ([A-Za-z0-9]+)", value)
        if match is None or match[1].lower() == "unknown":
            raise ValueError("Incomplete or malformed Xcode version output")
        return value
    except (OSError, subprocess.SubprocessError, ValueError) as error:
        raise ResourceDefinitionError("Cannot determine verification toolchain: " + str(error)) from error


def cache_paths(root=ROOT, configuration="Debug", instrumentation="plain", developer=None, toolchain=None):
    root = pathlib.Path(root).resolve()
    developer = developer or os.environ.get("GITX_DEVELOPER_DIR") or os.environ.get("DEVELOPER_DIR")
    developer = developer or "/Applications/Xcode.app/Contents/Developer"
    if toolchain is None:
        try:
            toolchain = toolchain_identity(developer)
        except ResourceDefinitionError:
            toolchain = str(developer)
    base = verification_cache_root(root)
    base = base / digest(str(root).encode())[:16] / digest(toolchain.encode())[:16]
    # Counter updates are part of instrumentation identity. Never reuse the
    # products previously compiled with racing, non-atomic coverage counters.
    partition = base / configuration / ("correctness-atomic" if instrumentation == "correctness" else instrumentation)
    return {"derivedData": str(pathlib.Path(os.environ.get("GITX_DERIVED_DATA", partition / "DerivedData")).expanduser().resolve()),
            "swiftPM": str(pathlib.Path(os.environ.get("GITX_SWIFTPM_BUILD_ROOT", partition / "SwiftPM")).expanduser().resolve()),
            "sourcePackages": str(pathlib.Path(os.environ.get("GITX_SOURCE_PACKAGE_CACHE", base / "SourcePackages")).expanduser().resolve()),
            "toolchain": toolchain}


class ResourceBusy(RuntimeError):
    def __init__(self, resource, owner):
        self.resource, self.owner = resource, owner
        super().__init__(f"Resource busy: {resource}; owning run {owner.get('runId', 'unknown')}; "
                         f"PID {owner.get('pid', 'unknown')}; receipt {owner.get('receipt', 'unknown')}. "
                         "Wait for that run to finish or interrupt its owning session.")


def resource_failure_fields(error):
    """Shared blocked outcome; callers retain their own receipt ownership and context."""
    busy = isinstance(error, ResourceBusy)
    fields = {"status": "blocked", "exitCode": 75 if busy else 2,
              "category": "resource-busy" if busy else error.category,
              "problem": str(error), "deliveryEligible": False,
              "finishedAt": dt.datetime.now(dt.timezone.utc).isoformat()}
    if busy:
        fields.update(owner=error.owner, resource=error.resource)
    return fields


def canonical_resource(resource):
    return resource if resource.startswith("desktop:") else str(pathlib.Path(resource).expanduser().resolve())


class Leases:
    def __init__(self, resources, owner, lock_root=LOCK_ROOT, inherited=None, wait_seconds=0):
        if not math.isfinite(wait_seconds) or wait_seconds < 0:
            raise ValueError("Resource wait must be finite and nonnegative")
        self.wait_limit = wait_seconds
        self.wait_seconds = 0.0
        self.resources = sorted({canonical_resource(r) for r in resources})
        self.owner, self.lock_root = owner, pathlib.Path(lock_root)
        self.inherited = inherited if inherited is not None else json.loads(os.environ.get("GITX_RESOURCE_LEASES", "{}"))
        self.held, self.opened = {}, []
        self.broker = None
        self.broker_thread = None
        self.broker_directory = None

    @staticmethod
    def authenticated(resource, prior):
        try:
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
                client.settimeout(1)
                client.connect(prior["socket"])
                client.sendall(json.dumps({"resource": digest(resource.encode()), "token": prior["token"]}).encode() + b"\n")
                reply = b""
                while len(reply) < 128:
                    data = client.recv(128 - len(reply))
                    if not data:
                        return reply == b"owned"
                    reply += data
                    if b"\n" in reply:
                        return reply == b"owned\n"
                return False
        except (OSError, KeyError, ValueError):
            return False

    def start_broker(self):
        # External macOS tools spawn persistent daemons. Passing lock FDs to a
        # shell leaks leases into those daemons, even after the shell exits.
        # Only this Python owner holds lock FDs; nested commands authenticate
        # over a private local socket while that owner is alive.
        if not self.opened:
            return
        self.broker_directory = tempfile.TemporaryDirectory(prefix="gitx-lease-")
        path = str(pathlib.Path(self.broker_directory.name) / "s")
        self.broker = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.broker.bind(path)
        self.broker.listen(16)
        self.broker.settimeout(.2)
        for value in self.held.values():
            if "socket" not in value:
                value["socket"] = path
        tokens = {digest(resource.encode()): value["token"] for resource, value in self.held.items() if value["socket"] == path}
        broker = self.broker
        def serve():
            while True:
                try:
                    connection, _ = broker.accept()
                except socket.timeout:
                    continue
                except OSError:
                    return
                with connection:
                    try:
                        connection.settimeout(1)
                        data = b""
                        while b"\n" not in data and len(data) <= 4096:
                            chunk = connection.recv(min(4097 - len(data), 4096))
                            if not chunk:
                                break
                            data += chunk
                        if len(data) > 4096:
                            continue
                        request = json.loads(data)
                        owned = tokens.get(request.get("resource")) == request.get("token") and request.get("resource") in tokens
                        connection.sendall(b"owned\n" if owned else b"denied\n")
                    except (OSError, ValueError):
                        pass
        self.broker_thread = threading.Thread(target=serve, daemon=True)
        self.broker_thread.start()

    def __enter__(self):
        started = time.monotonic()
        last_owner = None
        while True:
            try:
                result = self.acquire()
                self.wait_seconds = time.monotonic() - started
                return result
            except ResourceBusy as error:
                elapsed = time.monotonic() - started
                if elapsed >= self.wait_limit:
                    self.wait_seconds = elapsed
                    raise
                notice = (error.resource, error.owner.get("runId"), error.owner.get("pid"))
                if notice != last_owner:
                    print(f"Waiting up to {self.wait_limit:g}s: {error}", flush=True)
                    last_owner = notice
                time.sleep(min(.2, self.wait_limit - elapsed))

    def acquire(self):
        self.held = {}
        self.lock_root.mkdir(parents=True, exist_ok=True)
        try:
            for resource in self.resources:
                path = self.lock_root / (digest(resource.encode()) + ".lock")
                prior = self.inherited.get(resource)
                if prior and self.authenticated(resource, prior):
                    self.held[resource] = prior
                    continue
                stream = path.open("a+")
                try:
                    fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
                except BlockingIOError:
                    stream.seek(0)
                    try:
                        owner = json.load(stream)
                    except ValueError:
                        owner = {}
                    stream.close()
                    raise ResourceBusy(resource, owner)
                self.opened.append(stream)
                token = uuid.uuid4().hex
                stream.seek(0)
                stream.truncate()
                json.dump(self.owner | {"token": token, "resource": resource}, stream)
                stream.flush()
                os.set_inheritable(stream.fileno(), False)
                self.held[resource] = {"token": token}
            self.start_broker()
        except BaseException:
            self.__exit__(None, None, None)
            raise
        return self

    def environment(self):
        return os.environ | {"GITX_RESOURCE_LEASES": json.dumps(self.inherited | self.held),
                             "GITX_VERIFICATION_PRODUCER": json.dumps(self.owner.get("producer")),
                             "GITX_SESSION_ID": os.environ.get("GITX_SESSION_ID", self.owner["runId"])}

    def descriptors(self):
        return ()

    def __exit__(self, *_):
        try:
            if self.broker:
                self.broker.close()
                if self.broker_thread:
                    self.broker_thread.join(timeout=2)
                self.broker = None
            if self.broker_directory:
                self.broker_directory.cleanup()
                self.broker_directory = None
        finally:
            # Descriptor ownership ends even if broker-directory cleanup fails.
            # Inherited parent leases are never unlocked here.
            for stream in self.opened:
                stream.close()
            self.opened.clear()


def inherited_ownership():
    """Receipt helpers inherit their long-lived owner's authenticated holdings."""
    try:
        holdings = json.loads(os.environ.get("GITX_RESOURCE_LEASES", "{}"))
        producer = json.loads(os.environ.get("GITX_VERIFICATION_PRODUCER", "null"))
    except (ValueError, TypeError):
        return None, []
    if not isinstance(holdings, dict):
        return None, []
    resources = sorted(resource for resource, prior in holdings.items()
                       if isinstance(resource, str) and isinstance(prior, dict) and Leases.authenticated(resource, prior))
    if (not resources or not isinstance(producer, dict) or type(producer.get("pid")) is not int or
            producer["pid"] <= 0 or not isinstance(producer.get("started"), str) or not producer["started"]):
        producer = None
    return producer, resources


def desktop_checks():
    if platform.system() != "Darwin":
        return [{"name": "desktop-unavailable", "status": "failed", "detail": "App-host tests require a local macOS console session."}]
    result = subprocess.run(["/usr/sbin/scutil"], input="show State:/Users/ConsoleUser\n", text=True, capture_output=True)
    output = result.stdout
    console = "Name :" in output and "Name : loginwindow" not in output and f"UID : {os.getuid()}" in output
    display = subprocess.run(["/usr/sbin/ioreg", "-n", "IODisplayWrangler", "-r"], text=True, capture_output=True)
    lock_properties = subprocess.run(
        ["/usr/sbin/ioreg", "-a", "-n", "Root", "-d", "1"], capture_output=True).stdout
    locked = console_session_locked(lock_properties, os.getuid())
    checks = [{"name": "console-session", "status": "passed" if console else "failed",
               "detail": "Active local console user." if console else "Switch to this user's macOS desktop before retrying."},
              {"name": "display", "status": "passed" if display.stdout and not locked else "failed",
               "detail": "Display available." if display.stdout and not locked else "Wake and unlock the local display, then retry."}]
    pids = subprocess.run(["pgrep", "-x", "GitX"], capture_output=True, text=True).stdout.split()
    checks.append({"name": "competing-gitx", "status": "failed" if pids else "passed",
                   "detail": f"Close competing GitX processes {', '.join(pids)} and retry." if pids else "No competing GitX process."})
    return checks


def console_session_locked(properties, uid):
    try:
        tree = plistlib.loads(properties.encode() if isinstance(properties, str) else properties)
    except (ValueError, plistlib.InvalidFileException):
        return True
    sessions = []
    def visit(value, registry_locked=False):
        if isinstance(value, dict):
            registry_locked = value.get("IOConsoleLocked", registry_locked)
            if value.get("CGSSessionUserID", value.get("kCGSSessionUserIDKey")) == uid and value.get("CGSSessionOnConsole", value.get("kCGSSessionOnConsoleKey")) is True:
                sessions.append((value, registry_locked))
            for child in value.values():
                visit(child, registry_locked)
        elif isinstance(value, list):
            for child in value:
                visit(child, registry_locked)
    visit(tree)
    if len(sessions) != 1:
        return True
    value, registry_locked = sessions[0]
    locked = value.get("CGSSessionScreenIsLocked", value.get("kCGSSessionScreenIsLockedKey", False))
    return registry_locked is not False or locked is not False


def verify_signatures(derived_data):
    products = pathlib.Path(derived_data) / "Build/Products"
    bundles = [p for p in products.glob("**/*") if p.suffix in {".app", ".framework", ".xctest"}]
    if not bundles:
        raise ValueError("signature: no built app or test products found; run build-for-testing first")
    for bundle in bundles:
        result = subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(bundle)], capture_output=True, text=True)
        if result.returncode:
            raise ValueError(f"signature: {bundle}: {result.stderr.strip()}; rebuild with the suite's signing and instrumentation")
        if bundle.suffix == ".app" and any(bundle.glob("Contents/Frameworks/*.framework")):
            metadata = subprocess.run(["/usr/bin/codesign", "-dv", "--verbose=4", str(bundle)], capture_output=True, text=True)
            description = metadata.stdout + metadata.stderr
            if "runtime)" in description and "TeamIdentifier=not set" in description:
                entitlements = subprocess.run(["/usr/bin/codesign", "-d", "--entitlements", "-", "--xml", str(bundle)], capture_output=True)
                try:
                    allows_foreign = plistlib.loads(entitlements.stdout).get("com.apple.security.cs.disable-library-validation", False)
                except (ValueError, plistlib.InvalidFileException):
                    allows_foreign = False
                if not allows_foreign:
                    raise ValueError(f"signature-incompatible: {bundle}: an ad hoc hardened host cannot load non-platform frameworks with library validation. Use the canonical local test action (ENABLE_HARDENED_RUNTIME=NO); preserve ordinary Release build settings.")
    return [str(p) for p in bundles]


def owned_processes(group):
    result = subprocess.run(["ps", "-axo", "pid=,pgid=,comm="], capture_output=True, text=True)
    return [line.strip() for line in result.stdout.splitlines()
            if len(line.split()) > 1 and line.split()[1] == str(group)]


def descendant_processes(parent):
    """Snapshot actual descendants, including nested supervisors' new groups."""
    result = subprocess.run(["ps", "-axo", "pid=,ppid=,pgid=,comm="], capture_output=True, text=True)
    table = {}
    for line in result.stdout.splitlines():
        fields = line.split(maxsplit=3)
        if len(fields) == 4:
            table[int(fields[0])] = (int(fields[1]), fields[2], fields[3])
    descendants = {parent}
    while True:
        found = {pid for pid, (ppid, _, _) in table.items() if ppid in descendants}
        if found <= descendants:
            break
        descendants.update(found)
    records = []
    for pid in descendants:
        if pid not in table:
            continue
        started = subprocess.run(["ps", "-p", str(pid), "-o", "lstart="], capture_output=True, text=True).stdout.strip()
        if started:
            _, group, command = table[pid]
            records.append({"pid": pid, "started": started, "process": f"{pid} {group} {command}"})
    return records


def detached_owned_processes(tag, existing):
    """Require an inherited session marker for hosts outside the process group.

    Never attribute another app by name or a new PID alone. Environment values
    are inspected only in memory and never copied into diagnostic artifacts.
    """
    result = subprocess.run(["ps", "-axo", "pid=,pgid=,comm="], capture_output=True, text=True)
    owned = []
    for line in result.stdout.splitlines():
        fields = line.split(maxsplit=2)
        if len(fields) < 3 or fields[0] in existing or pathlib.Path(fields[2]).name not in {"GitX", "GitXUITests-Runner"}:
            continue
        pid = fields[0]
        environment = subprocess.run(["ps", "eww", "-p", pid, "-o", "command="], capture_output=True, text=True).stdout
        if re.search(r"(?:^| )GITX_VERIFICATION_SESSION=" + re.escape(tag) + r"(?: |$)", environment):
            started = subprocess.run(["ps", "-p", pid, "-o", "lstart="], capture_output=True, text=True).stdout.strip()
            owned.append({"pid": int(pid), "started": started, "process": line.strip()})
    return owned


def stop_detached(processes, signal_number=signal.SIGTERM):
    for process in processes:
        pid = process["pid"]
        current = subprocess.run(["ps", "-p", str(pid), "-o", "lstart="], capture_output=True, text=True).stdout.strip()
        if current and current == process["started"]:
            with contextlib.suppress(ProcessLookupError):
                os.kill(pid, signal_number)


def diagnostics(directory, group, category, detached=()):
    directory = pathlib.Path(directory)
    directory.mkdir(parents=True, exist_ok=True)
    processes = list({line.split()[0]: line for line in
                      owned_processes(group) + [process["process"] for process in detached]}.values())
    atomic_json(directory / "blocker.json", {"category": category, "ownedProcessGroup": group,
                "processes": processes, "nextAction": "Inspect retained logs and samples; retry after resolving the reported blocker."})
    for line in processes:
        pid = line.split()[0]
        if platform.system() == "Darwin" and category != "interrupted":
            subprocess.run(["/usr/bin/sample", pid, "1", "1", "-file", str(directory / f"sample-{pid}.txt")], capture_output=True, timeout=10)
            if pathlib.Path(line.split(maxsplit=2)[-1]).name == "GitX":
                log = subprocess.run(["/usr/bin/log", "show", "--last", "5m", "--style", "compact", "--predicate", f"processIdentifier == {pid}"], capture_output=True, timeout=15)
                (directory / f"gitx-{pid}.log").write_bytes(log.stdout + log.stderr)
                if shutil.which("peekaboo"):
                    capture = subprocess.run(["peekaboo", "image", "--pid", pid, "--path", str(directory / f"gitx-{pid}.png")], capture_output=True, timeout=15)
                    (directory / f"capture-{pid}.log").write_bytes(capture.stdout + capture.stderr)


class CapturedConsole:
    """Keep the full log on disk; a slow console must never stall the producer."""

    def __init__(self, path):
        candidate = pathlib.Path(path)
        if candidate.is_symlink():
            raise ValueError("Refusing symlink command output")
        self.path = candidate.resolve()
        if not self.path.is_relative_to(verification_artifact_root(ROOT).resolve()):
            raise ValueError("Command output must stay inside the configured verification artifact directory")
        descriptor = os.open(self.path, os.O_WRONLY | os.O_CREAT | os.O_NOFOLLOW | os.O_NONBLOCK, 0o600)
        try:
            if not stat.S_ISREG(os.fstat(descriptor).st_mode):
                raise ValueError("Command output must be a regular file")
            os.ftruncate(descriptor, 0)
            self.stream = os.fdopen(descriptor, 'wb', buffering=0)
        except BaseException:
            os.close(descriptor)
            raise
        self.ready = threading.Event()
        self.finished = threading.Event()
        self.captured_bytes = 0
        self.mirrored_bytes = 0
        self.console_error = None
        self.console = sys.stdout.fileno()
        self.reader = self.path.open('rb', buffering=0)
        self.worker = threading.Thread(target=self.mirror, daemon=True, name='verification-console')
        self.worker.start()

    def mirror(self):
        try:
            with self.reader:
                while True:
                    self.ready.clear()
                    data = self.reader.read(65536)
                    if data:
                        remaining = memoryview(data)
                        while remaining:
                            written = os.write(self.console, remaining)
                            self.mirrored_bytes += written
                            remaining = remaining[written:]
                    elif self.finished.is_set():
                        return
                    else:
                        self.ready.wait()
        except OSError as error:
            self.console_error = type(error).__name__

    def write(self, data):
        remaining = memoryview(data)
        while remaining:
            written = self.stream.write(remaining)
            self.captured_bytes += written
            remaining = remaining[written:]
        self.ready.set()

    def close(self):
        flush_error, close_error = None, None
        try:
            os.fsync(self.stream.fileno())
        except OSError as error:
            flush_error = type(error).__name__
        finally:
            try:
                self.stream.close()
            except OSError as error:
                close_error = type(error).__name__
            self.finished.set()
            self.ready.set()
            # The mirror may be blocked inside the caller's console pipe. Its
            # daemon cannot delay the watchdog, child completion, or CLI exit.
            self.worker.join(timeout=1)
        return {"path": str(self.path), "capturedBytes": self.captured_bytes,
                "mirroredBytes": self.mirrored_bytes, "consoleError": self.console_error,
                "flushError": flush_error, "closeError": close_error,
                "consoleComplete": not self.worker.is_alive() and self.mirrored_bytes == self.captured_bytes}



def test_output_started(data):
    return any(marker in data for marker in (b"Test Suite ", b"Test Case ", b"Test case '"))


NATIVE_RECORD_NAME = re.compile(r'(startup|capture)-[0-9]+-[A-Fa-f0-9-]+\.json')
NATIVE_STDERR_NAME = re.compile(r'GitX-[0-9]+-[A-Fa-f0-9-]+\.stderr\.log')
NATIVE_CAPTURE_RECORD_NAME = re.compile(r'capture-[0-9]+-[A-Fa-f0-9-]+\.json')


class NativeEvidenceError(OSError):
    """An inspected identity is invalid, rather than merely inaccessible."""

    def __init__(self, message, *, detail=None, error_number=errno.EPERM):
        self.detail = detail
        super().__init__(error_number, message)


def open_owned_regular(path, *, directory=None, maximum=None, identity=None, flags=os.O_RDONLY):
    """Return an owned regular descriptor without following a final symlink."""
    descriptor = os.open(path, flags | os.O_NOFOLLOW | os.O_CLOEXEC | os.O_NONBLOCK, dir_fd=directory)
    try:
        info = os.fstat(descriptor)
        if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or
                (maximum is not None and info.st_size > maximum) or
                (identity is not None and (info.st_dev, info.st_ino) != identity)):
            raise NativeEvidenceError('Native file identity is not valid')
        return descriptor, info
    except BaseException:
        os.close(descriptor)
        raise


class ExclusiveRenameUnavailable(OSError):
    """The platform provides no exclusive rename syscall."""


def exclusive_native_rename(source, destination, *, sync_parent=False):
    library = ctypes.CDLL(None, use_errno=True)
    if sys.platform == 'darwin':
        rename = library.renamex_np
        rename.argtypes = (ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint)
        arguments = (os.fsencode(source), os.fsencode(destination), 4)  # RENAME_EXCL
    elif hasattr(library, 'renameat2'):
        rename = library.renameat2
        rename.argtypes = (ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint)
        arguments = (-100, os.fsencode(source), -100, os.fsencode(destination), 1)
    else:
        raise ExclusiveRenameUnavailable(errno.ENOTSUP, 'Exclusive native publication is unavailable')
    rename.restype = ctypes.c_int
    if rename(*arguments) != 0:
        code = ctypes.get_errno()
        raise OSError(code, os.strerror(code), str(destination))
    if sync_parent:
        parents = dict.fromkeys((pathlib.Path(source).parent, pathlib.Path(destination).parent))
        for parent in parents:
            sync_native_directory(parent)


def read_native_record(directory, name, invocation, session):
    """Read one complete owned record; substituted files remain untrusted."""
    if not NATIVE_RECORD_NAME.fullmatch(name):
        return None
    try:
        descriptor, _ = open_owned_regular(name, directory=directory, maximum=65536)
        with os.fdopen(descriptor, 'rb') as stream:
            record = json.loads(stream.read(65537))
        if (not isinstance(record, dict) or type(record.get('schemaVersion')) is not int or
                record['schemaVersion'] != 1 or record.get('invocationID') != invocation or
                record.get('verificationSession') != session or type(record.get('pid')) is not int or record['pid'] <= 0):
            return None
        expected_event = 'bundle-start' if name.startswith('startup-') else 'capture'
        if record.get('event') != expected_event or int(name.split('-')[1]) != record['pid']:
            return None
        failure = record.get('publicationError')
        if failure is not None:
            operations = {'validate-record', 'open-directory', 'inspect-directory', 'validate-directory',
                          'create-record', 'encode-record', 'write-record', 'flush-record', 'publish-record'}
            if (not isinstance(failure, dict) or failure.get('operation') not in operations or
                    failure.get('category') not in {'system', 'configuration', 'ownership', 'serialization', 'unexpected'} or
                    (failure.get('errno') is not None and (type(failure['errno']) is not int or not 0 < failure['errno'] < 65536))):
                return None
        return record
    except (OSError, ValueError, UnicodeError):
        return None


class NativeTestProgress:
    """Cache immutable accepted records; only bundle records can establish startup."""

    def __init__(self, directory, invocation, session, bundles):
        descriptor = os.open(directory, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC)
        try:
            if os.fstat(descriptor).st_uid != os.getuid():
                raise OSError(errno.EPERM, 'Progress directory has a different owner')
        except BaseException:
            os.close(descriptor)
            raise
        self.descriptor = descriptor
        self.invocation, self.session, self.bundles = invocation, session, set(bundles)
        self.accepted = {}
        self.started = False

    def records(self):
        for name in os.listdir(self.descriptor):
            if name not in self.accepted:
                record = read_native_record(self.descriptor, name, self.invocation, self.session)
                if record is not None:
                    self.accepted[name] = record
        return list(self.accepted.values())

    def observed(self):
        if not self.started:
            self.started = any(record.get('event') == 'bundle-start' and record.get('bundleID') in self.bundles
                               for record in self.records())
        return self.started

    def close(self):
        os.close(self.descriptor)


class NativeProgressSetupError(OSError):
    def __init__(self, operation, cause):
        self.operation = operation
        super().__init__(getattr(cause, 'errno', None) or errno.EIO, 'Required native progress setup failed')


def native_directory_identity(path):
    info = pathlib.Path(path).lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid():
        raise NativeEvidenceError('Invalid native directory identity')
    return [info.st_dev, info.st_ino]


def descriptor_digest(descriptor):
    hasher = hashlib.sha256()
    offset = 0
    while data := os.pread(descriptor, 1024 * 1024, offset):
        hasher.update(data)
        offset += len(data)
    return hasher.hexdigest()


def sync_native_directory(path):
    descriptor = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


class NativeRegistrationChanged(OSError):
    def __init__(self):
        super().__init__(errno.EAGAIN, 'Native registration advanced or changed')


class NativeControlLease:
    """Validate and own one persistent nonblocking lock inode, without a ledger."""

    def __init__(self, path, *, create_parent=False, boundary=contextlib.nullcontext):
        self.path = pathlib.Path(path)
        self.create_parent = create_parent
        self.boundary = boundary
        self.directory = self.lock = None

    def __enter__(self):
        with self.boundary():
            return self.acquire()

    def acquire(self):
        try:
            if self.create_parent:
                self.path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
            self.identity = native_directory_identity(self.path.parent)
            self.directory = os.open(self.path.parent, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC)
            info = os.fstat(self.directory)
            if [info.st_dev, info.st_ino] != self.identity or info.st_uid != os.getuid():
                raise NativeEvidenceError('Native control directory changed')
            try:
                existing = os.stat(self.path.name, dir_fd=self.directory, follow_symlinks=False)
            except FileNotFoundError:
                existing = None
            if existing is not None:
                self.validate_control(existing)
            self.lock = os.open(self.path.name, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC,
                                0o600, dir_fd=self.directory)
            info = os.fstat(self.lock)
            self.validate_control(info)
            fcntl.flock(self.lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return self
        except BaseException:
            self.__exit__(None, None, None)
            raise

    @staticmethod
    def validate_control(info):
        detail = ('control-type' if not stat.S_ISREG(info.st_mode) else
                  'control-owner' if info.st_uid != os.getuid() else
                  'control-links' if info.st_nlink != 1 else
                  'control-mode' if info.st_mode & 0o077 else None)
        if detail:
            raise NativeEvidenceError('Invalid native invocation control', detail=detail)

    def __exit__(self, *_):
        lock, directory = self.lock, self.directory
        self.lock = self.directory = None
        try:
            if lock is not None:
                os.close(lock)
        finally:
            if directory is not None:
                os.close(directory)


class NativeRegistration:
    """Coordinate one invocation's publishers without holding shared build proofs."""

    def __init__(self, path, *, create=False, retry_retained=False):
        self.path = pathlib.Path(path)
        self.create, self.retry_retained = create, retry_retained
        self.directory = self.lock = self.control = None
        self.current = None

    def __enter__(self):
        try:
            if not self.create:
                descriptor, _ = open_owned_regular(self.path, maximum=1024 * 1024)
                os.close(descriptor)
            self.control = NativeControlLease(self.path.with_name(self.path.name + '.lock'), create_parent=self.create)
            self.control.__enter__()
            self.identity, self.directory, self.lock = self.control.identity, self.control.directory, self.control.lock
            self.current = self.read()
            return self
        except BaseException:
            self.__exit__(None, None, None)
            raise

    def read_bytes(self):
        try:
            descriptor, _ = open_owned_regular(self.path.name, directory=self.directory, maximum=1024 * 1024)
        except FileNotFoundError:
            if self.create:
                return None
            raise
        with os.fdopen(descriptor, 'rb') as stream:
            return stream.read(1024 * 1024 + 1)

    def read(self):
        self.serialized = self.read_bytes()
        if self.serialized is None:
            return None
        value = json.loads(self.serialized)
        if not isinstance(value, dict):
            raise ValueError('Invalid native registration')
        return value

    def publish(self, value):
        prior = self.current
        if self.read_bytes() != self.serialized or native_directory_identity(self.path.parent) != self.identity:
            raise NativeRegistrationChanged()
        if prior:
            phases = {None: 0, 'prepared': 1, 'deleting': 2, 'retired': 3}
            if (any(prior.get(key) != value.get(key) for key in NATIVE_OWNER_IDENTITY) or
                    (prior.get('retirementState') == 'retired' and prior != value) or
                    (prior.get('retirementState') == 'retained' and value.get('retirementState') != 'retained' and not self.retry_retained) or
                    phases.get(prior.get('retirementPhase'), 0) > phases.get(value.get('retirementPhase'), 0) or
                    (prior.get('collectionComplete') and not value.get('collectionComplete')) or
                    (prior.get('status') != 'running' and value.get('status') == 'running')):
                raise NativeRegistrationChanged()
        atomic_json(self.path, value)
        sync_native_directory(self.path.parent)
        self.current = copy.deepcopy(value)
        self.serialized = (json.dumps(value, indent=2, sort_keys=True) + '\n').encode()

    def __exit__(self, *_):
        if self.control is not None:
            self.control.__exit__(None, None, None)
        self.control = self.directory = self.lock = None


class NativeRegistrationSnapshot:
    """A captured version; each comparison/publication owns only a short transaction."""

    def __init__(self, path, *, retry_retained=False):
        self.path = pathlib.Path(path)
        self.retry_retained = retry_retained
        with NativeRegistration(path, retry_retained=retry_retained) as transaction:
            self.identity = transaction.identity
            self.current = transaction.current

    def publish(self, value):
        with native_retirement_boundary('registration', 'publish-registration'), \
                NativeRegistration(self.path, retry_retained=self.retry_retained) as transaction:
            if transaction.identity != self.identity or transaction.current != self.current:
                raise NativeRegistrationChanged()
            transaction.publish(value)
            self.current = transaction.current


def persist_native_registration(path, value):
    with NativeRegistration(path, create=True) as registration:
        registration.publish(value)


def native_path_absent(path):
    try:
        pathlib.Path(path).lstat()
        return False
    except FileNotFoundError:
        return True


@dataclasses.dataclass(frozen=True)
class NativeRetirementOutcome:
    state: str
    reason: str | None = None
    origin: str = 'retirement'
    operation: str | None = None
    error_number: int | None = None
    report_only: bool = False
    validation_detail: str | None = None

    def metadata(self):
        result = {'state': self.state, 'reason': self.reason, 'origin': self.origin,
                  'operation': self.operation, 'errno': self.error_number}
        if self.report_only:
            result.update(reportOnly=True, validationDetail=self.validation_detail)
        return result


class NativeRetirementFault(Exception):
    def __init__(self, outcome):
        self.outcome = outcome
        super().__init__(outcome.reason)


def native_evidence_failure_state(origin):
    """Retryability does not determine whether an outcome may be persisted."""
    return 'deferred' if origin in {'authorization', 'registration', 'durability'} else 'retained'


def native_outcome_is_publishable(outcome):
    return not outcome.report_only and not (outcome.state == 'deferred' and
                                           outcome.origin in {'authorization', 'registration', 'producer'})


@contextlib.contextmanager
def native_retirement_boundary(origin, operation, *, evidence=False):
    """Classify at the failing boundary, independently of mutable control flow."""
    try:
        yield
    except NativeRetirementFault:
        raise
    except ResourceBusy as error:
        raise NativeRetirementFault(NativeRetirementOutcome('deferred', 'retirement-proof-held', 'authorization', operation)) from error
    except NativeRetirementDeferred as error:
        raise NativeRetirementFault(NativeRetirementOutcome('deferred', str(error), 'authorization', operation)) from error
    except BlockingIOError as error:
        reason = 'producer-lease-held' if origin in {'source', 'producer'} else origin + '-busy'
        raise NativeRetirementFault(NativeRetirementOutcome('deferred', reason, origin, operation, error.errno)) from error
    except NativeEvidenceError as error:
        report_only = error.detail in {'control-type', 'control-owner', 'control-links', 'control-mode'}
        state = 'retained' if report_only else native_evidence_failure_state(origin)
        raise NativeRetirementFault(NativeRetirementOutcome(state, origin + '-invalid', origin, operation, error.errno,
                                                          report_only, error.detail)) from error
    except OSError as error:
        suffix = ('missing' if error.errno in {errno.ENOENT, errno.ENOTDIR} else
                  'invalid' if error.errno == errno.ELOOP else
                  'unavailable' if error.errno in {errno.EACCES, errno.EPERM} else 'unproven')
        state = 'retained' if (evidence and suffix != 'unproven' or origin == 'deletion' and error.errno in {errno.EACCES, errno.EPERM}) else 'deferred'
        raise NativeRetirementFault(NativeRetirementOutcome(state, origin + '-' + suffix, origin, operation, error.errno)) from error
    except (ValueError, TypeError, KeyError) as error:
        raise NativeRetirementFault(NativeRetirementOutcome('retained' if evidence else 'deferred',
                                    origin + '-invalid', origin, operation)) from error


@contextlib.contextmanager
def native_retirement_authorization(authorize):
    with native_retirement_boundary('authorization', 'authorize'):
        with (authorize or contextlib.nullcontext)():
            yield


def validate_native_archive(owner, checkout, *, snapshots=None):
    declared_archive = pathlib.Path(owner['artifactDirectory'])
    archive = declared_archive.resolve()
    if (owner.get('kind') != 'gitx-native-invocation' or owner.get('schemaVersion') != 1 or
            owner.get('checkout') != str(checkout.resolve()) or not owner.get('collectionComplete') or
            not declared_archive.is_absolute() or declared_archive.is_symlink() or
            not archive.is_relative_to(verification_artifact_root(checkout).resolve())):
        raise ValueError('Invalid native archive registration')
    identity = native_directory_identity(archive)
    if owner.get('archiveDirectoryIdentity', identity) != identity:
        raise ValueError('Native archive directory was replaced')
    names = set()
    for item in owner['files']:
        name = item['name']
        if (item['folder'] not in ('Progress', 'Stderr') or name in names or
                not (NATIVE_RECORD_NAME.fullmatch(name) or NATIVE_STDERR_NAME.fullmatch(name))):
            raise ValueError('Invalid native archive manifest')
        names.add(name)
        descriptor, info = open_owned_regular(archive / name, identity=tuple(item['archiveIdentity']))
        try:
            if (info.st_size != item['bytes'] or descriptor_digest(descriptor) != item['sha256'] or
                    native_stat_snapshot(os.fstat(descriptor)) != native_stat_snapshot(info)):
                raise ValueError('Native archive changed')
            if snapshots is not None:
                snapshots[name] = native_stat_snapshot(info)
        finally:
            os.close(descriptor)
    return archive


def native_stat_snapshot(info):
    return [info.st_dev, info.st_ino, stat.S_IFMT(info.st_mode), info.st_uid, info.st_size, info.st_mtime_ns]


def locked_native_file_info(path, descriptor):
    """Snapshot only after exclusion, binding the open file to its current name."""
    info = os.fstat(descriptor)
    if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or
            native_stat_snapshot(pathlib.Path(path).lstat()) != native_stat_snapshot(info)):
        raise NativeEvidenceError('Owned source changed')
    return info


def native_deletion_proof(root, owner, *, parent_identity=None):
    """Capture every approved entry before deletion; directories may shrink on resume."""
    entries = {}
    for path in root.rglob('*'):
        info = path.lstat()
        if info.st_uid != os.getuid() or not (stat.S_ISREG(info.st_mode) or stat.S_ISDIR(info.st_mode)):
            raise ValueError('Invalid deletion entry')
        entries[str(path.relative_to(root))] = native_stat_snapshot(info)
    return {'schemaVersion': 1, 'rootIdentity': owner['directoryIdentity'],
            'parentIdentity': list(parent_identity) if parent_identity is not None else native_directory_identity(root.parent), 'entries': entries}


def validate_native_deletion(root, original, owner, *, allow_missing, operation):
    proof = owner.get('deletionProof')
    if (not isinstance(proof, dict) or proof.get('schemaVersion') != 1 or
            proof.get('rootIdentity') != native_directory_identity(root) or
            proof.get('parentIdentity') != native_directory_identity(root.parent) or
            not native_path_absent(original)):
        raise ValueError('Invalid deletion proof')
    entries = proof['entries']
    if not isinstance(entries, dict):
        raise ValueError('Invalid deletion entry manifest')
    remaining = set()
    for path in root.rglob('*'):
        relative = str(path.relative_to(root))
        info = path.lstat()
        actual = native_stat_snapshot(info)
        expected = entries.get(relative)
        if (not expected or info.st_uid != os.getuid() or
                actual != expected and not (stat.S_ISDIR(info.st_mode) and actual[:4] == expected[:4])):
            raise NativeRetirementFault(NativeRetirementOutcome('retained', 'source-changed-during-retirement', 'source', operation))
        remaining.add(relative)
    if not allow_missing and remaining != entries.keys():
        raise ValueError('Quarantine content changed')


def upgrade_legacy_native_deletion(root, owner, descriptors):
    """An old deleting record may prove surviving entries without intact controls."""
    parent_identity = native_directory_identity(root.parent)
    if owner.get('retirementParentIdentity', parent_identity) != parent_identity:
        raise ValueError('Legacy deletion has no parent proof')
    files = {item['folder'] + '/' + item['name']: item for item in owner['files']}
    for path in root.rglob('*'):
        relative = str(path.relative_to(root))
        if relative in ('Progress', 'Stderr'):
            native_directory_identity(path)
            continue
        if relative not in files and relative not in ('native-owner.json', 'invocation.lease'):
            raise ValueError('Legacy quarantine has unknown contents')
        descriptor, info = open_owned_regular(path)
        descriptors.append(descriptor)
        fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        info = locked_native_file_info(path, descriptor)
        if relative in files:
            item = files[relative]
            if ([info.st_dev, info.st_ino] != item['identity'] or info.st_size != item['bytes'] or
                    descriptor_digest(descriptor) != item['sha256']):
                raise ValueError('Legacy source identity changed')
        elif relative == 'native-owner.json':
            current = json.loads(os.read(descriptor, 1024 * 1024))
            if not isinstance(current, dict):
                raise ValueError('Invalid legacy native owner')
            if any(current.get(key) != owner.get(key) for key in ('invocationID', 'checkout', 'directoryIdentity', 'files', 'collectionComplete')):
                raise ValueError('Legacy owner changed')
    return native_deletion_proof(root, owner)


def recheck_native_archive(archive, snapshots):
    for name, expected in snapshots.items():
        if native_stat_snapshot((archive / name).lstat()) != expected:
            raise ValueError('Archive changed at retirement boundary')


@dataclasses.dataclass(frozen=True)
class NativeRetirementLocation:
    original: pathlib.Path
    root: pathlib.Path
    parent_identity: tuple
    phase: str | None
    absent: bool = False
    root_identity: tuple = ()
    prepared: pathlib.Path | None = None

    @property
    def recovering(self):
        return self.root != self.original or self.phase in {'prepared', 'deleting', 'retired'}


def native_retirement_location(owner, checkout, *, retry_retained=False):
    with native_retirement_boundary('source', 'inspect-root', evidence=True):
        legacy_recovery = owner.get('retirementState') in {'prepared', 'deferred'} or (
            retry_retained and owner.get('retirementState') == 'retained')
        original = pathlib.Path(owner['sourceDirectory'])
        root = original
        prepared = pathlib.Path(owner.get('retirementPath', str(original)))
        if not original.is_absolute() or original.resolve() != original or original.is_symlink():
            raise NativeRetirementFault(NativeRetirementOutcome('retained', 'invalid-source-path', 'source'))
        parent_identity = native_directory_identity(original.parent)
        if owner.get('retirementParentIdentity', parent_identity) != parent_identity:
            raise NativeRetirementFault(NativeRetirementOutcome('retained', 'retirement-parent-changed', 'source'))
        if prepared != original:
            if prepared.parent != original.parent or not re.fullmatch(r'\.gitx-native-retired-[0-9a-f]{32}', prepared.name):
                raise NativeRetirementFault(NativeRetirementOutcome('retained', 'invalid-retirement-path', 'source'))
            if native_path_absent(original):
                if native_path_absent(prepared):
                    if not (owner.get('retirementPhase') in ('prepared', 'deleting', 'retired') or legacy_recovery):
                        raise NativeRetirementFault(NativeRetirementOutcome('retained', 'retirement-evidence-incomplete', 'source'))
                    return NativeRetirementLocation(original, prepared, tuple(parent_identity), owner.get('retirementPhase'), True, tuple(owner['directoryIdentity']), prepared)
                root = prepared
            elif not native_path_absent(prepared):
                raise NativeRetirementFault(NativeRetirementOutcome('retained', 'conflicting-retirement-paths', 'source'))
        if (owner.get('kind') != 'gitx-native-invocation' or owner.get('schemaVersion') != 1 or
                owner.get('checkout') != str(checkout.resolve()) or root.is_symlink() or root.resolve() != root or
                native_directory_identity(root) != owner['directoryIdentity']):
            raise NativeRetirementFault(NativeRetirementOutcome('retained', 'source-invalid', 'source'))

    phase = owner.get('retirementPhase')
    if root != original and phase is None and legacy_recovery:
        # Legacy rmtree could consume any subset, including only diagnostic
        # folders. Surviving controls do not establish an intact preparation.
        phase = 'deleting'
    return NativeRetirementLocation(original, root, tuple(parent_identity), phase, False, tuple(owner['directoryIdentity']), prepared)


def validate_native_location(location, *, root=None, absent=None, operation='revalidate-location'):
    """Recheck one approved location; never refresh its expected identities."""
    with native_retirement_boundary('source', operation, evidence=True):
        selected = pathlib.Path(root) if root is not None else location.root
        missing = location.absent if absent is None else absent
        if (location.original.resolve() != location.original or selected.resolve() != selected or
                tuple(native_directory_identity(location.original.parent)) != location.parent_identity or
                selected.parent != location.original.parent):
            raise NativeEvidenceError('Native retirement parent or canonical path changed')
        if missing:
            if not native_path_absent(location.original) or not native_path_absent(selected):
                raise NativeEvidenceError('Native retirement paths reappeared')
        elif (tuple(native_directory_identity(selected)) != location.root_identity or
                selected != location.original and not native_path_absent(location.original)):
            raise NativeEvidenceError('Native retirement root changed')
        elif (selected == location.original and location.prepared is not None and
              location.prepared != selected and not native_path_absent(location.prepared)):
            raise NativeEvidenceError('Native retirement paths conflict')


def retire_native_sources(owner, *, checkout=None, persist=None, authorize=None, source_owned=False, evidence=None, location=None):
    """Return a classified outcome; only mutation boundaries acquire cleanup proof."""
    descriptors = []
    evidence = evidence if evidence is not None else {}
    try:
        checkout = pathlib.Path(checkout or ROOT)
        location = location if location is not None else native_retirement_location(owner, checkout)
        original, root, parent_identity = location.original, location.root, list(location.parent_identity)
        validate_native_location(location)
        if location.absent:
            with native_retirement_boundary('archive', 'validate-archive', evidence=True):
                validate_native_archive(owner, checkout)
            with native_retirement_authorization(authorize):
                validate_native_location(location, operation='complete-absent-recovery')
                with native_retirement_boundary('durability', 'sync-retirement-parent'):
                    sync_native_directory(original.parent)
                owner['retirementPhase'] = 'retired'
            return NativeRetirementOutcome('retired', 'registered-sources-already-absent')
        if location.phase is not None:
            owner['retirementPhase'] = location.phase

        # A durable deleting proof replaces the intact-tree prerequisites that rmtree consumes.
        if root != original and owner.get('retirementPhase') == 'deleting':
            archive_snapshots = {}
            with native_retirement_boundary('archive', 'validate-archive', evidence=True):
                archive = validate_native_archive(owner, checkout, snapshots=archive_snapshots)
            if not owner.get('deletionProof'):
                with native_retirement_boundary('source', 'upgrade-legacy-deletion-proof', evidence=True):
                    legacy_proof = upgrade_legacy_native_deletion(root, owner, descriptors)
                if persist is None:
                    return NativeRetirementOutcome('deferred', 'retirement-registration-required', 'registration')
                with native_retirement_authorization(authorize):
                    validate_native_location(location, operation='publish-legacy-proof')
                    if tuple(legacy_proof['parentIdentity']) != location.parent_identity:
                        raise NativeRetirementFault(NativeRetirementOutcome('retained', 'source-invalid', 'source', 'publish-legacy-proof'))
                    owner['deletionProof'] = legacy_proof
                    owner['retirementParentIdentity'] = parent_identity
                    with native_retirement_boundary('registration', 'publish-deleting-proof'):
                        persist(owner)
            with native_retirement_boundary('source', 'validate-deletion-proof', evidence=True):
                validate_native_deletion(root, original, owner, allow_missing=True, operation='resume-deletion')
            with native_retirement_authorization(authorize):
                validate_native_location(location, operation='resume-deletion')
                with native_retirement_boundary('archive', 'recheck-archive', evidence=True):
                    recheck_native_archive(archive, archive_snapshots)
                with native_retirement_boundary('source', 'resume-deletion', evidence=True):
                    validate_native_deletion(root, original, owner, allow_missing=True, operation='resume-deletion')
                validate_native_location(location, operation='remove-quarantine')
                with native_retirement_boundary('deletion', 'remove-quarantine'):
                    shutil.rmtree(root)
                with native_retirement_boundary('durability', 'sync-retirement-parent'):
                    sync_native_directory(root.parent)
            owner['retirementPhase'] = 'retired'
            return NativeRetirementOutcome('retired')

        if not source_owned:
            with native_retirement_boundary('source', 'acquire-lease', evidence=True):
                lease, _ = open_owned_regular(root / 'invocation.lease')
                descriptors.append(lease)
                fcntl.flock(lease, fcntl.LOCK_EX | fcntl.LOCK_NB)
        archive_snapshots = {}
        with native_retirement_boundary('archive', 'validate-archive', evidence=True):
            if not owner.get('collectionComplete'):
                return NativeRetirementOutcome('retained', 'archive-incomplete', 'archive')
            if 'archive' in evidence:
                archive, archive_snapshots = evidence['archive'], evidence['archiveSnapshots']
                recheck_native_archive(archive, archive_snapshots)
            else:
                archive = validate_native_archive(owner, checkout, snapshots=archive_snapshots)
        with native_retirement_boundary('source', 'validate-inventory', evidence=True):
            manifest, _ = open_owned_regular(root / 'native-owner.json', maximum=1024 * 1024)
            descriptors.append(manifest)
            current = json.loads(os.read(manifest, 1024 * 1024))
            if not isinstance(current, dict):
                raise ValueError('Invalid native owner')
            if any(current.get(key) != owner.get(key) for key in ('invocationID', 'checkout', 'directoryIdentity', 'files', 'collectionComplete')):
                return NativeRetirementOutcome('retained', 'owner-changed', 'source')
            expected = {'native-owner.json', 'invocation.lease'}
            directories = {}
            for folder in ('Progress', 'Stderr'):
                path = root / folder
                if path.exists() or path.is_symlink():
                    directories[folder] = native_directory_identity(path)
            for item in owner['files']:
                relative = item['folder'] + '/' + item['name']
                expected.add(relative)
                source, info = native_source_file(root, relative, evidence, descriptors)
                if not source_owned:
                    fcntl.flock(source, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    info = locked_native_file_info(root / relative, source)
                if [info.st_dev, info.st_ino] != item['identity']:
                    raise NativeEvidenceError('Native source identity changed')
                validated = evidence.get('sourceSnapshots', {}).get(relative) == native_stat_snapshot(info)
                if (info.st_size != item['bytes'] or not validated and descriptor_digest(source) != item['sha256'] or
                        native_stat_snapshot(os.fstat(source)) != native_stat_snapshot(info)):
                    return NativeRetirementOutcome('retained', 'source-or-archive-changed', 'source')
            actual = {str(path.relative_to(root)) for path in root.rglob('*') if str(path.relative_to(root)) not in directories}
            if actual != expected:
                return NativeRetirementOutcome('retained', 'unexpected-source-content', 'source')
            validate_native_location(location, operation='prepare-deletion-proof')
            proof = native_deletion_proof(root, owner, parent_identity=location.parent_identity)
        if persist is None:
            return NativeRetirementOutcome('deferred', 'retirement-registration-required', 'registration')
        quarantine = root if root != original else root.with_name('.gitx-native-retired-' + uuid.uuid4().hex)
        if root == original:
            with native_retirement_authorization(authorize):
                validate_native_location(location, operation='publish-prepared')
                # No preparation fields escape a refused authorization.
                owner.update(retirementPath=str(quarantine), retirementState='prepared', retirementPhase='prepared',
                             retirementParentIdentity=parent_identity)
                with native_retirement_boundary('registration', 'publish-prepared'):
                    persist(owner)
                with native_retirement_boundary('source', 'rename-quarantine', evidence=True):
                    validate_native_location(location, operation='rename-quarantine')
                    exclusive_native_rename(root, quarantine, sync_parent=True)
        validate_native_location(location, root=quarantine, operation='validate-quarantine')
        with native_retirement_boundary('source', 'validate-quarantine', evidence=True):
            owner['deletionProof'] = proof
            validate_native_deletion(quarantine, original, owner, allow_missing=False, operation='validate-quarantine')
        with native_retirement_authorization(authorize):
            validate_native_location(location, root=quarantine, operation='delete-quarantine')
            with native_retirement_boundary('archive', 'recheck-archive', evidence=True):
                recheck_native_archive(archive, archive_snapshots)
            with native_retirement_boundary('source', 'validate-quarantine', evidence=True):
                validate_native_deletion(quarantine, original, owner, allow_missing=False, operation='validate-quarantine')
            owner['retirementPhase'] = 'deleting'
            with native_retirement_boundary('registration', 'publish-deleting'):
                persist(owner)
            validate_native_location(location, root=quarantine, operation='remove-quarantine')
            with native_retirement_boundary('source', 'validate-quarantine', evidence=True):
                validate_native_deletion(quarantine, original, owner, allow_missing=False, operation='validate-quarantine')
            with native_retirement_boundary('deletion', 'remove-quarantine'):
                shutil.rmtree(quarantine)
            with native_retirement_boundary('durability', 'sync-retirement-parent'):
                sync_native_directory(quarantine.parent)
        owner['retirementPhase'] = 'retired'
        return NativeRetirementOutcome('retired')
    except NativeRetirementFault as error:
        return error.outcome
    finally:
        for descriptor in descriptors:
            os.close(descriptor)


class NativeRetirementDeferred(RuntimeError):
    pass


def native_completion_path(registration):
    return pathlib.Path(registration).parent / 'Completions' / pathlib.Path(registration).name


def publish_native_completion(registration, owner):
    """A lock-independent, immutable handoff survives a busy registration publisher."""
    path = native_completion_path(registration)
    path.parent.mkdir(mode=0o700, exist_ok=True)
    native_directory_identity(path.parent)
    temporary = path.with_name('.pending-' + uuid.uuid4().hex)
    try:
        atomic_json(temporary, {'schemaVersion': 1, 'kind': 'gitx-native-completion', 'owner': owner})
        exclusive_native_rename(temporary, path, sync_parent=True)
    finally:
        with contextlib.suppress(FileNotFoundError):
            temporary.unlink()


NATIVE_OWNER_IDENTITY = ('kind', 'schemaVersion', 'invocationID', 'checkout', 'sourceDirectory', 'directoryIdentity', 'artifactDirectory')
NATIVE_FINAL_FIELDS = ('status', 'files', 'collectionComplete', 'finishedAt', 'archiveDirectoryIdentity')


def read_native_object(path):
    descriptor, _ = open_owned_regular(path, maximum=1024 * 1024)
    with os.fdopen(descriptor, 'rb') as stream:
        value = json.load(stream)
    if not isinstance(value, dict):
        raise ValueError('Invalid native object')
    return value


class NativeSourceOwnership:
    def __init__(self, root):
        self.root = root
        self.files = {}

    def inspect(self, root, relative):
        if root != self.root or relative not in self.files:
            raise NativeEvidenceError('Source was not owned at admission')
        descriptor, snapshot = self.files[relative]
        info = os.fstat(descriptor)
        if (native_stat_snapshot(info) != snapshot or
                native_stat_snapshot((root / relative).lstat()) != snapshot):
            raise NativeEvidenceError('Owned source changed')
        return descriptor, info


def native_source_file(root, relative, evidence, descriptors):
    if ownership := evidence.get('sourceOwnership'):
        return ownership.inspect(root, relative)
    descriptor, info = open_owned_regular(root / relative)
    descriptors.append(descriptor)
    return descriptor, info


@contextlib.contextmanager
def native_source_ownership(owner):
    """Keep root and inherited file writers excluded through metadata recovery."""
    descriptors = []
    try:
        with native_retirement_boundary('source', 'inspect-writer-root', evidence=True):
            root = pathlib.Path(owner['sourceDirectory'])
            if root.is_symlink() or root.resolve() != root or native_directory_identity(root) != owner['directoryIdentity']:
                raise ValueError('Native source ownership changed')
            ownership = NativeSourceOwnership(root)
        with native_retirement_boundary('producer', 'acquire-invocation-lease'):
            lease, _ = open_owned_regular(root / 'invocation.lease')
            descriptors.append(lease)
            fcntl.flock(lease, fcntl.LOCK_EX | fcntl.LOCK_NB)
        for folder in ('Stderr', 'Progress'):
            path = root / folder
            with native_retirement_boundary('producer', 'inspect-writer-directory'):
                if native_path_absent(path):
                    continue
                native_directory_identity(path)
                entries = list(path.iterdir())
            for entry in entries:
                with native_retirement_boundary('source', 'inspect-writer-file', evidence=True):
                    try:
                        descriptor, info = open_owned_regular(entry)
                    except NativeEvidenceError:
                        raise
                    except OSError as error:
                        if error.errno in {errno.EACCES, errno.EPERM}:
                            raise NativeRetirementFault(NativeRetirementOutcome('deferred', 'producer-lease-unproven',
                                                        'producer', 'inspect-writer-file', error.errno)) from error
                        raise
                    descriptors.append(descriptor)
                with native_retirement_boundary('producer', 'acquire-file-lease'):
                    fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
                with native_retirement_boundary('source', 'snapshot-owned-writer', evidence=True):
                    locked = locked_native_file_info(entry, descriptor)
                    relative = str(entry.relative_to(root))
                    ownership.files[relative] = descriptor, native_stat_snapshot(locked)
                    ownership.inspect(root, relative)
        yield ownership
    finally:
        for descriptor in descriptors:
            os.close(descriptor)


def validate_native_completion_files(final, checkout, evidence):
    snapshots = {}
    with native_retirement_boundary('archive', 'validate-completion-archive', evidence=True):
        evidence['archive'] = validate_native_archive(final, checkout, snapshots=snapshots)
        evidence['archiveSnapshots'] = snapshots
    snapshots, descriptors = {}, []
    try:
        with native_retirement_boundary('source', 'validate-completion-source', evidence=True):
            root = pathlib.Path(final['sourceDirectory'])
            for item in final['files']:
                relative = item['folder'] + '/' + item['name']
                descriptor, info = native_source_file(root, relative, evidence, descriptors)
                if ([info.st_dev, info.st_ino] != item['identity'] or info.st_size != item['bytes'] or
                        descriptor_digest(descriptor) != item['sha256'] or
                        native_stat_snapshot(info) != native_stat_snapshot(os.fstat(descriptor))):
                    raise ValueError('Native completion source changed')
                snapshots[relative] = native_stat_snapshot(info)
            evidence['sourceSnapshots'] = snapshots
    finally:
        for descriptor in descriptors:
            os.close(descriptor)


def promote_native_completion(registration, *, checkout, authorize, evidence):
    """Reconcile either checkpoint order, after proving all writers quiescent."""
    prior = registration.current
    root = pathlib.Path(prior['sourceDirectory'])
    source_fault = None
    try:
        with native_retirement_boundary('completion', 'read-source-checkpoint', evidence=True):
            try:
                source_owner = read_native_object(root / 'native-owner.json')
            except FileNotFoundError:
                source_owner = None
            if source_owner and any(source_owner.get(key) != prior.get(key) for key in NATIVE_OWNER_IDENTITY):
                raise ValueError('Native source checkpoint identity changed')
    except NativeRetirementFault as error:
        source_owner, source_fault = None, error
    if source_owner and source_owner.get('status') != 'running' and prior.get('status') != 'running':
        if any(source_owner.get(key) != prior.get(key) for key in NATIVE_FINAL_FIELDS):
            raise NativeRetirementFault(NativeRetirementOutcome('retained', 'completion-conflict', 'completion', 'compare-completed-checkpoints'))
        # Matching completed counterparts do not depend on an unused handoff.
        return
    with native_retirement_boundary('completion', 'validate-completion', evidence=True):
        path = native_completion_path(registration.path)
        try:
            native_directory_identity(path.parent)
            completion = read_native_object(path)
        except FileNotFoundError:
            completion = None
        if completion is None:
            if producer_state(prior.get('producer')) != 'abandoned':
                raise NativeRetirementFault(NativeRetirementOutcome('deferred', 'live native producer', 'producer', 'await-completion'))
            return
        final = completion.get('owner')
        if (completion.get('schemaVersion') != 1 or completion.get('kind') != 'gitx-native-completion' or
                not isinstance(final, dict) or any(prior.get(key) != final.get(key) for key in NATIVE_OWNER_IDENTITY) or
                final.get('status') not in {'passed', 'failed'}):
            raise ValueError('Invalid native finalization identity')
        for counterpart in (prior, source_owner):
            if counterpart and counterpart.get('status') != 'running' and any(counterpart.get(key) != final.get(key) for key in NATIVE_FINAL_FIELDS):
                raise ValueError('Conflicting completed evidence')
        if native_directory_identity(root) != final['directoryIdentity']:
            raise ValueError('Native finalization source changed')
        if 'archiveDirectoryIdentity' in final and native_directory_identity(final['artifactDirectory']) != final['archiveDirectoryIdentity']:
            raise ValueError('Native finalization archive changed')
    evidence['logicalCompletion'] = True
    if source_fault:
        raise source_fault
    if final.get('collectionComplete'):
        validate_native_completion_files(final, checkout, evidence)
    promoted = dict(prior)
    promoted.update({key: final[key] for key in NATIVE_FINAL_FIELDS if key in final})
    if promoted != prior:
        with native_retirement_authorization(authorize):
            validate_native_location(evidence['location'], operation='promote-completion')
            with native_retirement_boundary('registration', 'promote-completion'):
                registration.publish(promoted)
    # A publication failure after the authoritative ledger update is recoverable:
    # keep the immutable handoff until both checkpoints agree or retirement ends.
    if source_owner is None or source_owner == {} or source_owner.get('status') == 'running':
        with native_retirement_authorization(authorize):
            validate_native_location(evidence['location'], operation='repair-source-checkpoint')
            with native_retirement_boundary('completion', 'repair-source-checkpoint'):
                if native_directory_identity(root) != final['directoryIdentity']:
                    raise ValueError('Native source replaced before repair')
                try:
                    current = read_native_object(root / 'native-owner.json')
                except FileNotFoundError:
                    current = None
                if current != source_owner:
                    raise NativeRegistrationChanged()
                atomic_json(root / 'native-owner.json', final)
                sync_native_directory(root)


def publish_native_retirement_outcome(registration, outcome, authorize, *, location=None):
    owner = dict(registration.current)
    # Authorization and uncertain publications are diagnostic only. Never turn
    # them into sticky evidence or overwrite a record advanced by another writer.
    if not native_outcome_is_publishable(outcome):
        return dict(owner, retirementOutcome=outcome.metadata())
    with native_retirement_authorization(authorize):
        if outcome.state == 'retired' and location is not None:
            validate_native_location(location, root=owner.get('retirementPath', location.root), absent=True, operation='publish-retired')
        owner.update(retirementState=outcome.state, retirementReason=outcome.reason, retirementOutcome=outcome.metadata())
        if outcome.state == 'retired':
            owner['retirementPhase'] = 'retired'
        with native_retirement_boundary('registration', 'publish-retirement-outcome'):
            registration.publish(owner)
        if outcome.state == 'retired':
            owner = dict(owner, handoffCleanup=_cleanup_native_completion_authorized(registration.path, owner).metadata())
    return owner


def cleanup_native_completion(path, owner, *, authorize=None):
    try:
        return _cleanup_native_completion_authorized(path, owner, authorize=authorize)
    except NativeRetirementFault as error:
        return error.outcome


def _cleanup_native_completion_authorized(path, owner, *, authorize=None):
    """Remove only a proven duplicate; its outcome never changes source status."""
    completion = native_completion_path(path)
    directory = descriptor = None
    try:
        with native_retirement_boundary('handoff', 'validate-redundant-handoff', evidence=True):
            if owner.get('retirementState') != 'retired' or not owner.get('collectionComplete'):
                return NativeRetirementOutcome('retained', 'handoff-unresolved', 'handoff')
            try:
                identity = native_directory_identity(completion.parent)
                directory = os.open(completion.parent, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC)
                info = os.fstat(directory)
                if [info.st_dev, info.st_ino] != identity or info.st_uid != os.getuid():
                    raise ValueError('Completion directory changed')
                descriptor, info = open_owned_regular(completion.name, directory=directory, maximum=1024 * 1024)
            except FileNotFoundError:
                return NativeRetirementOutcome('absent', origin='handoff')
            snapshot = native_stat_snapshot(info)
            completion_owner = json.loads(os.read(descriptor, 1024 * 1024))
            if (not isinstance(completion_owner, dict) or completion_owner.get('schemaVersion') != 1 or
                    completion_owner.get('kind') != 'gitx-native-completion' or not isinstance(completion_owner.get('owner'), dict) or
                    any(completion_owner['owner'].get(key) != owner.get(key) for key in NATIVE_OWNER_IDENTITY + NATIVE_FINAL_FIELDS)):
                raise ValueError('Completion does not match retired registration')
        with native_retirement_authorization(authorize), native_retirement_boundary('handoff', 'remove-redundant-handoff', evidence=True):
            # Only a short metadata transaction; no hashing or recursive work.
            with NativeRegistration(path) as transaction:
                if transaction.current != owner:
                    raise NativeRegistrationChanged()
                if (not native_path_absent(owner['sourceDirectory']) or
                        not native_path_absent(owner.get('retirementPath', owner['sourceDirectory']))):
                    return NativeRetirementOutcome('retained', 'handoff-sources-present', 'handoff', 'remove-redundant-handoff')
                if (native_directory_identity(completion.parent) != identity or
                        native_stat_snapshot(os.stat(completion.name, dir_fd=directory, follow_symlinks=False)) != snapshot):
                    raise NativeRegistrationChanged()
                os.unlink(completion.name, dir_fd=directory)
                os.fsync(directory)
        return NativeRetirementOutcome('removed', origin='handoff', operation='remove-redundant-handoff')
    except NativeRetirementFault as error:
        return error.outcome
    finally:
        if descriptor is not None:
            os.close(descriptor)
        if directory is not None:
            os.close(directory)


def native_retirement_result(path, owner, *, authorize=None):
    state, reason = owner['retirementState'], owner.get('retirementReason')
    if state == 'retired':
        owner = dict(owner, handoffCleanup=cleanup_native_completion(path, owner, authorize=authorize).metadata())
    return state, reason, owner


def retire_registered_native_sources(path, *, checkout=None, authorize=None, admit=None, retry_retained=False):
    """Keep the public three-value wrapper; internal outcomes use named fields."""
    owner = None
    try:
        checkout = pathlib.Path(checkout or ROOT)
        with native_retirement_boundary('registration', 'inspect-registration'):
            owner = read_native_object(path)
        retirement_path = pathlib.Path(path).with_name(pathlib.Path(path).name + '.retirement.lock')
        with NativeControlLease(retirement_path, boundary=lambda: native_retirement_boundary('registration', 'acquire-retirement-lease')):
            with native_retirement_boundary('registration', 'open-registration-transaction'):
                registration = NativeRegistrationSnapshot(path, retry_retained=retry_retained)
            owner = dict(registration.current)
            if owner.get('invocationID') != pathlib.Path(path).stem or owner.get('checkout') != str(checkout.resolve()):
                raise ValueError('Native registration ownership changed')
            if owner.get('retirementState') == 'retained' and not retry_retained:
                return owner['retirementState'], owner.get('retirementReason'), owner
            if admit:
                with native_retirement_boundary('authorization', 'admit-native-retirement'):
                    if reason := admit():
                        raise NativeRetirementDeferred(reason)
            if owner.get('retirementState') == 'retired':
                return native_retirement_result(path, owner, authorize=authorize)
            # A prepared/deleting quarantine already has published completed
            # evidence; its durable proof deliberately permits missing controls.
            try:
                location = native_retirement_location(owner, checkout, retry_retained=retry_retained)
                recovering = location.recovering
                with (contextlib.nullcontext() if recovering else native_source_ownership(owner)) as ownership:
                    validate_native_location(location, operation='owned-location')
                    evidence = {'sourceOwnership': ownership} if ownership else {}
                    evidence['location'] = location
                    try:
                        if not recovering:
                            promote_native_completion(registration, checkout=checkout, authorize=authorize, evidence=evidence)
                        validate_native_location(location, operation='post-promotion-location')
                        owner = dict(registration.current)
                        outcome = retire_native_sources(owner, checkout=checkout, persist=registration.publish,
                                                        authorize=authorize, source_owned=not recovering, evidence=evidence, location=location)
                    except NativeRetirementFault as error:
                        outcome = error.outcome
                        # Quiescent descriptors alone do not prove logical completion
                        # of a live supervisor lacking a usable final handoff.
                        if (registration.current.get('status') == 'running' and
                                producer_state(registration.current.get('producer')) != 'abandoned' and
                                outcome.origin not in {'authorization', 'registration'} and not evidence.get('logicalCompletion')):
                            outcome = NativeRetirementOutcome('deferred', 'completion-unconfirmed', 'producer', outcome.operation, outcome.error_number)
                    owner = publish_native_retirement_outcome(registration, outcome, authorize, location=location)
                    return outcome.state, outcome.reason, owner
            except NativeRetirementFault as error:
                # Completed registrations can record protected missing/invalid
                # evidence. A running or uncertain writer remains untouched.
                if error.outcome.state == 'retained' and registration.current.get('status') != 'running':
                    owner = publish_native_retirement_outcome(registration, error.outcome, authorize)
                    return error.outcome.state, error.outcome.reason, owner
                if (error.outcome.state == 'retained' and registration.current.get('status') == 'running' and
                        producer_state(registration.current.get('producer')) != 'abandoned'):
                    raise NativeRetirementFault(NativeRetirementOutcome('deferred', 'producer-lease-unproven',
                                                'producer', error.outcome.operation, error.outcome.error_number)) from error
                raise
    except NativeRetirementFault as error:
        return error.outcome.state, error.outcome.reason, dict(owner or {}, retirementOutcome=error.outcome.metadata())
    except (OSError, ValueError, TypeError, KeyError) as error:
        reason = 'registration-writer-held' if isinstance(error, BlockingIOError) else 'registration-publication-unproven'
        outcome = NativeRetirementOutcome('deferred', reason, 'registration', 'publish-registration', getattr(error, 'errno', None))
        return outcome.state, outcome.reason, dict(owner or {}, retirementOutcome=outcome.metadata())


def read_native_registration(path, root):
    owner = read_native_object(path)
    if (owner.get('kind') != 'gitx-native-invocation' or owner.get('schemaVersion') != 1 or
            owner.get('checkout') != str(pathlib.Path(root).resolve()) or pathlib.Path(path).stem != owner.get('invocationID')):
        return None
    return owner


def registered_native_sources(root=ROOT):
    """Discover only explicit registrations; never adopt historical fixture directories."""
    directory = verification_artifact_root(root) / 'NativeSources'
    try:
        native_directory_identity(directory)
    except FileNotFoundError:
        return []
    result = []
    for path in directory.iterdir():
        if path.suffix != '.json':
            continue
        try:
            if (owner := read_native_registration(path, root)) and owner.get('retirementState') != 'retired':
                result.append((path, owner))
        except (OSError, ValueError):
            continue
    return result


def registered_native_completions(root=ROOT):
    """Only explicit retired audit records can identify older duplicate handoffs."""
    directory = verification_artifact_root(root) / 'NativeSources'
    try:
        native_directory_identity(directory)
        native_directory_identity(directory / 'Completions')
    except FileNotFoundError:
        return []
    result = []
    for completion in (directory / 'Completions').iterdir():
        if completion.suffix != '.json':
            continue
        path = directory / completion.name
        try:
            if (owner := read_native_registration(path, root)) and owner.get('retirementState') == 'retired':
                result.append((path, owner))
        except (OSError, ValueError):
            continue
    return result


class NativeTestDiagnostics:
    """Own cache sources, incremental archives and one canonical console sink."""

    def __init__(self, root, artifact_directory, session, bundles, capture_stderr):
        self.invocation, self.session = uuid.uuid4().hex, session
        self.requested = capture_stderr
        self.warnings = set()
        self.archive = pathlib.Path(artifact_directory) / self.invocation
        self.registration = verification_artifact_root(ROOT) / 'NativeSources' / (self.invocation + '.json')
        self.output = lambda data: None
        self.sources, self.cursor = {}, 0
        self.archive_identity = None
        self.emitted_bytes = 0
        self.root = self.lease = self.progress = None
        self.closed, self.archive_ready = False, False
        self.next_discovery = 0
        self.owner = {'schemaVersion': 1, 'kind': 'gitx-native-invocation', 'checkout': str(ROOT.resolve()),
                      'invocationID': self.invocation, 'verificationSession': session, 'status': 'running',
                      'producer': producer_identity(), 'startedAt': dt.datetime.now(dt.timezone.utc).isoformat(),
                      'artifactDirectory': str(self.archive), 'collectionComplete': False, 'retirementState': 'pending'}
        fallback = native_fallback_root()
        operation = 'create-directory'
        for index, selected in enumerate((pathlib.Path(root), fallback)):
            try:
                if not selected.is_absolute() or selected.is_symlink():
                    raise OSError(errno.EINVAL, 'Invalid native diagnostic root')
                selected.mkdir(parents=True, exist_ok=True, mode=0o700)
                self.root = pathlib.Path(tempfile.mkdtemp(prefix='invocation-', dir=selected.resolve()))
                self.progress_directory = self.root / 'Progress'
                self.progress_directory.mkdir(mode=0o700)
                operation = 'probe-publication'
                pending, published = self.progress_directory / '.probe-pending', self.progress_directory / '.probe-complete'
                with pending.open('xb') as stream:
                    stream.write(b'{}')
                    stream.flush()
                    os.fsync(stream.fileno())
                exclusive_native_rename(pending, published)
                published.unlink()
                operation = 'open-lease'
                self.lease = os.open(self.root / 'invocation.lease', os.O_RDWR | os.O_CREAT | os.O_EXCL | os.O_CLOEXEC, 0o600)
                fcntl.flock(self.lease, fcntl.LOCK_SH | fcntl.LOCK_NB)
                operation = 'open-progress'
                self.progress = NativeTestProgress(self.progress_directory, self.invocation, session, bundles)
                self.owner.update(sourceDirectory=str(self.root), directoryIdentity=native_directory_identity(self.root))
                operation = 'publish-owner'
                atomic_json(self.root / 'native-owner.json', self.owner)
                break
            except (OSError, ValueError) as error:
                if self.progress is not None:
                    self.progress.close()
                    self.progress = None
                if self.lease is not None:
                    os.close(self.lease)
                    self.lease = None
                if self.root is not None:
                    with contextlib.suppress(OSError):
                        shutil.rmtree(self.root)
                    self.root = None
                if index:
                    raise NativeProgressSetupError(operation, error) from error
                self.warnings.add('cache-directory')
                capture_stderr = False
                operation = 'create-directory'
        self.stderr_directory = self.root / 'Stderr'
        self.capture_enabled = capture_stderr
        if capture_stderr:
            try:
                self.stderr_directory.mkdir(mode=0o700)
            except OSError:
                self.capture_enabled = False
                self.warnings.add('capture-directory')
        try:
            if (self.archive.parent.is_symlink() or
                    not self.archive.resolve().is_relative_to(verification_artifact_root(ROOT).resolve())):
                raise ValueError('Invalid native artifact directory')
            self.archive.mkdir(parents=True, mode=0o700)
            self.archive_identity = native_directory_identity(self.archive)
            self.owner['archiveDirectoryIdentity'] = self.archive_identity
            self.archive_ready = True
        except (OSError, ValueError):
            self.warnings.add('collection-incomplete')
        self._checkpoint()

    def _checkpoint(self):
        for path in (self.root / 'native-owner.json', self.registration):
            try:
                if path == self.root / 'native-owner.json' and native_directory_identity(self.root) != self.owner['directoryIdentity']:
                    raise OSError(errno.EPERM, 'Native source root changed')
                if path.parent.is_symlink():
                    raise OSError(errno.EPERM, 'Native metadata directory changed')
                if path == self.registration:
                    persist_native_registration(path, self.owner)
                else:
                    atomic_json(path, self.owner)
            except (OSError, ValueError):
                self.warnings.add('metadata-retention')
        if self.archive_ready:
            try:
                if native_directory_identity(self.archive) != self.archive_identity:
                    raise OSError(errno.EPERM, 'Native archive changed')
                atomic_json(self.archive / 'native-diagnostics.json', self.owner | {'warnings': sorted(self.warnings)})
            except OSError:
                self.warnings.add('metadata-retention')

    def configure(self, environment):
        values = {'GITX_TEST_PROGRESS_DIRECTORY': str(self.progress_directory),
                  'GITX_TEST_INVOCATION_ID': self.invocation, 'GITX_VERIFICATION_SESSION': self.session,
                  'GITX_TEST_STDERR_DIRECTORY': str(self.stderr_directory) if self.capture_enabled else ''}
        for key, value in values.items():
            environment[key] = value
            environment['TEST_RUNNER_' + key] = value

    def _discover(self):
        for folder in ('Progress', 'Stderr'):
            directory = self.root / folder
            if folder == 'Stderr' and not self.capture_enabled:
                continue
            try:
                native_directory_identity(directory)
                for source in directory.iterdir():
                    allowed = NATIVE_RECORD_NAME.fullmatch(source.name) if folder == 'Progress' else (
                        NATIVE_STDERR_NAME.fullmatch(source.name) or NATIVE_CAPTURE_RECORD_NAME.fullmatch(source.name))
                    if not allowed or (folder, source.name) in self.sources:
                        continue
                    descriptor, info = open_owned_regular(source)
                    os.close(descriptor)
                    self.sources[(folder, source.name)] = {'identity': (info.st_dev, info.st_ino), 'archived': 0,
                                                          'mirrored': 0, 'output': None, 'archiveIdentity': None}
            except OSError:
                self.warnings.add('capture-read' if folder == 'Stderr' else 'progress-read')

    def _archive_chunk(self, source, state, limit):
        if not self.archive_ready:
            return
        try:
            if native_directory_identity(self.archive) != self.archive_identity:
                raise OSError(errno.EPERM, 'Native archive changed')
            if state['output'] is None:
                descriptor = os.open(self.archive / source.name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600)
                state['output'] = descriptor
                info = os.fstat(descriptor)
                state['archiveIdentity'] = (info.st_dev, info.st_ino)
            descriptor, info = open_owned_regular(source, identity=state['identity'])
            with os.fdopen(descriptor, 'rb') as stream:
                if info.st_size < state['archived']:
                    raise OSError(errno.EIO, 'Native source was truncated')
                stream.seek(state['archived'])
                data = stream.read(limit)
            remaining = memoryview(data)
            while remaining:
                count = os.write(state['output'], remaining)
                if count <= 0:
                    raise OSError(errno.EIO, 'Native archive write made no progress')
                state['archived'] += count
                remaining = remaining[count:]
        except OSError:
            self.warnings.add('collection-incomplete')

    def _mirror_chunk(self, source, state, limit):
        try:
            descriptor, info = open_owned_regular(source, identity=state['identity'])
            with os.fdopen(descriptor, 'rb') as stream:
                if info.st_size < state['mirrored']:
                    raise OSError(errno.EIO, 'Native source was truncated')
                stream.seek(state['mirrored'])
                data = stream.read(limit)
        except OSError:
            self.warnings.add('capture-read')
            return
        if data:
            self.output(data)
            state['mirrored'] += len(data)
            self.emitted_bytes += len(data)

    def poll(self):
        now = time.monotonic()
        if now >= self.next_discovery:
            self._discover()
            self.next_discovery = now + .2
        items = list(self.sources.items())
        if items:
            # Rotate rather than repeatedly favoring the first launches.
            for index in range(min(16, len(items))):
                (folder, name), state = items[(self.cursor + index) % len(items)]
                source = self.root / folder / name
                self._archive_chunk(source, state, 65536)
                if folder == 'Stderr' and NATIVE_STDERR_NAME.fullmatch(name):
                    self._mirror_chunk(source, state, 65536)
            self.cursor = (self.cursor + 16) % len(items)
        try:
            return self.progress.observed()
        except OSError as error:
            raise NativeProgressSetupError('read-progress', error) from error

    def close(self):
        if self.closed:
            return self.result
        self.result = {'invocationID': self.invocation, 'sourceDirectory': str(self.root),
                       'artifactDirectory': str(self.archive), 'captureRequested': self.requested,
                       'captures': [], 'files': [], 'warnings': [], 'collectionComplete': False}
        try:
            self._finish()
        finally:
            for state in self.sources.values():
                if state['output'] is not None:
                    try:
                        os.close(state['output'])
                    except OSError:
                        self.warnings.add('collection-close')
            self.owner.update(status='passed' if self.result['collectionComplete'] else 'failed',
                              files=self.result['files'], collectionComplete=self.result['collectionComplete'],
                              finishedAt=dt.datetime.now(dt.timezone.utc).isoformat())
            try:
                publish_native_completion(self.registration, self.owner)
            except (OSError, ValueError):
                self.warnings.add('completion-publication')
            self._checkpoint()
            try:
                self.progress.close()
            finally:
                os.close(self.lease)
            self.closed = True
            state, reason, registered = retire_registered_native_sources(self.registration)
            if registered and 'handoffCleanup' in registered:
                self.result['handoffCleanup'] = registered['handoffCleanup']
            if registered:
                self.owner.update({key: registered[key] for key in ('retirementPath', 'retirementParentIdentity', 'retirementPhase') if key in registered})
            self.owner.update(retirementState=state, retirementReason=reason)
            self.result.update(retirementState=state, retirementReason=reason, warnings=sorted(self.warnings))
            if self.archive_ready:
                with contextlib.suppress(OSError):
                    atomic_json(self.archive / 'native-diagnostics.json', self.result)
        return self.result

    def _fallback_capture_records(self):
        if not self.capture_enabled:
            return []
        descriptor = os.open(self.stderr_directory, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC)
        try:
            if os.fstat(descriptor).st_uid != os.getuid():
                raise OSError(errno.EPERM, 'Capture record directory owner changed')
            return [record for folder, name in self.sources if folder == 'Stderr' and NATIVE_CAPTURE_RECORD_NAME.fullmatch(name)
                    if (record := read_native_record(descriptor, name, self.invocation, self.session)) is not None
                    and record.get('event') == 'capture']
        finally:
            os.close(descriptor)

    def _finish(self):
        self._discover()
        captures, metadata_complete = [], True
        for channel, read in (('primary', self.progress.records), ('fallback', self._fallback_capture_records)):
            try:
                captures.extend(record for record in read() if record.get('event') == 'capture')
            except OSError:
                metadata_complete = False
                self.warnings.add('capture-record-' + channel)
        if any(record.get('publicationError') for record in captures):
            self.warnings.add('capture-publication')
        if self.requested:
            represented = {record.get('filename') for record in captures}
            if not captures or any(folder == 'Stderr' and NATIVE_STDERR_NAME.fullmatch(name) and name not in represented
                                   for folder, name in self.sources):
                self.warnings.add('capture-unconfirmed')
            if any(record.get('state') == 'unavailable' for record in captures):
                self.warnings.add('capture-unavailable')
        collected, complete, forwarded = [], self.archive_ready, True
        for (folder, name), state in self.sources.items():
            source = self.root / folder / name
            try:
                descriptor, info = open_owned_regular(source, identity=state['identity'])
                with os.fdopen(descriptor, 'rb') as stream:
                    target = info.st_size  # Final drainage cannot chase a live writer indefinitely.
                    if state['output'] is None:
                        self._archive_chunk(source, state, 0)
                    while state['archived'] < target:
                        previous = state['archived']
                        self._archive_chunk(source, state, min(65536, target - previous))
                        if state['archived'] == previous:
                            break
                    if folder == 'Stderr' and NATIVE_STDERR_NAME.fullmatch(name):
                        while state['mirrored'] < target:
                            previous = state['mirrored']
                            self._mirror_chunk(source, state, min(65536, target - previous))
                            if state['mirrored'] == previous:
                                break
                        forwarded &= state['mirrored'] == target
                    if state['output'] is not None:
                        os.fsync(state['output'])
                    digest_value = descriptor_digest(stream.fileno())
                    complete &= state['archived'] == target and os.fstat(stream.fileno()).st_size == target
                    copied, copied_info = open_owned_regular(self.archive / name, identity=state['archiveIdentity'])
                    with os.fdopen(copied, 'rb') as copy:
                        complete &= copied_info.st_size == target and descriptor_digest(copy.fileno()) == digest_value
                    collected.append({'folder': folder, 'name': name, 'identity': list(state['identity']),
                                      'archiveIdentity': list(state['archiveIdentity']) if state['archiveIdentity'] else [],
                                      'bytes': target, 'sha256': digest_value})
            except OSError:
                complete = False
                self.warnings.add('collection-incomplete')
        complete &= not self.warnings.intersection({'capture-read', 'progress-read'})
        self.result.update(captures=captures, captureMetadataComplete=metadata_complete, files=collected, collectionComplete=bool(complete),
                           collectionScope='observed-files-at-command-completion', nativeForwardComplete=forwarded,
                           mirroredBytes=self.emitted_bytes)
        if not complete:
            self.warnings.add('collection-incomplete')
        if self.warnings:
            message = ('Native diagnostics warning: ' + ', '.join(sorted(self.warnings)) + '\n').encode()
            self.output(message)
            if self.archive_ready:
                with contextlib.suppress(OSError):
                    (self.archive / 'warnings.log').write_bytes(message)


def supervise(command, timeout=7200, startup_timeout=None, desktop=False, directory=None, env=None, pass_fds=(), merge_stderr=True, cwd=None, output_log=None, native_test_root=None, native_artifact_directory=None,
              native_test_bundles=None, capture_native_stderr=False):
    """Bound a process group, retaining diagnostics and killing only that group."""
    directory = pathlib.Path(directory) if directory is not None else verification_artifact_root(ROOT) / "diagnostics" / ("owned-" + uuid.uuid4().hex)
    keeper = None
    child_env = dict(env or os.environ)
    tag = child_env.get("GITX_SESSION_ID", uuid.uuid4().hex)
    existing = set(subprocess.run(["ps", "-axo", "pid="], capture_output=True, text=True).stdout.split()) if desktop else set()
    if desktop:
        child_env["GITX_VERIFICATION_SESSION"] = tag
        child_env["TEST_RUNNER_GITX_VERIFICATION_SESSION"] = tag
    directory.mkdir(parents=True, exist_ok=True)
    manifest = directory / "diagnostic-owner.json"
    if directory.is_symlink() or manifest.is_symlink():
        raise ValueError("Refusing symlink diagnostic output")
    previous_owner = None
    try:
        previous_owner = json.loads(manifest.read_text()) if manifest.is_file() else None
    except (OSError, ValueError):
        pass
    owned = (isinstance(previous_owner, dict) and previous_owner.get("kind") == "gitx-diagnostics" and
             previous_owner.get("schemaVersion") == 1 and previous_owner.get("checkout") == str(ROOT.resolve()))
    if any(directory.iterdir()) and not owned:
        directory = directory / ("owned-" + uuid.uuid4().hex)
        directory.mkdir()
        manifest = directory / "diagnostic-owner.json"
    ownership = {"schemaVersion": 1, "kind": "gitx-diagnostics", "checkout": str(ROOT.resolve()),
                 "runId": tag, "producer": producer_identity(), "resources": [str(directory)],
                 "status": "running", "startedAt": dt.datetime.now(dt.timezone.utc).isoformat()}
    atomic_json(manifest, ownership)
    capture, native_diagnostics = None, None
    try:
        if native_test_root is not None:
            native_diagnostics = NativeTestDiagnostics(
                native_test_root, native_artifact_directory or directory / 'Native', tag,
                native_test_bundles or ['net.phere.GitXTests', 'net.phere.GitXUITests'], capture_native_stderr)
            native_diagnostics.configure(child_env)
            ownership['nativeDiagnostics'] = {'invocationID': native_diagnostics.invocation,
                'sourceDirectory': str(native_diagnostics.root), 'progressDirectory': str(native_diagnostics.progress_directory)}
            atomic_json(manifest, ownership)
            output_log = output_log or directory / 'command.log'
        capture = CapturedConsole(output_log) if output_log else None
        if native_diagnostics:
            native_diagnostics.output = capture.write
        child = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT if merge_stderr else None,
                                 start_new_session=True, env=child_env, pass_fds=pass_fds, cwd=cwd)
    except BaseException as error:
        if native_diagnostics:
            ownership['nativeDiagnostics'] = native_diagnostics.close()
        if capture:
            ownership['outputCapture'] = capture.close()
        category = 'native-progress-setup-failed' if isinstance(error, NativeProgressSetupError) else 'command-start-failed'
        details = {'operation': error.operation, 'errno': error.errno} if isinstance(error, NativeProgressSetupError) else {}
        atomic_json(manifest, ownership | {'status': 'failed', 'category': category, 'infrastructureError': details})
        if isinstance(error, NativeProgressSetupError):
            return 2
        raise
    if desktop and platform.system() == "Darwin":
        keeper = subprocess.Popen(["/usr/bin/caffeinate", "-di", "-w", str(child.pid)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    started, host_started, interrupted = time.monotonic(), False, None
    original = {}
    def host_startup(source):
        ownership['hostStartup'] = {"source": source, "observedAt": dt.datetime.now(dt.timezone.utc).isoformat()}
        with contextlib.suppress(OSError, ValueError):
            atomic_json(manifest, ownership)

    def interrupt(signum, _):
        nonlocal interrupted
        interrupted = signum
    for sig in (signal.SIGTERM, signal.SIGINT):
        original[sig] = signal.signal(sig, interrupt)
    selector = selectors.DefaultSelector()
    selector.register(child.stdout, selectors.EVENT_READ)
    buffered = b""
    category = None
    status = None
    try:
        while child.poll() is None or selector.get_map():
            elapsed = time.monotonic() - started
            if interrupted:
                category = "interrupted"
                break
            if elapsed > timeout:
                category = "command-timeout"
                break
            try:
                native_started = native_diagnostics.poll() if native_diagnostics else False
            except NativeProgressSetupError as error:
                ownership['infrastructureError'] = {'operation': error.operation, 'errno': error.errno}
                category = 'native-progress-unavailable'
                break
            except OSError:
                category = "output-capture-failed"
                break
            if not host_started and native_started:
                host_started = True
                host_startup("xctest-observer")
            if startup_timeout and not host_started and elapsed > startup_timeout:
                category = "unknown-host-startup-timeout"
                break
            for key, _ in selector.select(.2):
                data = os.read(key.fd, 65536)
                if not data:
                    selector.unregister(key.fileobj)
                    continue
                if capture:
                    try:
                        capture.write(data)
                    except OSError:
                        category = "output-capture-failed"
                        break
                else:
                    sys.stdout.buffer.write(data)
                    sys.stdout.buffer.flush()
                buffered = (buffered + data)[-65536:]
                if native_diagnostics:
                    failure = re.search(rb'GitXNativeStartupFailure invocation=' + native_diagnostics.invocation.encode() +
                                        rb' operation=([a-z-]+) category=([a-z-]+) errno=([0-9]+|none)', buffered)
                    if failure:
                        ownership['infrastructureError'] = {'operation': failure[1].decode(), 'category': failure[2].decode(),
                                                            'errno': None if failure[3] == b'none' else int(failure[3])}
                        category = 'native-startup-publication-failed'
                        break
                if not native_diagnostics and not host_started and test_output_started(buffered):
                    host_started = True
                    host_startup("command-output")
            if category:
                break
        if category:
            ownership['childExitCodeAtFailure'] = child.poll()
            detached = detached_owned_processes(tag, existing) if desktop else []
            # Every nested supervisor starts its own process group. A group
            # signal alone would orphan its compiler and release the outer
            # lease while that compiler still writes shared products.
            descendants = descendant_processes(child.pid)
            with contextlib.suppress(OSError, subprocess.SubprocessError):
                diagnostics(directory, child.pid, category, detached + descendants)
            message = f"\nVerification blocker: {category}. Diagnostics: {directory}\n"
            if capture:
                with contextlib.suppress(OSError):
                    capture.write(message.encode())
            else:
                print(message, end='', flush=True)
            # Diagnostic collection can outlast a natural command failure. Sample
            # again before any owned process receives a termination signal.
            exited_before_stop = child.poll()
            ownership['childExitCodeBeforeStop'] = exited_before_stop
            if interrupted:
                # Give a shell harness its EXIT trap before terminating owned
                # children; simultaneous termination races PID verification and
                # can strand otherwise safely removable fixture homes.
                with contextlib.suppress(ProcessLookupError):
                    child.send_signal(signal.SIGTERM)
                with contextlib.suppress(subprocess.TimeoutExpired):
                    child.wait(timeout=3)
            stop_detached(descendants + detached)
            try:
                child.wait(timeout=5)
            except subprocess.TimeoutExpired:
                stop_detached(descendants, signal.SIGKILL)
                child.wait()
            if descendants or detached:
                # Identity is checked again before escalation; PID reuse never
                # grants ownership of a replacement process.
                stop_detached(descendants + detached, signal.SIGKILL)
            status = (130 if interrupted else 74 if category == "output-capture-failed" else
                      2 if category in {'native-progress-unavailable', 'native-startup-publication-failed'} else 124)
            if (category in {'native-progress-unavailable', 'native-startup-publication-failed'} and
                    exited_before_stop is not None and exited_before_stop > 0):
                status = exited_before_stop
        else:
            status = child.wait()
            if native_diagnostics:
                try:
                    if native_diagnostics.poll():
                        if not host_started:
                            host_started = True
                            host_startup("xctest-observer")
                    elif status == 0:
                        category, status = "native-startup-unconfirmed", 2
                except NativeProgressSetupError as error:
                    ownership['infrastructureError'] = {'operation': error.operation, 'errno': error.errno}
                    category = 'native-progress-unavailable'
                    if status == 0:
                        status = 2
    finally:
        try:
            if native_diagnostics:
                try:
                    ownership['nativeDiagnostics'] = native_diagnostics.close()
                except OSError:
                    ownership['nativeDiagnostics'] = native_diagnostics.result
                    category = category or 'output-capture-failed'
                    if status in (None, 0):
                        status = 74
            if capture:
                metrics = capture.close()
                if (metrics['flushError'] or metrics['closeError']) and not category:
                    category = 'output-capture-failed'
                    status = 74
                metrics['captureComplete'] = category is None
                # This sidecar is uploaded with Logs. Never synchronously write
                # a truncation notice to stderr: run_step merges it with the
                # same potentially blocked console pipe.
                try:
                    atomic_json(capture.path.with_name(capture.path.name + '.capture.json'), metrics)
                except OSError as error:
                    metrics['metadataError'] = type(error).__name__
                    metrics['captureComplete'] = False
                    if not category:
                        category = 'output-capture-failed'
                        status = 74
                ownership['outputCapture'] = metrics
        finally:
            ownership['childExitCode'] = child.returncode
            if category:
                ownership['category'] = category
            with contextlib.suppress(OSError, ValueError):
                atomic_json(manifest, ownership | {"status": "failed" if category or child.returncode else "passed",
                            "finishedAt": dt.datetime.now(dt.timezone.utc).isoformat()})
            selector.close()
            child.stdout.close()
            if native_diagnostics and 'files' in ownership.get('nativeDiagnostics', {}):
                result = ownership['nativeDiagnostics']
                result['consoleComplete'] = (ownership.get('outputCapture', {}).get('consoleComplete', False) and
                                             result.get('nativeForwardComplete', False))
                if not result['consoleComplete']:
                    result['warnings'] = sorted(set(result['warnings']) | {'console-incomplete'})
                with contextlib.suppress(OSError, ValueError):
                    atomic_json(native_diagnostics.archive / 'native-diagnostics.json', result)
                    atomic_json(manifest, ownership | {"status": "failed" if category or child.returncode else "passed",
                                "finishedAt": dt.datetime.now(dt.timezone.utc).isoformat()})
            for sig, handler in original.items():
                signal.signal(sig, handler)
            if keeper:
                keeper.terminate()
                keeper.wait()
    return status


def uses_atomic_coverage(arguments):
    if "raw" in arguments:
        arguments = arguments[arguments.index("raw") + 1:]
        plan = "GitX"
        for index, argument in enumerate(arguments):
            if argument == "-testPlan" and index + 1 < len(arguments):
                plan = arguments[index + 1]
            elif argument.startswith("-testPlan="):
                plan = argument.partition("=")[2]
        return plan == "GitX" and any(action in arguments for action in ("test", "test-without-building", "build-for-testing"))
    if "build-tests" in arguments:
        return True
    if "test" not in arguments:
        return False
    arguments = arguments[arguments.index("test") + 1:]
    return arguments[:1] == ["correctness"] or arguments[:2] == ["-testPlan", "GitX"]


def entry_resources(entry, arguments, root=ROOT, toolchain=None):
    if arguments in (["--help"], ["-h"], ["--version"]):
        return [], {}
    if entry == "verify_static.sh" and toolchain is None:
        return [], {}
    if entry == "observe_app.sh" or (entry == "run_app.sh" and any(value in arguments for value in ("--no-build", "--stop"))):
        return [str(pathlib.Path(root) / "build/GitX.app"), f"desktop:{os.getuid()}"], {}
    configuration = "Release" if "archive" in arguments and "raw" not in arguments else "Debug"
    for index, value in enumerate(arguments[:-1]):
        if value in {"--configuration", "-configuration"}:
            configuration = arguments[index + 1]
    for value in arguments:
        if value.startswith("-configuration="):
            configuration = value.partition("=")[2]
    instrumentation = next((v for v in ("address-undefined", "thread-sanitizer", "correctness", "performance") if v in arguments), "plain")
    if "build-tests" in arguments:
        instrumentation = "correctness"
    plan_instrumentation = {"GitX": "correctness", "GitXAddressUndefined": "address-undefined",
                            "GitXThreadSanitizer": "thread-sanitizer", "GitXPerformance": "performance"}
    for index, value in enumerate(arguments[:-1]):
        if value == "-testPlan":
            instrumentation = plan_instrumentation.get(arguments[index + 1], "plain")
        if value in {"-enableAddressSanitizer", "-enableThreadSanitizer", "-enableCodeCoverage"} and arguments[index + 1] == "YES":
            instrumentation = {"-enableAddressSanitizer": "address-undefined", "-enableThreadSanitizer": "thread-sanitizer", "-enableCodeCoverage": "correctness"}[value]
    if entry == "xcodebuild.sh" and uses_atomic_coverage(arguments):
        instrumentation = "correctness"
    developer = None
    for index, value in enumerate(arguments[:-1]):
        if value == "--developer-dir":
            developer = arguments[index + 1]
            if pathlib.Path(developer).suffix.lower() == ".app":
                developer = str(pathlib.Path(developer) / "Contents/Developer")
    toolchain = toolchain if toolchain is not None else toolchain_identity(developer)
    paths = cache_paths(root, configuration, instrumentation, developer, toolchain=toolchain)
    resources = [] if entry == "verify_static.sh" else [paths["derivedData"], paths["swiftPM"], paths["sourcePackages"]]
    if entry == "check_test_build_contracts.py":
        for config in ("Debug", "Release"):
            probe_paths = cache_paths(root, config, developer=developer, toolchain=toolchain)
            resources.extend(probe_paths[key] for key in ("derivedData", "sourcePackages"))
    for index, arg in enumerate(arguments[:-1]):
        if arg == "--resume-analysis":
            value = arguments[index + 1]
            if not valid_run_id(value):
                raise ValueError("Invalid prior analyzer run ID")
            resources.append(str(verification_artifact_root(root) / value))
            receipt = verification_artifact_root(root) / value / "receipt.json"
            if receipt.is_file():
                try:
                    prior = json.loads(receipt.read_text())
                    evidence = prior.get("evidence", {}) if isinstance(prior, dict) else {}
                    scratch = evidence.get("analyzerScratch", {}) if isinstance(evidence, dict) else {}
                    scratch = scratch.get("path") if isinstance(scratch, dict) else None
                except (OSError, ValueError):
                    scratch = None
                if isinstance(scratch, str) and scratch:
                    try:
                        pathlib.Path(scratch).expanduser().resolve(strict=True)
                        canonical_resource(scratch)
                    except (OSError, ValueError, RuntimeError):
                        # Admission must reach the wrapper's fresh fallback
                        # even when prior provenance names an invalid path.
                        pass
                    else:
                        resources.append(scratch)
        if arg in {"-derivedDataPath", "-clonedSourcePackagesDirPath", "--scratch-path"}:
            resources.append(arguments[index + 1])
            if arg == "-derivedDataPath":
                paths["derivedData"] = str(pathlib.Path(arguments[index + 1]).expanduser().resolve())
            elif arg == "-clonedSourcePackagesDirPath":
                paths["sourcePackages"] = str(pathlib.Path(arguments[index + 1]).expanduser().resolve())
    for arg in arguments:
        for flag, key in (("-derivedDataPath=", "derivedData"), ("-clonedSourcePackagesDirPath=", "sourcePackages")):
            if arg.startswith(flag):
                paths[key] = str(pathlib.Path(arg[len(flag):]).expanduser().resolve())
                resources.append(paths[key])
    if entry == "run_app.sh" or "--stage-app" in arguments:
        resources.append(str(pathlib.Path(root) / "build/GitX.app"))
    if entry == "xcodebuild.sh" and "--profile-rules" in arguments:
        resources.append(str(pathlib.Path(root).resolve() / "artifacts/verification/.swiftlint-profile-output"))
    if entry == "run_app.sh" or (any(v in arguments for v in ("test", "test-without-building")) and not any(v in arguments for v in ("core", "forgekit"))):
        resources.append(f"desktop:{os.getuid()}")
    return resources, paths


def guard(entry, arguments):
    root = pathlib.Path(entry).resolve().parent.parent
    run_id = os.environ.get("GITX_SESSION_ID") or "session-" + uuid.uuid4().hex[:12]
    for index, arg in enumerate(arguments[:-1]):
        if arg == "--run-id":
            run_id = arguments[index + 1]
    if not valid_run_id(run_id):
        print("Run IDs may contain only letters, numbers, dots, underscores, and hyphens.", file=sys.stderr)
        return 2
    receipt = verification_artifact_root(root) / "Coordination" / f"{run_id}.json"
    if receipt.exists():
        receipt = receipt.with_name(f"{run_id}-{uuid.uuid4().hex[:8]}.json")
    owner = {"runId": run_id, "pid": os.getpid(), "receipt": str(receipt), "entry": str(entry), "schemaVersion": 2, "producer": producer_identity(), "startedAt": dt.datetime.now(dt.timezone.utc).isoformat()}
    try:
        wait = float(os.environ.get("GITX_RESOURCE_WAIT_SECONDS", "0"))
        if not math.isfinite(wait) or wait < 0:
            raise ValueError("Resource wait must be finite and nonnegative")
        deadline = time.monotonic() + wait
        while True:
            resources, paths = entry_resources(pathlib.Path(entry).name, arguments, root)
            if pathlib.Path(entry).name == "xcodebuild.sh":
                resources.append(str(verification_artifact_root(root) / run_id))
            with Leases(resources, owner, wait_seconds=max(0, deadline - time.monotonic())) as leases:
                refreshed_resources, refreshed_paths = entry_resources(pathlib.Path(entry).name, arguments, root)
                if pathlib.Path(entry).name == "xcodebuild.sh":
                    refreshed_resources.append(str(verification_artifact_root(root) / run_id))
                changed = ({canonical_resource(value) for value in refreshed_resources} != set(leases.held) or
                           paths.get("toolchain") != refreshed_paths.get("toolchain"))
                if changed:
                    if time.monotonic() >= deadline:
                        raise ResourceDefinitionError("Required resources changed while waiting; retry with stable inputs",
                                                      "resource-definition-changed")
                else:
                    return execute_guarded(entry, arguments, root, receipt, owner, resources, refreshed_paths, leases)
            time.sleep(min(.2, max(0, deadline - time.monotonic())))
    except (ResourceBusy, ResourceDefinitionError) as error:
        failure = resource_failure_fields(error)
        atomic_json(receipt, owner | failure)
        print(error, file=sys.stderr)
        return failure["exitCode"]


def execute_guarded(entry, arguments, root, receipt, owner, resources, paths, leases):
    # Keep execution inside the acquired context; its return releases all
    # leases only after final evidence has been published.
    env = leases.environment() | {"GITX_GUARDED_ENTRY": str(pathlib.Path(entry).resolve()),
          **{variable: paths[key] for variable, key in (("GITX_DERIVED_DATA", "derivedData"),
             ("GITX_SWIFTPM_BUILD_ROOT", "swiftPM"), ("GITX_SOURCE_PACKAGE_CACHE", "sourcePackages")) if key in paths}}
    if pathlib.Path(entry).name == "check_test_build_contracts.py":
        # This command probes two configurations. Preserve explicit
        # overrides, but do not turn its Debug default into a Release
        # override for the second probe.
        for variable in ("GITX_DERIVED_DATA", "GITX_SWIFTPM_BUILD_ROOT", "GITX_SOURCE_PACKAGE_CACHE"):
            if variable not in os.environ:
                env.pop(variable, None)
    before = inputs(root)
    atomic_json(receipt, owner | {"status": "running", "resources": resources, "paths": paths,
                                 "resourceWaitSeconds": round(leases.wait_seconds, 3), "deliveryEligible": False,
                                 "evidence": {"status": "pending", "inputsBefore": before}})
    interpreter = sys.executable if pathlib.Path(entry).suffix == ".py" else "bash"
    status = supervise([interpreter, str(pathlib.Path(entry).resolve()), *arguments], env=env, desktop=pathlib.Path(entry).name == "run_app.sh",
                       pass_fds=leases.descriptors(), timeout=float(os.environ.get("GITX_COMMAND_TIMEOUT", "7200")), directory=receipt.parent / "Diagnostics" / receipt.stem, merge_stderr=False)
    after = inputs(root)
    changed = changed_inputs(before, after)
    if changed and status == 0:
        status = 76
    atomic_json(receipt, owner | {"status": "invalid" if changed else "passed" if status == 0 else "failed", "exitCode": status, "resources": resources, "paths": paths, "resourceWaitSeconds": round(leases.wait_seconds, 3), "deliveryEligible": False, "finishedAt": dt.datetime.now(dt.timezone.utc).isoformat(),
        "evidence": {"status": "invalid" if changed else "valid", "inputsBefore": before, "inputsAfter": after, "changedInputs": changed}})
    return status


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    guarded = sub.add_parser("guard")
    guarded.add_argument("entry")
    guarded.add_argument("arguments", nargs=argparse.REMAINDER)
    bounded = sub.add_parser("run")
    bounded.add_argument("--timeout", type=float, default=float(os.environ.get("GITX_COMMAND_TIMEOUT", "7200")))
    bounded.add_argument("--startup-timeout", type=float)
    bounded.add_argument("--desktop", action="store_true")
    bounded.add_argument("--diagnostics", type=pathlib.Path)
    bounded.add_argument("--output-log", type=pathlib.Path)
    bounded.add_argument("--native-test-root", type=pathlib.Path)
    bounded.add_argument("--native-artifact-directory", type=pathlib.Path)
    bounded.add_argument("--native-test-bundle", action="append")
    bounded.add_argument("--capture-native-stderr", action="store_true")
    bounded.add_argument("arguments", nargs=argparse.REMAINDER)
    paths = sub.add_parser("paths")
    paths.add_argument("--configuration", default="Debug")
    paths.add_argument("--instrumentation", default="plain")
    counters = sub.add_parser("coverage-mode")
    counters.add_argument("arguments", nargs=argparse.REMAINDER)
    signature = sub.add_parser("signatures")
    signature.add_argument("derived_data")
    sub.add_parser("desktop")
    evidence = sub.add_parser("snapshot")
    evidence.add_argument("path", type=pathlib.Path)
    evidence.add_argument("--products")
    validate = sub.add_parser("validate")
    validate.add_argument("path", type=pathlib.Path)
    args = parser.parse_args()
    try:
        if args.command == "guard":
            return guard(args.entry, args.arguments)
        if args.command == "paths":
            print(json.dumps(cache_paths(configuration=args.configuration, instrumentation=args.instrumentation)))
        if args.command == "coverage-mode":
            print("atomic" if uses_atomic_coverage(args.arguments) else "unchanged")
        if args.command == "run":
            command = args.arguments[1:] if args.arguments[:1] == ["--"] else args.arguments
            inherited = Leases([], {"runId": os.environ.get("GITX_SESSION_ID", "command")})
            return supervise(command, args.timeout, args.startup_timeout, args.desktop, args.diagnostics,
                             pass_fds=inherited.descriptors(), output_log=args.output_log,
                             native_test_root=args.native_test_root, native_artifact_directory=args.native_artifact_directory,
                             native_test_bundles=args.native_test_bundle, capture_native_stderr=args.capture_native_stderr)
        if args.command == "signatures":
            print(json.dumps(verify_signatures(args.derived_data)))
        if args.command == "desktop":
            checks = desktop_checks()
            print(json.dumps(checks, indent=2))
            return 1 if any(c["status"] == "failed" for c in checks) else 0
        if args.command == "snapshot":
            value = {"inputs": inputs(), "dependencyProducts": dependency_products()}
            if args.products:
                value.update(products=product_identity(args.products), productPath=args.products)
            atomic_json(args.path, value)
        if args.command == "validate":
            value = json.loads(args.path.read_text())
            changed = changed_inputs(value["inputs"], inputs())
            if value.get("dependencyProducts") != dependency_products():
                changed.append("dependency-products")
            if "products" in value and value["products"] != product_identity(value["productPath"]):
                changed.append("products")
            if changed:
                print("Invalid verification evidence: changed " + ", ".join(changed), file=sys.stderr)
                return 76
        return 0
    except (OSError, ValueError) as error:
        if args.command == "signatures":
            category = "signature-incompatible" if str(error).startswith("signature-incompatible:") else "signature-invalid"
            print(f"Verification blocker: {category}.", file=sys.stderr)
        print(error, file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
