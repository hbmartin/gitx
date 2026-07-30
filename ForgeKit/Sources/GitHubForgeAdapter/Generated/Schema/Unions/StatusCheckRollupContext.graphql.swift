// @generated
// This file was automatically generated and should not be edited.

import ApolloAPI

extension GitHubAPI.Unions {
  nonisolated static let StatusCheckRollupContext = Union(
    name: "StatusCheckRollupContext",
    possibleTypes: [
      GitHubAPI.Objects.CheckRun.self,
      GitHubAPI.Objects.StatusContext.self
    ]
  )
}
