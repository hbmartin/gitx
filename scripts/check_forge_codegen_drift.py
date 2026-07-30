#!/usr/bin/env python3
"""Regenerate ForgeKit GraphQL sources offline and reject checked-in drift."""

from __future__ import annotations

import hashlib
import json
import os
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile
from typing import NamedTuple


ROOT = pathlib.Path(__file__).resolve().parents[1]
FORGEKIT_ROOT = pathlib.PurePosixPath("ForgeKit")
SCHEMA = pathlib.PurePosixPath("ForgeKit/GraphQL/schema.graphqls")
CONFIG = pathlib.PurePosixPath("ForgeKit/apollo-codegen-config.json")
GENERATOR = pathlib.PurePosixPath("ForgeKit/scripts/generate_graphql.sh")
UPDATER = pathlib.PurePosixPath("ForgeKit/scripts/update_github_graphql.sh")
OPERATIONS_ROOT = pathlib.PurePosixPath("ForgeKit/GraphQL/Operations")
GENERATED_ROOT = pathlib.PurePosixPath(
    "ForgeKit/Sources/GitHubForgeAdapter/Generated"
)
ADAPTER_ROOT = pathlib.PurePosixPath("ForgeKit/Sources/GitHubForgeAdapter")
APOLLO_IMPORT = re.compile(
    r"^\s*(?:(?:@[A-Za-z_][A-Za-z0-9_]*(?:\([^)]*\))?|"
    r"public|package|internal|fileprivate|private)\s+)*"
    r"import\s+(?:(?:class|struct|enum|protocol|func|var|let|typealias)\s+)?"
    r"Apollo[A-Za-z0-9_]*\b",
    re.MULTILINE,
)
CODEGEN_REFERENCE = re.compile(
    r"\bApollo(?:API)?\.|GitHubForgeAdapter/Generated|"
    r"Sources/GitHubForgeAdapter/Generated"
)
OPERATION_DEFINITION = re.compile(
    r"\b(query|mutation|subscription)\s+([A-Za-z_][A-Za-z0-9_]*)\b"
)
EXPECTED_READ_OPERATIONS = frozenset(
    {
        "GitHubAttentionCandidates",
        "GitHubHistoryOverlay",
        "GitHubIssueDetails",
        "GitHubIssueList",
        "GitHubPullRequestDetails",
        "GitHubPullRequestList",
        "GitHubPullRequestReviewThreadComments",
        "GitHubPullRequestReviewThreads",
        "GitHubRepositoryFacts",
        "GitHubRepositoryItemSearch",
    }
)
EXPECTED_MUTATION_PREFLIGHT_OPERATIONS = frozenset(
    {
        "GitHubHeadBranchDeletionPreflight",
        "GitHubPullRequestCreationPreflight",
        "GitHubPullRequestMutationPreflight",
        "GitHubReviewThreadMutationPreflight",
        "GitHubSyncForkPreflight",
    }
)
EXPECTED_MUTATION_OPERATIONS = frozenset(
    {
        "GitHubClosePullRequest",
        "GitHubConvertPullRequestToDraft",
        "GitHubCreatePullRequest",
        "GitHubDeleteHeadBranch",
        "GitHubEditPullRequest",
        "GitHubEnterMergeQueue",
        "GitHubLeaveMergeQueue",
        "GitHubMarkPullRequestReady",
        "GitHubMergePullRequest",
        "GitHubPublishInlineReview",
        "GitHubReopenPullRequest",
        "GitHubReplyToReviewThread",
        "GitHubResolveReviewThread",
        "GitHubSubmitFormalReview",
        "GitHubUnresolveReviewThread",
        "GitHubUpdatePullRequestBranch",
    }
)
EXPECTED_QUERY_OPERATIONS = EXPECTED_READ_OPERATIONS | EXPECTED_MUTATION_PREFLIGHT_OPERATIONS
EXPECTED_OPERATIONS = EXPECTED_QUERY_OPERATIONS | EXPECTED_MUTATION_OPERATIONS
PAGINATED_READ_OPERATIONS = EXPECTED_READ_OPERATIONS - {"GitHubRepositoryFacts"}
ATTENTION_INPUTS = (
    "assignedActors",
    "comments",
    "latestReviews",
    "participants",
    "reviewRequests",
    "reviewThreads",
    "statusCheckRollup",
)
NETWORKING_CODEGEN = re.compile(
    r"(?:^|[;&|]\s*)\s*(?:command\s+)?"
    r"(?:curl|wget|gh|nc|netcat|ftp|ssh|scp|sftp)\b|"
    r"fetch-schema|--fetch-schema|\burllib(?:\.request)?\b|"
    r"\brequests\s*\.|\bURLSession\b",
    re.IGNORECASE | re.MULTILINE,
)
SECRET_MATERIAL = re.compile(
    r"gh\s+auth\s+token|--show-token\b|Authorization|"
    r"GITHUB_TOKEN|GH_TOKEN|OAUTH_TOKEN|ACCESS_TOKEN",
    re.IGNORECASE,
)
SHELL_TRACING = re.compile(
    r"\bset\s+(?:-[A-Za-z]*[xv][A-Za-z]*|-o\s+(?:xtrace|verbose))\b|"
    r"\bbash\s+-[A-Za-z]*[xv][A-Za-z]*\b|\bPS4\s*=",
    re.IGNORECASE,
)


class ConnectionExpectation(NamedTuple):
    field_name: str
    required_arguments: tuple[tuple[str, ...], ...]
    count: int = 1


EXPECTED_CONNECTIONS_BY_DEFINITION = {
    "GitHubAttentionCandidates": (
        ConnectionExpectation(
            "search", (("first", ":", "$", "first"), ("after", ":", "$", "after"))
        ),
        ConnectionExpectation("assignedActors", (("first", ":", "100"),), 2),
        ConnectionExpectation("participants", (("first", ":", "100"),), 2),
        ConnectionExpectation("reviewRequests", (("first", ":", "100"),)),
        ConnectionExpectation(
            "comments", (("last", ":", "$", "activityLast"),), 3
        ),
        ConnectionExpectation("latestReviews", (("first", ":", "100"),)),
        ConnectionExpectation(
            "reviewThreads", (("first", ":", "$", "reviewThreadFirst"),)
        ),
    ),
    "GitHubHistoryOverlay": (
        ConnectionExpectation(
            "associatedPullRequests",
            (
                ("first", ":", "$", "pullRequestFirst"),
                ("after", ":", "$", "pullRequestAfter"),
            ),
        ),
    ),
    "GitHubIssueDetails": (
        ConnectionExpectation("assignedActors", (("first", ":", "100"),)),
        ConnectionExpectation("participants", (("first", ":", "100"),)),
        ConnectionExpectation(
            "timelineItems",
            (
                ("first", ":", "$", "timelineFirst"),
                ("after", ":", "$", "timelineAfter"),
            ),
        ),
    ),
    "GitHubIssueList": (
        ConnectionExpectation(
            "issues", (("first", ":", "$", "first"), ("after", ":", "$", "after"))
        ),
    ),
    "GitHubPullRequestDetails": (
        ConnectionExpectation("assignedActors", (("first", ":", "100"),)),
        ConnectionExpectation("participants", (("first", ":", "100"),)),
        ConnectionExpectation("reviewRequests", (("first", ":", "100"),)),
        ConnectionExpectation("latestReviews", (("first", ":", "100"),)),
        ConnectionExpectation(
            "closingIssuesReferences", (("first", ":", "100"),)
        ),
        ConnectionExpectation(
            "contexts",
            (
                ("first", ":", "$", "checkFirst"),
                ("after", ":", "$", "checkAfter"),
            ),
        ),
        ConnectionExpectation(
            "timelineItems",
            (
                ("first", ":", "$", "timelineFirst"),
                ("after", ":", "$", "timelineAfter"),
            ),
        ),
    ),
    "GitHubPullRequestList": (
        ConnectionExpectation(
            "pullRequests",
            (("first", ":", "$", "first"), ("after", ":", "$", "after")),
        ),
    ),
    "GitHubPullRequestCreationPreflight": (
        ConnectionExpectation(
            "pullRequests", (("first", ":", "100"), ("after", ":", "$", "after"))
        ),
    ),
    "GitHubPullRequestReviewThreadComments": (
        ConnectionExpectation(
            "comments", (("first", ":", "$", "first"), ("after", ":", "$", "after"))
        ),
    ),
    "GitHubPullRequestReviewThreads": (
        ConnectionExpectation(
            "reviewThreads",
            (("first", ":", "$", "first"), ("after", ":", "$", "after")),
        ),
        ConnectionExpectation(
            "comments", (("first", ":", "$", "commentFirst"),)
        ),
    ),
    "GitHubRepositoryFacts": (
        ConnectionExpectation("repositoryTopics", (("first", ":", "100"),)),
    ),
    "GitHubRepositoryItemSearch": (
        ConnectionExpectation(
            "search", (("first", ":", "$", "first"), ("after", ":", "$", "after"))
        ),
    ),
    "GitHubPullRequestSummary": (
        ConnectionExpectation("labels", (("first", ":", "100"),)),
    ),
    "GitHubIssueSummary": (
        ConnectionExpectation("labels", (("first", ":", "100"),)),
    ),
}
EXPECTED_PAGE_INFO_FIELDS = frozenset(
    {"hasPreviousPage", "startCursor", "hasNextPage", "endCursor"}
)


def generated_snapshot(repository_root: pathlib.Path) -> dict[str, str]:
    generated_root = repository_root / pathlib.Path(GENERATED_ROOT)
    if not generated_root.is_dir():
        return {}
    return {
        path.relative_to(generated_root).as_posix(): hashlib.sha256(
            path.read_bytes()
        ).hexdigest()
        for path in sorted(generated_root.rglob("*"))
        if path.is_file()
    }


def required_asset_failures(repository_root: pathlib.Path) -> list[str]:
    failures: list[str] = []
    for relative in (SCHEMA, CONFIG, GENERATOR, UPDATER):
        path = repository_root / pathlib.Path(relative)
        if not path.is_file():
            failures.append(f"missing required ForgeKit codegen asset: {relative}")

    for relative in (GENERATOR, UPDATER):
        executable = repository_root / pathlib.Path(relative)
        if executable.is_file() and not os.access(executable, os.X_OK):
            failures.append(f"ForgeKit codegen script is not executable: {relative}")

    operations_root = repository_root / pathlib.Path(OPERATIONS_ROOT)
    if not operations_root.is_dir():
        failures.append(f"missing ForgeKit GraphQL operations directory: {OPERATIONS_ROOT}")
    elif not any(operations_root.rglob("*.graphql")):
        failures.append(f"ForgeKit GraphQL operations directory is empty: {OPERATIONS_ROOT}")

    generated_root = repository_root / pathlib.Path(GENERATED_ROOT)
    if not generated_root.is_dir():
        failures.append(
            f"missing checked-in ForgeKit generated source directory: {GENERATED_ROOT}"
        )
    elif not generated_snapshot(repository_root):
        failures.append(
            f"ForgeKit generated source directory is empty: {GENERATED_ROOT}"
        )
    return failures


def graphql_tokens(source: str) -> list[str]:
    tokens: list[str] = []
    index = 0
    while index < len(source):
        character = source[index]
        if character.isspace() or character == ",":
            index += 1
            continue
        if character == "#":
            newline = source.find("\n", index)
            index = len(source) if newline == -1 else newline + 1
            continue
        if source.startswith('"""', index):
            end = source.find('"""', index + 3)
            index = len(source) if end == -1 else end + 3
            continue
        if character == '"':
            index += 1
            while index < len(source):
                if source[index] == "\\":
                    index += 2
                elif source[index] == '"':
                    index += 1
                    break
                else:
                    index += 1
            continue
        name = re.match(r"[_A-Za-z][_0-9A-Za-z]*", source[index:])
        if name:
            tokens.append(name.group(0))
            index += len(name.group(0))
            continue
        number = re.match(r"-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?", source[index:])
        if number:
            tokens.append(number.group(0))
            index += len(number.group(0))
            continue
        if source.startswith("...", index):
            tokens.append("...")
            index += 3
            continue
        tokens.append(character)
        index += 1
    return tokens


def matching_token_index(
    tokens: list[str], start: int, opening: str, closing: str
) -> int | None:
    depth = 0
    for index in range(start, len(tokens)):
        if tokens[index] == opening:
            depth += 1
        elif tokens[index] == closing:
            depth -= 1
            if depth == 0:
                return index
    return None


def definition_bodies(
    repository_root: pathlib.Path,
) -> dict[str, list[tuple[pathlib.Path, list[str]]]]:
    definitions: dict[str, list[tuple[pathlib.Path, list[str]]]] = {}
    operations_root = repository_root / pathlib.Path(OPERATIONS_ROOT)
    if not operations_root.is_dir():
        return definitions

    for path in sorted(operations_root.rglob("*.graphql")):
        tokens = graphql_tokens(path.read_text(errors="replace"))
        index = 0
        while index < len(tokens):
            token = tokens[index]
            if token not in {"query", "mutation", "subscription", "fragment"}:
                index += 1
                continue
            if index + 1 >= len(tokens):
                break
            name = tokens[index + 1]
            try:
                body_start = tokens.index("{", index + 2)
            except ValueError:
                break
            body_end = matching_token_index(tokens, body_start, "{", "}")
            if body_end is None:
                break
            definitions.setdefault(name, []).append(
                (path, tokens[body_start + 1 : body_end])
            )
            index = body_end + 1
    return definitions


def field_selections(
    definition_tokens: list[str],
) -> list[tuple[str, list[str], list[str]]]:
    selections: list[tuple[str, list[str], list[str]]] = []
    for index, token in enumerate(definition_tokens[:-1]):
        if not re.fullmatch(r"[_A-Za-z][_0-9A-Za-z]*", token):
            continue
        if definition_tokens[index + 1] != "(":
            continue
        arguments_end = matching_token_index(definition_tokens, index + 1, "(", ")")
        if arguments_end is None:
            continue
        selection_start = arguments_end + 1
        while selection_start < len(definition_tokens) and definition_tokens[
            selection_start
        ] == "@":
            selection_start += 2
            if (
                selection_start < len(definition_tokens)
                and definition_tokens[selection_start] == "("
            ):
                directive_end = matching_token_index(
                    definition_tokens, selection_start, "(", ")"
                )
                if directive_end is None:
                    break
                selection_start = directive_end + 1
        if (
            selection_start >= len(definition_tokens)
            or definition_tokens[selection_start] != "{"
        ):
            continue
        selection_end = matching_token_index(
            definition_tokens, selection_start, "{", "}"
        )
        if selection_end is None:
            continue
        selections.append(
            (
                token,
                definition_tokens[index + 2 : arguments_end],
                definition_tokens[selection_start + 1 : selection_end],
            )
        )
    return selections


def contains_token_sequence(tokens: list[str], expected: tuple[str, ...]) -> bool:
    width = len(expected)
    return any(
        tuple(tokens[index : index + width]) == expected
        for index in range(len(tokens))
    )


def direct_selection_names(tokens: list[str]) -> set[str]:
    names: set[str] = set()
    brace_depth = 0
    for token in tokens:
        if token == "{":
            brace_depth += 1
        elif token == "}":
            brace_depth -= 1
        elif brace_depth == 0 and re.fullmatch(r"[_A-Za-z][_0-9A-Za-z]*", token):
            names.add(token)
    return names


def connection_policy_failures(repository_root: pathlib.Path) -> list[str]:
    failures: list[str] = []
    operations_root = repository_root / pathlib.Path(OPERATIONS_ROOT)
    if not operations_root.is_dir() or not any(operations_root.rglob("*.graphql")):
        return failures
    definitions = definition_bodies(repository_root)

    for definition_name, expectations in EXPECTED_CONNECTIONS_BY_DEFINITION.items():
        candidates = definitions.get(definition_name, [])
        if len(candidates) != 1:
            failures.append(
                f"GraphQL definition {definition_name} must appear exactly once for "
                "connection completeness policy"
            )
            continue
        path, body = candidates[0]
        relative = path.relative_to(repository_root).as_posix()
        selections = field_selections(body)
        for expectation in expectations:
            matching = [
                selection
                for selection in selections
                if selection[0] == expectation.field_name
                and all(
                    contains_token_sequence(selection[1], required)
                    for required in expectation.required_arguments
                )
            ]
            if len(matching) != expectation.count:
                failures.append(
                    f"{relative}: {definition_name} must select "
                    f"{expectation.count} {expectation.field_name} connection(s) "
                    "with the required pagination arguments"
                )

    for definition_name, candidates in definitions.items():
        for path, body in candidates:
            relative = path.relative_to(repository_root).as_posix()
            occurrences: dict[str, int] = {}
            for field_name, arguments, selection in field_selections(body):
                if not any(
                    contains_token_sequence(arguments, (argument_name, ":"))
                    for argument_name in ("first", "last")
                ):
                    continue
                occurrences[field_name] = occurrences.get(field_name, 0) + 1
                markers = direct_selection_names(selection)
                missing = {"pageInfo", "totalCount"} - markers
                if missing:
                    failures.append(
                        f"{relative}: {definition_name} {field_name} connection "
                        f"occurrence {occurrences[field_name]} is missing "
                        + ", ".join(sorted(missing))
                    )

    page_info = definitions.get("GitHubPageInfo", [])
    if len(page_info) != 1:
        failures.append(
            "GraphQL fragment GitHubPageInfo must appear exactly once for pagination policy"
        )
    else:
        path, body = page_info[0]
        missing = EXPECTED_PAGE_INFO_FIELDS - direct_selection_names(body)
        if missing:
            relative = path.relative_to(repository_root).as_posix()
            failures.append(
                f"{relative}: GitHubPageInfo is missing " + ", ".join(sorted(missing))
            )
    return failures


def operation_policy_failures(repository_root: pathlib.Path) -> list[str]:
    operations_root = repository_root / pathlib.Path(OPERATIONS_ROOT)
    if not operations_root.is_dir():
        return []

    declarations: dict[str, list[tuple[str, pathlib.Path, str]]] = {}
    combined_source = ""
    for path in sorted(operations_root.rglob("*.graphql")):
        source = path.read_text(errors="replace")
        combined_source += "\n" + source
        for kind, name in OPERATION_DEFINITION.findall(source):
            declarations.setdefault(name, []).append((kind, path, source))

    failures: list[str] = []
    for name, definitions in sorted(declarations.items()):
        if len(definitions) > 1:
            failures.append(f"duplicate GraphQL operation definition: {name}")
        for kind, path, _ in definitions:
            expected_kind = "mutation" if name in EXPECTED_MUTATION_OPERATIONS else "query"
            if name not in EXPECTED_OPERATIONS:
                relative = path.relative_to(repository_root).as_posix()
                failures.append(f"{relative}: GraphQL operation {name} is outside the accepted Milestone 1-3 surface")
            elif kind != expected_kind:
                relative = path.relative_to(repository_root).as_posix()
                failures.append(
                    f"{relative}: GraphQL operation {name} must be a {expected_kind}"
                )

    for name in sorted(EXPECTED_OPERATIONS - declarations.keys()):
        if name in EXPECTED_READ_OPERATIONS:
            failures.append(f"missing required Milestone 1 GraphQL read operation: {name}")
        else:
            failures.append(f"missing required Milestones 2-3 GraphQL operation: {name}")

    for name in sorted(PAGINATED_READ_OPERATIONS & declarations.keys()):
        _, path, source = declarations[name][0]
        relative = path.relative_to(repository_root).as_posix()
        if not re.search(r"\$[A-Za-z0-9_]*[Ff]irst\s*:\s*Int!", source):
            failures.append(f"{relative}: {name} is missing an explicit page-size variable")
        if not re.search(r"\$[A-Za-z0-9_]*[Aa]fter\s*:\s*String", source):
            failures.append(f"{relative}: {name} is missing an explicit page-cursor variable")
        if "pageInfo" not in source or "totalCount" not in source:
            failures.append(f"{relative}: {name} is missing pagination completeness markers")

    attention = declarations.get("GitHubAttentionCandidates", [])
    if attention:
        _, path, source = attention[0]
        relative = path.relative_to(repository_root).as_posix()
        for required_input in ATTENTION_INPUTS:
            provided_by_summary = (
                required_input == "statusCheckRollup"
                and "GitHubPullRequestSummary" in source
            )
            if required_input not in source and not provided_by_summary:
                failures.append(
                    f"{relative}: Attention candidates omit derived input {required_input}"
                )

    if re.search(r"\bnotifications?\b", combined_source, re.IGNORECASE):
        failures.append(
            "Milestone 1 Attention operations must derive state without GitHub Notifications"
        )
    return failures


def tooling_policy_failures(repository_root: pathlib.Path) -> list[str]:
    failures: list[str] = []
    config_path = repository_root / pathlib.Path(CONFIG)
    if config_path.is_file():
        try:
            config = json.loads(config_path.read_text())
        except json.JSONDecodeError as error:
            failures.append(f"{CONFIG}: invalid JSON: {error}")
        else:
            if "schemaDownload" in config or "schemaDownloadConfiguration" in config:
                failures.append(
                    f"{CONFIG}: offline codegen configuration must not download a schema"
                )

    generator_path = repository_root / pathlib.Path(GENERATOR)
    if generator_path.is_file():
        generator = generator_path.read_text(errors="replace")
        if NETWORKING_CODEGEN.search(generator):
            failures.append(f"{GENERATOR}: offline generator contains a network command")
        if "2.3.0" not in generator:
            failures.append(f"{GENERATOR}: Apollo CLI version 2.3.0 is not enforced")

    updater_path = repository_root / pathlib.Path(UPDATER)
    if updater_path.is_file():
        updater = updater_path.read_text(errors="replace")
        for required in ("gh auth status", "gh api", "application/vnd.github.v4.idl"):
            if required not in updater:
                failures.append(f"{UPDATER}: authenticated schema refresh omits {required}")
        if SECRET_MATERIAL.search(updater) or SHELL_TRACING.search(updater):
            failures.append(f"{UPDATER}: schema refresh must not read, print, or store token material")
    return failures


def codegen_usage(repository_root: pathlib.Path) -> list[str]:
    usage: list[str] = []
    adapter_root = repository_root / pathlib.Path(ADAPTER_ROOT)
    if adapter_root.is_dir():
        for path in sorted(adapter_root.rglob("*.swift")):
            source = path.read_text(errors="replace")
            if APOLLO_IMPORT.search(source) or CODEGEN_REFERENCE.search(source):
                usage.append(path.relative_to(repository_root).as_posix())
    forgekit_root = repository_root / pathlib.Path(FORGEKIT_ROOT)
    if forgekit_root.is_dir():
        usage.extend(
            path.relative_to(repository_root).as_posix()
            for path in sorted(forgekit_root.rglob("*.graphql"))
        )
    return sorted(set(usage))


def codegen_is_applicable(repository_root: pathlib.Path) -> bool:
    assets = (SCHEMA, CONFIG, GENERATOR, UPDATER, OPERATIONS_ROOT)
    if any((repository_root / pathlib.Path(path)).exists() for path in assets):
        return True
    if (repository_root / pathlib.Path(GENERATED_ROOT)).exists():
        return True
    return bool(codegen_usage(repository_root))


def describe_drift(before: dict[str, str], after: dict[str, str]) -> list[str]:
    failures: list[str] = []
    before_paths = set(before)
    after_paths = set(after)
    for path in sorted(after_paths - before_paths):
        failures.append(f"generated GraphQL source was added by codegen: {path}")
    for path in sorted(before_paths - after_paths):
        failures.append(f"generated GraphQL source was removed by codegen: {path}")
    for path in sorted(before_paths & after_paths):
        if before[path] != after[path]:
            failures.append(f"generated GraphQL source changed after codegen: {path}")
    return failures


def prepare_isolated_codegen_root(
    repository_root: pathlib.Path,
    temporary_directory: str,
) -> pathlib.Path:
    isolated_root = pathlib.Path(temporary_directory) / "repository"
    graph_ql_root = repository_root / "ForgeKit/GraphQL"
    shutil.copytree(graph_ql_root, isolated_root / "ForgeKit/GraphQL")

    for relative in (CONFIG, GENERATOR):
        source = repository_root / pathlib.Path(relative)
        destination = isolated_root / pathlib.Path(relative)
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, destination)

    shutil.copytree(
        repository_root / pathlib.Path(GENERATED_ROOT),
        isolated_root / pathlib.Path(GENERATED_ROOT),
    )
    return isolated_root


def available_apollo_cli(repository_root: pathlib.Path) -> pathlib.Path | None:
    configured = os.environ.get("APOLLO_IOS_CLI")
    if configured:
        candidate = pathlib.Path(configured).expanduser()
        if not candidate.is_absolute():
            candidate = repository_root / candidate
        return candidate.resolve()

    forgekit_root = repository_root / pathlib.Path(FORGEKIT_ROOT)
    candidates = (
        forgekit_root / "apollo-ios-cli",
        forgekit_root / ".build/gitx-apollo-cli-2.3.0/apollo-ios-cli",
    )
    for candidate in candidates:
        if candidate.is_file() and os.access(candidate, os.X_OK):
            return candidate.resolve()

    archive = forgekit_root / ".build/checkouts/apollo-ios/CLI/apollo-ios-cli.tar.gz"
    cached_cli = candidates[1]
    if archive.is_file():
        cached_cli.parent.mkdir(parents=True, exist_ok=True)
        result = subprocess.run(
            ["tar", "-xzf", str(archive), "-C", str(cached_cli.parent)],
            capture_output=True,
            text=True,
            check=False,
        )
        if (
            result.returncode == 0
            and cached_cli.is_file()
            and os.access(cached_cli, os.X_OK)
        ):
            return cached_cli.resolve()

    path_cli = shutil.which("apollo-ios-cli")
    return pathlib.Path(path_cli).resolve() if path_cli else None


def codegen_drift_failures(repository_root: pathlib.Path) -> list[str]:
    usage = codegen_usage(repository_root)
    if not codegen_is_applicable(repository_root):
        return []

    asset_failures = required_asset_failures(repository_root)
    failures = list(asset_failures)
    failures.extend(operation_policy_failures(repository_root))
    failures.extend(connection_policy_failures(repository_root))
    failures.extend(tooling_policy_failures(repository_root))
    incomplete_assets = any(
        failure.startswith("missing ") or " is empty:" in failure
        for failure in asset_failures
    )
    if usage and incomplete_assets:
        failures.append(
            "ForgeKit Apollo/GraphQL usage exists without complete codegen infrastructure: "
            + ", ".join(usage)
        )
    if failures:
        return failures

    before = generated_snapshot(repository_root)
    environment = os.environ.copy()
    environment["GITX_FORGE_CODEGEN_OFFLINE"] = "1"
    apollo_cli = available_apollo_cli(repository_root)
    if apollo_cli is not None:
        environment["APOLLO_IOS_CLI"] = str(apollo_cli)

    with tempfile.TemporaryDirectory(prefix="gitx-forge-codegen-drift-") as directory:
        try:
            isolated_root = prepare_isolated_codegen_root(repository_root, directory)
            generator = isolated_root / pathlib.Path(GENERATOR)
            result = subprocess.run(
                [str(generator), "--offline"],
                cwd=isolated_root,
                env=environment,
                capture_output=True,
                text=True,
                check=False,
            )
        except OSError as error:
            return [f"could not execute isolated offline ForgeKit codegen: {error}"]

        after = generated_snapshot(isolated_root)

    if result.returncode != 0:
        detail = result.stderr.strip() or result.stdout.strip()
        suffix = f": {detail}" if detail else ""
        return [
            f"offline ForgeKit codegen exited with status {result.returncode}{suffix}"
        ]

    return describe_drift(before, after)


def main() -> int:
    if not (ROOT / pathlib.Path(FORGEKIT_ROOT)).exists():
        print("ForgeKit codegen-drift check skipped until the package is present.")
        return 0

    if not codegen_is_applicable(ROOT):
        print(
            "ForgeKit codegen-drift check passed: not applicable before the first "
            "Apollo/GraphQL operation."
        )
        return 0

    failures = codegen_drift_failures(ROOT)
    if failures:
        print("ForgeKit codegen-drift check failed:", file=sys.stderr)
        for failure in failures:
            print(f"- {failure}", file=sys.stderr)
        return 1

    print("ForgeKit offline codegen is reproducible and checked-in sources are current.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
