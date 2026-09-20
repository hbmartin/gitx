---
name: gitx-runtime-verification
description: Build, launch, observe, and diagnose GitX with the repository's deterministic runtime harness. Use when manually verifying a GitX UI or lifecycle change, reproducing a Milestone 2 or Milestone 3 journey, collecting diagnostic screenshots or accessibility evidence, inspecting live logs, or investigating a launch/runtime failure after XCTest.
---

# GitX Runtime Verification

Use the checked-in launch and observation scripts so a manual run has the same isolated preferences, deterministic repository fixtures, and noninteractive Git environment as the UI tests.

## Start from the verified harness

1. Read `AGENTS.md`, inspect `git status`, and preserve unrelated work.
2. Run the narrowest relevant XCTest first. Runtime inspection supplements XCTest; it does not replace it.
3. Build and launch with `scripts/run_app.sh`. Do not launch the binary directly or reuse the user's preferences and repositories.
4. Select a scenario from [references/scenarios.md](references/scenarios.md) when exercising a Milestone 2 or Milestone 3 journey.

Common launches:

```bash
scripts/run_app.sh
scripts/run_app.sh --no-build
scripts/run_app.sh --m2 push-create
scripts/run_app.sh --m3 lifecycle
scripts/run_app.sh --repo /tmp/existing-repository
```

Use only a repository in an unprotected temporary location unless access prompts are the behavior under test. The harness intentionally isolates preferences and Git configuration. If launch fails, inspect the paths printed by the script before trying a different launch method.

## Observe the recorded process

Use `scripts/observe_app.sh`; it verifies the recorded PID, process start time, executable, and repository window before querying live UI state.

```bash
scripts/observe_app.sh id
scripts/observe_app.sh image
scripts/observe_app.sh see
scripts/observe_app.sh tree Commit
scripts/observe_app.sh logs error
```

- `id` identifies the exact live process and repository window.
- `image` captures an unannotated diagnostic screenshot.
- `see` captures an annotated screenshot and requires observable accessibility elements.
- `tree [pattern]` inspects accessibility state and optionally filters it.
- `logs [pattern]` remains usable after the app exits, so use it for crashes and early termination.

Never substitute a broad app-name lookup for the recorded PID and window id. Never report an old screenshot as fresh: the observer deletes the requested output before capture and fails if no new nonempty file appears.

## Verify observable state

- Wait for UI state by querying `tree`, `see`, or app logs. Do not use arbitrary long sleeps.
- Match the repository window, not the first app window; the Welcome window may appear before deferred document opening finishes.
- Capture a current screenshot for any visible UI change and retain its path with the verification evidence.
- Inspect both os_log and stdout when a flow fails. Add focused logging when the relevant decision cannot otherwise be observed.
- Stop the recorded session with `scripts/run_app.sh --stop`. Do not kill a PID copied from a stale session file.

## Complete verification

After the runtime flow succeeds, run the risk-appropriate shared plans and checks from `$gitx-testing`. Use `scripts/xcodebuild.sh` so the run receives a unique result bundle and receipt. Finish with a staged Debug build at `build/GitX.app` and report the scenario, observable state, log evidence, screenshot paths, and any unverified branch.
