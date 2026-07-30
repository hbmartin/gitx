// @generated
// This file was automatically generated and should not be edited.

@_spi(Internal) @_spi(Unsafe) import ApolloAPI

extension GitHubAPI {
  nonisolated struct AddPullRequestReviewThreadInput: InputObject {
    private(set) var __data: InputDict

    init(_ data: InputDict) {
      __data = data
    }

    init(
      body: String,
      clientMutationId: GraphQLNullable<String> = nil,
      line: GraphQLNullable<Int32> = nil,
      path: GraphQLNullable<String> = nil,
      pullRequestId: GraphQLNullable<ID> = nil,
      pullRequestReviewId: GraphQLNullable<ID> = nil,
      side: GraphQLNullable<GraphQLEnum<DiffSide>> = nil,
      startLine: GraphQLNullable<Int32> = nil,
      startSide: GraphQLNullable<GraphQLEnum<DiffSide>> = nil,
      subjectType: GraphQLNullable<GraphQLEnum<PullRequestReviewThreadSubjectType>> = nil
    ) {
      __data = InputDict([
        "body": body,
        "clientMutationId": clientMutationId,
        "line": line,
        "path": path,
        "pullRequestId": pullRequestId,
        "pullRequestReviewId": pullRequestReviewId,
        "side": side,
        "startLine": startLine,
        "startSide": startSide,
        "subjectType": subjectType
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

    var line: GraphQLNullable<Int32> {
      get { __data["line"] }
      set { __data["line"] = newValue }
    }

    var path: GraphQLNullable<String> {
      get { __data["path"] }
      set { __data["path"] = newValue }
    }

    var pullRequestId: GraphQLNullable<ID> {
      get { __data["pullRequestId"] }
      set { __data["pullRequestId"] = newValue }
    }

    var pullRequestReviewId: GraphQLNullable<ID> {
      get { __data["pullRequestReviewId"] }
      set { __data["pullRequestReviewId"] = newValue }
    }

    var side: GraphQLNullable<GraphQLEnum<DiffSide>> {
      get { __data["side"] }
      set { __data["side"] = newValue }
    }

    var startLine: GraphQLNullable<Int32> {
      get { __data["startLine"] }
      set { __data["startLine"] = newValue }
    }

    var startSide: GraphQLNullable<GraphQLEnum<DiffSide>> {
      get { __data["startSide"] }
      set { __data["startSide"] = newValue }
    }

    var subjectType: GraphQLNullable<GraphQLEnum<PullRequestReviewThreadSubjectType>> {
      get { __data["subjectType"] }
      set { __data["subjectType"] = newValue }
    }
  }

}
