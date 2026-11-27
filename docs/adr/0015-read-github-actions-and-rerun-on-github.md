# Read GitHub Actions and rerun failed jobs on GitHub

GitX shows a pull request's checks as Workflow Runs, Workflow Jobs and their steps. To name the workflow run behind a GitHub Actions check suite, the GitHub App adds one repository permission to the envelope in ADR 0006: **Actions: read**. GitX makes no native Actions mutation. "Re-run Failed Jobs on GitHub…" opens the run on GitHub, where the person confirms the rerun with GitHub's own authorization. Job logs, `workflow_dispatch`, cancellation and native reruns stay deferred.

| Shipped surface | GitHub App repository permission | Fallback when unavailable |
| --- | --- | --- |
| Check suites, jobs and steps | Checks: read (ADR 0006) | Keep the existing check rollup in Details. |
| Workflow run name, number, attempt and page | Actions: read | Group jobs by check suite without run details; jobs still open their pages on GitHub; offer "Review App Permissions on GitHub…". |

Installations accepted under ADR 0006 do not grant Actions: read until their owner approves the upgraded request. Until then, GitX cannot know from its stored evidence whether a GitHub App user token can read Actions. Such a read is an **Unverified Read**: GitX asks for the workflow run in a separate, on-demand GraphQL read that never shares a request with pull request details, so a refusal cannot make the pull request read partial. An answer that includes a workflow run promotes the credential/repository/operation tuple to verified for the session. A `FORBIDDEN` error on a workflow run path records the tuple as denied, and GitX stops asking for workflow runs until the credential changes. Any other error leaves the tuple unverified and the answer partial. A commit without GitHub Actions suites proves nothing either way.

Unverified Read never overrides known evidence. Fine-grained personal access tokens use their reported `actions` permission. Classic tokens and the GitHub CLI read Actions with the full `repo` scope, or with `public_repo` on a public repository.

GitX reads workflow runs only when a pull request inspector or the Attention "Show Failed Jobs…" sheet shows them. Answers are cached per head commit until Refresh or a credential change; nothing polls. While GitHub is rate limiting the credential, Refresh is disabled and says until when.

Workflow Run and Workflow Job destinations are GitHub.com-only. They open in the browser and are not part of GitX's own deep links.
