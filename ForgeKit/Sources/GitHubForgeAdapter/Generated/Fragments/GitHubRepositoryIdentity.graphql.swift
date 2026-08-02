// @generated
// This file was automatically generated and should not be edited.

import ApolloAPI
@_spi(Execution) @_spi(Unsafe) import ApolloAPI

extension GitHubAPI {
  nonisolated struct GitHubRepositoryIdentity: GitHubAPI.SelectionSet, Fragment {
    static var fragmentDefinition: StaticString {
      #"fragment GitHubRepositoryIdentity on Repository { __typename id name nameWithOwner owner { __typename login } }"#
    }

    let __data: DataDict
    init(_dataDict: DataDict) { __data = _dataDict }

    static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.Repository }
    static var __selections: [ApolloAPI.Selection] { [
      .field("__typename", String.self),
      .field("id", GitHubAPI.ID.self),
      .field("name", String.self),
      .field("nameWithOwner", String.self),
      .field("owner", Owner.self),
    ] }
    static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
      GitHubRepositoryIdentity.self
    ] }

    var id: GitHubAPI.ID { __data["id"] }
    var name: String { __data["name"] }
    var nameWithOwner: String { __data["nameWithOwner"] }
    var owner: Owner { __data["owner"] }

    /// Owner
    nonisolated struct Owner: GitHubAPI.SelectionSet {
      let __data: DataDict
      init(_dataDict: DataDict) { __data = _dataDict }

      static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Interfaces.RepositoryOwner }
      static var __selections: [ApolloAPI.Selection] { [
        .field("__typename", String.self),
        .field("login", String.self),
      ] }
      static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
        GitHubRepositoryIdentity.Owner.self
      ] }

      var login: String { __data["login"] }
    }
  }

}
