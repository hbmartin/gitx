// @generated
// This file was automatically generated and should not be edited.

@_spi(Internal) @_spi(Unsafe) import ApolloAPI

extension GitHubAPI {
  nonisolated struct DraftPullRequestReviewComment: InputObject {
    private(set) var __data: InputDict

    init(_ data: InputDict) {
      __data = data
    }

    init(
      body: String,
      path: String,
      position: Int32
    ) {
      __data = InputDict([
        "body": body,
        "path": path,
        "position": position
      ])
    }

    var body: String {
      get { __data["body"] }
      set { __data["body"] = newValue }
    }

    var path: String {
      get { __data["path"] }
      set { __data["path"] = newValue }
    }

    var position: Int32 {
      get { __data["position"] }
      set { __data["position"] = newValue }
    }
  }

}
