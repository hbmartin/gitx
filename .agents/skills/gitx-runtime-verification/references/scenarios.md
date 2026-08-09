# Launch scenarios and the environment contract

`scripts/run_app.sh` reproduces the launch environment defined by the XCUITest
suites. This file records what the app actually reads, so the harness and the
tests cannot drift apart silently. Verify against the sources before relying on
anything here:

- `Classes/Controllers/ApplicationController.m` (repository opening)
- `Classes/Controllers/Milestone2UITestHarness.swift`
- `Classes/Controllers/Milestone3UITestHarness.swift`
- `Classes/Views/Milestone3DiagnosticPresenters.swift` (journey raw values)

## Environment variables the app reads

| Variable | Effect |
| --- | --- |
| `GITX_UITEST_REPO` | Opens this repository on launch and suppresses the untitled-file and session-restore paths. |
| `GITX_M2_UITEST=1` | Installs the Milestone 2 harness. |
| `GITX_M2_SCENARIO` | Selects the Milestone 2 journey. |
| `GITX_M2_EXPECTED_HEAD` | Required by `exact-checkout`. |
| `GITX_M2_CHECKOUT_REMOTE` | Required by `exact-checkout`. |
| `GITX_M2_DEEP_LINK` | Required by the deep-link journeys. |
| `GITX_M3_UITEST=1` | Installs the Milestone 3 harness. |
| `GITX_M3_SCENARIO` | Selects the Milestone 3 journey. |

Isolation variables (`CFFIXED_USER_HOME`, `CFPREFERENCES_AVOID_DAEMON`,
`GIT_CONFIG_GLOBAL=/dev/null`, `GIT_CONFIG_NOSYSTEM`, `GIT_TERMINAL_PROMPT=0`,
`GIT_ASKPASS=/usr/bin/false`, `GCM_INTERACTIVE=never`) keep a run from reading or
writing real preferences, real Git configuration, or real credentials. Do not
drop them to "make it work"; a run that needs them removed is not reproducing
what CI does.

## Milestone 2 scenarios

`--m2 <name>`, from the `Scenario` enum in `Milestone2UITestHarness.swift`:

`push-create`, `existing-pull-request`, `exact-checkout`, `deep-link`,
`deep-link-no-checkout`, `staging-create`, `sync-fork`

`exact-checkout` and the deep-link journeys need the extra variables above, so
they are not reachable through `run_app.sh` flags alone. Set them in the
environment before invoking the script, or drive that journey through its
XCUITest instead.

## Milestone 3 scenarios

`--m3 <name>`, from `Milestone3DiagnosticJourney`:

`review`, `suggested-change`, `lifecycle`, `merge`, `queue-delete`, `post-merge`

The harness publishes a readiness marker of the form `Ready.<scenario>`, which is
what the UI tests wait on. If a scenario never becomes ready, the harness logs
the reason under category `Milestone3UITestHarness`; check
`scripts/observe_app.sh logs Milestone3` before assuming a UI problem.

## The generated fixture

With no `--repo`, `run_app.sh` builds a deterministic repository under `$TMPDIR`:

- two commits on `main` (`Add the fixture readme`, `Add an answer that is off by one`);
- one commit on `topic` (`Correct the answer`) so branch and graph rendering have content;
- one modified tracked file and one untracked file, so the Staging Pane is not empty.

Author, committer, and dates are fixed, so commit ids are stable across runs.
A correct launch reports `3 commits loaded` and `1 unstaged, 1 untracked`; if it
does not, the fixture or the repository-open path changed.

## Known launch behavior

The Welcome window can appear alongside the repository window. Suppression is
applied in `applicationShouldOpenUntitledFile` and in the window-session
coordinator, but `applicationDidBecomeActive` calls `showIfNeeded()` without the
`GITX_UITEST_REPO` guard, and it races the deferred document open. Target the
repository window by id and this is harmless; do not treat the Welcome window's
presence as the state under test.
