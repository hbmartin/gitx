#!/usr/bin/env python3
"""Shared configuration, preflight, and receipt support for GitX verification."""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
import pathlib
import platform
import re
import shutil
import subprocess
import sys
import tempfile
import time
from typing import Any


ROOT = pathlib.Path(__file__).resolve().parent.parent
CONFIG_PATH = pathlib.Path(__file__).with_name("verification-config.json")
SECRET_ARGUMENT = re.compile(r"(?i)(password|secret|token|api[_-]?key)=")
RUN_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")


def load_config(path: pathlib.Path = CONFIG_PATH) -> dict[str, Any]:
    payload = json.loads(path.read_text())
    if payload.get("schemaVersion") != 1:
        raise ValueError(f"Unsupported verification config version in {path}")
    return payload


def run(arguments: list[str], *, cwd: pathlib.Path = ROOT, timeout: int = 30) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        arguments,
        cwd=cwd,
        capture_output=True,
        text=True,
        timeout=timeout,
        check=False,
    )


def xcode_version(developer_dir: pathlib.Path) -> tuple[str, str] | None:
    executable = developer_dir / "usr/bin/xcodebuild"
    if not executable.is_file():
        return None
    try:
        result = run([str(executable), "-version"], timeout=15)
    except (OSError, subprocess.TimeoutExpired):
        return None
    if result.returncode != 0:
        return None
    version_match = re.search(r"^Xcode\s+(\S+)", result.stdout, re.MULTILINE)
    build_match = re.search(r"^Build version\s+(\S+)", result.stdout, re.MULTILINE)
    if version_match is None:
        return None
    return version_match.group(1), build_match.group(1) if build_match else "unknown"


def version_components(value: str) -> tuple[int, ...]:
    match = re.match(r"(\d+(?:\.\d+)*)", value)
    if match is None:
        return ()
    return tuple(int(component) for component in match.group(1).split("."))


def version_at_least(actual: str, minimum: str) -> bool:
    left = version_components(actual)
    right = version_components(minimum)
    width = max(len(left), len(right))
    return left + (0,) * (width - len(left)) >= right + (0,) * (width - len(right))


def normalize_developer_directory(path: str) -> pathlib.Path:
    candidate = pathlib.Path(path).expanduser()
    if candidate.suffix == ".app":
        return candidate / "Contents" / "Developer"
    return candidate


def developer_dir_candidates(config: dict[str, Any]) -> list[pathlib.Path]:
    explicit = os.environ.get("GITX_DEVELOPER_DIR")
    if explicit:
        return [normalize_developer_directory(explicit)]
    standard = os.environ.get("DEVELOPER_DIR")
    if standard:
        return [normalize_developer_directory(standard)]
    return [normalize_developer_directory(config["defaultDeveloperDirectory"])]


def resolve_developer_dir(config: dict[str, Any]) -> pathlib.Path | None:
    minimum = config["minimumXcodeVersion"]
    for candidate in developer_dir_candidates(config):
        version = xcode_version(candidate)
        if version is not None and version_at_least(version[0], minimum):
            return candidate
    return None


def git_output(*arguments: str, cwd: pathlib.Path = ROOT) -> str:
    try:
        result = run(["git", *arguments], cwd=cwd, timeout=15)
    except (OSError, subprocess.TimeoutExpired):
        return ""
    return result.stdout.strip() if result.returncode == 0 else ""


def untracked_content_fingerprint(root: pathlib.Path) -> str:
    digest = hashlib.sha256()
    try:
        result = subprocess.run(
            ["git", "ls-files", "--others", "--exclude-standard", "-z"],
            cwd=root,
            capture_output=True,
            timeout=15,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        digest.update(f"untracked-list-error:{type(error).__name__}".encode())
        return digest.hexdigest()
    if result.returncode != 0:
        digest.update(f"untracked-list-exit:{result.returncode}".encode())
        return digest.hexdigest()

    for raw_path in sorted(path for path in result.stdout.split(b"\0") if path):
        digest.update(len(raw_path).to_bytes(8, "big"))
        digest.update(raw_path)
        path = root / os.fsdecode(raw_path)
        content_digest = hashlib.sha256()
        try:
            if path.is_symlink():
                content_digest.update(b"symlink\0")
                content_digest.update(os.fsencode(os.readlink(path)))
            elif path.is_file():
                content_digest.update(b"file\0")
                with path.open("rb") as handle:
                    while chunk := handle.read(1024 * 1024):
                        content_digest.update(chunk)
            else:
                content_digest.update(b"other\0")
        except OSError as error:
            content_digest.update(f"read-error:{error.errno}".encode())
        digest.update(content_digest.digest())
    return digest.hexdigest()


def working_tree_fingerprint(root: pathlib.Path = ROOT) -> str:
    state = "\n".join(
        (
            git_output("status", "--porcelain=v1", "--untracked-files=all", cwd=root),
            git_output("diff", "--binary", cwd=root),
            git_output("diff", "--cached", "--binary", cwd=root),
            untracked_content_fingerprint(root),
        )
    )
    return hashlib.sha256(state.encode()).hexdigest()


def scrub_arguments(arguments: list[str]) -> list[str]:
    scrubbed: list[str] = []
    redact_next = False
    for argument in arguments:
        if redact_next:
            scrubbed.append("<redacted>")
            redact_next = False
        elif argument.lower() in {"--password", "--token", "--secret", "--api-key"}:
            scrubbed.append(argument)
            redact_next = True
        elif SECRET_ARGUMENT.search(argument):
            scrubbed.append(argument.split("=", 1)[0] + "=<redacted>")
        else:
            scrubbed.append(argument)
    return scrubbed


def relative_artifact(path: str | None) -> str | None:
    if not path:
        return None
    candidate = pathlib.Path(path)
    try:
        return candidate.resolve().relative_to(ROOT.resolve()).as_posix()
    except (ValueError, OSError):
        return str(candidate)


def atomic_json(path: pathlib.Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(descriptor, "w") as handle:
            json.dump(payload, handle, indent=2, sort_keys=True)
            handle.write("\n")
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def destination_components(specification: str) -> dict[str, str]:
    """Return the destination fields that xcodebuild must satisfy."""
    normalized = specification.removeprefix("generic/")
    result: dict[str, str] = {}
    for component in normalized.split(","):
        key, separator, value = component.partition("=")
        if separator and key.strip() and value.strip():
            result[key.strip().lower()] = value.strip()
    return result


def available_destinations(output: str) -> list[dict[str, str]]:
    destinations: list[dict[str, str]] = []
    for body in re.findall(r"\{([^{}]+)\}", output):
        destination: dict[str, str] = {}
        for component in body.split(","):
            key, separator, value = component.partition(":")
            if separator and key.strip() and value.strip():
                destination[key.strip().lower()] = value.strip()
        if destination:
            destinations.append(destination)
    return destinations


def destination_is_available(specification: str, output: str) -> bool:
    requested = destination_components(specification)
    if not requested:
        return False
    return any(
        all(candidate.get(key) == value for key, value in requested.items())
        for candidate in available_destinations(output)
    )


def doctor_checks(
    mode: str,
    developer_dir: pathlib.Path | None = None,
    destination: str | None = None,
) -> tuple[list[dict[str, str]], pathlib.Path | None]:
    config = load_config()
    checks: list[dict[str, str]] = []
    requested_destination = destination or config["destination"]

    def add(name: str, status: str, detail: str) -> None:
        checks.append({"name": name, "status": status, "detail": detail})

    selected = developer_dir or resolve_developer_dir(config)
    if selected is None:
        inspected = ", ".join(str(path) for path in developer_dir_candidates(config)) or "none"
        add("xcode", "failed", f"No Xcode {config['minimumXcodeVersion']}+ found; inspected {inspected}")
    else:
        version = xcode_version(selected)
        if version is None:
            add("xcode", "failed", f"Could not query {selected}")
        elif not version_at_least(version[0], config["minimumXcodeVersion"]):
            add("xcode", "failed", f"Xcode {version[0]} is older than {config['minimumXcodeVersion']}")
        else:
            qualifier = " (newer toolchain; verify CI compatibility)" if version_components(version[0]) > version_components(config["minimumXcodeVersion"]) else ""
            add("xcode", "warning" if qualifier else "passed", f"Xcode {version[0]} ({version[1]}) at {selected}{qualifier}")

    for command in ("git", "python3", "xcrun"):
        location = shutil.which(command)
        add(command, "passed" if location else "failed", location or f"{command} is not on PATH")
    location = shutil.which("xcbeautify")
    add("xcbeautify", "passed" if location else "warning", location or "optional; raw output will be used")

    workspace = ROOT / config["workspace"]
    add("workspace", "passed" if workspace.exists() else "failed", str(workspace))
    package_lock = workspace / "xcshareddata/swiftpm/Package.resolved"
    add("package-lock", "passed" if package_lock.is_file() else "failed", str(package_lock))

    plan_names = [config["testPlans"]["correctness"]]
    if mode == "ui":
        plan_names.extend((config["testPlans"]["ui-preflight"], config["testPlans"]["ui"]))
    elif mode in {"test", "ci"}:
        plan_names.extend(
            value for key, value in config["testPlans"].items() if key != "ui-preflight"
        )
    for name in sorted(set(plan_names)):
        path = ROOT / "GitXTests" / f"{name}.xctestplan"
        add(f"test-plan:{name}", "passed" if path.is_file() else "failed", str(path))

    submodules = git_output("submodule", "status", "--recursive").splitlines()
    missing = [line for line in submodules if line.startswith("-")]
    divergent = [line for line in submodules if line.startswith("+")]
    if missing:
        add("submodules", "failed", f"{len(missing)} submodule(s) are not initialized")
    elif divergent:
        add("submodules", "warning", f"{len(divergent)} submodule(s) differ from the recorded commit")
    else:
        add("submodules", "passed", f"{len(submodules)} recursive submodule(s) initialized")

    try:
        free_bytes = shutil.disk_usage(ROOT).free
        if free_bytes < 1_000_000_000:
            status = "failed"
        elif free_bytes < 5_000_000_000:
            status = "warning"
        else:
            status = "passed"
        add("disk-space", status, f"{free_bytes / 1_000_000_000:.1f} GB free")
    except OSError as error:
        add("disk-space", "warning", str(error))

    if mode == "ui":
        try:
            processes = run(["pgrep", "-x", "GitX"], timeout=5)
            pids = processes.stdout.split()
        except (OSError, subprocess.TimeoutExpired):
            pids = []
        add("ui-processes", "failed" if pids else "passed", f"running GitX pid(s): {', '.join(pids)}" if pids else "no competing GitX process")

    if selected is not None and workspace.exists():
        executable = selected / "usr/bin/xcodebuild"
        derived_data = ROOT / config["derivedDataCache"]
        package_cache = ROOT / config["sourcePackageCache"]
        try:
            destinations = run(
                [
                    str(executable),
                    "-workspace",
                    config["workspace"],
                    "-scheme",
                    config["scheme"],
                    "-derivedDataPath",
                    str(derived_data),
                    "-clonedSourcePackagesDirPath",
                    str(package_cache),
                    "-disableAutomaticPackageResolution",
                    "-showdestinations",
                ],
                timeout=90,
            )
            output = destinations.stdout + destinations.stderr
            wanted = destination_is_available(requested_destination, output)
            add(
                "destination",
                "passed" if destinations.returncode == 0 and wanted else "failed",
                requested_destination
                if destinations.returncode == 0 and wanted
                else (
                    f"Requested destination is unavailable: {requested_destination}"
                    if destinations.returncode == 0
                    else (output.strip().splitlines()[-1] if output.strip() else "xcodebuild failed")
                ),
            )
        except subprocess.TimeoutExpired as error:
            add(
                "destination",
                "warning",
                f"Discovery timed out for {requested_destination}; the requested xcodebuild operation remains authoritative ({error})",
            )
        except OSError as error:
            add("destination", "failed", str(error))

    return checks, selected


def doctor_payload(
    mode: str,
    developer_dir: pathlib.Path | None = None,
    destination: str | None = None,
) -> dict[str, Any]:
    checks, selected = doctor_checks(mode, developer_dir, destination)
    failed = sum(check["status"] == "failed" for check in checks)
    warnings = sum(check["status"] == "warning" for check in checks)
    return {
        "schemaVersion": 1,
        "mode": mode,
        "status": "failed" if failed else "passed",
        "developerDir": str(selected) if selected else None,
        "destination": destination or load_config()["destination"],
        "summary": {"failed": failed, "warnings": warnings, "passed": len(checks) - failed - warnings},
        "checks": checks,
    }


def command_doctor(arguments: argparse.Namespace) -> int:
    payload = doctor_payload(
        arguments.mode,
        pathlib.Path(arguments.developer_dir) if arguments.developer_dir else None,
        arguments.destination,
    )
    if arguments.format == "json":
        print(json.dumps(payload, indent=2, sort_keys=True))
    else:
        for check in payload["checks"]:
            print(f"[{check['status'].upper():7}] {check['name']}: {check['detail']}")
        summary = payload["summary"]
        print(f"Doctor {payload['status']}: {summary['passed']} passed, {summary['warnings']} warning(s), {summary['failed']} failed")
    return 0 if payload["status"] == "passed" else 1


def receipt_base(arguments: argparse.Namespace) -> dict[str, Any]:
    config = load_config()
    developer_dir = pathlib.Path(arguments.developer_dir)
    version = xcode_version(developer_dir) or ("unknown", "unknown")
    try:
        xcrun = shutil.which("xcrun") or "/usr/bin/xcrun"
        swift = run([xcrun, "swift", "--version"], timeout=15)
        swift_version = (swift.stdout or swift.stderr).strip().splitlines()[0]
    except (OSError, subprocess.TimeoutExpired, IndexError):
        swift_version = "unknown"
    now = dt.datetime.now(dt.timezone.utc).isoformat()
    branch = git_output("branch", "--show-current") or None
    status = git_output("status", "--porcelain=v1", "--untracked-files=all")
    return {
        "schemaVersion": 1,
        "runId": arguments.run_id,
        "startedAt": now,
        "finishedAt": None,
        "durationSeconds": None,
        "repository": {
            "head": git_output("rev-parse", "HEAD"),
            "branch": branch,
            "dirty": bool(status),
            "workingTreeFingerprint": working_tree_fingerprint(),
        },
        "host": {
            "macOSVersion": platform.mac_ver()[0],
            "architecture": platform.machine(),
        },
        "toolchain": {
            "developerDir": str(developer_dir),
            "xcodeVersion": version[0],
            "xcodeBuild": version[1],
            "swiftVersion": swift_version,
            "supported": version_at_least(version[0], config["minimumXcodeVersion"]),
        },
        "invocation": {
            "preset": arguments.preset,
            "arguments": scrub_arguments(arguments.arguments),
            "workspace": config["workspace"],
            "scheme": config["scheme"],
            "configuration": arguments.configuration,
            "destination": arguments.destination,
            "signingMode": arguments.signing_mode,
            "coverageGate": arguments.coverage_gate,
        },
        "steps": [],
        "artifacts": [],
        "status": "running",
        "exitCode": None,
        "_startedMonotonic": time.time(),
    }


def command_receipt_init(arguments: argparse.Namespace) -> int:
    atomic_json(arguments.path, receipt_base(arguments))
    return 0


def command_receipt_step(arguments: argparse.Namespace) -> int:
    payload = json.loads(arguments.path.read_text())
    test_counts = None
    coverage = None
    failure_category = None
    if arguments.xcresult and pathlib.Path(arguments.xcresult).is_dir():
        try:
            summary = run(
                [
                    "xcrun",
                    "xcresulttool",
                    "get",
                    "test-results",
                    "summary",
                    "--path",
                    arguments.xcresult,
                    "--format",
                    "json",
                ],
                timeout=30,
            )
            if summary.returncode == 0:
                raw_summary = json.loads(summary.stdout)
                test_counts = {
                    "total": int(raw_summary.get("totalTestCount", 0)),
                    "passed": int(raw_summary.get("passedTests", 0)),
                    "failed": int(raw_summary.get("failedTests", 0)),
                    "skipped": int(raw_summary.get("skippedTests", 0)),
                }
                if test_counts["failed"]:
                    failure_category = "test-failure"
                elif arguments.exit_code and not test_counts["total"]:
                    failure_category = "test-infrastructure"
            coverage_result = run(
                ["xcrun", "xccov", "view", "--report", "--json", arguments.xcresult],
                timeout=30,
            )
            if coverage_result.returncode == 0:
                targets = json.loads(coverage_result.stdout).get("targets", [])
                target = next((item for item in targets if item.get("name") == "GitX.app"), None)
                if target is not None:
                    line_coverage = target.get("lineCoverage")
                    coverage = {
                        "target": target["name"],
                        "lineCoverage": float(line_coverage) if line_coverage is not None else None,
                    }
        except (OSError, subprocess.TimeoutExpired, ValueError, json.JSONDecodeError):
            pass
    if arguments.exit_code and failure_category is None:
        failure_category = "command"
    step = {
        "name": arguments.name,
        "status": arguments.status,
        "exitCode": arguments.exit_code,
        "durationSeconds": round(arguments.duration, 3),
        "command": scrub_arguments(arguments.command),
        "log": relative_artifact(arguments.log),
        "xcresult": relative_artifact(arguments.xcresult),
        "failureCategory": failure_category,
        "testCounts": test_counts,
        "coverage": coverage,
    }
    payload["steps"].append(step)
    for value in (arguments.log, arguments.xcresult):
        artifact = relative_artifact(value)
        if artifact and artifact not in payload["artifacts"]:
            payload["artifacts"].append(artifact)
    atomic_json(arguments.path, payload)
    return 0


def command_receipt_finish(arguments: argparse.Namespace) -> int:
    payload = json.loads(arguments.path.read_text())
    now = dt.datetime.now(dt.timezone.utc)
    payload["finishedAt"] = now.isoformat()
    started = payload.pop("_startedMonotonic", None)
    payload["durationSeconds"] = round(time.time() - started, 3) if isinstance(started, (int, float)) else None
    payload["status"] = arguments.status
    payload["exitCode"] = arguments.exit_code
    run_directory = arguments.path.parent
    bundle_suffixes = {".app", ".xcarchive", ".xcresult"}
    discovered: set[str | None] = set()
    for collection in ("Logs", "Results"):
        collection_root = run_directory / collection
        if not collection_root.exists():
            continue
        for path in collection_root.rglob("*"):
            parents_inside_collection = path.relative_to(collection_root).parents
            if any(parent.suffix in bundle_suffixes for parent in parents_inside_collection):
                continue
            if path.is_file() or path.suffix in bundle_suffixes:
                discovered.add(relative_artifact(str(path)))
    products_root = run_directory / "Products"
    if products_root.exists():
        for path in products_root.iterdir():
            # Package scratch directories contain thousands of compiler cache
            # files. A coverage file explicitly attached to a step is retained,
            # while discovery records only top-level deliverables.
            if path.is_file() or path.suffix in bundle_suffixes:
                discovered.add(relative_artifact(str(path)))
    payload["artifacts"] = sorted(
        artifact for artifact in set(payload.get("artifacts", [])) | discovered if artifact
    )
    atomic_json(arguments.path, payload)
    config = load_config()
    latest = ROOT / config["artifactRoot"] / "latest.json"
    atomic_json(
        latest,
        {"schemaVersion": 1, "runId": payload["runId"], "receipt": relative_artifact(str(arguments.path))},
    )
    return 0


def command_config(arguments: argparse.Namespace) -> int:
    value: Any = load_config()
    for component in arguments.key.split("."):
        value = value[component]
    if isinstance(value, (dict, list)):
        print(json.dumps(value, sort_keys=True))
    else:
        print(value)
    return 0


def command_run_id(arguments: argparse.Namespace) -> int:
    if arguments.value:
        if RUN_ID.fullmatch(arguments.value) is None:
            print("Run IDs may contain only letters, numbers, dots, underscores, and hyphens.", file=sys.stderr)
            return 2
        print(arguments.value)
        return 0
    timestamp = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    commit = git_output("rev-parse", "--short=10", "HEAD") or "uncommitted"
    suffix = os.environ.get("GITHUB_RUN_ID")
    if suffix:
        attempt = os.environ.get("GITHUB_RUN_ATTEMPT", "1")
        job = re.sub(r"[^A-Za-z0-9._-]", "-", os.environ.get("GITHUB_JOB", "job"))
        suffix = f"{suffix}-{attempt}-{job}"
    else:
        suffix = str(os.getpid())
    print(f"{timestamp}-{commit}-{suffix}")
    return 0


def command_developer_dir(arguments: argparse.Namespace) -> int:
    selected = resolve_developer_dir(load_config())
    if selected is None:
        print("No supported Xcode developer directory was found.", file=sys.stderr)
        return 1
    print(selected)
    return 0


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__)
    subparsers = result.add_subparsers(dest="command", required=True)
    doctor = subparsers.add_parser("doctor")
    doctor.add_argument("--mode", choices=("build", "test", "ui", "ci"), default="build")
    doctor.add_argument("--format", choices=("text", "json"), default="text")
    doctor.add_argument("--developer-dir")
    doctor.add_argument("--destination")
    doctor.set_defaults(handler=command_doctor)

    config = subparsers.add_parser("config")
    config.add_argument("key")
    config.set_defaults(handler=command_config)

    run_id = subparsers.add_parser("run-id")
    run_id.add_argument("value", nargs="?")
    run_id.set_defaults(handler=command_run_id)

    developer_dir = subparsers.add_parser("developer-dir")
    developer_dir.set_defaults(handler=command_developer_dir)

    receipt_init = subparsers.add_parser("receipt-init")
    receipt_init.add_argument("path", type=pathlib.Path)
    receipt_init.add_argument("--run-id", required=True)
    receipt_init.add_argument("--preset", required=True)
    receipt_init.add_argument("--configuration", required=True)
    receipt_init.add_argument("--destination", required=True)
    receipt_init.add_argument("--developer-dir", required=True)
    receipt_init.add_argument("--signing-mode", required=True)
    receipt_init.add_argument("--coverage-gate", default="not-applicable")
    receipt_init.add_argument("arguments", nargs=argparse.REMAINDER)
    receipt_init.set_defaults(handler=command_receipt_init)

    receipt_step = subparsers.add_parser("receipt-step")
    receipt_step.add_argument("path", type=pathlib.Path)
    receipt_step.add_argument("--name", required=True)
    receipt_step.add_argument("--status", choices=("passed", "failed", "blocked", "interrupted"), required=True)
    receipt_step.add_argument("--exit-code", type=int, required=True)
    receipt_step.add_argument("--duration", type=float, required=True)
    receipt_step.add_argument("--log")
    receipt_step.add_argument("--xcresult")
    receipt_step.add_argument("command", nargs=argparse.REMAINDER)
    receipt_step.set_defaults(handler=command_receipt_step)

    receipt_finish = subparsers.add_parser("receipt-finish")
    receipt_finish.add_argument("path", type=pathlib.Path)
    receipt_finish.add_argument("--status", choices=("passed", "failed", "blocked", "interrupted"), required=True)
    receipt_finish.add_argument("--exit-code", type=int, required=True)
    receipt_finish.set_defaults(handler=command_receipt_finish)
    return result


def main() -> int:
    arguments = parser().parse_args()
    try:
        return arguments.handler(arguments)
    except (KeyError, OSError, ValueError, json.JSONDecodeError) as error:
        print(error, file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
