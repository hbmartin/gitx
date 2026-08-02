// @generated
// This file was automatically generated and should not be edited.

@_spi(Internal) @_spi(Unsafe) import ApolloAPI

extension GitHubAPI {
  nonisolated struct AddPullRequestReviewThreadReplyInput: InputObject {
    private(set) var __data: InputDict

    init(_ data: InputDict) {
      __data = data
    }

    init(
      body: String,
      clientMutationId: GraphQLNullable<String> = nil,
      pullRequestReviewId: GraphQLNullable<ID> = nil,
      pullRequestReviewThreadId: ID
    ) {
      __data = InputDict([
        "body": body,
        "clientMutationId": clientMutationId,
        "pullRequestReviewId": pullRequestReviewId,
        "pullRequestReviewThreadId": pullRequestReviewThreadId
      ])
    }

    var body: String {
      get { __data["body"] }
      set { __data["body"] = newValue }
    }

    var clientMutationId: GraphQLNullable<String> {
      get { __data["clientMutationId"] }
      set { __data["clientMutationId"] = newValue }
    }

    var pullRequestReviewId: GraphQLNullable<ID> {
      get { __data["pullRequestReviewId"] }
      set { __data["pullRequestReviewId"] = newValue }
    }

    var pullRequestReviewThreadId: ID {
      get { __data["pullRequestReviewThreadId"] }
      set { __data["pullRequestReviewThreadId"] = newValue }
    }
  }

}
