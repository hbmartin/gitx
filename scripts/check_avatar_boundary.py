#!/usr/bin/env python3
"""Protect the inert Markdown and structured-avatar security boundary."""

from __future__ import annotations

import pathlib
import re
import sys


ROOT = pathlib.Path(__file__).resolve().parents[1]
POLICY_PATH = pathlib.PurePosixPath(
    "ForgeKit/Sources/ForgeKit/ForgeAvatarPolicy.swift"
)
MARKDOWN_PATH = pathlib.PurePosixPath(
    "ForgeKit/Sources/ForgeKit/ForgeMarkdown.swift"
)
RENDERER_PATH = pathlib.PurePosixPath(
    "Classes/Views/ForgeMarkdownNativeRenderer.swift"
)
LOADER_PATH = pathlib.PurePosixPath("Classes/Views/ForgeAvatarLoading.swift")
APPROVED_HOSTS = {"avatars.githubusercontent.com"}

HOST_ALLOWLIST = re.compile(
    r"exactGitHubHosts\s*:\s*Set<String>\s*=\s*\[(.*?)\]",
    re.DOTALL,
)
STRING_LITERAL = re.compile(r'"([^"\\]*(?:\\.[^"\\]*)*)"')
IMAGE_PLACEHOLDER = re.compile(
    r"case\s+imagePlaceholder\s*\(([^)]*)\)", re.DOTALL
)
MARKDOWN_IO = {
    "URLSession": re.compile(r"\bURLSession\b"),
    "URL loading": re.compile(r"\bData\s*\(\s*contentsOf\s*:"),
    "NSImage URL loading": re.compile(r"\bNSImage\s*\(\s*contentsOf\s*:"),
    "ImageIO URL loading": re.compile(r"\bCGImageSourceCreateWithURL\b"),
    "web rendering": re.compile(r"\b(?:WKWebView|WebView)\b"),
}
REQUIRED_RENDERER_PATTERNS = {
    "sanitized document input": re.compile(
        r"func\s+render\s*\(\s*_\s+document\s*:\s*ForgeMarkdownDocument"
    ),
    "inert image placeholder": re.compile(r"case\s+let\s+\.imagePlaceholder\(altText\)"),
    "heading fragment map": re.compile(r"headingRanges"),
    "typed navigation seam": re.compile(r"ForgeMarkdownNavigationRouting"),
    "explicit browser escape": re.compile(r"openMarkdownLinkInBrowser"),
}
REQUIRED_AVATAR_PATTERNS = {
    "ephemeral session": re.compile(r"URLSessionConfiguration\.ephemeral"),
    "no cookie storage": re.compile(r"httpCookieStorage\s*=\s*nil"),
    "cookies disabled": re.compile(r"httpShouldSetCookies\s*=\s*false"),
    "no credential storage": re.compile(r"urlCredentialStorage\s*=\s*nil"),
    "no URL cache": re.compile(r"urlCache\s*=\s*nil"),
    "authorization stripped": re.compile(
        r"setValue\(nil,\s*forHTTPHeaderField:\s*\"Authorization\"\)"
    ),
    "cookie stripped": re.compile(
        r"setValue\(nil,\s*forHTTPHeaderField:\s*\"Cookie\"\)"
    ),
    "referrer stripped": re.compile(
        r"setValue\(nil,\s*forHTTPHeaderField:\s*\"Referer\"\)"
    ),
    "redirect revalidation": re.compile(r"ForgeAvatarURL\(url\)"),
    "final URL revalidation": re.compile(r"ForgeAvatarResponseMetadata\s*\("),
    "stream byte limit": re.compile(r"ForgeAvatarByteAccumulator\s*\("),
    "declared media validation": re.compile(r"mediaType\(for:\s*sourceType\)"),
    "decoded pixel validation": re.compile(r"ForgeAvatarDecodedDimensions\s*\("),
    "first-frame decode": re.compile(
        r"CGImageSourceCreateImageAtIndex\(source,\s*0,"
    ),
    "cancellation": re.compile(r"Task\.checkCancellation\(\)"),
    "cache purge on disable": re.compile(
        r"guard\s+!enabled\s+else\s*\{\s*return\s*\}.*?cache\.removeAll\(\)",
        re.DOTALL,
    ),
}


def read_required(
    repository_root: pathlib.Path,
    relative: pathlib.PurePosixPath,
    failures: list[str],
) -> str:
    path = repository_root / pathlib.Path(relative)
    if not path.is_file():
        failures.append(f"{relative}: required boundary source is missing")
        return ""
    return path.read_text(errors="replace")


def boundary_failures(repository_root: pathlib.Path) -> list[str]:
    failures: list[str] = []
    policy = read_required(repository_root, POLICY_PATH, failures)
    markdown = read_required(repository_root, MARKDOWN_PATH, failures)
    renderer = read_required(repository_root, RENDERER_PATH, failures)
    loader = read_required(repository_root, LOADER_PATH, failures)

    allowlist = HOST_ALLOWLIST.search(policy)
    if allowlist is None:
        failures.append(f"{POLICY_PATH}: exact GitHub avatar host allowlist is missing")
    else:
        hosts = set(STRING_LITERAL.findall(allowlist.group(1)))
        if hosts != APPROVED_HOSTS:
            failures.append(
                f"{POLICY_PATH}: avatar hosts must be exactly "
                f"{sorted(APPROVED_HOSTS)}, found {sorted(hosts)}"
            )
        if "*" in allowlist.group(1):
            failures.append(f"{POLICY_PATH}: wildcard avatar hosts are forbidden")

    placeholder = IMAGE_PLACEHOLDER.search(markdown)
    if placeholder is None:
        failures.append(f"{MARKDOWN_PATH}: inert image placeholder case is missing")
    else:
        declaration = placeholder.group(1)
        if not re.fullmatch(r"\s*altText\s*:\s*String\s*", declaration):
            failures.append(
                f"{MARKDOWN_PATH}: imagePlaceholder must contain altText only"
            )

    for description, pattern in MARKDOWN_IO.items():
        if pattern.search(renderer):
            failures.append(
                f"{RENDERER_PATH}: contains forbidden {description} capability"
            )
    for description, pattern in REQUIRED_RENDERER_PATTERNS.items():
        if not pattern.search(renderer):
            failures.append(f"{RENDERER_PATH}: missing {description}")

    for description, pattern in REQUIRED_AVATAR_PATTERNS.items():
        if not pattern.search(loader):
            failures.append(f"{LOADER_PATH}: missing {description}")

    return failures


def main() -> int:
    failures = boundary_failures(ROOT)
    if failures:
        print("Markdown/avatar boundary check failed:", file=sys.stderr)
        for failure in failures:
            print(f"- {failure}", file=sys.stderr)
        return 1
    print("Markdown/avatar boundary check passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
