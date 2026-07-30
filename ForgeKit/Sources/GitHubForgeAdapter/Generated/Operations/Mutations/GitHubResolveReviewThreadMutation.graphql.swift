// @generated
// This file was automatically generated and should not be edited.

import ApolloAPI
@_spi(Execution) @_spi(Unsafe) import ApolloAPI

extension GitHubAPI {
  nonisolated struct GitHubResolveReviewThreadMutation: GraphQLMutation {
    static let operationName: String = "GitHubResolveReviewThread"
    static let operationDocument: ApolloAPI.OperationDocument = .init(
      definition: .init(
        #"mutation GitHubResolveReviewThread($input: ResolveReviewThreadInput!) { resolveReviewThread(input: $input) { __typename thread { __typename id isResolved pullRequest { __typename number repository { __typename ...GitHubRepositoryIdentity } } } } }"#,
        fragments: [GitHubRepositoryIdentity.self]
      ))

    public var input: ResolveReviewThreadInput

    public init(input: ResolveReviewThreadInput) {
      self.input = input
    }

    @_spi(Unsafe) public var __variables: Variables? { ["input": input] }

    nonisolated struct Data: GitHubAPI.SelectionSet {
      let __data: DataDict
      init(_dataDict: DataDict) { __data = _dataDict }

      static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.Mutation }
      static var __selections: [ApolloAPI.Selection] { [
        .field("resolveReviewThread", ResolveReviewThread?.self, arguments: ["input": .variable("input")]),
      ] }
      static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
        GitHubResolveReviewThreadMutation.Data.self
      ] }

      var resolveReviewThread: ResolveReviewThread? { __data["resolveReviewThread"] }

      /// ResolveReviewThread
      nonisolated struct ResolveReviewThread: GitHubAPI.SelectionSet {
        let __data: DataDict
        init(_dataDict: DataDict) { __data = _dataDict }

        static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.ResolveReviewThreadPayload }
        static var __selections: [ApolloAPI.Selection] { [
          .field("__typename", String.self),
          .field("thread", Thread?.self),
        ] }
        static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
          GitHubResolveReviewThreadMutation.Data.ResolveReviewThread.self
        ] }

        var thread: Thread? { __data["thread"] }

        /// ResolveReviewThread.Thread
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
            GitHubResolveReviewThreadMutation.Data.ResolveReviewThread.Thread.self
          ] }

          var id: GitHubAPI.ID { __data["id"] }
          var isResolved: Bool { __data["isResolved"] }
          var pullRequest: PullRequest { __data["pullRequest"] }

          /// ResolveReviewThread.Thread.PullRequest
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
              GitHubResolveReviewThreadMutation.Data.ResolveReviewThread.Thread.PullRequest.self
            ] }

            var number: Int { __data["number"] }
            var repository: Repository { __data["repository"] }

            /// ResolveReviewThread.Thread.PullRequest.Repository
            nonisolated struct Repository: GitHubAPI.SelectionSet {
              let __data: DataDict
              init(_dataDict: DataDict) { __data = _dataDict }

              static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.Repository }
              static var __selections: [ApolloAPI.Selection] { [
                .field("__typename", String.self),
                .fragment(GitHubRepositoryIdentity.self),
              ] }
              static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                GitHubResolveReviewThreadMutation.Data.ResolveReviewThread.Thread.PullRequest.Repository.self,
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
