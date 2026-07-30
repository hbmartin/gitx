// @generated
// This file was automatically generated and should not be edited.

import ApolloAPI
@_spi(Execution) @_spi(Unsafe) import ApolloAPI

extension GitHubAPI {
  nonisolated struct GitHubAttentionCandidatesQuery: GraphQLQuery {
    static let operationName: String = "GitHubAttentionCandidates"
    static let operationDocument: ApolloAPI.OperationDocument = .init(
      definition: .init(
        #"query GitHubAttentionCandidates($query: String!, $first: Int!, $after: String, $activityLast: Int!, $reviewThreadFirst: Int!) { viewer { __typename ...GitHubActor } search(query: $query, type: ISSUE, first: $first, after: $after) { __typename totalCount: issueCount pageInfo { __typename ...GitHubPageInfo } nodes { __typename ... on PullRequest { ...GitHubPullRequestSummary body assignedActors(first: 100) { __typename totalCount pageInfo { __typename ...GitHubPageInfo } nodes { __typename ...GitHubAssignee } } participants(first: 100) { __typename totalCount pageInfo { __typename ...GitHubPageInfo } nodes { __typename ...GitHubActor } } reviewRequests(first: 100) { __typename totalCount pageInfo { __typename ...GitHubPageInfo } nodes { __typename id requestedReviewer { __typename ...GitHubRequestedReviewer } } } comments(last: $activityLast) { __typename totalCount pageInfo { __typename ...GitHubPageInfo } nodes { __typename ...GitHubIssueComment } } latestReviews(first: 100) { __typename totalCount pageInfo { __typename ...GitHubPageInfo } nodes { __typename id body state submittedAt author { __typename ...GitHubActor } } } reviewThreads(first: $reviewThreadFirst) { __typename totalCount pageInfo { __typename ...GitHubPageInfo } nodes { __typename id isResolved isOutdated comments(last: $activityLast) { __typename totalCount pageInfo { __typename ...GitHubPageInfo } nodes { __typename ...GitHubReviewComment } } } } } ... on Issue { ...GitHubIssueSummary body assignedActors(first: 100) { __typename totalCount pageInfo { __typename ...GitHubPageInfo } nodes { __typename ...GitHubAssignee } } participants(first: 100) { __typename totalCount pageInfo { __typename ...GitHubPageInfo } nodes { __typename ...GitHubActor } } comments(last: $activityLast) { __typename totalCount pageInfo { __typename ...GitHubPageInfo } nodes { __typename ...GitHubIssueComment } } } } } }"#,
        fragments: [GitHubActor.self, GitHubAssignee.self, GitHubIssueComment.self, GitHubIssueSummary.self, GitHubLabel.self, GitHubPageInfo.self, GitHubPullRequestSummary.self, GitHubRepositoryIdentity.self, GitHubRequestedReviewer.self, GitHubReviewComment.self]
      ))

    public var query: String
    public var first: Int32
    public var after: GraphQLNullable<String>
    public var activityLast: Int32
    public var reviewThreadFirst: Int32

    public init(
      query: String,
      first: Int32,
      after: GraphQLNullable<String>,
      activityLast: Int32,
      reviewThreadFirst: Int32
    ) {
      self.query = query
      self.first = first
      self.after = after
      self.activityLast = activityLast
      self.reviewThreadFirst = reviewThreadFirst
    }

    @_spi(Unsafe) public var __variables: Variables? { [
      "query": query,
      "first": first,
      "after": after,
      "activityLast": activityLast,
      "reviewThreadFirst": reviewThreadFirst
    ] }

    nonisolated struct Data: GitHubAPI.SelectionSet {
      let __data: DataDict
      init(_dataDict: DataDict) { __data = _dataDict }

      static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.Query }
      static var __selections: [ApolloAPI.Selection] { [
        .field("viewer", Viewer.self),
        .field("search", Search.self, arguments: [
          "query": .variable("query"),
          "type": "ISSUE",
          "first": .variable("first"),
          "after": .variable("after")
        ]),
      ] }
      static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
        GitHubAttentionCandidatesQuery.Data.self
      ] }

      var viewer: Viewer { __data["viewer"] }
      var search: Search { __data["search"] }

      /// Viewer
      nonisolated struct Viewer: GitHubAPI.SelectionSet {
        let __data: DataDict
        init(_dataDict: DataDict) { __data = _dataDict }

        static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.User }
        static var __selections: [ApolloAPI.Selection] { [
          .field("__typename", String.self),
          .fragment(GitHubActor.self),
        ] }
        static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
          GitHubAttentionCandidatesQuery.Data.Viewer.self,
          GitHubActor.self,
          GitHubActor.AsNode.self,
          GitHubActor.AsUser.self
        ] }

        var login: String { __data["login"] }
        var avatarUrl: GitHubAPI.URI { __data["avatarUrl"] }
        var id: GitHubAPI.ID { __data["id"] }
        var name: String? { __data["name"] }

        var asOrganization: AsOrganization? { _asInlineFragment() }

        struct Fragments: FragmentContainer {
          let __data: DataDict
          init(_dataDict: DataDict) { __data = _dataDict }

          var gitHubActor: GitHubActor { _toFragment() }
        }

        /// Viewer.AsOrganization
        nonisolated struct AsOrganization: GitHubAPI.InlineFragment, ApolloAPI.CompositeInlineFragment {
          let __data: DataDict
          init(_dataDict: DataDict) { __data = _dataDict }

          typealias RootEntityType = GitHubAttentionCandidatesQuery.Data.Viewer
          static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.Organization }
          static var __mergedSources: [any ApolloAPI.SelectionSet.Type] { [
            GitHubAttentionCandidatesQuery.Data.Viewer.self,
            GitHubActor.self,
            GitHubActor.AsNode.self,
            GitHubActor.AsUser.self,
            GitHubActor.AsOrganization.self
          ] }
          static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
            GitHubAttentionCandidatesQuery.Data.Viewer.self,
            GitHubAttentionCandidatesQuery.Data.Viewer.AsOrganization.self,
            GitHubActor.self,
            GitHubActor.AsNode.self,
            GitHubActor.AsUser.self,
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

      /// Search
      nonisolated struct Search: GitHubAPI.SelectionSet {
        let __data: DataDict
        init(_dataDict: DataDict) { __data = _dataDict }

        static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.SearchResultItemConnection }
        static var __selections: [ApolloAPI.Selection] { [
          .field("__typename", String.self),
          .field("issueCount", alias: "totalCount", Int.self),
          .field("pageInfo", PageInfo.self),
          .field("nodes", [Node?]?.self),
        ] }
        static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
          GitHubAttentionCandidatesQuery.Data.Search.self
        ] }

        var totalCount: Int { __data["totalCount"] }
        var pageInfo: PageInfo { __data["pageInfo"] }
        var nodes: [Node?]? { __data["nodes"] }

        /// Search.PageInfo
        nonisolated struct PageInfo: GitHubAPI.SelectionSet {
          let __data: DataDict
          init(_dataDict: DataDict) { __data = _dataDict }

          static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.PageInfo }
          static var __selections: [ApolloAPI.Selection] { [
            .field("__typename", String.self),
            .fragment(GitHubPageInfo.self),
          ] }
          static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
            GitHubAttentionCandidatesQuery.Data.Search.PageInfo.self,
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

        /// Search.Node
        nonisolated struct Node: GitHubAPI.SelectionSet {
          let __data: DataDict
          init(_dataDict: DataDict) { __data = _dataDict }

          static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Unions.SearchResultItem }
          static var __selections: [ApolloAPI.Selection] { [
            .field("__typename", String.self),
            .inlineFragment(AsPullRequest.self),
            .inlineFragment(AsIssue.self),
          ] }
          static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
            GitHubAttentionCandidatesQuery.Data.Search.Node.self
          ] }

          var asPullRequest: AsPullRequest? { _asInlineFragment() }
          var asIssue: AsIssue? { _asInlineFragment() }

          /// Search.Node.AsPullRequest
          nonisolated struct AsPullRequest: GitHubAPI.InlineFragment {
            let __data: DataDict
            init(_dataDict: DataDict) { __data = _dataDict }

            typealias RootEntityType = GitHubAttentionCandidatesQuery.Data.Search.Node
            static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.PullRequest }
            static var __selections: [ApolloAPI.Selection] { [
              .field("body", String.self),
              .field("assignedActors", AssignedActors.self, arguments: ["first": 100]),
              .field("participants", Participants.self, arguments: ["first": 100]),
              .field("reviewRequests", ReviewRequests?.self, arguments: ["first": 100]),
              .field("comments", Comments.self, arguments: ["last": .variable("activityLast")]),
              .field("latestReviews", LatestReviews?.self, arguments: ["first": 100]),
              .field("reviewThreads", ReviewThreads.self, arguments: ["first": .variable("reviewThreadFirst")]),
              .fragment(GitHubPullRequestSummary.self),
            ] }
            static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
              GitHubAttentionCandidatesQuery.Data.Search.Node.self,
              GitHubAttentionCandidatesQuery.Data.Search.Node.AsPullRequest.self,
              GitHubPullRequestSummary.self
            ] }

            var body: String { __data["body"] }
            var assignedActors: AssignedActors { __data["assignedActors"] }
            var participants: Participants { __data["participants"] }
            var reviewRequests: ReviewRequests? { __data["reviewRequests"] }
            var comments: Comments { __data["comments"] }
            var latestReviews: LatestReviews? { __data["latestReviews"] }
            var reviewThreads: ReviewThreads { __data["reviewThreads"] }
            var id: GitHubAPI.ID { __data["id"] }
            var number: Int { __data["number"] }
            var pullRequestState: GraphQLEnum<GitHubAPI.PullRequestState> { __data["pullRequestState"] }
            var isDraft: Bool { __data["isDraft"] }
            var title: String { __data["title"] }
            var createdAt: GitHubAPI.DateTime { __data["createdAt"] }
            var updatedAt: GitHubAPI.DateTime { __data["updatedAt"] }
            var closedAt: GitHubAPI.DateTime? { __data["closedAt"] }
            var mergedAt: GitHubAPI.DateTime? { __data["mergedAt"] }
            var author: Author? { __data["author"] }
            var headRefName: String { __data["headRefName"] }
            var headRefOid: GitHubAPI.GitObjectID { __data["headRefOid"] }
            var headRepository: HeadRepository? { __data["headRepository"] }
            var baseRefName: String { __data["baseRefName"] }
            var baseRefOid: GitHubAPI.GitObjectID { __data["baseRefOid"] }
            var baseRepository: BaseRepository? { __data["baseRepository"] }
            var labels: Labels? { __data["labels"] }
            var statusCheckRollup: StatusCheckRollup? { __data["statusCheckRollup"] }
            var reviewDecision: GraphQLEnum<GitHubAPI.PullRequestReviewDecision>? { __data["reviewDecision"] }

            struct Fragments: FragmentContainer {
              let __data: DataDict
              init(_dataDict: DataDict) { __data = _dataDict }

              var gitHubPullRequestSummary: GitHubPullRequestSummary { _toFragment() }
            }

            /// Search.Node.AsPullRequest.AssignedActors
            nonisolated struct AssignedActors: GitHubAPI.SelectionSet {
              let __data: DataDict
              init(_dataDict: DataDict) { __data = _dataDict }

              static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.AssigneeConnection }
              static var __selections: [ApolloAPI.Selection] { [
                .field("__typename", String.self),
                .field("totalCount", Int.self),
                .field("pageInfo", PageInfo.self),
                .field("nodes", [Node?]?.self),
              ] }
              static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                GitHubAttentionCandidatesQuery.Data.Search.Node.AsPullRequest.AssignedActors.self
              ] }

              var totalCount: Int { __data["totalCount"] }
              var pageInfo: PageInfo { __data["pageInfo"] }
              var nodes: [Node?]? { __data["nodes"] }

              /// Search.Node.AsPullRequest.AssignedActors.PageInfo
              nonisolated struct PageInfo: GitHubAPI.SelectionSet {
                let __data: DataDict
                init(_dataDict: DataDict) { __data = _dataDict }

                static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.PageInfo }
                static var __selections: [ApolloAPI.Selection] { [
                  .field("__typename", String.self),
                  .fragment(GitHubPageInfo.self),
                ] }
                static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                  GitHubAttentionCandidatesQuery.Data.Search.Node.AsPullRequest.AssignedActors.PageInfo.self,
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

              /// Search.Node.AsPullRequest.AssignedActors.Node
              nonisolated struct Node: GitHubAPI.SelectionSet {
                let __data: DataDict
                init(_dataDict: DataDict) { __data = _dataDict }

                static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Unions.Assignee }
                static var __selections: [ApolloAPI.Selection] { [
                  .field("__typename", String.self),
                  .fragment(GitHubAssignee.self),
                ] }
                static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                  GitHubAttentionCandidatesQuery.Data.Search.Node.AsPullRequest.AssignedActors.Node.self
                ] }

                var asActor: AsActor? { _asInlineFragment() }
                var asMannequin: AsMannequin? { _asInlineFragment() }

                struct Fragments: FragmentContainer {
                  let __data: DataDict
                  init(_dataDict: DataDict) { __data = _dataDict }

                  var gitHubAssignee: GitHubAssignee { _toFragment() }
                }

                /// Search.Node.AsPullRequest.AssignedActors.Node.AsActor
                nonisolated struct AsActor: GitHubAPI.InlineFragment, ApolloAPI.CompositeInlineFragment {
                  let __data: DataDict
                  init(_dataDict: DataDict) { __data = _dataDict }

                  typealias RootEntityType = GitHubAttentionCandidatesQuery.Data.Search.Node.AsPullRequest.AssignedActors.Node
                  static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Interfaces.Actor }
                  static var __mergedSources: [any ApolloAPI.SelectionSet.Type] { [
                    GitHubAssignee.AsActor.self,
                    GitHubActor.self,
                    GitHubAttentionCandidatesQuery.Data.Search.Node.AsPullRequest.AssignedActors.Node.self
                  ] }
                  static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                    GitHubAttentionCandidatesQuery.Data.Search.Node.AsPullRequest.AssignedActors.Node.self,
                    GitHubAttentionCandidatesQuery.Data.Search.Node.AsPullRequest.AssignedActors.Node.AsActor.self,
                    GitHubAssignee.self,
                    GitHubAssignee.AsActor.self,
                    GitHubActor.self
                  ] }

                  var login: String { __data["login"] }
                  var avatarUrl: GitHubAPI.URI { __data["avatarUrl"] }

                  struct Fragments: FragmentContainer {
                    let __data: DataDict
                    init(_dataDict: DataDict) { __data = _dataDict }

                    var gitHubActor: GitHubActor { _toFragment() }
                    var gitHubAssignee: GitHubAssignee { _toFragment() }
                  }
                }

                /// Search.Node.AsPullRequest.AssignedActors.Node.AsMannequin
                nonisolated struct AsMannequin: GitHubAPI.InlineFragment, ApolloAPI.CompositeInlineFragment {
                  let __data: DataDict
                  init(_dataDict: DataDict) { __data = _dataDict }

                  typealias RootEntityType = GitHubAttentionCandidatesQuery.Data.Search.Node.AsPullRequest.AssignedActors.Node
                  static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.Mannequin }
                  static var __mergedSources: [any ApolloAPI.SelectionSet.Type] { [
                    GitHubAssignee.AsActor.self,
                    GitHubActor.self,
                    GitHubActor.AsNode.self,
                    GitHubAssignee.AsMannequin.self,
                    GitHubAttentionCandidatesQuery.Data.Search.Node.AsPullRequest.AssignedActors.Node.self
                  ] }
                  static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                    GitHubAttentionCandidatesQuery.Data.Search.Node.AsPullRequest.AssignedActors.Node.self,
                    GitHubAttentionCandidatesQuery.Data.Search.Node.AsPullRequest.AssignedActors.Node.AsMannequin.self,
                    GitHubAssignee.self,
                    GitHubAssignee.AsActor.self,
                    GitHubActor.self,
                    GitHubActor.AsNode.self,
                    GitHubAssignee.AsMannequin.self
                  ] }

                  var login: String { __data["login"] }
                  var avatarUrl: GitHubAPI.URI { __data["avatarUrl"] }
                  var id: GitHubAPI.ID { __data["id"] }
                  var mannequinID: GitHubAPI.ID { __data["mannequinID"] }
                  var mannequinLogin: String { __data["mannequinLogin"] }
                  var mannequinAvatarURL: GitHubAPI.URI { __data["mannequinAvatarURL"] }

                  struct Fragments: FragmentContainer {
                    let __data: DataDict
                    init(_dataDict: DataDict) { __data = _dataDict }

                    var gitHubActor: GitHubActor { _toFragment() }
                    var gitHubAssignee: GitHubAssignee { _toFragment() }
                  }
                }
              }
            }

            /// Search.Node.AsPullRequest.Participants
            nonisolated struct Participants: GitHubAPI.SelectionSet {
              let __data: DataDict
              init(_dataDict: DataDict) { __data = _dataDict }

              static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.UserConnection }
              static var __selections: [ApolloAPI.Selection] { [
                .field("__typename", String.self),
                .field("totalCount", Int.self),
                .field("pageInfo", PageInfo.self),
                .field("nodes", [Node?]?.self),
              ] }
              static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                GitHubAttentionCandidatesQuery.Data.Search.Node.AsPullRequest.Participants.self
              ] }

              var totalCount: Int { __data["totalCount"] }
              var pageInfo: PageInfo { __data["pageInfo"] }
              var nodes: [Node?]? { __data["nodes"] }

              /// Search.Node.AsPullRequest.Participants.PageInfo
              nonisolated struct PageInfo: GitHubAPI.SelectionSet {
                let __data: DataDict
                init(_dataDict: DataDict) { __data = _dataDict }

                static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.PageInfo }
                static var __selections: [ApolloAPI.Selection] { [
                  .field("__typename", String.self),
                  .fragment(GitHubPageInfo.self),
                ] }
                static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                  GitHubAttentionCandidatesQuery.Data.Search.Node.AsPullRequest.Participants.PageInfo.self,
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

              /// Search.Node.AsPullRequest.Participants.Node
              nonisolated struct Node: GitHubAPI.SelectionSet {
                let __data: DataDict
                init(_dataDict: DataDict) { __data = _dataDict }

                static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.User }
                static var __selections: [ApolloAPI.Selection] { [
                  .field("__typename", String.self),
                  .fragment(GitHubActor.self),
                ] }
                static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                  GitHubAttentionCandidatesQuery.Data.Search.Node.AsPullRequest.Participants.Node.self,
                  GitHubActor.self,
                  GitHubActor.AsNode.self,
                  GitHubActor.AsUser.self
                ] }

                var login: String { __data["login"] }
                var avatarUrl: GitHubAPI.URI { __data["avatarUrl"] }
                var id: GitHubAPI.ID { __data["id"] }
                var name: String? { __data["name"] }

                var asOrganization: AsOrganization? { _asInlineFragment() }

                struct Fragments: FragmentContainer {
                  let __data: DataDict
                  init(_dataDict: DataDict) { __data = _dataDict }

                  var gitHubActor: GitHubActor { _toFragment() }
                }

                /// Search.Node.AsPullRequest.Participants.Node.AsOrganization
                nonisolated struct AsOrganization: GitHubAPI.InlineFragment, ApolloAPI.CompositeInlineFragment {
                  let __data: DataDict
                  init(_dataDict: DataDict) { __data = _dataDict }

                  typealias RootEntityType = GitHubAttentionCandidatesQuery.Data.Search.Node.AsPullRequest.Participants.Node
                  static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.Organization }
                  static var __mergedSources: [any ApolloAPI.SelectionSet.Type] { [
                    GitHubActor.self,
                    GitHubActor.AsNode.self,
                    GitHubActor.AsUser.self,
                    GitHubActor.AsOrganization.self,
                    GitHubAttentionCandidatesQuery.Data.Search.Node.AsPullRequest.Participants.Node.self
                  ] }
                  static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                    GitHubAttentionCandidatesQuery.Data.Search.Node.AsPullRequest.Participants.Node.self,
                    GitHubAttentionCandidatesQuery.Data.Search.Node.AsPullRequest.Participants.Node.AsOrganization.self,
                    GitHubActor.self,
                    GitHubActor.AsNode.self,
                    GitHubActor.AsUser.self,
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

            /// Search.Node.AsPullRequest.ReviewRequests
            nonisolated struct ReviewRequests: GitHubAPI.SelectionSet {
              let __data: DataDict
              init(_dataDict: DataDict) { __data = _dataDict }

              static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.ReviewRequestConnection }
              static var __selections: [ApolloAPI.Selection] { [
                .field("__typename", String.self),
                .field("totalCount", Int.self),
                .field("pageInfo", PageInfo.self),
                .field("nodes", [Node?]?.self),
              ] }
              static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                GitHubAttentionCandidatesQuery.Data.Search.Node.AsPullRequest.ReviewRequests.self
              ] }

              var totalCount: Int { __data["totalCount"] }
              var pageInfo: PageInfo { __data["pageInfo"] }
              var nodes: [Node?]? { __data["nodes"] }

              /// Search.Node.AsPullRequest.ReviewRequests.PageInfo
              nonisolated struct PageInfo: GitHubAPI.SelectionSet {
                let __data: DataDict
                init(_dataDict: DataDict) { __data = _dataDict }

                static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.PageInfo }
                static var __selections: [ApolloAPI.Selection] { [
                  .field("__typename", String.self),
                  .fragment(GitHubPageInfo.self),
                ] }
                static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                  GitHubAttentionCandidatesQuery.Data.Search.Node.AsPullRequest.ReviewRequests.PageInfo.self,
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

              /// Search.Node.AsPullRequest.ReviewRequests.Node
              nonisolated struct Node: GitHubAPI.SelectionSet {
                let __data: DataDict
                init(_dataDict: DataDict) { __data = _dataDict }

                static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.ReviewRequest }
                static var __selections: [ApolloAPI.Selection] { [
                  .field("__typename", String.self),
                  .field("id", GitHubAPI.ID.self),
                  .field("requestedReviewer", RequestedReviewer?.self),
                ] }
                static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                  GitHubAttentionCandidatesQuery.Data.Search.Node.AsPullRequest.ReviewRequests.Node.self
                ] }

                var id: GitHubAPI.ID { __data["id"] }
                var requestedReviewer: RequestedReviewer? { __data["requestedReviewer"] }

                /// Search.Node.AsPullRequest.ReviewRequests.Node.RequestedReviewer
                nonisolated struct RequestedReviewer: GitHubAPI.SelectionSet {
                  let __data: DataDict
                  init(_dataDict: DataDict) { __data = _dataDict }

                  static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Unions.RequestedReviewer }
                  static var __selections: [ApolloAPI.Selection] { [
                    .field("__typename", String.self),
                    .fragment(GitHubRequestedReviewer.self),
                  ] }
                  static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                    GitHubAttentionCandidatesQuery.Data.Search.Node.AsPullRequest.ReviewRequests.Node.RequestedReviewer.self
                  ] }

                  var asActor: AsActor? { _asInlineFragment() }
                  var asMannequin: AsMannequin? { _asInlineFragment() }
                  var asTeam: AsTeam? { _asInlineFragment() }

                  struct Fragments: FragmentContainer {
                    let __data: DataDict
                    init(_dataDict: DataDict) { __data = _dataDict }

                    var gitHubRequestedReviewer: GitHubRequestedReviewer { _toFragment() }
                  }

                  /// Search.Node.AsPullRequest.ReviewRequests.Node.RequestedReviewer.AsActor
                  nonisolated struct AsActor: GitHubAPI.InlineFragment, ApolloAPI.CompositeInlineFragment {
                    let __data: DataDict
                    init(_dataDict: DataDict) { __data = _dataDict }

                    typealias RootEntityType = GitHubAttentionCandidatesQuery.Data.Search.Node.AsPullRequest.ReviewRequests.Node.RequestedReviewer
                    static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Interfaces.Actor }
                    static var __mergedSources: [any ApolloAPI.SelectionSet.Type] { [
                      GitHubRequestedReviewer.AsActor.self,
                      GitHubActor.self,
                      GitHubAttentionCandidatesQuery.Data.Search.Node.AsPullRequest.ReviewRequests.Node.RequestedReviewer.self
                    ] }
                    static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                      GitHubAttentionCandidatesQuery.Data.Search.Node.AsPullRequest.ReviewRequests.Node.RequestedReviewer.self,
                      GitHubAttentionCandidatesQuery.Data.Search.Node.AsPullRequest.ReviewRequests.Node.RequestedReviewer.AsActor.self,
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
                      var gitHubRequestedReviewer: GitHubRequestedReviewer { _toFragment() }
                    }
                  }

                  /// Search.Node.AsPullRequest.ReviewRequests.Node.RequestedReviewer.AsMannequin
                  nonisolated struct AsMannequin: GitHubAPI.InlineFragment, ApolloAPI.CompositeInlineFragment {
                    let __data: DataDict
                    init(_dataDict: DataDict) { __data = _dataDict }

                    typealias RootEntityType = GitHubAttentionCandidatesQuery.Data.Search.Node.AsPullRequest.ReviewRequests.Node.RequestedReviewer
                    static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.Mannequin }
                    static var __mergedSources: [any ApolloAPI.SelectionSet.Type] { [
                      GitHubRequestedReviewer.AsActor.self,
                      GitHubActor.self,
                      GitHubActor.AsNode.self,
                      GitHubRequestedReviewer.AsMannequin.self,
                      GitHubAttentionCandidatesQuery.Data.Search.Node.AsPullRequest.ReviewRequests.Node.RequestedReviewer.self
                    ] }
                    static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                      GitHubAttentionCandidatesQuery.Data.Search.Node.AsPullRequest.ReviewRequests.Node.RequestedReviewer.self,
                      GitHubAttentionCandidatesQuery.Data.Search.Node.AsPullRequest.ReviewRequests.Node.RequestedReviewer.AsMannequin.self,
                      GitHubRequestedReviewer.self,
                      GitHubRequestedReviewer.AsActor.self,
                      GitHubActor.self,
                      GitHubActor.AsNode.self,
                      GitHubRequestedReviewer.AsMannequin.self
                    ] }

                    var login: String { __data["login"] }
                    var avatarUrl: GitHubAPI.URI { __data["avatarUrl"] }
                    var id: GitHubAPI.ID { __data["id"] }
                    var mannequinID: GitHubAPI.ID { __data["mannequinID"] }
                    var mannequinLogin: String { __data["mannequinLogin"] }
                    var mannequinAvatarURL: GitHubAPI.URI { __data["mannequinAvatarURL"] }

                    struct Fragments: FragmentContainer {
                      let __data: DataDict
                      init(_dataDict: DataDict) { __data = _dataDict }

                      var gitHubActor: GitHubActor { _toFragment() }
                      var gitHubRequestedReviewer: GitHubRequestedReviewer { _toFragment() }
                    }
                  }

                  /// Search.Node.AsPullRequest.ReviewRequests.Node.RequestedReviewer.AsTeam
                  nonisolated struct AsTeam: GitHubAPI.InlineFragment, ApolloAPI.CompositeInlineFragment {
                    let __data: DataDict
                    init(_dataDict: DataDict) { __data = _dataDict }

                    typealias RootEntityType = GitHubAttentionCandidatesQuery.Data.Search.Node.AsPullRequest.ReviewRequests.Node.RequestedReviewer
                    static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.Team }
                    static var __mergedSources: [any ApolloAPI.SelectionSet.Type] { [
                      GitHubRequestedReviewer.AsTeam.self,
                      GitHubAttentionCandidatesQuery.Data.Search.Node.AsPullRequest.ReviewRequests.Node.RequestedReviewer.self
                    ] }
                    static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                      GitHubAttentionCandidatesQuery.Data.Search.Node.AsPullRequest.ReviewRequests.Node.RequestedReviewer.self,
                      GitHubAttentionCandidatesQuery.Data.Search.Node.AsPullRequest.ReviewRequests.Node.RequestedReviewer.AsTeam.self,
                      GitHubRequestedReviewer.self,
                      GitHubRequestedReviewer.AsTeam.self
                    ] }

                    var teamID: GitHubAPI.ID { __data["teamID"] }
                    var teamName: String { __data["teamName"] }
                    var teamSlug: String { __data["teamSlug"] }
                    var teamAvatarURL: GitHubAPI.URI? { __data["teamAvatarURL"] }

                    struct Fragments: FragmentContainer {
                      let __data: DataDict
                      init(_dataDict: DataDict) { __data = _dataDict }

                      var gitHubRequestedReviewer: GitHubRequestedReviewer { _toFragment() }
                    }
                  }
                }
              }
            }

            /// Search.Node.AsPullRequest.Comments
            nonisolated struct Comments: GitHubAPI.SelectionSet {
              let __data: DataDict
              init(_dataDict: DataDict) { __data = _dataDict }

              static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.IssueCommentConnection }
              static var __selections: [ApolloAPI.Selection] { [
                .field("__typename", String.self),
                .field("totalCount", Int.self),
                .field("pageInfo", PageInfo.self),
                .field("nodes", [Node?]?.self),
              ] }
              static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                GitHubAttentionCandidatesQuery.Data.Search.Node.AsPullRequest.Comments.self
              ] }

              var totalCount: Int { __data["totalCount"] }
              var pageInfo: PageInfo { __data["pageInfo"] }
              var nodes: [Node?]? { __data["nodes"] }

              /// Search.Node.AsPullRequest.Comments.PageInfo
              nonisolated struct PageInfo: GitHubAPI.SelectionSet {
                let __data: DataDict
                init(_dataDict: DataDict) { __data = _dataDict }

                static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.PageInfo }
                static var __selections: [ApolloAPI.Selection] { [
                  .field("__typename", String.self),
                  .fragment(GitHubPageInfo.self),
                ] }
                static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                  GitHubAttentionCandidatesQuery.Data.Search.Node.AsPullRequest.Comments.PageInfo.self,
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

              /// Search.Node.AsPullRequest.Comments.Node
              nonisolated struct Node: GitHubAPI.SelectionSet {
                let __data: DataDict
                init(_dataDict: DataDict) { __data = _dataDict }

                static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.IssueComment }
                static var __selections: [ApolloAPI.Selection] { [
                  .field("__typename", String.self),
                  .fragment(GitHubIssueComment.self),
                ] }
                static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                  GitHubAttentionCandidatesQuery.Data.Search.Node.AsPullRequest.Comments.Node.self,
                  GitHubIssueComment.self
                ] }

                var id: GitHubAPI.ID { __data["id"] }
                var body: String { __data["body"] }
                var createdAt: GitHubAPI.DateTime { __data["createdAt"] }
                var updatedAt: GitHubAPI.DateTime { __data["updatedAt"] }
                var author: Author? { __data["author"] }

                struct Fragments: FragmentContainer {
                  let __data: DataDict
                  init(_dataDict: DataDict) { __data = _dataDict }

                  var gitHubIssueComment: GitHubIssueComment { _toFragment() }
                }

                typealias Author = GitHubIssueComment.Author
              }
            }

            /// Search.Node.AsPullRequest.LatestReviews
            nonisolated struct LatestReviews: GitHubAPI.SelectionSet {
              let __data: DataDict
              init(_dataDict: DataDict) { __data = _dataDict }

              static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.PullRequestReviewConnection }
              static var __selections: [ApolloAPI.Selection] { [
                .field("__typename", String.self),
                .field("totalCount", Int.self),
                .field("pageInfo", PageInfo.self),
                .field("nodes", [Node?]?.self),
              ] }
              static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                GitHubAttentionCandidatesQuery.Data.Search.Node.AsPullRequest.LatestReviews.self
              ] }

              var totalCount: Int { __data["totalCount"] }
              var pageInfo: PageInfo { __data["pageInfo"] }
              var nodes: [Node?]? { __data["nodes"] }

              /// Search.Node.AsPullRequest.LatestReviews.PageInfo
              nonisolated struct PageInfo: GitHubAPI.SelectionSet {
                let __data: DataDict
                init(_dataDict: DataDict) { __data = _dataDict }

                static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.PageInfo }
                static var __selections: [ApolloAPI.Selection] { [
                  .field("__typename", String.self),
                  .fragment(GitHubPageInfo.self),
                ] }
                static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                  GitHubAttentionCandidatesQuery.Data.Search.Node.AsPullRequest.LatestReviews.PageInfo.self,
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

              /// Search.Node.AsPullRequest.LatestReviews.Node
              nonisolated struct Node: GitHubAPI.SelectionSet {
                let __data: DataDict
                init(_dataDict: DataDict) { __data = _dataDict }

                static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.PullRequestReview }
                static var __selections: [ApolloAPI.Selection] { [
                  .field("__typename", String.self),
                  .field("id", GitHubAPI.ID.self),
                  .field("body", String.self),
                  .field("state", GraphQLEnum<GitHubAPI.PullRequestReviewState>.self),
                  .field("submittedAt", GitHubAPI.DateTime?.self),
                  .field("author", Author?.self),
                ] }
                static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                  GitHubAttentionCandidatesQuery.Data.Search.Node.AsPullRequest.LatestReviews.Node.self
                ] }

                var id: GitHubAPI.ID { __data["id"] }
                var body: String { __data["body"] }
                var state: GraphQLEnum<GitHubAPI.PullRequestReviewState> { __data["state"] }
                var submittedAt: GitHubAPI.DateTime? { __data["submittedAt"] }
                var author: Author? { __data["author"] }

                /// Search.Node.AsPullRequest.LatestReviews.Node.Author
                nonisolated struct Author: GitHubAPI.SelectionSet {
                  let __data: DataDict
                  init(_dataDict: DataDict) { __data = _dataDict }

                  static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Interfaces.Actor }
                  static var __selections: [ApolloAPI.Selection] { [
                    .field("__typename", String.self),
                    .fragment(GitHubActor.self),
                  ] }
                  static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                    GitHubAttentionCandidatesQuery.Data.Search.Node.AsPullRequest.LatestReviews.Node.Author.self,
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

                  /// Search.Node.AsPullRequest.LatestReviews.Node.Author.AsNode
                  nonisolated struct AsNode: GitHubAPI.InlineFragment, ApolloAPI.CompositeInlineFragment {
                    let __data: DataDict
                    init(_dataDict: DataDict) { __data = _dataDict }

                    typealias RootEntityType = GitHubAttentionCandidatesQuery.Data.Search.Node.AsPullRequest.LatestReviews.Node.Author
                    static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Interfaces.Node }
                    static var __mergedSources: [any ApolloAPI.SelectionSet.Type] { [
                      GitHubActor.self,
                      GitHubActor.AsNode.self,
                      GitHubAttentionCandidatesQuery.Data.Search.Node.AsPullRequest.LatestReviews.Node.Author.self
                    ] }
                    static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                      GitHubAttentionCandidatesQuery.Data.Search.Node.AsPullRequest.LatestReviews.Node.Author.self,
                      GitHubAttentionCandidatesQuery.Data.Search.Node.AsPullRequest.LatestReviews.Node.Author.AsNode.self,
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

                  /// Search.Node.AsPullRequest.LatestReviews.Node.Author.AsUser
                  nonisolated struct AsUser: GitHubAPI.InlineFragment, ApolloAPI.CompositeInlineFragment {
                    let __data: DataDict
                    init(_dataDict: DataDict) { __data = _dataDict }

                    typealias RootEntityType = GitHubAttentionCandidatesQuery.Data.Search.Node.AsPullRequest.LatestReviews.Node.Author
                    static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.User }
                    static var __mergedSources: [any ApolloAPI.SelectionSet.Type] { [
                      GitHubActor.self,
                      GitHubActor.AsNode.self,
                      GitHubActor.AsUser.self,
                      GitHubAttentionCandidatesQuery.Data.Search.Node.AsPullRequest.LatestReviews.Node.Author.self
                    ] }
                    static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                      GitHubAttentionCandidatesQuery.Data.Search.Node.AsPullRequest.LatestReviews.Node.Author.self,
                      GitHubAttentionCandidatesQuery.Data.Search.Node.AsPullRequest.LatestReviews.Node.Author.AsUser.self,
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

                  /// Search.Node.AsPullRequest.LatestReviews.Node.Author.AsOrganization
                  nonisolated struct AsOrganization: GitHubAPI.InlineFragment, ApolloAPI.CompositeInlineFragment {
                    let __data: DataDict
                    init(_dataDict: DataDict) { __data = _dataDict }

                    typealias RootEntityType = GitHubAttentionCandidatesQuery.Data.Search.Node.AsPullRequest.LatestReviews.Node.Author
                    static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.Organization }
                    static var __mergedSources: [any ApolloAPI.SelectionSet.Type] { [
                      GitHubActor.self,
                      GitHubActor.AsNode.self,
                      GitHubActor.AsOrganization.self,
                      GitHubAttentionCandidatesQuery.Data.Search.Node.AsPullRequest.LatestReviews.Node.Author.self
                    ] }
                    static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                      GitHubAttentionCandidatesQuery.Data.Search.Node.AsPullRequest.LatestReviews.Node.Author.self,
                      GitHubAttentionCandidatesQuery.Data.Search.Node.AsPullRequest.LatestReviews.Node.Author.AsOrganization.self,
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

            /// Search.Node.AsPullRequest.ReviewThreads
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
                GitHubAttentionCandidatesQuery.Data.Search.Node.AsPullRequest.ReviewThreads.self
              ] }

              var totalCount: Int { __data["totalCount"] }
              var pageInfo: PageInfo { __data["pageInfo"] }
              var nodes: [Node?]? { __data["nodes"] }

              /// Search.Node.AsPullRequest.ReviewThreads.PageInfo
              nonisolated struct PageInfo: GitHubAPI.SelectionSet {
                let __data: DataDict
                init(_dataDict: DataDict) { __data = _dataDict }

                static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.PageInfo }
                static var __selections: [ApolloAPI.Selection] { [
                  .field("__typename", String.self),
                  .fragment(GitHubPageInfo.self),
                ] }
                static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                  GitHubAttentionCandidatesQuery.Data.Search.Node.AsPullRequest.ReviewThreads.PageInfo.self,
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

              /// Search.Node.AsPullRequest.ReviewThreads.Node
              nonisolated struct Node: GitHubAPI.SelectionSet {
                let __data: DataDict
                init(_dataDict: DataDict) { __data = _dataDict }

                static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.PullRequestReviewThread }
                static var __selections: [ApolloAPI.Selection] { [
                  .field("__typename", String.self),
                  .field("id", GitHubAPI.ID.self),
                  .field("isResolved", Bool.self),
                  .field("isOutdated", Bool.self),
                  .field("comments", Comments.self, arguments: ["last": .variable("activityLast")]),
                ] }
                static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                  GitHubAttentionCandidatesQuery.Data.Search.Node.AsPullRequest.ReviewThreads.Node.self
                ] }

                var id: GitHubAPI.ID { __data["id"] }
                var isResolved: Bool { __data["isResolved"] }
                var isOutdated: Bool { __data["isOutdated"] }
                var comments: Comments { __data["comments"] }

                /// Search.Node.AsPullRequest.ReviewThreads.Node.Comments
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
                    GitHubAttentionCandidatesQuery.Data.Search.Node.AsPullRequest.ReviewThreads.Node.Comments.self
                  ] }

                  var totalCount: Int { __data["totalCount"] }
                  var pageInfo: PageInfo { __data["pageInfo"] }
                  var nodes: [Node?]? { __data["nodes"] }

                  /// Search.Node.AsPullRequest.ReviewThreads.Node.Comments.PageInfo
                  nonisolated struct PageInfo: GitHubAPI.SelectionSet {
                    let __data: DataDict
                    init(_dataDict: DataDict) { __data = _dataDict }

                    static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.PageInfo }
                    static var __selections: [ApolloAPI.Selection] { [
                      .field("__typename", String.self),
                      .fragment(GitHubPageInfo.self),
                    ] }
                    static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                      GitHubAttentionCandidatesQuery.Data.Search.Node.AsPullRequest.ReviewThreads.Node.Comments.PageInfo.self,
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

                  /// Search.Node.AsPullRequest.ReviewThreads.Node.Comments.Node
                  nonisolated struct Node: GitHubAPI.SelectionSet {
                    let __data: DataDict
                    init(_dataDict: DataDict) { __data = _dataDict }

                    static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.PullRequestReviewComment }
                    static var __selections: [ApolloAPI.Selection] { [
                      .field("__typename", String.self),
                      .fragment(GitHubReviewComment.self),
                    ] }
                    static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                      GitHubAttentionCandidatesQuery.Data.Search.Node.AsPullRequest.ReviewThreads.Node.Comments.Node.self,
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

            typealias Author = GitHubPullRequestSummary.Author

            typealias HeadRepository = GitHubPullRequestSummary.HeadRepository

            typealias BaseRepository = GitHubPullRequestSummary.BaseRepository

            typealias Labels = GitHubPullRequestSummary.Labels

            typealias StatusCheckRollup = GitHubPullRequestSummary.StatusCheckRollup
          }

          /// Search.Node.AsIssue
          nonisolated struct AsIssue: GitHubAPI.InlineFragment {
            let __data: DataDict
            init(_dataDict: DataDict) { __data = _dataDict }

            typealias RootEntityType = GitHubAttentionCandidatesQuery.Data.Search.Node
            static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.Issue }
            static var __selections: [ApolloAPI.Selection] { [
              .field("body", String.self),
              .field("assignedActors", AssignedActors.self, arguments: ["first": 100]),
              .field("participants", Participants.self, arguments: ["first": 100]),
              .field("comments", Comments.self, arguments: ["last": .variable("activityLast")]),
              .fragment(GitHubIssueSummary.self),
            ] }
            static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
              GitHubAttentionCandidatesQuery.Data.Search.Node.self,
              GitHubAttentionCandidatesQuery.Data.Search.Node.AsIssue.self,
              GitHubIssueSummary.self
            ] }

            var body: String { __data["body"] }
            var assignedActors: AssignedActors { __data["assignedActors"] }
            var participants: Participants { __data["participants"] }
            var comments: Comments { __data["comments"] }
            var id: GitHubAPI.ID { __data["id"] }
            var number: Int { __data["number"] }
            var issueState: GraphQLEnum<GitHubAPI.IssueState> { __data["issueState"] }
            var title: String { __data["title"] }
            var createdAt: GitHubAPI.DateTime { __data["createdAt"] }
            var updatedAt: GitHubAPI.DateTime { __data["updatedAt"] }
            var closedAt: GitHubAPI.DateTime? { __data["closedAt"] }
            var author: Author? { __data["author"] }
            var labels: Labels? { __data["labels"] }

            struct Fragments: FragmentContainer {
              let __data: DataDict
              init(_dataDict: DataDict) { __data = _dataDict }

              var gitHubIssueSummary: GitHubIssueSummary { _toFragment() }
            }

            /// Search.Node.AsIssue.AssignedActors
            nonisolated struct AssignedActors: GitHubAPI.SelectionSet {
              let __data: DataDict
              init(_dataDict: DataDict) { __data = _dataDict }

              static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.AssigneeConnection }
              static var __selections: [ApolloAPI.Selection] { [
                .field("__typename", String.self),
                .field("totalCount", Int.self),
                .field("pageInfo", PageInfo.self),
                .field("nodes", [Node?]?.self),
              ] }
              static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                GitHubAttentionCandidatesQuery.Data.Search.Node.AsIssue.AssignedActors.self
              ] }

              var totalCount: Int { __data["totalCount"] }
              var pageInfo: PageInfo { __data["pageInfo"] }
              var nodes: [Node?]? { __data["nodes"] }

              /// Search.Node.AsIssue.AssignedActors.PageInfo
              nonisolated struct PageInfo: GitHubAPI.SelectionSet {
                let __data: DataDict
                init(_dataDict: DataDict) { __data = _dataDict }

                static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.PageInfo }
                static var __selections: [ApolloAPI.Selection] { [
                  .field("__typename", String.self),
                  .fragment(GitHubPageInfo.self),
                ] }
                static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                  GitHubAttentionCandidatesQuery.Data.Search.Node.AsIssue.AssignedActors.PageInfo.self,
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

              /// Search.Node.AsIssue.AssignedActors.Node
              nonisolated struct Node: GitHubAPI.SelectionSet {
                let __data: DataDict
                init(_dataDict: DataDict) { __data = _dataDict }

                static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Unions.Assignee }
                static var __selections: [ApolloAPI.Selection] { [
                  .field("__typename", String.self),
                  .fragment(GitHubAssignee.self),
                ] }
                static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                  GitHubAttentionCandidatesQuery.Data.Search.Node.AsIssue.AssignedActors.Node.self
                ] }

                var asActor: AsActor? { _asInlineFragment() }
                var asMannequin: AsMannequin? { _asInlineFragment() }

                struct Fragments: FragmentContainer {
                  let __data: DataDict
                  init(_dataDict: DataDict) { __data = _dataDict }

                  var gitHubAssignee: GitHubAssignee { _toFragment() }
                }

                /// Search.Node.AsIssue.AssignedActors.Node.AsActor
                nonisolated struct AsActor: GitHubAPI.InlineFragment, ApolloAPI.CompositeInlineFragment {
                  let __data: DataDict
                  init(_dataDict: DataDict) { __data = _dataDict }

                  typealias RootEntityType = GitHubAttentionCandidatesQuery.Data.Search.Node.AsIssue.AssignedActors.Node
                  static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Interfaces.Actor }
                  static var __mergedSources: [any ApolloAPI.SelectionSet.Type] { [
                    GitHubAssignee.AsActor.self,
                    GitHubActor.self,
                    GitHubAttentionCandidatesQuery.Data.Search.Node.AsIssue.AssignedActors.Node.self
                  ] }
                  static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                    GitHubAttentionCandidatesQuery.Data.Search.Node.AsIssue.AssignedActors.Node.self,
                    GitHubAttentionCandidatesQuery.Data.Search.Node.AsIssue.AssignedActors.Node.AsActor.self,
                    GitHubAssignee.self,
                    GitHubAssignee.AsActor.self,
                    GitHubActor.self
                  ] }

                  var login: String { __data["login"] }
                  var avatarUrl: GitHubAPI.URI { __data["avatarUrl"] }

                  struct Fragments: FragmentContainer {
                    let __data: DataDict
                    init(_dataDict: DataDict) { __data = _dataDict }

                    var gitHubActor: GitHubActor { _toFragment() }
                    var gitHubAssignee: GitHubAssignee { _toFragment() }
                  }
                }

                /// Search.Node.AsIssue.AssignedActors.Node.AsMannequin
                nonisolated struct AsMannequin: GitHubAPI.InlineFragment, ApolloAPI.CompositeInlineFragment {
                  let __data: DataDict
                  init(_dataDict: DataDict) { __data = _dataDict }

                  typealias RootEntityType = GitHubAttentionCandidatesQuery.Data.Search.Node.AsIssue.AssignedActors.Node
                  static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.Mannequin }
                  static var __mergedSources: [any ApolloAPI.SelectionSet.Type] { [
                    GitHubAssignee.AsActor.self,
                    GitHubActor.self,
                    GitHubActor.AsNode.self,
                    GitHubAssignee.AsMannequin.self,
                    GitHubAttentionCandidatesQuery.Data.Search.Node.AsIssue.AssignedActors.Node.self
                  ] }
                  static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                    GitHubAttentionCandidatesQuery.Data.Search.Node.AsIssue.AssignedActors.Node.self,
                    GitHubAttentionCandidatesQuery.Data.Search.Node.AsIssue.AssignedActors.Node.AsMannequin.self,
                    GitHubAssignee.self,
                    GitHubAssignee.AsActor.self,
                    GitHubActor.self,
                    GitHubActor.AsNode.self,
                    GitHubAssignee.AsMannequin.self
                  ] }

                  var login: String { __data["login"] }
                  var avatarUrl: GitHubAPI.URI { __data["avatarUrl"] }
                  var id: GitHubAPI.ID { __data["id"] }
                  var mannequinID: GitHubAPI.ID { __data["mannequinID"] }
                  var mannequinLogin: String { __data["mannequinLogin"] }
                  var mannequinAvatarURL: GitHubAPI.URI { __data["mannequinAvatarURL"] }

                  struct Fragments: FragmentContainer {
                    let __data: DataDict
                    init(_dataDict: DataDict) { __data = _dataDict }

                    var gitHubActor: GitHubActor { _toFragment() }
                    var gitHubAssignee: GitHubAssignee { _toFragment() }
                  }
                }
              }
            }

            /// Search.Node.AsIssue.Participants
            nonisolated struct Participants: GitHubAPI.SelectionSet {
              let __data: DataDict
              init(_dataDict: DataDict) { __data = _dataDict }

              static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.UserConnection }
              static var __selections: [ApolloAPI.Selection] { [
                .field("__typename", String.self),
                .field("totalCount", Int.self),
                .field("pageInfo", PageInfo.self),
                .field("nodes", [Node?]?.self),
              ] }
              static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                GitHubAttentionCandidatesQuery.Data.Search.Node.AsIssue.Participants.self
              ] }

              var totalCount: Int { __data["totalCount"] }
              var pageInfo: PageInfo { __data["pageInfo"] }
              var nodes: [Node?]? { __data["nodes"] }

              /// Search.Node.AsIssue.Participants.PageInfo
              nonisolated struct PageInfo: GitHubAPI.SelectionSet {
                let __data: DataDict
                init(_dataDict: DataDict) { __data = _dataDict }

                static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.PageInfo }
                static var __selections: [ApolloAPI.Selection] { [
                  .field("__typename", String.self),
                  .fragment(GitHubPageInfo.self),
                ] }
                static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                  GitHubAttentionCandidatesQuery.Data.Search.Node.AsIssue.Participants.PageInfo.self,
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

              /// Search.Node.AsIssue.Participants.Node
              nonisolated struct Node: GitHubAPI.SelectionSet {
                let __data: DataDict
                init(_dataDict: DataDict) { __data = _dataDict }

                static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.User }
                static var __selections: [ApolloAPI.Selection] { [
                  .field("__typename", String.self),
                  .fragment(GitHubActor.self),
                ] }
                static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                  GitHubAttentionCandidatesQuery.Data.Search.Node.AsIssue.Participants.Node.self,
                  GitHubActor.self,
                  GitHubActor.AsNode.self,
                  GitHubActor.AsUser.self
                ] }

                var login: String { __data["login"] }
                var avatarUrl: GitHubAPI.URI { __data["avatarUrl"] }
                var id: GitHubAPI.ID { __data["id"] }
                var name: String? { __data["name"] }

                var asOrganization: AsOrganization? { _asInlineFragment() }

                struct Fragments: FragmentContainer {
                  let __data: DataDict
                  init(_dataDict: DataDict) { __data = _dataDict }

                  var gitHubActor: GitHubActor { _toFragment() }
                }

                /// Search.Node.AsIssue.Participants.Node.AsOrganization
                nonisolated struct AsOrganization: GitHubAPI.InlineFragment, ApolloAPI.CompositeInlineFragment {
                  let __data: DataDict
                  init(_dataDict: DataDict) { __data = _dataDict }

                  typealias RootEntityType = GitHubAttentionCandidatesQuery.Data.Search.Node.AsIssue.Participants.Node
                  static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.Organization }
                  static var __mergedSources: [any ApolloAPI.SelectionSet.Type] { [
                    GitHubActor.self,
                    GitHubActor.AsNode.self,
                    GitHubActor.AsUser.self,
                    GitHubActor.AsOrganization.self,
                    GitHubAttentionCandidatesQuery.Data.Search.Node.AsIssue.Participants.Node.self
                  ] }
                  static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                    GitHubAttentionCandidatesQuery.Data.Search.Node.AsIssue.Participants.Node.self,
                    GitHubAttentionCandidatesQuery.Data.Search.Node.AsIssue.Participants.Node.AsOrganization.self,
                    GitHubActor.self,
                    GitHubActor.AsNode.self,
                    GitHubActor.AsUser.self,
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

            /// Search.Node.AsIssue.Comments
            nonisolated struct Comments: GitHubAPI.SelectionSet {
              let __data: DataDict
              init(_dataDict: DataDict) { __data = _dataDict }

              static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.IssueCommentConnection }
              static var __selections: [ApolloAPI.Selection] { [
                .field("__typename", String.self),
                .field("totalCount", Int.self),
                .field("pageInfo", PageInfo.self),
                .field("nodes", [Node?]?.self),
              ] }
              static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                GitHubAttentionCandidatesQuery.Data.Search.Node.AsIssue.Comments.self
              ] }

              var totalCount: Int { __data["totalCount"] }
              var pageInfo: PageInfo { __data["pageInfo"] }
              var nodes: [Node?]? { __data["nodes"] }

              /// Search.Node.AsIssue.Comments.PageInfo
              nonisolated struct PageInfo: GitHubAPI.SelectionSet {
                let __data: DataDict
                init(_dataDict: DataDict) { __data = _dataDict }

                static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.PageInfo }
                static var __selections: [ApolloAPI.Selection] { [
                  .field("__typename", String.self),
                  .fragment(GitHubPageInfo.self),
                ] }
                static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                  GitHubAttentionCandidatesQuery.Data.Search.Node.AsIssue.Comments.PageInfo.self,
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

              /// Search.Node.AsIssue.Comments.Node
              nonisolated struct Node: GitHubAPI.SelectionSet {
                let __data: DataDict
                init(_dataDict: DataDict) { __data = _dataDict }

                static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.IssueComment }
                static var __selections: [ApolloAPI.Selection] { [
                  .field("__typename", String.self),
                  .fragment(GitHubIssueComment.self),
                ] }
                static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                  GitHubAttentionCandidatesQuery.Data.Search.Node.AsIssue.Comments.Node.self,
                  GitHubIssueComment.self
                ] }

                var id: GitHubAPI.ID { __data["id"] }
                var body: String { __data["body"] }
                var createdAt: GitHubAPI.DateTime { __data["createdAt"] }
                var updatedAt: GitHubAPI.DateTime { __data["updatedAt"] }
                var author: Author? { __data["author"] }

                struct Fragments: FragmentContainer {
                  let __data: DataDict
                  init(_dataDict: DataDict) { __data = _dataDict }

                  var gitHubIssueComment: GitHubIssueComment { _toFragment() }
                }

                typealias Author = GitHubIssueComment.Author
              }
            }

            typealias Author = GitHubIssueSummary.Author

            typealias Labels = GitHubIssueSummary.Labels
          }
        }
      }
    }
  }

}
