# Prevent recurring GitX review bugs

Research checked 2026-10-09. This guide explains the local regression workflow and
proposes manual AI review and historical evaluation practices. `AGENTS.md`, the
current scripts, shared test plans, pinned tools and baselines own enforcement.
There is no new CI job, hook, AI runner, service, testing dependency or automatic
mutation execution. Existing test and coverage failures remain blocking; the new
contract and completion reports are advisory.

## What changes the recurrence rate

Convert an accepted review finding into an invariant with an independent oracle,
a named regression test, an appropriate verification plan and a discoverable
contract. Fixing the reported line is only the first part of that process.
Similar faults can enter through another action, configuration or callback order.

[OpenAI's harness engineering account](https://openai.com/index/harness-engineering/)
describes repository knowledge, executable constraints and feedback loops as the
environment that makes agent work reliable. Its progressive disclosure approach
supports keeping this skill's entry point short and loading this reference when
recurrence matters. Those observations are engineering experience, not a measured
guarantee for GitX.

Our application of that approach is a small feedback loop:

1. Retrieve affected contracts before implementing.
2. State the allowed behavior and the smallest fault that violates it.
3. Exercise the real decision boundary or consumer with a meaningful oracle.
4. Review the patch against the invariant, including nearby entry points.
5. Repair accepted findings and validate again at the final commit.
6. Preserve the evidence and update the contract when the protected behavior changes.

Backpressure means the agent must resolve a failed check or report a concrete
blocker before claiming completion. It does not mean adding a human approval step
to every reversible change. Advisory metadata cannot grant permission, waive
tests, authorize a push or change the repository's delivery policy.

## Contract catalogue and local commands

[`scripts/regression-contracts.json`](../../../../scripts/regression-contracts.json)
records stable IDs, families, invariants, causes, production path patterns,
protecting test identifiers, test source, roles, oracle descriptions and canonical
workflow check names. Roles distinguish valid behavior, rejection/failure,
boundaries, interoperability and performance. The seed uses existing meaningful
tests; it is not an inventory of every possible GitX defect.

Run from the checkout you are editing:

```sh
python3 scripts/regression_guardrails.py check --base BASE_REF
python3 scripts/regression_guardrails.py assess --base BASE_REF --receipts artifacts/verification/RUN/workflow.json
```

Replace `BASE_REF` with the inspected integration base and `RUN` with the actual
local verification run. `--receipts` also accepts multiple canonical receipt
paths; a workflow automatically follows its children. `--format json` produces
structured output. `--output` must remain under ignored `artifacts/verification`.
Policy findings return zero; an unreadable catalogue or unresolvable base returns
two. These commands inspect Git and retained evidence; they do not launch tests,
builds, network requests, AI review or mutation testing.

`check` validates metadata and selects contracts from the merge base through
committed, staged and unstaged changes, including both rename paths and new files.
Changing the catalogue selects all contracts. A test-source change selects its
referencing contracts. Unmapped production/test source is reported for review.
Lexical existence of a test method establishes only that a reference can be found;
Debug/Release consumer compilation and actual execution establish stronger facts.
The checker locates Swift class/extension methods and Objective-C implementation
methods. It does not replace either compiler or require converting Objective-C
exception/C tests to satisfy the catalogue. Untracked source absent from canonical
input fingerprints is advisory-incomplete until it is tracked and verified.

`assess` reports required checks and individual protecting XCTest outcomes. Its
states are:

| State | Meaning |
| --- | --- |
| ready | Every selected requirement has current, valid, passing evidence. |
| incomplete | A requirement, named test, coverage gate or valid provenance is missing. |
| failed | Current valid evidence contains a check or test failure. |
| blocked | Current valid evidence identifies an infrastructure/resource blocker. |

Read invalid observations separately: old receipts remain visible but cannot
satisfy current requirements. The assessor compares exact checkout, HEAD, source,
dependency and plan identities, toolchain, relevant products and retained results.
It does not substitute nearby commits, another worktree or a visually identical
app. Skipped/missing tests do not count as passes. Debug and Release outcomes stay
separate. A focused correctness run cannot replace full Debug correctness with
coverage. The latest valid failed check supersedes an earlier valid success;
ambiguous untimed coordination observations are resolved conservatively.

The report's `ready` applies to its selected requirements. Full delivery still
requires the canonical workflow and any additional task-specific checks. A clean
metadata `check` is not completion evidence. A failure observed in an invalid
receipt remains visible as that observation; it does not establish the result
for today's source. Treat receipts as trusted local observations, not a security
boundary against an actor who can rewrite both code and evidence.

## Recurrence taxonomy and independent oracles

| Contract | Recurring cause | What should decide correctness |
| --- | --- | --- |
| PUSH-001 | Retry rebuilt from mutable source/configuration or an implicit lease | Captured intent plus actual bare-remote OID before/after a competing update |
| PUSH-002 | Literal refnames treated as refspec operators; named remote identity lost | Actual remote refs, effective mapping and locally observed hook/transport identity |
| EVENT-001 | Duplicate, reordered or late terminal callbacks | Accepted event log and public operation lifetime across bounded sequences |
| PATH-001 | Unicode/display equality substituted for Git identity | Exact `Data` keys, BOM bytes, invalid UTF-8 and canonically equivalent names |
| PATH-002 | Unsafe pathspecs or validation after some chunks already ran | Actual raw-byte filesystem/index state and no mutation for a rejected selection |
| STATE-001 | Old generation or stale confirmation retains action authority | Current selection/index/content after a deterministically delayed callback |
| STATE-002 | Partial failure returns controls before reconciliation | Actual staged content and observable control state after reconciliation |
| COMMIT-001 | Retry loses prepared fields or confuses HEAD OID with identity | Captured branch/HEAD identity, parents, message, signing and environment |
| COPY-001 | Menu validation protects only one entry point | Pasteboard text, types and change count after menu/responder selections and clicked drag sources |
| PATCH-001 | Wrong parent/format or removal of the last byte | Real Git apply/am and resulting tree ID; exact final content |
| TASK-001 | Leader exit mistaken for EOF; arbitrary drainage cutoffs | Exact accepted bytes, actual exit status and truthful completeness |
| DIAG-001 | Redaction occurs after truncation or misses split/malformed userinfo | Credential absence in both rendered summary and full export, with ordinary text preserved |
| EXPORT-001 | Visibility confused with actual presentation lifetime | Exactly one restored-owner error, and no presentation after real closure |
| ENV-001 | Ambient Git configuration or selectors contaminate fixtures | Isolated environment and actual local repository/hook/input behavior |
| INTEROP-001 | Debug-only declarations or runtime assumptions escape into Release | Both consumer builds and configuration-specific runtime XCTest |

Test positive behavior alongside refusal. A guard that rejects every operation
can pass a collection of rejection-only tests. Likewise, a mock returning the
implementation's expected command string cannot prove a real ref moved safely.
Use a command-spy test for argument construction and a real local Git fixture for
the externally observable result when both facts matter.

## Planning and repair protocol for agents

Before editing, read affected contracts and the existing tests. Record:

```text
Task and integration base:
Affected contract IDs and invariant:
Normal behavior that must continue:
Minimal violating scenario and nearby entry points:
Independent oracle and selected test layer:
Captured identity / generation / lifetime across async boundaries:
Required canonical checks and expected evidence:
```

Use the smallest effective seam. Prefer value decisions, then focused app-hosted
AppKit tests, then XCUITest for critical cross-component flows. Keep responder
chain, bindings, accessibility and rendering in the existing Cocoa owners. A
small relevant seam is within ordinary implementation scope; broad module,
controller or dependency redesign follows the existing approval policy.

For an accepted finding, preserve its reviewed SHA and inspect current HEAD
independently using the development-workflow review provenance tools. Record
whether it was valid at the target, whether it is actionable now, the invariant,
the actual failing scenario and the test that protects the fix. Group duplicates
without deleting their original identities. A changed file alone does not prove
that a finding was fixed.

When meaningful coverage is missing, follow the testing skill's passing
characterization commit, local failing expectation and passing implementation
commit sequence. Do not commit an intentionally failing test. If coverage is
already meaningful, demonstrate the relevant local red/green cycle directly.
After a fix, revisit other callers that share the same assumption. Expand a test
matrix only where it exposes a distinct decision, boundary or entry point.

Do not weaken an assertion, raise a timeout, skip a test, lower a coverage floor
or add a debt-baseline entry merely to make a report green. Diagnose a flaky or
blocked run separately from a product failure. Use observable waits and explicit
gates, and retain failure logs. Stop a repair loop when verification passes, or
when a concrete external prerequisite prevents progress; do not endlessly retry
an unchanged blocker.

## Targeted AI review, manually invoked

AI review is a supplementary search for counterexamples. Its output is a set of
claims to validate, not proof that a patch is safe. Use a fresh review context
with the immutable target, diff, affected contracts, actual consumer behavior
and receipts. Do not lead with the author's confidence or a desired verdict.
Only start another agent or paid reviewer when the user has authorized that work.

Suggested review request:

```text
Review TARGET_SHA against BASE_SHA for contracts IDS. Trace each affected user
entry point and async boundary. Try to violate the invariant while preserving
valid behavior. Prioritize actual wrong refs/paths, stale publication, lost bytes,
credential exposure, premature completion and Debug/Release interop failures.
For each actionable finding provide target file/line, concrete trigger, violated
invariant, observable result, current-HEAD applicability and a minimal independent
regression test. Separate confirmed defects from unresolved hypotheses. Verify
claims against code and evidence; omit cosmetic suggestions and speculative
findings without a feasible trigger. Read test oracles for common assumptions
shared with the implementation. Do not modify files.
```

Give different passes distinct jobs when authorized: state/lifetime review,
Git byte/ref semantics, and AppKit/interop entry points. Parallel generic reviews
can share blind spots and repeat the same assertions. After accepting a finding,
perform the repair protocol and a scoped validation pass on the new immutable
target. Preserve rejected findings with evidence rather than silently dropping
them. The code owner remains responsible for adjudication.

## Historical agent evaluation, manually designed

[Anthropic's agent evaluation guidance](https://www.anthropic.com/engineering/demystifying-evals-for-ai-agents)
separates a task, trial, transcript and externally graded outcome. It also
distinguishes occasional success from repeated reliability. Apply those ideas
to GitX review incidents rather than judging an agent by its final explanation.
This reference supplies a protocol; it does not implement an evaluation runner.

Choose a small set of validated historical bugs from different families. Pin the
pre-fix source, original human request, toolchain and local fixtures. Remove the
answer, later review discussion and implementation commit from the agent's
starting context. Keep evaluation assertions read-only and separate from the
agent's editable tests so changing a test cannot manufacture success. The
maintainer controls that separation in a disposable checkout.

Record each case before a trial:

```text
Case ID / contract / original reviewed SHA:
Original task and permitted scope:
Environment and dependency identities:
Hidden external oracle, valid behavior and failure scenario:
Time/cost limit and permitted tools:
Success criteria, forbidden shortcuts and infrastructure exclusions:
Model/version, harness/skill revision and trial number:
```

Compare the prior instructions with the new contract-guided workflow on the same
cases. Repeat trials when practical; report sample sizes and uncertainty. Grade
the resulting app/repository behavior, required checks and scope adherence.
Inspect transcripts afterward for mechanisms: forgotten entry points, invalid
evidence reuse, test weakening, loss of intent or a productive counterexample.
Never count a blocked environment as a proven product defect or silently remove
an inconvenient failed trial from the denominator.

Suggested measures are recurrence by contract per completed change, externally
graded task success, false completion claims, valid behavior preserved, accepted
review findings, repair rounds and total verification time. Keep flaky tests,
infra blockers and reviewer false positives separate. Establish a baseline before
setting thresholds; raw test count, coverage percentage and reviewer agreement
are inadequate proxies for correctness.

Manual mutation testing can test whether an oracle catches a particular injected
fault. It cannot establish coverage of all possible bugs. Follow the separately
planned maintainer workflow: select a representative historical fault, use a
disposable worktree, show the focused regression rejects it, restore the original
source and confirm green. Do not integrate mutation execution into this command,
normal agent development, CI or a hook. Add no mutation dependency here.

## Swift and macOS boundaries worth reviewing

Actor isolation prevents a class of data races but an `await` can still invalidate
logical assumptions. Capture immutable operation identity, establish consistent
state before suspension and revalidate state before publication. Apple's
[Protect mutable state with Swift actors](https://developer.apple.com/videos/play/wwdc2021/10133/)
explains this reentrancy boundary. Use deterministic callback gates and bounded
sequences to test GitX's observable policy; Thread Sanitizer alone cannot prove it.

Keep AppKit state and completion delivery on the main actor/thread. Avoid waiting
on writer ownership or Git processes from a UI action. Use expectations and
observable state following Apple's
[asynchronous XCTest guidance](https://developer.apple.com/documentation/xctest/asynchronous-tests-and-expectations),
and keep performance checks in the explicit performance plan. Apple recommends
moving lengthy work away from the main thread in
[Improving app responsiveness](https://developer.apple.com/documentation/xcode/improving-app-responsiveness).

During Objective-C/Swift work, treat nullability, lightweight generics, imported
selectors and conditional compilation as consumer contracts. Apple's
[nullability guidance](https://developer.apple.com/documentation/swift/designating-nullability-in-objective-c-apis)
explains how these declarations affect Swift imports. The repository conversion
skill owns preparation coverage, exception/C exclusions and bridge verification.
Compile both Debug and Release consumers before running long suites.

Git's [push documentation](https://git-scm.com/docs/git-push) warns that implicit
force-with-lease expectations can be undermined by background fetches. Prefer the
explicit captured expected OID, with unchanged destination/remote intent. The
[diff documentation](https://git-scm.com/docs/git-diff) describes `-z` path framing;
retain raw bytes for authority and decode only for display. These are Git semantic
contracts even when the caller is written in Swift.

## Handoff, completion and maintenance

Use this compact handoff at interruption, review or completion:

```text
Worktree / branch / base / current HEAD:
Affected contracts and changed behavior:
Passing preparation and implementation commits:
Protecting test IDs and independent oracles:
Canonical runs, receipt paths and observed results:
Current invalid/stale evidence and why:
Concrete blockers or remaining required checks:
Coverage/baseline change and staged Debug app path:
```

Run the canonical serial workflow after the final commit and assess that evidence.
Do not race different suites against the same desktop/products, remove resource
locks or kill another chat's app. A new commit invalidates older evidence. A
coverage policy change also needs refreshed verification. The final signature
verified app remains `build/GitX.app`, displayed as Half Dark.

When a validated new recurrence appears, add or update the narrowest contract and
its protecting test. Keep stable IDs; do not silently recycle them for a different
invariant. Replace renamed test references deliberately. Review unmapped-source
advisories and catalogue staleness during the task that changes the behavior.
Keep research claims separate from GitX policy and refresh source links when
tool capabilities change. Enforce new metadata only after measuring advisory
noise and obtaining an explicit decision to change the rollout policy.
