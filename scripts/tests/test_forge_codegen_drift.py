from __future__ import annotations

import os
import pathlib
import shutil
import subprocess
import tarfile
import tempfile
import unittest
from unittest import mock

from support import load_script


checker = load_script("check_forge_codegen_drift.py")


def write(root: pathlib.Path, relative: str, contents: str) -> pathlib.Path:
    path = root / relative
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(contents)
    return path


def prepare_repository(root: pathlib.Path, generator_body: str) -> None:
    write(root, str(checker.SCHEMA), "type Query { viewer: String }\n")
    write(root, str(checker.CONFIG), "{}\n")
    write(
        root,
        str(checker.GENERATED_ROOT / "Schema.swift"),
        "struct Schema {}\n",
    )
    generator = write(
        root,
        str(checker.GENERATOR),
        "#!/bin/bash\nset -euo pipefail\n# Apollo 2.3.0\n" + generator_body,
    )
    generator.chmod(generator.stat().st_mode | 0o111)
    updater = write(
        root,
        str(checker.UPDATER),
        "#!/bin/bash\n"
        "set -euo pipefail\n"
        "# gh auth status; gh api; application/vnd.github.v4.idl\n"
        "exit 0\n",
    )
    updater.chmod(updater.stat().st_mode | 0o111)
    shutil.copytree(
        checker.ROOT / checker.OPERATIONS_ROOT,
        root / checker.OPERATIONS_ROOT,
    )


class ForgeCodegenDriftTests(unittest.TestCase):
    def test_all_absent_without_graphql_usage_is_not_applicable(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            (root / "ForgeKit").mkdir()

            failures = checker.codegen_drift_failures(root)
            applicable = checker.codegen_is_applicable(root)

        self.assertFalse(applicable)
        self.assertEqual(failures, [])

    def test_dependency_scaffold_comments_do_not_count_as_codegen_usage(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            write(
                root,
                "ForgeKit/Sources/GitHubForgeAdapter/Metadata.swift",
                "// Apollo GraphQL operations arrive in Milestone 1.\n"
                "public enum Metadata {}\n",
            )

            failures = checker.codegen_drift_failures(root)

        self.assertEqual(failures, [])

    def test_partial_codegen_infrastructure_fails_closed(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            write(root, str(checker.SCHEMA), "type Query { viewer: String }\n")

            failures = checker.codegen_drift_failures(root)

        self.assertEqual(len(failures), 5)
        self.assertTrue(any("apollo-codegen-config.json" in failure for failure in failures))
        self.assertTrue(any("generate_graphql.sh" in failure for failure in failures))
        self.assertTrue(any("update_github_graphql.sh" in failure for failure in failures))
        self.assertTrue(any("operations directory" in failure for failure in failures))
        self.assertTrue(any("generated source directory" in failure for failure in failures))

    def test_apollo_usage_without_codegen_infrastructure_fails_closed(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            write(
                root,
                "ForgeKit/Sources/GitHubForgeAdapter/Client.swift",
                "import Apollo\nstruct Client {}\n",
            )

            failures = checker.codegen_drift_failures(root)

        self.assertEqual(len(failures), 7)
        self.assertTrue(any("schema.graphqls" in failure for failure in failures))
        self.assertTrue(any("apollo-codegen-config.json" in failure for failure in failures))
        self.assertTrue(any("generate_graphql.sh" in failure for failure in failures))
        self.assertTrue(any("update_github_graphql.sh" in failure for failure in failures))
        self.assertTrue(any("operations directory" in failure for failure in failures))
        self.assertTrue(any("Apollo/GraphQL usage" in failure for failure in failures))

    def test_generator_must_be_executable(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            prepare_repository(root, "exit 0\n")
            generator = root / pathlib.Path(checker.GENERATOR)
            generator.chmod(0o644)

            failures = checker.codegen_drift_failures(root)

        self.assertEqual(len(failures), 1)
        self.assertIn("not executable", failures[0])

    def test_authenticated_updater_must_be_executable(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            prepare_repository(root, "exit 0\n")
            updater = root / pathlib.Path(checker.UPDATER)
            updater.chmod(0o644)

            failures = checker.codegen_drift_failures(root)

        self.assertEqual(len(failures), 1)
        self.assertIn("not executable", failures[0])

    def test_mutation_operation_is_rejected_from_milestone_one(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            prepare_repository(root, "exit 0\n")
            write(
                root,
                str(checker.OPERATIONS_ROOT / "Forbidden.graphql"),
                "mutation GitHubForbiddenWrite { viewer { login } }\n",
            )

            failures = checker.operation_policy_failures(root)

        self.assertEqual(len(failures), 1)
        self.assertIn("must be read-only", failures[0])

    def test_missing_required_read_operation_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            prepare_repository(root, "exit 0\n")
            missing = root / checker.OPERATIONS_ROOT / "HistoryOverlay.graphql"
            missing.unlink()

            failures = checker.operation_policy_failures(root)

        self.assertEqual(failures, [
            "missing required Milestone 1 GraphQL read operation: GitHubHistoryOverlay"
        ])

    def test_attention_cannot_use_github_notifications(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            prepare_repository(root, "exit 0\n")
            write(
                root,
                str(checker.OPERATIONS_ROOT / "Fragments" / "Forbidden.graphql"),
                "fragment GitHubLeak on User { notification: login }\n",
            )

            failures = checker.operation_policy_failures(root)

        self.assertEqual(len(failures), 1)
        self.assertIn("without GitHub Notifications", failures[0])

    def test_paginated_reads_require_cursor_and_completeness_markers(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            prepare_repository(root, "exit 0\n")
            write(
                root,
                str(checker.OPERATIONS_ROOT / "HistoryOverlay.graphql"),
                "query GitHubHistoryOverlay { viewer { login } }\n",
            )

            failures = checker.operation_policy_failures(root)

        self.assertEqual(len(failures), 3)
        self.assertTrue(any("page-size" in failure for failure in failures))
        self.assertTrue(any("page-cursor" in failure for failure in failures))
        self.assertTrue(any("completeness" in failure for failure in failures))

    def test_nested_connection_requires_its_own_completeness_markers(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            prepare_repository(root, "exit 0\n")
            operation = root / checker.OPERATIONS_ROOT / "AttentionCandidates.graphql"
            source = operation.read_text()
            original = (
                "            comments(last: $activityLast) {\n"
                "              totalCount\n"
                "              pageInfo {"
            )
            self.assertIn(original, source)
            operation.write_text(
                source.replace(
                    original,
                    "            comments(last: $activityLast) {\n"
                    "              pageInfo {",
                    1,
                )
            )

            failures = checker.connection_policy_failures(root)

        self.assertEqual(len(failures), 1)
        self.assertIn("comments connection occurrence 2", failures[0])
        self.assertIn("totalCount", failures[0])

    def test_summary_fragment_connection_requires_its_own_markers(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            prepare_repository(root, "exit 0\n")
            summaries = root / checker.OPERATIONS_ROOT / "Fragments/Summaries.graphql"
            source = summaries.read_text()
            original = (
                "  labels(first: 100) {\n"
                "    totalCount\n"
                "    pageInfo {\n"
                "      ...GitHubPageInfo\n"
                "    }"
            )
            self.assertEqual(source.count(original), 2)
            summaries.write_text(
                source.replace(
                    original,
                    "  labels(first: 100) {\n"
                    "    totalCount",
                    1,
                )
            )

            failures = checker.connection_policy_failures(root)

        self.assertEqual(len(failures), 1)
        self.assertIn("GitHubPullRequestSummary labels connection", failures[0])
        self.assertIn("pageInfo", failures[0])

    def test_repository_topics_connection_requires_completeness_markers(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            prepare_repository(root, "exit 0\n")
            facts = root / checker.OPERATIONS_ROOT / "RepositoryFacts.graphql"
            source = facts.read_text()
            self.assertIn("    repositoryTopics(first: 100) {\n      totalCount\n", source)
            facts.write_text(
                source.replace(
                    "    repositoryTopics(first: 100) {\n      totalCount\n",
                    "    repositoryTopics(first: 100) {\n",
                    1,
                )
            )

            failures = checker.connection_policy_failures(root)

        self.assertEqual(len(failures), 1)
        self.assertIn("GitHubRepositoryFacts repositoryTopics connection", failures[0])
        self.assertIn("totalCount", failures[0])

    def test_page_info_fragment_requires_both_direction_markers(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            prepare_repository(root, "exit 0\n")
            common = root / checker.OPERATIONS_ROOT / "Fragments/Common.graphql"
            source = common.read_text()
            self.assertIn("  endCursor\n", source)
            common.write_text(source.replace("  endCursor\n", "", 1))

            failures = checker.connection_policy_failures(root)

        self.assertEqual(len(failures), 1)
        self.assertIn("GitHubPageInfo is missing endCursor", failures[0])

    def test_offline_generator_cannot_fetch_schema_or_use_network(self) -> None:
        for command in (
            "curl https://example.com/schema\n",
            "wget https://example.com/schema\n",
            "python3 -c 'import urllib.request'\n",
        ):
            with self.subTest(command=command), tempfile.TemporaryDirectory() as directory:
                root = pathlib.Path(directory)
                prepare_repository(root, command)

                failures = checker.tooling_policy_failures(root)

            self.assertEqual(len(failures), 1)
            self.assertIn("network command", failures[0])

    def test_schema_updater_cannot_handle_token_material_directly(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            prepare_repository(root, "exit 0\n")
            write(
                root,
                str(checker.UPDATER),
                "#!/bin/bash\n"
                "# gh auth status; gh api; application/vnd.github.v4.idl\n"
                "gh auth token > token.txt\n",
            )

            failures = checker.tooling_policy_failures(root)

        self.assertEqual(len(failures), 1)
        self.assertIn("token material", failures[0])

    def test_schema_updater_cannot_display_token_or_enable_shell_tracing(self) -> None:
        for unsafe_command in (
            "gh auth status --hostname github.com --show-token\n",
            "set -x\n",
            "set -o xtrace\n",
        ):
            with (
                self.subTest(command=unsafe_command),
                tempfile.TemporaryDirectory() as directory,
            ):
                root = pathlib.Path(directory)
                prepare_repository(root, "exit 0\n")
                write(
                    root,
                    str(checker.UPDATER),
                    "#!/bin/bash\n"
                    "# gh auth status; gh api; application/vnd.github.v4.idl\n"
                    + unsafe_command,
                )

                failures = checker.tooling_policy_failures(root)

            self.assertEqual(len(failures), 1)
            self.assertIn("token material", failures[0])

    def test_unchanged_offline_generation_passes(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            prepare_repository(
                root,
                '[[ "$1" == "--offline" ]]\n'
                '[[ "${GITX_FORGE_CODEGEN_OFFLINE:-}" == "1" ]]\n',
            )

            failures = checker.codegen_drift_failures(root)

        self.assertEqual(failures, [])

    def test_isolated_codegen_uses_absolute_repository_archive_cli_fallback(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            prepare_repository(
                root,
                '[[ "${APOLLO_IOS_CLI:-}" == /* ]]\n'
                '[[ "$("$APOLLO_IOS_CLI" --version)" == "2.3.0" ]]\n',
            )
            archived_cli = write(
                root,
                "archive-source/apollo-ios-cli",
                "#!/bin/bash\nprintf '2.3.0\\n'\n",
            )
            archived_cli.chmod(archived_cli.stat().st_mode | 0o111)
            archive = (
                root
                / "ForgeKit/.build/checkouts/apollo-ios/CLI/apollo-ios-cli.tar.gz"
            )
            archive.parent.mkdir(parents=True, exist_ok=True)
            with tarfile.open(archive, "w:gz") as tar:
                tar.add(archived_cli, arcname="apollo-ios-cli")

            with mock.patch.dict(os.environ, {"APOLLO_IOS_CLI": ""}):
                failures = checker.codegen_drift_failures(root)

        self.assertEqual(failures, [])

    def test_changed_generated_source_is_reported(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            prepare_repository(
                root,
                'printf "struct Schema { let changed: Bool }\\n" '
                '> ForgeKit/Sources/GitHubForgeAdapter/Generated/Schema.swift\n',
            )
            generated = root / checker.GENERATED_ROOT / "Schema.swift"
            original = generated.read_text()

            failures = checker.codegen_drift_failures(root)
            restored = generated.read_text()

        self.assertEqual(len(failures), 1)
        self.assertIn("changed after codegen", failures[0])
        self.assertEqual(restored, original)

    def test_generator_failure_is_reported(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            prepare_repository(
                root,
                'printf "partial output\\n" '
                '> ForgeKit/Sources/GitHubForgeAdapter/Generated/Schema.swift\n'
                'echo "offline cache unavailable" >&2\n'
                'exit 7\n',
            )
            generated = root / checker.GENERATED_ROOT / "Schema.swift"
            original = generated.read_text()

            failures = checker.codegen_drift_failures(root)
            restored = generated.read_text()

        self.assertEqual(len(failures), 1)
        self.assertIn("status 7", failures[0])
        self.assertIn("offline cache unavailable", failures[0])
        self.assertEqual(restored, original)

    def test_transactional_generator_failure_preserves_checked_in_output(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            generator = write(
                root,
                str(checker.GENERATOR),
                (checker.ROOT / checker.GENERATOR).read_text(),
            )
            generator.chmod(generator.stat().st_mode | 0o111)
            write(
                root,
                str(checker.CONFIG),
                '{"output":{"schemaTypes":{"path":"Generated"}}}\n',
            )
            generated = write(
                root,
                str(checker.GENERATED_ROOT / "Sentinel.swift"),
                "struct Sentinel {}\n",
            )
            fake_cli = write(
                root,
                "fake-apollo-ios-cli",
                "#!/bin/bash\n"
                "if [[ \"$1\" == \"--version\" ]]; then\n"
                "  printf '2.3.0\\n'\n"
                "  exit 0\n"
                "fi\n"
                "exit 7\n",
            )
            fake_cli.chmod(fake_cli.stat().st_mode | 0o111)
            environment = os.environ.copy()
            environment["APOLLO_IOS_CLI"] = str(fake_cli)

            result = subprocess.run(
                [str(generator), "--offline"],
                cwd=root,
                env=environment,
                capture_output=True,
                text=True,
                check=False,
            )

            self.assertEqual(result.returncode, 7)
            self.assertEqual(generated.read_text(), "struct Sentinel {}\n")

    def test_generator_recovers_backup_left_by_interrupted_swap(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            generator = write(
                root,
                str(checker.GENERATOR),
                (checker.ROOT / checker.GENERATOR).read_text(),
            )
            generator.chmod(generator.stat().st_mode | 0o111)
            write(
                root,
                str(checker.CONFIG),
                '{"output":{"schemaTypes":{"path":"Generated"}}}\n',
            )
            interrupted_backup = (
                root
                / checker.GENERATED_ROOT.parent
                / ".graphql-backup.interrupted"
                / "Generated"
            )
            sentinel = write(
                interrupted_backup,
                "Sentinel.swift",
                "struct Sentinel {}\n",
            )
            fake_cli = write(
                root,
                "fake-apollo-ios-cli",
                "#!/bin/bash\n"
                "if [[ \"$1\" == \"--version\" ]]; then\n"
                "  printf '2.3.0\\n'\n"
                "  exit 0\n"
                "fi\n"
                "exit 7\n",
            )
            fake_cli.chmod(fake_cli.stat().st_mode | 0o111)
            environment = os.environ.copy()
            environment["APOLLO_IOS_CLI"] = str(fake_cli)

            result = subprocess.run(
                [str(generator), "--offline"],
                cwd=root,
                env=environment,
                capture_output=True,
                text=True,
                check=False,
            )

            recovered = root / checker.GENERATED_ROOT / sentinel.name
            self.assertEqual(result.returncode, 7)
            self.assertEqual(recovered.read_text(), "struct Sentinel {}\n")
            self.assertFalse(interrupted_backup.parent.exists())
            self.assertIn("Recovered generated GraphQL sources", result.stderr)

    def test_schema_refresh_recovers_one_complete_hard_interruption_backup(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            updater = write(
                root,
                str(checker.UPDATER),
                (checker.ROOT / checker.UPDATER).read_text(),
            )
            updater.chmod(updater.stat().st_mode | 0o111)
            schema = write(
                root,
                str(checker.SCHEMA),
                "type Query { interruptedNewField: String }\n",
            )
            generated_root = root / checker.GENERATED_ROOT
            write(generated_root, "NewOnly.swift", "struct NewOnly {}\n")
            backup = root / "ForgeKit/.github-schema-backup.interrupted"
            write(
                backup,
                "schema.graphqls",
                "type Query { priorField: String }\n",
            )
            write(
                backup / "Generated",
                "Prior.swift",
                "struct Prior {}\n",
            )
            environment = os.environ.copy()
            environment["PATH"] = "/usr/bin:/bin"

            result = subprocess.run(
                [str(updater)],
                cwd=root,
                env=environment,
                capture_output=True,
                text=True,
                check=False,
            )

            self.assertEqual(result.returncode, 69)
            self.assertEqual(schema.read_text(), "type Query { priorField: String }\n")
            self.assertEqual(
                (generated_root / "Prior.swift").read_text(),
                "struct Prior {}\n",
            )
            self.assertFalse((generated_root / "NewOnly.swift").exists())
            self.assertFalse(backup.exists())
            self.assertIn("Recovered schema and generated sources", result.stderr)

    def test_schema_refresh_refuses_ambiguous_hard_interruption_backups(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            updater = write(
                root,
                str(checker.UPDATER),
                (checker.ROOT / checker.UPDATER).read_text(),
            )
            updater.chmod(updater.stat().st_mode | 0o111)
            schema = write(
                root,
                str(checker.SCHEMA),
                "type Query { currentField: String }\n",
            )
            generated = write(
                root,
                str(checker.GENERATED_ROOT / "Current.swift"),
                "struct Current {}\n",
            )
            for suffix in ("first", "second"):
                backup = root / f"ForgeKit/.github-schema-backup.{suffix}"
                write(
                    backup,
                    "schema.graphqls",
                    f"type Query {{ {suffix}Field: String }}\n",
                )
                write(
                    backup / "Generated",
                    f"{suffix.title()}.swift",
                    f"struct {suffix.title()} {{}}\n",
                )
            environment = os.environ.copy()
            environment["PATH"] = "/usr/bin:/bin"

            result = subprocess.run(
                [str(updater)],
                cwd=root,
                env=environment,
                capture_output=True,
                text=True,
                check=False,
            )

            self.assertEqual(result.returncode, 74)
            self.assertEqual(schema.read_text(), "type Query { currentField: String }\n")
            self.assertEqual(generated.read_text(), "struct Current {}\n")
            self.assertEqual(
                len(list((root / "ForgeKit").glob(".github-schema-backup.*"))),
                2,
            )
            self.assertIn("Expected exactly one backup; found 2", result.stderr)

    def test_schema_refresh_refuses_incomplete_hard_interruption_backup(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            updater = write(
                root,
                str(checker.UPDATER),
                (checker.ROOT / checker.UPDATER).read_text(),
            )
            updater.chmod(updater.stat().st_mode | 0o111)
            schema = write(
                root,
                str(checker.SCHEMA),
                "type Query { currentField: String }\n",
            )
            generated = write(
                root,
                str(checker.GENERATED_ROOT / "Current.swift"),
                "struct Current {}\n",
            )
            backup = root / "ForgeKit/.github-schema-backup.incomplete"
            write(
                backup,
                "schema.graphqls",
                "type Query { priorField: String }\n",
            )
            environment = os.environ.copy()
            environment["PATH"] = "/usr/bin:/bin"

            result = subprocess.run(
                [str(updater)],
                cwd=root,
                env=environment,
                capture_output=True,
                text=True,
                check=False,
            )

            self.assertEqual(result.returncode, 74)
            self.assertEqual(schema.read_text(), "type Query { currentField: String }\n")
            self.assertEqual(generated.read_text(), "struct Current {}\n")
            self.assertTrue(backup.exists())
            self.assertIn("Backup is incomplete", result.stderr)

    def test_schema_refresh_failure_rolls_back_schema_and_generated_sources(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            updater = write(
                root,
                str(checker.UPDATER),
                (checker.ROOT / checker.UPDATER).read_text(),
            )
            updater.chmod(updater.stat().st_mode | 0o111)
            original_schema = "type Query { oldField: String }\n"
            schema = write(root, str(checker.SCHEMA), original_schema)
            original_generated = "struct Original {}\n"
            generated = write(
                root,
                str(checker.GENERATED_ROOT / "Sentinel.swift"),
                original_generated,
            )
            generator = write(
                root,
                str(checker.GENERATOR),
                "#!/bin/bash\n"
                "printf 'struct Partial {}\\n' > "
                "ForgeKit/Sources/GitHubForgeAdapter/Generated/Sentinel.swift\n"
                "printf 'partial\\n' > "
                "ForgeKit/Sources/GitHubForgeAdapter/Generated/Partial.swift\n"
                "exit 7\n",
            )
            generator.chmod(generator.stat().st_mode | 0o111)
            executable_directory = root / "bin"
            fake_gh = write(
                executable_directory,
                "gh",
                "#!/bin/bash\n"
                "if [[ \"$1\" == \"auth\" ]]; then\n"
                "  exit 0\n"
                "fi\n"
                "if [[ \"$1\" == \"api\" ]]; then\n"
                "  printf 'type Query { newField: String }\\n'\n"
                "  exit 0\n"
                "fi\n"
                "exit 64\n",
            )
            fake_gh.chmod(fake_gh.stat().st_mode | 0o111)
            environment = os.environ.copy()
            environment["PATH"] = f"{executable_directory}:{environment['PATH']}"

            result = subprocess.run(
                [str(updater)],
                cwd=root,
                env=environment,
                capture_output=True,
                text=True,
                check=False,
            )

            self.assertEqual(result.returncode, 7)
            self.assertEqual(schema.read_text(), original_schema)
            self.assertEqual(generated.read_text(), original_generated)
            self.assertFalse((generated.parent / "Partial.swift").exists())
            self.assertEqual(list((root / "ForgeKit").glob(".github-schema-backup.*")), [])


if __name__ == "__main__":
    unittest.main()
