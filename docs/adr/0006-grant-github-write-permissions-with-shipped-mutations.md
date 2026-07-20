# Grant GitHub write permissions only with shipped mutations

GitX's first authenticated GitHub release will request only the read permissions required by its shipped Pull Request, Issue, and repository-content surfaces. It will not request Contents, Pull Requests, or Issues write access before a corresponding mutation is available.

Each write permission will be added when its feature ships. Installation owners must explicitly approve that elevation, and installations that do not approve it remain read-only. GitX must derive feature availability from the credential's effective permissions rather than assuming that every account accepted a requested upgrade.

When GitX can narrow a credential or installation token, it will request an explicit repository and permission subset instead of inheriting the GitHub App's complete permission envelope. Selected-repository installation access, per-account Keychain storage, and mutation confirmation remain defense in depth; none substitutes for limiting the credential's authority.
