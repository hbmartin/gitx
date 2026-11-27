// @generated
// This file was automatically generated and should not be edited.

import ApolloAPI
@_spi(Execution) @_spi(Unsafe) import ApolloAPI

extension GitHubAPI {
  nonisolated struct GitHubWorkflowCheckSuite: GitHubAPI.SelectionSet, Fragment {
    static var fragmentDefinition: StaticString {
      #"fragment GitHubWorkflowCheckSuite on CheckSuite { __typename id status conclusion updatedAt app { __typename name slug } }"#
    }

    let __data: DataDict
    init(_dataDict: DataDict) { __data = _dataDict }

    static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.CheckSuite }
    static var __selections: [ApolloAPI.Selection] { [
      .field("__typename", String.self),
      .field("id", GitHubAPI.ID.self),
      .field("status", GraphQLEnum<GitHubAPI.CheckStatusState>.self),
      .field("conclusion", GraphQLEnum<GitHubAPI.CheckConclusionState>?.self),
      .field("updatedAt", GitHubAPI.DateTime.self),
      .field("app", App?.self),
    ] }
    static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
      GitHubWorkflowCheckSuite.self
    ] }

    var id: GitHubAPI.ID { __data["id"] }
    var status: GraphQLEnum<GitHubAPI.CheckStatusState> { __data["status"] }
    var conclusion: GraphQLEnum<GitHubAPI.CheckConclusionState>? { __data["conclusion"] }
    var updatedAt: GitHubAPI.DateTime { __data["updatedAt"] }
    var app: App? { __data["app"] }

    /// App
    nonisolated struct App: GitHubAPI.SelectionSet {
      let __data: DataDict
      init(_dataDict: DataDict) { __data = _dataDict }

      static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.App }
      static var __selections: [ApolloAPI.Selection] { [
        .field("__typename", String.self),
        .field("name", String.self),
        .field("slug", String.self),
      ] }
      static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
        GitHubWorkflowCheckSuite.App.self
      ] }

      var name: String { __data["name"] }
      var slug: String { __data["slug"] }
    }
  }

}
