from __future__ import annotations

import copy
import argparse
import contextlib
import io
import json
import pathlib
import subprocess
import tempfile
import unittest
from unittest import mock

from support import ROOT
import regression_guardrails as guard
import workflow_session as session


def test_tree(result="Passed", configuration=None, repetitions=()):
    case = {"nodeType": "Test Case", "nodeIdentifier": "ContractTests/testNormal()", "result": result,
            "children": [{"nodeType": "Repetition", "result": value} for value in repetitions]}
    bundle = {"nodeType": "Unit test bundle", "name": "GitXTests", "children": [case]}
    return {"testNodes": [bundle if configuration is None else {
        "nodeType": "Test Plan Configuration", "name": configuration, "children": [bundle]}]}


class Context:
    def __init__(self, root):
        self.root = root
        self.inputs = session.inputs(root)
        self.toolchain = "Xcode test"
        self.version = ("test", "build")

    def identity(self, kind, path):
        return {"results": session.tree_identity, "products": session.product_identity,
                "dependencies": session.dependency_products, "packages": session.package_products}[kind](path)

    def tests(self, path):
        return guard.collect_test_outcomes(json.loads((path / "tests.json").read_text()))


class RegressionGuardrailTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = pathlib.Path(self.directory.name).resolve()
        self.git("init", "-q")
        (self.root / "Classes").mkdir()
        (self.root / "Classes/Decision.swift").write_text("struct Decision {}\n")
        (self.root / "GitXTests").mkdir()
        (self.root / "GitXTests/ContractTests.swift").write_text(
            "class ContractTests { func testNormal() {} func testBoundary() {} }\n")
        self.git("add", ".")
        self.git("-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-qm", "base")
        self.base = self.git("rev-parse", "HEAD").strip()
        self.catalogue = {"schemaVersion": 1, "contracts": [{
            "id": "STATE-001", "family": "State", "invariant": "Only current intent may publish",
            "rootCause": "Stale callbacks", "sourcePaths": ["Classes/Decision.swift"],
            "requiredChecks": ["correctness"], "tests": [{"source": "GitXTests/ContractTests.swift",
            "identifier": "GitXTests/ContractTests/testNormal", "role": "valid", "oracle": "Observe publication"}]}]}
        self.context = Context(self.root)

    def git(self, *arguments):
        return subprocess.check_output(["git", "-C", str(self.root), *arguments], text=True)

    def receipt(self, name="receipt.json", status="passed", result="Passed"):
        bundle = self.root / "artifacts/verification/result.xcresult"
        bundle.mkdir(parents=True, exist_ok=True)
        (bundle / "tests.json").write_text(json.dumps(test_tree(result)))
        derived = self.root / "artifacts/verification/products"
        (derived / "Build/Products/GitX.app").mkdir(parents=True, exist_ok=True)
        (derived / "Build/Products/GitX.app/binary").write_bytes(b"compiled app")
        evidence = {"status": "valid", "inputsBefore": self.context.inputs, "inputsAfter": self.context.inputs,
                    "dependencyProducts": {}, "products": session.product_identity(derived),
                    "results": {str(bundle): session.tree_identity(bundle)}}
        payload = {"schemaVersion": 2, "status": status, "exitCode": 0 if status == "passed" else 65,
                   "finishedAt": "2026-10-09T12:00:00Z", "evidence": evidence,
                   "invocation": {"preset": "test:correctness", "configuration": "Debug",
                                  "coverageGate": "enforced", "arguments": []},
                   "toolchain": {"xcodeVersion": "test", "xcodeBuild": "build"},
                   "buildPaths": {"derivedData": str(derived)},
                   "steps": [{"name": "test:correctness", "status": status, "exitCode": 0 if status == "passed" else 65,
                              "xcresult": str(bundle), "testCounts": {"failed": int(result == "Failed")}},
                             {"name": "coverage", "status": "passed"}]}
        return self.save(name, payload), payload

    def save(self, name, payload):
        path = self.root / "artifacts/verification" / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(payload))
        return path

    def test_checked_in_catalogue_references_real_tests(self):
        contracts, problems = guard.validate_catalogue(json.loads(guard.CATALOGUE.read_text()))
        self.assertGreaterEqual(len(contracts), 15)
        self.assertEqual(problems, [])

    def test_catalogue_errors_are_advisory_and_do_not_accept_broken_references(self):
        for change in ({"id": "../bad"}, {"sourcePaths": ["../outside"]}, {"requiredChecks": None},
                       {"tests": [{"identifier": [], "check": [], "source": "missing"}]}):
            payload = copy.deepcopy(self.catalogue)
            payload["contracts"][0].update(change)
            contracts, findings = guard.validate_catalogue(payload, self.root)
            self.assertEqual(contracts, [])
            self.assertTrue(findings)
        payload = copy.deepcopy(self.catalogue)
        payload["contracts"][0]["tests"][0]["identifier"] += "Missing"
        self.assertEqual(guard.validate_catalogue(payload, self.root)[1][0]["code"], "contract-test-missing")

    def test_lexical_reference_must_belong_to_the_named_class(self):
        source = 'class First { func testOne() {} } class Second { func testTwo() {} }'
        self.assertTrue(guard.contains_test(source, "Second", "testTwo"))
        self.assertFalse(guard.contains_test(source, "First", "testTwo"))
        self.assertFalse(guard.contains_test('class First { class Helper { func testOne() {} } }', "First", "testOne"))
        self.assertFalse(guard.contains_test('class First { /* func testOne() {} */ }', "First", "testOne"))

    def test_objective_c_implementation_reference_keeps_exception_tests_supported(self):
        source = '@implementation First\n- (void)testOne { }\n@end\n@implementation Second\n- (void)testTwo { }\n@end'
        self.assertTrue(guard.contains_test(source, "First", "testOne"))
        self.assertFalse(guard.contains_test(source, "First", "testTwo"))
        self.assertFalse(guard.contains_test('@interface First\n- (void)testOne;\n@end', "First", "testOne"))

    def test_untracked_resource_without_input_provenance_is_advisory_incomplete(self):
        resource = self.root / "Resources/New.xib"
        resource.parent.mkdir()
        resource.write_text("fixture")
        catalogue = self.save("catalogue.json", self.catalogue)
        output = self.root / "artifacts/verification/report.json"
        with mock.patch.object(guard, "ROOT", self.root), mock.patch.object(guard, "CATALOGUE", catalogue):
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(guard.main(["check", "--base", self.base, "--output", str(output)]), 0)
        report = json.loads(output.read_text())
        self.assertEqual(report["status"], "incomplete")
        self.assertTrue(any(f["code"] == "unfingerprinted-source" for f in report["findings"]))

    def test_analyzer_receipt_finish_records_durable_log_and_diagnostic_identities(self):
        path, payload = self.receipt()
        payload.update(runId="unit-analysis", artifacts=[])
        payload["invocation"]["preset"] = "analyze"
        payload["toolchain"]["developerDir"] = "/test/Xcode"
        log = path.parent / "analysis.log"
        log.write_text("Verified analysis")
        diagnostics = path.parent / "Results/Analyzer"
        diagnostics.mkdir(parents=True)
        (diagnostics / "finding.plist").write_text("Retained diagnostic")
        payload["steps"] = [{"name": "analyze", "status": "passed", "exitCode": 0, "log": str(log)}]
        self.save(path.name, payload)
        with mock.patch.object(guard.verification, "ROOT", self.root), mock.patch.object(
                guard.verification, "xcode_version", return_value=self.context.version):
            self.assertEqual(guard.verification.command_receipt_finish(argparse.Namespace(path=path, status="passed", exit_code=0)), 0)
        artifacts = json.loads(path.read_text())["evidence"]["analysisArtifacts"]
        self.assertEqual(artifacts[str(log)], session.tree_identity(log))
        self.assertEqual(artifacts[str(diagnostics)], session.tree_identity(diagnostics))

    def test_git_scope_includes_old_and_new_rename_paths_and_untracked_source(self):
        self.git("mv", "Classes/Decision.swift", "Classes/Renamed.swift")
        (self.root / "Classes/New.swift").write_text("struct New {}")
        identities, paths = guard.changes(self.root, self.base)
        self.assertEqual(identities["base"], self.base)
        self.assertEqual(paths, ["Classes/Decision.swift", "Classes/New.swift", "Classes/Renamed.swift"])
        report = guard.build_report(self.root, self.base, self.catalogue)
        self.assertEqual([c["id"] for c in report["contracts"]], ["STATE-001"])
        self.assertTrue(any(f["code"] == "unmapped-source" for f in report["findings"]))
        self.assertIn("release-test-build", report["requiredChecks"])

    def test_test_source_and_catalogue_changes_select_contracts(self):
        contract = self.catalogue["contracts"][0]
        for path in ("GitXTests/ContractTests.swift", "scripts/regression-contracts.json"):
            self.assertEqual(len(guard.select_contracts([contract], [path])), 1)

    def test_package_changes_require_consumer_verification(self):
        for path, check in (("GitXCore/Sources/New.swift", "core"), ("ForgeKit/Package.swift", "forgekit")):
            requirements = guard.required_checks([path], [])
            self.assertIn(check, requirements)
            self.assertTrue(guard.GENERAL_APP_CHECKS <= set(requirements))

    def test_result_walker_keeps_configuration_skip_and_failing_repetition(self):
        for result, repetitions, expected in [("Skipped", (), "Skipped"), ("Passed", ("Passed", "Failed"), "Failed"),
                                              ("Passed", ("Passed", "Skipped"), "Unknown")]:
            outcomes = guard.collect_test_outcomes(test_tree(result, "Release", repetitions))
            self.assertEqual(outcomes, [{"identifier": "GitXTests/ContractTests/testNormal",
                                        "configuration": "Release", "result": expected}])

    def test_full_current_evidence_can_satisfy_named_test(self):
        path, _ = self.receipt()
        record = guard.inspect_receipt(path, self.context)
        self.assertEqual(record["reasons"], [])
        self.assertEqual(guard.assess_checks(["correctness"], self.catalogue["contracts"], [record])[0], "ready")

    def test_plan_configuration_is_distinct_from_build_configuration(self):
        path, payload = self.receipt()
        bundle = pathlib.Path(payload["steps"][0]["xcresult"])
        (bundle / "tests.json").write_text(json.dumps(test_tree(configuration="Default")))
        payload["evidence"]["results"][str(bundle)] = session.tree_identity(bundle)
        self.save(path.name, payload)
        record = guard.inspect_receipt(path, self.context)
        self.assertEqual(record["tests"][0]["planConfiguration"], "Default")
        self.assertEqual(record["tests"][0]["configuration"], "Debug")
        self.assertEqual(guard.assess_checks(["correctness"], self.catalogue["contracts"], [record])[0], "ready")

    def test_analyzer_cleanup_uses_durable_diagnostics_but_replaced_logs_are_invalid(self):
        path, payload = self.receipt()
        payload["invocation"]["preset"] = "analyze"
        payload["buildPaths"]["derivedData"] = str(path.parent / "AnalyzerDerivedData.removed")
        payload["evidence"]["products"] = {"temporary.app": "deleted intentionally"}
        payload["steps"] = []
        payload["evidence"]["analysisArtifacts"] = {}
        for name in ("analyze", "analyzer-policy", "swiftlint-analyze"):
            log = path.parent / (name + ".log")
            log.write_text("Diagnostic output")
            payload["steps"].append({"name": name, "status": "passed", "log": str(log)})
            payload["evidence"]["analysisArtifacts"][str(log)] = session.tree_identity(log)
        self.save(path.name, payload)
        self.assertEqual(guard.inspect_receipt(path, self.context)["reasons"], [])
        log.write_text("Replaced output")
        self.assertEqual(guard.inspect_receipt(path, self.context)["validity"], "invalid")

    def test_static_workflow_resource_collision_is_blocked(self):
        payload = {"schemaVersion": 2, "profile": "full", "status": "failed",
                   "updatedAt": "2026-10-09T12:00:00Z", "inputsBefore": self.context.inputs,
                   "inputsAfter": self.context.inputs, "steps": [{"name": "static", "status": "failed", "exitCode": 75,
                   "command": dict(guard.dev_workflow.full_profile(self.root))["static"], "evidenceStatus": "valid",
                   "inputsBefore": self.context.inputs, "inputsAfter": self.context.inputs, "toolchain": self.context.toolchain}]}
        record = guard.inspect_workflow(self.root / "workflow.json", payload, self.context)[0]
        self.assertEqual(record["reasons"], [])
        self.assertEqual(guard.assess_checks(["static"], [], [record])[0], "blocked")

    def test_changed_head_source_dependencies_plans_and_checkout_are_invalid(self):
        for key in ("head", "source", "dependencies", "plans", "root"):
            path, payload = self.receipt()
            payload["evidence"]["inputsAfter"] = dict(self.context.inputs, **{key: "different"})
            self.save(path.name, payload)
            record = guard.inspect_receipt(path, self.context)
            self.assertEqual(record["validity"], "invalid", key)

    def test_changed_products_and_result_bundle_are_invalid(self):
        path, payload = self.receipt()
        (path.parent / "products/Build/Products/GitX.app/binary").write_bytes(b"replaced")
        self.assertIn("Build products are missing or changed", guard.inspect_receipt(path, self.context)["reasons"])
        (path.parent / "result.xcresult/tests.json").write_text(json.dumps(test_tree("Skipped")))
        record = guard.inspect_receipt(path, self.context)
        self.assertTrue(any("Result artifact" in reason for reason in record["reasons"]))

    def test_historical_toolchain_and_schema_cannot_satisfy_completion(self):
        path, payload = self.receipt()
        payload["schemaVersion"] = 1
        payload["toolchain"]["xcodeBuild"] = "old"
        self.save(path.name, payload)
        record = guard.inspect_receipt(path, self.context)
        self.assertIn("Historical receipt schema", record["reasons"])
        self.assertTrue(any("Toolchain" in reason for reason in record["reasons"]))

    def test_focused_and_uncovered_correctness_never_satisfy_full_correctness(self):
        for invocation_change in ({"arguments": ["-only-testing:GitXTests/ContractTests"]}, {"coverageGate": "skipped"}):
            path, payload = self.receipt()
            payload["invocation"].update(invocation_change)
            self.save(path.name, payload)
            record = guard.inspect_receipt(path, self.context)
            self.assertEqual(record["validity"], "invalid")
            self.assertEqual(guard.assess_checks(["correctness"], self.catalogue["contracts"], [record])[0], "incomplete")

    def test_missing_skipped_and_release_only_execution_cannot_prove_debug_test(self):
        for tests in ([], [{"identifier": "GitXTests/ContractTests/testNormal", "configuration": "Debug", "result": "Skipped"}],
                      [{"identifier": "GitXTests/ContractTests/testNormal", "configuration": "Release", "result": "Passed"}]):
            record = {"check": "correctness", "validity": "valid", "status": "passed", "finishedAt": "2026-10-09T12:00:00Z", "receipt": "run", "tests": tests}
            self.assertEqual(guard.assess_checks(["correctness"], self.catalogue["contracts"], [record])[0], "incomplete")

    def test_latest_failure_wins_independent_of_receipt_order(self):
        first = {"check": "correctness", "validity": "valid", "status": "passed", "finishedAt": "2026-10-09T12:00:00Z", "receipt": "first", "tests": []}
        later = dict(first, status="failed", finishedAt="2026-10-09T13:00:00Z", receipt="later")
        for records in ([first, later], [later, first]):
            self.assertEqual(guard.assess_checks(["correctness"], [], records)[0], "failed")

    def test_real_assertions_remain_failed_even_with_infrastructure_category(self):
        path, payload = self.receipt(status="failed", result="Failed")
        payload["steps"][0]["failureCategory"] = "test-infrastructure"
        self.save(path.name, payload)
        record = guard.inspect_receipt(path, self.context)
        self.assertEqual(record["status"], "failed")
        self.assertEqual(guard.assess_checks(["correctness"], [], [record])[0], "failed")

    def test_infrastructure_blocker_is_distinct_from_missing_evidence(self):
        path, payload = self.receipt(status="failed", result="Skipped")
        payload["steps"][0]["failureCategory"] = "unknown-host-startup-timeout"
        self.save(path.name, payload)
        record = guard.inspect_receipt(path, self.context)
        self.assertEqual(record["status"], "blocked")
        self.assertEqual(guard.assess_checks(["correctness"], [], [record])[0], "blocked")
        self.assertEqual(guard.assess_checks(["correctness"], [], [])[0], "incomplete")

    def test_blocked_doctor_step_is_not_reported_as_a_product_failure(self):
        path, payload = self.receipt(status="failed", result="Skipped")
        payload["steps"] = [{"name": "doctor", "status": "blocked", "failureCategory": "command"}]
        self.save(path.name, payload)
        self.assertEqual(guard.inspect_receipt(path, self.context)["status"], "blocked")

    def test_workflow_cannot_relabel_a_wrong_child_receipt_as_a_pass(self):
        path, payload = self.receipt()
        workflow = {"schemaVersion": 2, "profile": "full", "status": "passed", "evidenceStatus": "valid",
                    "finishedAt": payload["finishedAt"], "inputsBefore": self.context.inputs, "inputsAfter": self.context.inputs,
                    "steps": [{"name": "release-test-build", "command": dict(guard.dev_workflow.full_profile(self.root))["release-test-build"],
                               "status": "passed", "exitCode": 0, "evidenceStatus": "valid", "inputsBefore": self.context.inputs,
                               "inputsAfter": self.context.inputs, "toolchain": self.context.toolchain, "receipt": str(path)}]}
        record = guard.inspect_workflow(path, workflow, self.context)[0]
        self.assertIn("Child receipt does not match its workflow check", record["reasons"])
        self.assertEqual(record["validity"], "invalid")

    def test_malformed_receipt_is_visible_and_does_not_crash_batch(self):
        path = self.save("broken.json", ["not an object"])
        records = guard.inspect_evidence([path, self.root / "absent.json"], self.context)
        self.assertEqual(len(records), 2)
        self.assertTrue(all(r["validity"] == "invalid" for r in records))

    def test_cli_findings_exit_zero_and_bad_base_is_operational_error(self):
        catalogue = self.save("catalogue.json", self.catalogue)
        output = self.root / "artifacts/verification/report.json"
        with mock.patch.object(guard, "ROOT", self.root), mock.patch.object(guard, "CATALOGUE", catalogue):
            with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(guard.main(["assess", "--base", self.base, "--output", str(output)]), 0)
                self.assertEqual(guard.main(["check", "--base", "missing-base"]), 2)
                catalogue.write_text("{malformed")
                self.assertEqual(guard.main(["check", "--base", self.base, "--output", str(output)]), 0)
        self.assertEqual(json.loads(output.read_text())["findings"][0]["code"], "catalogue-invalid")

    def test_cli_never_overwrites_existing_verification_evidence(self):
        catalogue = self.save("catalogue.json", self.catalogue)
        receipt, _ = self.receipt()
        before = receipt.read_bytes()
        with mock.patch.object(guard, "ROOT", self.root), mock.patch.object(guard, "CATALOGUE", catalogue):
            with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(guard.main(["check", "--base", self.base, "--output", str(receipt)]), 2)
        self.assertEqual(receipt.read_bytes(), before)


if __name__ == "__main__":
    unittest.main()
