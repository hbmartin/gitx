# Comprehensive GitHub Integration Plan

Status: accepted for implementation planning on 2026-07-29.

This plan adds a native GitHub.com collaboration overlay to GitX without replacing local Git as the source of truth. Milestones 0–3 are cumulative, independently usable checkpoints delivered as a deliberate commit series in one ready pull request against the `hbmartin/gitx` fork. ADR-0004, ADR-0005, and ADR-0006 record the hard-to-reverse package, rendering, and permission choices; `CONTEXT.md` defines the canonical language.

Repository scripts, `Mintfile`, shared test plans, repo-local skills, and `AGENTS.md` remain authoritative for implementation and verification. This planning document does not override them.

## Product boundaries

The integration follows these invariants:

- Native AppKit lists, inspectors, sheets, menus, and diff overlays are the primary UI. No embedded browser is added.
- Local Git remains authoritative for commits, refs, working state, diffs, checkout safety, fetch, pull, and push. Forge data is a cached overlay that must not block those features.
- GitHub.com is the only authenticated native API endpoint through Milestone 3. GitHub Enterprise Server, GitLab, and Bitbucket retain provider-aware links and browser routing.
- `ForgeKit` is provider-neutral and GitHub-first. Application code consumes its values and capabilities rather than Apollo or GitHub transport types.
- Unauthenticated linking always remains available. Authentication unlocks additional capabilities instead of becoming an app-wide gate.
- There is no experimental feature toggle. Each supported milestone ships only after its checkpoint gates pass.
- Forge startup is lazy. Normal launch performs no synchronous Keychain, database, or network work on the main thread.
- The visual treatment follows GitX's Mac OS X 10.6 Snow Leopard restraint. New Forge views are programmatic Swift AppKit where that matches the app; XIB-backed views remain allowed when necessary to preserve the established appearance and Cocoa contracts.

Milestone 4 is documentation-only. Actions, releases, broader search, Gists, security alerts, Projects, Discussions, issue mutation, native reviewer management, Markdown image loading, GitHub Enterprise Server APIs, and a PBWebHistory structured-concurrency redesign are not part of Milestones 0–3.

## Package and application architecture

Add `ForgeKit/Package.swift` as a second local Swift package beside `GitXCore` with these initial targets:

- `ForgeKit`: provider-neutral identities, Forge Repository Binding, destination parsing, capabilities, Pull Request and Issue values, Check and Review Rollups, sanitized Markdown documents, pagination, cache records, refresh policy, draft identity, and mutation results.
- `GitHubForgeAdapter`: GitHub.com authentication, Apollo GraphQL operations, REST gaps, transport errors, rate-limit metadata, and mapping into `ForgeKit` values.
- `ForgeKitTests` and `GitHubForgeAdapterTests`: hostless, network-free XCTest targets using deterministic fixtures and transport fakes.

Pin Apollo iOS exactly at 2.3.0 and `swift-markdown` exactly at 0.8.0 in the canonical workspace resolution. Their package manifests and transitive dependencies must retain the current macOS 15.0 deployment target and Swift 6 build ceiling rather than raising either. Apollo's normalized cache is memory-only. Check in the selected GitHub schema snapshot, GraphQL operations, and generated sources. An explicit authenticated maintenance script refreshes the schema and generated output; CI runs offline code generation and fails on a diff.

GraphQL is the primary data path for connected GitHub state. Focused REST transport covers device flow, endpoints or mutations not available in the selected GraphQL surface, and server responses whose REST metadata is required. Both paths map into the same provider-neutral values before crossing the adapter boundary.

Extend `ApplicationComposition.swift` as the composition root for Keychain access, the Forge database, the GitHub adapter, the refresh coordinator, and per-window Forge sessions. Do not introduce application-wide dependency injection. Existing Objective-C callers receive only narrow `@objc` façades where migrating the caller would create disproportionate churn.

Use a dedicated Forge refresh coordinator rather than placing API polling inside `PBAutoFetchManager`. Local scheduled Git fetch and Forge refresh have independent preferences, queues, failure state, and cancellation. App activation, repository open, successful fetch/push, selected Pull Request or Issue changes, manual refresh, network restoration, and mutation completion can request a coalesced Forge refresh.

### Boundary enforcement

Apollo modules, generated operation selections, and generated models are private to `GitHubForgeAdapter`:

- target dependencies provide compile-time isolation;
- a checked-in dependency-free Python checker rejects Apollo imports and generated-source references outside approved adapter paths;
- an exported-symbol check rejects Apollo or generated types in public APIs;
- focused Python tests pin allowed and rejected examples; and
- `scripts/verify_static.sh` invokes the checks locally and in CI.

Do not add Semgrep or another analysis dependency.

## Identity, binding, and capability model

A normalized Forge identity contains the Forge Kind, exact HTTPS origin, owner, and repository name. Remote parsing accepts the existing SCP-style SSH, `ssh`, `git`, and `https` forms and preserves the existing GitHub/GitLab/Bitbucket hostname heuristic for links. URL construction always uses parsed and percent-encoded components rather than string-prefix security checks.

Each local repository has one stable Primary Forge Repository. High-confidence remote detection may create its initial Forge Repository Binding automatically. Ambiguous candidates require a chooser; changing the currently selected Git remote does not silently change the Primary Forge Repository. The binding records the local remote, Forge Repository, and preferred Forge Account in Repository View State.

Fork-aware binding distinguishes the checked-out fork from its parent. The user chooses the primary overlay repository when both are plausible. `origin` and `upstream` names are hints, never authority. Clone and Sync Fork flows use the bound identities rather than inventing a second mapping.

Capabilities are evaluated per Credential, Forge Repository, and operation. Known missing permission or repository access disables the operation. An `Unverified Write` may attempt only the explicitly confirmed operation; success promotes that exact Credential/repository/capability tuple until the Credential changes or a later authorization response invalidates it. Cached or stale Forge data never makes a mutation eligible.

## Authentication and permissions

Milestone 1 introduces a Preferences → Accounts surface with multiple GitHub.com Forge Accounts. One Forge Account has one current Credential.

Credential acquisition is explicit:

- GitHub App device flow is the primary path and yields an expiring user access token plus rotating refresh token.
- The native client ships no GitHub App private key, never mints installation access tokens, and depends on no token-broker backend.
- GitHub CLI may be consulted only during an explicit add-account flow as an identity/credential broker. It is not a silent runtime fallback.
- Fine-grained and classic personal access tokens remain available. Known scopes and access map to capabilities; non-introspectable fine-grained writes use `Unverified Write`.

Tokens and refresh tokens live only in Keychain. Structured logs may contain provider, operation, status class, timing, cache result, and stable non-secret identifiers, but never tokens, request bodies, comment text, draft content, or private response payloads.

The GitHub App requests the full Milestone 3 repository permission envelope from Milestone 1: Metadata read, Contents write, Pull Requests write, Issues write, Checks read, and Commit Statuses read. Issue UI remains read-only through Milestone 3. Effective capability is still the intersection of App installation repository selection, token authority, and the user's role.

There is no automatic Credential fallback. Removing an account uses a simple destructive confirmation without a detailed affected-repository inventory and deletes its Keychain material, account partitions, drafts, watched choices, seen state, bindings, and cached avatars attributable only to that account. It does not clear the app-wide trusted external-link origin list.

An organization SAML failure offers **Authorize in Browser** and Retry. Missing GitHub App installation or repository selection offers **Configure Repository Access** and Retry. Declining either leaves every still-effective capability usable.

### Anonymous public access

Public GitHub.com repositories may perform anonymous REST reads only after an explicit open or manual refresh. Anonymous mode has no timer, Attention polling, or mutation capability and reserves ten requests from its current allowance. Its requests share one app-wide remaining-budget counter and cooldown.

After sign-in, anonymous cache entries never seed authenticated views. If the selected Credential becomes unavailable, GitX requires an explicit **Continue Publicly** choice before using anonymous data. Anonymous Review Rollup displays **Sign in to view** rather than inferring private review state.

## Storage, cache, drafts, and recovery

Use one `ForgeKit`-owned system-SQLite database without adding a wrapper dependency.

| State | Owner and lifetime |
| --- | --- |
| Tokens and refresh tokens | Keychain, one current Credential per Forge Account |
| Forge Repository Binding and Primary Forge Repository | Repository View State |
| Status-bar visibility, polling preset, avatar loading, alert categories, trusted external origins | Application Preferences |
| Configurable list columns, filters, inspector layout, remembered merge method, successful delete-branch choice | Repository View State |
| Pull Request/Issue/check/review snapshots and derived render data | Disposable SQLite cache under the global LRU |
| Attention watched choices, seen markers, and Forge Drafts | Durable SQLite records outside LRU eviction |
| Apollo normalized objects | Memory only |

The disposable cache has a 250 MB global LRU across strict public and per-account partitions. Repository partitions expire after 30 idle days. The avatar cache is a shared credential-free 25 MB sub-cap inside the 250 MB total. Private and public partitions never blend, and account data never crosses accounts. On-disk Forge data is owner-only but has no additional app-layer encryption.

Forge Drafts autosave across restarts for the exact Forge Account and destination, including the displayed Pull Request head where relevant. Publishing, explicit discard, account removal, or 30 days of inactivity deletes a draft. There is no draft export feature and no offline mutation queue.

Schema migrations are transactional. Disposable snapshots may be rebuilt, but a corrupt database or failed durable-state migration is copied aside before recovery. Recovery copies are owner-only, excluded from system backups, and expire after 30 days. The failure-time UI exposes **Reveal in Finder** and a single-step permanent **Delete Now** action; it does not retain a Preferences list after dismissal and does not claim secure erase.

Recovery attempts durable-record salvage and offers **Retry**, destructive **Reset Forge Data**, and **Not Now**. Reset preserves accounts, Keychain credentials, and repository bindings but removes the Forge database and clears the app-wide trusted external-link origin list. Not Now disables Forge for the session without blocking local Git, shows **Forge Unavailable** with **Details** in the status bar, and mirrors that persistent failure on the Forge toolbar control when the status bar is hidden. The next launch retries automatically.

## Refresh, freshness, rate limits, and offline behavior

Fetched state carries a visible freshness timestamp. Partial GraphQL data renders every usable field and marks missing sections unavailable. A failed repository refresh retains its last snapshot as explicitly stale and never infers resolution or authorizes a mutation.

Normal repository-overlay refresh is adaptive: approximately one minute while an affected Forge view is active, five minutes for other open repositories, and fifteen minutes for other bound repositories. Attention uses its separate user-selected presets below. The coordinator coalesces overlapping data needs; every interval remains a target subject to rate limits, sleep, network reachability, and request cost rather than a guarantee.

Server-reported cooldowns are coordinated per Credential. A throttled Credential pauses every background request, manual API refresh, and Forge mutation using it until the supplied retry/reset time. GitX preserves drafts and local state, disables account rebinding as a cooldown bypass, and offers **Open on GitHub**. Cooldown deadlines are session-local and are discarded on quit.

The visible status bar shows **Rate Limited**, remaining time, and cached-data age. If the status bar is hidden, the Forge toolbar control does not mirror rate limiting; each affected disabled action instead explains **Rate limited until [time]** in its tooltip or disabled-state help.

Offline mutations fail fast, preserve drafts and local state, and never queue for later. If the app quits with a mutation in flight, it prompts **Wait** or **Quit Anyway**. Quit Anyway records an unknown outcome; the next applicable refresh reconciles server state without automatically retrying the mutation.

## Native UI shell

Replace the legacy bottom strip with a hideable, native repository status bar managed by a tested presenter. **View → Show Status Bar** and Application Preferences control one app-wide setting. Its visibility remains as the user set it; progress or errors never force it open.

The bar presents compact local Git and Forge groups:

- local branch/detached/unborn identity, ahead/behind state, staged/unstaged/untracked/conflict counts, and current Git operation or progress;
- bound Forge Repository and Account, overlay freshness/refresh state, and unavailable, offline, authentication, or rate-limit diagnostics; and
- concise Details actions for states that require explanation or recovery.

At narrow widths, lower-priority counts collapse before branch identity or the active operation. Existing toolbar status mirrors active progress. It also mirrors a persistent Forge database failure when the bar is hidden, but not the ordinary rate-limit countdown.

Add Pull Requests, Issues, and Attention to the source list. Use a collapsible right inspector for Repository Facts, Pull Request, Issue, Check, and Review details. Pull Request lists, Issue lists, the Attention list, inspector modes, and new History columns have configurable visible columns and remembered view state.

The toolbar gains a contextual Forge account/avatar control, New Pull Request, and Attention bell. **View Remote** becomes a pull-down. The Repository menu uses the detected user-facing family name—GitHub, GitLab, or Bitbucket—while internal APIs retain the term Forge.

Progress uses native `NSProgressIndicator` and status text, not shimmer placeholders. All new controls receive stable accessibility identifiers, keyboard order, VoiceOver labels, menu validation, and Snow Leopard-appropriate icons and spacing.

## Native Markdown and navigation

Implement ADR-0005 as a strict parse → sanitize → GitX document → AppKit render pipeline. Raw HTML, directives, active media, styles, forms, scripts, and unknown active structures never reach the renderer. Task-list checkboxes and reactions are read-only. Markdown editors use Write and Preview modes and provide no mention or issue-number autocomplete.

Markdown images remain inert alt text plus a placeholder through Milestone 3. Structured avatars are the sole image-network exception: exact checked-in GitHub avatar hosts, isolated credential/cookie/referrer-free loading, redirect revalidation, byte and decoded-pixel limits, static first-frame PNG/JPEG/GIF/WebP decoding, and initials fallback. **Load Avatars** is app-wide, defaults on, and clears/cancels the avatar cache when disabled.

Relative links resolve within the bound Forge Repository: Pull Request, Issue, review, and comment bodies use repository root/default branch; file-backed Markdown uses the displayed file directory and revision. GitHub-compatible heading slugs support local fragment scrolling. Recognized bound-repository Pull Request, Issue, commit, and file links route natively; every such link also offers **Open in Browser**.

Cross-origin HTTPS links show the complete normalized URL, with display and ASCII/Punycode host forms for internationalized names. Users may persist an exact HTTPS-origin trust entry and manage it in Preferences; there is no wildcard or parent-domain inheritance. Reset Forge Data clears this list, while account removal does not. Every `mailto` activation separately confirms decoded To/CC/BCC recipients, subject, and whether a body is prefilled; mail trust is never persistent.

## Milestone 0 — Forge identity and linking

Milestone 0 has no authentication requirement.

1. Establish the `ForgeKit` package, provider-neutral identities, remote parser, Primary Forge Repository selection, destination values, and security validation.
2. Move the policy currently embedded in `RepositoryRemoteURLCoordinator` into ForgeKit while retaining a narrow Objective-C-compatible façade in `RepositorySettingsController.swift` for existing callers.
3. Support repository, branch, commit, file, line/range permalink, compare, Pull Request, and Issue destinations for GitHub, GitLab, and Bitbucket. Keep the existing custom HTTPS URL template and host-match protection.
4. Add the View Remote toolbar pull-down and matching contextual Repository menu. Parse provider-native `#123` Pull Request/Issue references only in an unambiguous bound context; otherwise present a chooser.
5. Extend `Resources/GitX.sdef` with read-only commands for all supported native destinations. Ambiguous or invalid scripting requests fail with structured errors and never display interactive UI. Do not add a Services-menu surface.
6. Convert `PBGitWindowController.m` plus its Dialogs and ToolbarActions categories to Swift after the required characterization/header-preparation commit. Preserve nib runtime name, outlets, actions, window delegate behavior, KVO status observation, responder-chain dispatch, and Objective-C selectors.

Milestone 0 does not register `x-gitx` deep links, authenticate, access GitHub APIs, or clone/fetch missing data.

### Milestone 0 acceptance

- Provider/remote/destination tables cover schemes, Unicode, percent encoding, ports, malformed input, host deception, revisions, ranges, and all supported link families.
- Existing View Remote and post-push safety behavior remains characterized.
- AppleScript happy paths and structured failures are app-hosted XCTest covered.
- `PBGitWindowController` exceeds the conversion gate before conversion and passes generated-interface, nib, responder-chain, lifecycle, UI-plan, analyzer, coverage, and stable-build checks afterward.
- A named Milestone 0 checkpoint commit passes the full applicable verification matrix.

## Milestone 1 — Accounts and read overlays

1. Add Accounts preferences, GitHub App device flow, explicit GitHub CLI brokerage, PAT entry, Keychain storage, refresh-token rotation, App installation/repository-access configuration, SAML recovery, capability mapping, and account removal.
2. Bind repositories to a Primary Forge Repository and preferred Account. Show recognized providers in the sidebar; visually distinguish personal, organization, fork, parent, and upstream relationships.
3. Add paginated, searchable Pull Request and Issue source-list views plus native inspectors. Read-only surfaces include state, title/body, author, assignees, labels, milestones, reviewers, linked issues, mergeability, checks, review decision, and chronological timeline when returned. Partial data keeps usable sections visible.
4. Add Repository Facts—default branch, description, topics, visibility, archived state, fork relationship—to the History inspector.
5. Add demand-loaded History columns for Check Rollup and Pull Request badges. Preserve local History performance by loading cached values first and scheduling Forge work off the main thread.
6. Add the hideable repository status bar and Forge diagnostics described above.
7. Add the Attention Inbox, native Markdown renderer, structured avatars, external-link confirmation, and trusted-origin Preferences UI.
8. Convert `PBGitSidebarController.m` to Swift after its own characterization/header-preparation commit. Preserve source-list data source/delegate behavior, bindings, group visibility, selection restoration, responder chain, context menus, drag/drop behavior, runtime name, and XIB connections.

### Check and review presentation

Check Rollup is derived only from known current checks/statuses and maps to Succeeded, Failed, Running, Attention Required, or Neutral. Missing data is unavailable rather than successful. Review Rollup uses GitHub's current server review decision as authoritative and maps it to Approved, Changes Requested, Review Required, or No Decision; personal review attention is separate.

### Attention Inbox

Attention is an account-wide current-state view, not GitHub Notifications and not an event log. It polls only explicitly watched repositories; opening or binding a repository adds it to the watched set, and Preferences can remove it. There is no hard watch cap; scheduling is round-robin and target-based.

The list offers Current Repository and All, defaults to unseen/newest, supports filters and configurable columns, and reuses existing inspectors. The toolbar bell and sidebar item show unseen state. Opening an item marks it seen; Mark Unseen and Mark All Seen are available. Seen and resolved records expire after 30 days and remain local to the Mac.

Own comments never create Attention. Mentions qualify regardless of prior participation. Replies mean new human Pull Request conversation comments or review-thread replies after the account participated. Bot reply activity is configurable per watched repository and defaults off.

Check-failure attention supports **My Pull Requests** on by default and **Awaiting My Review** off by default. Merge Queue transitions are not Attention items.

macOS alerts are opt-in per category: review requests, mentions/replies, assignments, and failed checks on authored Pull Requests. Permission is requested only when the first alert category is enabled. Alerts occur only on a state transition while GitX is running; the first baseline marks existing items unseen but emits no operating-system alerts. An alert offers only Open and Mark Seen.

Polling presets are user-configurable:

| Preset | Active/open target | Background watched target |
| --- | ---: | ---: |
| Frequent | 2 minutes | 5 minutes |
| Balanced (default) | 5 minutes | 15 minutes |
| Conservative | 15 minutes | 30 minutes |
| Manual | No timer | No timer |

### Milestone 1 acceptance

- Authentication, token refresh, installation selection, SAML, missing-installation, capability, `Unverified Write`, account-removal, Keychain, and redaction tests are deterministic and network-free.
- Pull Request, Issue, Markdown sanitizer, link policy, avatar boundary, pagination, rollup, Attention, cache-partition, migration/recovery, refresh, partial-data, stale, offline, and rate-limit fixtures cover normal, failure, and boundary behavior.
- History cached rendering and view switching remain within 50 ms p95, with no more than 16 ms of main-thread work for overlay application.
- `PBGitSidebarController` meets the conversion gate and passes app-hosted, XIB, responder-chain, UI, analyzer, coverage, and stable-build checks.
- A named Milestone 1 checkpoint commit passes the full applicable verification matrix and ratchets every improved baseline.

## Milestone 2 — Pull Request creation and local integration

1. Add a one-shot **Create Pull Request** checkbox beside Push. When New Pull Request is invoked for an unpushed branch, open the Push sheet with the checkbox selected. A successful push with the box selected opens the native Create Pull Request sheet; an unchecked GitHub push has no Pull Request navigation side effect. Cancelling the sheet preserves the draft but does not reopen automatically. The native flow replaces automatic opening of GitHub's post-push Pull Request suggestion for an API-capable bound repository while retaining the validated browser fallback where native creation is unavailable.
2. Create Pull Requests with base, head, title, body, and Draft only. Draft defaults off every time. Use repository templates first, then the accepted commit-based heuristics. Do not include reviewer/team controls or best-effort follow-up mutations.
3. Detect an existing open Pull Request for the same head/base before creation and offer the native existing Pull Request instead of producing a duplicate. On success, open the native Pull Request destination.
4. Allow title/body edits with `updatedAt` conflict detection. All other metadata editing remains read-only or browser-routed through Milestone 3.
5. Add native Overview and Changes modes. The Pull Request diff is computed from local Git objects through GitX's existing diff model; Forge patches are not the rendering authority.
6. Check out Pull Requests, including contributor forks, by creating a collision-safe local branch and explicit remote/refspec only after working-state safety checks. Conflicts leave a named branch and require external/manual resolution; GitX does not hide or auto-resolve them.
7. Add owned/organization repository cloning with an explicit Account and SSH choice. Starred-repository clone browsing is not included.
8. Add server-side Sync Fork followed by a local fetch/report. Dirty, ahead, or diverged local state does not disable it because the action does not mutate the checkout.
9. Register `x-gitx` read-only deep links for supported native destinations. The Forge host occupies the URL authority and the remaining path must match a checked-in destination grammar; credentials, malformed authorities, unsupported schemes, authentication callbacks, and mutation routes are rejected. Route to the frontmost matching open checkout, otherwise show a checkout chooser. Never auto-clone or auto-fetch a missing Git object; offer Fetch or Open in Browser.
10. Convert `PBGitCommitController.m` and `PBWebHistoryController.m` separately. Each receives its own passing characterization/header-preparation commit and its own behavior-preserving conversion commit.

`PBWebHistoryController` retains its serial rendering queue, generation-based stale-result rejection, active-task cancellation, callback ordering, owner lifetime, and main-thread installation. Bridge ForgeKit async APIs into that contract; do not combine this conversion with actors or structured-concurrency redesign.

### Milestone 2 acceptance

- Push/Create PR state, templates, heuristics, duplicate detection, draft persistence, cancellation, concurrency conflicts, checkout safety, fork remote creation, branch naming, Sync Fork, clone, and deep-link routing have decision-level and app-hosted coverage.
- Critical Push → Create Pull Request, existing Pull Request, checkout, and deep-link journeys have accessibility-driven XCUITest with observable waits.
- `PBGitCommitController` and `PBWebHistoryController` each reach at least 90% line coverage with explicit normal/failure/boundary characterization before conversion, then pass generated-interface, XIB, bindings, responder-chain, cancellation/lifecycle, UI, TSan where applicable, analyzer, coverage, and stable-build checks.
- A named Milestone 2 checkpoint commit passes the full applicable verification matrix and ratchets every improved baseline.

## Milestone 3 — Native review, lifecycle, and merge

1. Render review threads in the local diff with expanded/collapsed state, single-line/range/file anchors, outdated markers, minimized-comment reasons, deleted/unavailable tombstones, and read-only reactions. An outdated thread may display a best-effort local location only when context produces one exact unique match; it remains visibly outdated and its server anchor is not rewritten.
2. Publish inline comments immediately; there is no pending-comment queue. Replies publish immediately inside an existing Review Thread. Top-level Pull Request conversation commenting is not added.
3. Bind a new inline Forge Draft to the displayed head. If the head changes, preserve it and offer only an exact unique re-anchor, requiring explicit confirmation. Invalid, ambiguous, or truncated anchors cannot publish.
4. Resolve/unresolve threads optimistically with a short Undo window. Published comments cannot be edited or deleted.
5. Submit Approve, Comment, or Request Changes from a native formal-review sheet bound to the displayed head. A head change stops submission and requires a refreshed explicit confirmation.
6. Apply one Suggested Change at a time as an unstaged local edit only when the exact Pull Request head is checked out, the target file has no uncommitted edits, and the original context matches. There is no GitX Undo for an applied suggestion.
7. Support Draft/Ready, Close/Reopen, and explicit Update Branch. Update Branch is separate from Merge and never automatic.
8. Show reviewer management read-only and route changes to the browser after creation.
9. Support merge, squash, and rebase methods only when the repository enables them. Remember the last successful method per repository. Merge/squash title and message are editable; rebase shows a read-only summary.
10. Refetch immediately before Merge. Require a fresh open non-draft Pull Request, `viewerCanMerge`, unchanged head/base, and an enabled method. Present blockers as warnings and let GitHub make the authoritative final decision. A changed head/base stops the action and requires reconfirmation.
11. Offer Delete Head Branch after merge only for a same-repository, non-default, non-protected branch with permission and no checked-out safety conflict. The checkbox starts unchecked, remembers the last successful per-repository choice, and is disabled for forks or unsafe branches. Deletion is a separate mutation; its failure does not change merge success and offers Retry/Open in Browser. A queued merge never schedules deletion; once merge is observed, deletion remains a separate explicit action.
12. Support explicit Enter Merge Queue and Leave Merge Queue. Do not add auto-merge, automatic queueing, or queue-change Attention items.
13. After merge, never change the local checkout automatically. Offer explicit Fetch and Check Out Base actions.

Every mutation uses the current effective capability, fresh eligibility state, exact account/repository identity, explicit confirmation where specified, structured logs, cancellation, draft preservation, and post-result reconciliation. GitHub errors remain authoritative and are surfaced without automatic retry.

### Milestone 3 acceptance

- Anchor/re-anchor, thread state, minimized/tombstone rendering, immediate publication, formal review head binding, resolve Undo, suggested-change eligibility/application, lifecycle, Update Branch, merge methods, blocker warnings, refetch races, merge queue, branch deletion, unknown outcomes, and offline/rate-limit behavior have fixture and decision coverage.
- Critical review, suggested-change, lifecycle, merge, queue, and post-merge journeys have focused app-hosted/UI coverage with accessibility identifiers and no fixed sleeps.
- Queue/callback/shared-state work passes the Thread Sanitizer plan; pointer/C/ownership changes, if any, pass Address/Undefined Behavior Sanitizers.
- A named Milestone 3 checkpoint commit passes the full verification matrix, raises all improved baselines, produces the final screenshot set, and refreshes `build/GitX.app`.

## Controller migration sequence

The approved middle-ground conversion keeps dense Cocoa Bindings and responder-chain behavior stable while accepting moderate controller risk:

| Milestone | Controller | Required migration shape |
| --- | --- | --- |
| 0 | `PBGitWindowController` plus Dialogs and ToolbarActions categories | Full Swift replacement after a separate green characterization/header commit; preserve XIB/runtime/selectors |
| 1 | `PBGitSidebarController` | Full Swift replacement after its own preparation commit; preserve source-list Cocoa behavior |
| 2 | `PBGitCommitController` | Full Swift replacement after its own preparation commit; preserve commit/staging wiring and bindings |
| 2 | `PBWebHistoryController` | Full Swift replacement after its own preparation commit; preserve existing queue/generation/cancellation model |
| 0–3 | `PBGitHistoryController` and UI category | Remain Objective-C; extract only low-churn Swift decision seams directly needed by Forge columns and actions |

Each preparation modernizes the affected first-party header with audited nullability and generics, removes its header-debt entry, proves normal/failure/boundary behavior, and reaches at least 90% implementation line coverage. Each conversion is a separate commit, preserves generated Objective-C exposure and XIB identity, migrates the coverage key one-for-one before ratcheting, and receives risk-directed lifecycle, UI, analyzer, sanitizer, and generated-interface checks.

## Test and verification implementation

Use XCTest only.

- Put provider parsing, destination validation, capability, rollup, cache policy, refresh policy, state transitions, merge eligibility, anchor mapping, Markdown sanitization, and retry/cooldown logic in hostless Swift tests.
- Use checked-in GraphQL/REST JSON fixtures and transport fakes. Automated tests never use live GitHub, a developer token, or recorded secrets. A separate optional manual live smoke script may exercise a dedicated test account.
- Test filesystem, Keychain adapters, SQLite migration/recovery, ObjectiveGit, local Git repositories, defaults, notifications, and app composition with focused app-hosted XCTest and isolated temporary state.
- Test XIB wiring, bindings, responder-chain actions, menus, accessibility, source-list/inspector behavior, and critical cross-window workflows through focused app-hosted XCTest and XCUITest.
- Add static Python tests for Apollo/generated-type isolation, credential redaction fixtures, schema/codegen drift, and exact URL/avatar security policy.
- Maintain at least 95% line coverage for handwritten ForgeKit and GitHub adapter code; exclude generated Apollo sources. Completely cover affected normal, failure, and boundary behavior and ratchet the checked-in application/file floors without lowering them.
- Preserve the cached UI budgets of no more than 50 ms p95 for affected view switches and no more than 16 ms of main-thread overlay work. Put stable benchmarks in `GitXPerformance`.
- Use the existing `GitX`, `GitXUI`, `GitXPerformance`, `GitXAddressUndefined`, and `GitXThreadSanitizer` shared plans. Run the analyzer for Objective-C/C-family edits and pinned SwiftLint 0.63.2 and SwiftFormat 0.62.1 through `scripts/run_pinned_tool.sh` for Swift changes.
- Add structured diagnostic logging throughout authentication, binding, refresh, cache, recovery, routing, and mutation state transitions while preserving the redaction boundary.
- At the final PR tip, attach one current diagnostic screenshot set per distinct changed UI surface, grouping related states and workflows. Do not add screenshot or pixel-comparison tests.

At each milestone checkpoint, run focused tests during development, the full correctness plan with fresh coverage, `scripts/check_coverage.py`, `--record-improvements` when coverage rises, static verification, relevant UI/performance/sanitizer plans, analyzer where applicable, and the stable Debug build. Remove stale SwiftLint, header, and analyzer baseline entries in the same checkpoint that fixes them.

## Commit and pull-request delivery

Implementation is one branch and one ready PR against `origin` (`hbmartin/gitx`), never upstream. The PR requests merge-commit integration so its commit sequence is preserved.

The intended commit groups are:

1. current plan, glossary, ADR, and future-work documentation;
2. Milestone 0 window-controller characterization/header preparation;
3. behavior-preserving window-controller Swift conversion;
4. ForgeKit foundation, provider linking, scripting/menu integration, and Milestone 0 checkpoint;
5. Milestone 1 sidebar characterization/header preparation;
6. behavior-preserving sidebar Swift conversion;
7. account/adapter/persistence/read-overlay slices and Milestone 1 checkpoint;
8. Milestone 2 commit-controller characterization/header preparation;
9. behavior-preserving commit-controller Swift conversion;
10. Milestone 2 PBWebHistory characterization/header preparation;
11. behavior-preserving PBWebHistory Swift conversion;
12. Pull Request creation/checkout/deep-link slices and Milestone 2 checkpoint;
13. review/lifecycle/merge slices and Milestone 3 checkpoint; and
14. final verification evidence, grouped diagnostic screenshots, and ready-PR documentation.

Exact development history is preserved. Intermediate commits are not universally required to build or pass the full matrix, but no intentionally failing test is committed, every repository-required characterization/preparation commit is green, and each named milestone checkpoint is fully verified. The PR description lists every verified checkpoint SHA and any known non-buildable intermediate commit so reviewers know which revisions are dependable.

Open the ready PR only after the Milestone 3 tip passes all required checks and `build/GitX.app` is freshly produced from that tip.

## File map

The implementation should normally touch or add these areas:

- `ForgeKit/Package.swift`, `ForgeKit/Sources/ForgeKit/`, `ForgeKit/Sources/GitHubForgeAdapter/`, and their test/fixture directories;
- `Classes/Controllers/ApplicationComposition.swift`, `ApplicationSettings.swift`, `ApplicationPreferencesUI.swift`, and the existing Preferences controller seam;
- `Classes/Controllers/RepositorySettingsController.swift` and `RepositoryRemoteActionCoordinator.swift`;
- the selected window/sidebar/commit/web-history controller sources and headers, `RepositoryToolbarController.swift`, and narrow History presenter/column seams;
- `Resources/en.lproj/RepositoryWindow.xib`, relevant existing XIBs only where required, `Resources/en.lproj/MainMenu.xib`, and `Resources/GitX.sdef`;
- `GitX.xcodeproj/project.pbxproj`, the canonical workspace `Package.resolved`, shared test plans, coverage/header/analyzer baselines, static scripts, and CI workflows; and
- `CONTEXT.md`, ADR-0004 through ADR-0006, and `docs/future_work.md` as the decisions evolve.

Do not modify `External/`, add a testing/analysis dependency, expose Apollo/generated types, redesign `PBGitHistoryController`, replace Cocoa Bindings or responder-chain contracts, or combine PBWebHistory conversion with a concurrency rewrite.

## Definition of done

The comprehensive Milestone 0–3 integration is done only when:

- every accepted native/read/write/review/Attention/status-bar behavior above is present and accessible;
- local Git remains usable during authentication, network, database, partial-data, and rate-limit failure;
- provider, account, repository, public/private cache, and mutation identities cannot cross;
- all automated tests are deterministic and network-free, handwritten Forge code meets its coverage floor, and every baseline is nondecreasing;
- static boundaries prove Apollo/generated types do not leak;
- selected Objective-C controllers have completed their preparation and behavior-preserving Swift conversion workflows;
- the final grouped screenshot set documents every distinct visible surface;
- every required verification plan and script passes at the Milestone 3 checkpoint;
- the final verified app exists at `build/GitX.app`; and
- the single ready PR targets the hbmartin fork, documents checkpoint and known-broken SHAs, and requests a merge commit.
