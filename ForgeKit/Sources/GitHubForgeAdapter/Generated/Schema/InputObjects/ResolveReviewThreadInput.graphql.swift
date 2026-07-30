// @generated
// This file was automatically generated and should not be edited.

@_spi(Internal) @_spi(Unsafe) import ApolloAPI

extension GitHubAPI {
  nonisolated struct ResolveReviewThreadInput: InputObject {
    private(set) var __data: InputDict

    init(_ data: InputDict) {
      __data = data
    }

    init(
      clientMutationId: GraphQLNullable<String> = nil,
      threadId: ID
    ) {
      __data = InputDict([
        "clientMutationId": clientMutationId,
        "threadId": threadId
      ])
    }

    var clientMutationId: GraphQLNullable<String> {
      get { __data["clientMutationId"] }
      set { __data["clientMutationId"] = newValue }
    }

    var threadId: ID {
      get { __data["threadId"] }
      set { __data["threadId"] = newValue }
    }
  }

}
