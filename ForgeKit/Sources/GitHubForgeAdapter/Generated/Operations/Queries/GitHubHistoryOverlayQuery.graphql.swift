// @generated
// This file was automatically generated and should not be edited.

import ApolloAPI
@_spi(Execution) @_spi(Unsafe) import ApolloAPI

extension GitHubAPI {
  nonisolated struct GitHubHistoryOverlayQuery: GraphQLQuery {
    static let operationName: String = "GitHubHistoryOverlay"
    static let operationDocument: ApolloAPI.OperationDocument = .init(
      definition: .init(
        #"query GitHubHistoryOverlay($owner: String!, $name: String!, $oid: GitObjectID!, $pullRequestFirst: Int!, $pullRequestAfter: String) { repository(owner: $owner, name: $name) { __typename id object(oid: $oid) { __typename ... on Commit { oid statusCheckRollup { __typename state } associatedPullRequests(first: $pullRequestFirst, after: $pullRequestAfter) { __typename totalCount pageInfo { __typename ...GitHubPageInfo } nodes { __typename ...GitHubPullRequestSummary } } } } } }"#,
        fragments: [GitHubActor.self, GitHubLabel.self, GitHubPageInfo.self, GitHubPullRequestSummary.self, GitHubRepositoryIdentity.self]
      ))

    public var owner: String
    public var name: String
    public var oid: GitObjectID
    public var pullRequestFirst: Int32
    public var pullRequestAfter: GraphQLNullable<String>

    public init(
      owner: String,
      name: String,
      oid: GitObjectID,
      pullRequestFirst: Int32,
      pullRequestAfter: GraphQLNullable<String>
    ) {
      self.owner = owner
      self.name = name
      self.oid = oid
      self.pullRequestFirst = pullRequestFirst
      self.pullRequestAfter = pullRequestAfter
    }

    @_spi(Unsafe) public var __variables: Variables? { [
      "owner": owner,
      "name": name,
      "oid": oid,
      "pullRequestFirst": pullRequestFirst,
      "pullRequestAfter": pullRequestAfter
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
        GitHubHistoryOverlayQuery.Data.self
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
          .field("object", Object?.self, arguments: ["oid": .variable("oid")]),
        ] }
        static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
          GitHubHistoryOverlayQuery.Data.Repository.self
        ] }

        var id: GitHubAPI.ID { __data["id"] }
        var object: Object? { __data["object"] }

        /// Repository.Object
        nonisolated struct Object: GitHubAPI.SelectionSet {
          let __data: DataDict
          init(_dataDict: DataDict) { __data = _dataDict }

          static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Interfaces.GitObject }
          static var __selections: [ApolloAPI.Selection] { [
            .field("__typename", String.self),
            .inlineFragment(AsCommit.self),
          ] }
          static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
            GitHubHistoryOverlayQuery.Data.Repository.Object.self
          ] }

          var asCommit: AsCommit? { _asInlineFragment() }

          /// Repository.Object.AsCommit
          nonisolated struct AsCommit: GitHubAPI.InlineFragment {
            let __data: DataDict
            init(_dataDict: DataDict) { __data = _dataDict }

            typealias RootEntityType = GitHubHistoryOverlayQuery.Data.Repository.Object
            static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.Commit }
            static var __selections: [ApolloAPI.Selection] { [
              .field("oid", GitHubAPI.GitObjectID.self),
              .field("statusCheckRollup", StatusCheckRollup?.self),
              .field("associatedPullRequests", AssociatedPullRequests?.self, arguments: [
                "first": .variable("pullRequestFirst"),
                "after": .variable("pullRequestAfter")
              ]),
            ] }
            static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
              GitHubHistoryOverlayQuery.Data.Repository.Object.self,
              GitHubHistoryOverlayQuery.Data.Repository.Object.AsCommit.self
            ] }

            var oid: GitHubAPI.GitObjectID { __data["oid"] }
            var statusCheckRollup: StatusCheckRollup? { __data["statusCheckRollup"] }
            var associatedPullRequests: AssociatedPullRequests? { __data["associatedPullRequests"] }

            /// Repository.Object.AsCommit.StatusCheckRollup
            nonisolated struct StatusCheckRollup: GitHubAPI.SelectionSet {
              let __data: DataDict
              init(_dataDict: DataDict) { __data = _dataDict }

              static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.StatusCheckRollup }
              static var __selections: [ApolloAPI.Selection] { [
                .field("__typename", String.self),
                .field("state", GraphQLEnum<GitHubAPI.StatusState>.self),
              ] }
              static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                GitHubHistoryOverlayQuery.Data.Repository.Object.AsCommit.StatusCheckRollup.self
              ] }

              var state: GraphQLEnum<GitHubAPI.StatusState> { __data["state"] }
            }

            /// Repository.Object.AsCommit.AssociatedPullRequests
            nonisolated struct AssociatedPullRequests: GitHubAPI.SelectionSet {
              let __data: DataDict
              init(_dataDict: DataDict) { __data = _dataDict }

              static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.PullRequestConnection }
              static var __selections: [ApolloAPI.Selection] { [
                .field("__typename", String.self),
                .field("totalCount", Int.self),
                .field("pageInfo", PageInfo.self),
                .field("nodes", [Node?]?.self),
              ] }
              static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                GitHubHistoryOverlayQuery.Data.Repository.Object.AsCommit.AssociatedPullRequests.self
              ] }

              var totalCount: Int { __data["totalCount"] }
              var pageInfo: PageInfo { __data["pageInfo"] }
              var nodes: [Node?]? { __data["nodes"] }

              /// Repository.Object.AsCommit.AssociatedPullRequests.PageInfo
              nonisolated struct PageInfo: GitHubAPI.SelectionSet {
                let __data: DataDict
                init(_dataDict: DataDict) { __data = _dataDict }

                static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.PageInfo }
                static var __selections: [ApolloAPI.Selection] { [
                  .field("__typename", String.self),
                  .fragment(GitHubPageInfo.self),
                ] }
                static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                  GitHubHistoryOverlayQuery.Data.Repository.Object.AsCommit.AssociatedPullRequests.PageInfo.self,
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

              /// Repository.Object.AsCommit.AssociatedPullRequests.Node
              nonisolated struct Node: GitHubAPI.SelectionSet {
                let __data: DataDict
                init(_dataDict: DataDict) { __data = _dataDict }

                static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.PullRequest }
                static var __selections: [ApolloAPI.Selection] { [
                  .field("__typename", String.self),
                  .fragment(GitHubPullRequestSummary.self),
                ] }
                static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                  GitHubHistoryOverlayQuery.Data.Repository.Object.AsCommit.AssociatedPullRequests.Node.self,
                  GitHubPullRequestSummary.self
                ] }

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

                typealias Author = GitHubPullRequestSummary.Author

                typealias HeadRepository = GitHubPullRequestSummary.HeadRepository

                typealias BaseRepository = GitHubPullRequestSummary.BaseRepository

                typealias Labels = GitHubPullRequestSummary.Labels

                typealias StatusCheckRollup = GitHubPullRequestSummary.StatusCheckRollup
              }
            }
          }
        }
      }
    }
  }

}
