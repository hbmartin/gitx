from __future__ import annotations

import pathlib
import tempfile
import unittest

from support import load_script


boundary = load_script("check_forgekit_boundary.py")
exports = load_script("check_forgekit_exports.py")


def write(root: pathlib.Path, relative: str, contents: str) -> pathlib.Path:
    path = root / relative
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(contents)
    return path


class ForgeKitBoundaryTests(unittest.TestCase):
    def test_apollo_imports_are_allowed_only_inside_the_adapter(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            write(
                root,
                "ForgeKit/Sources/GitHubForgeAdapter/Client.swift",
                "@testable import Apollo\n",
            )
            write(
                root,
                "ForgeKit/Sources/ForgeKit/Identity.swift",
                "@preconcurrency import ApolloAPI\n",
            )

            failures = boundary.boundary_failures(root)

        self.assertEqual(len(failures), 1)
        self.assertIn("Identity.swift", failures[0])
        self.assertIn("ApolloAPI", failures[0])

    def test_swiftpm_build_dependencies_are_not_first_party_sources(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            write(
                root,
                "ForgeKit/.build/checkouts/apollo-ios/Sources/Apollo/Client.swift",
                "import ApolloAPI\n",
            )

            failures = boundary.boundary_failures(root)

        self.assertEqual(failures, [])

    def test_scoped_apollo_import_cannot_bypass_the_boundary(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            write(
                root,
                "Classes/ScopedImport.swift",
                "import class Apollo.ApolloClient\n",
            )

            failures = boundary.boundary_failures(root)

        self.assertEqual(len(failures), 1)
        self.assertIn("imports Apollo", failures[0])

    def test_generated_symbols_and_locations_cannot_escape_the_adapter(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            write(
                root,
                "ForgeKit/Sources/GitHubForgeAdapter/Generated/RepositoryQuery.swift",
                "struct RepositoryQuery {}\n",
            )
            write(
                root,
                "ForgeKit/Sources/GitHubForgeAdapter/Mapper.swift",
                "func map(_ query: RepositoryQuery) {}\n",
            )
            write(
                root,
                "Classes/Leaky.swift",
                "let query: RepositoryQuery? = nil\n",
            )
            write(
                root,
                "GitXTests/LeakyPath.swift",
                'let path = "GitHubForgeAdapter/Generated/RepositoryQuery.swift"\n',
            )

            failures = boundary.boundary_failures(root)

        self.assertEqual(len(failures), 3)
        self.assertTrue(any("Leaky.swift" in failure for failure in failures))
        self.assertTrue(any("LeakyPath.swift" in failure for failure in failures))

    def test_generated_declarations_must_not_be_exported(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            write(
                root,
                "ForgeKit/Sources/GitHubForgeAdapter/Generated/RepositoryQuery.swift",
                "public struct RepositoryQuery {}\n",
            )

            failures = exports.export_failures(root)

        self.assertEqual(len(failures), 1)
        self.assertIn("must remain internal", failures[0])

    def test_handwritten_export_cannot_expose_apollo_or_generated_types(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            write(
                root,
                "ForgeKit/Sources/GitHubForgeAdapter/Generated/RepositoryQuery.swift",
                "struct RepositoryQuery {}\n",
            )
            write(
                root,
                "ForgeKit/Sources/GitHubForgeAdapter/Client.swift",
                """
                public func safeValue() -> String { "safe" }
                public func rawClient() -> ApolloClient { fatalError() }
                public func query(
                    _ value: RepositoryQuery
                ) -> String { "unsafe" }
                """,
            )

            failures = exports.export_failures(root)

        self.assertEqual(len(failures), 2)
        self.assertTrue(any("ApolloClient" in failure for failure in failures))
        self.assertTrue(any("RepositoryQuery" in failure for failure in failures))

    def test_exported_apollo_imports_cannot_reexport_the_adapter_dependency(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            write(
                root,
                "ForgeKit/Sources/GitHubForgeAdapter/Exported.swift",
                "@_exported import Apollo\n",
            )
            write(
                root,
                "ForgeKit/Sources/GitHubForgeAdapter/Public.swift",
                "public import ApolloAPI\n",
            )
            write(
                root,
                "ForgeKit/Sources/GitHubForgeAdapter/Internal.swift",
                "import Apollo\ninternal import ApolloAPI\n",
            )

            failures = exports.export_failures(root)

        self.assertEqual(len(failures), 2)
        self.assertTrue(any("Exported.swift" in failure for failure in failures))
        self.assertTrue(any("Public.swift" in failure for failure in failures))
        self.assertFalse(any("Internal.swift" in failure for failure in failures))

    def test_exported_signatures_cover_ordinary_modifiers_and_multiline_clauses(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            write(
                root,
                "ForgeKit/Sources/GitHubForgeAdapter/Client.swift",
                """
                import Apollo

                public static func staticClient() -> ApolloClient { fatalError() }
                public class func classClient() -> ApolloClient { fatalError() }
                public required init(client: ApolloClient) { fatalError() }
                final public class RawStore: ApolloStore {}
                public func multilineClient()
                    -> ApolloClient
                { fatalError() }
                package func constrained<Value>(_ value: Value) -> Value
                    where Value: ApolloSelectionSet
                { value }
                """,
            )

            failures = exports.export_failures(root)

        self.assertEqual(len(failures), 6)
        for leaked_type in ("ApolloClient", "ApolloStore", "ApolloSelectionSet"):
            self.assertTrue(any(leaked_type in failure for failure in failures))

    def test_internal_uses_and_exported_implementation_bodies_are_safe(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            write(
                root,
                "ForgeKit/Sources/GitHubForgeAdapter/Safe.swift",
                '''
                import Apollo

                internal static func rawClient() -> ApolloClient { fatalError() }
                public static func safeValue() -> String {
                    let client: ApolloClient? = nil
                    return client == nil ? "ApolloClient" : "ready"
                }
                // public func commentedOut() -> ApolloClient
                /* public func outerComment() -> ApolloClient
                   /* public func nestedComment() -> ApolloStore */ */
                public func label(_ value: String = "ApolloClient") -> String { value }
                ''',
            )

            failures = exports.export_failures(root)

        self.assertEqual(failures, [])


if __name__ == "__main__":
    unittest.main()
