// @generated
// This file was automatically generated and should not be edited.

import ApolloAPI
@_spi(Execution) @_spi(Unsafe) import ApolloAPI

extension GitHubAPI {
  nonisolated struct GitHubDeleteHeadBranchMutation: GraphQLMutation {
    static let operationName: String = "GitHubDeleteHeadBranch"
    static let operationDocument: ApolloAPI.OperationDocument = .init(
      definition: .init(
        #"mutation GitHubDeleteHeadBranch($input: DeleteRefInput!) { deleteRef(input: $input) { __typename clientMutationId } }"#
      ))

    public var input: DeleteRefInput

    public init(input: DeleteRefInput) {
      self.input = input
    }

    @_spi(Unsafe) public var __variables: Variables? { ["input": input] }

    nonisolated struct Data: GitHubAPI.SelectionSet {
      let __data: DataDict
      init(_dataDict: DataDict) { __data = _dataDict }

      static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.Mutation }
      static var __selections: [ApolloAPI.Selection] { [
        .field("deleteRef", DeleteRef?.self, arguments: ["input": .variable("input")]),
      ] }
      static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
        GitHubDeleteHeadBranchMutation.Data.self
      ] }

      var deleteRef: DeleteRef? { __data["deleteRef"] }

      /// DeleteRef
      nonisolated struct DeleteRef: GitHubAPI.SelectionSet {
        let __data: DataDict
        init(_dataDict: DataDict) { __data = _dataDict }

        static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.DeleteRefPayload }
        static var __selections: [ApolloAPI.Selection] { [
          .field("__typename", String.self),
          .field("clientMutationId", String?.self),
        ] }
        static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
          GitHubDeleteHeadBranchMutation.Data.DeleteRef.self
        ] }

        var clientMutationId: String? { __data["clientMutationId"] }
      }
    }
  }

}
