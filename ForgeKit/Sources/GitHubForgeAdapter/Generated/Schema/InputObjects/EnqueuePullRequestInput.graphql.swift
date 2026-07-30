// @generated
// This file was automatically generated and should not be edited.

@_spi(Internal) @_spi(Unsafe) import ApolloAPI

extension GitHubAPI {
  nonisolated struct EnqueuePullRequestInput: InputObject {
    private(set) var __data: InputDict

    init(_ data: InputDict) {
      __data = data
    }

    init(
      clientMutationId: GraphQLNullable<String> = nil,
      expectedHeadOid: GraphQLNullable<GitObjectID> = nil,
      jump: GraphQLNullable<Bool> = nil,
      pullRequestId: ID
    ) {
      __data = InputDict([
        "clientMutationId": clientMutationId,
        "expectedHeadOid": expectedHeadOid,
        "jump": jump,
        "pullRequestId": pullRequestId
      ])
    }

    var clientMutationId: GraphQLNullable<String> {
      get { __data["clientMutationId"] }
      set { __data["clientMutationId"] = newValue }
    }

    var expectedHeadOid: GraphQLNullable<GitObjectID> {
      get { __data["expectedHeadOid"] }
      set { __data["expectedHeadOid"] = newValue }
    }

    var jump: GraphQLNullable<Bool> {
      get { __data["jump"] }
      set { __data["jump"] = newValue }
    }

    var pullRequestId: ID {
      get { __data["pullRequestId"] }
      set { __data["pullRequestId"] = newValue }
    }
  }

}
