// @generated
// This file was automatically generated and should not be edited.

import ApolloAPI

extension GitHubAPI.Unions {
  nonisolated static let Assignee = Union(
    name: "Assignee",
    possibleTypes: [
      GitHubAPI.Objects.Bot.self,
      GitHubAPI.Objects.Mannequin.self,
      GitHubAPI.Objects.Organization.self,
      GitHubAPI.Objects.User.self
    ]
  )
}
