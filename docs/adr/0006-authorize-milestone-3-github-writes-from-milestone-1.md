# Authorize Milestone 3 GitHub writes from Milestone 1

GitX's first authenticated GitHub release will request the complete permission envelope needed through Milestone 3: Metadata read, Contents write, Pull Requests write, Issues write, Checks read, and Commit Statuses read. Issues remain read-only in GitX through Milestone 3, but their write permission is reserved for the planned expansion so installations receive one predictable authorization contract instead of repeated permission-elevation prompts.

| Shipped surface | GitHub App repository permission | Credential | Fallback when unavailable |
| --- | --- | --- | --- |
| Repository identity and binding | Metadata: read | Installation access token narrowed to the selected repository | Keep the local repository available and leave Forge identity unavailable. |
| Repository file reads and mutations | Contents: write | Installation access token narrowed to the selected repository | Keep local content available; disable Forge-backed content mutations. |
| Pull Request metadata, reviews, and mutations | Pull requests: write | Installation access token narrowed to the selected repository | Preserve any readable Pull Request overlay; disable unavailable mutations. |
| Issue metadata and comments | Issues: write | Installation access token narrowed to the selected repository | Preserve read-only Issue data when effective access permits; otherwise hide the Issue surface. |
| Check Rollups | Checks: read | Installation access token narrowed to the selected repository | Show check state as unavailable without blocking local Git operations. |
| Commit Status Rollups | Commit statuses: read | Installation access token narrowed to the selected repository | Show commit status as unavailable without blocking local Git operations. |

GitHub CLI and personal access token credentials may support the same surfaces only when GitX can map their detected scopes and effective repository access to this matrix. Unknown or unverifiable access is treated as unavailable.

GitX will still derive each feature's availability from the credential's effective permissions and the authenticated user's repository role. Requesting the envelope does not make a mutation eligible: unavailable operations remain disabled, every destructive or consequential action requires its specified confirmation, and rejected installation upgrades remain usable for the capabilities their effective permissions allow.

The Attention Inbox does not request notification permission because it derives actionable state from accessible Pull Requests, reviews, checks, mentions, and assignments rather than using GitHub's classic-PAT-only Notifications API. Selected-repository installation access, one Credential per Forge Account, per-account Keychain storage, and explicit mutation confirmation constrain the broader authorization.
