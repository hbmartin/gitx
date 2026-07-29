# Future Work: Grow GitXCore Deliberately

## Current Boundary

`GitXCore` is a local Swift package containing Foundation-only domain and presentation decisions. `GitX.app` links the package and owns AppKit, ObjectiveGit, persistence adapters, process execution, and Objective-C compatibility facades.

The package currently owns:

- application-preference validation and repository view-state identity;
- commit remote presentation and submission eligibility;
- history-search normalization and Git argument construction;
- repository-configuration validation and commit-message rules;
- sidebar remote synchronization and revision placement.

`swift test --package-path GitXCore --enable-code-coverage` is the canonical hostless test command. CI runs it as a job separate from app-hosted XCTest and enforces `GitXCore/coverage-baseline.json`. `scripts/check_gitxcore_boundary.py` rejects application and global-runtime dependencies.

## Next Candidates

Move behavior in narrow, behavior-preserving slices:

1. Relative-date calculation. Inject `now` and `Calendar`; retain the Objective-C-visible formatter as the app adapter.
2. Revision-specifier parsing and reference-name classification. Keep conversion to ObjectiveGit values in the app.
3. Source-language lookup from `PBHighlighting`. Keep attributed-string construction and HighlightKit in the app.
4. History menu eligibility, staging eligibility, split limits, and retry delays when those decisions are next changed.

URL-provider detection, remote-to-Forge identity, and remote-link destination construction are no longer GitXCore candidates. Milestone 0 of the Forge integration moves those decisions into the provider-neutral `ForgeKit` package defined by ADR-0004 so authenticated and unauthenticated Forge behavior share one model.

Do not move repository access, `NSDocument`, mutable ObjectiveGit models, AppKit values, defaults storage, notifications, file watchers, or task execution into the package.

## Migration Rule

For each slice:

1. Characterize the current app behavior.
2. Define explicit Foundation inputs and outputs.
3. Add equivalent XCTest coverage in `GitXCoreTests`.
4. Implement the policy and retain a thin app adapter where Objective-C compatibility requires it.
5. Run core and app-hosted suites and ratchet both coverage policies.
6. Remove app characterization only when the same observable contract remains covered at the lower layer.

## Success Criteria

- Core tests remain hostless, deterministic, and fast.
- Every package source is represented in the nondecreasing coverage baseline.
- The app depends on `GitXCore`; the package never depends on the app.
- New controller decision logic normally enters through a tested core value.
- New packages or targets require a distinct ownership boundary, not just directory size.

## Deferred Build Work

Dependency and script-phase tuning is intentionally separate from core extraction. See `docs/build-performance-followups.md`.

## Deferred History Rendering Concurrency Work

When `PBWebHistoryController` is converted to Swift for Forge integration, preserve its existing serial render queue, content-generation stale-result rejection, active-task cancellation, callback ordering, and main-thread rendering installation. Bridge ForgeKit's async/await APIs into that characterized contract; do not combine the language conversion with a render-pipeline concurrency redesign.

A later, separately approved change may evaluate replacing the legacy queue and generation model with structured concurrency or an actor. Before doing so, characterize success, failure, cancellation, reentrancy, owner deallocation, and stale-result behavior; preserve the established cached-feedback and main-thread performance budgets; and verify the redesign with focused ordering tests, TSan, lifecycle observation, the full test plans, and the coverage ratchet.

## Deferred Forge Markdown Image Loading

Milestones 1–3 render every Markdown image as inert alt text and a placeholder and perform no image network or local-file access. A later milestone will add explicit image loading after a separate product and security review; it must not weaken the sanitizer or make image retrieval a prerequisite for rendering Markdown.

That future design must resolve user-consent scope, trusted-origin policy, redirect handling, private and loopback address blocking, response-byte and decoded-pixel limits, accepted media types, animated-image behavior, cache retention, accessibility, and failure presentation. Its network client must be isolated from Forge authentication and browser state, send no credentials or cookies to image hosts, revalidate every redirect and final URL, accept only HTTPS, and preserve the inert placeholder on denial or failure. Add security fixtures, cancellation and resource-limit tests, cache-purge coverage, and diagnostic screenshots before shipping it.

## Deferred GitHub Enterprise Server API Support

Milestones 0–3 limit authenticated native API operations to GitHub.com. GitHub Enterprise Server remotes still receive provider-aware identity, link generation, and system-browser routing, but no native authenticated Pull Request, Issue, review, check, merge, Attention, or mutation surfaces.

A later, separately approved milestone may add Enterprise Server APIs. It must define per-server authentication and GitHub App configuration, supported server-version and capability ranges, GraphQL-schema and REST-version compatibility, TLS and custom-certificate policy, redirect and origin validation, account and credential isolation, upgrade/deprecation behavior, and a representative self-hosted verification matrix without weakening the provider-neutral ForgeKit boundary.

## Deferred Forge Milestone 4

Milestones 0–3 stop at repository linking, read overlays, Pull Request creation and checkout, native review, lifecycle and merge, Attention, and their supporting account/cache/status infrastructure. The following catalog remains future work rather than partially hidden or shipped behind an experimental toggle:

- GitHub Actions workflow/run/job views, native log streaming, rerun-failed, and `workflow_dispatch`;
- GitHub Release creation from tags, generated changelogs, prerelease/draft state, and asset uploads;
- repository/organization code, Pull Request, and Issue search;
- Gist creation, Projects, Discussions, and security-alert surfaces;
- native Issue creation, editing, close/reopen, comments, labels, assignees, and milestones; and
- native reviewer/team mutation after Pull Request creation.

Each future slice needs a new scope and permission review, provider-neutral capability additions, deterministic fixtures, explicit pagination/rate-limit behavior, accessibility and Snow Leopard UI review, coverage ratcheting, and current diagnostic screenshots. The full Milestone 3 permission envelope does not pre-authorize unrelated Actions, workflow, release, security, organization, or Gist authority.
