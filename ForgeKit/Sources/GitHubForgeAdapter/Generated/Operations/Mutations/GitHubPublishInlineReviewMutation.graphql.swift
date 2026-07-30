// @generated
// This file was automatically generated and should not be edited.

import ApolloAPI
@_spi(Execution) @_spi(Unsafe) import ApolloAPI

extension GitHubAPI {
  nonisolated struct GitHubPublishInlineReviewMutation: GraphQLMutation {
    static let operationName: String = "GitHubPublishInlineReview"
    static let operationDocument: ApolloAPI.OperationDocument = .init(
      definition: .init(
        #"mutation GitHubPublishInlineReview($input: AddPullRequestReviewThreadInput!) { addPullRequestReviewThread(input: $input) { __typename thread { __typename id isResolved isOutdated pullRequest { __typename number headRefOid repository { __typename ...GitHubRepositoryIdentity } } } } }"#,
        fragments: [GitHubRepositoryIdentity.self]
      ))

    public var input: AddPullRequestReviewThreadInput

    public init(input: AddPullRequestReviewThreadInput) {
      self.input = input
    }

    @_spi(Unsafe) public var __variables: Variables? { ["input": input] }

    nonisolated struct Data: GitHubAPI.SelectionSet {
      let __data: DataDict
      init(_dataDict: DataDict) { __data = _dataDict }

      static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.Mutation }
      static var __selections: [ApolloAPI.Selection] { [
        .field("addPullRequestReviewThread", AddPullRequestReviewThread?.self, arguments: ["input": .variable("input")]),
      ] }
      static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
        GitHubPublishInlineReviewMutation.Data.self
      ] }

      var addPullRequestReviewThread: AddPullRequestReviewThread? { __data["addPullRequestReviewThread"] }

      /// AddPullRequestReviewThread
      nonisolated struct AddPullRequestReviewThread: GitHubAPI.SelectionSet {
        let __data: DataDict
        init(_dataDict: DataDict) { __data = _dataDict }

        static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.AddPullRequestReviewThreadPayload }
        static var __selections: [ApolloAPI.Selection] { [
          .field("__typename", String.self),
          .field("thread", Thread?.self),
        ] }
        static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
          GitHubPublishInlineReviewMutation.Data.AddPullRequestReviewThread.self
        ] }

        var thread: Thread? { __data["thread"] }

        /// AddPullRequestReviewThread.Thread
        nonisolated struct Thread: GitHubAPI.SelectionSet {
          let __data: DataDict
          init(_dataDict: DataDict) { __data = _dataDict }

          static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.PullRequestReviewThread }
          static var __selections: [ApolloAPI.Selection] { [
            .field("__typename", String.self),
            .field("id", GitHubAPI.ID.self),
            .field("isResolved", Bool.self),
            .field("isOutdated", Bool.self),
            .field("pullRequest", PullRequest.self),
          ] }
          static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
            GitHubPublishInlineReviewMutation.Data.AddPullRequestReviewThread.Thread.self
          ] }

          var id: GitHubAPI.ID { __data["id"] }
          var isResolved: Bool { __data["isResolved"] }
          var isOutdated: Bool { __data["isOutdated"] }
          var pullRequest: PullRequest { __data["pullRequest"] }

          /// AddPullRequestReviewThread.Thread.PullRequest
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
              GitHubPublishInlineReviewMutation.Data.AddPullRequestReviewThread.Thread.PullRequest.self
            ] }

            var number: Int { __data["number"] }
            var headRefOid: GitHubAPI.GitObjectID { __data["headRefOid"] }
            var repository: Repository { __data["repository"] }

            /// AddPullRequestReviewThread.Thread.PullRequest.Repository
            nonisolated struct Repository: GitHubAPI.SelectionSet {
              let __data: DataDict
              init(_dataDict: DataDict) { __data = _dataDict }

              static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.Repository }
              static var __selections: [ApolloAPI.Selection] { [
                .field("__typename", String.self),
                .fragment(GitHubRepositoryIdentity.self),
              ] }
              static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                GitHubPublishInlineReviewMutation.Data.AddPullRequestReviewThread.Thread.PullRequest.Repository.self,
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
