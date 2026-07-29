#!/usr/bin/env python3
"""Reject Apollo and generated GraphQL types from ForgeKit public APIs."""

from __future__ import annotations

import pathlib
import re
import sys


ROOT = pathlib.Path(__file__).resolve().parents[1]
FORGEKIT_ROOT = pathlib.PurePosixPath("ForgeKit")
SOURCE_ROOTS = (
    pathlib.PurePosixPath("ForgeKit/Sources/ForgeKit"),
    pathlib.PurePosixPath("ForgeKit/Sources/GitHubForgeAdapter"),
)
GENERATED_ROOT = pathlib.PurePosixPath(
    "ForgeKit/Sources/GitHubForgeAdapter/Generated"
)
TOP_LEVEL_DECLARATION = re.compile(
    r"^(?:(?:public|package|internal|fileprivate|private|open|final|indirect|"
    r"nonisolated)\s+)*(?:class|struct|enum|protocol|actor|typealias)\s+"
    r"([A-Za-z_][A-Za-z0-9_]*)\b",
    re.MULTILINE,
)
DECLARATION_START = re.compile(
    r"^\s*(?P<modifiers>(?:(?:@[A-Za-z_][A-Za-z0-9_]*(?:\([^)]*\))?|"
    r"[A-Za-z_][A-Za-z0-9_]*(?:\([^)]*\))?)\s+)*)"
    r"(?P<kind>class|struct|enum|protocol|actor|extension|typealias|func|var|let|"
    r"subscript|init|deinit)\b"
)
EXPORTED_ACCESS = re.compile(r"\b(?:public|package|open)\b")
IMPORT_DECLARATION = re.compile(
    r"^\s*(?P<prefix>(?:(?:@[A-Za-z_][A-Za-z0-9_]*(?:\([^)]*\))?|"
    r"public|package|internal|fileprivate|private)\s+)*)"
    r"import\s+(?:(?:class|struct|enum|protocol|func|var|let|typealias)\s+)?"
    r"(?P<module>[A-Za-z_][A-Za-z0-9_]*)\b",
    re.MULTILINE,
)
APOLLO_TOKEN = re.compile(r"\bApollo[A-Za-z0-9_]*\b")


def is_relative_to(path: pathlib.PurePosixPath, parent: pathlib.PurePosixPath) -> bool:
    try:
        path.relative_to(parent)
        return True
    except ValueError:
        return False


def generated_type_names(repository_root: pathlib.Path) -> set[str]:
    root = repository_root / pathlib.Path(GENERATED_ROOT)
    names: set[str] = set()
    if not root.is_dir():
        return names
    for path in sorted(root.rglob("*.swift")):
        names.update(TOP_LEVEL_DECLARATION.findall(path.read_text(errors="replace")))
    return names


def source_without_comments_and_strings(source: str) -> str:
    """Mask comments and string contents while preserving lines and delimiters."""
    output: list[str] = []
    index = 0
    state = "code"
    block_comment_depth = 0
    while index < len(source):
        character = source[index]
        following = source[index + 1] if index + 1 < len(source) else ""
        if state == "code":
            if character == "/" and following == "/":
                output.extend((" ", " "))
                index += 2
                state = "line-comment"
                continue
            if character == "/" and following == "*":
                output.extend((" ", " "))
                index += 2
                state = "block-comment"
                block_comment_depth = 1
                continue
            if source.startswith('"""', index):
                output.extend((" ", " ", " "))
                index += 3
                state = "multiline-string"
                continue
            if character == '"':
                output.append(" ")
                index += 1
                state = "string"
                continue
            output.append(character)
            index += 1
            continue
        if state == "line-comment":
            if character == "\n":
                output.append("\n")
                state = "code"
            else:
                output.append(" ")
            index += 1
            continue
        if state == "block-comment":
            if character == "/" and following == "*":
                output.extend((" ", " "))
                index += 2
                block_comment_depth += 1
            elif character == "*" and following == "/":
                output.extend((" ", " "))
                index += 2
                block_comment_depth -= 1
                if block_comment_depth == 0:
                    state = "code"
            else:
                output.append("\n" if character == "\n" else " ")
                index += 1
            continue
        if state == "multiline-string":
            if source.startswith('"""', index):
                output.extend((" ", " ", " "))
                index += 3
                state = "code"
            else:
                output.append("\n" if character == "\n" else " ")
                index += 1
            continue
        if character == "\\" and following:
            output.extend((" ", "\n" if following == "\n" else " "))
            index += 2
        elif character == '"':
            output.append(" ")
            index += 1
            state = "code"
        else:
            output.append("\n" if character == "\n" else " ")
            index += 1
    return "".join(output)


def declaration_match(line: str) -> re.Match[str] | None:
    match = DECLARATION_START.match(line)
    if match is None or EXPORTED_ACCESS.search(match.group("modifiers")) is None:
        return None
    return match


def signature_before_body(lines: list[str], start: int) -> str:
    fragment: list[str] = []
    parentheses = 0
    brackets = 0
    for index in range(start, len(lines)):
        line = lines[index]
        if index > start and parentheses == 0 and brackets == 0:
            if DECLARATION_START.match(line) is not None or line.lstrip().startswith("}"):
                break
        end = len(line)
        for position, character in enumerate(line):
            if character == "(":
                parentheses += 1
            elif character == ")":
                parentheses = max(0, parentheses - 1)
            elif character == "[":
                brackets += 1
            elif character == "]":
                brackets = max(0, brackets - 1)
            elif character == "{" and parentheses == 0 and brackets == 0:
                end = position
                break
        fragment.append(line[:end])
        if end != len(line):
            break
    return "\n".join(fragment)


def exported_declarations(source: str) -> list[tuple[int, str]]:
    lines = source_without_comments_and_strings(source).splitlines()
    declarations: list[tuple[int, str]] = []
    for index, line in enumerate(lines):
        if declaration_match(line) is not None:
            declarations.append((index + 1, signature_before_body(lines, index)))
    return declarations


def exported_apollo_imports(source: str) -> list[tuple[int, str]]:
    sanitized = source_without_comments_and_strings(source)
    imports: list[tuple[int, str]] = []
    for match in IMPORT_DECLARATION.finditer(sanitized):
        module = match.group("module")
        prefix = match.group("prefix")
        if not module.startswith("Apollo"):
            continue
        if "@_exported" in prefix or EXPORTED_ACCESS.search(prefix) is not None:
            imports.append((sanitized.count("\n", 0, match.start()) + 1, module))
    return imports


def export_failures(repository_root: pathlib.Path) -> list[str]:
    failures: list[str] = []
    generated_names = generated_type_names(repository_root)
    for source_root in SOURCE_ROOTS:
        directory = repository_root / pathlib.Path(source_root)
        if not directory.is_dir():
            continue
        for path in sorted(directory.rglob("*.swift")):
            relative = pathlib.PurePosixPath(path.relative_to(repository_root).as_posix())
            source = path.read_text(errors="replace")
            if is_relative_to(relative, GENERATED_ROOT):
                if exported_declarations(source) or exported_apollo_imports(source):
                    failures.append(
                        f"{relative}: generated GraphQL declarations must remain internal"
                    )
                continue
            for line, module in exported_apollo_imports(source):
                failures.append(
                    f"{relative}:{line}: exported import exposes adapter-private module {module}"
                )
            for line, declaration in exported_declarations(source):
                forbidden = set(APOLLO_TOKEN.findall(declaration))
                forbidden.update(
                    name
                    for name in generated_names
                    if re.search(rf"\b{re.escape(name)}\b", declaration)
                )
                for name in sorted(forbidden):
                    failures.append(
                        f"{relative}:{line}: exported API exposes adapter-private type {name}"
                    )
    return failures


def main() -> int:
    if not (ROOT / pathlib.Path(FORGEKIT_ROOT)).exists():
        print("ForgeKit exported-symbol check skipped until the ForgeKit package is present.")
        return 0
    failures = export_failures(ROOT)
    if failures:
        print("ForgeKit exported-symbol check failed:", file=sys.stderr)
        for failure in failures:
            print(f"- {failure}", file=sys.stderr)
        return 1
    print("ForgeKit exported-symbol check passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
