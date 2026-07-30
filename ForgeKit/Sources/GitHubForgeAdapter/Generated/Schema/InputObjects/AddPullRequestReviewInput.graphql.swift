// @generated
// This file was automatically generated and should not be edited.

@_spi(Internal) @_spi(Unsafe) import ApolloAPI

extension GitHubAPI {
  nonisolated struct AddPullRequestReviewInput: InputObject {
    private(set) var __data: InputDict

    init(_ data: InputDict) {
      __data = data
    }

    init(
      body: GraphQLNullable<String> = nil,
      clientMutationId: GraphQLNullable<String> = nil,
      comments: GraphQLNullable<[DraftPullRequestReviewComment?]> = nil,
      commitOID: GraphQLNullable<GitObjectID> = nil,
      event: GraphQLNullable<GraphQLEnum<PullRequestReviewEvent>> = nil,
      pullRequestId: ID,
      threads: GraphQLNullable<[DraftPullRequestReviewThread?]> = nil
    ) {
      __data = InputDict([
        "body": body,
        "clientMutationId": clientMutationId,
        "comments": comments,
        "commitOID": commitOID,
        "event": event,
        "pullRequestId": pullRequestId,
        "threads": threads
      ])
    }

    var body: GraphQLNullable<String> {
      get { __data["body"] }
      set { __data["body"] = newValue }
    }

    var clientMutationId: GraphQLNullable<String> {
      get { __data["clientMutationId"] }
      set { __data["clientMutationId"] = newValue }
    }

    var comments: GraphQLNullable<[DraftPullRequestReviewComment?]> {
      get { __data["comments"] }
      set { __data["comments"] = newValue }
    }

    var commitOID: GraphQLNullable<GitObjectID> {
      get { __data["commitOID"] }
      set { __data["commitOID"] = newValue }
    }

    var event: GraphQLNullable<GraphQLEnum<PullRequestReviewEvent>> {
      get { __data["event"] }
      set { __data["event"] = newValue }
    }

    var pullRequestId: ID {
      get { __data["pullRequestId"] }
      set { __data["pullRequestId"] = newValue }
    }

    var threads: GraphQLNullable<[DraftPullRequestReviewThread?]> {
      get { __data["threads"] }
      set { __data["threads"] = newValue }
    }
  }

}
