// @generated
// This file was automatically generated and should not be edited.

import ApolloAPI
@_spi(Execution) @_spi(Unsafe) import ApolloAPI

extension GitHubAPI {
  nonisolated struct GitHubRepositoryItemSearchQuery: GraphQLQuery {
    static let operationName: String = "GitHubRepositoryItemSearch"
    static let operationDocument: ApolloAPI.OperationDocument = .init(
      definition: .init(
        #"query GitHubRepositoryItemSearch($query: String!, $first: Int!, $after: String) { search(query: $query, type: ISSUE, first: $first, after: $after) { __typename totalCount: issueCount pageInfo { __typename ...GitHubPageInfo } nodes { __typename ... on PullRequest { repository { __typename ...GitHubRepositoryIdentity } ...GitHubPullRequestSummary } ... on Issue { repository { __typename ...GitHubRepositoryIdentity } ...GitHubIssueSummary } } } }"#,
        fragments: [GitHubActor.self, GitHubIssueSummary.self, GitHubLabel.self, GitHubPageInfo.self, GitHubPullRequestSummary.self, GitHubRepositoryIdentity.self]
      ))

    public var query: String
    public var first: Int32
    public var after: GraphQLNullable<String>

    public init(
      query: String,
      first: Int32,
      after: GraphQLNullable<String>
    ) {
      self.query = query
      self.first = first
      self.after = after
    }

    @_spi(Unsafe) public var __variables: Variables? { [
      "query": query,
      "first": first,
      "after": after
    ] }

    nonisolated struct Data: GitHubAPI.SelectionSet {
      let __data: DataDict
      init(_dataDict: DataDict) { __data = _dataDict }

      static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.Query }
      static var __selections: [ApolloAPI.Selection] { [
        .field("search", Search.self, arguments: [
          "query": .variable("query"),
          "type": "ISSUE",
          "first": .variable("first"),
          "after": .variable("after")
        ]),
      ] }
      static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
        GitHubRepositoryItemSearchQuery.Data.self
      ] }

      var search: Search { __data["search"] }

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
          GitHubRepositoryItemSearchQuery.Data.Search.self
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
            GitHubRepositoryItemSearchQuery.Data.Search.PageInfo.self,
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
            GitHubRepositoryItemSearchQuery.Data.Search.Node.self
          ] }

          var asPullRequest: AsPullRequest? { _asInlineFragment() }
          var asIssue: AsIssue? { _asInlineFragment() }

          /// Search.Node.AsPullRequest
          nonisolated struct AsPullRequest: GitHubAPI.InlineFragment {
            let __data: DataDict
            init(_dataDict: DataDict) { __data = _dataDict }

            typealias RootEntityType = GitHubRepositoryItemSearchQuery.Data.Search.Node
            static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.PullRequest }
            static var __selections: [ApolloAPI.Selection] { [
              .field("repository", Repository.self),
              .fragment(GitHubPullRequestSummary.self),
            ] }
            static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
              GitHubRepositoryItemSearchQuery.Data.Search.Node.self,
              GitHubRepositoryItemSearchQuery.Data.Search.Node.AsPullRequest.self,
              GitHubPullRequestSummary.self
            ] }

            var repository: Repository { __data["repository"] }
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

            /// Search.Node.AsPullRequest.Repository
            nonisolated struct Repository: GitHubAPI.SelectionSet {
              let __data: DataDict
              init(_dataDict: DataDict) { __data = _dataDict }

              static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.Repository }
              static var __selections: [ApolloAPI.Selection] { [
                .field("__typename", String.self),
                .fragment(GitHubRepositoryIdentity.self),
              ] }
              static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                GitHubRepositoryItemSearchQuery.Data.Search.Node.AsPullRequest.Repository.self,
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

            typealias RootEntityType = GitHubRepositoryItemSearchQuery.Data.Search.Node
            static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.Issue }
            static var __selections: [ApolloAPI.Selection] { [
              .field("repository", Repository.self),
              .fragment(GitHubIssueSummary.self),
            ] }
            static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
              GitHubRepositoryItemSearchQuery.Data.Search.Node.self,
              GitHubRepositoryItemSearchQuery.Data.Search.Node.AsIssue.self,
              GitHubIssueSummary.self
            ] }

            var repository: Repository { __data["repository"] }
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

            /// Search.Node.AsIssue.Repository
            nonisolated struct Repository: GitHubAPI.SelectionSet {
              let __data: DataDict
              init(_dataDict: DataDict) { __data = _dataDict }

              static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.Repository }
              static var __selections: [ApolloAPI.Selection] { [
                .field("__typename", String.self),
                .fragment(GitHubRepositoryIdentity.self),
              ] }
              static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                GitHubRepositoryItemSearchQuery.Data.Search.Node.AsIssue.Repository.self,
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

            typealias Author = GitHubIssueSummary.Author

            typealias Labels = GitHubIssueSummary.Labels
          }
        }
      }
    }
  }

}
