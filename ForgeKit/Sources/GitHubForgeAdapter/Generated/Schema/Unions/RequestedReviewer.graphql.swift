// @generated
// This file was automatically generated and should not be edited.

import ApolloAPI

extension GitHubAPI.Unions {
  nonisolated static let RequestedReviewer = Union(
    name: "RequestedReviewer",
    possibleTypes: [
      GitHubAPI.Objects.Bot.self,
      GitHubAPI.Objects.EnterpriseTeam.self,
      GitHubAPI.Objects.Mannequin.self,
      GitHubAPI.Objects.Team.self,
      GitHubAPI.Objects.User.self
    ]
  )
}
