// @generated
// This file was automatically generated and should not be edited.

@_spi(Internal) @_spi(Unsafe) import ApolloAPI

extension GitHubAPI {
  nonisolated struct DraftPullRequestReviewThread: InputObject {
    private(set) var __data: InputDict

    init(_ data: InputDict) {
      __data = data
    }

    init(
      body: String,
      line: GraphQLNullable<Int32> = nil,
      path: GraphQLNullable<String> = nil,
      side: GraphQLNullable<GraphQLEnum<DiffSide>> = nil,
      startLine: GraphQLNullable<Int32> = nil,
      startSide: GraphQLNullable<GraphQLEnum<DiffSide>> = nil
    ) {
      __data = InputDict([
        "body": body,
        "line": line,
        "path": path,
        "side": side,
        "startLine": startLine,
        "startSide": startSide
      ])
    }

    var body: String {
      get { __data["body"] }
      set { __data["body"] = newValue }
    }

    var line: GraphQLNullable<Int32> {
      get { __data["line"] }
      set { __data["line"] = newValue }
    }

    var path: GraphQLNullable<String> {
      get { __data["path"] }
      set { __data["path"] = newValue }
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
  }

}
