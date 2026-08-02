// @generated
// This file was automatically generated and should not be edited.

import ApolloAPI
@_spi(Execution) @_spi(Unsafe) import ApolloAPI

extension GitHubAPI {
  nonisolated struct GitHubPageInfo: GitHubAPI.SelectionSet, Fragment {
    static var fragmentDefinition: StaticString {
      #"fragment GitHubPageInfo on PageInfo { __typename hasPreviousPage startCursor hasNextPage endCursor }"#
    }

    let __data: DataDict
    init(_dataDict: DataDict) { __data = _dataDict }

    static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.PageInfo }
    static var __selections: [ApolloAPI.Selection] { [
      .field("__typename", String.self),
      .field("hasPreviousPage", Bool.self),
      .field("startCursor", String?.self),
      .field("hasNextPage", Bool.self),
      .field("endCursor", String?.self),
    ] }
    static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
      GitHubPageInfo.self
    ] }

    var hasPreviousPage: Bool { __data["hasPreviousPage"] }
    var startCursor: String? { __data["startCursor"] }
    var hasNextPage: Bool { __data["hasNextPage"] }
    var endCursor: String? { __data["endCursor"] }
  }

}
