// @generated
// This file was automatically generated and should not be edited.

import ApolloAPI
@_spi(Execution) @_spi(Unsafe) import ApolloAPI

extension GitHubAPI {
  nonisolated struct GitHubPullRequestReviewThreadsQuery: GraphQLQuery {
    static let operationName: String = "GitHubPullRequestReviewThreads"
    static let operationDocument: ApolloAPI.OperationDocument = .init(
      definition: .init(
        #"query GitHubPullRequestReviewThreads($owner: String!, $name: String!, $number: Int!, $first: Int!, $after: String, $commentFirst: Int!) { repository(owner: $owner, name: $name) { __typename id pullRequest(number: $number) { __typename id reviewThreads(first: $first, after: $after) { __typename totalCount pageInfo { __typename ...GitHubPageInfo } nodes { __typename id isResolved isOutdated path subjectType diffSide startLine line startDiffSide originalStartLine originalLine comments(first: $commentFirst) { __typename totalCount pageInfo { __typename ...GitHubPageInfo } nodes { __typename ...GitHubReviewComment } } } } } } }"#,
        fragments: [GitHubActor.self, GitHubPageInfo.self, GitHubReviewComment.self]
      ))

    public var owner: String
    public var name: String
    public var number: Int32
    public var first: Int32
    public var after: GraphQLNullable<String>
    public var commentFirst: Int32

    public init(
      owner: String,
      name: String,
      number: Int32,
      first: Int32,
      after: GraphQLNullable<String>,
      commentFirst: Int32
    ) {
      self.owner = owner
      self.name = name
      self.number = number
      self.first = first
      self.after = after
      self.commentFirst = commentFirst
    }

    @_spi(Unsafe) public var __variables: Variables? { [
      "owner": owner,
      "name": name,
      "number": number,
      "first": first,
      "after": after,
      "commentFirst": commentFirst
    ] }

    nonisolated struct Data: GitHubAPI.SelectionSet {
      let __data: DataDict
      init(_dataDict: DataDict) { __data = _dataDict }

      static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.Query }
      static var __selections: [ApolloAPI.Selection] { [
        .field("repository", Repository?.self, arguments: [
          "owner": .variable("owner"),
          "name": .variable("name")
        ]),
      ] }
      static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
        GitHubPullRequestReviewThreadsQuery.Data.self
      ] }

      var repository: Repository? { __data["repository"] }

      /// Repository
      nonisolated struct Repository: GitHubAPI.SelectionSet {
        let __data: DataDict
        init(_dataDict: DataDict) { __data = _dataDict }

        static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.Repository }
        static var __selections: [ApolloAPI.Selection] { [
          .field("__typename", String.self),
          .field("id", GitHubAPI.ID.self),
          .field("pullRequest", PullRequest?.self, arguments: ["number": .variable("number")]),
        ] }
        static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
          GitHubPullRequestReviewThreadsQuery.Data.Repository.self
        ] }

        var id: GitHubAPI.ID { __data["id"] }
        var pullRequest: PullRequest? { __data["pullRequest"] }

        /// Repository.PullRequest
        nonisolated struct PullRequest: GitHubAPI.SelectionSet {
          let __data: DataDict
          init(_dataDict: DataDict) { __data = _dataDict }

          static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.PullRequest }
          static var __selections: [ApolloAPI.Selection] { [
            .field("__typename", String.self),
            .field("id", GitHubAPI.ID.self),
            .field("reviewThreads", ReviewThreads.self, arguments: [
              "first": .variable("first"),
              "after": .variable("after")
            ]),
          ] }
          static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
            GitHubPullRequestReviewThreadsQuery.Data.Repository.PullRequest.self
          ] }

          var id: GitHubAPI.ID { __data["id"] }
          var reviewThreads: ReviewThreads { __data["reviewThreads"] }

          /// Repository.PullRequest.ReviewThreads
          nonisolated struct ReviewThreads: GitHubAPI.SelectionSet {
            let __data: DataDict
            init(_dataDict: DataDict) { __data = _dataDict }

            static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.PullRequestReviewThreadConnection }
            static var __selections: [ApolloAPI.Selection] { [
              .field("__typename", String.self),
              .field("totalCount", Int.self),
              .field("pageInfo", PageInfo.self),
              .field("nodes", [Node?]?.self),
            ] }
            static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
              GitHubPullRequestReviewThreadsQuery.Data.Repository.PullRequest.ReviewThreads.self
            ] }

            var totalCount: Int { __data["totalCount"] }
            var pageInfo: PageInfo { __data["pageInfo"] }
            var nodes: [Node?]? { __data["nodes"] }

            /// Repository.PullRequest.ReviewThreads.PageInfo
            nonisolated struct PageInfo: GitHubAPI.SelectionSet {
              let __data: DataDict
              init(_dataDict: DataDict) { __data = _dataDict }

              static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.PageInfo }
              static var __selections: [ApolloAPI.Selection] { [
                .field("__typename", String.self),
                .fragment(GitHubPageInfo.self),
              ] }
              static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                GitHubPullRequestReviewThreadsQuery.Data.Repository.PullRequest.ReviewThreads.PageInfo.self,
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

            /// Repository.PullRequest.ReviewThreads.Node
            nonisolated struct Node: GitHubAPI.SelectionSet {
              let __data: DataDict
              init(_dataDict: DataDict) { __data = _dataDict }

              static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.PullRequestReviewThread }
              static var __selections: [ApolloAPI.Selection] { [
                .field("__typename", String.self),
                .field("id", GitHubAPI.ID.self),
                .field("isResolved", Bool.self),
                .field("isOutdated", Bool.self),
                .field("path", String.self),
                .field("subjectType", GraphQLEnum<GitHubAPI.PullRequestReviewThreadSubjectType>.self),
                .field("diffSide", GraphQLEnum<GitHubAPI.DiffSide>.self),
                .field("startLine", Int?.self),
                .field("line", Int?.self),
                .field("startDiffSide", GraphQLEnum<GitHubAPI.DiffSide>?.self),
                .field("originalStartLine", Int?.self),
                .field("originalLine", Int?.self),
                .field("comments", Comments.self, arguments: ["first": .variable("commentFirst")]),
              ] }
              static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                GitHubPullRequestReviewThreadsQuery.Data.Repository.PullRequest.ReviewThreads.Node.self
              ] }

              var id: GitHubAPI.ID { __data["id"] }
              var isResolved: Bool { __data["isResolved"] }
              var isOutdated: Bool { __data["isOutdated"] }
              var path: String { __data["path"] }
              var subjectType: GraphQLEnum<GitHubAPI.PullRequestReviewThreadSubjectType> { __data["subjectType"] }
              var diffSide: GraphQLEnum<GitHubAPI.DiffSide> { __data["diffSide"] }
              var startLine: Int? { __data["startLine"] }
              var line: Int? { __data["line"] }
              var startDiffSide: GraphQLEnum<GitHubAPI.DiffSide>? { __data["startDiffSide"] }
              var originalStartLine: Int? { __data["originalStartLine"] }
              var originalLine: Int? { __data["originalLine"] }
              var comments: Comments { __data["comments"] }

              /// Repository.PullRequest.ReviewThreads.Node.Comments
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
                  GitHubPullRequestReviewThreadsQuery.Data.Repository.PullRequest.ReviewThreads.Node.Comments.self
                ] }

                var totalCount: Int { __data["totalCount"] }
                var pageInfo: PageInfo { __data["pageInfo"] }
                var nodes: [Node?]? { __data["nodes"] }

                /// Repository.PullRequest.ReviewThreads.Node.Comments.PageInfo
                nonisolated struct PageInfo: GitHubAPI.SelectionSet {
                  let __data: DataDict
                  init(_dataDict: DataDict) { __data = _dataDict }

                  static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.PageInfo }
                  static var __selections: [ApolloAPI.Selection] { [
                    .field("__typename", String.self),
                    .fragment(GitHubPageInfo.self),
                  ] }
                  static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                    GitHubPullRequestReviewThreadsQuery.Data.Repository.PullRequest.ReviewThreads.Node.Comments.PageInfo.self,
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

                /// Repository.PullRequest.ReviewThreads.Node.Comments.Node
                nonisolated struct Node: GitHubAPI.SelectionSet {
                  let __data: DataDict
                  init(_dataDict: DataDict) { __data = _dataDict }

                  static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.PullRequestReviewComment }
                  static var __selections: [ApolloAPI.Selection] { [
                    .field("__typename", String.self),
                    .fragment(GitHubReviewComment.self),
                  ] }
                  static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                    GitHubPullRequestReviewThreadsQuery.Data.Repository.PullRequest.ReviewThreads.Node.Comments.Node.self,
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
  }

}
