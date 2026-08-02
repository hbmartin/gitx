// @generated
// This file was automatically generated and should not be edited.

@_spi(Internal) @_spi(Unsafe) import ApolloAPI

extension GitHubAPI {
  nonisolated struct CreatePullRequestInput: InputObject {
    private(set) var __data: InputDict

    init(_ data: InputDict) {
      __data = data
    }

    init(
      baseRefName: String,
      body: GraphQLNullable<String> = nil,
      clientMutationId: GraphQLNullable<String> = nil,
      draft: GraphQLNullable<Bool> = nil,
      headRefName: String,
      headRepositoryId: GraphQLNullable<ID> = nil,
      maintainerCanModify: GraphQLNullable<Bool> = nil,
      repositoryId: ID,
      title: String
    ) {
      __data = InputDict([
        "baseRefName": baseRefName,
        "body": body,
        "clientMutationId": clientMutationId,
        "draft": draft,
        "headRefName": headRefName,
        "headRepositoryId": headRepositoryId,
        "maintainerCanModify": maintainerCanModify,
        "repositoryId": repositoryId,
        "title": title
      ])
    }

    var baseRefName: String {
      get { __data["baseRefName"] }
      set { __data["baseRefName"] = newValue }
    }

    var body: GraphQLNullable<String> {
      get { __data["body"] }
      set { __data["body"] = newValue }
    }

    var clientMutationId: GraphQLNullable<String> {
      get { __data["clientMutationId"] }
      set { __data["clientMutationId"] = newValue }
    }

    var draft: GraphQLNullable<Bool> {
      get { __data["draft"] }
      set { __data["draft"] = newValue }
    }

    var headRefName: String {
      get { __data["headRefName"] }
      set { __data["headRefName"] = newValue }
    }

    var headRepositoryId: GraphQLNullable<ID> {
      get { __data["headRepositoryId"] }
      set { __data["headRepositoryId"] = newValue }
    }

    var maintainerCanModify: GraphQLNullable<Bool> {
      get { __data["maintainerCanModify"] }
      set { __data["maintainerCanModify"] = newValue }
    }

    var repositoryId: ID {
      get { __data["repositoryId"] }
      set { __data["repositoryId"] = newValue }
    }

    var title: String {
      get { __data["title"] }
      set { __data["title"] = newValue }
    }
  }

}
