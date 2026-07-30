// @generated
// This file was automatically generated and should not be edited.

import ApolloAPI
@_spi(Execution) @_spi(Unsafe) import ApolloAPI

extension GitHubAPI {
  nonisolated struct GitHubEnterMergeQueueMutation: GraphQLMutation {
    static let operationName: String = "GitHubEnterMergeQueue"
    static let operationDocument: ApolloAPI.OperationDocument = .init(
      definition: .init(
        #"mutation GitHubEnterMergeQueue($input: EnqueuePullRequestInput!) { enqueuePullRequest(input: $input) { __typename mergeQueueEntry { __typename id pullRequest { __typename id number headRefOid repository { __typename ...GitHubRepositoryIdentity } } } } }"#,
        fragments: [GitHubRepositoryIdentity.self]
      ))

    public var input: EnqueuePullRequestInput

    public init(input: EnqueuePullRequestInput) {
      self.input = input
    }

    @_spi(Unsafe) public var __variables: Variables? { ["input": input] }

    nonisolated struct Data: GitHubAPI.SelectionSet {
      let __data: DataDict
      init(_dataDict: DataDict) { __data = _dataDict }

      static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.Mutation }
      static var __selections: [ApolloAPI.Selection] { [
        .field("enqueuePullRequest", EnqueuePullRequest?.self, arguments: ["input": .variable("input")]),
      ] }
      static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
        GitHubEnterMergeQueueMutation.Data.self
      ] }

      var enqueuePullRequest: EnqueuePullRequest? { __data["enqueuePullRequest"] }

      /// EnqueuePullRequest
      nonisolated struct EnqueuePullRequest: GitHubAPI.SelectionSet {
        let __data: DataDict
        init(_dataDict: DataDict) { __data = _dataDict }

        static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.EnqueuePullRequestPayload }
        static var __selections: [ApolloAPI.Selection] { [
          .field("__typename", String.self),
          .field("mergeQueueEntry", MergeQueueEntry?.self),
        ] }
        static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
          GitHubEnterMergeQueueMutation.Data.EnqueuePullRequest.self
        ] }

        var mergeQueueEntry: MergeQueueEntry? { __data["mergeQueueEntry"] }

        /// EnqueuePullRequest.MergeQueueEntry
        nonisolated struct MergeQueueEntry: GitHubAPI.SelectionSet {
          let __data: DataDict
          init(_dataDict: DataDict) { __data = _dataDict }

          static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.MergeQueueEntry }
          static var __selections: [ApolloAPI.Selection] { [
            .field("__typename", String.self),
            .field("id", GitHubAPI.ID.self),
            .field("pullRequest", PullRequest?.self),
          ] }
          static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
            GitHubEnterMergeQueueMutation.Data.EnqueuePullRequest.MergeQueueEntry.self
          ] }

          var id: GitHubAPI.ID { __data["id"] }
          var pullRequest: PullRequest? { __data["pullRequest"] }

          /// EnqueuePullRequest.MergeQueueEntry.PullRequest
          nonisolated struct PullRequest: GitHubAPI.SelectionSet {
            let __data: DataDict
            init(_dataDict: DataDict) { __data = _dataDict }

            static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.PullRequest }
            static var __selections: [ApolloAPI.Selection] { [
              .field("__typename", String.self),
              .field("id", GitHubAPI.ID.self),
              .field("number", Int.self),
              .field("headRefOid", GitHubAPI.GitObjectID.self),
              .field("repository", Repository.self),
            ] }
            static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
              GitHubEnterMergeQueueMutation.Data.EnqueuePullRequest.MergeQueueEntry.PullRequest.self
            ] }

            var id: GitHubAPI.ID { __data["id"] }
            var number: Int { __data["number"] }
            var headRefOid: GitHubAPI.GitObjectID { __data["headRefOid"] }
            var repository: Repository { __data["repository"] }

            /// EnqueuePullRequest.MergeQueueEntry.PullRequest.Repository
            nonisolated struct Repository: GitHubAPI.SelectionSet {
              let __data: DataDict
              init(_dataDict: DataDict) { __data = _dataDict }

              static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.Repository }
              static var __selections: [ApolloAPI.Selection] { [
                .field("__typename", String.self),
                .fragment(GitHubRepositoryIdentity.self),
              ] }
              static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                GitHubEnterMergeQueueMutation.Data.EnqueuePullRequest.MergeQueueEntry.PullRequest.Repository.self,
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
