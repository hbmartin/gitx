// @generated
// This file was automatically generated and should not be edited.

@_spi(Internal) @_spi(Unsafe) import ApolloAPI

extension GitHubAPI {
  nonisolated struct DeleteRefInput: InputObject {
    private(set) var __data: InputDict

    init(_ data: InputDict) {
      __data = data
    }

    init(
      clientMutationId: GraphQLNullable<String> = nil,
      refId: ID
    ) {
      __data = InputDict([
        "clientMutationId": clientMutationId,
        "refId": refId
      ])
    }

    var clientMutationId: GraphQLNullable<String> {
      get { __data["clientMutationId"] }
      set { __data["clientMutationId"] = newValue }
    }

    var refId: ID {
      get { __data["refId"] }
      set { __data["refId"] = newValue }
    }
  }

}
