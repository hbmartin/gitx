// @generated
// This file was automatically generated and should not be edited.

@_spi(Internal) @_spi(Unsafe) import ApolloAPI

extension GitHubAPI {
  nonisolated struct UpdatePullRequestInput: InputObject {
    private(set) var __data: InputDict

    init(_ data: InputDict) {
      __data = data
    }

    init(
      assigneeIds: GraphQLNullable<[ID]> = nil,
      baseRefName: GraphQLNullable<String> = nil,
      body: GraphQLNullable<String> = nil,
      clientMutationId: GraphQLNullable<String> = nil,
      labelIds: GraphQLNullable<[ID]> = nil,
      maintainerCanModify: GraphQLNullable<Bool> = nil,
      milestoneId: GraphQLNullable<ID> = nil,
      projectIds: GraphQLNullable<[ID]> = nil,
      pullRequestId: ID,
      state: GraphQLNullable<GraphQLEnum<PullRequestUpdateState>> = nil,
      title: GraphQLNullable<String> = nil
    ) {
      __data = InputDict([
        "assigneeIds": assigneeIds,
        "baseRefName": baseRefName,
        "body": body,
        "clientMutationId": clientMutationId,
        "labelIds": labelIds,
        "maintainerCanModify": maintainerCanModify,
        "milestoneId": milestoneId,
        "projectIds": projectIds,
        "pullRequestId": pullRequestId,
        "state": state,
        "title": title
      ])
    }

    var assigneeIds: GraphQLNullable<[ID]> {
      get { __data["assigneeIds"] }
      set { __data["assigneeIds"] = newValue }
    }

    var baseRefName: GraphQLNullable<String> {
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

    var labelIds: GraphQLNullable<[ID]> {
      get { __data["labelIds"] }
      set { __data["labelIds"] = newValue }
    }

    var maintainerCanModify: GraphQLNullable<Bool> {
      get { __data["maintainerCanModify"] }
      set { __data["maintainerCanModify"] = newValue }
    }

    var milestoneId: GraphQLNullable<ID> {
      get { __data["milestoneId"] }
      set { __data["milestoneId"] = newValue }
    }

    var projectIds: GraphQLNullable<[ID]> {
      get { __data["projectIds"] }
      set { __data["projectIds"] = newValue }
    }

    var pullRequestId: ID {
      get { __data["pullRequestId"] }
      set { __data["pullRequestId"] = newValue }
    }

    var state: GraphQLNullable<GraphQLEnum<PullRequestUpdateState>> {
      get { __data["state"] }
      set { __data["state"] = newValue }
    }

    var title: GraphQLNullable<String> {
      get { __data["title"] }
      set { __data["title"] = newValue }
    }
  }

}
