// @generated
// This file was automatically generated and should not be edited.

import ApolloAPI
@_spi(Execution) @_spi(Unsafe) import ApolloAPI

extension GitHubAPI {
  nonisolated struct GitHubMilestone: GitHubAPI.SelectionSet, Fragment {
    static var fragmentDefinition: StaticString {
      #"fragment GitHubMilestone on Milestone { __typename id number title description state dueOn }"#
    }

    let __data: DataDict
    init(_dataDict: DataDict) { __data = _dataDict }

    static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.Milestone }
    static var __selections: [ApolloAPI.Selection] { [
      .field("__typename", String.self),
      .field("id", GitHubAPI.ID.self),
      .field("number", Int.self),
      .field("title", String.self),
      .field("description", String?.self),
      .field("state", GraphQLEnum<GitHubAPI.MilestoneState>.self),
      .field("dueOn", GitHubAPI.DateTime?.self),
    ] }
    static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
      GitHubMilestone.self
    ] }

    var id: GitHubAPI.ID { __data["id"] }
    var number: Int { __data["number"] }
    var title: String { __data["title"] }
    var description: String? { __data["description"] }
    var state: GraphQLEnum<GitHubAPI.MilestoneState> { __data["state"] }
    var dueOn: GitHubAPI.DateTime? { __data["dueOn"] }
  }

}
