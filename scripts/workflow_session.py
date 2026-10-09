#!/usr/bin/env python3
"""Process-held resource leases, immutable evidence, and bounded local commands.

Only the standard library is used. Lock files are never unlinked: their inode
is the coordination point. A private local broker authenticates nested owners;
lock descriptors never escape into external tools or their persistent daemons.
"""
from __future__ import annotations

import argparse
import contextlib
import datetime as dt
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
import subprocess
import sys
import tempfile
import time
import threading
import uuid

ROOT = pathlib.Path(__file__).resolve().parent.parent
LOCK_ROOT = pathlib.Path.home() / "Library/Caches/GitX/Verification/Locks"


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


def git(root, *args):
    result = subprocess.run(["git", "-C", str(root), *args], capture_output=True)
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
    names += [p for p in new if p.startswith(("Classes/", "GitXTests/", "GitXUITests/",
              "GitXCore/Sources/", "ForgeKit/Sources/", "scripts/", ".agents/skills/"))]
    files = {name: file_identity(root / name) for name in sorted(set(names)) if name}
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


def verification_artifact_root(root=ROOT):
    root = pathlib.Path(root).resolve()
    config = json.loads((root / "scripts/verification-config.json").read_text())
    return root / config["artifactRoot"]


def cache_paths(root=ROOT, configuration="Debug", instrumentation="plain", developer=None, toolchain=None):
    root = pathlib.Path(root).resolve()
    developer = developer or os.environ.get("GITX_DEVELOPER_DIR") or os.environ.get("DEVELOPER_DIR")
    developer = developer or "/Applications/Xcode.app/Contents/Developer"
    if toolchain is None:
        try:
            toolchain = subprocess.check_output([str(pathlib.Path(developer) / "usr/bin/xcodebuild"), "-version"], timeout=15).decode().strip()
        except (OSError, subprocess.SubprocessError):
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


def canonical_resource(resource):
    return resource if resource.startswith("desktop:") else str(pathlib.Path(resource).expanduser().resolve())


class Leases:
    def __init__(self, resources, owner, lock_root=LOCK_ROOT, inherited=None):
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
                client.sendall(json.dumps({"resource": digest(resource.encode()), "token": prior["token"]}).encode())
                client.shutdown(socket.SHUT_WR)
                return client.recv(128) == b"owned"
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
                        request = json.loads(connection.recv(4096))
                        owned = tokens.get(request.get("resource")) == request.get("token") and request.get("resource") in tokens
                        connection.sendall(b"owned" if owned else b"denied")
                    except (OSError, ValueError):
                        pass
        self.broker_thread = threading.Thread(target=serve, daemon=True)
        self.broker_thread.start()

    def __enter__(self):
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
                             "GITX_SESSION_ID": os.environ.get("GITX_SESSION_ID", self.owner["runId"])}

    def descriptors(self):
        return ()

    def __exit__(self, *_):
        if self.broker:
            self.broker.close()
            if self.broker_thread:
                self.broker_thread.join(timeout=2)
            self.broker = None
        if self.broker_directory:
            self.broker_directory.cleanup()
            self.broker_directory = None
        # Close our descriptors, never unlock an inherited parent's lease.
        for stream in self.opened:
            stream.close()
        self.opened.clear()


def desktop_checks():
    if platform.system() != "Darwin":
        return [{"name": "desktop-unavailable", "status": "failed", "detail": "App-host tests require a local macOS console session."}]
    result = subprocess.run(["/usr/sbin/scutil"], input="show State:/Users/ConsoleUser\n", text=True, capture_output=True)
    output = result.stdout
    console = "Name :" in output and "Name : loginwindow" not in output and f"UID : {os.getuid()}" in output
    display = subprocess.run(["/usr/sbin/ioreg", "-n", "IODisplayWrangler", "-r"], text=True, capture_output=True)
    lock_properties = subprocess.run(
        ["/usr/sbin/ioreg", "-n", "Root", "-d", "1"], capture_output=True, text=True).stdout
    locked = bool(re.search(r'"CGSSessionScreenIsLocked"\s*=\s*Yes\b', lock_properties))
    checks = [{"name": "console-session", "status": "passed" if console else "failed",
               "detail": "Active local console user." if console else "Switch to this user's macOS desktop before retrying."},
              {"name": "display", "status": "passed" if display.stdout and not locked else "failed",
               "detail": "Display available." if display.stdout and not locked else "Wake and unlock the local display, then retry."}]
    pids = subprocess.run(["pgrep", "-x", "GitX"], capture_output=True, text=True).stdout.split()
    checks.append({"name": "competing-gitx", "status": "failed" if pids else "passed",
                   "detail": f"Close competing GitX processes {', '.join(pids)} and retry." if pids else "No competing GitX process."})
    return checks


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
    processes = owned_processes(group) + [process["process"] for process in detached]
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


def supervise(command, timeout=7200, startup_timeout=None, desktop=False, directory=None, env=None, pass_fds=(), merge_stderr=True):
    """Bound a process group, retaining diagnostics and killing only that group."""
    directory = pathlib.Path(directory or ROOT / "artifacts/verification/diagnostics")
    keeper = None
    child_env = dict(env or os.environ)
    tag = child_env.get("GITX_SESSION_ID", uuid.uuid4().hex)
    existing = set(subprocess.run(["ps", "-axo", "pid="], capture_output=True, text=True).stdout.split()) if desktop else set()
    if desktop:
        child_env["GITX_VERIFICATION_SESSION"] = tag
        child_env["TEST_RUNNER_GITX_VERIFICATION_SESSION"] = tag
    child = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT if merge_stderr else None,
                             start_new_session=True, env=child_env, pass_fds=pass_fds)
    if desktop and platform.system() == "Darwin":
        keeper = subprocess.Popen(["/usr/bin/caffeinate", "-di", "-w", str(child.pid)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    started, host_started, interrupted = time.monotonic(), False, None
    original = {}
    def interrupt(signum, _):
        nonlocal interrupted
        interrupted = signum
    for sig in (signal.SIGTERM, signal.SIGINT):
        original[sig] = signal.signal(sig, interrupt)
    selector = selectors.DefaultSelector()
    selector.register(child.stdout, selectors.EVENT_READ)
    buffered = b""
    category = None
    try:
        while child.poll() is None or selector.get_map():
            elapsed = time.monotonic() - started
            if interrupted:
                category = "interrupted"
                break
            if elapsed > timeout:
                category = "command-timeout"
                break
            if startup_timeout and not host_started and elapsed > startup_timeout:
                category = "unknown-host-startup-timeout"
                break
            for key, _ in selector.select(.2):
                data = os.read(key.fd, 65536)
                if not data:
                    selector.unregister(key.fileobj)
                    continue
                sys.stdout.buffer.write(data)
                sys.stdout.buffer.flush()
                buffered = (buffered + data)[-65536:]
                if b"Test Suite " in buffered or b"Test Case " in buffered or b"Test case '" in buffered:
                    host_started = True
        if category:
            detached = detached_owned_processes(tag, existing) if desktop else []
            # Every nested supervisor starts its own process group. A group
            # signal alone would orphan its compiler and release the outer
            # lease while that compiler still writes shared products.
            descendants = descendant_processes(child.pid)
            with contextlib.suppress(OSError, subprocess.SubprocessError):
                diagnostics(directory, child.pid, category, detached + descendants)
            print(f"\nVerification blocker: {category}. Diagnostics: {directory}", flush=True)
            if interrupted:
                # Give a shell harness its EXIT trap before terminating owned
                # children; simultaneous termination races PID verification and
                # can strand otherwise safely removable fixture homes.
                with contextlib.suppress(ProcessLookupError):
                    os.kill(child.pid, signal.SIGTERM)
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
            return 130 if interrupted else 124
        return child.wait()
    finally:
        selector.close()
        child.stdout.close()
        for sig, handler in original.items():
            signal.signal(sig, handler)
        if keeper:
            keeper.terminate()
            keeper.wait()


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
    paths = cache_paths(root, configuration, instrumentation, developer, toolchain=toolchain)
    resources = [paths["derivedData"], paths["swiftPM"], paths["sourcePackages"]]
    if entry == "check_test_build_contracts.py":
        for config in ("Debug", "Release"):
            probe_paths = cache_paths(root, config, developer=developer, toolchain=toolchain)
            resources.extend(probe_paths[key] for key in ("derivedData", "sourcePackages"))
    for index, arg in enumerate(arguments[:-1]):
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
    if entry in {"verify_static.sh", "run_app.sh"} or (any(v in arguments for v in ("test", "test-without-building")) and not any(v in arguments for v in ("core", "forgekit"))):
        resources.append(f"desktop:{os.getuid()}")
    return resources, paths


def guard(entry, arguments):
    root = pathlib.Path(entry).resolve().parent.parent
    run_id = os.environ.get("GITX_SESSION_ID") or "session-" + uuid.uuid4().hex[:12]
    for index, arg in enumerate(arguments[:-1]):
        if arg == "--run-id":
            run_id = arguments[index + 1]
    if re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", run_id) is None:
        print("Run IDs may contain only letters, numbers, dots, underscores, and hyphens.", file=sys.stderr)
        return 2
    receipt = verification_artifact_root(root) / "Coordination" / f"{run_id}.json"
    if receipt.exists():
        receipt = receipt.with_name(f"{run_id}-{uuid.uuid4().hex[:8]}.json")
    owner = {"runId": run_id, "pid": os.getpid(), "receipt": str(receipt), "entry": str(entry)}
    resources, paths = entry_resources(pathlib.Path(entry).name, arguments, root)
    if pathlib.Path(entry).name == "xcodebuild.sh":
        resources.append(str(verification_artifact_root(root) / run_id))
    try:
        with Leases(resources, owner) as leases:
            env = leases.environment() | {"GITX_GUARDED_ENTRY": str(pathlib.Path(entry).resolve()),
                  "GITX_DERIVED_DATA": paths["derivedData"], "GITX_SWIFTPM_BUILD_ROOT": paths["swiftPM"],
                  "GITX_SOURCE_PACKAGE_CACHE": paths["sourcePackages"]}
            if pathlib.Path(entry).name == "check_test_build_contracts.py":
                # This command probes two configurations. Preserve explicit
                # overrides, but do not turn its Debug default into a Release
                # override for the second probe.
                for variable in ("GITX_DERIVED_DATA", "GITX_SWIFTPM_BUILD_ROOT", "GITX_SOURCE_PACKAGE_CACHE"):
                    if variable not in os.environ:
                        env.pop(variable, None)
            before = inputs(root)
            atomic_json(receipt, owner | {"status": "running", "resources": resources, "paths": paths,
                                         "evidence": {"status": "pending", "inputsBefore": before}})
            interpreter = sys.executable if pathlib.Path(entry).suffix == ".py" else "bash"
            status = supervise([interpreter, str(pathlib.Path(entry).resolve()), *arguments], env=env, desktop=pathlib.Path(entry).name == "run_app.sh",
                               pass_fds=leases.descriptors(), timeout=float(os.environ.get("GITX_COMMAND_TIMEOUT", "7200")), directory=receipt.parent / "Diagnostics", merge_stderr=False)
            after = inputs(root)
            changed = changed_inputs(before, after)
            if changed and status == 0:
                status = 76
            atomic_json(receipt, owner | {"status": "invalid" if changed else "passed" if status == 0 else "failed", "exitCode": status, "resources": resources, "paths": paths,
                "evidence": {"status": "invalid" if changed else "valid", "inputsBefore": before, "inputsAfter": after, "changedInputs": changed}})
            return status
    except ResourceBusy as error:
        atomic_json(receipt, owner | {"status": "blocked", "exitCode": 75, "category": "resource-busy", "owner": error.owner, "resource": error.resource})
        print(error, file=sys.stderr)
        return 75


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
                             pass_fds=inherited.descriptors())
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
