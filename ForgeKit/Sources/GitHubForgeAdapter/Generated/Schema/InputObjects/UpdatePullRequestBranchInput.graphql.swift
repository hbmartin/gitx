// @generated
// This file was automatically generated and should not be edited.

@_spi(Internal) @_spi(Unsafe) import ApolloAPI

extension GitHubAPI {
  nonisolated struct UpdatePullRequestBranchInput: InputObject {
    private(set) var __data: InputDict

    init(_ data: InputDict) {
      __data = data
    }

    init(
      clientMutationId: GraphQLNullable<String> = nil,
      expectedHeadOid: GraphQLNullable<GitObjectID> = nil,
      pullRequestId: ID,
      updateMethod: GraphQLNullable<GraphQLEnum<PullRequestBranchUpdateMethod>> = nil
    ) {
      __data = InputDict([
        "clientMutationId": clientMutationId,
        "expectedHeadOid": expectedHeadOid,
        "pullRequestId": pullRequestId,
        "updateMethod": updateMethod
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

    var pullRequestId: ID {
      get { __data["pullRequestId"] }
      set { __data["pullRequestId"] = newValue }
    }

    var updateMethod: GraphQLNullable<GraphQLEnum<PullRequestBranchUpdateMethod>> {
      get { __data["updateMethod"] }
      set { __data["updateMethod"] = newValue }
    }
  }

}
