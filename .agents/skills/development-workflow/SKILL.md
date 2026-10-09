---
name: development-workflow
description: Coordinate GitX local verification, work ownership and exact review provenance. Use for development verification, recovery inventories, cleanup planning or review reconciliation.
---

Use `scripts/dev_workflow.py` as the local coordinator. Existing entrypoints remain supported and acquire the same resource leases. Local Xcode evidence is authoritative; do not change CI, account permissions, or desktop lock settings to resolve local blockers.

## Verification

- `python3 scripts/dev_workflow.py verify --profile full` runs static checks, interoperability settings, Debug/Release test compilation, correctness/coverage, package checks, sanitizers, UI activation/workflows, Release performance, fresh analysis and Debug staging serially.
- Use `--check NAME` for iteration. Partial checks do not satisfy full delivery. `--timeout SECONDS` sets each command's backstop (default two hours).
- `verify --resume RUN-ID` reuses only passed checks with matching source, commit, dependencies, plans, toolchain, products and results. A commit invalidates prior evidence; resume cannot replace required post-commit verification.
- Exit 75 means a resource belongs to another session. Read the owning run/receipt; wait or interrupt its owner. Never remove lock files or kill unrelated GitX processes.
- Read blocker diagnostics and logs. An unknown host startup timeout remains unknown. Wake/unlock the local desktop when explicitly reported; preserve genuine test failures.
- Defaults are internal caches under `~/Library/Caches/GitX/Verification`, partitioned by checkout, Xcode, configuration and instrumentation. `GITX_VERIFICATION_CACHE_ROOT` relocates this hierarchy while preserving its partitions; relative roots resolve against the checkout. Explicit `GITX_DERIVED_DATA`, `GITX_SWIFTPM_BUILD_ROOT` and `GITX_SOURCE_PACKAGE_CACHE` paths take precedence and are resolved and recorded.
- Correctness compilation uses atomic Swift and Clang coverage counter updates, including its host probe. Effective compiler flags appear in receipts; the `correctness-atomic` product partition separates them from older instrumentation. Performance, sanitizer and ordinary build instrumentation remain unchanged. A counter-mode change is measurement evidence, not an automatic reason to ratchet floors. Preserve failed coverage gates and never relax floors to accommodate inaccurate historical counts.
- Review the non-mutating coverage proposal. Ratchet with `scripts/check_coverage.py RESULT --receipt RECEIPT --record-improvements` from one complete passed correctness run with valid evidence, then run the plain checker. New files need explicit policy admission; conversion paths preserve existing floors. Invalid evidence never relaxes policy.
- Deliver the signature-verified `build/GitX.app`; its displayed name remains Half Dark.
- Use `python3 scripts/regression_guardrails.py assess --base REF --receipts artifacts/verification/RUN/workflow.json` for an advisory assessment of affected regression contracts. Missing/skipped tests, focused-only execution and stale provenance cannot establish readiness. Read [agentic regression prevention](../gitx-testing/references/agentic-regression-prevention.md) for contract maintenance, targeted AI review and manual historical evaluation. The report does not replace the canonical full profile or task-specific checks.

## Work ownership and recovery

`work inventory`, `work register ID --purpose TEXT --owner OWNER --chat CHAT`, `work update ID --owner OWNER --changes JSON`, `work seed MANIFEST`, and `work export --output JSON` maintain the atomic ledger under the common Git directory. All worktrees share it. Inventories and exports belong in ignored artifacts. `work import JSON` restores non-conflicting metadata.

Before cleanup, inspect ownership, dirty state, recovery checksums and integration evidence. Protect work belonging to other chats. Ancestry and patch equivalence are observed Git facts; they do not establish feature equivalence. Archived or uncertain items need review. Inventory commands do not delete checkouts or recover features.

## Review provenance

`review prepare FEEDBACK.json --output RECORD.json [--target SHA]` accepts GitHub feedback JSON; add `--pasted` for text. Resolve the reviewed commit from original comment metadata or an explicit target. Missing/unresolvable targets produce `needs-target`; pause classification and present candidates. Never substitute HEAD.

Inspect each comment at its frozen reviewed SHA and independently at current HEAD. Use `review reconcile RECORD.json --decisions DECISIONS.json` to record `id`, `reviewedSHA`, `currentHEAD`, `validityAtTarget`, `currentActionability`, `evidence`, `disposition` and optional `implementingCommit`. Duplicate groups retain every comment. HEAD changes require `--refresh` and refreshed decisions. File differences alone do not establish whether feedback is valid or fixed. Preserve the personal triage skill unchanged.
