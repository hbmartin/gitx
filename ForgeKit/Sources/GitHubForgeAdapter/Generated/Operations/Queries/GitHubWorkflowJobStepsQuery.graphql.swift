// @generated
// This file was automatically generated and should not be edited.

import ApolloAPI
@_spi(Execution) @_spi(Unsafe) import ApolloAPI

extension GitHubAPI {
  nonisolated struct GitHubWorkflowJobStepsQuery: GraphQLQuery {
    static let operationName: String = "GitHubWorkflowJobSteps"
    static let operationDocument: ApolloAPI.OperationDocument = .init(
      definition: .init(
        #"query GitHubWorkflowJobSteps($id: ID!, $first: Int!, $after: String) { node(id: $id) { __typename ... on CheckRun { id repository { __typename ...GitHubRepositoryIdentity } steps(first: $first, after: $after) { __typename totalCount pageInfo { __typename ...GitHubPageInfo } nodes { __typename number name status conclusion startedAt completedAt } } } } }"#,
        fragments: [GitHubPageInfo.self, GitHubRepositoryIdentity.self]
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
        GitHubWorkflowJobStepsQuery.Data.self
      ] }

      var node: Node? { __data["node"] }

      /// Node
      nonisolated struct Node: GitHubAPI.SelectionSet {
        let __data: DataDict
        init(_dataDict: DataDict) { __data = _dataDict }

        static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Interfaces.Node }
        static var __selections: [ApolloAPI.Selection] { [
          .field("__typename", String.self),
          .inlineFragment(AsCheckRun.self),
        ] }
        static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
          GitHubWorkflowJobStepsQuery.Data.Node.self
        ] }

        var asCheckRun: AsCheckRun? { _asInlineFragment() }

        /// Node.AsCheckRun
        nonisolated struct AsCheckRun: GitHubAPI.InlineFragment {
          let __data: DataDict
          init(_dataDict: DataDict) { __data = _dataDict }

          typealias RootEntityType = GitHubWorkflowJobStepsQuery.Data.Node
          static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.CheckRun }
          static var __selections: [ApolloAPI.Selection] { [
            .field("id", GitHubAPI.ID.self),
            .field("repository", Repository.self),
            .field("steps", Steps?.self, arguments: [
              "first": .variable("first"),
              "after": .variable("after")
            ]),
          ] }
          static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
            GitHubWorkflowJobStepsQuery.Data.Node.self,
            GitHubWorkflowJobStepsQuery.Data.Node.AsCheckRun.self
          ] }

          var id: GitHubAPI.ID { __data["id"] }
          var repository: Repository { __data["repository"] }
          var steps: Steps? { __data["steps"] }

          /// Node.AsCheckRun.Repository
          nonisolated struct Repository: GitHubAPI.SelectionSet {
            let __data: DataDict
            init(_dataDict: DataDict) { __data = _dataDict }

            static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.Repository }
            static var __selections: [ApolloAPI.Selection] { [
              .field("__typename", String.self),
              .fragment(GitHubRepositoryIdentity.self),
            ] }
            static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
              GitHubWorkflowJobStepsQuery.Data.Node.AsCheckRun.Repository.self,
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

          /// Node.AsCheckRun.Steps
          nonisolated struct Steps: GitHubAPI.SelectionSet {
            let __data: DataDict
            init(_dataDict: DataDict) { __data = _dataDict }

            static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.CheckStepConnection }
            static var __selections: [ApolloAPI.Selection] { [
              .field("__typename", String.self),
              .field("totalCount", Int.self),
              .field("pageInfo", PageInfo.self),
              .field("nodes", [Node?]?.self),
            ] }
            static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
              GitHubWorkflowJobStepsQuery.Data.Node.AsCheckRun.Steps.self
            ] }

            var totalCount: Int { __data["totalCount"] }
            var pageInfo: PageInfo { __data["pageInfo"] }
            var nodes: [Node?]? { __data["nodes"] }

            /// Node.AsCheckRun.Steps.PageInfo
            nonisolated struct PageInfo: GitHubAPI.SelectionSet {
              let __data: DataDict
              init(_dataDict: DataDict) { __data = _dataDict }

              static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.PageInfo }
              static var __selections: [ApolloAPI.Selection] { [
                .field("__typename", String.self),
                .fragment(GitHubPageInfo.self),
              ] }
              static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                GitHubWorkflowJobStepsQuery.Data.Node.AsCheckRun.Steps.PageInfo.self,
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

            /// Node.AsCheckRun.Steps.Node
            nonisolated struct Node: GitHubAPI.SelectionSet {
              let __data: DataDict
              init(_dataDict: DataDict) { __data = _dataDict }

              static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.CheckStep }
              static var __selections: [ApolloAPI.Selection] { [
                .field("__typename", String.self),
                .field("number", Int.self),
                .field("name", String.self),
                .field("status", GraphQLEnum<GitHubAPI.CheckStatusState>.self),
                .field("conclusion", GraphQLEnum<GitHubAPI.CheckConclusionState>?.self),
                .field("startedAt", GitHubAPI.DateTime?.self),
                .field("completedAt", GitHubAPI.DateTime?.self),
              ] }
              static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                GitHubWorkflowJobStepsQuery.Data.Node.AsCheckRun.Steps.Node.self
              ] }

              var number: Int { __data["number"] }
              var name: String { __data["name"] }
              var status: GraphQLEnum<GitHubAPI.CheckStatusState> { __data["status"] }
              var conclusion: GraphQLEnum<GitHubAPI.CheckConclusionState>? { __data["conclusion"] }
              var startedAt: GitHubAPI.DateTime? { __data["startedAt"] }
              var completedAt: GitHubAPI.DateTime? { __data["completedAt"] }
            }
          }
        }
      }
    }
  }

}
