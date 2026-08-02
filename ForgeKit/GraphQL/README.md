# GitHub GraphQL inputs

`schema.graphqls` is a checked-in snapshot of the GitHub.com public GraphQL
schema. `Operations` contains only Milestone 1 read operations. Generated Swift
sources are checked in under `Sources/GitHubForgeAdapter/Generated` and remain
an internal implementation detail of that target.

Regenerate from the checked-in schema without network access:

```sh
APOLLO_IOS_CLI=/path/to/apollo-ios-cli scripts/generate_graphql.sh --offline
```

Explicitly refresh the schema with the authenticated GitHub CLI, then regenerate:

```sh
APOLLO_IOS_CLI=/path/to/apollo-ios-cli scripts/update_github_graphql.sh
```

Both scripts require Apollo iOS CLI 2.3.0. The refresh script asks `gh` to make
the authenticated request and never reads or prints the credential itself.
