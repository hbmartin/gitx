// @generated
// This file was automatically generated and should not be edited.

import ApolloAPI
@_spi(Execution) @_spi(Unsafe) import ApolloAPI

extension GitHubAPI {
  nonisolated struct GitHubSubmitFormalReviewMutation: GraphQLMutation {
    static let operationName: String = "GitHubSubmitFormalReview"
    static let operationDocument: ApolloAPI.OperationDocument = .init(
      definition: .init(
        #"mutation GitHubSubmitFormalReview($input: AddPullRequestReviewInput!) { addPullRequestReview(input: $input) { __typename pullRequestReview { __typename id state commit { __typename oid } pullRequest { __typename number repository { __typename ...GitHubRepositoryIdentity } } } } }"#,
        fragments: [GitHubRepositoryIdentity.self]
      ))

    public var input: AddPullRequestReviewInput

    public init(input: AddPullRequestReviewInput) {
      self.input = input
    }

    @_spi(Unsafe) public var __variables: Variables? { ["input": input] }

    nonisolated struct Data: GitHubAPI.SelectionSet {
      let __data: DataDict
      init(_dataDict: DataDict) { __data = _dataDict }

      static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.Mutation }
      static var __selections: [ApolloAPI.Selection] { [
        .field("addPullRequestReview", AddPullRequestReview?.self, arguments: ["input": .variable("input")]),
      ] }
      static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
        GitHubSubmitFormalReviewMutation.Data.self
      ] }

      var addPullRequestReview: AddPullRequestReview? { __data["addPullRequestReview"] }

      /// AddPullRequestReview
      nonisolated struct AddPullRequestReview: GitHubAPI.SelectionSet {
        let __data: DataDict
        init(_dataDict: DataDict) { __data = _dataDict }

        static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.AddPullRequestReviewPayload }
        static var __selections: [ApolloAPI.Selection] { [
          .field("__typename", String.self),
          .field("pullRequestReview", PullRequestReview?.self),
        ] }
        static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
          GitHubSubmitFormalReviewMutation.Data.AddPullRequestReview.self
        ] }

        var pullRequestReview: PullRequestReview? { __data["pullRequestReview"] }

        /// AddPullRequestReview.PullRequestReview
        nonisolated struct PullRequestReview: GitHubAPI.SelectionSet {
          let __data: DataDict
          init(_dataDict: DataDict) { __data = _dataDict }

          static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.PullRequestReview }
          static var __selections: [ApolloAPI.Selection] { [
            .field("__typename", String.self),
            .field("id", GitHubAPI.ID.self),
            .field("state", GraphQLEnum<GitHubAPI.PullRequestReviewState>.self),
            .field("commit", Commit?.self),
            .field("pullRequest", PullRequest.self),
          ] }
          static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
            GitHubSubmitFormalReviewMutation.Data.AddPullRequestReview.PullRequestReview.self
          ] }

          var id: GitHubAPI.ID { __data["id"] }
          var state: GraphQLEnum<GitHubAPI.PullRequestReviewState> { __data["state"] }
          var commit: Commit? { __data["commit"] }
          var pullRequest: PullRequest { __data["pullRequest"] }

          /// AddPullRequestReview.PullRequestReview.Commit
          nonisolated struct Commit: GitHubAPI.SelectionSet {
            let __data: DataDict
            init(_dataDict: DataDict) { __data = _dataDict }

            static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.Commit }
            static var __selections: [ApolloAPI.Selection] { [
              .field("__typename", String.self),
              .field("oid", GitHubAPI.GitObjectID.self),
            ] }
            static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
              GitHubSubmitFormalReviewMutation.Data.AddPullRequestReview.PullRequestReview.Commit.self
            ] }

            var oid: GitHubAPI.GitObjectID { __data["oid"] }
          }

          /// AddPullRequestReview.PullRequestReview.PullRequest
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
              GitHubSubmitFormalReviewMutation.Data.AddPullRequestReview.PullRequestReview.PullRequest.self
            ] }

            var number: Int { __data["number"] }
            var repository: Repository { __data["repository"] }

            /// AddPullRequestReview.PullRequestReview.PullRequest.Repository
            nonisolated struct Repository: GitHubAPI.SelectionSet {
              let __data: DataDict
              init(_dataDict: DataDict) { __data = _dataDict }

              static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.Repository }
              static var __selections: [ApolloAPI.Selection] { [
                .field("__typename", String.self),
                .fragment(GitHubRepositoryIdentity.self),
              ] }
              static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                GitHubSubmitFormalReviewMutation.Data.AddPullRequestReview.PullRequestReview.PullRequest.Repository.self,
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
