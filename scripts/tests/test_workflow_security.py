from __future__ import annotations

import unittest

from support import ROOT, load_script


PIN = "0123456789abcdef0123456789abcdef01234567"


class WorkflowSecurityTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.module = load_script("check_workflow_security.py")

    def test_accepts_hosted_pull_request_with_minimal_permissions(self) -> None:
        workflow = f"""
name: verify
on:
  pull_request:
permissions:
  contents: read
jobs:
  test:
    runs-on: macos-26
    steps:
      - uses: actions/checkout@{PIN}
        with:
          persist-credentials: false
"""

        self.assertEqual(self.module.check_workflow(workflow), [])

    def test_accepts_explicitly_trusted_self_hosted_job(self) -> None:
        workflow = f"""
name: verify
on:
  pull_request:
  schedule:
    - cron: '0 0 * * *'
permissions: {{}}
jobs:
  sanitizer:
    if: github.event_name == 'schedule' || github.event_name == 'workflow_dispatch'
    runs-on: [self-hosted, macOS, ARM64]
    steps:
      - uses: actions/checkout@{PIN}
        with:
          persist-credentials: false
"""

        self.assertEqual(self.module.check_workflow(workflow), [])

    def test_rejects_untrusted_self_hosted_pull_request_job(self) -> None:
        workflow = f"""
name: verify
on:
  pull_request:
permissions: {{}}
jobs:
  test:
    runs-on: [self-hosted, macOS, ARM64]
    steps:
      - uses: actions/checkout@{PIN}
        with:
          persist-credentials: false
"""

        failures = self.module.check_workflow(workflow)

        self.assertTrue(any("untrusted self-hosted" in failure for failure in failures))

    def test_rejects_implicit_permissions_mutable_actions_and_credentials(self) -> None:
        workflow = """
name: verify
on:
  push:
jobs:
  test:
    runs-on: macos-26
    steps:
      - uses: actions/checkout@v7
"""

        failures = self.module.check_workflow(workflow)

        self.assertTrue(any("permissions" in failure for failure in failures))
        self.assertTrue(any("full commit SHA" in failure for failure in failures))
        self.assertTrue(any("persists Git credentials" in failure for failure in failures))

    def test_repository_workflows_satisfy_security_policy(self) -> None:
        workflow_paths = sorted((ROOT / ".github" / "workflows").glob("*.yml"))

        self.assertEqual(self.module.check_paths(workflow_paths), [])


if __name__ == "__main__":
    unittest.main()
