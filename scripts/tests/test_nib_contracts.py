from __future__ import annotations

import unittest
import xml.etree.ElementTree as ET

from support import ROOT


class MainMenuNibContractTests(unittest.TestCase):
    def test_repository_document_controller_is_the_only_document_controller(self) -> None:
        root = ET.parse(ROOT / "Resources/en.lproj/MainMenu.xib").getroot()
        objects = root.find("objects")
        self.assertIsNotNone(objects)
        document_controllers = [
            element
            for element in objects.findall("customObject")
            if element.get("customClass")
            in {"NSDocumentController", "PBRepositoryDocumentController"}
        ]

        self.assertEqual(
            [element.get("customClass") for element in document_controllers],
            ["PBRepositoryDocumentController"],
        )


if __name__ == "__main__":
    unittest.main()
