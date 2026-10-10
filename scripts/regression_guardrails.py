#!/usr/bin/env python3
"""Report regression contracts and local completion evidence (advisory only).

Policy findings exit zero. Operational errors exit two. Builds, tests, AI,
network access and mutation testing are never started by this command.
"""
from __future__ import annotations

import argparse
import datetime as dt
import fnmatch
import json
import os
import pathlib
import re
import subprocess
import sys
import uuid

import dev_workflow
import report_xcresult
import verification_support as verification
import workflow_session as session

ROOT = pathlib.Path(__file__).resolve().parent.parent
CATALOGUE = ROOT / "scripts/regression-contracts.json"
SOURCE_PREFIXES = ("Classes/", "GitXTests/", "GitXUITests/", "GitXCore/", "ForgeKit/",
                   "Resources/", "GitX.xcodeproj/", "GitX.xcworkspace/")
GENERAL_APP_CHECKS = {"static", "interop", "debug-test-build", "release-test-build",
                      "correctness", "stage-debug"}
ROLES = {"valid", "failure", "boundary", "compatibility", "performance"}
BLOCKERS = {"resource-busy", "console-unavailable", "display-unavailable", "desktop-locked",
            "signature-invalid", "signature-incompatible", "host-probe-missing",
            "host-startup-timeout", "unknown-host-startup-timeout", "test-infrastructure",
            "dependency-unavailable", "test-evidence-missing", "test-selection-empty"}


def finding(code, detail, contract=None):
    return {"code": code, "detail": detail, "contract": contract,
            "affectsReadiness": code not in {"unmapped-source", "contract-path-missing"}}


def relative_path(value):
    return (isinstance(value, str) and bool(value) and "\0" not in value
            and not pathlib.PurePosixPath(value).is_absolute()
            and ".." not in pathlib.PurePosixPath(value).parts)


def contains_test(contents, class_name, method):
    """Conservative lexical membership; actual consumer execution remains proof."""
    masked = re.sub(r'/\*.*?\*/|//[^\n]*|""".*?"""|"(?:\\.|[^"\\])*"',
                    lambda match: " " * len(match.group()), contents, flags=re.S)
    for declaration in re.finditer(r"@implementation\s+" + re.escape(class_name) + r"\b", masked):
        end = masked.find("@end", declaration.end())
        body = masked[declaration.end():end if end >= 0 else len(masked)]
        if re.search(r"-\s*\([^)]*\)\s*" + re.escape(method) + r"\s*\{", body):
            return True
    for declaration in re.finditer(r"\b(?:class|extension)\s+" + re.escape(class_name) + r"\b", masked):
        start = masked.find("{", declaration.end())
        if start < 0:
            continue
        depth = 1
        end = start + 1
        while end < len(masked) and depth:
            depth += (masked[end] == "{") - (masked[end] == "}")
            end += 1
        body = masked[start + 1:end - 1]
        for match in re.finditer(r"\bfunc\s+" + re.escape(method) + r"\s*\(", body):
            prefix = body[:match.start()]
            if prefix.count("{") == prefix.count("}"):
                return True
    return False


def validate_catalogue(payload, root=ROOT):
    """Validate references lexically; compilation and execution establish truth."""
    problems, warnings, contracts, seen = [], [], [], set()
    profiles = {name for name, _ in dev_workflow.full_profile(root)}
    if not isinstance(payload, dict) or payload.get("schemaVersion") != 1 or not isinstance(payload.get("contracts"), list):
        return [], [finding("catalogue-invalid", "Expected schemaVersion 1 and a contracts array")]
    for item in payload["contracts"]:
        if not isinstance(item, dict):
            problems.append(finding("contract-invalid", "Contract must be an object"))
            continue
        identity = item.get("id")
        if not isinstance(identity, str) or not re.fullmatch(r"[A-Z]+-\d{3}", identity) or identity in seen:
            problems.append(finding("contract-id-invalid", f"Invalid or duplicate contract ID: {identity!r}"))
            continue
        seen.add(identity)
        start = len(problems)
        for field in ("family", "invariant", "rootCause"):
            if not isinstance(item.get(field), str) or not item[field].strip():
                problems.append(finding("contract-field-missing", f"{field} must be nonempty", identity))
        paths = item.get("sourcePaths")
        if not isinstance(paths, list) or not paths or not all(relative_path(p) for p in paths):
            problems.append(finding("contract-path-invalid", "sourcePaths must contain relative path patterns", identity))
        else:
            for pattern in paths:
                if not any(path.is_file() for path in pathlib.Path(root).glob(pattern)):
                    warnings.append(finding("contract-path-missing", f"No current source matches {pattern}", identity))
        checks = item.get("requiredChecks")
        if not isinstance(checks, list) or not checks or any(not isinstance(p, str) or p not in profiles for p in checks):
            problems.append(finding("contract-check-invalid", "requiredChecks must name canonical workflow checks", identity))
            checks = []
        tests = item.get("tests")
        if not isinstance(tests, list) or not tests:
            problems.append(finding("contract-test-missing", "At least one protecting test is required", identity))
        else:
            test_ids = set()
            for test in tests:
                if not isinstance(test, dict):
                    problems.append(finding("contract-test-invalid", "Test reference must be an object", identity))
                    continue
                identifier = test.get("identifier", "")
                source = test.get("source", "")
                check = test.get("check", "correctness")
                if not isinstance(identifier, str) or not isinstance(check, str):
                    problems.append(finding("contract-test-invalid", "Test identifier and check must be strings", identity))
                    continue
                key = (identifier, check)
                if (not isinstance(identifier, str) or not re.fullmatch(r"\w+/\w+/test\w+", identifier)
                        or key in test_ids or not relative_path(source) or check not in profiles
                        or check not in checks):
                    problems.append(finding("contract-test-invalid", f"Invalid test reference: {identifier!r}", identity))
                    continue
                test_ids.add(key)
                if test.get("role") not in ROLES or not isinstance(test.get("oracle"), str) or not test["oracle"].strip():
                    problems.append(finding("contract-oracle-missing", f"{identifier} needs a role and independent oracle description", identity))
                path = pathlib.Path(root) / source
                if not path.is_file():
                    problems.append(finding("contract-test-missing", f"Missing source: {source}", identity))
                    continue
                _, class_name, method = identifier.split("/")
                contents = path.read_text(errors="replace")
                if not contains_test(contents, class_name, method):
                    problems.append(finding("contract-test-missing", f"Cannot find {identifier} in {source}", identity))
            if not any(test.get("role") == "valid" for test in tests if isinstance(test, dict)):
                problems.append(finding("contract-valid-case-missing", "Include a valid behavior test alongside rejection cases", identity))
        if len(problems) == start:
            contracts.append(item)
    if not payload["contracts"]:
        problems.append(finding("catalogue-empty", "The catalogue contains no contracts"))
    return contracts, problems + warnings


def git(root, *arguments):
    result = subprocess.run(["git", "-C", str(root), *arguments], capture_output=True, timeout=30, env=session.git_environment())
    if result.returncode:
        raise ValueError(result.stderr.decode(errors="replace").strip() or "Git inspection failed")
    return result.stdout


def changes(root, base):
    resolved = git(root, "rev-parse", "--verify", "--end-of-options", base + "^{commit}").decode().strip()
    head = git(root, "rev-parse", "HEAD").decode().strip()
    merge_base = git(root, "merge-base", resolved, head).decode().strip()
    fields = git(root, "diff", "--name-status", "-z", "--find-renames", merge_base, "--").split(b"\0")
    paths, index = set(), 0
    while index < len(fields) and fields[index]:
        status = fields[index].decode("ascii")
        width = 2 if status.startswith(("R", "C")) else 1
        for path in fields[index + 1:index + 1 + width]:
            paths.add(os.fsdecode(path))
        index += width + 1
    paths.update(os.fsdecode(p) for p in git(root, "ls-files", "--others", "--exclude-standard", "-z").split(b"\0") if p)
    return {"base": resolved, "mergeBase": merge_base, "head": head}, sorted(p for p in paths if not session.generated_input_path(p))


def select_contracts(contracts, paths):
    all_contracts = "scripts/regression-contracts.json" in paths
    selected = []
    for item in contracts:
        test_paths = {test["source"] for test in item["tests"]}
        matched = [p for p in paths if p in test_paths or any(fnmatch.fnmatchcase(p, pattern) for pattern in item["sourcePaths"])]
        if all_contracts or matched:
            selected.append({**item, "changedPaths": matched})
    return selected


def required_checks(paths, contracts):
    paths = [p for p in paths if not session.generated_input_path(p)]
    mapped = {path for contract in contracts for path in contract["sourcePaths"]}
    mapped.update(test["source"] for contract in contracts for test in contract["tests"])
    checks = {"static"} if paths else set()
    if any(session.build_input_path(p) and (not p.startswith(SOURCE_PREFIXES) or not any(fnmatch.fnmatchcase(p, pattern) for pattern in mapped)) for p in paths):
        checks.update(name for name, _ in dev_workflow.full_profile(ROOT))
    app = any(p.startswith(SOURCE_PREFIXES) for p in paths)
    if app:
        checks.update(GENERAL_APP_CHECKS)
    if any(p.startswith("GitXCore/") for p in paths):
        checks.add("core")
    if any(p.startswith("ForgeKit/") for p in paths):
        checks.add("forgekit")
    for item in contracts:
        checks.update(item["requiredChecks"])
    return sorted(checks)


def normalize_identifier(bundle, identifier):
    if not isinstance(identifier, str):
        return None
    identifier = re.sub(r"\(\)$", "", identifier)
    if identifier.startswith(bundle + "/"):
        return identifier
    return bundle + "/" + identifier


def collect_test_outcomes(payload):
    """Retain configurations and failing repetitions instead of flattening them."""
    outcomes = []
    def visit(node, bundle="", configuration=None):
        if not isinstance(node, dict):
            return
        if node.get("nodeType") in {"Unit test bundle", "UI test bundle"}:
            bundle = node.get("name", "")
        if node.get("nodeType") == "Test Plan Configuration":
            configuration = node.get("name")
        if node.get("nodeType") == "Test Case":
            identifier = normalize_identifier(bundle, node.get("nodeIdentifier") or node.get("name"))
            if identifier and bundle:
                result = node.get("result", "Unknown")
                repeated = [child.get("result") for child, _ in report_xcresult.walk(node)
                            if child.get("nodeType") == "Repetition"]
                if "Failed" in repeated or report_xcresult.failure_messages(node):
                    result = "Failed"
                elif result == "Passed" and any(value not in {None, "Passed"} for value in repeated):
                    result = "Unknown"
                outcomes.append({"identifier": identifier, "configuration": configuration, "result": result})
        for child in node.get("children") or []:
            visit(child, bundle, configuration)
    for node in payload.get("testNodes") or []:
        visit(node)
    return outcomes


class EvidenceContext:
    """Cache expensive identity reads, always using canonical workflow helpers."""
    def __init__(self, root=ROOT):
        self.root = pathlib.Path(root)
        self.inputs = session.inputs(root)
        self.toolchain = session.cache_paths(root)["toolchain"]
        developer = verification.resolve_developer_dir(verification.load_config())
        self.version = verification.xcode_version(developer) if developer else None
        self.memo = {}

    def identity(self, kind, value):
        key = (kind, str(value))
        if key not in self.memo:
            functions = {"products": session.product_identity, "results": session.tree_identity,
                         "packages": session.package_products, "dependencies": session.dependency_products}
            self.memo[key] = functions[kind](value)
        return self.memo[key]

    def tests(self, path):
        key = ("tests", str(path))
        if key not in self.memo:
            self.memo[key] = collect_test_outcomes(report_xcresult.run_xcresulttool(path, "tests"))
        return self.memo[key]


def input_problems(evidence, context):
    if not isinstance(evidence, dict) or evidence.get("status") != "valid":
        return ["Evidence is not recorded as valid"]
    before, after = evidence.get("inputsBefore"), evidence.get("inputsAfter")
    required = {"root", "head", "source", "dependencies", "plans"}
    if not isinstance(before, dict) or not isinstance(after, dict) or not required <= before.keys() or not required <= after.keys():
        return ["Historical or incomplete input provenance"]
    changed = session.changed_inputs(before, after) + session.changed_inputs(after, context.inputs)
    if evidence.get("changedInputs"):
        changed.append("recorded inputs during verification")
    if before["root"] != str(context.root) or after["root"] != str(context.root):
        changed.append("checkout")
    return ["Changed " + key for key in sorted(set(changed))]


def result_path(context, value):
    path = pathlib.Path(value)
    return path if path.is_absolute() else context.root / path


def xcode_problems(payload, context, mutable_caches=None):
    evidence = payload.get("evidence", {})
    problems = input_problems(evidence, context)
    if payload.get("schemaVersion") != 2:
        problems.append("Historical receipt schema")
    toolchain = payload.get("toolchain", {})
    if context.version is None or (toolchain.get("xcodeVersion"), toolchain.get("xcodeBuild")) != context.version:
        problems.append("Toolchain does not match the current supported Xcode")
    paths = payload.get("buildPaths", {})
    problems.extend(session.receipt_artifact_problems(payload, context.root, mutable_caches, context.identity))
    derived = paths.get("derivedData")
    analysis = payload.get("invocation", {}).get("preset") == "analyze"
    artifacts = evidence.get("analysisArtifacts", {})
    durable_analysis = (analysis and derived and pathlib.Path(derived).name.startswith("AnalyzerDerivedData.")
                        and bool(artifacts) and all(identity is not None and identity == context.identity("results", result_path(context, path))
                        for path, identity in artifacts.items()))
    if analysis and payload.get("status") == "passed":
        names = {step.get("name") for step in payload.get("steps", []) if step.get("status") == "passed"}
        if not {"analyze", "analyzer-policy", "swiftlint-analyze"} <= names:
            problems.append("Analyzer policy checks did not all pass")
        if any(not step.get("log") or step["log"] not in artifacts for step in payload.get("steps", [])
               if step.get("name") in {"analyze", "analyzer-policy", "swiftlint-analyze"}):
            problems.append("Analyzer policy log identities are missing")
    if analysis and not durable_analysis:
        problems.append("Durable analyzer diagnostics are missing or changed")
    return problems


def receipt_check(payload):
    invocation = payload.get("invocation", {})
    preset, configuration = invocation.get("preset"), invocation.get("configuration")
    if preset == "build-tests":
        return {"Debug": "debug-test-build", "Release": "release-test-build"}.get(configuration)
    if preset == "analyze":
        return "analyze"
    if isinstance(preset, str) and preset.startswith("test:"):
        name = preset[5:]
        if name == "correctness" and configuration == "Release":
            return "release-contracts"
        return name
    entry = pathlib.Path(payload.get("entry", "")).name
    return {"verify_static.sh": "static", "check_test_build_contracts.py": "interop"}.get(entry)


def timestamp(payload):
    times = []
    for key in ("finishedAt", "updatedAt"):
        value = payload.get(key)
        if value:
            parsed = dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
            if parsed.tzinfo is None:
                raise ValueError("Receipt timestamps must include a timezone")
            times.append(parsed.astimezone(dt.timezone.utc))
    # Resuming a finished workflow can retain its previous finishedAt while a
    # new attempt updates updatedAt and fails. Never let that old finish hide it.
    return max(times).isoformat() if times else ""


def observed_status(payload):
    steps = payload.get("steps", [])
    if any((s.get("testCounts") or {}).get("failed", 0) for s in steps):
        return "failed"
    if payload.get("status") == "blocked" or payload.get("category") in BLOCKERS or payload.get("exitCode") in {75, 77, 78, 124}:
        return "blocked"
    if any(s.get("status") == "blocked" for s in steps):
        return "blocked"
    if any(s.get("failureCategory") in BLOCKERS for s in steps if s.get("status") != "passed"):
        return "blocked"
    return payload.get("status", "unknown")


def inspect_receipt(path, context, expected_check=None, mutable_caches=None):
    path = pathlib.Path(path)
    record = {"receipt": str(path), "check": expected_check, "validity": "invalid",
              "status": "unknown", "reasons": [], "tests": [], "finishedAt": ""}
    try:
        payload = json.loads(path.read_text())
        if not isinstance(payload, dict):
            raise ValueError("Receipt must be an object")
        actual_check = receipt_check(payload)
        invocation = payload.get("invocation", {})
        # Staging is proved by the canonical workflow command AND its app output;
        # a standalone build receipt cannot claim to have staged the app.
        if expected_check == "stage-debug" and invocation.get("preset") == "build" and invocation.get("configuration") == "Debug":
            actual_check = "stage-debug"
        record.update(check=actual_check, status=observed_status(payload),
                      finishedAt=timestamp(payload))
        if "invocation" in payload:
            record["reasons"] = xcode_problems(payload, context, mutable_caches)
            for step in payload.get("steps", []):
                if step.get("xcresult") and step["xcresult"].endswith(".xcresult"):
                    try:
                        record["tests"].extend({**test, "planConfiguration": test.get("configuration"),
                                               "configuration": invocation.get("configuration")}
                                               for test in context.tests(result_path(context, step["xcresult"])))
                    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
                        record["reasons"].append("Cannot read test outcomes: " + str(error))
            if record["check"] == "correctness" and payload.get("status") == "passed":
                invocation = payload["invocation"]
                if invocation.get("configuration") != "Debug" or invocation.get("coverageGate") != "enforced":
                    record["reasons"].append("A complete Debug correctness run with coverage is required")
                if any(str(a).startswith(("-only-testing", "-skip-testing")) for a in invocation.get("arguments", [])):
                    record["reasons"].append("Focused correctness execution cannot satisfy full correctness")
                if not any(s.get("name") == "coverage" and s.get("status") == "passed" for s in payload.get("steps", [])):
                    record["reasons"].append("Coverage gate did not pass")
            if record["check"] in {"core", "forgekit"} and payload.get("status") == "passed":
                if any(str(a).startswith(("--filter", "--skip", "--list")) for a in payload["invocation"].get("arguments", [])):
                    record["reasons"].append("Focused package execution cannot satisfy its full check")
                if not any(s.get("name") == "coverage:" + record["check"] and s.get("status") == "passed" for s in payload.get("steps", [])):
                    record["reasons"].append("Package coverage gate did not pass")
        else:
            record["reasons"] = input_problems(payload.get("evidence"), context)
            if payload.get("paths", {}).get("toolchain") != context.toolchain:
                record["reasons"].append("Coordination receipt lacks matching toolchain provenance")
        if not record["finishedAt"] and not payload.get("entry"):
            record["reasons"].append("Receipt did not finish")
        if payload.get("entry") and not record["finishedAt"]:
            # Coordination receipts currently have no wall-clock timestamp.
            # Nonpassing observations cannot be safely ordered around a pass.
            record["finishedAt"] = ""
        if not record["check"]:
            record["reasons"].append("Unrecognized verification check")
        if expected_check and record["check"] != expected_check:
            record["reasons"].append("Child receipt does not match its workflow check")
            record["check"] = expected_check
        if payload.get("status") == "passed" and payload.get("exitCode") != 0:
            record["reasons"].append("Passed status disagrees with command exit")
        if any(t["result"] == "Failed" for t in record["tests"]):
            record["status"] = "failed"
        record["validity"] = "valid" if not record["reasons"] else "invalid"
    except (OSError, ValueError, TypeError, KeyError, AttributeError, subprocess.SubprocessError) as error:
        record["reasons"].append(str(error))
    return record


def inspect_workflow(path, payload, context):
    records = []
    commands = dict(dev_workflow.full_profile(context.root))
    global_problems = input_problems({"status": "invalid" if payload.get("evidenceStatus") == "invalid" else "valid",
        "inputsBefore": payload.get("inputsBefore"), "inputsAfter": payload.get("inputsAfter")}, context)
    if payload.get("schemaVersion") != 2:
        global_problems.append("Historical workflow schema")
    cache_problems = session.final_cache_problems(payload, context.root)
    global_problems.extend(cache_problems)
    mutable_caches = None if cache_problems else payload.get("finalCacheProducts", session.workflow_cache_snapshots(payload, context.root))
    for step in payload.get("steps", []):
        name = step.get("name")
        if step.get("receipt"):
            child = inspect_receipt(result_path(context, step["receipt"]), context, name, mutable_caches)
        else:
            child = {"receipt": str(path), "check": name, "status": observed_status(step),
                     "validity": "invalid", "tests": [], "reasons": [], "finishedAt": timestamp(payload)}
        problems = global_problems + input_problems({"status": step.get("evidenceStatus"),
            "inputsBefore": step.get("inputsBefore"), "inputsAfter": step.get("inputsAfter")}, context)
        if name not in commands or not session.command_matches(step, commands.get(name, [])):
            problems.append("Workflow command does not match its canonical check")
        if step.get("toolchain") != context.toolchain:
            problems.append("Workflow toolchain changed")
        if step.get("status") == "passed" and step.get("exitCode") != 0:
            problems.append("Passed workflow step disagrees with command exit")
        for output, expected in step.get("outputs", {}).items():
            if expected is None or context.identity("results", result_path(context, output)) != expected:
                problems.append("Workflow output missing or changed: " + output)
        if name == "stage-debug" and str(context.root / "build/GitX.app") not in step.get("outputs", {}):
            problems.append("Staged Debug app identity is missing")
        child["reasons"].extend(problems)
        child["validity"] = "valid" if not child["reasons"] else "invalid"
        if child["status"] == "unknown":
            child["status"] = step.get("status", "unknown")
        if step.get("status") in {"failed", "blocked", "interrupted"} and child["status"] == "passed":
            child["status"] = step["status"]
        records.append(child)
    return records


def inspect_evidence(paths, context):
    records = []
    for value in dict.fromkeys(str(pathlib.Path(p).resolve()) for p in paths):
        path = pathlib.Path(value)
        try:
            payload = json.loads(path.read_text())
            if isinstance(payload, dict) and "profile" in payload and "invocation" not in payload:
                records.extend(inspect_workflow(path, payload, context))
            else:
                records.append(inspect_receipt(path, context))
        except (OSError, ValueError, TypeError, KeyError, AttributeError, subprocess.SubprocessError) as error:
            records.append({"receipt": value, "check": None, "validity": "invalid", "status": "unknown",
                            "reasons": [str(error)], "tests": [], "finishedAt": ""})
    return records


def assess_checks(checks, contracts, records):
    assessed, test_results = [], []
    chosen = {}
    for name in checks:
        candidates = [r for r in records if r["check"] == name and r["validity"] == "valid"]
        if candidates:
            # A later failure supersedes an earlier success; input order cannot hide it.
            untimed = [r for r in candidates if not r["finishedAt"] and r["status"] != "passed"]
            severity = {"failed": 3, "blocked": 2, "passed": 0}
            latest = max(untimed or candidates, key=lambda r: (r["finishedAt"], severity.get(r["status"], 1), r["receipt"]))
            chosen[name] = latest
            status = latest["status"] if latest["status"] in {"passed", "failed", "blocked"} else "incomplete"
            assessed.append({"check": name, "status": status, "receipt": latest["receipt"]})
        else:
            assessed.append({"check": name, "status": "incomplete", "receipt": None})
    for contract in contracts:
        for test in contract["tests"]:
            check = test.get("check", "correctness")
            outcomes = chosen.get(check, {}).get("tests", [])
            configuration = "Release" if check in {"release-contracts", "performance"} else "Debug"
            matches = [t for t in outcomes if t["identifier"] == test["identifier"]
                       and t.get("configuration") == configuration]
            statuses = {m["result"] for m in matches}
            status = "failed" if "Failed" in statuses else "passed" if statuses == {"Passed"} else "incomplete"
            test_results.append({"contract": contract["id"], "identifier": test["identifier"], "status": status,
                                 "check": check, "observedResults": sorted(statuses)})
    statuses = {item["status"] for item in assessed + test_results}
    status = ("failed" if "failed" in statuses else "blocked" if "blocked" in statuses
              else "incomplete" if "incomplete" in statuses else "ready")
    return status, assessed, test_results


def build_report(root, base, payload):
    identities, paths = changes(root, base)
    contracts, problems = validate_catalogue(payload, root)
    selected = select_contracts(contracts, paths)
    mapped = {p for item in selected for p in item["changedPaths"]}
    for path in paths:
        if path.startswith(SOURCE_PREFIXES) and path not in mapped:
            problems.append(finding("unmapped-source", f"No seeded regression contract matches {path}"))
    return {"schemaVersion": 1, "mode": "advisory", "action": "check", "status": "incomplete" if any(f["affectsReadiness"] for f in problems) else "ready",
            "repository": identities, "changedPaths": paths, "contracts": selected,
            "requiredChecks": required_checks(paths, selected), "findings": problems}


def render(report):
    lines = [f"Regression {report['action']}: {report['status']} (advisory)",
             f"Base {report['repository']['base']}; HEAD {report['repository']['head']}",
             f"{len(report['contracts'])} affected contracts; {len(report['changedPaths'])} changed paths."]
    if report["action"] == "check":
        lines.append("Metadata check only; completion requires assess with current canonical verification evidence.")
    for item in report["contracts"]:
        lines.append(f"  {item['id']}: {item['invariant']}")
    for item in report["findings"]:
        lines.append(f"  [{item['code']}, {'blocking' if item['affectsReadiness'] else 'warning'}] {item['detail']}")
    for item in report.get("checks", []):
        lines.append(f"  {item['check']}: {item['status']}")
    for item in report.get("testEvidence", []):
        if item["status"] != "passed":
            lines.append(f"  {item['contract']} {item['identifier']}: {item['status']}")
    for item in report.get("receipts", []):
        if item["validity"] != "valid":
            lines.append(f"  Invalid evidence {item['receipt']} (observed {item['status']}): {'; '.join(item['reasons'])}")
    lines.append("Policy findings do not block execution. Existing test and coverage failures remain authoritative.")
    lines.append("Report: " + report["reportPath"])
    return "\n".join(lines)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("check", "assess"))
    parser.add_argument("--base", required=True)
    parser.add_argument("--receipts", nargs="+", type=pathlib.Path, default=[])
    parser.add_argument("--format", choices=("text", "json"), default="text")
    parser.add_argument("--output", type=pathlib.Path)
    args = parser.parse_args(argv)
    try:
        before = session.inputs(ROOT)
        contents = CATALOGUE.read_text()
        try:
            payload = json.loads(contents)
        except ValueError:
            payload = None
        report = build_report(ROOT, args.base, payload)
        report["inputs"] = {key: value for key, value in before.items() if key != "files"}
        if report["repository"]["head"] != before["head"]:
            report["findings"].append(finding("assessment-inputs-changed", "HEAD changed while collecting the diff"))
        tracked = set(session.git(ROOT, "ls-files", "-z").split("\0"))
        for path in report["changedPaths"]:
            if session.build_input_path(path) and (ROOT / path).is_file() and (path not in before["files"] or path not in tracked):
                report["findings"].append(finding("unfingerprinted-source", f"Canonical inputs do not yet fingerprint {path}; track it before final verification"))
        if any(f["affectsReadiness"] for f in report["findings"]):
            report["status"] = "incomplete"
        if args.action == "assess":
            context = EvidenceContext(ROOT)
            records = inspect_evidence(args.receipts, context)
            status, checks, tests = assess_checks(report["requiredChecks"], report["contracts"], records)
            report.update(action="assess", status=status, checks=checks, testEvidence=tests, receipts=records)
            if any(f["affectsReadiness"] for f in report["findings"]) and status == "ready":
                report["status"] = "incomplete"
        drift = session.changed_inputs(before, session.inputs(ROOT))
        if drift:
            report["findings"].append(finding("assessment-inputs-changed", ", ".join(drift)))
            if report["status"] not in {"failed", "blocked"}:
                report["status"] = "incomplete"
        output = args.output or ROOT / "artifacts/verification/regression-guardrails" / (uuid.uuid4().hex + ".json")
        output = output.resolve()
        if not output.is_relative_to((ROOT / "artifacts/verification").resolve()):
            raise ValueError("Reports must stay under ignored artifacts/verification")
        if output.exists():
            existing = json.loads(output.read_text())
            if not isinstance(existing, dict) or existing.get("mode") != "advisory" or existing.get("action") not in {"check", "assess"}:
                raise ValueError("Output would overwrite an existing verification artifact")
        report["reportPath"] = str(output)
        session.atomic_json(output, report)
        print(json.dumps(report, indent=2, sort_keys=True) if args.format == "json" else
              render(report).encode("utf-8", "backslashreplace").decode("utf-8"))
        return 0
    except (OSError, ValueError, TypeError, KeyError, AttributeError, subprocess.SubprocessError) as error:
        print("Regression assessor operational error: " + str(error), file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
