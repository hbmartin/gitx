// @generated
// This file was automatically generated and should not be edited.

import ApolloAPI
@_spi(Execution) @_spi(Unsafe) import ApolloAPI

extension GitHubAPI {
  nonisolated struct GitHubCheckSuiteJobsQuery: GraphQLQuery {
    static let operationName: String = "GitHubCheckSuiteJobs"
    static let operationDocument: ApolloAPI.OperationDocument = .init(
      definition: .init(
        #"query GitHubCheckSuiteJobs($id: ID!, $first: Int!, $after: String) { node(id: $id) { __typename ... on CheckSuite { id repository { __typename ...GitHubRepositoryIdentity } checkRuns(first: $first, after: $after, filterBy: { checkType: LATEST }) { __typename totalCount pageInfo { __typename ...GitHubPageInfo } nodes { __typename ...GitHubWorkflowJob } } } } }"#,
        fragments: [GitHubPageInfo.self, GitHubRepositoryIdentity.self, GitHubWorkflowJob.self]
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
        GitHubCheckSuiteJobsQuery.Data.self
      ] }

      var node: Node? { __data["node"] }

      /// Node
      nonisolated struct Node: GitHubAPI.SelectionSet {
        let __data: DataDict
        init(_dataDict: DataDict) { __data = _dataDict }

        static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Interfaces.Node }
        static var __selections: [ApolloAPI.Selection] { [
          .field("__typename", String.self),
          .inlineFragment(AsCheckSuite.self),
        ] }
        static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
          GitHubCheckSuiteJobsQuery.Data.Node.self
        ] }

        var asCheckSuite: AsCheckSuite? { _asInlineFragment() }

        /// Node.AsCheckSuite
        nonisolated struct AsCheckSuite: GitHubAPI.InlineFragment {
          let __data: DataDict
          init(_dataDict: DataDict) { __data = _dataDict }

          typealias RootEntityType = GitHubCheckSuiteJobsQuery.Data.Node
          static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.CheckSuite }
          static var __selections: [ApolloAPI.Selection] { [
            .field("id", GitHubAPI.ID.self),
            .field("repository", Repository.self),
            .field("checkRuns", CheckRuns?.self, arguments: [
              "first": .variable("first"),
              "after": .variable("after"),
              "filterBy": ["checkType": "LATEST"]
            ]),
          ] }
          static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
            GitHubCheckSuiteJobsQuery.Data.Node.self,
            GitHubCheckSuiteJobsQuery.Data.Node.AsCheckSuite.self
          ] }

          var id: GitHubAPI.ID { __data["id"] }
          var repository: Repository { __data["repository"] }
          var checkRuns: CheckRuns? { __data["checkRuns"] }

          /// Node.AsCheckSuite.Repository
          nonisolated struct Repository: GitHubAPI.SelectionSet {
            let __data: DataDict
            init(_dataDict: DataDict) { __data = _dataDict }

            static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.Repository }
            static var __selections: [ApolloAPI.Selection] { [
              .field("__typename", String.self),
              .fragment(GitHubRepositoryIdentity.self),
            ] }
            static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
              GitHubCheckSuiteJobsQuery.Data.Node.AsCheckSuite.Repository.self,
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

          /// Node.AsCheckSuite.CheckRuns
          nonisolated struct CheckRuns: GitHubAPI.SelectionSet {
            let __data: DataDict
            init(_dataDict: DataDict) { __data = _dataDict }

            static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.CheckRunConnection }
            static var __selections: [ApolloAPI.Selection] { [
              .field("__typename", String.self),
              .field("totalCount", Int.self),
              .field("pageInfo", PageInfo.self),
              .field("nodes", [Node?]?.self),
            ] }
            static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
              GitHubCheckSuiteJobsQuery.Data.Node.AsCheckSuite.CheckRuns.self
            ] }

            var totalCount: Int { __data["totalCount"] }
            var pageInfo: PageInfo { __data["pageInfo"] }
            var nodes: [Node?]? { __data["nodes"] }

            /// Node.AsCheckSuite.CheckRuns.PageInfo
            nonisolated struct PageInfo: GitHubAPI.SelectionSet {
              let __data: DataDict
              init(_dataDict: DataDict) { __data = _dataDict }

              static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.PageInfo }
              static var __selections: [ApolloAPI.Selection] { [
                .field("__typename", String.self),
                .fragment(GitHubPageInfo.self),
              ] }
              static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                GitHubCheckSuiteJobsQuery.Data.Node.AsCheckSuite.CheckRuns.PageInfo.self,
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

            /// Node.AsCheckSuite.CheckRuns.Node
            nonisolated struct Node: GitHubAPI.SelectionSet {
              let __data: DataDict
              init(_dataDict: DataDict) { __data = _dataDict }

              static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.CheckRun }
              static var __selections: [ApolloAPI.Selection] { [
                .field("__typename", String.self),
                .fragment(GitHubWorkflowJob.self),
              ] }
              static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                GitHubCheckSuiteJobsQuery.Data.Node.AsCheckSuite.CheckRuns.Node.self,
                GitHubWorkflowJob.self
              ] }

              var id: GitHubAPI.ID { __data["id"] }
              var databaseId: Int? { __data["databaseId"] }
              var name: String { __data["name"] }
              var status: GraphQLEnum<GitHubAPI.CheckStatusState> { __data["status"] }
              var conclusion: GraphQLEnum<GitHubAPI.CheckConclusionState>? { __data["conclusion"] }
              var detailsUrl: GitHubAPI.URI? { __data["detailsUrl"] }
              var startedAt: GitHubAPI.DateTime? { __data["startedAt"] }
              var completedAt: GitHubAPI.DateTime? { __data["completedAt"] }

              struct Fragments: FragmentContainer {
                let __data: DataDict
                init(_dataDict: DataDict) { __data = _dataDict }

                var gitHubWorkflowJob: GitHubWorkflowJob { _toFragment() }
              }
            }
          }
        }
      }
    }
  }

}
