# Authorize Milestone 3 GitHub writes from Milestone 1

GitX's first authenticated GitHub.com release will request the complete permission envelope needed through Milestone 3: Metadata read, Contents write, Pull Requests write, Issues write, Checks read, and Commit Statuses read. Issues remain read-only in GitX through Milestone 3, but their write permission is reserved for the planned expansion so installations receive one predictable authorization contract instead of repeated permission-elevation prompts. Authenticated native GitHub Enterprise Server API support is outside Milestones 0–3.

| Shipped surface | GitHub App repository permission | Credential | Fallback when unavailable |
| --- | --- | --- | --- |
| Repository identity and binding | Metadata: read | GitHub App user access token | Keep the local repository available and leave Forge identity unavailable. |
| Repository file reads and mutations | Contents: write | GitHub App user access token | Keep local content available; disable Forge-backed content mutations. |
| Pull Request metadata, reviews, and mutations | Pull requests: write | GitHub App user access token | Preserve any readable Pull Request overlay; disable unavailable mutations. |
| Issue metadata and comments | Issues: write | GitHub App user access token | Preserve read-only Issue data when effective access permits; otherwise hide the Issue surface. |
| Check Rollups | Checks: read | GitHub App user access token | Show check state as unavailable without blocking local Git operations. |
| Commit Status Rollups | Commit statuses: read | GitHub App user access token | Show commit status as unavailable without blocking local Git operations. |

GitX is a public native client and will never ship a GitHub App private key, mint installation access tokens, or depend on a token-broker backend. Device flow yields a user access token whose effective authority is the intersection of the App's requested permissions, repositories granted to the App's installations, and the authenticated user's own access. User-initiated activity is therefore attributed to that user. Repository selection happens through App installation access and Forge Repository Binding; GitX does not claim to narrow a reusable user token into a per-request installation token.

GitHub CLI and personal access token credentials may support the same surfaces when GitX can map their detected scopes and effective repository access to this matrix. Known insufficiency is unavailable. When a fine-grained personal access token's write grant cannot be introspected, GitX represents the affected repository capability as **Unverified Write** instead of treating it as missing.

Unverified Write never overrides a known missing scope, denied repository, inadequate user role, branch rule, or other server-reported restriction. The operation remains subject to its normal explicit confirmation, then GitHub makes the authoritative authorization decision. A successful operation promotes that credential/repository/capability tuple to verified until the credential changes or a later authorization response invalidates it; failure preserves the user's draft or local state and surfaces the server response without automatic retry.

GitX will still derive each feature's availability from the credential's effective permissions and the authenticated user's repository role. Requesting the envelope does not make a mutation eligible: unavailable operations remain disabled, every destructive or consequential action requires its specified confirmation, and rejected installation upgrades remain usable for the capabilities their effective permissions allow.

The Attention Inbox does not request notification permission because it derives actionable state from accessible Pull Requests, reviews, checks, mentions, and assignments rather than using GitHub's classic-PAT-only Notifications API. Selected-repository installation access, one Credential per Forge Account, per-account Keychain storage, and explicit mutation confirmation constrain the broader authorization.
