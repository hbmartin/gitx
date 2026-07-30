// @generated
// This file was automatically generated and should not be edited.

import ApolloAPI
@_spi(Execution) @_spi(Unsafe) import ApolloAPI

extension GitHubAPI {
  nonisolated struct GitHubPullRequestMutationPreflightQuery: GraphQLQuery {
    static let operationName: String = "GitHubPullRequestMutationPreflight"
    static let operationDocument: ApolloAPI.OperationDocument = .init(
      definition: .init(
        #"query GitHubPullRequestMutationPreflight($owner: String!, $name: String!, $number: Int!) { repository(owner: $owner, name: $name) { __typename ...GitHubRepositoryIdentity id mergeCommitAllowed squashMergeAllowed rebaseMergeAllowed viewerPermission pullRequest(number: $number) { __typename ...GitHubPullRequestMutationSnapshot id number title body state isDraft createdAt updatedAt closedAt mergedAt headRefName headRefOid headRepository { __typename ...GitHubRepositoryIdentity } baseRefName baseRefOid baseRepository { __typename ...GitHubRepositoryIdentity } viewerCanClose viewerCanReopen viewerCanUpdate viewerCanUpdateBranch mergeable reviewDecision statusCheckRollup { __typename state } mergeQueueEntry { __typename id } } } }"#,
        fragments: [GitHubPullRequestMutationSnapshot.self, GitHubRepositoryIdentity.self]
      ))

    public var owner: String
    public var name: String
    public var number: Int32

    public init(
      owner: String,
      name: String,
      number: Int32
    ) {
      self.owner = owner
      self.name = name
      self.number = number
    }

    @_spi(Unsafe) public var __variables: Variables? { [
      "owner": owner,
      "name": name,
      "number": number
    ] }

    nonisolated struct Data: GitHubAPI.SelectionSet {
      let __data: DataDict
      init(_dataDict: DataDict) { __data = _dataDict }

      static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.Query }
      static var __selections: [ApolloAPI.Selection] { [
        .field("repository", Repository?.self, arguments: [
          "owner": .variable("owner"),
          "name": .variable("name")
        ]),
      ] }
      static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
        GitHubPullRequestMutationPreflightQuery.Data.self
      ] }

      var repository: Repository? { __data["repository"] }

      /// Repository
      nonisolated struct Repository: GitHubAPI.SelectionSet {
        let __data: DataDict
        init(_dataDict: DataDict) { __data = _dataDict }

        static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.Repository }
        static var __selections: [ApolloAPI.Selection] { [
          .field("__typename", String.self),
          .field("id", GitHubAPI.ID.self),
          .field("mergeCommitAllowed", Bool.self),
          .field("squashMergeAllowed", Bool.self),
          .field("rebaseMergeAllowed", Bool.self),
          .field("viewerPermission", GraphQLEnum<GitHubAPI.RepositoryPermission>?.self),
          .field("pullRequest", PullRequest?.self, arguments: ["number": .variable("number")]),
          .fragment(GitHubRepositoryIdentity.self),
        ] }
        static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
          GitHubPullRequestMutationPreflightQuery.Data.Repository.self,
          GitHubRepositoryIdentity.self
        ] }

        var id: GitHubAPI.ID { __data["id"] }
        var mergeCommitAllowed: Bool { __data["mergeCommitAllowed"] }
        var squashMergeAllowed: Bool { __data["squashMergeAllowed"] }
        var rebaseMergeAllowed: Bool { __data["rebaseMergeAllowed"] }
        var viewerPermission: GraphQLEnum<GitHubAPI.RepositoryPermission>? { __data["viewerPermission"] }
        var pullRequest: PullRequest? { __data["pullRequest"] }
        var name: String { __data["name"] }
        var nameWithOwner: String { __data["nameWithOwner"] }
        var owner: Owner { __data["owner"] }

        struct Fragments: FragmentContainer {
          let __data: DataDict
          init(_dataDict: DataDict) { __data = _dataDict }

          var gitHubRepositoryIdentity: GitHubRepositoryIdentity { _toFragment() }
        }

        /// Repository.PullRequest
        nonisolated struct PullRequest: GitHubAPI.SelectionSet {
          let __data: DataDict
          init(_dataDict: DataDict) { __data = _dataDict }

          static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.PullRequest }
          static var __selections: [ApolloAPI.Selection] { [
            .field("__typename", String.self),
            .field("id", GitHubAPI.ID.self),
            .field("number", Int.self),
            .field("title", String.self),
            .field("body", String.self),
            .field("state", GraphQLEnum<GitHubAPI.PullRequestState>.self),
            .field("isDraft", Bool.self),
            .field("createdAt", GitHubAPI.DateTime.self),
            .field("updatedAt", GitHubAPI.DateTime.self),
            .field("closedAt", GitHubAPI.DateTime?.self),
            .field("mergedAt", GitHubAPI.DateTime?.self),
            .field("headRefName", String.self),
            .field("headRefOid", GitHubAPI.GitObjectID.self),
            .field("headRepository", HeadRepository?.self),
            .field("baseRefName", String.self),
            .field("baseRefOid", GitHubAPI.GitObjectID.self),
            .field("baseRepository", BaseRepository?.self),
            .field("viewerCanClose", Bool.self),
            .field("viewerCanReopen", Bool.self),
            .field("viewerCanUpdate", Bool.self),
            .field("viewerCanUpdateBranch", Bool.self),
            .field("mergeable", GraphQLEnum<GitHubAPI.MergeableState>.self),
            .field("reviewDecision", GraphQLEnum<GitHubAPI.PullRequestReviewDecision>?.self),
            .field("statusCheckRollup", StatusCheckRollup?.self),
            .field("mergeQueueEntry", MergeQueueEntry?.self),
            .fragment(GitHubPullRequestMutationSnapshot.self),
          ] }
          static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
            GitHubPullRequestMutationPreflightQuery.Data.Repository.PullRequest.self
          ] }

          var id: GitHubAPI.ID { __data["id"] }
          var number: Int { __data["number"] }
          var title: String { __data["title"] }
          var body: String { __data["body"] }
          var state: GraphQLEnum<GitHubAPI.PullRequestState> { __data["state"] }
          var isDraft: Bool { __data["isDraft"] }
          var createdAt: GitHubAPI.DateTime { __data["createdAt"] }
          var updatedAt: GitHubAPI.DateTime { __data["updatedAt"] }
          var closedAt: GitHubAPI.DateTime? { __data["closedAt"] }
          var mergedAt: GitHubAPI.DateTime? { __data["mergedAt"] }
          var headRefName: String { __data["headRefName"] }
          var headRefOid: GitHubAPI.GitObjectID { __data["headRefOid"] }
          var headRepository: HeadRepository? { __data["headRepository"] }
          var baseRefName: String { __data["baseRefName"] }
          var baseRefOid: GitHubAPI.GitObjectID { __data["baseRefOid"] }
          var baseRepository: BaseRepository? { __data["baseRepository"] }
          var viewerCanClose: Bool { __data["viewerCanClose"] }
          var viewerCanReopen: Bool { __data["viewerCanReopen"] }
          var viewerCanUpdate: Bool { __data["viewerCanUpdate"] }
          var viewerCanUpdateBranch: Bool { __data["viewerCanUpdateBranch"] }
          var mergeable: GraphQLEnum<GitHubAPI.MergeableState> { __data["mergeable"] }
          var reviewDecision: GraphQLEnum<GitHubAPI.PullRequestReviewDecision>? { __data["reviewDecision"] }
          var statusCheckRollup: StatusCheckRollup? { __data["statusCheckRollup"] }
          var mergeQueueEntry: MergeQueueEntry? { __data["mergeQueueEntry"] }

          struct Fragments: FragmentContainer {
            let __data: DataDict
            init(_dataDict: DataDict) { __data = _dataDict }

            var gitHubPullRequestMutationSnapshot: GitHubPullRequestMutationSnapshot { _toFragment() }
          }

          /// Repository.PullRequest.HeadRepository
          nonisolated struct HeadRepository: GitHubAPI.SelectionSet {
            let __data: DataDict
            init(_dataDict: DataDict) { __data = _dataDict }

            static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.Repository }
            static var __selections: [ApolloAPI.Selection] { [
              .field("__typename", String.self),
              .fragment(GitHubRepositoryIdentity.self),
            ] }
            static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
              GitHubPullRequestMutationPreflightQuery.Data.Repository.PullRequest.HeadRepository.self,
              GitHubRepositoryIdentity.self
            ] }

            var id: GitHubAPI.ID { __data["id"] }
            var name: String { __data["name"] }
            var nameWithOwner: String { __data["nameWithOwner"] }
            var owner: Owner { __data["owner"] }

            struct Fragments: FragmentContainer {
              let __data: DataDict
              init(_dataDict: DataDict) { __data = _dataDict }

              var gitHubRepositoryIdentity: GitHubRepositoryIdentity { _toFragment() }
            }

            typealias Owner = GitHubRepositoryIdentity.Owner
          }

          /// Repository.PullRequest.BaseRepository
          nonisolated struct BaseRepository: GitHubAPI.SelectionSet {
            let __data: DataDict
            init(_dataDict: DataDict) { __data = _dataDict }

            static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.Repository }
            static var __selections: [ApolloAPI.Selection] { [
              .field("__typename", String.self),
              .fragment(GitHubRepositoryIdentity.self),
            ] }
            static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
              GitHubPullRequestMutationPreflightQuery.Data.Repository.PullRequest.BaseRepository.self,
              GitHubRepositoryIdentity.self
            ] }

            var id: GitHubAPI.ID { __data["id"] }
            var name: String { __data["name"] }
            var nameWithOwner: String { __data["nameWithOwner"] }
            var owner: Owner { __data["owner"] }

            struct Fragments: FragmentContainer {
              let __data: DataDict
              init(_dataDict: DataDict) { __data = _dataDict }

              var gitHubRepositoryIdentity: GitHubRepositoryIdentity { _toFragment() }
            }

            typealias Owner = GitHubRepositoryIdentity.Owner
          }

          /// Repository.PullRequest.StatusCheckRollup
          nonisolated struct StatusCheckRollup: GitHubAPI.SelectionSet {
            let __data: DataDict
            init(_dataDict: DataDict) { __data = _dataDict }

            static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.StatusCheckRollup }
            static var __selections: [ApolloAPI.Selection] { [
              .field("__typename", String.self),
              .field("state", GraphQLEnum<GitHubAPI.StatusState>.self),
            ] }
            static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
              GitHubPullRequestMutationPreflightQuery.Data.Repository.PullRequest.StatusCheckRollup.self
            ] }

            var state: GraphQLEnum<GitHubAPI.StatusState> { __data["state"] }
          }

          /// Repository.PullRequest.MergeQueueEntry
          nonisolated struct MergeQueueEntry: GitHubAPI.SelectionSet {
            let __data: DataDict
            init(_dataDict: DataDict) { __data = _dataDict }

            static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.MergeQueueEntry }
            static var __selections: [ApolloAPI.Selection] { [
              .field("__typename", String.self),
              .field("id", GitHubAPI.ID.self),
            ] }
            static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
              GitHubPullRequestMutationPreflightQuery.Data.Repository.PullRequest.MergeQueueEntry.self
            ] }

            var id: GitHubAPI.ID { __data["id"] }
          }
        }

        typealias Owner = GitHubRepositoryIdentity.Owner
      }
    }
  }

}
