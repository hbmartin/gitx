from __future__ import annotations

import os
import pathlib
import tempfile
import unittest

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
        "#!/bin/bash\nset -euo pipefail\n" + generator_body,
    )
    generator.chmod(generator.stat().st_mode | 0o111)


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

        self.assertEqual(len(failures), 3)
        self.assertTrue(any("apollo-codegen-config.json" in failure for failure in failures))
        self.assertTrue(any("generate_graphql.sh" in failure for failure in failures))
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

        self.assertEqual(len(failures), 5)
        self.assertTrue(any("schema.graphqls" in failure for failure in failures))
        self.assertTrue(any("apollo-codegen-config.json" in failure for failure in failures))
        self.assertTrue(any("generate_graphql.sh" in failure for failure in failures))
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

    def test_changed_generated_source_is_reported(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            prepare_repository(
                root,
                'printf "struct Schema { let changed: Bool }\\n" '
                '> ForgeKit/Sources/GitHubForgeAdapter/Generated/Schema.swift\n',
            )

            failures = checker.codegen_drift_failures(root)

        self.assertEqual(len(failures), 1)
        self.assertIn("changed after codegen", failures[0])

    def test_generator_failure_is_reported(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            prepare_repository(root, 'echo "offline cache unavailable" >&2\nexit 7\n')

            failures = checker.codegen_drift_failures(root)

        self.assertEqual(len(failures), 1)
        self.assertIn("status 7", failures[0])
        self.assertIn("offline cache unavailable", failures[0])


if __name__ == "__main__":
    unittest.main()
