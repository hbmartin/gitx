// @generated
// This file was automatically generated and should not be edited.

import ApolloAPI
@_spi(Execution) @_spi(Unsafe) import ApolloAPI

extension GitHubAPI {
  nonisolated struct GitHubIssueComment: GitHubAPI.SelectionSet, Fragment {
    static var fragmentDefinition: StaticString {
      #"fragment GitHubIssueComment on IssueComment { __typename id body createdAt updatedAt author { __typename ...GitHubActor } }"#
    }

    let __data: DataDict
    init(_dataDict: DataDict) { __data = _dataDict }

    static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.IssueComment }
    static var __selections: [ApolloAPI.Selection] { [
      .field("__typename", String.self),
      .field("id", GitHubAPI.ID.self),
      .field("body", String.self),
      .field("createdAt", GitHubAPI.DateTime.self),
      .field("updatedAt", GitHubAPI.DateTime.self),
      .field("author", Author?.self),
    ] }
    static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
      GitHubIssueComment.self
    ] }

    var id: GitHubAPI.ID { __data["id"] }
    var body: String { __data["body"] }
    var createdAt: GitHubAPI.DateTime { __data["createdAt"] }
    var updatedAt: GitHubAPI.DateTime { __data["updatedAt"] }
    var author: Author? { __data["author"] }

    /// Author
    nonisolated struct Author: GitHubAPI.SelectionSet {
      let __data: DataDict
      init(_dataDict: DataDict) { __data = _dataDict }

      static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Interfaces.Actor }
      static var __selections: [ApolloAPI.Selection] { [
        .field("__typename", String.self),
        .fragment(GitHubActor.self),
      ] }
      static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
        GitHubIssueComment.Author.self,
        GitHubActor.self
      ] }

      var login: String { __data["login"] }
      var avatarUrl: GitHubAPI.URI { __data["avatarUrl"] }

      var asNode: AsNode? { _asInlineFragment() }
      var asUser: AsUser? { _asInlineFragment() }
      var asOrganization: AsOrganization? { _asInlineFragment() }

      struct Fragments: FragmentContainer {
        let __data: DataDict
        init(_dataDict: DataDict) { __data = _dataDict }

        var gitHubActor: GitHubActor { _toFragment() }
      }

      /// Author.AsNode
      nonisolated struct AsNode: GitHubAPI.InlineFragment, ApolloAPI.CompositeInlineFragment {
        let __data: DataDict
        init(_dataDict: DataDict) { __data = _dataDict }

        typealias RootEntityType = GitHubIssueComment.Author
        static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Interfaces.Node }
        static var __mergedSources: [any ApolloAPI.SelectionSet.Type] { [
          GitHubIssueComment.Author.self,
          GitHubActor.self,
          GitHubActor.AsNode.self
        ] }
        static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
          GitHubIssueComment.Author.self,
          GitHubIssueComment.Author.AsNode.self,
          GitHubActor.self,
          GitHubActor.AsNode.self
        ] }

        var login: String { __data["login"] }
        var avatarUrl: GitHubAPI.URI { __data["avatarUrl"] }
        var id: GitHubAPI.ID { __data["id"] }

        struct Fragments: FragmentContainer {
          let __data: DataDict
          init(_dataDict: DataDict) { __data = _dataDict }

          var gitHubActor: GitHubActor { _toFragment() }
        }
      }

      /// Author.AsUser
      nonisolated struct AsUser: GitHubAPI.InlineFragment, ApolloAPI.CompositeInlineFragment {
        let __data: DataDict
        init(_dataDict: DataDict) { __data = _dataDict }

        typealias RootEntityType = GitHubIssueComment.Author
        static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.User }
        static var __mergedSources: [any ApolloAPI.SelectionSet.Type] { [
          GitHubIssueComment.Author.self,
          GitHubActor.self,
          GitHubActor.AsNode.self,
          GitHubActor.AsUser.self
        ] }
        static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
          GitHubIssueComment.Author.self,
          GitHubIssueComment.Author.AsUser.self,
          GitHubActor.self,
          GitHubActor.AsNode.self,
          GitHubActor.AsUser.self
        ] }

        var login: String { __data["login"] }
        var avatarUrl: GitHubAPI.URI { __data["avatarUrl"] }
        var id: GitHubAPI.ID { __data["id"] }
        var name: String? { __data["name"] }

        struct Fragments: FragmentContainer {
          let __data: DataDict
          init(_dataDict: DataDict) { __data = _dataDict }

          var gitHubActor: GitHubActor { _toFragment() }
        }
      }

      /// Author.AsOrganization
      nonisolated struct AsOrganization: GitHubAPI.InlineFragment, ApolloAPI.CompositeInlineFragment {
        let __data: DataDict
        init(_dataDict: DataDict) { __data = _dataDict }

        typealias RootEntityType = GitHubIssueComment.Author
        static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.Organization }
        static var __mergedSources: [any ApolloAPI.SelectionSet.Type] { [
          GitHubIssueComment.Author.self,
          GitHubActor.self,
          GitHubActor.AsNode.self,
          GitHubActor.AsOrganization.self
        ] }
        static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
          GitHubIssueComment.Author.self,
          GitHubIssueComment.Author.AsOrganization.self,
          GitHubActor.self,
          GitHubActor.AsNode.self,
          GitHubActor.AsOrganization.self
        ] }

        var login: String { __data["login"] }
        var avatarUrl: GitHubAPI.URI { __data["avatarUrl"] }
        var id: GitHubAPI.ID { __data["id"] }
        var name: String? { __data["name"] }

        struct Fragments: FragmentContainer {
          let __data: DataDict
          init(_dataDict: DataDict) { __data = _dataDict }

          var gitHubActor: GitHubActor { _toFragment() }
        }
      }
    }
  }

}
