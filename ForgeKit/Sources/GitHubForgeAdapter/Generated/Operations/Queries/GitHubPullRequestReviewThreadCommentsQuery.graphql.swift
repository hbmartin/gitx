// @generated
// This file was automatically generated and should not be edited.

import ApolloAPI
@_spi(Execution) @_spi(Unsafe) import ApolloAPI

extension GitHubAPI {
  nonisolated struct GitHubPullRequestReviewThreadCommentsQuery: GraphQLQuery {
    static let operationName: String = "GitHubPullRequestReviewThreadComments"
    static let operationDocument: ApolloAPI.OperationDocument = .init(
      definition: .init(
        #"query GitHubPullRequestReviewThreadComments($id: ID!, $first: Int!, $after: String) { node(id: $id) { __typename ... on PullRequestReviewThread { id pullRequest { __typename repository { __typename ...GitHubRepositoryIdentity } } comments(first: $first, after: $after) { __typename totalCount pageInfo { __typename ...GitHubPageInfo } nodes { __typename ...GitHubReviewComment } } } } }"#,
        fragments: [GitHubActor.self, GitHubPageInfo.self, GitHubRepositoryIdentity.self, GitHubReviewComment.self]
      ))

    public var id: ID
    public var first: Int32
    public var after: GraphQLNullable<String>

    public init(
      id: ID,
      first: Int32,
      after: GraphQLNullable<String>
    ) {
      self.id = id
      self.first = first
      self.after = after
    }

    @_spi(Unsafe) public var __variables: Variables? { [
      "id": id,
      "first": first,
      "after": after
    ] }

    nonisolated struct Data: GitHubAPI.SelectionSet {
      let __data: DataDict
      init(_dataDict: DataDict) { __data = _dataDict }

      static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.Query }
      static var __selections: [ApolloAPI.Selection] { [
        .field("node", Node?.self, arguments: ["id": .variable("id")]),
      ] }
      static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
        GitHubPullRequestReviewThreadCommentsQuery.Data.self
      ] }

      var node: Node? { __data["node"] }

      /// Node
      nonisolated struct Node: GitHubAPI.SelectionSet {
        let __data: DataDict
        init(_dataDict: DataDict) { __data = _dataDict }

        static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Interfaces.Node }
        static var __selections: [ApolloAPI.Selection] { [
          .field("__typename", String.self),
          .inlineFragment(AsPullRequestReviewThread.self),
        ] }
        static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
          GitHubPullRequestReviewThreadCommentsQuery.Data.Node.self
        ] }

        var asPullRequestReviewThread: AsPullRequestReviewThread? { _asInlineFragment() }

        /// Node.AsPullRequestReviewThread
        nonisolated struct AsPullRequestReviewThread: GitHubAPI.InlineFragment {
          let __data: DataDict
          init(_dataDict: DataDict) { __data = _dataDict }

          typealias RootEntityType = GitHubPullRequestReviewThreadCommentsQuery.Data.Node
          static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.PullRequestReviewThread }
          static var __selections: [ApolloAPI.Selection] { [
            .field("id", GitHubAPI.ID.self),
            .field("pullRequest", PullRequest.self),
            .field("comments", Comments.self, arguments: [
              "first": .variable("first"),
              "after": .variable("after")
            ]),
          ] }
          static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
            GitHubPullRequestReviewThreadCommentsQuery.Data.Node.self,
            GitHubPullRequestReviewThreadCommentsQuery.Data.Node.AsPullRequestReviewThread.self
          ] }

          var id: GitHubAPI.ID { __data["id"] }
          var pullRequest: PullRequest { __data["pullRequest"] }
          var comments: Comments { __data["comments"] }

          /// Node.AsPullRequestReviewThread.PullRequest
          nonisolated struct PullRequest: GitHubAPI.SelectionSet {
            let __data: DataDict
            init(_dataDict: DataDict) { __data = _dataDict }

            static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.PullRequest }
            static var __selections: [ApolloAPI.Selection] { [
              .field("__typename", String.self),
              .field("repository", Repository.self),
            ] }
            static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
              GitHubPullRequestReviewThreadCommentsQuery.Data.Node.AsPullRequestReviewThread.PullRequest.self
            ] }

            var repository: Repository { __data["repository"] }

            /// Node.AsPullRequestReviewThread.PullRequest.Repository
            nonisolated struct Repository: GitHubAPI.SelectionSet {
              let __data: DataDict
              init(_dataDict: DataDict) { __data = _dataDict }

              static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.Repository }
              static var __selections: [ApolloAPI.Selection] { [
                .field("__typename", String.self),
                .fragment(GitHubRepositoryIdentity.self),
              ] }
              static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                GitHubPullRequestReviewThreadCommentsQuery.Data.Node.AsPullRequestReviewThread.PullRequest.Repository.self,
                GitHubRepositoryIdentity.self
              ] }

              var id: GitHubAPI.ID { __data["id"] }
              var name: String { __data["name"] }
              var nameWithOwner: String { __data["nameWithOwner"] }
              var owner: Owner { __data["owner"] }

              struct Fragments: FragmentContainer {
                let __data: DataDict
                init(_dataDict: DataDict) { __data = _dataDict }

                var gitHubRepositoryIdentity: GitHubRepositoryIdentity { _toFragment() }
              }

              typealias Owner = GitHubRepositoryIdentity.Owner
            }
          }

          /// Node.AsPullRequestReviewThread.Comments
          nonisolated struct Comments: GitHubAPI.SelectionSet {
            let __data: DataDict
            init(_dataDict: DataDict) { __data = _dataDict }

            static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.PullRequestReviewCommentConnection }
            static var __selections: [ApolloAPI.Selection] { [
              .field("__typename", String.self),
              .field("totalCount", Int.self),
              .field("pageInfo", PageInfo.self),
              .field("nodes", [Node?]?.self),
            ] }
            static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
              GitHubPullRequestReviewThreadCommentsQuery.Data.Node.AsPullRequestReviewThread.Comments.self
            ] }

            var totalCount: Int { __data["totalCount"] }
            var pageInfo: PageInfo { __data["pageInfo"] }
            var nodes: [Node?]? { __data["nodes"] }

            /// Node.AsPullRequestReviewThread.Comments.PageInfo
            nonisolated struct PageInfo: GitHubAPI.SelectionSet {
              let __data: DataDict
              init(_dataDict: DataDict) { __data = _dataDict }

              static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.PageInfo }
              static var __selections: [ApolloAPI.Selection] { [
                .field("__typename", String.self),
                .fragment(GitHubPageInfo.self),
              ] }
              static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                GitHubPullRequestReviewThreadCommentsQuery.Data.Node.AsPullRequestReviewThread.Comments.PageInfo.self,
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

            /// Node.AsPullRequestReviewThread.Comments.Node
            nonisolated struct Node: GitHubAPI.SelectionSet {
              let __data: DataDict
              init(_dataDict: DataDict) { __data = _dataDict }

              static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.PullRequestReviewComment }
              static var __selections: [ApolloAPI.Selection] { [
                .field("__typename", String.self),
                .fragment(GitHubReviewComment.self),
              ] }
              static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                GitHubPullRequestReviewThreadCommentsQuery.Data.Node.AsPullRequestReviewThread.Comments.Node.self,
                GitHubReviewComment.self
              ] }

              var id: GitHubAPI.ID { __data["id"] }
              var body: String { __data["body"] }
              var createdAt: GitHubAPI.DateTime { __data["createdAt"] }
              var updatedAt: GitHubAPI.DateTime { __data["updatedAt"] }
              var author: Author? { __data["author"] }
              var replyTo: ReplyTo? { __data["replyTo"] }

              struct Fragments: FragmentContainer {
                let __data: DataDict
                init(_dataDict: DataDict) { __data = _dataDict }

                var gitHubReviewComment: GitHubReviewComment { _toFragment() }
              }

              typealias Author = GitHubReviewComment.Author

              typealias ReplyTo = GitHubReviewComment.ReplyTo
            }
          }
        }
      }
    }
  }

}
