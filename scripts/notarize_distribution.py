"""Submit once and retain evidence while waiting for Apple's notarization service."""

from __future__ import annotations

import json
import os
import pathlib
import subprocess
import sys
import time
import uuid


class NotarizationError(Exception):
    def __init__(self, message, status=1):
        super().__init__(message)
        self.status = status


def positive_integer(environment, key, default):
    value = environment.get(key, str(default))
    if not value.isascii() or not value.isdecimal() or int(value) <= 0:
        raise NotarizationError(f"{key} must be a positive integer")
    return int(value)


def response(text):
    try:
        result = json.loads(text)
    except ValueError as error:
        raise NotarizationError("Malformed notarization JSON") from error
    if not isinstance(result, dict):
        raise NotarizationError("Notarization response must be an object")
    return result


def submission_identifier(result):
    identifier = result.get("id")
    if not isinstance(identifier, str):
        raise NotarizationError("Notarization response has no submission ID")
    try:
        uuid.UUID(identifier)
    except ValueError as error:
        raise NotarizationError("Notarization submission ID is not a UUID") from error
    return identifier


def notarize(archive, directory, environment, *, run=subprocess.run, now=time.monotonic, sleep=time.sleep):
    timeout = positive_integer(environment, "GITX_NOTARIZATION_TIMEOUT_SECONDS", 3600)
    interval = positive_integer(environment, "GITX_NOTARIZATION_POLL_SECONDS", 30)
    credentials = []
    for flag, key in (("--apple-id", "APPLE_ID"), ("--team-id", "TEAM_ID"), ("--password", "APPLE_PASSWORD")):
        if not environment.get(key):
            raise NotarizationError(f"Missing {key}")
        credentials.extend((flag, environment[key]))
    directory = pathlib.Path(directory)
    directory.mkdir(parents=True, exist_ok=True)
    deadline = now() + timeout
    identifier = None

    def invoke(arguments, name, budget):
        try:
            result = run(["xcrun", "notarytool", *arguments, *credentials], capture_output=True,
                         text=True, encoding="utf-8", errors="replace", timeout=max(0.001, budget))
        except subprocess.TimeoutExpired as error:
            def decoded(value):
                return value.decode("utf-8", errors="replace") if isinstance(value, bytes) else value or ""
            result = subprocess.CompletedProcess([], 124, decoded(error.stdout), decoded(error.stderr))
        (directory / f"{name}.json").write_text(result.stdout)
        (directory / f"{name}.stderr").write_text(result.stderr)
        print(result.stdout, end="")
        print(result.stderr, end="", file=sys.stderr)
        return result

    try:
        submitted = invoke(["submit", str(archive), "--output-format", "json"], "notary-submission", timeout)
        try:
            initial = response(submitted.stdout)
            identifier = submission_identifier(initial)
        except NotarizationError:
            if submitted.returncode:
                raise NotarizationError("Notarization submission failed", submitted.returncode) from None
            raise
        if submitted.returncode:
            raise NotarizationError("Notarization submission failed", submitted.returncode)
        status = initial.get("status")
        if status not in (None, "Accepted", "In Progress", "Invalid", "Rejected"):
            raise NotarizationError("Unknown notarization status")
        attempt = 0
        while status != "Accepted":
            if status in ("Invalid", "Rejected"):
                raise NotarizationError(f"Notarization finished with status {status}")
            remaining = deadline - now()
            if remaining <= 0:
                raise NotarizationError(f"Notarization was not accepted within {timeout} seconds")
            attempt += 1
            print(f"[gitx-notary] Waiting for {identifier}, attempt {attempt}")
            invoke(["wait", identifier, "--timeout", f"{max(1, int(min(1200, remaining)))}s"],
                   f"notary-wait-{attempt}", remaining)
            remaining = deadline - now()
            if remaining <= 0:
                raise NotarizationError(f"Notarization was not accepted within {timeout} seconds")
            information = invoke(["info", identifier, "--output-format", "json"], f"notary-info-{attempt}", remaining)
            if information.returncode == 0:
                result = response(information.stdout)
                if submission_identifier(result) != identifier:
                    raise NotarizationError("Notarization status belongs to a different submission")
                status = result.get("status")
                if status not in ("Accepted", "In Progress", "Invalid", "Rejected"):
                    raise NotarizationError("Unknown notarization status")
                if status in ("Accepted", "Invalid", "Rejected"):
                    continue
            remaining = deadline - now()
            if remaining > 0:
                sleep(min(interval, remaining))
        print(f"[gitx-notary] Accepted submission {identifier}")
    finally:
        if identifier:
            details = directory / "notary-details.json"
            try:
                result = run(["xcrun", "notarytool", "log", identifier, *credentials, str(details)],
                             capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=30)
                (directory / "notary-details.stderr").write_text(result.stderr)
                if result.returncode == 0 and details.is_file():
                    print(details.read_text(encoding="utf-8", errors="replace"))
                else:
                    print(f"[gitx-notary] Could not fetch the detailed log for {identifier}", file=sys.stderr)
            except (OSError, subprocess.TimeoutExpired):
                print(f"[gitx-notary] Could not fetch the detailed log for {identifier}", file=sys.stderr)


def main(arguments=None):
    arguments = sys.argv[1:] if arguments is None else arguments
    if len(arguments) != 2:
        print("Usage: notarize_distribution.sh ZIP LOG_DIRECTORY", file=sys.stderr)
        return 2
    try:
        notarize(*arguments, os.environ)
    except (NotarizationError, OSError) as error:
        print(f"[gitx-notary] {error}", file=sys.stderr)
        return error.status if isinstance(error, NotarizationError) else 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
