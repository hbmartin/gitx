// @generated
// This file was automatically generated and should not be edited.

import ApolloAPI

extension GitHubAPI.Unions {
  nonisolated static let SearchResultItem = Union(
    name: "SearchResultItem",
    possibleTypes: [
      GitHubAPI.Objects.App.self,
      GitHubAPI.Objects.Discussion.self,
      GitHubAPI.Objects.Issue.self,
      GitHubAPI.Objects.MarketplaceListing.self,
      GitHubAPI.Objects.Organization.self,
      GitHubAPI.Objects.PullRequest.self,
      GitHubAPI.Objects.Repository.self,
      GitHubAPI.Objects.User.self
    ]
  )
}
