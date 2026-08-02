from __future__ import annotations

import pathlib
import tempfile
import unittest

from support import load_script


boundary = load_script("check_avatar_boundary.py")


def write(root: pathlib.Path, relative: pathlib.PurePosixPath, source: str) -> None:
    path = root / pathlib.Path(relative)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(source)


def safe_sources(root: pathlib.Path) -> None:
    write(
        root,
        boundary.POLICY_PATH,
        'static let exactGitHubHosts: Set<String> = ["avatars.githubusercontent.com"]',
    )
    write(
        root,
        boundary.MARKDOWN_PATH,
        "enum Inline { case imagePlaceholder(altText: String) }",
    )
    write(
        root,
        boundary.RENDERER_PATH,
        """
        protocol ForgeMarkdownNavigationRouting {
          func openMarkdownLinkInBrowser(_ url: URL)
        }
        struct Renderer {
          let headingRanges = 1
          func render(_ document: ForgeMarkdownDocument) {
            switch value { case let .imagePlaceholder(altText): print(altText) }
          }
        }
        """,
    )
    write(
        root,
        boundary.LOADER_PATH,
        """
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil
        config.urlCache = nil
        request.setValue(nil, forHTTPHeaderField: "Authorization")
        request.setValue(nil, forHTTPHeaderField: "Cookie")
        request.setValue(nil, forHTTPHeaderField: "Referer")
        let redirected = ForgeAvatarURL(url)
        let metadata = ForgeAvatarResponseMetadata(
        let bytes = ForgeAvatarByteAccumulator(
        mediaType(for: sourceType)
        let dimensions = ForgeAvatarDecodedDimensions(
        CGImageSourceCreateImageAtIndex(source, 0, options)
        Task.checkCancellation()
        guard !enabled else { return }
        cache.removeAll()
        """,
    )


class AvatarBoundaryTests(unittest.TestCase):
    def test_accepts_exact_inert_boundary(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            safe_sources(root)

            failures = boundary.boundary_failures(root)

        self.assertEqual(failures, [])

    def test_rejects_broader_host_and_markdown_source(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            safe_sources(root)
            write(
                root,
                boundary.POLICY_PATH,
                """static let exactGitHubHosts: Set<String> = [
                "avatars.githubusercontent.com", "*.githubusercontent.com"]
                """,
            )
            write(
                root,
                boundary.MARKDOWN_PATH,
                "enum Inline { case imagePlaceholder(altText: String, source: URL) }",
            )

            failures = boundary.boundary_failures(root)

        self.assertTrue(any("must be exactly" in failure for failure in failures))
        self.assertTrue(any("wildcard" in failure for failure in failures))
        self.assertTrue(any("altText only" in failure for failure in failures))

    def test_rejects_markdown_network_and_ambient_avatar_credentials(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            safe_sources(root)
            renderer = root / pathlib.Path(boundary.RENDERER_PATH)
            renderer.write_text(renderer.read_text() + "\nlet session: URLSession\n")
            loader = root / pathlib.Path(boundary.LOADER_PATH)
            loader.write_text(
                loader.read_text().replace(
                    'request.setValue(nil, forHTTPHeaderField: "Authorization")',
                    "// authorization inherited",
                )
            )

            failures = boundary.boundary_failures(root)

        self.assertTrue(any("URLSession" in failure for failure in failures))
        self.assertTrue(any("authorization stripped" in failure for failure in failures))

    def test_rejects_missing_final_response_and_first_frame_checks(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            safe_sources(root)
            loader = root / pathlib.Path(boundary.LOADER_PATH)
            loader.write_text(
                loader.read_text()
                .replace("ForgeAvatarResponseMetadata(", "UncheckedMetadata(")
                .replace(
                    "CGImageSourceCreateImageAtIndex(source, 0, options)",
                    "decodeAllFrames(source)",
                )
            )

            failures = boundary.boundary_failures(root)

        self.assertTrue(any("final URL revalidation" in failure for failure in failures))
        self.assertTrue(any("first-frame decode" in failure for failure in failures))


if __name__ == "__main__":
    unittest.main()
