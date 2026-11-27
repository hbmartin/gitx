// @generated
// This file was automatically generated and should not be edited.

import ApolloAPI
@_spi(Execution) @_spi(Unsafe) import ApolloAPI

extension GitHubAPI {
  nonisolated struct GitHubCommitWorkflowRunsQuery: GraphQLQuery {
    static let operationName: String = "GitHubCommitWorkflowRuns"
    static let operationDocument: ApolloAPI.OperationDocument = .init(
      definition: .init(
        #"query GitHubCommitWorkflowRuns($owner: String!, $name: String!, $oid: GitObjectID!, $first: Int!, $after: String, $jobFirst: Int!, $includeWorkflowRuns: Boolean!) { repository(owner: $owner, name: $name) { __typename ...GitHubRepositoryIdentity object(oid: $oid) { __typename ... on Commit { oid checkSuites(first: $first, after: $after) { __typename totalCount pageInfo { __typename ...GitHubPageInfo } nodes { __typename ...GitHubWorkflowCheckSuite workflowRun @include(if: $includeWorkflowRuns) { __typename databaseId runNumber runAttempt event displayTitle workflow { __typename name } } checkRuns(first: $jobFirst, filterBy: { checkType: LATEST }) { __typename totalCount pageInfo { __typename ...GitHubPageInfo } nodes { __typename ...GitHubWorkflowJob } } } } } } } }"#,
        fragments: [GitHubPageInfo.self, GitHubRepositoryIdentity.self, GitHubWorkflowCheckSuite.self, GitHubWorkflowJob.self]
      ))

    public var owner: String
    public var name: String
    public var oid: GitObjectID
    public var first: Int32
    public var after: GraphQLNullable<String>
    public var jobFirst: Int32
    public var includeWorkflowRuns: Bool

    public init(
      owner: String,
      name: String,
      oid: GitObjectID,
      first: Int32,
      after: GraphQLNullable<String>,
      jobFirst: Int32,
      includeWorkflowRuns: Bool
    ) {
      self.owner = owner
      self.name = name
      self.oid = oid
      self.first = first
      self.after = after
      self.jobFirst = jobFirst
      self.includeWorkflowRuns = includeWorkflowRuns
    }

    @_spi(Unsafe) public var __variables: Variables? { [
      "owner": owner,
      "name": name,
      "oid": oid,
      "first": first,
      "after": after,
      "jobFirst": jobFirst,
      "includeWorkflowRuns": includeWorkflowRuns
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
        GitHubCommitWorkflowRunsQuery.Data.self
      ] }

      var repository: Repository? { __data["repository"] }

      /// Repository
      nonisolated struct Repository: GitHubAPI.SelectionSet {
        let __data: DataDict
        init(_dataDict: DataDict) { __data = _dataDict }

        static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.Repository }
        static var __selections: [ApolloAPI.Selection] { [
          .field("__typename", String.self),
          .field("object", Object?.self, arguments: ["oid": .variable("oid")]),
          .fragment(GitHubRepositoryIdentity.self),
        ] }
        static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
          GitHubCommitWorkflowRunsQuery.Data.Repository.self,
          GitHubRepositoryIdentity.self
        ] }

        var object: Object? { __data["object"] }
        var id: GitHubAPI.ID { __data["id"] }
        var name: String { __data["name"] }
        var nameWithOwner: String { __data["nameWithOwner"] }
        var owner: Owner { __data["owner"] }

        struct Fragments: FragmentContainer {
          let __data: DataDict
          init(_dataDict: DataDict) { __data = _dataDict }

          var gitHubRepositoryIdentity: GitHubRepositoryIdentity { _toFragment() }
        }

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
            GitHubCommitWorkflowRunsQuery.Data.Repository.Object.self
          ] }

          var asCommit: AsCommit? { _asInlineFragment() }

          /// Repository.Object.AsCommit
          nonisolated struct AsCommit: GitHubAPI.InlineFragment {
            let __data: DataDict
            init(_dataDict: DataDict) { __data = _dataDict }

            typealias RootEntityType = GitHubCommitWorkflowRunsQuery.Data.Repository.Object
            static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.Commit }
            static var __selections: [ApolloAPI.Selection] { [
              .field("oid", GitHubAPI.GitObjectID.self),
              .field("checkSuites", CheckSuites?.self, arguments: [
                "first": .variable("first"),
                "after": .variable("after")
              ]),
            ] }
            static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
              GitHubCommitWorkflowRunsQuery.Data.Repository.Object.self,
              GitHubCommitWorkflowRunsQuery.Data.Repository.Object.AsCommit.self
            ] }

            var oid: GitHubAPI.GitObjectID { __data["oid"] }
            var checkSuites: CheckSuites? { __data["checkSuites"] }

            /// Repository.Object.AsCommit.CheckSuites
            nonisolated struct CheckSuites: GitHubAPI.SelectionSet {
              let __data: DataDict
              init(_dataDict: DataDict) { __data = _dataDict }

              static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.CheckSuiteConnection }
              static var __selections: [ApolloAPI.Selection] { [
                .field("__typename", String.self),
                .field("totalCount", Int.self),
                .field("pageInfo", PageInfo.self),
                .field("nodes", [Node?]?.self),
              ] }
              static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                GitHubCommitWorkflowRunsQuery.Data.Repository.Object.AsCommit.CheckSuites.self
              ] }

              var totalCount: Int { __data["totalCount"] }
              var pageInfo: PageInfo { __data["pageInfo"] }
              var nodes: [Node?]? { __data["nodes"] }

              /// Repository.Object.AsCommit.CheckSuites.PageInfo
              nonisolated struct PageInfo: GitHubAPI.SelectionSet {
                let __data: DataDict
                init(_dataDict: DataDict) { __data = _dataDict }

                static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.PageInfo }
                static var __selections: [ApolloAPI.Selection] { [
                  .field("__typename", String.self),
                  .fragment(GitHubPageInfo.self),
                ] }
                static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                  GitHubCommitWorkflowRunsQuery.Data.Repository.Object.AsCommit.CheckSuites.PageInfo.self,
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

              /// Repository.Object.AsCommit.CheckSuites.Node
              nonisolated struct Node: GitHubAPI.SelectionSet {
                let __data: DataDict
                init(_dataDict: DataDict) { __data = _dataDict }

                static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.CheckSuite }
                static var __selections: [ApolloAPI.Selection] { [
                  .field("__typename", String.self),
                  .field("checkRuns", CheckRuns?.self, arguments: [
                    "first": .variable("jobFirst"),
                    "filterBy": ["checkType": "LATEST"]
                  ]),
                  .fragment(GitHubWorkflowCheckSuite.self),
                  .include(if: "includeWorkflowRuns", .field("workflowRun", WorkflowRun?.self)),
                ] }
                static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                  GitHubCommitWorkflowRunsQuery.Data.Repository.Object.AsCommit.CheckSuites.Node.self,
                  GitHubWorkflowCheckSuite.self
                ] }

                var workflowRun: WorkflowRun? { __data["workflowRun"] }
                var checkRuns: CheckRuns? { __data["checkRuns"] }
                var id: GitHubAPI.ID { __data["id"] }
                var status: GraphQLEnum<GitHubAPI.CheckStatusState> { __data["status"] }
                var conclusion: GraphQLEnum<GitHubAPI.CheckConclusionState>? { __data["conclusion"] }
                var updatedAt: GitHubAPI.DateTime { __data["updatedAt"] }
                var app: App? { __data["app"] }

                struct Fragments: FragmentContainer {
                  let __data: DataDict
                  init(_dataDict: DataDict) { __data = _dataDict }

                  var gitHubWorkflowCheckSuite: GitHubWorkflowCheckSuite { _toFragment() }
                }

                /// Repository.Object.AsCommit.CheckSuites.Node.WorkflowRun
                nonisolated struct WorkflowRun: GitHubAPI.SelectionSet {
                  let __data: DataDict
                  init(_dataDict: DataDict) { __data = _dataDict }

                  static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.WorkflowRun }
                  static var __selections: [ApolloAPI.Selection] { [
                    .field("__typename", String.self),
                    .field("databaseId", Int?.self),
                    .field("runNumber", Int.self),
                    .field("runAttempt", Int.self),
                    .field("event", String.self),
                    .field("displayTitle", String?.self),
                    .field("workflow", Workflow.self),
                  ] }
                  static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                    GitHubCommitWorkflowRunsQuery.Data.Repository.Object.AsCommit.CheckSuites.Node.WorkflowRun.self
                  ] }

                  var databaseId: Int? { __data["databaseId"] }
                  var runNumber: Int { __data["runNumber"] }
                  var runAttempt: Int { __data["runAttempt"] }
                  var event: String { __data["event"] }
                  var displayTitle: String? { __data["displayTitle"] }
                  var workflow: Workflow { __data["workflow"] }

                  /// Repository.Object.AsCommit.CheckSuites.Node.WorkflowRun.Workflow
                  nonisolated struct Workflow: GitHubAPI.SelectionSet {
                    let __data: DataDict
                    init(_dataDict: DataDict) { __data = _dataDict }

                    static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.Workflow }
                    static var __selections: [ApolloAPI.Selection] { [
                      .field("__typename", String.self),
                      .field("name", String.self),
                    ] }
                    static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                      GitHubCommitWorkflowRunsQuery.Data.Repository.Object.AsCommit.CheckSuites.Node.WorkflowRun.Workflow.self
                    ] }

                    var name: String { __data["name"] }
                  }
                }

                /// Repository.Object.AsCommit.CheckSuites.Node.CheckRuns
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
                    GitHubCommitWorkflowRunsQuery.Data.Repository.Object.AsCommit.CheckSuites.Node.CheckRuns.self
                  ] }

                  var totalCount: Int { __data["totalCount"] }
                  var pageInfo: PageInfo { __data["pageInfo"] }
                  var nodes: [Node?]? { __data["nodes"] }

                  /// Repository.Object.AsCommit.CheckSuites.Node.CheckRuns.PageInfo
                  nonisolated struct PageInfo: GitHubAPI.SelectionSet {
                    let __data: DataDict
                    init(_dataDict: DataDict) { __data = _dataDict }

                    static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.PageInfo }
                    static var __selections: [ApolloAPI.Selection] { [
                      .field("__typename", String.self),
                      .fragment(GitHubPageInfo.self),
                    ] }
                    static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                      GitHubCommitWorkflowRunsQuery.Data.Repository.Object.AsCommit.CheckSuites.Node.CheckRuns.PageInfo.self,
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

                  /// Repository.Object.AsCommit.CheckSuites.Node.CheckRuns.Node
                  nonisolated struct Node: GitHubAPI.SelectionSet {
                    let __data: DataDict
                    init(_dataDict: DataDict) { __data = _dataDict }

                    static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.CheckRun }
                    static var __selections: [ApolloAPI.Selection] { [
                      .field("__typename", String.self),
                      .fragment(GitHubWorkflowJob.self),
                    ] }
                    static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                      GitHubCommitWorkflowRunsQuery.Data.Repository.Object.AsCommit.CheckSuites.Node.CheckRuns.Node.self,
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

                typealias App = GitHubWorkflowCheckSuite.App
              }
            }
          }
        }

        typealias Owner = GitHubRepositoryIdentity.Owner
      }
    }
  }

}
