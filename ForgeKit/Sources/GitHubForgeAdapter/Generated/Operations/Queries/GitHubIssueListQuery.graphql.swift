// @generated
// This file was automatically generated and should not be edited.

import ApolloAPI
@_spi(Execution) @_spi(Unsafe) import ApolloAPI

extension GitHubAPI {
  nonisolated struct GitHubIssueListQuery: GraphQLQuery {
    static let operationName: String = "GitHubIssueList"
    static let operationDocument: ApolloAPI.OperationDocument = .init(
      definition: .init(
        #"query GitHubIssueList($owner: String!, $name: String!, $first: Int!, $after: String, $states: [IssueState!]) { repository(owner: $owner, name: $name) { __typename id issues( first: $first after: $after states: $states orderBy: { field: UPDATED_AT, direction: DESC } ) { __typename totalCount pageInfo { __typename ...GitHubPageInfo } nodes { __typename ...GitHubIssueSummary } } } }"#,
        fragments: [GitHubActor.self, GitHubIssueSummary.self, GitHubLabel.self, GitHubPageInfo.self]
      ))

    public var owner: String
    public var name: String
    public var first: Int32
    public var after: GraphQLNullable<String>
    public var states: GraphQLNullable<[GraphQLEnum<IssueState>]>

    public init(
      owner: String,
      name: String,
      first: Int32,
      after: GraphQLNullable<String>,
      states: GraphQLNullable<[GraphQLEnum<IssueState>]>
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
        GitHubIssueListQuery.Data.self
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
          .field("issues", Issues.self, arguments: [
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
          GitHubIssueListQuery.Data.Repository.self
        ] }

        var id: GitHubAPI.ID { __data["id"] }
        var issues: Issues { __data["issues"] }

        /// Repository.Issues
        nonisolated struct Issues: GitHubAPI.SelectionSet {
          let __data: DataDict
          init(_dataDict: DataDict) { __data = _dataDict }

          static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.IssueConnection }
          static var __selections: [ApolloAPI.Selection] { [
            .field("__typename", String.self),
            .field("totalCount", Int.self),
            .field("pageInfo", PageInfo.self),
            .field("nodes", [Node?]?.self),
          ] }
          static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
            GitHubIssueListQuery.Data.Repository.Issues.self
          ] }

          var totalCount: Int { __data["totalCount"] }
          var pageInfo: PageInfo { __data["pageInfo"] }
          var nodes: [Node?]? { __data["nodes"] }

          /// Repository.Issues.PageInfo
          nonisolated struct PageInfo: GitHubAPI.SelectionSet {
            let __data: DataDict
            init(_dataDict: DataDict) { __data = _dataDict }

            static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.PageInfo }
            static var __selections: [ApolloAPI.Selection] { [
              .field("__typename", String.self),
              .fragment(GitHubPageInfo.self),
            ] }
            static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
              GitHubIssueListQuery.Data.Repository.Issues.PageInfo.self,
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

          /// Repository.Issues.Node
          nonisolated struct Node: GitHubAPI.SelectionSet {
            let __data: DataDict
            init(_dataDict: DataDict) { __data = _dataDict }

            static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.Issue }
            static var __selections: [ApolloAPI.Selection] { [
              .field("__typename", String.self),
              .fragment(GitHubIssueSummary.self),
            ] }
            static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
              GitHubIssueListQuery.Data.Repository.Issues.Node.self,
              GitHubIssueSummary.self
            ] }

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

            typealias Author = GitHubIssueSummary.Author

            typealias Labels = GitHubIssueSummary.Labels
          }
        }
      }
    }
  }

}
