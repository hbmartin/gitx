// @generated
// This file was automatically generated and should not be edited.

import ApolloAPI
@_spi(Execution) @_spi(Unsafe) import ApolloAPI

extension GitHubAPI {
  nonisolated struct GitHubPullRequestDetailsQuery: GraphQLQuery {
    static let operationName: String = "GitHubPullRequestDetails"
    static let operationDocument: ApolloAPI.OperationDocument = .init(
      definition: .init(
        #"query GitHubPullRequestDetails($owner: String!, $name: String!, $number: Int!, $timelineFirst: Int!, $timelineAfter: String, $checkFirst: Int!, $checkAfter: String) { repository(owner: $owner, name: $name) { __typename id pullRequest(number: $number) { __typename ...GitHubPullRequestSummary body mergeable assignedActors(first: 100) { __typename totalCount pageInfo { __typename ...GitHubPageInfo } nodes { __typename ...GitHubAssignee } } milestone { __typename ...GitHubMilestone } participants(first: 100) { __typename totalCount pageInfo { __typename ...GitHubPageInfo } nodes { __typename ...GitHubActor } } reviewRequests(first: 100) { __typename totalCount pageInfo { __typename ...GitHubPageInfo } nodes { __typename id requestedReviewer { __typename ...GitHubRequestedReviewer } } } latestReviews(first: 100) { __typename totalCount pageInfo { __typename ...GitHubPageInfo } nodes { __typename id state submittedAt author { __typename ...GitHubActor } } } closingIssuesReferences(first: 100) { __typename totalCount pageInfo { __typename ...GitHubPageInfo } nodes { __typename id number state title repository { __typename ...GitHubRepositoryIdentity } } } statusCheckRollup { __typename state contexts(first: $checkFirst, after: $checkAfter) { __typename totalCount pageInfo { __typename ...GitHubPageInfo } nodes { __typename ... on CheckRun { id name summary status conclusion detailsUrl startedAt completedAt } ... on StatusContext { id context description state targetUrl createdAt updatedAt } } } } timelineItems( first: $timelineFirst after: $timelineAfter itemTypes: [ ISSUE_COMMENT PULL_REQUEST_REVIEW CLOSED_EVENT REOPENED_EVENT MERGED_EVENT ASSIGNED_EVENT UNASSIGNED_EVENT LABELED_EVENT UNLABELED_EVENT MILESTONED_EVENT DEMILESTONED_EVENT RENAMED_TITLE_EVENT CROSS_REFERENCED_EVENT ] ) { __typename totalCount pageInfo { __typename ...GitHubPageInfo } nodes { __typename ... on IssueComment { ...GitHubIssueComment } ... on PullRequestReview { id body state createdAt submittedAt author { __typename ...GitHubActor } commit { __typename oid } } ... on ClosedEvent { id createdAt actor { __typename ...GitHubActor } } ... on ReopenedEvent { id createdAt actor { __typename ...GitHubActor } } ... on MergedEvent { id createdAt actor { __typename ...GitHubActor } commit { __typename oid } } ... on AssignedEvent { id createdAt actor { __typename ...GitHubActor } assignee { __typename ...GitHubAssignee } } ... on UnassignedEvent { id createdAt actor { __typename ...GitHubActor } assignee { __typename ...GitHubAssignee } } ... on LabeledEvent { id createdAt actor { __typename ...GitHubActor } label { __typename ...GitHubLabel } } ... on UnlabeledEvent { id createdAt actor { __typename ...GitHubActor } label { __typename ...GitHubLabel } } ... on MilestonedEvent { id createdAt milestoneTitle actor { __typename ...GitHubActor } } ... on DemilestonedEvent { id createdAt milestoneTitle actor { __typename ...GitHubActor } } ... on RenamedTitleEvent { id createdAt previousTitle currentTitle actor { __typename ...GitHubActor } } ... on CrossReferencedEvent { id createdAt actor { __typename ...GitHubActor } source { __typename ... on PullRequest { number pullRequestState: state title repository { __typename ...GitHubRepositoryIdentity } } ... on Issue { number issueState: state title repository { __typename ...GitHubRepositoryIdentity } } } } } } } } }"#,
        fragments: [GitHubActor.self, GitHubAssignee.self, GitHubIssueComment.self, GitHubLabel.self, GitHubMilestone.self, GitHubPageInfo.self, GitHubPullRequestSummary.self, GitHubRepositoryIdentity.self, GitHubRequestedReviewer.self]
      ))

    public var owner: String
    public var name: String
    public var number: Int32
    public var timelineFirst: Int32
    public var timelineAfter: GraphQLNullable<String>
    public var checkFirst: Int32
    public var checkAfter: GraphQLNullable<String>

    public init(
      owner: String,
      name: String,
      number: Int32,
      timelineFirst: Int32,
      timelineAfter: GraphQLNullable<String>,
      checkFirst: Int32,
      checkAfter: GraphQLNullable<String>
    ) {
      self.owner = owner
      self.name = name
      self.number = number
      self.timelineFirst = timelineFirst
      self.timelineAfter = timelineAfter
      self.checkFirst = checkFirst
      self.checkAfter = checkAfter
    }

    @_spi(Unsafe) public var __variables: Variables? { [
      "owner": owner,
      "name": name,
      "number": number,
      "timelineFirst": timelineFirst,
      "timelineAfter": timelineAfter,
      "checkFirst": checkFirst,
      "checkAfter": checkAfter
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
        GitHubPullRequestDetailsQuery.Data.self
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
          .field("pullRequest", PullRequest?.self, arguments: ["number": .variable("number")]),
        ] }
        static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
          GitHubPullRequestDetailsQuery.Data.Repository.self
        ] }

        var id: GitHubAPI.ID { __data["id"] }
        var pullRequest: PullRequest? { __data["pullRequest"] }

        /// Repository.PullRequest
        nonisolated struct PullRequest: GitHubAPI.SelectionSet {
          let __data: DataDict
          init(_dataDict: DataDict) { __data = _dataDict }

          static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.PullRequest }
          static var __selections: [ApolloAPI.Selection] { [
            .field("__typename", String.self),
            .field("body", String.self),
            .field("mergeable", GraphQLEnum<GitHubAPI.MergeableState>.self),
            .field("assignedActors", AssignedActors.self, arguments: ["first": 100]),
            .field("milestone", Milestone?.self),
            .field("participants", Participants.self, arguments: ["first": 100]),
            .field("reviewRequests", ReviewRequests?.self, arguments: ["first": 100]),
            .field("latestReviews", LatestReviews?.self, arguments: ["first": 100]),
            .field("closingIssuesReferences", ClosingIssuesReferences?.self, arguments: ["first": 100]),
            .field("statusCheckRollup", StatusCheckRollup?.self),
            .field("timelineItems", TimelineItems.self, arguments: [
              "first": .variable("timelineFirst"),
              "after": .variable("timelineAfter"),
              "itemTypes": ["ISSUE_COMMENT", "PULL_REQUEST_REVIEW", "CLOSED_EVENT", "REOPENED_EVENT", "MERGED_EVENT", "ASSIGNED_EVENT", "UNASSIGNED_EVENT", "LABELED_EVENT", "UNLABELED_EVENT", "MILESTONED_EVENT", "DEMILESTONED_EVENT", "RENAMED_TITLE_EVENT", "CROSS_REFERENCED_EVENT"]
            ]),
            .fragment(GitHubPullRequestSummary.self),
          ] }
          static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
            GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.self,
            GitHubPullRequestSummary.self
          ] }

          var body: String { __data["body"] }
          var mergeable: GraphQLEnum<GitHubAPI.MergeableState> { __data["mergeable"] }
          var assignedActors: AssignedActors { __data["assignedActors"] }
          var milestone: Milestone? { __data["milestone"] }
          var participants: Participants { __data["participants"] }
          var reviewRequests: ReviewRequests? { __data["reviewRequests"] }
          var latestReviews: LatestReviews? { __data["latestReviews"] }
          var closingIssuesReferences: ClosingIssuesReferences? { __data["closingIssuesReferences"] }
          var statusCheckRollup: StatusCheckRollup? { __data["statusCheckRollup"] }
          var timelineItems: TimelineItems { __data["timelineItems"] }
          var id: GitHubAPI.ID { __data["id"] }
          var number: Int { __data["number"] }
          var pullRequestState: GraphQLEnum<GitHubAPI.PullRequestState> { __data["pullRequestState"] }
          var isDraft: Bool { __data["isDraft"] }
          var title: String { __data["title"] }
          var createdAt: GitHubAPI.DateTime { __data["createdAt"] }
          var updatedAt: GitHubAPI.DateTime { __data["updatedAt"] }
          var closedAt: GitHubAPI.DateTime? { __data["closedAt"] }
          var mergedAt: GitHubAPI.DateTime? { __data["mergedAt"] }
          var author: Author? { __data["author"] }
          var headRefName: String { __data["headRefName"] }
          var headRefOid: GitHubAPI.GitObjectID { __data["headRefOid"] }
          var headRepository: HeadRepository? { __data["headRepository"] }
          var baseRefName: String { __data["baseRefName"] }
          var baseRefOid: GitHubAPI.GitObjectID { __data["baseRefOid"] }
          var baseRepository: BaseRepository? { __data["baseRepository"] }
          var labels: Labels? { __data["labels"] }
          var reviewDecision: GraphQLEnum<GitHubAPI.PullRequestReviewDecision>? { __data["reviewDecision"] }

          struct Fragments: FragmentContainer {
            let __data: DataDict
            init(_dataDict: DataDict) { __data = _dataDict }

            var gitHubPullRequestSummary: GitHubPullRequestSummary { _toFragment() }
          }

          /// Repository.PullRequest.AssignedActors
          nonisolated struct AssignedActors: GitHubAPI.SelectionSet {
            let __data: DataDict
            init(_dataDict: DataDict) { __data = _dataDict }

            static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.AssigneeConnection }
            static var __selections: [ApolloAPI.Selection] { [
              .field("__typename", String.self),
              .field("totalCount", Int.self),
              .field("pageInfo", PageInfo.self),
              .field("nodes", [Node?]?.self),
            ] }
            static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
              GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.AssignedActors.self
            ] }

            var totalCount: Int { __data["totalCount"] }
            var pageInfo: PageInfo { __data["pageInfo"] }
            var nodes: [Node?]? { __data["nodes"] }

            /// Repository.PullRequest.AssignedActors.PageInfo
            nonisolated struct PageInfo: GitHubAPI.SelectionSet {
              let __data: DataDict
              init(_dataDict: DataDict) { __data = _dataDict }

              static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.PageInfo }
              static var __selections: [ApolloAPI.Selection] { [
                .field("__typename", String.self),
                .fragment(GitHubPageInfo.self),
              ] }
              static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.AssignedActors.PageInfo.self,
                GitHubPageInfo.self
              ] }

              var hasPreviousPage: Bool { __data["hasPreviousPage"] }
              var startCursor: String? { __data["startCursor"] }
              var hasNextPage: Bool { __data["hasNextPage"] }
              var endCursor: String? { __data["endCursor"] }

              struct Fragments: FragmentContainer {
                let __data: DataDict
                init(_dataDict: DataDict) { __data = _dataDict }

                var gitHubPageInfo: GitHubPageInfo { _toFragment() }
              }
            }

            /// Repository.PullRequest.AssignedActors.Node
            nonisolated struct Node: GitHubAPI.SelectionSet {
              let __data: DataDict
              init(_dataDict: DataDict) { __data = _dataDict }

              static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Unions.Assignee }
              static var __selections: [ApolloAPI.Selection] { [
                .field("__typename", String.self),
                .fragment(GitHubAssignee.self),
              ] }
              static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.AssignedActors.Node.self
              ] }

              var asActor: AsActor? { _asInlineFragment() }
              var asMannequin: AsMannequin? { _asInlineFragment() }

              struct Fragments: FragmentContainer {
                let __data: DataDict
                init(_dataDict: DataDict) { __data = _dataDict }

                var gitHubAssignee: GitHubAssignee { _toFragment() }
              }

              /// Repository.PullRequest.AssignedActors.Node.AsActor
              nonisolated struct AsActor: GitHubAPI.InlineFragment, ApolloAPI.CompositeInlineFragment {
                let __data: DataDict
                init(_dataDict: DataDict) { __data = _dataDict }

                typealias RootEntityType = GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.AssignedActors.Node
                static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Interfaces.Actor }
                static var __mergedSources: [any ApolloAPI.SelectionSet.Type] { [
                  GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.AssignedActors.Node.self,
                  GitHubAssignee.AsActor.self,
                  GitHubActor.self
                ] }
                static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                  GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.AssignedActors.Node.self,
                  GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.AssignedActors.Node.AsActor.self,
                  GitHubAssignee.self,
                  GitHubAssignee.AsActor.self,
                  GitHubActor.self
                ] }

                var login: String { __data["login"] }
                var avatarUrl: GitHubAPI.URI { __data["avatarUrl"] }

                struct Fragments: FragmentContainer {
                  let __data: DataDict
                  init(_dataDict: DataDict) { __data = _dataDict }

                  var gitHubAssignee: GitHubAssignee { _toFragment() }
                  var gitHubActor: GitHubActor { _toFragment() }
                }
              }

              /// Repository.PullRequest.AssignedActors.Node.AsMannequin
              nonisolated struct AsMannequin: GitHubAPI.InlineFragment, ApolloAPI.CompositeInlineFragment {
                let __data: DataDict
                init(_dataDict: DataDict) { __data = _dataDict }

                typealias RootEntityType = GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.AssignedActors.Node
                static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.Mannequin }
                static var __mergedSources: [any ApolloAPI.SelectionSet.Type] { [
                  GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.AssignedActors.Node.self,
                  GitHubAssignee.AsActor.self,
                  GitHubActor.self,
                  GitHubActor.AsNode.self,
                  GitHubAssignee.AsMannequin.self
                ] }
                static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                  GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.AssignedActors.Node.self,
                  GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.AssignedActors.Node.AsMannequin.self,
                  GitHubAssignee.self,
                  GitHubAssignee.AsActor.self,
                  GitHubActor.self,
                  GitHubActor.AsNode.self,
                  GitHubAssignee.AsMannequin.self
                ] }

                var login: String { __data["login"] }
                var avatarUrl: GitHubAPI.URI { __data["avatarUrl"] }
                var id: GitHubAPI.ID { __data["id"] }
                var mannequinID: GitHubAPI.ID { __data["mannequinID"] }
                var mannequinLogin: String { __data["mannequinLogin"] }
                var mannequinAvatarURL: GitHubAPI.URI { __data["mannequinAvatarURL"] }

                struct Fragments: FragmentContainer {
                  let __data: DataDict
                  init(_dataDict: DataDict) { __data = _dataDict }

                  var gitHubAssignee: GitHubAssignee { _toFragment() }
                  var gitHubActor: GitHubActor { _toFragment() }
                }
              }
            }
          }

          /// Repository.PullRequest.Milestone
          nonisolated struct Milestone: GitHubAPI.SelectionSet {
            let __data: DataDict
            init(_dataDict: DataDict) { __data = _dataDict }

            static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.Milestone }
            static var __selections: [ApolloAPI.Selection] { [
              .field("__typename", String.self),
              .fragment(GitHubMilestone.self),
            ] }
            static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
              GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.Milestone.self,
              GitHubMilestone.self
            ] }

            var id: GitHubAPI.ID { __data["id"] }
            var number: Int { __data["number"] }
            var title: String { __data["title"] }
            var description: String? { __data["description"] }
            var state: GraphQLEnum<GitHubAPI.MilestoneState> { __data["state"] }
            var dueOn: GitHubAPI.DateTime? { __data["dueOn"] }

            struct Fragments: FragmentContainer {
              let __data: DataDict
              init(_dataDict: DataDict) { __data = _dataDict }

              var gitHubMilestone: GitHubMilestone { _toFragment() }
            }
          }

          /// Repository.PullRequest.Participants
          nonisolated struct Participants: GitHubAPI.SelectionSet {
            let __data: DataDict
            init(_dataDict: DataDict) { __data = _dataDict }

            static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.UserConnection }
            static var __selections: [ApolloAPI.Selection] { [
              .field("__typename", String.self),
              .field("totalCount", Int.self),
              .field("pageInfo", PageInfo.self),
              .field("nodes", [Node?]?.self),
            ] }
            static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
              GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.Participants.self
            ] }

            var totalCount: Int { __data["totalCount"] }
            var pageInfo: PageInfo { __data["pageInfo"] }
            var nodes: [Node?]? { __data["nodes"] }

            /// Repository.PullRequest.Participants.PageInfo
            nonisolated struct PageInfo: GitHubAPI.SelectionSet {
              let __data: DataDict
              init(_dataDict: DataDict) { __data = _dataDict }

              static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.PageInfo }
              static var __selections: [ApolloAPI.Selection] { [
                .field("__typename", String.self),
                .fragment(GitHubPageInfo.self),
              ] }
              static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.Participants.PageInfo.self,
                GitHubPageInfo.self
              ] }

              var hasPreviousPage: Bool { __data["hasPreviousPage"] }
              var startCursor: String? { __data["startCursor"] }
              var hasNextPage: Bool { __data["hasNextPage"] }
              var endCursor: String? { __data["endCursor"] }

              struct Fragments: FragmentContainer {
                let __data: DataDict
                init(_dataDict: DataDict) { __data = _dataDict }

                var gitHubPageInfo: GitHubPageInfo { _toFragment() }
              }
            }

            /// Repository.PullRequest.Participants.Node
            nonisolated struct Node: GitHubAPI.SelectionSet {
              let __data: DataDict
              init(_dataDict: DataDict) { __data = _dataDict }

              static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.User }
              static var __selections: [ApolloAPI.Selection] { [
                .field("__typename", String.self),
                .fragment(GitHubActor.self),
              ] }
              static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.Participants.Node.self,
                GitHubActor.self,
                GitHubActor.AsNode.self,
                GitHubActor.AsUser.self
              ] }

              var login: String { __data["login"] }
              var avatarUrl: GitHubAPI.URI { __data["avatarUrl"] }
              var id: GitHubAPI.ID { __data["id"] }
              var name: String? { __data["name"] }

              var asOrganization: AsOrganization? { _asInlineFragment() }

              struct Fragments: FragmentContainer {
                let __data: DataDict
                init(_dataDict: DataDict) { __data = _dataDict }

                var gitHubActor: GitHubActor { _toFragment() }
              }

              /// Repository.PullRequest.Participants.Node.AsOrganization
              nonisolated struct AsOrganization: GitHubAPI.InlineFragment, ApolloAPI.CompositeInlineFragment {
                let __data: DataDict
                init(_dataDict: DataDict) { __data = _dataDict }

                typealias RootEntityType = GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.Participants.Node
                static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.Organization }
                static var __mergedSources: [any ApolloAPI.SelectionSet.Type] { [
                  GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.Participants.Node.self,
                  GitHubActor.self,
                  GitHubActor.AsNode.self,
                  GitHubActor.AsUser.self,
                  GitHubActor.AsOrganization.self
                ] }
                static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                  GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.Participants.Node.self,
                  GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.Participants.Node.AsOrganization.self,
                  GitHubActor.self,
                  GitHubActor.AsNode.self,
                  GitHubActor.AsUser.self,
                  GitHubActor.AsOrganization.self
                ] }

                var login: String { __data["login"] }
                var avatarUrl: GitHubAPI.URI { __data["avatarUrl"] }
                var id: GitHubAPI.ID { __data["id"] }
                var name: String? { __data["name"] }

                struct Fragments: FragmentContainer {
                  let __data: DataDict
                  init(_dataDict: DataDict) { __data = _dataDict }

                  var gitHubActor: GitHubActor { _toFragment() }
                }
              }
            }
          }

          /// Repository.PullRequest.ReviewRequests
          nonisolated struct ReviewRequests: GitHubAPI.SelectionSet {
            let __data: DataDict
            init(_dataDict: DataDict) { __data = _dataDict }

            static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.ReviewRequestConnection }
            static var __selections: [ApolloAPI.Selection] { [
              .field("__typename", String.self),
              .field("totalCount", Int.self),
              .field("pageInfo", PageInfo.self),
              .field("nodes", [Node?]?.self),
            ] }
            static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
              GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.ReviewRequests.self
            ] }

            var totalCount: Int { __data["totalCount"] }
            var pageInfo: PageInfo { __data["pageInfo"] }
            var nodes: [Node?]? { __data["nodes"] }

            /// Repository.PullRequest.ReviewRequests.PageInfo
            nonisolated struct PageInfo: GitHubAPI.SelectionSet {
              let __data: DataDict
              init(_dataDict: DataDict) { __data = _dataDict }

              static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.PageInfo }
              static var __selections: [ApolloAPI.Selection] { [
                .field("__typename", String.self),
                .fragment(GitHubPageInfo.self),
              ] }
              static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.ReviewRequests.PageInfo.self,
                GitHubPageInfo.self
              ] }

              var hasPreviousPage: Bool { __data["hasPreviousPage"] }
              var startCursor: String? { __data["startCursor"] }
              var hasNextPage: Bool { __data["hasNextPage"] }
              var endCursor: String? { __data["endCursor"] }

              struct Fragments: FragmentContainer {
                let __data: DataDict
                init(_dataDict: DataDict) { __data = _dataDict }

                var gitHubPageInfo: GitHubPageInfo { _toFragment() }
              }
            }

            /// Repository.PullRequest.ReviewRequests.Node
            nonisolated struct Node: GitHubAPI.SelectionSet {
              let __data: DataDict
              init(_dataDict: DataDict) { __data = _dataDict }

              static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.ReviewRequest }
              static var __selections: [ApolloAPI.Selection] { [
                .field("__typename", String.self),
                .field("id", GitHubAPI.ID.self),
                .field("requestedReviewer", RequestedReviewer?.self),
              ] }
              static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.ReviewRequests.Node.self
              ] }

              var id: GitHubAPI.ID { __data["id"] }
              var requestedReviewer: RequestedReviewer? { __data["requestedReviewer"] }

              /// Repository.PullRequest.ReviewRequests.Node.RequestedReviewer
              nonisolated struct RequestedReviewer: GitHubAPI.SelectionSet {
                let __data: DataDict
                init(_dataDict: DataDict) { __data = _dataDict }

                static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Unions.RequestedReviewer }
                static var __selections: [ApolloAPI.Selection] { [
                  .field("__typename", String.self),
                  .fragment(GitHubRequestedReviewer.self),
                ] }
                static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                  GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.ReviewRequests.Node.RequestedReviewer.self
                ] }

                var asActor: AsActor? { _asInlineFragment() }
                var asMannequin: AsMannequin? { _asInlineFragment() }
                var asTeam: AsTeam? { _asInlineFragment() }

                struct Fragments: FragmentContainer {
                  let __data: DataDict
                  init(_dataDict: DataDict) { __data = _dataDict }

                  var gitHubRequestedReviewer: GitHubRequestedReviewer { _toFragment() }
                }

                /// Repository.PullRequest.ReviewRequests.Node.RequestedReviewer.AsActor
                nonisolated struct AsActor: GitHubAPI.InlineFragment, ApolloAPI.CompositeInlineFragment {
                  let __data: DataDict
                  init(_dataDict: DataDict) { __data = _dataDict }

                  typealias RootEntityType = GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.ReviewRequests.Node.RequestedReviewer
                  static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Interfaces.Actor }
                  static var __mergedSources: [any ApolloAPI.SelectionSet.Type] { [
                    GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.ReviewRequests.Node.RequestedReviewer.self,
                    GitHubRequestedReviewer.AsActor.self,
                    GitHubActor.self
                  ] }
                  static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                    GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.ReviewRequests.Node.RequestedReviewer.self,
                    GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.ReviewRequests.Node.RequestedReviewer.AsActor.self,
                    GitHubRequestedReviewer.self,
                    GitHubRequestedReviewer.AsActor.self,
                    GitHubActor.self
                  ] }

                  var login: String { __data["login"] }
                  var avatarUrl: GitHubAPI.URI { __data["avatarUrl"] }

                  struct Fragments: FragmentContainer {
                    let __data: DataDict
                    init(_dataDict: DataDict) { __data = _dataDict }

                    var gitHubRequestedReviewer: GitHubRequestedReviewer { _toFragment() }
                    var gitHubActor: GitHubActor { _toFragment() }
                  }
                }

                /// Repository.PullRequest.ReviewRequests.Node.RequestedReviewer.AsMannequin
                nonisolated struct AsMannequin: GitHubAPI.InlineFragment, ApolloAPI.CompositeInlineFragment {
                  let __data: DataDict
                  init(_dataDict: DataDict) { __data = _dataDict }

                  typealias RootEntityType = GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.ReviewRequests.Node.RequestedReviewer
                  static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.Mannequin }
                  static var __mergedSources: [any ApolloAPI.SelectionSet.Type] { [
                    GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.ReviewRequests.Node.RequestedReviewer.self,
                    GitHubRequestedReviewer.AsActor.self,
                    GitHubActor.self,
                    GitHubActor.AsNode.self,
                    GitHubRequestedReviewer.AsMannequin.self
                  ] }
                  static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                    GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.ReviewRequests.Node.RequestedReviewer.self,
                    GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.ReviewRequests.Node.RequestedReviewer.AsMannequin.self,
                    GitHubRequestedReviewer.self,
                    GitHubRequestedReviewer.AsActor.self,
                    GitHubActor.self,
                    GitHubActor.AsNode.self,
                    GitHubRequestedReviewer.AsMannequin.self
                  ] }

                  var login: String { __data["login"] }
                  var avatarUrl: GitHubAPI.URI { __data["avatarUrl"] }
                  var id: GitHubAPI.ID { __data["id"] }
                  var mannequinID: GitHubAPI.ID { __data["mannequinID"] }
                  var mannequinLogin: String { __data["mannequinLogin"] }
                  var mannequinAvatarURL: GitHubAPI.URI { __data["mannequinAvatarURL"] }

                  struct Fragments: FragmentContainer {
                    let __data: DataDict
                    init(_dataDict: DataDict) { __data = _dataDict }

                    var gitHubRequestedReviewer: GitHubRequestedReviewer { _toFragment() }
                    var gitHubActor: GitHubActor { _toFragment() }
                  }
                }

                /// Repository.PullRequest.ReviewRequests.Node.RequestedReviewer.AsTeam
                nonisolated struct AsTeam: GitHubAPI.InlineFragment, ApolloAPI.CompositeInlineFragment {
                  let __data: DataDict
                  init(_dataDict: DataDict) { __data = _dataDict }

                  typealias RootEntityType = GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.ReviewRequests.Node.RequestedReviewer
                  static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.Team }
                  static var __mergedSources: [any ApolloAPI.SelectionSet.Type] { [
                    GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.ReviewRequests.Node.RequestedReviewer.self,
                    GitHubRequestedReviewer.AsTeam.self
                  ] }
                  static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                    GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.ReviewRequests.Node.RequestedReviewer.self,
                    GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.ReviewRequests.Node.RequestedReviewer.AsTeam.self,
                    GitHubRequestedReviewer.self,
                    GitHubRequestedReviewer.AsTeam.self
                  ] }

                  var teamID: GitHubAPI.ID { __data["teamID"] }
                  var teamName: String { __data["teamName"] }
                  var teamSlug: String { __data["teamSlug"] }
                  var teamAvatarURL: GitHubAPI.URI? { __data["teamAvatarURL"] }

                  struct Fragments: FragmentContainer {
                    let __data: DataDict
                    init(_dataDict: DataDict) { __data = _dataDict }

                    var gitHubRequestedReviewer: GitHubRequestedReviewer { _toFragment() }
                  }
                }
              }
            }
          }

          /// Repository.PullRequest.LatestReviews
          nonisolated struct LatestReviews: GitHubAPI.SelectionSet {
            let __data: DataDict
            init(_dataDict: DataDict) { __data = _dataDict }

            static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.PullRequestReviewConnection }
            static var __selections: [ApolloAPI.Selection] { [
              .field("__typename", String.self),
              .field("totalCount", Int.self),
              .field("pageInfo", PageInfo.self),
              .field("nodes", [Node?]?.self),
            ] }
            static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
              GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.LatestReviews.self
            ] }

            var totalCount: Int { __data["totalCount"] }
            var pageInfo: PageInfo { __data["pageInfo"] }
            var nodes: [Node?]? { __data["nodes"] }

            /// Repository.PullRequest.LatestReviews.PageInfo
            nonisolated struct PageInfo: GitHubAPI.SelectionSet {
              let __data: DataDict
              init(_dataDict: DataDict) { __data = _dataDict }

              static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.PageInfo }
              static var __selections: [ApolloAPI.Selection] { [
                .field("__typename", String.self),
                .fragment(GitHubPageInfo.self),
              ] }
              static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.LatestReviews.PageInfo.self,
                GitHubPageInfo.self
              ] }

              var hasPreviousPage: Bool { __data["hasPreviousPage"] }
              var startCursor: String? { __data["startCursor"] }
              var hasNextPage: Bool { __data["hasNextPage"] }
              var endCursor: String? { __data["endCursor"] }

              struct Fragments: FragmentContainer {
                let __data: DataDict
                init(_dataDict: DataDict) { __data = _dataDict }

                var gitHubPageInfo: GitHubPageInfo { _toFragment() }
              }
            }

            /// Repository.PullRequest.LatestReviews.Node
            nonisolated struct Node: GitHubAPI.SelectionSet {
              let __data: DataDict
              init(_dataDict: DataDict) { __data = _dataDict }

              static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.PullRequestReview }
              static var __selections: [ApolloAPI.Selection] { [
                .field("__typename", String.self),
                .field("id", GitHubAPI.ID.self),
                .field("state", GraphQLEnum<GitHubAPI.PullRequestReviewState>.self),
                .field("submittedAt", GitHubAPI.DateTime?.self),
                .field("author", Author?.self),
              ] }
              static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.LatestReviews.Node.self
              ] }

              var id: GitHubAPI.ID { __data["id"] }
              var state: GraphQLEnum<GitHubAPI.PullRequestReviewState> { __data["state"] }
              var submittedAt: GitHubAPI.DateTime? { __data["submittedAt"] }
              var author: Author? { __data["author"] }

              /// Repository.PullRequest.LatestReviews.Node.Author
              nonisolated struct Author: GitHubAPI.SelectionSet {
                let __data: DataDict
                init(_dataDict: DataDict) { __data = _dataDict }

                static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Interfaces.Actor }
                static var __selections: [ApolloAPI.Selection] { [
                  .field("__typename", String.self),
                  .fragment(GitHubActor.self),
                ] }
                static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                  GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.LatestReviews.Node.Author.self,
                  GitHubActor.self
                ] }

                var login: String { __data["login"] }
                var avatarUrl: GitHubAPI.URI { __data["avatarUrl"] }

                var asNode: AsNode? { _asInlineFragment() }
                var asUser: AsUser? { _asInlineFragment() }
                var asOrganization: AsOrganization? { _asInlineFragment() }

                struct Fragments: FragmentContainer {
                  let __data: DataDict
                  init(_dataDict: DataDict) { __data = _dataDict }

                  var gitHubActor: GitHubActor { _toFragment() }
                }

                /// Repository.PullRequest.LatestReviews.Node.Author.AsNode
                nonisolated struct AsNode: GitHubAPI.InlineFragment, ApolloAPI.CompositeInlineFragment {
                  let __data: DataDict
                  init(_dataDict: DataDict) { __data = _dataDict }

                  typealias RootEntityType = GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.LatestReviews.Node.Author
                  static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Interfaces.Node }
                  static var __mergedSources: [any ApolloAPI.SelectionSet.Type] { [
                    GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.LatestReviews.Node.Author.self,
                    GitHubActor.self,
                    GitHubActor.AsNode.self
                  ] }
                  static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                    GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.LatestReviews.Node.Author.self,
                    GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.LatestReviews.Node.Author.AsNode.self,
                    GitHubActor.self,
                    GitHubActor.AsNode.self
                  ] }

                  var login: String { __data["login"] }
                  var avatarUrl: GitHubAPI.URI { __data["avatarUrl"] }
                  var id: GitHubAPI.ID { __data["id"] }

                  struct Fragments: FragmentContainer {
                    let __data: DataDict
                    init(_dataDict: DataDict) { __data = _dataDict }

                    var gitHubActor: GitHubActor { _toFragment() }
                  }
                }

                /// Repository.PullRequest.LatestReviews.Node.Author.AsUser
                nonisolated struct AsUser: GitHubAPI.InlineFragment, ApolloAPI.CompositeInlineFragment {
                  let __data: DataDict
                  init(_dataDict: DataDict) { __data = _dataDict }

                  typealias RootEntityType = GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.LatestReviews.Node.Author
                  static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.User }
                  static var __mergedSources: [any ApolloAPI.SelectionSet.Type] { [
                    GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.LatestReviews.Node.Author.self,
                    GitHubActor.self,
                    GitHubActor.AsNode.self,
                    GitHubActor.AsUser.self
                  ] }
                  static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                    GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.LatestReviews.Node.Author.self,
                    GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.LatestReviews.Node.Author.AsUser.self,
                    GitHubActor.self,
                    GitHubActor.AsNode.self,
                    GitHubActor.AsUser.self
                  ] }

                  var login: String { __data["login"] }
                  var avatarUrl: GitHubAPI.URI { __data["avatarUrl"] }
                  var id: GitHubAPI.ID { __data["id"] }
                  var name: String? { __data["name"] }

                  struct Fragments: FragmentContainer {
                    let __data: DataDict
                    init(_dataDict: DataDict) { __data = _dataDict }

                    var gitHubActor: GitHubActor { _toFragment() }
                  }
                }

                /// Repository.PullRequest.LatestReviews.Node.Author.AsOrganization
                nonisolated struct AsOrganization: GitHubAPI.InlineFragment, ApolloAPI.CompositeInlineFragment {
                  let __data: DataDict
                  init(_dataDict: DataDict) { __data = _dataDict }

                  typealias RootEntityType = GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.LatestReviews.Node.Author
                  static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.Organization }
                  static var __mergedSources: [any ApolloAPI.SelectionSet.Type] { [
                    GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.LatestReviews.Node.Author.self,
                    GitHubActor.self,
                    GitHubActor.AsNode.self,
                    GitHubActor.AsOrganization.self
                  ] }
                  static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                    GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.LatestReviews.Node.Author.self,
                    GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.LatestReviews.Node.Author.AsOrganization.self,
                    GitHubActor.self,
                    GitHubActor.AsNode.self,
                    GitHubActor.AsOrganization.self
                  ] }

                  var login: String { __data["login"] }
                  var avatarUrl: GitHubAPI.URI { __data["avatarUrl"] }
                  var id: GitHubAPI.ID { __data["id"] }
                  var name: String? { __data["name"] }

                  struct Fragments: FragmentContainer {
                    let __data: DataDict
                    init(_dataDict: DataDict) { __data = _dataDict }

                    var gitHubActor: GitHubActor { _toFragment() }
                  }
                }
              }
            }
          }

          /// Repository.PullRequest.ClosingIssuesReferences
          nonisolated struct ClosingIssuesReferences: GitHubAPI.SelectionSet {
            let __data: DataDict
            init(_dataDict: DataDict) { __data = _dataDict }

            static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.IssueConnection }
            static var __selections: [ApolloAPI.Selection] { [
              .field("__typename", String.self),
              .field("totalCount", Int.self),
              .field("pageInfo", PageInfo.self),
              .field("nodes", [Node?]?.self),
            ] }
            static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
              GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.ClosingIssuesReferences.self
            ] }

            var totalCount: Int { __data["totalCount"] }
            var pageInfo: PageInfo { __data["pageInfo"] }
            var nodes: [Node?]? { __data["nodes"] }

            /// Repository.PullRequest.ClosingIssuesReferences.PageInfo
            nonisolated struct PageInfo: GitHubAPI.SelectionSet {
              let __data: DataDict
              init(_dataDict: DataDict) { __data = _dataDict }

              static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.PageInfo }
              static var __selections: [ApolloAPI.Selection] { [
                .field("__typename", String.self),
                .fragment(GitHubPageInfo.self),
              ] }
              static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.ClosingIssuesReferences.PageInfo.self,
                GitHubPageInfo.self
              ] }

              var hasPreviousPage: Bool { __data["hasPreviousPage"] }
              var startCursor: String? { __data["startCursor"] }
              var hasNextPage: Bool { __data["hasNextPage"] }
              var endCursor: String? { __data["endCursor"] }

              struct Fragments: FragmentContainer {
                let __data: DataDict
                init(_dataDict: DataDict) { __data = _dataDict }

                var gitHubPageInfo: GitHubPageInfo { _toFragment() }
              }
            }

            /// Repository.PullRequest.ClosingIssuesReferences.Node
            nonisolated struct Node: GitHubAPI.SelectionSet {
              let __data: DataDict
              init(_dataDict: DataDict) { __data = _dataDict }

              static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.Issue }
              static var __selections: [ApolloAPI.Selection] { [
                .field("__typename", String.self),
                .field("id", GitHubAPI.ID.self),
                .field("number", Int.self),
                .field("state", GraphQLEnum<GitHubAPI.IssueState>.self),
                .field("title", String.self),
                .field("repository", Repository.self),
              ] }
              static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.ClosingIssuesReferences.Node.self
              ] }

              var id: GitHubAPI.ID { __data["id"] }
              var number: Int { __data["number"] }
              var state: GraphQLEnum<GitHubAPI.IssueState> { __data["state"] }
              var title: String { __data["title"] }
              var repository: Repository { __data["repository"] }

              /// Repository.PullRequest.ClosingIssuesReferences.Node.Repository
              nonisolated struct Repository: GitHubAPI.SelectionSet {
                let __data: DataDict
                init(_dataDict: DataDict) { __data = _dataDict }

                static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.Repository }
                static var __selections: [ApolloAPI.Selection] { [
                  .field("__typename", String.self),
                  .fragment(GitHubRepositoryIdentity.self),
                ] }
                static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                  GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.ClosingIssuesReferences.Node.Repository.self,
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
            }
          }

          /// Repository.PullRequest.StatusCheckRollup
          nonisolated struct StatusCheckRollup: GitHubAPI.SelectionSet {
            let __data: DataDict
            init(_dataDict: DataDict) { __data = _dataDict }

            static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.StatusCheckRollup }
            static var __selections: [ApolloAPI.Selection] { [
              .field("__typename", String.self),
              .field("state", GraphQLEnum<GitHubAPI.StatusState>.self),
              .field("contexts", Contexts.self, arguments: [
                "first": .variable("checkFirst"),
                "after": .variable("checkAfter")
              ]),
            ] }
            static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
              GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.StatusCheckRollup.self
            ] }

            var state: GraphQLEnum<GitHubAPI.StatusState> { __data["state"] }
            var contexts: Contexts { __data["contexts"] }

            /// Repository.PullRequest.StatusCheckRollup.Contexts
            nonisolated struct Contexts: GitHubAPI.SelectionSet {
              let __data: DataDict
              init(_dataDict: DataDict) { __data = _dataDict }

              static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.StatusCheckRollupContextConnection }
              static var __selections: [ApolloAPI.Selection] { [
                .field("__typename", String.self),
                .field("totalCount", Int.self),
                .field("pageInfo", PageInfo.self),
                .field("nodes", [Node?]?.self),
              ] }
              static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.StatusCheckRollup.Contexts.self
              ] }

              var totalCount: Int { __data["totalCount"] }
              var pageInfo: PageInfo { __data["pageInfo"] }
              var nodes: [Node?]? { __data["nodes"] }

              /// Repository.PullRequest.StatusCheckRollup.Contexts.PageInfo
              nonisolated struct PageInfo: GitHubAPI.SelectionSet {
                let __data: DataDict
                init(_dataDict: DataDict) { __data = _dataDict }

                static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.PageInfo }
                static var __selections: [ApolloAPI.Selection] { [
                  .field("__typename", String.self),
                  .fragment(GitHubPageInfo.self),
                ] }
                static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                  GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.StatusCheckRollup.Contexts.PageInfo.self,
                  GitHubPageInfo.self
                ] }

                var hasPreviousPage: Bool { __data["hasPreviousPage"] }
                var startCursor: String? { __data["startCursor"] }
                var hasNextPage: Bool { __data["hasNextPage"] }
                var endCursor: String? { __data["endCursor"] }

                struct Fragments: FragmentContainer {
                  let __data: DataDict
                  init(_dataDict: DataDict) { __data = _dataDict }

                  var gitHubPageInfo: GitHubPageInfo { _toFragment() }
                }
              }

              /// Repository.PullRequest.StatusCheckRollup.Contexts.Node
              nonisolated struct Node: GitHubAPI.SelectionSet {
                let __data: DataDict
                init(_dataDict: DataDict) { __data = _dataDict }

                static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Unions.StatusCheckRollupContext }
                static var __selections: [ApolloAPI.Selection] { [
                  .field("__typename", String.self),
                  .inlineFragment(AsCheckRun.self),
                  .inlineFragment(AsStatusContext.self),
                ] }
                static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                  GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.StatusCheckRollup.Contexts.Node.self
                ] }

                var asCheckRun: AsCheckRun? { _asInlineFragment() }
                var asStatusContext: AsStatusContext? { _asInlineFragment() }

                /// Repository.PullRequest.StatusCheckRollup.Contexts.Node.AsCheckRun
                nonisolated struct AsCheckRun: GitHubAPI.InlineFragment {
                  let __data: DataDict
                  init(_dataDict: DataDict) { __data = _dataDict }

                  typealias RootEntityType = GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.StatusCheckRollup.Contexts.Node
                  static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.CheckRun }
                  static var __selections: [ApolloAPI.Selection] { [
                    .field("id", GitHubAPI.ID.self),
                    .field("name", String.self),
                    .field("summary", String?.self),
                    .field("status", GraphQLEnum<GitHubAPI.CheckStatusState>.self),
                    .field("conclusion", GraphQLEnum<GitHubAPI.CheckConclusionState>?.self),
                    .field("detailsUrl", GitHubAPI.URI?.self),
                    .field("startedAt", GitHubAPI.DateTime?.self),
                    .field("completedAt", GitHubAPI.DateTime?.self),
                  ] }
                  static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                    GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.StatusCheckRollup.Contexts.Node.self,
                    GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.StatusCheckRollup.Contexts.Node.AsCheckRun.self
                  ] }

                  var id: GitHubAPI.ID { __data["id"] }
                  var name: String { __data["name"] }
                  var summary: String? { __data["summary"] }
                  var status: GraphQLEnum<GitHubAPI.CheckStatusState> { __data["status"] }
                  var conclusion: GraphQLEnum<GitHubAPI.CheckConclusionState>? { __data["conclusion"] }
                  var detailsUrl: GitHubAPI.URI? { __data["detailsUrl"] }
                  var startedAt: GitHubAPI.DateTime? { __data["startedAt"] }
                  var completedAt: GitHubAPI.DateTime? { __data["completedAt"] }
                }

                /// Repository.PullRequest.StatusCheckRollup.Contexts.Node.AsStatusContext
                nonisolated struct AsStatusContext: GitHubAPI.InlineFragment {
                  let __data: DataDict
                  init(_dataDict: DataDict) { __data = _dataDict }

                  typealias RootEntityType = GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.StatusCheckRollup.Contexts.Node
                  static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.StatusContext }
                  static var __selections: [ApolloAPI.Selection] { [
                    .field("id", GitHubAPI.ID.self),
                    .field("context", String.self),
                    .field("description", String?.self),
                    .field("state", GraphQLEnum<GitHubAPI.StatusState>.self),
                    .field("targetUrl", GitHubAPI.URI?.self),
                    .field("createdAt", GitHubAPI.DateTime.self),
                    .field("updatedAt", GitHubAPI.DateTime.self),
                  ] }
                  static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                    GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.StatusCheckRollup.Contexts.Node.self,
                    GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.StatusCheckRollup.Contexts.Node.AsStatusContext.self
                  ] }

                  var id: GitHubAPI.ID { __data["id"] }
                  var context: String { __data["context"] }
                  var description: String? { __data["description"] }
                  var state: GraphQLEnum<GitHubAPI.StatusState> { __data["state"] }
                  var targetUrl: GitHubAPI.URI? { __data["targetUrl"] }
                  var createdAt: GitHubAPI.DateTime { __data["createdAt"] }
                  var updatedAt: GitHubAPI.DateTime { __data["updatedAt"] }
                }
              }
            }
          }

          /// Repository.PullRequest.TimelineItems
          nonisolated struct TimelineItems: GitHubAPI.SelectionSet {
            let __data: DataDict
            init(_dataDict: DataDict) { __data = _dataDict }

            static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.PullRequestTimelineItemsConnection }
            static var __selections: [ApolloAPI.Selection] { [
              .field("__typename", String.self),
              .field("totalCount", Int.self),
              .field("pageInfo", PageInfo.self),
              .field("nodes", [Node?]?.self),
            ] }
            static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
              GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.self
            ] }

            var totalCount: Int { __data["totalCount"] }
            var pageInfo: PageInfo { __data["pageInfo"] }
            var nodes: [Node?]? { __data["nodes"] }

            /// Repository.PullRequest.TimelineItems.PageInfo
            nonisolated struct PageInfo: GitHubAPI.SelectionSet {
              let __data: DataDict
              init(_dataDict: DataDict) { __data = _dataDict }

              static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.PageInfo }
              static var __selections: [ApolloAPI.Selection] { [
                .field("__typename", String.self),
                .fragment(GitHubPageInfo.self),
              ] }
              static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.PageInfo.self,
                GitHubPageInfo.self
              ] }

              var hasPreviousPage: Bool { __data["hasPreviousPage"] }
              var startCursor: String? { __data["startCursor"] }
              var hasNextPage: Bool { __data["hasNextPage"] }
              var endCursor: String? { __data["endCursor"] }

              struct Fragments: FragmentContainer {
                let __data: DataDict
                init(_dataDict: DataDict) { __data = _dataDict }

                var gitHubPageInfo: GitHubPageInfo { _toFragment() }
              }
            }

            /// Repository.PullRequest.TimelineItems.Node
            nonisolated struct Node: GitHubAPI.SelectionSet {
              let __data: DataDict
              init(_dataDict: DataDict) { __data = _dataDict }

              static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Unions.PullRequestTimelineItems }
              static var __selections: [ApolloAPI.Selection] { [
                .field("__typename", String.self),
                .inlineFragment(AsIssueComment.self),
                .inlineFragment(AsPullRequestReview.self),
                .inlineFragment(AsClosedEvent.self),
                .inlineFragment(AsReopenedEvent.self),
                .inlineFragment(AsMergedEvent.self),
                .inlineFragment(AsAssignedEvent.self),
                .inlineFragment(AsUnassignedEvent.self),
                .inlineFragment(AsLabeledEvent.self),
                .inlineFragment(AsUnlabeledEvent.self),
                .inlineFragment(AsMilestonedEvent.self),
                .inlineFragment(AsDemilestonedEvent.self),
                .inlineFragment(AsRenamedTitleEvent.self),
                .inlineFragment(AsCrossReferencedEvent.self),
              ] }
              static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node.self
              ] }

              var asIssueComment: AsIssueComment? { _asInlineFragment() }
              var asPullRequestReview: AsPullRequestReview? { _asInlineFragment() }
              var asClosedEvent: AsClosedEvent? { _asInlineFragment() }
              var asReopenedEvent: AsReopenedEvent? { _asInlineFragment() }
              var asMergedEvent: AsMergedEvent? { _asInlineFragment() }
              var asAssignedEvent: AsAssignedEvent? { _asInlineFragment() }
              var asUnassignedEvent: AsUnassignedEvent? { _asInlineFragment() }
              var asLabeledEvent: AsLabeledEvent? { _asInlineFragment() }
              var asUnlabeledEvent: AsUnlabeledEvent? { _asInlineFragment() }
              var asMilestonedEvent: AsMilestonedEvent? { _asInlineFragment() }
              var asDemilestonedEvent: AsDemilestonedEvent? { _asInlineFragment() }
              var asRenamedTitleEvent: AsRenamedTitleEvent? { _asInlineFragment() }
              var asCrossReferencedEvent: AsCrossReferencedEvent? { _asInlineFragment() }

              /// Repository.PullRequest.TimelineItems.Node.AsIssueComment
              nonisolated struct AsIssueComment: GitHubAPI.InlineFragment {
                let __data: DataDict
                init(_dataDict: DataDict) { __data = _dataDict }

                typealias RootEntityType = GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node
                static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.IssueComment }
                static var __selections: [ApolloAPI.Selection] { [
                  .fragment(GitHubIssueComment.self),
                ] }
                static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                  GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node.self,
                  GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node.AsIssueComment.self,
                  GitHubIssueComment.self
                ] }

                var id: GitHubAPI.ID { __data["id"] }
                var body: String { __data["body"] }
                var createdAt: GitHubAPI.DateTime { __data["createdAt"] }
                var updatedAt: GitHubAPI.DateTime { __data["updatedAt"] }
                var author: Author? { __data["author"] }

                struct Fragments: FragmentContainer {
                  let __data: DataDict
                  init(_dataDict: DataDict) { __data = _dataDict }

                  var gitHubIssueComment: GitHubIssueComment { _toFragment() }
                }

                typealias Author = GitHubIssueComment.Author
              }

              /// Repository.PullRequest.TimelineItems.Node.AsPullRequestReview
              nonisolated struct AsPullRequestReview: GitHubAPI.InlineFragment {
                let __data: DataDict
                init(_dataDict: DataDict) { __data = _dataDict }

                typealias RootEntityType = GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node
                static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.PullRequestReview }
                static var __selections: [ApolloAPI.Selection] { [
                  .field("id", GitHubAPI.ID.self),
                  .field("body", String.self),
                  .field("state", GraphQLEnum<GitHubAPI.PullRequestReviewState>.self),
                  .field("createdAt", GitHubAPI.DateTime.self),
                  .field("submittedAt", GitHubAPI.DateTime?.self),
                  .field("author", Author?.self),
                  .field("commit", Commit?.self),
                ] }
                static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                  GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node.self,
                  GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node.AsPullRequestReview.self
                ] }

                var id: GitHubAPI.ID { __data["id"] }
                var body: String { __data["body"] }
                var state: GraphQLEnum<GitHubAPI.PullRequestReviewState> { __data["state"] }
                var createdAt: GitHubAPI.DateTime { __data["createdAt"] }
                var submittedAt: GitHubAPI.DateTime? { __data["submittedAt"] }
                var author: Author? { __data["author"] }
                var commit: Commit? { __data["commit"] }

                /// Repository.PullRequest.TimelineItems.Node.AsPullRequestReview.Author
                nonisolated struct Author: GitHubAPI.SelectionSet {
                  let __data: DataDict
                  init(_dataDict: DataDict) { __data = _dataDict }

                  static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Interfaces.Actor }
                  static var __selections: [ApolloAPI.Selection] { [
                    .field("__typename", String.self),
                    .fragment(GitHubActor.self),
                  ] }
                  static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                    GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node.AsPullRequestReview.Author.self,
                    GitHubActor.self
                  ] }

                  var login: String { __data["login"] }
                  var avatarUrl: GitHubAPI.URI { __data["avatarUrl"] }

                  var asNode: AsNode? { _asInlineFragment() }
                  var asUser: AsUser? { _asInlineFragment() }
                  var asOrganization: AsOrganization? { _asInlineFragment() }

                  struct Fragments: FragmentContainer {
                    let __data: DataDict
                    init(_dataDict: DataDict) { __data = _dataDict }

                    var gitHubActor: GitHubActor { _toFragment() }
                  }

                  /// Repository.PullRequest.TimelineItems.Node.AsPullRequestReview.Author.AsNode
                  nonisolated struct AsNode: GitHubAPI.InlineFragment, ApolloAPI.CompositeInlineFragment {
                    let __data: DataDict
                    init(_dataDict: DataDict) { __data = _dataDict }

                    typealias RootEntityType = GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node.AsPullRequestReview.Author
                    static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Interfaces.Node }
                    static var __mergedSources: [any ApolloAPI.SelectionSet.Type] { [
                      GitHubActor.self,
                      GitHubActor.AsNode.self,
                      GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node.AsPullRequestReview.Author.self
                    ] }
                    static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                      GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node.AsPullRequestReview.Author.self,
                      GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node.AsPullRequestReview.Author.AsNode.self,
                      GitHubActor.self,
                      GitHubActor.AsNode.self
                    ] }

                    var login: String { __data["login"] }
                    var avatarUrl: GitHubAPI.URI { __data["avatarUrl"] }
                    var id: GitHubAPI.ID { __data["id"] }

                    struct Fragments: FragmentContainer {
                      let __data: DataDict
                      init(_dataDict: DataDict) { __data = _dataDict }

                      var gitHubActor: GitHubActor { _toFragment() }
                    }
                  }

                  /// Repository.PullRequest.TimelineItems.Node.AsPullRequestReview.Author.AsUser
                  nonisolated struct AsUser: GitHubAPI.InlineFragment, ApolloAPI.CompositeInlineFragment {
                    let __data: DataDict
                    init(_dataDict: DataDict) { __data = _dataDict }

                    typealias RootEntityType = GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node.AsPullRequestReview.Author
                    static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.User }
                    static var __mergedSources: [any ApolloAPI.SelectionSet.Type] { [
                      GitHubActor.self,
                      GitHubActor.AsNode.self,
                      GitHubActor.AsUser.self,
                      GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node.AsPullRequestReview.Author.self
                    ] }
                    static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                      GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node.AsPullRequestReview.Author.self,
                      GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node.AsPullRequestReview.Author.AsUser.self,
                      GitHubActor.self,
                      GitHubActor.AsNode.self,
                      GitHubActor.AsUser.self
                    ] }

                    var login: String { __data["login"] }
                    var avatarUrl: GitHubAPI.URI { __data["avatarUrl"] }
                    var id: GitHubAPI.ID { __data["id"] }
                    var name: String? { __data["name"] }

                    struct Fragments: FragmentContainer {
                      let __data: DataDict
                      init(_dataDict: DataDict) { __data = _dataDict }

                      var gitHubActor: GitHubActor { _toFragment() }
                    }
                  }

                  /// Repository.PullRequest.TimelineItems.Node.AsPullRequestReview.Author.AsOrganization
                  nonisolated struct AsOrganization: GitHubAPI.InlineFragment, ApolloAPI.CompositeInlineFragment {
                    let __data: DataDict
                    init(_dataDict: DataDict) { __data = _dataDict }

                    typealias RootEntityType = GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node.AsPullRequestReview.Author
                    static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.Organization }
                    static var __mergedSources: [any ApolloAPI.SelectionSet.Type] { [
                      GitHubActor.self,
                      GitHubActor.AsNode.self,
                      GitHubActor.AsOrganization.self,
                      GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node.AsPullRequestReview.Author.self
                    ] }
                    static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                      GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node.AsPullRequestReview.Author.self,
                      GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node.AsPullRequestReview.Author.AsOrganization.self,
                      GitHubActor.self,
                      GitHubActor.AsNode.self,
                      GitHubActor.AsOrganization.self
                    ] }

                    var login: String { __data["login"] }
                    var avatarUrl: GitHubAPI.URI { __data["avatarUrl"] }
                    var id: GitHubAPI.ID { __data["id"] }
                    var name: String? { __data["name"] }

                    struct Fragments: FragmentContainer {
                      let __data: DataDict
                      init(_dataDict: DataDict) { __data = _dataDict }

                      var gitHubActor: GitHubActor { _toFragment() }
                    }
                  }
                }

                /// Repository.PullRequest.TimelineItems.Node.AsPullRequestReview.Commit
                nonisolated struct Commit: GitHubAPI.SelectionSet {
                  let __data: DataDict
                  init(_dataDict: DataDict) { __data = _dataDict }

                  static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.Commit }
                  static var __selections: [ApolloAPI.Selection] { [
                    .field("__typename", String.self),
                    .field("oid", GitHubAPI.GitObjectID.self),
                  ] }
                  static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                    GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node.AsPullRequestReview.Commit.self
                  ] }

                  var oid: GitHubAPI.GitObjectID { __data["oid"] }
                }
              }

              /// Repository.PullRequest.TimelineItems.Node.AsClosedEvent
              nonisolated struct AsClosedEvent: GitHubAPI.InlineFragment {
                let __data: DataDict
                init(_dataDict: DataDict) { __data = _dataDict }

                typealias RootEntityType = GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node
                static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.ClosedEvent }
                static var __selections: [ApolloAPI.Selection] { [
                  .field("id", GitHubAPI.ID.self),
                  .field("createdAt", GitHubAPI.DateTime.self),
                  .field("actor", Actor?.self),
                ] }
                static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                  GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node.self,
                  GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node.AsClosedEvent.self
                ] }

                var id: GitHubAPI.ID { __data["id"] }
                var createdAt: GitHubAPI.DateTime { __data["createdAt"] }
                var actor: Actor? { __data["actor"] }

                /// Repository.PullRequest.TimelineItems.Node.AsClosedEvent.Actor
                nonisolated struct Actor: GitHubAPI.SelectionSet {
                  let __data: DataDict
                  init(_dataDict: DataDict) { __data = _dataDict }

                  static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Interfaces.Actor }
                  static var __selections: [ApolloAPI.Selection] { [
                    .field("__typename", String.self),
                    .fragment(GitHubActor.self),
                  ] }
                  static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                    GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node.AsClosedEvent.Actor.self,
                    GitHubActor.self
                  ] }

                  var login: String { __data["login"] }
                  var avatarUrl: GitHubAPI.URI { __data["avatarUrl"] }

                  var asNode: AsNode? { _asInlineFragment() }
                  var asUser: AsUser? { _asInlineFragment() }
                  var asOrganization: AsOrganization? { _asInlineFragment() }

                  struct Fragments: FragmentContainer {
                    let __data: DataDict
                    init(_dataDict: DataDict) { __data = _dataDict }

                    var gitHubActor: GitHubActor { _toFragment() }
                  }

                  /// Repository.PullRequest.TimelineItems.Node.AsClosedEvent.Actor.AsNode
                  nonisolated struct AsNode: GitHubAPI.InlineFragment, ApolloAPI.CompositeInlineFragment {
                    let __data: DataDict
                    init(_dataDict: DataDict) { __data = _dataDict }

                    typealias RootEntityType = GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node.AsClosedEvent.Actor
                    static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Interfaces.Node }
                    static var __mergedSources: [any ApolloAPI.SelectionSet.Type] { [
                      GitHubActor.self,
                      GitHubActor.AsNode.self,
                      GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node.AsClosedEvent.Actor.self
                    ] }
                    static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                      GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node.AsClosedEvent.Actor.self,
                      GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node.AsClosedEvent.Actor.AsNode.self,
                      GitHubActor.self,
                      GitHubActor.AsNode.self
                    ] }

                    var login: String { __data["login"] }
                    var avatarUrl: GitHubAPI.URI { __data["avatarUrl"] }
                    var id: GitHubAPI.ID { __data["id"] }

                    struct Fragments: FragmentContainer {
                      let __data: DataDict
                      init(_dataDict: DataDict) { __data = _dataDict }

                      var gitHubActor: GitHubActor { _toFragment() }
                    }
                  }

                  /// Repository.PullRequest.TimelineItems.Node.AsClosedEvent.Actor.AsUser
                  nonisolated struct AsUser: GitHubAPI.InlineFragment, ApolloAPI.CompositeInlineFragment {
                    let __data: DataDict
                    init(_dataDict: DataDict) { __data = _dataDict }

                    typealias RootEntityType = GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node.AsClosedEvent.Actor
                    static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.User }
                    static var __mergedSources: [any ApolloAPI.SelectionSet.Type] { [
                      GitHubActor.self,
                      GitHubActor.AsNode.self,
                      GitHubActor.AsUser.self,
                      GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node.AsClosedEvent.Actor.self
                    ] }
                    static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                      GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node.AsClosedEvent.Actor.self,
                      GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node.AsClosedEvent.Actor.AsUser.self,
                      GitHubActor.self,
                      GitHubActor.AsNode.self,
                      GitHubActor.AsUser.self
                    ] }

                    var login: String { __data["login"] }
                    var avatarUrl: GitHubAPI.URI { __data["avatarUrl"] }
                    var id: GitHubAPI.ID { __data["id"] }
                    var name: String? { __data["name"] }

                    struct Fragments: FragmentContainer {
                      let __data: DataDict
                      init(_dataDict: DataDict) { __data = _dataDict }

                      var gitHubActor: GitHubActor { _toFragment() }
                    }
                  }

                  /// Repository.PullRequest.TimelineItems.Node.AsClosedEvent.Actor.AsOrganization
                  nonisolated struct AsOrganization: GitHubAPI.InlineFragment, ApolloAPI.CompositeInlineFragment {
                    let __data: DataDict
                    init(_dataDict: DataDict) { __data = _dataDict }

                    typealias RootEntityType = GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node.AsClosedEvent.Actor
                    static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.Organization }
                    static var __mergedSources: [any ApolloAPI.SelectionSet.Type] { [
                      GitHubActor.self,
                      GitHubActor.AsNode.self,
                      GitHubActor.AsOrganization.self,
                      GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node.AsClosedEvent.Actor.self
                    ] }
                    static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                      GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node.AsClosedEvent.Actor.self,
                      GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node.AsClosedEvent.Actor.AsOrganization.self,
                      GitHubActor.self,
                      GitHubActor.AsNode.self,
                      GitHubActor.AsOrganization.self
                    ] }

                    var login: String { __data["login"] }
                    var avatarUrl: GitHubAPI.URI { __data["avatarUrl"] }
                    var id: GitHubAPI.ID { __data["id"] }
                    var name: String? { __data["name"] }

                    struct Fragments: FragmentContainer {
                      let __data: DataDict
                      init(_dataDict: DataDict) { __data = _dataDict }

                      var gitHubActor: GitHubActor { _toFragment() }
                    }
                  }
                }
              }

              /// Repository.PullRequest.TimelineItems.Node.AsReopenedEvent
              nonisolated struct AsReopenedEvent: GitHubAPI.InlineFragment {
                let __data: DataDict
                init(_dataDict: DataDict) { __data = _dataDict }

                typealias RootEntityType = GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node
                static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.ReopenedEvent }
                static var __selections: [ApolloAPI.Selection] { [
                  .field("id", GitHubAPI.ID.self),
                  .field("createdAt", GitHubAPI.DateTime.self),
                  .field("actor", Actor?.self),
                ] }
                static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                  GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node.self,
                  GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node.AsReopenedEvent.self
                ] }

                var id: GitHubAPI.ID { __data["id"] }
                var createdAt: GitHubAPI.DateTime { __data["createdAt"] }
                var actor: Actor? { __data["actor"] }

                /// Repository.PullRequest.TimelineItems.Node.AsReopenedEvent.Actor
                nonisolated struct Actor: GitHubAPI.SelectionSet {
                  let __data: DataDict
                  init(_dataDict: DataDict) { __data = _dataDict }

                  static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Interfaces.Actor }
                  static var __selections: [ApolloAPI.Selection] { [
                    .field("__typename", String.self),
                    .fragment(GitHubActor.self),
                  ] }
                  static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                    GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node.AsReopenedEvent.Actor.self,
                    GitHubActor.self
                  ] }

                  var login: String { __data["login"] }
                  var avatarUrl: GitHubAPI.URI { __data["avatarUrl"] }

                  var asNode: AsNode? { _asInlineFragment() }
                  var asUser: AsUser? { _asInlineFragment() }
                  var asOrganization: AsOrganization? { _asInlineFragment() }

                  struct Fragments: FragmentContainer {
                    let __data: DataDict
                    init(_dataDict: DataDict) { __data = _dataDict }

                    var gitHubActor: GitHubActor { _toFragment() }
                  }

                  /// Repository.PullRequest.TimelineItems.Node.AsReopenedEvent.Actor.AsNode
                  nonisolated struct AsNode: GitHubAPI.InlineFragment, ApolloAPI.CompositeInlineFragment {
                    let __data: DataDict
                    init(_dataDict: DataDict) { __data = _dataDict }

                    typealias RootEntityType = GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node.AsReopenedEvent.Actor
                    static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Interfaces.Node }
                    static var __mergedSources: [any ApolloAPI.SelectionSet.Type] { [
                      GitHubActor.self,
                      GitHubActor.AsNode.self,
                      GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node.AsReopenedEvent.Actor.self
                    ] }
                    static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                      GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node.AsReopenedEvent.Actor.self,
                      GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node.AsReopenedEvent.Actor.AsNode.self,
                      GitHubActor.self,
                      GitHubActor.AsNode.self
                    ] }

                    var login: String { __data["login"] }
                    var avatarUrl: GitHubAPI.URI { __data["avatarUrl"] }
                    var id: GitHubAPI.ID { __data["id"] }

                    struct Fragments: FragmentContainer {
                      let __data: DataDict
                      init(_dataDict: DataDict) { __data = _dataDict }

                      var gitHubActor: GitHubActor { _toFragment() }
                    }
                  }

                  /// Repository.PullRequest.TimelineItems.Node.AsReopenedEvent.Actor.AsUser
                  nonisolated struct AsUser: GitHubAPI.InlineFragment, ApolloAPI.CompositeInlineFragment {
                    let __data: DataDict
                    init(_dataDict: DataDict) { __data = _dataDict }

                    typealias RootEntityType = GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node.AsReopenedEvent.Actor
                    static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.User }
                    static var __mergedSources: [any ApolloAPI.SelectionSet.Type] { [
                      GitHubActor.self,
                      GitHubActor.AsNode.self,
                      GitHubActor.AsUser.self,
                      GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node.AsReopenedEvent.Actor.self
                    ] }
                    static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                      GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node.AsReopenedEvent.Actor.self,
                      GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node.AsReopenedEvent.Actor.AsUser.self,
                      GitHubActor.self,
                      GitHubActor.AsNode.self,
                      GitHubActor.AsUser.self
                    ] }

                    var login: String { __data["login"] }
                    var avatarUrl: GitHubAPI.URI { __data["avatarUrl"] }
                    var id: GitHubAPI.ID { __data["id"] }
                    var name: String? { __data["name"] }

                    struct Fragments: FragmentContainer {
                      let __data: DataDict
                      init(_dataDict: DataDict) { __data = _dataDict }

                      var gitHubActor: GitHubActor { _toFragment() }
                    }
                  }

                  /// Repository.PullRequest.TimelineItems.Node.AsReopenedEvent.Actor.AsOrganization
                  nonisolated struct AsOrganization: GitHubAPI.InlineFragment, ApolloAPI.CompositeInlineFragment {
                    let __data: DataDict
                    init(_dataDict: DataDict) { __data = _dataDict }

                    typealias RootEntityType = GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node.AsReopenedEvent.Actor
                    static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.Organization }
                    static var __mergedSources: [any ApolloAPI.SelectionSet.Type] { [
                      GitHubActor.self,
                      GitHubActor.AsNode.self,
                      GitHubActor.AsOrganization.self,
                      GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node.AsReopenedEvent.Actor.self
                    ] }
                    static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                      GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node.AsReopenedEvent.Actor.self,
                      GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node.AsReopenedEvent.Actor.AsOrganization.self,
                      GitHubActor.self,
                      GitHubActor.AsNode.self,
                      GitHubActor.AsOrganization.self
                    ] }

                    var login: String { __data["login"] }
                    var avatarUrl: GitHubAPI.URI { __data["avatarUrl"] }
                    var id: GitHubAPI.ID { __data["id"] }
                    var name: String? { __data["name"] }

                    struct Fragments: FragmentContainer {
                      let __data: DataDict
                      init(_dataDict: DataDict) { __data = _dataDict }

                      var gitHubActor: GitHubActor { _toFragment() }
                    }
                  }
                }
              }

              /// Repository.PullRequest.TimelineItems.Node.AsMergedEvent
              nonisolated struct AsMergedEvent: GitHubAPI.InlineFragment {
                let __data: DataDict
                init(_dataDict: DataDict) { __data = _dataDict }

                typealias RootEntityType = GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node
                static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.MergedEvent }
                static var __selections: [ApolloAPI.Selection] { [
                  .field("id", GitHubAPI.ID.self),
                  .field("createdAt", GitHubAPI.DateTime.self),
                  .field("actor", Actor?.self),
                  .field("commit", Commit?.self),
                ] }
                static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                  GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node.self,
                  GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node.AsMergedEvent.self
                ] }

                var id: GitHubAPI.ID { __data["id"] }
                var createdAt: GitHubAPI.DateTime { __data["createdAt"] }
                var actor: Actor? { __data["actor"] }
                var commit: Commit? { __data["commit"] }

                /// Repository.PullRequest.TimelineItems.Node.AsMergedEvent.Actor
                nonisolated struct Actor: GitHubAPI.SelectionSet {
                  let __data: DataDict
                  init(_dataDict: DataDict) { __data = _dataDict }

                  static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Interfaces.Actor }
                  static var __selections: [ApolloAPI.Selection] { [
                    .field("__typename", String.self),
                    .fragment(GitHubActor.self),
                  ] }
                  static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                    GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node.AsMergedEvent.Actor.self,
                    GitHubActor.self
                  ] }

                  var login: String { __data["login"] }
                  var avatarUrl: GitHubAPI.URI { __data["avatarUrl"] }

                  var asNode: AsNode? { _asInlineFragment() }
                  var asUser: AsUser? { _asInlineFragment() }
                  var asOrganization: AsOrganization? { _asInlineFragment() }

                  struct Fragments: FragmentContainer {
                    let __data: DataDict
                    init(_dataDict: DataDict) { __data = _dataDict }

                    var gitHubActor: GitHubActor { _toFragment() }
                  }

                  /// Repository.PullRequest.TimelineItems.Node.AsMergedEvent.Actor.AsNode
                  nonisolated struct AsNode: GitHubAPI.InlineFragment, ApolloAPI.CompositeInlineFragment {
                    let __data: DataDict
                    init(_dataDict: DataDict) { __data = _dataDict }

                    typealias RootEntityType = GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node.AsMergedEvent.Actor
                    static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Interfaces.Node }
                    static var __mergedSources: [any ApolloAPI.SelectionSet.Type] { [
                      GitHubActor.self,
                      GitHubActor.AsNode.self,
                      GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node.AsMergedEvent.Actor.self
                    ] }
                    static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                      GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node.AsMergedEvent.Actor.self,
                      GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node.AsMergedEvent.Actor.AsNode.self,
                      GitHubActor.self,
                      GitHubActor.AsNode.self
                    ] }

                    var login: String { __data["login"] }
                    var avatarUrl: GitHubAPI.URI { __data["avatarUrl"] }
                    var id: GitHubAPI.ID { __data["id"] }

                    struct Fragments: FragmentContainer {
                      let __data: DataDict
                      init(_dataDict: DataDict) { __data = _dataDict }

                      var gitHubActor: GitHubActor { _toFragment() }
                    }
                  }

                  /// Repository.PullRequest.TimelineItems.Node.AsMergedEvent.Actor.AsUser
                  nonisolated struct AsUser: GitHubAPI.InlineFragment, ApolloAPI.CompositeInlineFragment {
                    let __data: DataDict
                    init(_dataDict: DataDict) { __data = _dataDict }

                    typealias RootEntityType = GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node.AsMergedEvent.Actor
                    static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.User }
                    static var __mergedSources: [any ApolloAPI.SelectionSet.Type] { [
                      GitHubActor.self,
                      GitHubActor.AsNode.self,
                      GitHubActor.AsUser.self,
                      GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node.AsMergedEvent.Actor.self
                    ] }
                    static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                      GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node.AsMergedEvent.Actor.self,
                      GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node.AsMergedEvent.Actor.AsUser.self,
                      GitHubActor.self,
                      GitHubActor.AsNode.self,
                      GitHubActor.AsUser.self
                    ] }

                    var login: String { __data["login"] }
                    var avatarUrl: GitHubAPI.URI { __data["avatarUrl"] }
                    var id: GitHubAPI.ID { __data["id"] }
                    var name: String? { __data["name"] }

                    struct Fragments: FragmentContainer {
                      let __data: DataDict
                      init(_dataDict: DataDict) { __data = _dataDict }

                      var gitHubActor: GitHubActor { _toFragment() }
                    }
                  }

                  /// Repository.PullRequest.TimelineItems.Node.AsMergedEvent.Actor.AsOrganization
                  nonisolated struct AsOrganization: GitHubAPI.InlineFragment, ApolloAPI.CompositeInlineFragment {
                    let __data: DataDict
                    init(_dataDict: DataDict) { __data = _dataDict }

                    typealias RootEntityType = GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node.AsMergedEvent.Actor
                    static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.Organization }
                    static var __mergedSources: [any ApolloAPI.SelectionSet.Type] { [
                      GitHubActor.self,
                      GitHubActor.AsNode.self,
                      GitHubActor.AsOrganization.self,
                      GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node.AsMergedEvent.Actor.self
                    ] }
                    static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                      GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node.AsMergedEvent.Actor.self,
                      GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node.AsMergedEvent.Actor.AsOrganization.self,
                      GitHubActor.self,
                      GitHubActor.AsNode.self,
                      GitHubActor.AsOrganization.self
                    ] }

                    var login: String { __data["login"] }
                    var avatarUrl: GitHubAPI.URI { __data["avatarUrl"] }
                    var id: GitHubAPI.ID { __data["id"] }
                    var name: String? { __data["name"] }

                    struct Fragments: FragmentContainer {
                      let __data: DataDict
                      init(_dataDict: DataDict) { __data = _dataDict }

                      var gitHubActor: GitHubActor { _toFragment() }
                    }
                  }
                }

                /// Repository.PullRequest.TimelineItems.Node.AsMergedEvent.Commit
                nonisolated struct Commit: GitHubAPI.SelectionSet {
                  let __data: DataDict
                  init(_dataDict: DataDict) { __data = _dataDict }

                  static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.Commit }
                  static var __selections: [ApolloAPI.Selection] { [
                    .field("__typename", String.self),
                    .field("oid", GitHubAPI.GitObjectID.self),
                  ] }
                  static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                    GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node.AsMergedEvent.Commit.self
                  ] }

                  var oid: GitHubAPI.GitObjectID { __data["oid"] }
                }
              }

              /// Repository.PullRequest.TimelineItems.Node.AsAssignedEvent
              nonisolated struct AsAssignedEvent: GitHubAPI.InlineFragment {
                let __data: DataDict
                init(_dataDict: DataDict) { __data = _dataDict }

                typealias RootEntityType = GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node
                static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.AssignedEvent }
                static var __selections: [ApolloAPI.Selection] { [
                  .field("id", GitHubAPI.ID.self),
                  .field("createdAt", GitHubAPI.DateTime.self),
                  .field("actor", Actor?.self),
                  .field("assignee", Assignee?.self),
                ] }
                static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                  GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node.self,
                  GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node.AsAssignedEvent.self
                ] }

                var id: GitHubAPI.ID { __data["id"] }
                var createdAt: GitHubAPI.DateTime { __data["createdAt"] }
                var actor: Actor? { __data["actor"] }
                var assignee: Assignee? { __data["assignee"] }

                /// Repository.PullRequest.TimelineItems.Node.AsAssignedEvent.Actor
                nonisolated struct Actor: GitHubAPI.SelectionSet {
                  let __data: DataDict
                  init(_dataDict: DataDict) { __data = _dataDict }

                  static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Interfaces.Actor }
                  static var __selections: [ApolloAPI.Selection] { [
                    .field("__typename", String.self),
                    .fragment(GitHubActor.self),
                  ] }
                  static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                    GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node.AsAssignedEvent.Actor.self,
                    GitHubActor.self
                  ] }

                  var login: String { __data["login"] }
                  var avatarUrl: GitHubAPI.URI { __data["avatarUrl"] }

                  var asNode: AsNode? { _asInlineFragment() }
                  var asUser: AsUser? { _asInlineFragment() }
                  var asOrganization: AsOrganization? { _asInlineFragment() }

                  struct Fragments: FragmentContainer {
                    let __data: DataDict
                    init(_dataDict: DataDict) { __data = _dataDict }

                    var gitHubActor: GitHubActor { _toFragment() }
                  }

                  /// Repository.PullRequest.TimelineItems.Node.AsAssignedEvent.Actor.AsNode
                  nonisolated struct AsNode: GitHubAPI.InlineFragment, ApolloAPI.CompositeInlineFragment {
                    let __data: DataDict
                    init(_dataDict: DataDict) { __data = _dataDict }

                    typealias RootEntityType = GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node.AsAssignedEvent.Actor
                    static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Interfaces.Node }
                    static var __mergedSources: [any ApolloAPI.SelectionSet.Type] { [
                      GitHubActor.self,
                      GitHubActor.AsNode.self,
                      GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node.AsAssignedEvent.Actor.self
                    ] }
                    static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                      GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node.AsAssignedEvent.Actor.self,
                      GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node.AsAssignedEvent.Actor.AsNode.self,
                      GitHubActor.self,
                      GitHubActor.AsNode.self
                    ] }

                    var login: String { __data["login"] }
                    var avatarUrl: GitHubAPI.URI { __data["avatarUrl"] }
                    var id: GitHubAPI.ID { __data["id"] }

                    struct Fragments: FragmentContainer {
                      let __data: DataDict
                      init(_dataDict: DataDict) { __data = _dataDict }

                      var gitHubActor: GitHubActor { _toFragment() }
                    }
                  }

                  /// Repository.PullRequest.TimelineItems.Node.AsAssignedEvent.Actor.AsUser
                  nonisolated struct AsUser: GitHubAPI.InlineFragment, ApolloAPI.CompositeInlineFragment {
                    let __data: DataDict
                    init(_dataDict: DataDict) { __data = _dataDict }

                    typealias RootEntityType = GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node.AsAssignedEvent.Actor
                    static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.User }
                    static var __mergedSources: [any ApolloAPI.SelectionSet.Type] { [
                      GitHubActor.self,
                      GitHubActor.AsNode.self,
                      GitHubActor.AsUser.self,
                      GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node.AsAssignedEvent.Actor.self
                    ] }
                    static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                      GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node.AsAssignedEvent.Actor.self,
                      GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node.AsAssignedEvent.Actor.AsUser.self,
                      GitHubActor.self,
                      GitHubActor.AsNode.self,
                      GitHubActor.AsUser.self
                    ] }

                    var login: String { __data["login"] }
                    var avatarUrl: GitHubAPI.URI { __data["avatarUrl"] }
                    var id: GitHubAPI.ID { __data["id"] }
                    var name: String? { __data["name"] }

                    struct Fragments: FragmentContainer {
                      let __data: DataDict
                      init(_dataDict: DataDict) { __data = _dataDict }

                      var gitHubActor: GitHubActor { _toFragment() }
                    }
                  }

                  /// Repository.PullRequest.TimelineItems.Node.AsAssignedEvent.Actor.AsOrganization
                  nonisolated struct AsOrganization: GitHubAPI.InlineFragment, ApolloAPI.CompositeInlineFragment {
                    let __data: DataDict
                    init(_dataDict: DataDict) { __data = _dataDict }

                    typealias RootEntityType = GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node.AsAssignedEvent.Actor
                    static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.Organization }
                    static var __mergedSources: [any ApolloAPI.SelectionSet.Type] { [
                      GitHubActor.self,
                      GitHubActor.AsNode.self,
                      GitHubActor.AsOrganization.self,
                      GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node.AsAssignedEvent.Actor.self
                    ] }
                    static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                      GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node.AsAssignedEvent.Actor.self,
                      GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node.AsAssignedEvent.Actor.AsOrganization.self,
                      GitHubActor.self,
                      GitHubActor.AsNode.self,
                      GitHubActor.AsOrganization.self
                    ] }

                    var login: String { __data["login"] }
                    var avatarUrl: GitHubAPI.URI { __data["avatarUrl"] }
                    var id: GitHubAPI.ID { __data["id"] }
                    var name: String? { __data["name"] }

                    struct Fragments: FragmentContainer {
                      let __data: DataDict
                      init(_dataDict: DataDict) { __data = _dataDict }

                      var gitHubActor: GitHubActor { _toFragment() }
                    }
                  }
                }

                /// Repository.PullRequest.TimelineItems.Node.AsAssignedEvent.Assignee
                nonisolated struct Assignee: GitHubAPI.SelectionSet {
                  let __data: DataDict
                  init(_dataDict: DataDict) { __data = _dataDict }

                  static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Unions.Assignee }
                  static var __selections: [ApolloAPI.Selection] { [
                    .field("__typename", String.self),
                    .fragment(GitHubAssignee.self),
                  ] }
                  static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                    GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node.AsAssignedEvent.Assignee.self
                  ] }

                  var asActor: AsActor? { _asInlineFragment() }
                  var asMannequin: AsMannequin? { _asInlineFragment() }

                  struct Fragments: FragmentContainer {
                    let __data: DataDict
                    init(_dataDict: DataDict) { __data = _dataDict }

                    var gitHubAssignee: GitHubAssignee { _toFragment() }
                  }

                  /// Repository.PullRequest.TimelineItems.Node.AsAssignedEvent.Assignee.AsActor
                  nonisolated struct AsActor: GitHubAPI.InlineFragment, ApolloAPI.CompositeInlineFragment {
                    let __data: DataDict
                    init(_dataDict: DataDict) { __data = _dataDict }

                    typealias RootEntityType = GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node.AsAssignedEvent.Assignee
                    static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Interfaces.Actor }
                    static var __mergedSources: [any ApolloAPI.SelectionSet.Type] { [
                      GitHubAssignee.AsActor.self,
                      GitHubActor.self,
                      GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node.AsAssignedEvent.Assignee.self
                    ] }
                    static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                      GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node.AsAssignedEvent.Assignee.self,
                      GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node.AsAssignedEvent.Assignee.AsActor.self,
                      GitHubAssignee.self,
                      GitHubAssignee.AsActor.self,
                      GitHubActor.self
                    ] }

                    var login: String { __data["login"] }
                    var avatarUrl: GitHubAPI.URI { __data["avatarUrl"] }

                    struct Fragments: FragmentContainer {
                      let __data: DataDict
                      init(_dataDict: DataDict) { __data = _dataDict }

                      var gitHubActor: GitHubActor { _toFragment() }
                      var gitHubAssignee: GitHubAssignee { _toFragment() }
                    }
                  }

                  /// Repository.PullRequest.TimelineItems.Node.AsAssignedEvent.Assignee.AsMannequin
                  nonisolated struct AsMannequin: GitHubAPI.InlineFragment, ApolloAPI.CompositeInlineFragment {
                    let __data: DataDict
                    init(_dataDict: DataDict) { __data = _dataDict }

                    typealias RootEntityType = GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node.AsAssignedEvent.Assignee
                    static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.Mannequin }
                    static var __mergedSources: [any ApolloAPI.SelectionSet.Type] { [
                      GitHubAssignee.AsActor.self,
                      GitHubActor.self,
                      GitHubActor.AsNode.self,
                      GitHubAssignee.AsMannequin.self,
                      GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node.AsAssignedEvent.Assignee.self
                    ] }
                    static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                      GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node.AsAssignedEvent.Assignee.self,
                      GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node.AsAssignedEvent.Assignee.AsMannequin.self,
                      GitHubAssignee.self,
                      GitHubAssignee.AsActor.self,
                      GitHubActor.self,
                      GitHubActor.AsNode.self,
                      GitHubAssignee.AsMannequin.self
                    ] }

                    var login: String { __data["login"] }
                    var avatarUrl: GitHubAPI.URI { __data["avatarUrl"] }
                    var id: GitHubAPI.ID { __data["id"] }
                    var mannequinID: GitHubAPI.ID { __data["mannequinID"] }
                    var mannequinLogin: String { __data["mannequinLogin"] }
                    var mannequinAvatarURL: GitHubAPI.URI { __data["mannequinAvatarURL"] }

                    struct Fragments: FragmentContainer {
                      let __data: DataDict
                      init(_dataDict: DataDict) { __data = _dataDict }

                      var gitHubActor: GitHubActor { _toFragment() }
                      var gitHubAssignee: GitHubAssignee { _toFragment() }
                    }
                  }
                }
              }

              /// Repository.PullRequest.TimelineItems.Node.AsUnassignedEvent
              nonisolated struct AsUnassignedEvent: GitHubAPI.InlineFragment {
                let __data: DataDict
                init(_dataDict: DataDict) { __data = _dataDict }

                typealias RootEntityType = GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node
                static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.UnassignedEvent }
                static var __selections: [ApolloAPI.Selection] { [
                  .field("id", GitHubAPI.ID.self),
                  .field("createdAt", GitHubAPI.DateTime.self),
                  .field("actor", Actor?.self),
                  .field("assignee", Assignee?.self),
                ] }
                static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                  GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node.self,
                  GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node.AsUnassignedEvent.self
                ] }

                var id: GitHubAPI.ID { __data["id"] }
                var createdAt: GitHubAPI.DateTime { __data["createdAt"] }
                var actor: Actor? { __data["actor"] }
                var assignee: Assignee? { __data["assignee"] }

                /// Repository.PullRequest.TimelineItems.Node.AsUnassignedEvent.Actor
                nonisolated struct Actor: GitHubAPI.SelectionSet {
                  let __data: DataDict
                  init(_dataDict: DataDict) { __data = _dataDict }

                  static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Interfaces.Actor }
                  static var __selections: [ApolloAPI.Selection] { [
                    .field("__typename", String.self),
                    .fragment(GitHubActor.self),
                  ] }
                  static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                    GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node.AsUnassignedEvent.Actor.self,
                    GitHubActor.self
                  ] }

                  var login: String { __data["login"] }
                  var avatarUrl: GitHubAPI.URI { __data["avatarUrl"] }

                  var asNode: AsNode? { _asInlineFragment() }
                  var asUser: AsUser? { _asInlineFragment() }
                  var asOrganization: AsOrganization? { _asInlineFragment() }

                  struct Fragments: FragmentContainer {
                    let __data: DataDict
                    init(_dataDict: DataDict) { __data = _dataDict }

                    var gitHubActor: GitHubActor { _toFragment() }
                  }

                  /// Repository.PullRequest.TimelineItems.Node.AsUnassignedEvent.Actor.AsNode
                  nonisolated struct AsNode: GitHubAPI.InlineFragment, ApolloAPI.CompositeInlineFragment {
                    let __data: DataDict
                    init(_dataDict: DataDict) { __data = _dataDict }

                    typealias RootEntityType = GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node.AsUnassignedEvent.Actor
                    static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Interfaces.Node }
                    static var __mergedSources: [any ApolloAPI.SelectionSet.Type] { [
                      GitHubActor.self,
                      GitHubActor.AsNode.self,
                      GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node.AsUnassignedEvent.Actor.self
                    ] }
                    static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                      GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node.AsUnassignedEvent.Actor.self,
                      GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node.AsUnassignedEvent.Actor.AsNode.self,
                      GitHubActor.self,
                      GitHubActor.AsNode.self
                    ] }

                    var login: String { __data["login"] }
                    var avatarUrl: GitHubAPI.URI { __data["avatarUrl"] }
                    var id: GitHubAPI.ID { __data["id"] }

                    struct Fragments: FragmentContainer {
                      let __data: DataDict
                      init(_dataDict: DataDict) { __data = _dataDict }

                      var gitHubActor: GitHubActor { _toFragment() }
                    }
                  }

                  /// Repository.PullRequest.TimelineItems.Node.AsUnassignedEvent.Actor.AsUser
                  nonisolated struct AsUser: GitHubAPI.InlineFragment, ApolloAPI.CompositeInlineFragment {
                    let __data: DataDict
                    init(_dataDict: DataDict) { __data = _dataDict }

                    typealias RootEntityType = GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node.AsUnassignedEvent.Actor
                    static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.User }
                    static var __mergedSources: [any ApolloAPI.SelectionSet.Type] { [
                      GitHubActor.self,
                      GitHubActor.AsNode.self,
                      GitHubActor.AsUser.self,
                      GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node.AsUnassignedEvent.Actor.self
                    ] }
                    static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                      GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node.AsUnassignedEvent.Actor.self,
                      GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node.AsUnassignedEvent.Actor.AsUser.self,
                      GitHubActor.self,
                      GitHubActor.AsNode.self,
                      GitHubActor.AsUser.self
                    ] }

                    var login: String { __data["login"] }
                    var avatarUrl: GitHubAPI.URI { __data["avatarUrl"] }
                    var id: GitHubAPI.ID { __data["id"] }
                    var name: String? { __data["name"] }

                    struct Fragments: FragmentContainer {
                      let __data: DataDict
                      init(_dataDict: DataDict) { __data = _dataDict }

                      var gitHubActor: GitHubActor { _toFragment() }
                    }
                  }

                  /// Repository.PullRequest.TimelineItems.Node.AsUnassignedEvent.Actor.AsOrganization
                  nonisolated struct AsOrganization: GitHubAPI.InlineFragment, ApolloAPI.CompositeInlineFragment {
                    let __data: DataDict
                    init(_dataDict: DataDict) { __data = _dataDict }

                    typealias RootEntityType = GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node.AsUnassignedEvent.Actor
                    static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.Organization }
                    static var __mergedSources: [any ApolloAPI.SelectionSet.Type] { [
                      GitHubActor.self,
                      GitHubActor.AsNode.self,
                      GitHubActor.AsOrganization.self,
                      GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node.AsUnassignedEvent.Actor.self
                    ] }
                    static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                      GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node.AsUnassignedEvent.Actor.self,
                      GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node.AsUnassignedEvent.Actor.AsOrganization.self,
                      GitHubActor.self,
                      GitHubActor.AsNode.self,
                      GitHubActor.AsOrganization.self
                    ] }

                    var login: String { __data["login"] }
                    var avatarUrl: GitHubAPI.URI { __data["avatarUrl"] }
                    var id: GitHubAPI.ID { __data["id"] }
                    var name: String? { __data["name"] }

                    struct Fragments: FragmentContainer {
                      let __data: DataDict
                      init(_dataDict: DataDict) { __data = _dataDict }

                      var gitHubActor: GitHubActor { _toFragment() }
                    }
                  }
                }

                /// Repository.PullRequest.TimelineItems.Node.AsUnassignedEvent.Assignee
                nonisolated struct Assignee: GitHubAPI.SelectionSet {
                  let __data: DataDict
                  init(_dataDict: DataDict) { __data = _dataDict }

                  static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Unions.Assignee }
                  static var __selections: [ApolloAPI.Selection] { [
                    .field("__typename", String.self),
                    .fragment(GitHubAssignee.self),
                  ] }
                  static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                    GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node.AsUnassignedEvent.Assignee.self
                  ] }

                  var asActor: AsActor? { _asInlineFragment() }
                  var asMannequin: AsMannequin? { _asInlineFragment() }

                  struct Fragments: FragmentContainer {
                    let __data: DataDict
                    init(_dataDict: DataDict) { __data = _dataDict }

                    var gitHubAssignee: GitHubAssignee { _toFragment() }
                  }

                  /// Repository.PullRequest.TimelineItems.Node.AsUnassignedEvent.Assignee.AsActor
                  nonisolated struct AsActor: GitHubAPI.InlineFragment, ApolloAPI.CompositeInlineFragment {
                    let __data: DataDict
                    init(_dataDict: DataDict) { __data = _dataDict }

                    typealias RootEntityType = GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node.AsUnassignedEvent.Assignee
                    static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Interfaces.Actor }
                    static var __mergedSources: [any ApolloAPI.SelectionSet.Type] { [
                      GitHubAssignee.AsActor.self,
                      GitHubActor.self,
                      GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node.AsUnassignedEvent.Assignee.self
                    ] }
                    static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                      GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node.AsUnassignedEvent.Assignee.self,
                      GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node.AsUnassignedEvent.Assignee.AsActor.self,
                      GitHubAssignee.self,
                      GitHubAssignee.AsActor.self,
                      GitHubActor.self
                    ] }

                    var login: String { __data["login"] }
                    var avatarUrl: GitHubAPI.URI { __data["avatarUrl"] }

                    struct Fragments: FragmentContainer {
                      let __data: DataDict
                      init(_dataDict: DataDict) { __data = _dataDict }

                      var gitHubActor: GitHubActor { _toFragment() }
                      var gitHubAssignee: GitHubAssignee { _toFragment() }
                    }
                  }

                  /// Repository.PullRequest.TimelineItems.Node.AsUnassignedEvent.Assignee.AsMannequin
                  nonisolated struct AsMannequin: GitHubAPI.InlineFragment, ApolloAPI.CompositeInlineFragment {
                    let __data: DataDict
                    init(_dataDict: DataDict) { __data = _dataDict }

                    typealias RootEntityType = GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node.AsUnassignedEvent.Assignee
                    static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.Mannequin }
                    static var __mergedSources: [any ApolloAPI.SelectionSet.Type] { [
                      GitHubAssignee.AsActor.self,
                      GitHubActor.self,
                      GitHubActor.AsNode.self,
                      GitHubAssignee.AsMannequin.self,
                      GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node.AsUnassignedEvent.Assignee.self
                    ] }
                    static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                      GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node.AsUnassignedEvent.Assignee.self,
                      GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node.AsUnassignedEvent.Assignee.AsMannequin.self,
                      GitHubAssignee.self,
                      GitHubAssignee.AsActor.self,
                      GitHubActor.self,
                      GitHubActor.AsNode.self,
                      GitHubAssignee.AsMannequin.self
                    ] }

                    var login: String { __data["login"] }
                    var avatarUrl: GitHubAPI.URI { __data["avatarUrl"] }
                    var id: GitHubAPI.ID { __data["id"] }
                    var mannequinID: GitHubAPI.ID { __data["mannequinID"] }
                    var mannequinLogin: String { __data["mannequinLogin"] }
                    var mannequinAvatarURL: GitHubAPI.URI { __data["mannequinAvatarURL"] }

                    struct Fragments: FragmentContainer {
                      let __data: DataDict
                      init(_dataDict: DataDict) { __data = _dataDict }

                      var gitHubActor: GitHubActor { _toFragment() }
                      var gitHubAssignee: GitHubAssignee { _toFragment() }
                    }
                  }
                }
              }

              /// Repository.PullRequest.TimelineItems.Node.AsLabeledEvent
              nonisolated struct AsLabeledEvent: GitHubAPI.InlineFragment {
                let __data: DataDict
                init(_dataDict: DataDict) { __data = _dataDict }

                typealias RootEntityType = GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node
                static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.LabeledEvent }
                static var __selections: [ApolloAPI.Selection] { [
                  .field("id", GitHubAPI.ID.self),
                  .field("createdAt", GitHubAPI.DateTime.self),
                  .field("actor", Actor?.self),
                  .field("label", Label.self),
                ] }
                static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                  GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node.self,
                  GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node.AsLabeledEvent.self
                ] }

                var id: GitHubAPI.ID { __data["id"] }
                var createdAt: GitHubAPI.DateTime { __data["createdAt"] }
                var actor: Actor? { __data["actor"] }
                var label: Label { __data["label"] }

                /// Repository.PullRequest.TimelineItems.Node.AsLabeledEvent.Actor
                nonisolated struct Actor: GitHubAPI.SelectionSet {
                  let __data: DataDict
                  init(_dataDict: DataDict) { __data = _dataDict }

                  static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Interfaces.Actor }
                  static var __selections: [ApolloAPI.Selection] { [
                    .field("__typename", String.self),
                    .fragment(GitHubActor.self),
                  ] }
                  static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                    GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node.AsLabeledEvent.Actor.self,
                    GitHubActor.self
                  ] }

                  var login: String { __data["login"] }
                  var avatarUrl: GitHubAPI.URI { __data["avatarUrl"] }

                  var asNode: AsNode? { _asInlineFragment() }
                  var asUser: AsUser? { _asInlineFragment() }
                  var asOrganization: AsOrganization? { _asInlineFragment() }

                  struct Fragments: FragmentContainer {
                    let __data: DataDict
                    init(_dataDict: DataDict) { __data = _dataDict }

                    var gitHubActor: GitHubActor { _toFragment() }
                  }

                  /// Repository.PullRequest.TimelineItems.Node.AsLabeledEvent.Actor.AsNode
                  nonisolated struct AsNode: GitHubAPI.InlineFragment, ApolloAPI.CompositeInlineFragment {
                    let __data: DataDict
                    init(_dataDict: DataDict) { __data = _dataDict }

                    typealias RootEntityType = GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node.AsLabeledEvent.Actor
                    static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Interfaces.Node }
                    static var __mergedSources: [any ApolloAPI.SelectionSet.Type] { [
                      GitHubActor.self,
                      GitHubActor.AsNode.self,
                      GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node.AsLabeledEvent.Actor.self
                    ] }
                    static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                      GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node.AsLabeledEvent.Actor.self,
                      GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node.AsLabeledEvent.Actor.AsNode.self,
                      GitHubActor.self,
                      GitHubActor.AsNode.self
                    ] }

                    var login: String { __data["login"] }
                    var avatarUrl: GitHubAPI.URI { __data["avatarUrl"] }
                    var id: GitHubAPI.ID { __data["id"] }

                    struct Fragments: FragmentContainer {
                      let __data: DataDict
                      init(_dataDict: DataDict) { __data = _dataDict }

                      var gitHubActor: GitHubActor { _toFragment() }
                    }
                  }

                  /// Repository.PullRequest.TimelineItems.Node.AsLabeledEvent.Actor.AsUser
                  nonisolated struct AsUser: GitHubAPI.InlineFragment, ApolloAPI.CompositeInlineFragment {
                    let __data: DataDict
                    init(_dataDict: DataDict) { __data = _dataDict }

                    typealias RootEntityType = GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node.AsLabeledEvent.Actor
                    static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.User }
                    static var __mergedSources: [any ApolloAPI.SelectionSet.Type] { [
                      GitHubActor.self,
                      GitHubActor.AsNode.self,
                      GitHubActor.AsUser.self,
                      GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node.AsLabeledEvent.Actor.self
                    ] }
                    static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                      GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node.AsLabeledEvent.Actor.self,
                      GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node.AsLabeledEvent.Actor.AsUser.self,
                      GitHubActor.self,
                      GitHubActor.AsNode.self,
                      GitHubActor.AsUser.self
                    ] }

                    var login: String { __data["login"] }
                    var avatarUrl: GitHubAPI.URI { __data["avatarUrl"] }
                    var id: GitHubAPI.ID { __data["id"] }
                    var name: String? { __data["name"] }

                    struct Fragments: FragmentContainer {
                      let __data: DataDict
                      init(_dataDict: DataDict) { __data = _dataDict }

                      var gitHubActor: GitHubActor { _toFragment() }
                    }
                  }

                  /// Repository.PullRequest.TimelineItems.Node.AsLabeledEvent.Actor.AsOrganization
                  nonisolated struct AsOrganization: GitHubAPI.InlineFragment, ApolloAPI.CompositeInlineFragment {
                    let __data: DataDict
                    init(_dataDict: DataDict) { __data = _dataDict }

                    typealias RootEntityType = GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node.AsLabeledEvent.Actor
                    static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.Organization }
                    static var __mergedSources: [any ApolloAPI.SelectionSet.Type] { [
                      GitHubActor.self,
                      GitHubActor.AsNode.self,
                      GitHubActor.AsOrganization.self,
                      GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node.AsLabeledEvent.Actor.self
                    ] }
                    static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                      GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node.AsLabeledEvent.Actor.self,
                      GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node.AsLabeledEvent.Actor.AsOrganization.self,
                      GitHubActor.self,
                      GitHubActor.AsNode.self,
                      GitHubActor.AsOrganization.self
                    ] }

                    var login: String { __data["login"] }
                    var avatarUrl: GitHubAPI.URI { __data["avatarUrl"] }
                    var id: GitHubAPI.ID { __data["id"] }
                    var name: String? { __data["name"] }

                    struct Fragments: FragmentContainer {
                      let __data: DataDict
                      init(_dataDict: DataDict) { __data = _dataDict }

                      var gitHubActor: GitHubActor { _toFragment() }
                    }
                  }
                }

                /// Repository.PullRequest.TimelineItems.Node.AsLabeledEvent.Label
                nonisolated struct Label: GitHubAPI.SelectionSet {
                  let __data: DataDict
                  init(_dataDict: DataDict) { __data = _dataDict }

                  static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.Label }
                  static var __selections: [ApolloAPI.Selection] { [
                    .field("__typename", String.self),
                    .fragment(GitHubLabel.self),
                  ] }
                  static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                    GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node.AsLabeledEvent.Label.self,
                    GitHubLabel.self
                  ] }

                  var id: GitHubAPI.ID { __data["id"] }
                  var name: String { __data["name"] }
                  var description: String? { __data["description"] }
                  var color: String { __data["color"] }

                  struct Fragments: FragmentContainer {
                    let __data: DataDict
                    init(_dataDict: DataDict) { __data = _dataDict }

                    var gitHubLabel: GitHubLabel { _toFragment() }
                  }
                }
              }

              /// Repository.PullRequest.TimelineItems.Node.AsUnlabeledEvent
              nonisolated struct AsUnlabeledEvent: GitHubAPI.InlineFragment {
                let __data: DataDict
                init(_dataDict: DataDict) { __data = _dataDict }

                typealias RootEntityType = GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node
                static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.UnlabeledEvent }
                static var __selections: [ApolloAPI.Selection] { [
                  .field("id", GitHubAPI.ID.self),
                  .field("createdAt", GitHubAPI.DateTime.self),
                  .field("actor", Actor?.self),
                  .field("label", Label.self),
                ] }
                static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                  GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node.self,
                  GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node.AsUnlabeledEvent.self
                ] }

                var id: GitHubAPI.ID { __data["id"] }
                var createdAt: GitHubAPI.DateTime { __data["createdAt"] }
                var actor: Actor? { __data["actor"] }
                var label: Label { __data["label"] }

                /// Repository.PullRequest.TimelineItems.Node.AsUnlabeledEvent.Actor
                nonisolated struct Actor: GitHubAPI.SelectionSet {
                  let __data: DataDict
                  init(_dataDict: DataDict) { __data = _dataDict }

                  static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Interfaces.Actor }
                  static var __selections: [ApolloAPI.Selection] { [
                    .field("__typename", String.self),
                    .fragment(GitHubActor.self),
                  ] }
                  static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                    GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node.AsUnlabeledEvent.Actor.self,
                    GitHubActor.self
                  ] }

                  var login: String { __data["login"] }
                  var avatarUrl: GitHubAPI.URI { __data["avatarUrl"] }

                  var asNode: AsNode? { _asInlineFragment() }
                  var asUser: AsUser? { _asInlineFragment() }
                  var asOrganization: AsOrganization? { _asInlineFragment() }

                  struct Fragments: FragmentContainer {
                    let __data: DataDict
                    init(_dataDict: DataDict) { __data = _dataDict }

                    var gitHubActor: GitHubActor { _toFragment() }
                  }

                  /// Repository.PullRequest.TimelineItems.Node.AsUnlabeledEvent.Actor.AsNode
                  nonisolated struct AsNode: GitHubAPI.InlineFragment, ApolloAPI.CompositeInlineFragment {
                    let __data: DataDict
                    init(_dataDict: DataDict) { __data = _dataDict }

                    typealias RootEntityType = GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node.AsUnlabeledEvent.Actor
                    static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Interfaces.Node }
                    static var __mergedSources: [any ApolloAPI.SelectionSet.Type] { [
                      GitHubActor.self,
                      GitHubActor.AsNode.self,
                      GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node.AsUnlabeledEvent.Actor.self
                    ] }
                    static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                      GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node.AsUnlabeledEvent.Actor.self,
                      GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node.AsUnlabeledEvent.Actor.AsNode.self,
                      GitHubActor.self,
                      GitHubActor.AsNode.self
                    ] }

                    var login: String { __data["login"] }
                    var avatarUrl: GitHubAPI.URI { __data["avatarUrl"] }
                    var id: GitHubAPI.ID { __data["id"] }

                    struct Fragments: FragmentContainer {
                      let __data: DataDict
                      init(_dataDict: DataDict) { __data = _dataDict }

                      var gitHubActor: GitHubActor { _toFragment() }
                    }
                  }

                  /// Repository.PullRequest.TimelineItems.Node.AsUnlabeledEvent.Actor.AsUser
                  nonisolated struct AsUser: GitHubAPI.InlineFragment, ApolloAPI.CompositeInlineFragment {
                    let __data: DataDict
                    init(_dataDict: DataDict) { __data = _dataDict }

                    typealias RootEntityType = GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node.AsUnlabeledEvent.Actor
                    static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.User }
                    static var __mergedSources: [any ApolloAPI.SelectionSet.Type] { [
                      GitHubActor.self,
                      GitHubActor.AsNode.self,
                      GitHubActor.AsUser.self,
                      GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node.AsUnlabeledEvent.Actor.self
                    ] }
                    static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                      GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node.AsUnlabeledEvent.Actor.self,
                      GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node.AsUnlabeledEvent.Actor.AsUser.self,
                      GitHubActor.self,
                      GitHubActor.AsNode.self,
                      GitHubActor.AsUser.self
                    ] }

                    var login: String { __data["login"] }
                    var avatarUrl: GitHubAPI.URI { __data["avatarUrl"] }
                    var id: GitHubAPI.ID { __data["id"] }
                    var name: String? { __data["name"] }

                    struct Fragments: FragmentContainer {
                      let __data: DataDict
                      init(_dataDict: DataDict) { __data = _dataDict }

                      var gitHubActor: GitHubActor { _toFragment() }
                    }
                  }

                  /// Repository.PullRequest.TimelineItems.Node.AsUnlabeledEvent.Actor.AsOrganization
                  nonisolated struct AsOrganization: GitHubAPI.InlineFragment, ApolloAPI.CompositeInlineFragment {
                    let __data: DataDict
                    init(_dataDict: DataDict) { __data = _dataDict }

                    typealias RootEntityType = GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node.AsUnlabeledEvent.Actor
                    static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.Organization }
                    static var __mergedSources: [any ApolloAPI.SelectionSet.Type] { [
                      GitHubActor.self,
                      GitHubActor.AsNode.self,
                      GitHubActor.AsOrganization.self,
                      GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node.AsUnlabeledEvent.Actor.self
                    ] }
                    static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                      GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node.AsUnlabeledEvent.Actor.self,
                      GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node.AsUnlabeledEvent.Actor.AsOrganization.self,
                      GitHubActor.self,
                      GitHubActor.AsNode.self,
                      GitHubActor.AsOrganization.self
                    ] }

                    var login: String { __data["login"] }
                    var avatarUrl: GitHubAPI.URI { __data["avatarUrl"] }
                    var id: GitHubAPI.ID { __data["id"] }
                    var name: String? { __data["name"] }

                    struct Fragments: FragmentContainer {
                      let __data: DataDict
                      init(_dataDict: DataDict) { __data = _dataDict }

                      var gitHubActor: GitHubActor { _toFragment() }
                    }
                  }
                }

                /// Repository.PullRequest.TimelineItems.Node.AsUnlabeledEvent.Label
                nonisolated struct Label: GitHubAPI.SelectionSet {
                  let __data: DataDict
                  init(_dataDict: DataDict) { __data = _dataDict }

                  static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.Label }
                  static var __selections: [ApolloAPI.Selection] { [
                    .field("__typename", String.self),
                    .fragment(GitHubLabel.self),
                  ] }
                  static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                    GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node.AsUnlabeledEvent.Label.self,
                    GitHubLabel.self
                  ] }

                  var id: GitHubAPI.ID { __data["id"] }
                  var name: String { __data["name"] }
                  var description: String? { __data["description"] }
                  var color: String { __data["color"] }

                  struct Fragments: FragmentContainer {
                    let __data: DataDict
                    init(_dataDict: DataDict) { __data = _dataDict }

                    var gitHubLabel: GitHubLabel { _toFragment() }
                  }
                }
              }

              /// Repository.PullRequest.TimelineItems.Node.AsMilestonedEvent
              nonisolated struct AsMilestonedEvent: GitHubAPI.InlineFragment {
                let __data: DataDict
                init(_dataDict: DataDict) { __data = _dataDict }

                typealias RootEntityType = GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node
                static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.MilestonedEvent }
                static var __selections: [ApolloAPI.Selection] { [
                  .field("id", GitHubAPI.ID.self),
                  .field("createdAt", GitHubAPI.DateTime.self),
                  .field("milestoneTitle", String.self),
                  .field("actor", Actor?.self),
                ] }
                static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                  GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node.self,
                  GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node.AsMilestonedEvent.self
                ] }

                var id: GitHubAPI.ID { __data["id"] }
                var createdAt: GitHubAPI.DateTime { __data["createdAt"] }
                var milestoneTitle: String { __data["milestoneTitle"] }
                var actor: Actor? { __data["actor"] }

                /// Repository.PullRequest.TimelineItems.Node.AsMilestonedEvent.Actor
                nonisolated struct Actor: GitHubAPI.SelectionSet {
                  let __data: DataDict
                  init(_dataDict: DataDict) { __data = _dataDict }

                  static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Interfaces.Actor }
                  static var __selections: [ApolloAPI.Selection] { [
                    .field("__typename", String.self),
                    .fragment(GitHubActor.self),
                  ] }
                  static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                    GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node.AsMilestonedEvent.Actor.self,
                    GitHubActor.self
                  ] }

                  var login: String { __data["login"] }
                  var avatarUrl: GitHubAPI.URI { __data["avatarUrl"] }

                  var asNode: AsNode? { _asInlineFragment() }
                  var asUser: AsUser? { _asInlineFragment() }
                  var asOrganization: AsOrganization? { _asInlineFragment() }

                  struct Fragments: FragmentContainer {
                    let __data: DataDict
                    init(_dataDict: DataDict) { __data = _dataDict }

                    var gitHubActor: GitHubActor { _toFragment() }
                  }

                  /// Repository.PullRequest.TimelineItems.Node.AsMilestonedEvent.Actor.AsNode
                  nonisolated struct AsNode: GitHubAPI.InlineFragment, ApolloAPI.CompositeInlineFragment {
                    let __data: DataDict
                    init(_dataDict: DataDict) { __data = _dataDict }

                    typealias RootEntityType = GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node.AsMilestonedEvent.Actor
                    static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Interfaces.Node }
                    static var __mergedSources: [any ApolloAPI.SelectionSet.Type] { [
                      GitHubActor.self,
                      GitHubActor.AsNode.self,
                      GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node.AsMilestonedEvent.Actor.self
                    ] }
                    static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                      GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node.AsMilestonedEvent.Actor.self,
                      GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node.AsMilestonedEvent.Actor.AsNode.self,
                      GitHubActor.self,
                      GitHubActor.AsNode.self
                    ] }

                    var login: String { __data["login"] }
                    var avatarUrl: GitHubAPI.URI { __data["avatarUrl"] }
                    var id: GitHubAPI.ID { __data["id"] }

                    struct Fragments: FragmentContainer {
                      let __data: DataDict
                      init(_dataDict: DataDict) { __data = _dataDict }

                      var gitHubActor: GitHubActor { _toFragment() }
                    }
                  }

                  /// Repository.PullRequest.TimelineItems.Node.AsMilestonedEvent.Actor.AsUser
                  nonisolated struct AsUser: GitHubAPI.InlineFragment, ApolloAPI.CompositeInlineFragment {
                    let __data: DataDict
                    init(_dataDict: DataDict) { __data = _dataDict }

                    typealias RootEntityType = GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node.AsMilestonedEvent.Actor
                    static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.User }
                    static var __mergedSources: [any ApolloAPI.SelectionSet.Type] { [
                      GitHubActor.self,
                      GitHubActor.AsNode.self,
                      GitHubActor.AsUser.self,
                      GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node.AsMilestonedEvent.Actor.self
                    ] }
                    static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                      GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node.AsMilestonedEvent.Actor.self,
                      GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node.AsMilestonedEvent.Actor.AsUser.self,
                      GitHubActor.self,
                      GitHubActor.AsNode.self,
                      GitHubActor.AsUser.self
                    ] }

                    var login: String { __data["login"] }
                    var avatarUrl: GitHubAPI.URI { __data["avatarUrl"] }
                    var id: GitHubAPI.ID { __data["id"] }
                    var name: String? { __data["name"] }

                    struct Fragments: FragmentContainer {
                      let __data: DataDict
                      init(_dataDict: DataDict) { __data = _dataDict }

                      var gitHubActor: GitHubActor { _toFragment() }
                    }
                  }

                  /// Repository.PullRequest.TimelineItems.Node.AsMilestonedEvent.Actor.AsOrganization
                  nonisolated struct AsOrganization: GitHubAPI.InlineFragment, ApolloAPI.CompositeInlineFragment {
                    let __data: DataDict
                    init(_dataDict: DataDict) { __data = _dataDict }

                    typealias RootEntityType = GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node.AsMilestonedEvent.Actor
                    static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.Organization }
                    static var __mergedSources: [any ApolloAPI.SelectionSet.Type] { [
                      GitHubActor.self,
                      GitHubActor.AsNode.self,
                      GitHubActor.AsOrganization.self,
                      GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node.AsMilestonedEvent.Actor.self
                    ] }
                    static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                      GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node.AsMilestonedEvent.Actor.self,
                      GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node.AsMilestonedEvent.Actor.AsOrganization.self,
                      GitHubActor.self,
                      GitHubActor.AsNode.self,
                      GitHubActor.AsOrganization.self
                    ] }

                    var login: String { __data["login"] }
                    var avatarUrl: GitHubAPI.URI { __data["avatarUrl"] }
                    var id: GitHubAPI.ID { __data["id"] }
                    var name: String? { __data["name"] }

                    struct Fragments: FragmentContainer {
                      let __data: DataDict
                      init(_dataDict: DataDict) { __data = _dataDict }

                      var gitHubActor: GitHubActor { _toFragment() }
                    }
                  }
                }
              }

              /// Repository.PullRequest.TimelineItems.Node.AsDemilestonedEvent
              nonisolated struct AsDemilestonedEvent: GitHubAPI.InlineFragment {
                let __data: DataDict
                init(_dataDict: DataDict) { __data = _dataDict }

                typealias RootEntityType = GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node
                static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.DemilestonedEvent }
                static var __selections: [ApolloAPI.Selection] { [
                  .field("id", GitHubAPI.ID.self),
                  .field("createdAt", GitHubAPI.DateTime.self),
                  .field("milestoneTitle", String.self),
                  .field("actor", Actor?.self),
                ] }
                static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                  GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node.self,
                  GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node.AsDemilestonedEvent.self
                ] }

                var id: GitHubAPI.ID { __data["id"] }
                var createdAt: GitHubAPI.DateTime { __data["createdAt"] }
                var milestoneTitle: String { __data["milestoneTitle"] }
                var actor: Actor? { __data["actor"] }

                /// Repository.PullRequest.TimelineItems.Node.AsDemilestonedEvent.Actor
                nonisolated struct Actor: GitHubAPI.SelectionSet {
                  let __data: DataDict
                  init(_dataDict: DataDict) { __data = _dataDict }

                  static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Interfaces.Actor }
                  static var __selections: [ApolloAPI.Selection] { [
                    .field("__typename", String.self),
                    .fragment(GitHubActor.self),
                  ] }
                  static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                    GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node.AsDemilestonedEvent.Actor.self,
                    GitHubActor.self
                  ] }

                  var login: String { __data["login"] }
                  var avatarUrl: GitHubAPI.URI { __data["avatarUrl"] }

                  var asNode: AsNode? { _asInlineFragment() }
                  var asUser: AsUser? { _asInlineFragment() }
                  var asOrganization: AsOrganization? { _asInlineFragment() }

                  struct Fragments: FragmentContainer {
                    let __data: DataDict
                    init(_dataDict: DataDict) { __data = _dataDict }

                    var gitHubActor: GitHubActor { _toFragment() }
                  }

                  /// Repository.PullRequest.TimelineItems.Node.AsDemilestonedEvent.Actor.AsNode
                  nonisolated struct AsNode: GitHubAPI.InlineFragment, ApolloAPI.CompositeInlineFragment {
                    let __data: DataDict
                    init(_dataDict: DataDict) { __data = _dataDict }

                    typealias RootEntityType = GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node.AsDemilestonedEvent.Actor
                    static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Interfaces.Node }
                    static var __mergedSources: [any ApolloAPI.SelectionSet.Type] { [
                      GitHubActor.self,
                      GitHubActor.AsNode.self,
                      GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node.AsDemilestonedEvent.Actor.self
                    ] }
                    static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                      GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node.AsDemilestonedEvent.Actor.self,
                      GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node.AsDemilestonedEvent.Actor.AsNode.self,
                      GitHubActor.self,
                      GitHubActor.AsNode.self
                    ] }

                    var login: String { __data["login"] }
                    var avatarUrl: GitHubAPI.URI { __data["avatarUrl"] }
                    var id: GitHubAPI.ID { __data["id"] }

                    struct Fragments: FragmentContainer {
                      let __data: DataDict
                      init(_dataDict: DataDict) { __data = _dataDict }

                      var gitHubActor: GitHubActor { _toFragment() }
                    }
                  }

                  /// Repository.PullRequest.TimelineItems.Node.AsDemilestonedEvent.Actor.AsUser
                  nonisolated struct AsUser: GitHubAPI.InlineFragment, ApolloAPI.CompositeInlineFragment {
                    let __data: DataDict
                    init(_dataDict: DataDict) { __data = _dataDict }

                    typealias RootEntityType = GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node.AsDemilestonedEvent.Actor
                    static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.User }
                    static var __mergedSources: [any ApolloAPI.SelectionSet.Type] { [
                      GitHubActor.self,
                      GitHubActor.AsNode.self,
                      GitHubActor.AsUser.self,
                      GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node.AsDemilestonedEvent.Actor.self
                    ] }
                    static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                      GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node.AsDemilestonedEvent.Actor.self,
                      GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node.AsDemilestonedEvent.Actor.AsUser.self,
                      GitHubActor.self,
                      GitHubActor.AsNode.self,
                      GitHubActor.AsUser.self
                    ] }

                    var login: String { __data["login"] }
                    var avatarUrl: GitHubAPI.URI { __data["avatarUrl"] }
                    var id: GitHubAPI.ID { __data["id"] }
                    var name: String? { __data["name"] }

                    struct Fragments: FragmentContainer {
                      let __data: DataDict
                      init(_dataDict: DataDict) { __data = _dataDict }

                      var gitHubActor: GitHubActor { _toFragment() }
                    }
                  }

                  /// Repository.PullRequest.TimelineItems.Node.AsDemilestonedEvent.Actor.AsOrganization
                  nonisolated struct AsOrganization: GitHubAPI.InlineFragment, ApolloAPI.CompositeInlineFragment {
                    let __data: DataDict
                    init(_dataDict: DataDict) { __data = _dataDict }

                    typealias RootEntityType = GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node.AsDemilestonedEvent.Actor
                    static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.Organization }
                    static var __mergedSources: [any ApolloAPI.SelectionSet.Type] { [
                      GitHubActor.self,
                      GitHubActor.AsNode.self,
                      GitHubActor.AsOrganization.self,
                      GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node.AsDemilestonedEvent.Actor.self
                    ] }
                    static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                      GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node.AsDemilestonedEvent.Actor.self,
                      GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node.AsDemilestonedEvent.Actor.AsOrganization.self,
                      GitHubActor.self,
                      GitHubActor.AsNode.self,
                      GitHubActor.AsOrganization.self
                    ] }

                    var login: String { __data["login"] }
                    var avatarUrl: GitHubAPI.URI { __data["avatarUrl"] }
                    var id: GitHubAPI.ID { __data["id"] }
                    var name: String? { __data["name"] }

                    struct Fragments: FragmentContainer {
                      let __data: DataDict
                      init(_dataDict: DataDict) { __data = _dataDict }

                      var gitHubActor: GitHubActor { _toFragment() }
                    }
                  }
                }
              }

              /// Repository.PullRequest.TimelineItems.Node.AsRenamedTitleEvent
              nonisolated struct AsRenamedTitleEvent: GitHubAPI.InlineFragment {
                let __data: DataDict
                init(_dataDict: DataDict) { __data = _dataDict }

                typealias RootEntityType = GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node
                static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.RenamedTitleEvent }
                static var __selections: [ApolloAPI.Selection] { [
                  .field("id", GitHubAPI.ID.self),
                  .field("createdAt", GitHubAPI.DateTime.self),
                  .field("previousTitle", String.self),
                  .field("currentTitle", String.self),
                  .field("actor", Actor?.self),
                ] }
                static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                  GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node.self,
                  GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node.AsRenamedTitleEvent.self
                ] }

                var id: GitHubAPI.ID { __data["id"] }
                var createdAt: GitHubAPI.DateTime { __data["createdAt"] }
                var previousTitle: String { __data["previousTitle"] }
                var currentTitle: String { __data["currentTitle"] }
                var actor: Actor? { __data["actor"] }

                /// Repository.PullRequest.TimelineItems.Node.AsRenamedTitleEvent.Actor
                nonisolated struct Actor: GitHubAPI.SelectionSet {
                  let __data: DataDict
                  init(_dataDict: DataDict) { __data = _dataDict }

                  static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Interfaces.Actor }
                  static var __selections: [ApolloAPI.Selection] { [
                    .field("__typename", String.self),
                    .fragment(GitHubActor.self),
                  ] }
                  static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                    GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node.AsRenamedTitleEvent.Actor.self,
                    GitHubActor.self
                  ] }

                  var login: String { __data["login"] }
                  var avatarUrl: GitHubAPI.URI { __data["avatarUrl"] }

                  var asNode: AsNode? { _asInlineFragment() }
                  var asUser: AsUser? { _asInlineFragment() }
                  var asOrganization: AsOrganization? { _asInlineFragment() }

                  struct Fragments: FragmentContainer {
                    let __data: DataDict
                    init(_dataDict: DataDict) { __data = _dataDict }

                    var gitHubActor: GitHubActor { _toFragment() }
                  }

                  /// Repository.PullRequest.TimelineItems.Node.AsRenamedTitleEvent.Actor.AsNode
                  nonisolated struct AsNode: GitHubAPI.InlineFragment, ApolloAPI.CompositeInlineFragment {
                    let __data: DataDict
                    init(_dataDict: DataDict) { __data = _dataDict }

                    typealias RootEntityType = GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node.AsRenamedTitleEvent.Actor
                    static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Interfaces.Node }
                    static var __mergedSources: [any ApolloAPI.SelectionSet.Type] { [
                      GitHubActor.self,
                      GitHubActor.AsNode.self,
                      GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node.AsRenamedTitleEvent.Actor.self
                    ] }
                    static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                      GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node.AsRenamedTitleEvent.Actor.self,
                      GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node.AsRenamedTitleEvent.Actor.AsNode.self,
                      GitHubActor.self,
                      GitHubActor.AsNode.self
                    ] }

                    var login: String { __data["login"] }
                    var avatarUrl: GitHubAPI.URI { __data["avatarUrl"] }
                    var id: GitHubAPI.ID { __data["id"] }

                    struct Fragments: FragmentContainer {
                      let __data: DataDict
                      init(_dataDict: DataDict) { __data = _dataDict }

                      var gitHubActor: GitHubActor { _toFragment() }
                    }
                  }

                  /// Repository.PullRequest.TimelineItems.Node.AsRenamedTitleEvent.Actor.AsUser
                  nonisolated struct AsUser: GitHubAPI.InlineFragment, ApolloAPI.CompositeInlineFragment {
                    let __data: DataDict
                    init(_dataDict: DataDict) { __data = _dataDict }

                    typealias RootEntityType = GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node.AsRenamedTitleEvent.Actor
                    static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.User }
                    static var __mergedSources: [any ApolloAPI.SelectionSet.Type] { [
                      GitHubActor.self,
                      GitHubActor.AsNode.self,
                      GitHubActor.AsUser.self,
                      GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node.AsRenamedTitleEvent.Actor.self
                    ] }
                    static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                      GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node.AsRenamedTitleEvent.Actor.self,
                      GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node.AsRenamedTitleEvent.Actor.AsUser.self,
                      GitHubActor.self,
                      GitHubActor.AsNode.self,
                      GitHubActor.AsUser.self
                    ] }

                    var login: String { __data["login"] }
                    var avatarUrl: GitHubAPI.URI { __data["avatarUrl"] }
                    var id: GitHubAPI.ID { __data["id"] }
                    var name: String? { __data["name"] }

                    struct Fragments: FragmentContainer {
                      let __data: DataDict
                      init(_dataDict: DataDict) { __data = _dataDict }

                      var gitHubActor: GitHubActor { _toFragment() }
                    }
                  }

                  /// Repository.PullRequest.TimelineItems.Node.AsRenamedTitleEvent.Actor.AsOrganization
                  nonisolated struct AsOrganization: GitHubAPI.InlineFragment, ApolloAPI.CompositeInlineFragment {
                    let __data: DataDict
                    init(_dataDict: DataDict) { __data = _dataDict }

                    typealias RootEntityType = GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node.AsRenamedTitleEvent.Actor
                    static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.Organization }
                    static var __mergedSources: [any ApolloAPI.SelectionSet.Type] { [
                      GitHubActor.self,
                      GitHubActor.AsNode.self,
                      GitHubActor.AsOrganization.self,
                      GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node.AsRenamedTitleEvent.Actor.self
                    ] }
                    static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                      GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node.AsRenamedTitleEvent.Actor.self,
                      GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node.AsRenamedTitleEvent.Actor.AsOrganization.self,
                      GitHubActor.self,
                      GitHubActor.AsNode.self,
                      GitHubActor.AsOrganization.self
                    ] }

                    var login: String { __data["login"] }
                    var avatarUrl: GitHubAPI.URI { __data["avatarUrl"] }
                    var id: GitHubAPI.ID { __data["id"] }
                    var name: String? { __data["name"] }

                    struct Fragments: FragmentContainer {
                      let __data: DataDict
                      init(_dataDict: DataDict) { __data = _dataDict }

                      var gitHubActor: GitHubActor { _toFragment() }
                    }
                  }
                }
              }

              /// Repository.PullRequest.TimelineItems.Node.AsCrossReferencedEvent
              nonisolated struct AsCrossReferencedEvent: GitHubAPI.InlineFragment {
                let __data: DataDict
                init(_dataDict: DataDict) { __data = _dataDict }

                typealias RootEntityType = GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node
                static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.CrossReferencedEvent }
                static var __selections: [ApolloAPI.Selection] { [
                  .field("id", GitHubAPI.ID.self),
                  .field("createdAt", GitHubAPI.DateTime.self),
                  .field("actor", Actor?.self),
                  .field("source", Source.self),
                ] }
                static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                  GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node.self,
                  GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node.AsCrossReferencedEvent.self
                ] }

                var id: GitHubAPI.ID { __data["id"] }
                var createdAt: GitHubAPI.DateTime { __data["createdAt"] }
                var actor: Actor? { __data["actor"] }
                var source: Source { __data["source"] }

                /// Repository.PullRequest.TimelineItems.Node.AsCrossReferencedEvent.Actor
                nonisolated struct Actor: GitHubAPI.SelectionSet {
                  let __data: DataDict
                  init(_dataDict: DataDict) { __data = _dataDict }

                  static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Interfaces.Actor }
                  static var __selections: [ApolloAPI.Selection] { [
                    .field("__typename", String.self),
                    .fragment(GitHubActor.self),
                  ] }
                  static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                    GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node.AsCrossReferencedEvent.Actor.self,
                    GitHubActor.self
                  ] }

                  var login: String { __data["login"] }
                  var avatarUrl: GitHubAPI.URI { __data["avatarUrl"] }

                  var asNode: AsNode? { _asInlineFragment() }
                  var asUser: AsUser? { _asInlineFragment() }
                  var asOrganization: AsOrganization? { _asInlineFragment() }

                  struct Fragments: FragmentContainer {
                    let __data: DataDict
                    init(_dataDict: DataDict) { __data = _dataDict }

                    var gitHubActor: GitHubActor { _toFragment() }
                  }

                  /// Repository.PullRequest.TimelineItems.Node.AsCrossReferencedEvent.Actor.AsNode
                  nonisolated struct AsNode: GitHubAPI.InlineFragment, ApolloAPI.CompositeInlineFragment {
                    let __data: DataDict
                    init(_dataDict: DataDict) { __data = _dataDict }

                    typealias RootEntityType = GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node.AsCrossReferencedEvent.Actor
                    static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Interfaces.Node }
                    static var __mergedSources: [any ApolloAPI.SelectionSet.Type] { [
                      GitHubActor.self,
                      GitHubActor.AsNode.self,
                      GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node.AsCrossReferencedEvent.Actor.self
                    ] }
                    static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                      GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node.AsCrossReferencedEvent.Actor.self,
                      GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node.AsCrossReferencedEvent.Actor.AsNode.self,
                      GitHubActor.self,
                      GitHubActor.AsNode.self
                    ] }

                    var login: String { __data["login"] }
                    var avatarUrl: GitHubAPI.URI { __data["avatarUrl"] }
                    var id: GitHubAPI.ID { __data["id"] }

                    struct Fragments: FragmentContainer {
                      let __data: DataDict
                      init(_dataDict: DataDict) { __data = _dataDict }

                      var gitHubActor: GitHubActor { _toFragment() }
                    }
                  }

                  /// Repository.PullRequest.TimelineItems.Node.AsCrossReferencedEvent.Actor.AsUser
                  nonisolated struct AsUser: GitHubAPI.InlineFragment, ApolloAPI.CompositeInlineFragment {
                    let __data: DataDict
                    init(_dataDict: DataDict) { __data = _dataDict }

                    typealias RootEntityType = GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node.AsCrossReferencedEvent.Actor
                    static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.User }
                    static var __mergedSources: [any ApolloAPI.SelectionSet.Type] { [
                      GitHubActor.self,
                      GitHubActor.AsNode.self,
                      GitHubActor.AsUser.self,
                      GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node.AsCrossReferencedEvent.Actor.self
                    ] }
                    static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                      GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node.AsCrossReferencedEvent.Actor.self,
                      GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node.AsCrossReferencedEvent.Actor.AsUser.self,
                      GitHubActor.self,
                      GitHubActor.AsNode.self,
                      GitHubActor.AsUser.self
                    ] }

                    var login: String { __data["login"] }
                    var avatarUrl: GitHubAPI.URI { __data["avatarUrl"] }
                    var id: GitHubAPI.ID { __data["id"] }
                    var name: String? { __data["name"] }

                    struct Fragments: FragmentContainer {
                      let __data: DataDict
                      init(_dataDict: DataDict) { __data = _dataDict }

                      var gitHubActor: GitHubActor { _toFragment() }
                    }
                  }

                  /// Repository.PullRequest.TimelineItems.Node.AsCrossReferencedEvent.Actor.AsOrganization
                  nonisolated struct AsOrganization: GitHubAPI.InlineFragment, ApolloAPI.CompositeInlineFragment {
                    let __data: DataDict
                    init(_dataDict: DataDict) { __data = _dataDict }

                    typealias RootEntityType = GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node.AsCrossReferencedEvent.Actor
                    static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.Organization }
                    static var __mergedSources: [any ApolloAPI.SelectionSet.Type] { [
                      GitHubActor.self,
                      GitHubActor.AsNode.self,
                      GitHubActor.AsOrganization.self,
                      GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node.AsCrossReferencedEvent.Actor.self
                    ] }
                    static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                      GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node.AsCrossReferencedEvent.Actor.self,
                      GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node.AsCrossReferencedEvent.Actor.AsOrganization.self,
                      GitHubActor.self,
                      GitHubActor.AsNode.self,
                      GitHubActor.AsOrganization.self
                    ] }

                    var login: String { __data["login"] }
                    var avatarUrl: GitHubAPI.URI { __data["avatarUrl"] }
                    var id: GitHubAPI.ID { __data["id"] }
                    var name: String? { __data["name"] }

                    struct Fragments: FragmentContainer {
                      let __data: DataDict
                      init(_dataDict: DataDict) { __data = _dataDict }

                      var gitHubActor: GitHubActor { _toFragment() }
                    }
                  }
                }

                /// Repository.PullRequest.TimelineItems.Node.AsCrossReferencedEvent.Source
                nonisolated struct Source: GitHubAPI.SelectionSet {
                  let __data: DataDict
                  init(_dataDict: DataDict) { __data = _dataDict }

                  static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Unions.ReferencedSubject }
                  static var __selections: [ApolloAPI.Selection] { [
                    .field("__typename", String.self),
                    .inlineFragment(AsPullRequest.self),
                    .inlineFragment(AsIssue.self),
                  ] }
                  static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                    GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node.AsCrossReferencedEvent.Source.self
                  ] }

                  var asPullRequest: AsPullRequest? { _asInlineFragment() }
                  var asIssue: AsIssue? { _asInlineFragment() }

                  /// Repository.PullRequest.TimelineItems.Node.AsCrossReferencedEvent.Source.AsPullRequest
                  nonisolated struct AsPullRequest: GitHubAPI.InlineFragment {
                    let __data: DataDict
                    init(_dataDict: DataDict) { __data = _dataDict }

                    typealias RootEntityType = GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node.AsCrossReferencedEvent.Source
                    static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.PullRequest }
                    static var __selections: [ApolloAPI.Selection] { [
                      .field("number", Int.self),
                      .field("state", alias: "pullRequestState", GraphQLEnum<GitHubAPI.PullRequestState>.self),
                      .field("title", String.self),
                      .field("repository", Repository.self),
                    ] }
                    static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                      GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node.AsCrossReferencedEvent.Source.self,
                      GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node.AsCrossReferencedEvent.Source.AsPullRequest.self
                    ] }

                    var number: Int { __data["number"] }
                    var pullRequestState: GraphQLEnum<GitHubAPI.PullRequestState> { __data["pullRequestState"] }
                    var title: String { __data["title"] }
                    var repository: Repository { __data["repository"] }

                    /// Repository.PullRequest.TimelineItems.Node.AsCrossReferencedEvent.Source.AsPullRequest.Repository
                    nonisolated struct Repository: GitHubAPI.SelectionSet {
                      let __data: DataDict
                      init(_dataDict: DataDict) { __data = _dataDict }

                      static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.Repository }
                      static var __selections: [ApolloAPI.Selection] { [
                        .field("__typename", String.self),
                        .fragment(GitHubRepositoryIdentity.self),
                      ] }
                      static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                        GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node.AsCrossReferencedEvent.Source.AsPullRequest.Repository.self,
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
                  }

                  /// Repository.PullRequest.TimelineItems.Node.AsCrossReferencedEvent.Source.AsIssue
                  nonisolated struct AsIssue: GitHubAPI.InlineFragment {
                    let __data: DataDict
                    init(_dataDict: DataDict) { __data = _dataDict }

                    typealias RootEntityType = GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node.AsCrossReferencedEvent.Source
                    static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.Issue }
                    static var __selections: [ApolloAPI.Selection] { [
                      .field("number", Int.self),
                      .field("state", alias: "issueState", GraphQLEnum<GitHubAPI.IssueState>.self),
                      .field("title", String.self),
                      .field("repository", Repository.self),
                    ] }
                    static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                      GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node.AsCrossReferencedEvent.Source.self,
                      GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node.AsCrossReferencedEvent.Source.AsIssue.self
                    ] }

                    var number: Int { __data["number"] }
                    var issueState: GraphQLEnum<GitHubAPI.IssueState> { __data["issueState"] }
                    var title: String { __data["title"] }
                    var repository: Repository { __data["repository"] }

                    /// Repository.PullRequest.TimelineItems.Node.AsCrossReferencedEvent.Source.AsIssue.Repository
                    nonisolated struct Repository: GitHubAPI.SelectionSet {
                      let __data: DataDict
                      init(_dataDict: DataDict) { __data = _dataDict }

                      static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.Repository }
                      static var __selections: [ApolloAPI.Selection] { [
                        .field("__typename", String.self),
                        .fragment(GitHubRepositoryIdentity.self),
                      ] }
                      static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                        GitHubPullRequestDetailsQuery.Data.Repository.PullRequest.TimelineItems.Node.AsCrossReferencedEvent.Source.AsIssue.Repository.self,
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
                  }
                }
              }
            }
          }

          typealias Author = GitHubPullRequestSummary.Author

          typealias HeadRepository = GitHubPullRequestSummary.HeadRepository

          typealias BaseRepository = GitHubPullRequestSummary.BaseRepository

          typealias Labels = GitHubPullRequestSummary.Labels
        }
      }
    }
  }

}
