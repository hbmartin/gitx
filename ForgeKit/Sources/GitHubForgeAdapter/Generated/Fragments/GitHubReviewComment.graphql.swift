// @generated
// This file was automatically generated and should not be edited.

import ApolloAPI
@_spi(Execution) @_spi(Unsafe) import ApolloAPI

extension GitHubAPI {
  nonisolated struct GitHubReviewComment: GitHubAPI.SelectionSet, Fragment {
    static var fragmentDefinition: StaticString {
      #"fragment GitHubReviewComment on PullRequestReviewComment { __typename id body createdAt updatedAt isMinimized minimizedReason diffHunk reactionGroups { __typename content viewerHasReacted reactors(first: 1) { __typename totalCount pageInfo { __typename ...GitHubPageInfo } } } author { __typename ...GitHubActor } replyTo { __typename id } }"#
    }

    let __data: DataDict
    init(_dataDict: DataDict) { __data = _dataDict }

    static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.PullRequestReviewComment }
    static var __selections: [ApolloAPI.Selection] { [
      .field("__typename", String.self),
      .field("id", GitHubAPI.ID.self),
      .field("body", String.self),
      .field("createdAt", GitHubAPI.DateTime.self),
      .field("updatedAt", GitHubAPI.DateTime.self),
      .field("isMinimized", Bool.self),
      .field("minimizedReason", String?.self),
      .field("diffHunk", String.self),
      .field("reactionGroups", [ReactionGroup]?.self),
      .field("author", Author?.self),
      .field("replyTo", ReplyTo?.self),
    ] }
    static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
      GitHubReviewComment.self
    ] }

    var id: GitHubAPI.ID { __data["id"] }
    var body: String { __data["body"] }
    var createdAt: GitHubAPI.DateTime { __data["createdAt"] }
    var updatedAt: GitHubAPI.DateTime { __data["updatedAt"] }
    var isMinimized: Bool { __data["isMinimized"] }
    var minimizedReason: String? { __data["minimizedReason"] }
    var diffHunk: String { __data["diffHunk"] }
    var reactionGroups: [ReactionGroup]? { __data["reactionGroups"] }
    var author: Author? { __data["author"] }
    var replyTo: ReplyTo? { __data["replyTo"] }

    /// ReactionGroup
    nonisolated struct ReactionGroup: GitHubAPI.SelectionSet {
      let __data: DataDict
      init(_dataDict: DataDict) { __data = _dataDict }

      static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.ReactionGroup }
      static var __selections: [ApolloAPI.Selection] { [
        .field("__typename", String.self),
        .field("content", GraphQLEnum<GitHubAPI.ReactionContent>.self),
        .field("viewerHasReacted", Bool.self),
        .field("reactors", Reactors.self, arguments: ["first": 1]),
      ] }
      static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
        GitHubReviewComment.ReactionGroup.self
      ] }

      var content: GraphQLEnum<GitHubAPI.ReactionContent> { __data["content"] }
      var viewerHasReacted: Bool { __data["viewerHasReacted"] }
      var reactors: Reactors { __data["reactors"] }

      /// ReactionGroup.Reactors
      nonisolated struct Reactors: GitHubAPI.SelectionSet {
        let __data: DataDict
        init(_dataDict: DataDict) { __data = _dataDict }

        static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.ReactorConnection }
        static var __selections: [ApolloAPI.Selection] { [
          .field("__typename", String.self),
          .field("totalCount", Int.self),
          .field("pageInfo", PageInfo.self),
        ] }
        static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
          GitHubReviewComment.ReactionGroup.Reactors.self
        ] }

        var totalCount: Int { __data["totalCount"] }
        var pageInfo: PageInfo { __data["pageInfo"] }

        /// ReactionGroup.Reactors.PageInfo
        nonisolated struct PageInfo: GitHubAPI.SelectionSet {
          let __data: DataDict
          init(_dataDict: DataDict) { __data = _dataDict }

          static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.PageInfo }
          static var __selections: [ApolloAPI.Selection] { [
            .field("__typename", String.self),
            .fragment(GitHubPageInfo.self),
          ] }
          static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
            GitHubReviewComment.ReactionGroup.Reactors.PageInfo.self,
            GitHubPageInfo.self
          ] }

          var hasPreviousPage: Bool { __data["hasPreviousPage"] }
          var startCursor: String? { __data["startCursor"] }
          var hasNextPage: Bool { __data["hasNextPage"] }
          var endCursor: String? { __data["endCursor"] }

          struct Fragments: FragmentContainer {
            let __data: DataDict
            init(_dataDict: DataDict) { __data = _dataDict }

            var gitHubPageInfo: GitHubPageInfo { _toFragment() }
          }
        }
      }
    }

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
        GitHubReviewComment.Author.self,
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

        typealias RootEntityType = GitHubReviewComment.Author
        static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Interfaces.Node }
        static var __mergedSources: [any ApolloAPI.SelectionSet.Type] { [
          GitHubReviewComment.Author.self,
          GitHubActor.self,
          GitHubActor.AsNode.self
        ] }
        static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
          GitHubReviewComment.Author.self,
          GitHubReviewComment.Author.AsNode.self,
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

        typealias RootEntityType = GitHubReviewComment.Author
        static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.User }
        static var __mergedSources: [any ApolloAPI.SelectionSet.Type] { [
          GitHubReviewComment.Author.self,
          GitHubActor.self,
          GitHubActor.AsNode.self,
          GitHubActor.AsUser.self
        ] }
        static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
          GitHubReviewComment.Author.self,
          GitHubReviewComment.Author.AsUser.self,
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

        typealias RootEntityType = GitHubReviewComment.Author
        static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.Organization }
        static var __mergedSources: [any ApolloAPI.SelectionSet.Type] { [
          GitHubReviewComment.Author.self,
          GitHubActor.self,
          GitHubActor.AsNode.self,
          GitHubActor.AsOrganization.self
        ] }
        static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
          GitHubReviewComment.Author.self,
          GitHubReviewComment.Author.AsOrganization.self,
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

    /// ReplyTo
    nonisolated struct ReplyTo: GitHubAPI.SelectionSet {
      let __data: DataDict
      init(_dataDict: DataDict) { __data = _dataDict }

      static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.PullRequestReviewComment }
      static var __selections: [ApolloAPI.Selection] { [
        .field("__typename", String.self),
        .field("id", GitHubAPI.ID.self),
      ] }
      static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
        GitHubReviewComment.ReplyTo.self
      ] }

      var id: GitHubAPI.ID { __data["id"] }
    }
  }

}
