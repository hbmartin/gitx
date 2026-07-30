// @generated
// This file was automatically generated and should not be edited.

import ApolloAPI
@_spi(Execution) @_spi(Unsafe) import ApolloAPI

extension GitHubAPI {
  nonisolated struct GitHubUnresolveReviewThreadMutation: GraphQLMutation {
    static let operationName: String = "GitHubUnresolveReviewThread"
    static let operationDocument: ApolloAPI.OperationDocument = .init(
      definition: .init(
        #"mutation GitHubUnresolveReviewThread($input: UnresolveReviewThreadInput!) { unresolveReviewThread(input: $input) { __typename thread { __typename id isResolved pullRequest { __typename number repository { __typename ...GitHubRepositoryIdentity } } } } }"#,
        fragments: [GitHubRepositoryIdentity.self]
      ))

    public var input: UnresolveReviewThreadInput

    public init(input: UnresolveReviewThreadInput) {
      self.input = input
    }

    @_spi(Unsafe) public var __variables: Variables? { ["input": input] }

    nonisolated struct Data: GitHubAPI.SelectionSet {
      let __data: DataDict
      init(_dataDict: DataDict) { __data = _dataDict }

      static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.Mutation }
      static var __selections: [ApolloAPI.Selection] { [
        .field("unresolveReviewThread", UnresolveReviewThread?.self, arguments: ["input": .variable("input")]),
      ] }
      static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
        GitHubUnresolveReviewThreadMutation.Data.self
      ] }

      var unresolveReviewThread: UnresolveReviewThread? { __data["unresolveReviewThread"] }

      /// UnresolveReviewThread
      nonisolated struct UnresolveReviewThread: GitHubAPI.SelectionSet {
        let __data: DataDict
        init(_dataDict: DataDict) { __data = _dataDict }

        static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.UnresolveReviewThreadPayload }
        static var __selections: [ApolloAPI.Selection] { [
          .field("__typename", String.self),
          .field("thread", Thread?.self),
        ] }
        static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
          GitHubUnresolveReviewThreadMutation.Data.UnresolveReviewThread.self
        ] }

        var thread: Thread? { __data["thread"] }

        /// UnresolveReviewThread.Thread
        nonisolated struct Thread: GitHubAPI.SelectionSet {
          let __data: DataDict
          init(_dataDict: DataDict) { __data = _dataDict }

          static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.PullRequestReviewThread }
          static var __selections: [ApolloAPI.Selection] { [
            .field("__typename", String.self),
            .field("id", GitHubAPI.ID.self),
            .field("isResolved", Bool.self),
            .field("pullRequest", PullRequest.self),
          ] }
          static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
            GitHubUnresolveReviewThreadMutation.Data.UnresolveReviewThread.Thread.self
          ] }

          var id: GitHubAPI.ID { __data["id"] }
          var isResolved: Bool { __data["isResolved"] }
          var pullRequest: PullRequest { __data["pullRequest"] }

          /// UnresolveReviewThread.Thread.PullRequest
          nonisolated struct PullRequest: GitHubAPI.SelectionSet {
            let __data: DataDict
            init(_dataDict: DataDict) { __data = _dataDict }

            static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.PullRequest }
            static var __selections: [ApolloAPI.Selection] { [
              .field("__typename", String.self),
              .field("number", Int.self),
              .field("repository", Repository.self),
            ] }
            static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
              GitHubUnresolveReviewThreadMutation.Data.UnresolveReviewThread.Thread.PullRequest.self
            ] }

            var number: Int { __data["number"] }
            var repository: Repository { __data["repository"] }

            /// UnresolveReviewThread.Thread.PullRequest.Repository
            nonisolated struct Repository: GitHubAPI.SelectionSet {
              let __data: DataDict
              init(_dataDict: DataDict) { __data = _dataDict }

              static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.Repository }
              static var __selections: [ApolloAPI.Selection] { [
                .field("__typename", String.self),
                .fragment(GitHubRepositoryIdentity.self),
              ] }
              static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                GitHubUnresolveReviewThreadMutation.Data.UnresolveReviewThread.Thread.PullRequest.Repository.self,
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
