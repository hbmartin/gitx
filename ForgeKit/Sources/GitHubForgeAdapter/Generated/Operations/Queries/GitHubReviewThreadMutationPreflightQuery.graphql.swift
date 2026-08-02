// @generated
// This file was automatically generated and should not be edited.

import ApolloAPI
@_spi(Execution) @_spi(Unsafe) import ApolloAPI

extension GitHubAPI {
  nonisolated struct GitHubReviewThreadMutationPreflightQuery: GraphQLQuery {
    static let operationName: String = "GitHubReviewThreadMutationPreflight"
    static let operationDocument: ApolloAPI.OperationDocument = .init(
      definition: .init(
        #"query GitHubReviewThreadMutationPreflight($id: ID!) { node(id: $id) { __typename ... on PullRequestReviewThread { id isResolved pullRequest { __typename number headRefOid repository { __typename ...GitHubRepositoryIdentity } } } } }"#,
        fragments: [GitHubRepositoryIdentity.self]
      ))

    public var id: ID

    public init(id: ID) {
      self.id = id
    }

    @_spi(Unsafe) public var __variables: Variables? { ["id": id] }

    nonisolated struct Data: GitHubAPI.SelectionSet {
      let __data: DataDict
      init(_dataDict: DataDict) { __data = _dataDict }

      static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.Query }
      static var __selections: [ApolloAPI.Selection] { [
        .field("node", Node?.self, arguments: ["id": .variable("id")]),
      ] }
      static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
        GitHubReviewThreadMutationPreflightQuery.Data.self
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
          GitHubReviewThreadMutationPreflightQuery.Data.Node.self
        ] }

        var asPullRequestReviewThread: AsPullRequestReviewThread? { _asInlineFragment() }

        /// Node.AsPullRequestReviewThread
        nonisolated struct AsPullRequestReviewThread: GitHubAPI.InlineFragment {
          let __data: DataDict
          init(_dataDict: DataDict) { __data = _dataDict }

          typealias RootEntityType = GitHubReviewThreadMutationPreflightQuery.Data.Node
          static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.PullRequestReviewThread }
          static var __selections: [ApolloAPI.Selection] { [
            .field("id", GitHubAPI.ID.self),
            .field("isResolved", Bool.self),
            .field("pullRequest", PullRequest.self),
          ] }
          static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
            GitHubReviewThreadMutationPreflightQuery.Data.Node.self,
            GitHubReviewThreadMutationPreflightQuery.Data.Node.AsPullRequestReviewThread.self
          ] }

          var id: GitHubAPI.ID { __data["id"] }
          var isResolved: Bool { __data["isResolved"] }
          var pullRequest: PullRequest { __data["pullRequest"] }

          /// Node.AsPullRequestReviewThread.PullRequest
          nonisolated struct PullRequest: GitHubAPI.SelectionSet {
            let __data: DataDict
            init(_dataDict: DataDict) { __data = _dataDict }

            static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.PullRequest }
            static var __selections: [ApolloAPI.Selection] { [
              .field("__typename", String.self),
              .field("number", Int.self),
              .field("headRefOid", GitHubAPI.GitObjectID.self),
              .field("repository", Repository.self),
            ] }
            static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
              GitHubReviewThreadMutationPreflightQuery.Data.Node.AsPullRequestReviewThread.PullRequest.self
            ] }

            var number: Int { __data["number"] }
            var headRefOid: GitHubAPI.GitObjectID { __data["headRefOid"] }
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
                GitHubReviewThreadMutationPreflightQuery.Data.Node.AsPullRequestReviewThread.PullRequest.Repository.self,
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
        }
      }
    }
  }

}
