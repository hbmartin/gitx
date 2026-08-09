---
name: gitx-runtime-verification
description: Run GitX and verify behavior against the real running app rather than tests alone. Use whenever confirming a change works end to end, reproducing or diagnosing a reported bug, inspecting runtime logging, capturing or refreshing diagnostic screenshots, driving the UI to reach a state, or answering what the app actually does at runtime. Covers the deterministic launch harness, fixture repositories, Milestone 2 and 3 scenarios, Peekaboo observation and input, os_log and stderr reading, and turning a red build or test run into a short failure report.
---

# GitX Runtime Verification

Tests prove a decision; the running app proves the feature. This skill covers the
second half. It is the manual counterpart to the XCUITest suites and deliberately
reuses their launch environment, so what you observe by hand matches what CI sees.

This skill does not replace `$gitx-testing`. Load that one for test design,
coverage, plans, and the commit-boundary rules. Load this one when you need to
see, drive, or listen to the app.

## Never build with bare xcodebuild

`scripts/xcodebuild.sh` is the only sanctioned build entry point. It pins the
stable Xcode (the selected one may be a beta that cannot build this workspace),
pins `-derivedDataPath build/DerivedData` so the cache stays warm across
worktrees and sessions, shapes output through xcbeautify, and keeps the full log
at `build/Logs/last-xcodebuild.log`.

```sh
scripts/xcodebuild.sh build                     # defaults: GitX workspace, GitX scheme, macOS arm64
scripts/xcodebuild.sh --stage-app build         # also refresh build/GitX.app
scripts/xcodebuild.sh test -testPlan GitX       # result bundle at build/Logs/last-test.xcresult
```

Never pass an ad-hoc `-derivedDataPath`. Per-session derived data turns a ~5s
warm build into a ~60s cold build and leaks gigabytes.

After a red run, do not read raw xcodebuild output. Run:

```sh
scripts/report_xcresult.py build/Logs/last-test.xcresult
```

It prints only failures: a count header, then each failing test with its
`path/File.swift:LINE: message` lines indented beneath it (runner-level failures
may carry no source location). `--full` disables truncation; `--format json` is
available for scripting.

## Launch the app

```sh
scripts/run_app.sh                    # build, then launch on a fresh fixture repository
scripts/run_app.sh --no-build         # relaunch using the current build/GitX.app
scripts/run_app.sh --m3 review        # deterministic Milestone 3 journey
scripts/run_app.sh --repo /tmp/thing  # open an existing repository
scripts/run_app.sh --stop             # terminate the app and the log stream
```

`run_app.sh` starts the os_log stream *before* the app so startup logging is
never missed, launches with the same arguments and environment the XCUITests
use, waits for the repository window to appear rather than sleeping, and writes
`build/Logs/run-app/session.txt` describing the session.

The generated fixture and the isolated preferences home both live under
`$TMPDIR`. Keep it that way. `$TMPDIR` is not a TCC-protected location, so a
debug-signed build never triggers a consent prompt there. Pointing `--repo` at an
external volume, Desktop, Documents, or Downloads reintroduces prompts, and a
prompt that is answered "Don't Allow" once will deny silently forever after.
`--reset-tcc` clears such a stale decision; it does not prevent prompts.

Read [references/scenarios.md](references/scenarios.md) for the Milestone 2 and 3
scenario names and the environment contract behind them.

## Observe the app

```sh
scripts/observe_app.sh image          # screenshot the repository window
scripts/observe_app.sh see            # annotated screenshot plus element ids
scripts/observe_app.sh tree           # actionable elements with accessibility identifiers
scripts/observe_app.sh tree branch    # only rows matching a pattern
scripts/observe_app.sh logs           # tail both log streams
scripts/observe_app.sh logs error     # grep both log streams
```

Then **read the PNG**. A screenshot you did not open is not evidence. Use the
Read tool on the path `observe_app.sh image` prints; it renders images.

Target windows by id, never by title. GitX rewrites its title as commits load
(`repo (branch: main)` becomes `... - 3 commits loaded`), so a title resolved a
moment earlier is already stale. `observe_app.sh` resolves the id for you.

`tree` prints the accessibility identifier column. Those identifiers are the same
selectors the XCUITests use, so a state you reach by hand is directly expressible
as a test. Prefer them over labels, which are localized and volatile.

## Drive the app

Use `see` or `tree` to get element ids, then act on them:

```sh
peekaboo click --app "PID:$(awk -F= '/^app_pid=/{print $2}' build/Logs/run-app/session.txt)" --on elem_10
peekaboo type "text"
peekaboo hotkey cmd,s
```

Re-snapshot after any navigation, sheet, or scroll: element ids are only valid
for the snapshot that produced them. Wait for observable state rather than
sleeping, exactly as the UI tests do.

Peekaboo needs Screen Recording and Accessibility granted to the *controlling*
terminal, not to GitX.

## Read the logs

GitX logs through two channels and reading only one hides half the story:

- `os_log` via `Logger`/`os_log`, subsystems `com.gitx.gitx` and
  `com.gitx.ForgeKit`, captured to `build/Logs/run-app/gitx-oslog.txt`;
- `NSLog`, which reaches stderr, captured to `build/Logs/run-app/gitx-stdout.txt`.

`observe_app.sh logs` always consults both. Categories are meaningful
(`ForgeCredentialRefresh`, `AttentionInbox`, `DiffDocumentParser`, and others);
grep by category to follow one subsystem.

When adding logging for a change you are verifying, prefer `Logger` with an
existing subsystem and a specific category over `NSLog`, and mark values that may
carry repository or account content with an explicit privacy level.

## Report what you observed

State the scenario and fixture, the observed behavior, the screenshot path you
opened, and the log lines that corroborate it. Distinguish what you saw from what
you inferred. If the app behaved correctly but a log line contradicted the UI,
say so; that gap is usually the real defect.

Screenshots taken this way are diagnostic evidence. Do not add screenshot or
pixel comparison testing.
