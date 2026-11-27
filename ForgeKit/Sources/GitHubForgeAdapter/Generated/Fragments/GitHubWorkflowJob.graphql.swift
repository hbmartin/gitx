// @generated
// This file was automatically generated and should not be edited.

import ApolloAPI
@_spi(Execution) @_spi(Unsafe) import ApolloAPI

extension GitHubAPI {
  nonisolated struct GitHubWorkflowJob: GitHubAPI.SelectionSet, Fragment {
    static var fragmentDefinition: StaticString {
      #"fragment GitHubWorkflowJob on CheckRun { __typename id databaseId name status conclusion detailsUrl startedAt completedAt }"#
    }

    let __data: DataDict
    init(_dataDict: DataDict) { __data = _dataDict }

    static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.CheckRun }
    static var __selections: [ApolloAPI.Selection] { [
      .field("__typename", String.self),
      .field("id", GitHubAPI.ID.self),
      .field("databaseId", Int?.self),
      .field("name", String.self),
      .field("status", GraphQLEnum<GitHubAPI.CheckStatusState>.self),
      .field("conclusion", GraphQLEnum<GitHubAPI.CheckConclusionState>?.self),
      .field("detailsUrl", GitHubAPI.URI?.self),
      .field("startedAt", GitHubAPI.DateTime?.self),
      .field("completedAt", GitHubAPI.DateTime?.self),
    ] }
    static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
      GitHubWorkflowJob.self
    ] }

    var id: GitHubAPI.ID { __data["id"] }
    var databaseId: Int? { __data["databaseId"] }
    var name: String { __data["name"] }
    var status: GraphQLEnum<GitHubAPI.CheckStatusState> { __data["status"] }
    var conclusion: GraphQLEnum<GitHubAPI.CheckConclusionState>? { __data["conclusion"] }
    var detailsUrl: GitHubAPI.URI? { __data["detailsUrl"] }
    var startedAt: GitHubAPI.DateTime? { __data["startedAt"] }
    var completedAt: GitHubAPI.DateTime? { __data["completedAt"] }
  }

}
