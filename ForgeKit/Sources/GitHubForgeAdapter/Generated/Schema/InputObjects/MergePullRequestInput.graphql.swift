// @generated
// This file was automatically generated and should not be edited.

@_spi(Internal) @_spi(Unsafe) import ApolloAPI

extension GitHubAPI {
  nonisolated struct MergePullRequestInput: InputObject {
    private(set) var __data: InputDict

    init(_ data: InputDict) {
      __data = data
    }

    init(
      authorEmail: GraphQLNullable<String> = nil,
      clientMutationId: GraphQLNullable<String> = nil,
      commitBody: GraphQLNullable<String> = nil,
      commitHeadline: GraphQLNullable<String> = nil,
      expectedHeadOid: GraphQLNullable<GitObjectID> = nil,
      mergeMethod: GraphQLNullable<GraphQLEnum<PullRequestMergeMethod>> = nil,
      pullRequestId: ID
    ) {
      __data = InputDict([
        "authorEmail": authorEmail,
        "clientMutationId": clientMutationId,
        "commitBody": commitBody,
        "commitHeadline": commitHeadline,
        "expectedHeadOid": expectedHeadOid,
        "mergeMethod": mergeMethod,
        "pullRequestId": pullRequestId
      ])
    }

    var authorEmail: GraphQLNullable<String> {
      get { __data["authorEmail"] }
      set { __data["authorEmail"] = newValue }
    }

    var clientMutationId: GraphQLNullable<String> {
      get { __data["clientMutationId"] }
      set { __data["clientMutationId"] = newValue }
    }

    var commitBody: GraphQLNullable<String> {
      get { __data["commitBody"] }
      set { __data["commitBody"] = newValue }
    }

    var commitHeadline: GraphQLNullable<String> {
      get { __data["commitHeadline"] }
      set { __data["commitHeadline"] = newValue }
    }

    var expectedHeadOid: GraphQLNullable<GitObjectID> {
      get { __data["expectedHeadOid"] }
      set { __data["expectedHeadOid"] = newValue }
    }

    var mergeMethod: GraphQLNullable<GraphQLEnum<PullRequestMergeMethod>> {
      get { __data["mergeMethod"] }
      set { __data["mergeMethod"] = newValue }
    }

    var pullRequestId: ID {
      get { __data["pullRequestId"] }
      set { __data["pullRequestId"] = newValue }
    }
  }

}
