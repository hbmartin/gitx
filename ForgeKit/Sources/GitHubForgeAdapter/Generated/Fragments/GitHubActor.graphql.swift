// @generated
// This file was automatically generated and should not be edited.

import ApolloAPI
@_spi(Execution) @_spi(Unsafe) import ApolloAPI

extension GitHubAPI {
  nonisolated struct GitHubActor: GitHubAPI.SelectionSet, Fragment {
    static var fragmentDefinition: StaticString {
      #"fragment GitHubActor on Actor { __typename login avatarUrl(size: 64) ... on Node { id } ... on User { name } ... on Organization { name } }"#
    }

    let __data: DataDict
    init(_dataDict: DataDict) { __data = _dataDict }

    static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Interfaces.Actor }
    static var __selections: [ApolloAPI.Selection] { [
      .field("__typename", String.self),
      .field("login", String.self),
      .field("avatarUrl", GitHubAPI.URI.self, arguments: ["size": 64]),
      .inlineFragment(AsNode.self),
      .inlineFragment(AsUser.self),
      .inlineFragment(AsOrganization.self),
    ] }
    static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
      GitHubActor.self
    ] }

    var login: String { __data["login"] }
    var avatarUrl: GitHubAPI.URI { __data["avatarUrl"] }

    var asNode: AsNode? { _asInlineFragment() }
    var asUser: AsUser? { _asInlineFragment() }
    var asOrganization: AsOrganization? { _asInlineFragment() }

    /// AsNode
    nonisolated struct AsNode: GitHubAPI.InlineFragment {
      let __data: DataDict
      init(_dataDict: DataDict) { __data = _dataDict }

      typealias RootEntityType = GitHubActor
      static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Interfaces.Node }
      static var __selections: [ApolloAPI.Selection] { [
        .field("id", GitHubAPI.ID.self),
      ] }
      static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
        GitHubActor.self,
        GitHubActor.AsNode.self
      ] }

      var id: GitHubAPI.ID { __data["id"] }
      var login: String { __data["login"] }
      var avatarUrl: GitHubAPI.URI { __data["avatarUrl"] }
    }

    /// AsUser
    nonisolated struct AsUser: GitHubAPI.InlineFragment {
      let __data: DataDict
      init(_dataDict: DataDict) { __data = _dataDict }

      typealias RootEntityType = GitHubActor
      static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.User }
      static var __selections: [ApolloAPI.Selection] { [
        .field("name", String?.self),
      ] }
      static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
        GitHubActor.self,
        GitHubActor.AsUser.self,
        GitHubActor.AsNode.self
      ] }

      var name: String? { __data["name"] }
      var login: String { __data["login"] }
      var avatarUrl: GitHubAPI.URI { __data["avatarUrl"] }
      var id: GitHubAPI.ID { __data["id"] }
    }

    /// AsOrganization
    nonisolated struct AsOrganization: GitHubAPI.InlineFragment {
      let __data: DataDict
      init(_dataDict: DataDict) { __data = _dataDict }

      typealias RootEntityType = GitHubActor
      static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.Organization }
      static var __selections: [ApolloAPI.Selection] { [
        .field("name", String?.self),
      ] }
      static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
        GitHubActor.self,
        GitHubActor.AsOrganization.self,
        GitHubActor.AsNode.self
      ] }

      var name: String? { __data["name"] }
      var login: String { __data["login"] }
      var avatarUrl: GitHubAPI.URI { __data["avatarUrl"] }
      var id: GitHubAPI.ID { __data["id"] }
    }
  }

}
