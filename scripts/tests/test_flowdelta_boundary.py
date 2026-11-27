from __future__ import annotations

import json
import pathlib
import tempfile
import unittest

from support import load_script


class FlowDeltaBoundaryTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.module = load_script("check_flowdelta_boundary.py")

    def make_approved_seams(self, root: pathlib.Path) -> None:
        controllers = root / "Controllers"
        controllers.mkdir()
        (controllers / "FlowDeltaAdapters.swift").write_text("import FlowDeltaUI\n")
        (controllers / "HistoryFlowRevisionProvider.swift").write_text("import FlowDeltaGit\n")
        (controllers / "FlowDeltaReviewCommands.swift").write_text("import FlowDeltaExport\n")

    def make_repository(
        self,
        root: pathlib.Path,
        *,
        requirement: str = "kind = exactVersion;\n\t\t\t\tversion = 0.3.0;",
        products: tuple[str, ...] = (
            "FlowDeltaCore", "FlowDeltaAnalysis", "FlowDeltaGit", "FlowDeltaUI", "FlowDeltaExport",
        ),
        resolved_version: str | None = "0.3.0",
        extra_project: str = "",
        workspace_references: tuple[str, ...] = ("group:GitX.xcodeproj",),
    ) -> None:
        project = root / "GitX.xcodeproj"
        project.mkdir()
        dependencies = "".join(
            f"\t\tFD{index:022d} /* {name} */ = {{\n"
            "\t\t\tisa = XCSwiftPackageProductDependency;\n"
            '\t\t\tpackage = FD2000000000000000017 /* XCRemoteSwiftPackageReference "FlowDelta" */;\n'
            f"\t\t\tproductName = {name};\n"
            "\t\t};\n"
            for index, name in enumerate(products)
        )
        (project / "project.pbxproj").write_text(
            "/* Begin XCRemoteSwiftPackageReference section */\n"
            '\t\tFD2000000000000000017 /* XCRemoteSwiftPackageReference "FlowDelta" */ = {\n'
            "\t\t\tisa = XCRemoteSwiftPackageReference;\n"
            '\t\t\trepositoryURL = "https://github.com/hbmartin/FlowDelta.git";\n'
            f"\t\t\trequirement = {{\n\t\t\t\t{requirement}\n\t\t\t}};\n"
            "\t\t};\n"
            "/* End XCRemoteSwiftPackageReference section */\n"
            "/* Begin XCSwiftPackageProductDependency section */\n"
            f"{dependencies}"
            "\t\tC0DE /* HighlightKit */ = {\n"
            "\t\t\tisa = XCSwiftPackageProductDependency;\n"
            '\t\t\tpackage = C0DE1 /* XCRemoteSwiftPackageReference "HighlightKit" */;\n'
            "\t\t\tproductName = HighlightKit;\n"
            "\t\t};\n"
            "/* End XCSwiftPackageProductDependency section */\n"
            f"{extra_project}"
        )
        workspace = root / "GitX.xcworkspace"
        (workspace / "xcshareddata" / "swiftpm").mkdir(parents=True)
        (workspace / "contents.xcworkspacedata").write_text(
            "<Workspace version = \"1.0\">\n"
            + "".join(f'   <FileRef location = "{location}"></FileRef>\n' for location in workspace_references)
            + "</Workspace>\n"
        )
        pins = [{"identity": "highlightkit", "state": {"revision": "a", "version": "0.3.0"}}]
        if resolved_version is not None:
            pins.append({"identity": "flowdelta", "state": {"revision": "b", "version": resolved_version}})
        (workspace / "xcshareddata" / "swiftpm" / "Package.resolved").write_text(
            json.dumps({"pins": pins, "version": 3})
        )

    def test_the_exact_pin_with_matching_resolution_and_approved_products_passes(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            self.make_repository(root)

            self.assertEqual(self.module.dependency_failures(root), [])

    def test_a_range_requirement_fails(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            self.make_repository(root, requirement="kind = upToNextMajorVersion;\n\t\t\t\tminimumVersion = 0.3.0;")

            self.assertEqual(
                self.module.dependency_failures(root),
                [
                    "FlowDelta must be pinned with exactVersion, not upToNextMajorVersion",
                    "Package.resolved pins FlowDelta 0.3.0 but the project has no exact version",
                ],
            )

    def test_the_resolution_must_match_the_pin(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            self.make_repository(root, resolved_version="0.2.2")
            self.assertEqual(
                self.module.dependency_failures(root),
                ["Package.resolved pins FlowDelta 0.2.2 but the project requires exactly 0.3.0"],
            )

        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            self.make_repository(root, resolved_version=None)
            self.assertEqual(
                self.module.dependency_failures(root),
                ["GitX.xcworkspace/xcshareddata/swiftpm/Package.resolved does not pin FlowDelta"],
            )

    def test_local_flowdelta_overrides_fail(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            self.make_repository(
                root,
                extra_project=(
                    '\t\tAB /* XCLocalSwiftPackageReference "../FlowDelta" */ = {\n'
                    "\t\t\tisa = XCLocalSwiftPackageReference;\n"
                    "\t\t\trelativePath = ../FlowDelta;\n"
                    "\t\t};\n"
                ),
                workspace_references=("group:GitX.xcodeproj", "group:../FlowDelta"),
            )

            self.assertEqual(
                self.module.dependency_failures(root),
                [
                    "GitX.xcodeproj references a local FlowDelta package at ../FlowDelta",
                    "GitX.xcworkspace references a local FlowDelta checkout at group:../FlowDelta",
                ],
            )

    def test_linked_products_must_be_exactly_the_approved_set(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            self.make_repository(
                root,
                products=("FlowDeltaCore", "FlowDeltaAnalysis", "FlowDeltaGit", "FlowDeltaUI", "FlowDeltaLayout"),
            )

            self.assertEqual(
                self.module.dependency_failures(root),
                [
                    "GitX links unapproved FlowDelta product FlowDeltaLayout",
                    "GitX does not link required FlowDelta product FlowDeltaExport",
                ],
            )

    def test_a_missing_remote_reference_fails_closed(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            self.make_repository(root)
            (root / "GitX.xcodeproj" / "project.pbxproj").write_text("// no packages\n")

            self.assertEqual(
                self.module.dependency_failures(root),
                [
                    "GitX.xcodeproj has no remote FlowDelta package reference",
                    "Package.resolved pins FlowDelta 0.3.0 but the project has no exact version",
                ],
            )

    def test_only_the_approved_integration_files_may_import_flowdelta(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            self.make_approved_seams(root)

            self.assertEqual(self.module.boundary_failures(root), [])

            (root / "Controller.swift").write_text("@preconcurrency import FlowDeltaCore\n")
            failures = self.module.boundary_failures(root)

        self.assertEqual(
            failures,
            ["Controller.swift: imports FlowDelta outside an approved integration seam"],
        )

    def test_missing_integration_seams_fail_closed(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            root.mkdir(exist_ok=True)

            failures = self.module.boundary_failures(root)

        self.assertEqual(
            failures,
            [
                "Missing FlowDelta integration seam Controllers/FlowDeltaAdapters.swift",
                "Missing FlowDelta integration seam Controllers/FlowDeltaReviewCommands.swift",
                "Missing FlowDelta integration seam Controllers/HistoryFlowRevisionProvider.swift",
            ],
        )

    def test_kind_qualified_imports_cannot_bypass_the_boundary(self) -> None:
        for kind in ("typealias", "struct", "class", "enum", "protocol", "let", "var", "func"):
            for prefix in ("", "@preconcurrency ", "internal "):
                with self.subTest(kind=kind, prefix=prefix), tempfile.TemporaryDirectory() as directory:
                    root = pathlib.Path(directory)
                    self.make_approved_seams(root)
                    (root / "TypedImport.swift").write_text(
                        f"{prefix}import {kind} FlowDeltaCore.Symbol\n"
                    )

                    self.assertEqual(
                        self.module.boundary_failures(root),
                        ["TypedImport.swift: imports FlowDelta outside an approved integration seam"],
                    )

    def test_kind_qualified_imports_are_allowed_in_the_approved_seams(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            self.make_approved_seams(root)
            (root / "Controllers" / "HistoryFlowRevisionProvider.swift").write_text(
                "@preconcurrency import struct FlowDeltaCore.AnalysisLimits\n"
            )

            self.assertEqual(self.module.boundary_failures(root), [])


if __name__ == "__main__":
    unittest.main()
