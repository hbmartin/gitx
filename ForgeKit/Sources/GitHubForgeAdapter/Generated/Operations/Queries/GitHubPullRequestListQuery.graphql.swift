// @generated
// This file was automatically generated and should not be edited.

import ApolloAPI
@_spi(Execution) @_spi(Unsafe) import ApolloAPI

extension GitHubAPI {
  nonisolated struct GitHubPullRequestListQuery: GraphQLQuery {
    static let operationName: String = "GitHubPullRequestList"
    static let operationDocument: ApolloAPI.OperationDocument = .init(
      definition: .init(
        #"query GitHubPullRequestList($owner: String!, $name: String!, $first: Int!, $after: String, $states: [PullRequestState!]) { repository(owner: $owner, name: $name) { __typename id pullRequests( first: $first after: $after states: $states orderBy: { field: UPDATED_AT, direction: DESC } ) { __typename totalCount pageInfo { __typename ...GitHubPageInfo } nodes { __typename ...GitHubPullRequestSummary } } } }"#,
        fragments: [GitHubActor.self, GitHubLabel.self, GitHubPageInfo.self, GitHubPullRequestSummary.self, GitHubRepositoryIdentity.self]
      ))

    public var owner: String
    public var name: String
    public var first: Int32
    public var after: GraphQLNullable<String>
    public var states: GraphQLNullable<[GraphQLEnum<PullRequestState>]>

    public init(
      owner: String,
      name: String,
      first: Int32,
      after: GraphQLNullable<String>,
      states: GraphQLNullable<[GraphQLEnum<PullRequestState>]>
    ) {
      self.owner = owner
      self.name = name
      self.first = first
      self.after = after
      self.states = states
    }

    @_spi(Unsafe) public var __variables: Variables? { [
      "owner": owner,
      "name": name,
      "first": first,
      "after": after,
      "states": states
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
        GitHubPullRequestListQuery.Data.self
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
          .field("pullRequests", PullRequests.self, arguments: [
            "first": .variable("first"),
            "after": .variable("after"),
            "states": .variable("states"),
            "orderBy": [
              "field": "UPDATED_AT",
              "direction": "DESC"
            ]
          ]),
        ] }
        static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
          GitHubPullRequestListQuery.Data.Repository.self
        ] }

        var id: GitHubAPI.ID { __data["id"] }
        var pullRequests: PullRequests { __data["pullRequests"] }

        /// Repository.PullRequests
        nonisolated struct PullRequests: GitHubAPI.SelectionSet {
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
            GitHubPullRequestListQuery.Data.Repository.PullRequests.self
          ] }

          var totalCount: Int { __data["totalCount"] }
          var pageInfo: PageInfo { __data["pageInfo"] }
          var nodes: [Node?]? { __data["nodes"] }

          /// Repository.PullRequests.PageInfo
          nonisolated struct PageInfo: GitHubAPI.SelectionSet {
            let __data: DataDict
            init(_dataDict: DataDict) { __data = _dataDict }

            static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.PageInfo }
            static var __selections: [ApolloAPI.Selection] { [
              .field("__typename", String.self),
              .fragment(GitHubPageInfo.self),
            ] }
            static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
              GitHubPullRequestListQuery.Data.Repository.PullRequests.PageInfo.self,
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

          /// Repository.PullRequests.Node
          nonisolated struct Node: GitHubAPI.SelectionSet {
            let __data: DataDict
            init(_dataDict: DataDict) { __data = _dataDict }

            static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.PullRequest }
            static var __selections: [ApolloAPI.Selection] { [
              .field("__typename", String.self),
              .fragment(GitHubPullRequestSummary.self),
            ] }
            static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
              GitHubPullRequestListQuery.Data.Repository.PullRequests.Node.self,
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
