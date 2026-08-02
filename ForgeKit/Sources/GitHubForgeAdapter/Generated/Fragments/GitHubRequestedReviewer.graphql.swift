// @generated
// This file was automatically generated and should not be edited.

import ApolloAPI
@_spi(Execution) @_spi(Unsafe) import ApolloAPI

extension GitHubAPI {
  nonisolated struct GitHubRequestedReviewer: GitHubAPI.SelectionSet, Fragment {
    static var fragmentDefinition: StaticString {
      #"fragment GitHubRequestedReviewer on RequestedReviewer { __typename ... on Actor { ...GitHubActor } ... on Mannequin { mannequinID: id mannequinLogin: login mannequinAvatarURL: avatarUrl(size: 64) } ... on Team { teamID: id teamName: name teamSlug: slug teamAvatarURL: avatarUrl } }"#
    }

    let __data: DataDict
    init(_dataDict: DataDict) { __data = _dataDict }

    static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Unions.RequestedReviewer }
    static var __selections: [ApolloAPI.Selection] { [
      .field("__typename", String.self),
      .inlineFragment(AsActor.self),
      .inlineFragment(AsMannequin.self),
      .inlineFragment(AsTeam.self),
    ] }
    static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
      GitHubRequestedReviewer.self
    ] }

    var asActor: AsActor? { _asInlineFragment() }
    var asMannequin: AsMannequin? { _asInlineFragment() }
    var asTeam: AsTeam? { _asInlineFragment() }

    /// AsActor
    nonisolated struct AsActor: GitHubAPI.InlineFragment {
      let __data: DataDict
      init(_dataDict: DataDict) { __data = _dataDict }

      typealias RootEntityType = GitHubRequestedReviewer
      static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Interfaces.Actor }
      static var __selections: [ApolloAPI.Selection] { [
        .fragment(GitHubActor.self),
      ] }
      static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
        GitHubRequestedReviewer.self,
        GitHubRequestedReviewer.AsActor.self,
        GitHubActor.self
      ] }

      var login: String { __data["login"] }
      var avatarUrl: GitHubAPI.URI { __data["avatarUrl"] }

      struct Fragments: FragmentContainer {
        let __data: DataDict
        init(_dataDict: DataDict) { __data = _dataDict }

        var gitHubActor: GitHubActor { _toFragment() }
      }
    }

    /// AsMannequin
    nonisolated struct AsMannequin: GitHubAPI.InlineFragment {
      let __data: DataDict
      init(_dataDict: DataDict) { __data = _dataDict }

      typealias RootEntityType = GitHubRequestedReviewer
      static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.Mannequin }
      static var __selections: [ApolloAPI.Selection] { [
        .field("id", alias: "mannequinID", GitHubAPI.ID.self),
        .field("login", alias: "mannequinLogin", String.self),
        .field("avatarUrl", alias: "mannequinAvatarURL", GitHubAPI.URI.self, arguments: ["size": 64]),
      ] }
      static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
        GitHubRequestedReviewer.self,
        GitHubRequestedReviewer.AsMannequin.self,
        GitHubRequestedReviewer.AsActor.self,
        GitHubActor.self,
        GitHubActor.AsNode.self
      ] }

      var mannequinID: GitHubAPI.ID { __data["mannequinID"] }
      var mannequinLogin: String { __data["mannequinLogin"] }
      var mannequinAvatarURL: GitHubAPI.URI { __data["mannequinAvatarURL"] }
      var login: String { __data["login"] }
      var avatarUrl: GitHubAPI.URI { __data["avatarUrl"] }
      var id: GitHubAPI.ID { __data["id"] }

      struct Fragments: FragmentContainer {
        let __data: DataDict
        init(_dataDict: DataDict) { __data = _dataDict }

        var gitHubActor: GitHubActor { _toFragment() }
      }
    }

    /// AsTeam
    nonisolated struct AsTeam: GitHubAPI.InlineFragment {
      let __data: DataDict
      init(_dataDict: DataDict) { __data = _dataDict }

      typealias RootEntityType = GitHubRequestedReviewer
      static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.Team }
      static var __selections: [ApolloAPI.Selection] { [
        .field("id", alias: "teamID", GitHubAPI.ID.self),
        .field("name", alias: "teamName", String.self),
        .field("slug", alias: "teamSlug", String.self),
        .field("avatarUrl", alias: "teamAvatarURL", GitHubAPI.URI?.self),
      ] }
      static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
        GitHubRequestedReviewer.self,
        GitHubRequestedReviewer.AsTeam.self
      ] }

      var teamID: GitHubAPI.ID { __data["teamID"] }
      var teamName: String { __data["teamName"] }
      var teamSlug: String { __data["teamSlug"] }
      var teamAvatarURL: GitHubAPI.URI? { __data["teamAvatarURL"] }
    }
  }

}
