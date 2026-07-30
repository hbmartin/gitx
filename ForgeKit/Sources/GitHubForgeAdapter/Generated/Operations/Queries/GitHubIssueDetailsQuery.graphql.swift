// @generated
// This file was automatically generated and should not be edited.

import ApolloAPI
@_spi(Execution) @_spi(Unsafe) import ApolloAPI

extension GitHubAPI {
  nonisolated struct GitHubIssueDetailsQuery: GraphQLQuery {
    static let operationName: String = "GitHubIssueDetails"
    static let operationDocument: ApolloAPI.OperationDocument = .init(
      definition: .init(
        #"query GitHubIssueDetails($owner: String!, $name: String!, $number: Int!, $timelineFirst: Int!, $timelineAfter: String) { repository(owner: $owner, name: $name) { __typename id issue(number: $number) { __typename ...GitHubIssueSummary body assignedActors(first: 100) { __typename totalCount pageInfo { __typename ...GitHubPageInfo } nodes { __typename ...GitHubAssignee } } milestone { __typename ...GitHubMilestone } participants(first: 100) { __typename totalCount pageInfo { __typename ...GitHubPageInfo } nodes { __typename ...GitHubActor } } timelineItems( first: $timelineFirst after: $timelineAfter itemTypes: [ ISSUE_COMMENT CLOSED_EVENT REOPENED_EVENT ASSIGNED_EVENT UNASSIGNED_EVENT LABELED_EVENT UNLABELED_EVENT MILESTONED_EVENT DEMILESTONED_EVENT RENAMED_TITLE_EVENT CROSS_REFERENCED_EVENT ] ) { __typename totalCount pageInfo { __typename ...GitHubPageInfo } nodes { __typename ... on IssueComment { ...GitHubIssueComment } ... on ClosedEvent { id createdAt actor { __typename ...GitHubActor } } ... on ReopenedEvent { id createdAt actor { __typename ...GitHubActor } } ... on AssignedEvent { id createdAt actor { __typename ...GitHubActor } assignee { __typename ...GitHubAssignee } } ... on UnassignedEvent { id createdAt actor { __typename ...GitHubActor } assignee { __typename ...GitHubAssignee } } ... on LabeledEvent { id createdAt actor { __typename ...GitHubActor } label { __typename ...GitHubLabel } } ... on UnlabeledEvent { id createdAt actor { __typename ...GitHubActor } label { __typename ...GitHubLabel } } ... on MilestonedEvent { id createdAt milestoneTitle actor { __typename ...GitHubActor } } ... on DemilestonedEvent { id createdAt milestoneTitle actor { __typename ...GitHubActor } } ... on RenamedTitleEvent { id createdAt previousTitle currentTitle actor { __typename ...GitHubActor } } ... on CrossReferencedEvent { id createdAt actor { __typename ...GitHubActor } source { __typename ... on PullRequest { number pullRequestState: state title repository { __typename ...GitHubRepositoryIdentity } } ... on Issue { number issueState: state title repository { __typename ...GitHubRepositoryIdentity } } } } } } } } }"#,
        fragments: [GitHubActor.self, GitHubAssignee.self, GitHubIssueComment.self, GitHubIssueSummary.self, GitHubLabel.self, GitHubMilestone.self, GitHubPageInfo.self, GitHubRepositoryIdentity.self]
      ))

    public var owner: String
    public var name: String
    public var number: Int32
    public var timelineFirst: Int32
    public var timelineAfter: GraphQLNullable<String>

    public init(
      owner: String,
      name: String,
      number: Int32,
      timelineFirst: Int32,
      timelineAfter: GraphQLNullable<String>
    ) {
      self.owner = owner
      self.name = name
      self.number = number
      self.timelineFirst = timelineFirst
      self.timelineAfter = timelineAfter
    }

    @_spi(Unsafe) public var __variables: Variables? { [
      "owner": owner,
      "name": name,
      "number": number,
      "timelineFirst": timelineFirst,
      "timelineAfter": timelineAfter
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
        GitHubIssueDetailsQuery.Data.self
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
          .field("issue", Issue?.self, arguments: ["number": .variable("number")]),
        ] }
        static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
          GitHubIssueDetailsQuery.Data.Repository.self
        ] }

        var id: GitHubAPI.ID { __data["id"] }
        var issue: Issue? { __data["issue"] }

        /// Repository.Issue
        nonisolated struct Issue: GitHubAPI.SelectionSet {
          let __data: DataDict
          init(_dataDict: DataDict) { __data = _dataDict }

          static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.Issue }
          static var __selections: [ApolloAPI.Selection] { [
            .field("__typename", String.self),
            .field("body", String.self),
            .field("assignedActors", AssignedActors.self, arguments: ["first": 100]),
            .field("milestone", Milestone?.self),
            .field("participants", Participants.self, arguments: ["first": 100]),
            .field("timelineItems", TimelineItems.self, arguments: [
              "first": .variable("timelineFirst"),
              "after": .variable("timelineAfter"),
              "itemTypes": ["ISSUE_COMMENT", "CLOSED_EVENT", "REOPENED_EVENT", "ASSIGNED_EVENT", "UNASSIGNED_EVENT", "LABELED_EVENT", "UNLABELED_EVENT", "MILESTONED_EVENT", "DEMILESTONED_EVENT", "RENAMED_TITLE_EVENT", "CROSS_REFERENCED_EVENT"]
            ]),
            .fragment(GitHubIssueSummary.self),
          ] }
          static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
            GitHubIssueDetailsQuery.Data.Repository.Issue.self,
            GitHubIssueSummary.self
          ] }

          var body: String { __data["body"] }
          var assignedActors: AssignedActors { __data["assignedActors"] }
          var milestone: Milestone? { __data["milestone"] }
          var participants: Participants { __data["participants"] }
          var timelineItems: TimelineItems { __data["timelineItems"] }
          var id: GitHubAPI.ID { __data["id"] }
          var number: Int { __data["number"] }
          var issueState: GraphQLEnum<GitHubAPI.IssueState> { __data["issueState"] }
          var title: String { __data["title"] }
          var createdAt: GitHubAPI.DateTime { __data["createdAt"] }
          var updatedAt: GitHubAPI.DateTime { __data["updatedAt"] }
          var closedAt: GitHubAPI.DateTime? { __data["closedAt"] }
          var author: Author? { __data["author"] }
          var labels: Labels? { __data["labels"] }

          struct Fragments: FragmentContainer {
            let __data: DataDict
            init(_dataDict: DataDict) { __data = _dataDict }

            var gitHubIssueSummary: GitHubIssueSummary { _toFragment() }
          }

          /// Repository.Issue.AssignedActors
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
              GitHubIssueDetailsQuery.Data.Repository.Issue.AssignedActors.self
            ] }

            var totalCount: Int { __data["totalCount"] }
            var pageInfo: PageInfo { __data["pageInfo"] }
            var nodes: [Node?]? { __data["nodes"] }

            /// Repository.Issue.AssignedActors.PageInfo
            nonisolated struct PageInfo: GitHubAPI.SelectionSet {
              let __data: DataDict
              init(_dataDict: DataDict) { __data = _dataDict }

              static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.PageInfo }
              static var __selections: [ApolloAPI.Selection] { [
                .field("__typename", String.self),
                .fragment(GitHubPageInfo.self),
              ] }
              static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                GitHubIssueDetailsQuery.Data.Repository.Issue.AssignedActors.PageInfo.self,
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

            /// Repository.Issue.AssignedActors.Node
            nonisolated struct Node: GitHubAPI.SelectionSet {
              let __data: DataDict
              init(_dataDict: DataDict) { __data = _dataDict }

              static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Unions.Assignee }
              static var __selections: [ApolloAPI.Selection] { [
                .field("__typename", String.self),
                .fragment(GitHubAssignee.self),
              ] }
              static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                GitHubIssueDetailsQuery.Data.Repository.Issue.AssignedActors.Node.self
              ] }

              var asActor: AsActor? { _asInlineFragment() }
              var asMannequin: AsMannequin? { _asInlineFragment() }

              struct Fragments: FragmentContainer {
                let __data: DataDict
                init(_dataDict: DataDict) { __data = _dataDict }

                var gitHubAssignee: GitHubAssignee { _toFragment() }
              }

              /// Repository.Issue.AssignedActors.Node.AsActor
              nonisolated struct AsActor: GitHubAPI.InlineFragment, ApolloAPI.CompositeInlineFragment {
                let __data: DataDict
                init(_dataDict: DataDict) { __data = _dataDict }

                typealias RootEntityType = GitHubIssueDetailsQuery.Data.Repository.Issue.AssignedActors.Node
                static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Interfaces.Actor }
                static var __mergedSources: [any ApolloAPI.SelectionSet.Type] { [
                  GitHubIssueDetailsQuery.Data.Repository.Issue.AssignedActors.Node.self,
                  GitHubAssignee.AsActor.self,
                  GitHubActor.self
                ] }
                static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                  GitHubIssueDetailsQuery.Data.Repository.Issue.AssignedActors.Node.self,
                  GitHubIssueDetailsQuery.Data.Repository.Issue.AssignedActors.Node.AsActor.self,
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

              /// Repository.Issue.AssignedActors.Node.AsMannequin
              nonisolated struct AsMannequin: GitHubAPI.InlineFragment, ApolloAPI.CompositeInlineFragment {
                let __data: DataDict
                init(_dataDict: DataDict) { __data = _dataDict }

                typealias RootEntityType = GitHubIssueDetailsQuery.Data.Repository.Issue.AssignedActors.Node
                static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.Mannequin }
                static var __mergedSources: [any ApolloAPI.SelectionSet.Type] { [
                  GitHubIssueDetailsQuery.Data.Repository.Issue.AssignedActors.Node.self,
                  GitHubAssignee.AsActor.self,
                  GitHubActor.self,
                  GitHubActor.AsNode.self,
                  GitHubAssignee.AsMannequin.self
                ] }
                static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                  GitHubIssueDetailsQuery.Data.Repository.Issue.AssignedActors.Node.self,
                  GitHubIssueDetailsQuery.Data.Repository.Issue.AssignedActors.Node.AsMannequin.self,
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

          /// Repository.Issue.Milestone
          nonisolated struct Milestone: GitHubAPI.SelectionSet {
            let __data: DataDict
            init(_dataDict: DataDict) { __data = _dataDict }

            static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.Milestone }
            static var __selections: [ApolloAPI.Selection] { [
              .field("__typename", String.self),
              .fragment(GitHubMilestone.self),
            ] }
            static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
              GitHubIssueDetailsQuery.Data.Repository.Issue.Milestone.self,
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

          /// Repository.Issue.Participants
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
              GitHubIssueDetailsQuery.Data.Repository.Issue.Participants.self
            ] }

            var totalCount: Int { __data["totalCount"] }
            var pageInfo: PageInfo { __data["pageInfo"] }
            var nodes: [Node?]? { __data["nodes"] }

            /// Repository.Issue.Participants.PageInfo
            nonisolated struct PageInfo: GitHubAPI.SelectionSet {
              let __data: DataDict
              init(_dataDict: DataDict) { __data = _dataDict }

              static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.PageInfo }
              static var __selections: [ApolloAPI.Selection] { [
                .field("__typename", String.self),
                .fragment(GitHubPageInfo.self),
              ] }
              static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                GitHubIssueDetailsQuery.Data.Repository.Issue.Participants.PageInfo.self,
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

            /// Repository.Issue.Participants.Node
            nonisolated struct Node: GitHubAPI.SelectionSet {
              let __data: DataDict
              init(_dataDict: DataDict) { __data = _dataDict }

              static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.User }
              static var __selections: [ApolloAPI.Selection] { [
                .field("__typename", String.self),
                .fragment(GitHubActor.self),
              ] }
              static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                GitHubIssueDetailsQuery.Data.Repository.Issue.Participants.Node.self,
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

              /// Repository.Issue.Participants.Node.AsOrganization
              nonisolated struct AsOrganization: GitHubAPI.InlineFragment, ApolloAPI.CompositeInlineFragment {
                let __data: DataDict
                init(_dataDict: DataDict) { __data = _dataDict }

                typealias RootEntityType = GitHubIssueDetailsQuery.Data.Repository.Issue.Participants.Node
                static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.Organization }
                static var __mergedSources: [any ApolloAPI.SelectionSet.Type] { [
                  GitHubIssueDetailsQuery.Data.Repository.Issue.Participants.Node.self,
                  GitHubActor.self,
                  GitHubActor.AsNode.self,
                  GitHubActor.AsUser.self,
                  GitHubActor.AsOrganization.self
                ] }
                static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                  GitHubIssueDetailsQuery.Data.Repository.Issue.Participants.Node.self,
                  GitHubIssueDetailsQuery.Data.Repository.Issue.Participants.Node.AsOrganization.self,
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

          /// Repository.Issue.TimelineItems
          nonisolated struct TimelineItems: GitHubAPI.SelectionSet {
            let __data: DataDict
            init(_dataDict: DataDict) { __data = _dataDict }

            static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.IssueTimelineItemsConnection }
            static var __selections: [ApolloAPI.Selection] { [
              .field("__typename", String.self),
              .field("totalCount", Int.self),
              .field("pageInfo", PageInfo.self),
              .field("nodes", [Node?]?.self),
            ] }
            static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
              GitHubIssueDetailsQuery.Data.Repository.Issue.TimelineItems.self
            ] }

            var totalCount: Int { __data["totalCount"] }
            var pageInfo: PageInfo { __data["pageInfo"] }
            var nodes: [Node?]? { __data["nodes"] }

            /// Repository.Issue.TimelineItems.PageInfo
            nonisolated struct PageInfo: GitHubAPI.SelectionSet {
              let __data: DataDict
              init(_dataDict: DataDict) { __data = _dataDict }

              static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.PageInfo }
              static var __selections: [ApolloAPI.Selection] { [
                .field("__typename", String.self),
                .fragment(GitHubPageInfo.self),
              ] }
              static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                GitHubIssueDetailsQuery.Data.Repository.Issue.TimelineItems.PageInfo.self,
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

            /// Repository.Issue.TimelineItems.Node
            nonisolated struct Node: GitHubAPI.SelectionSet {
              let __data: DataDict
              init(_dataDict: DataDict) { __data = _dataDict }

              static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Unions.IssueTimelineItems }
              static var __selections: [ApolloAPI.Selection] { [
                .field("__typename", String.self),
                .inlineFragment(AsIssueComment.self),
                .inlineFragment(AsClosedEvent.self),
                .inlineFragment(AsReopenedEvent.self),
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
                GitHubIssueDetailsQuery.Data.Repository.Issue.TimelineItems.Node.self
              ] }

              var asIssueComment: AsIssueComment? { _asInlineFragment() }
              var asClosedEvent: AsClosedEvent? { _asInlineFragment() }
              var asReopenedEvent: AsReopenedEvent? { _asInlineFragment() }
              var asAssignedEvent: AsAssignedEvent? { _asInlineFragment() }
              var asUnassignedEvent: AsUnassignedEvent? { _asInlineFragment() }
              var asLabeledEvent: AsLabeledEvent? { _asInlineFragment() }
              var asUnlabeledEvent: AsUnlabeledEvent? { _asInlineFragment() }
              var asMilestonedEvent: AsMilestonedEvent? { _asInlineFragment() }
              var asDemilestonedEvent: AsDemilestonedEvent? { _asInlineFragment() }
              var asRenamedTitleEvent: AsRenamedTitleEvent? { _asInlineFragment() }
              var asCrossReferencedEvent: AsCrossReferencedEvent? { _asInlineFragment() }

              /// Repository.Issue.TimelineItems.Node.AsIssueComment
              nonisolated struct AsIssueComment: GitHubAPI.InlineFragment {
                let __data: DataDict
                init(_dataDict: DataDict) { __data = _dataDict }

                typealias RootEntityType = GitHubIssueDetailsQuery.Data.Repository.Issue.TimelineItems.Node
                static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.IssueComment }
                static var __selections: [ApolloAPI.Selection] { [
                  .fragment(GitHubIssueComment.self),
                ] }
                static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                  GitHubIssueDetailsQuery.Data.Repository.Issue.TimelineItems.Node.self,
                  GitHubIssueDetailsQuery.Data.Repository.Issue.TimelineItems.Node.AsIssueComment.self,
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

              /// Repository.Issue.TimelineItems.Node.AsClosedEvent
              nonisolated struct AsClosedEvent: GitHubAPI.InlineFragment {
                let __data: DataDict
                init(_dataDict: DataDict) { __data = _dataDict }

                typealias RootEntityType = GitHubIssueDetailsQuery.Data.Repository.Issue.TimelineItems.Node
                static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.ClosedEvent }
                static var __selections: [ApolloAPI.Selection] { [
                  .field("id", GitHubAPI.ID.self),
                  .field("createdAt", GitHubAPI.DateTime.self),
                  .field("actor", Actor?.self),
                ] }
                static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                  GitHubIssueDetailsQuery.Data.Repository.Issue.TimelineItems.Node.self,
                  GitHubIssueDetailsQuery.Data.Repository.Issue.TimelineItems.Node.AsClosedEvent.self
                ] }

                var id: GitHubAPI.ID { __data["id"] }
                var createdAt: GitHubAPI.DateTime { __data["createdAt"] }
                var actor: Actor? { __data["actor"] }

                /// Repository.Issue.TimelineItems.Node.AsClosedEvent.Actor
                nonisolated struct Actor: GitHubAPI.SelectionSet {
                  let __data: DataDict
                  init(_dataDict: DataDict) { __data = _dataDict }

                  static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Interfaces.Actor }
                  static var __selections: [ApolloAPI.Selection] { [
                    .field("__typename", String.self),
                    .fragment(GitHubActor.self),
                  ] }
                  static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                    GitHubIssueDetailsQuery.Data.Repository.Issue.TimelineItems.Node.AsClosedEvent.Actor.self,
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

                  /// Repository.Issue.TimelineItems.Node.AsClosedEvent.Actor.AsNode
                  nonisolated struct AsNode: GitHubAPI.InlineFragment, ApolloAPI.CompositeInlineFragment {
                    let __data: DataDict
                    init(_dataDict: DataDict) { __data = _dataDict }

                    typealias RootEntityType = GitHubIssueDetailsQuery.Data.Repository.Issue.TimelineItems.Node.AsClosedEvent.Actor
                    static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Interfaces.Node }
                    static var __mergedSources: [any ApolloAPI.SelectionSet.Type] { [
                      GitHubActor.self,
                      GitHubActor.AsNode.self,
                      GitHubIssueDetailsQuery.Data.Repository.Issue.TimelineItems.Node.AsClosedEvent.Actor.self
                    ] }
                    static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                      GitHubIssueDetailsQuery.Data.Repository.Issue.TimelineItems.Node.AsClosedEvent.Actor.self,
                      GitHubIssueDetailsQuery.Data.Repository.Issue.TimelineItems.Node.AsClosedEvent.Actor.AsNode.self,
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

                  /// Repository.Issue.TimelineItems.Node.AsClosedEvent.Actor.AsUser
                  nonisolated struct AsUser: GitHubAPI.InlineFragment, ApolloAPI.CompositeInlineFragment {
                    let __data: DataDict
                    init(_dataDict: DataDict) { __data = _dataDict }

                    typealias RootEntityType = GitHubIssueDetailsQuery.Data.Repository.Issue.TimelineItems.Node.AsClosedEvent.Actor
                    static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.User }
                    static var __mergedSources: [any ApolloAPI.SelectionSet.Type] { [
                      GitHubActor.self,
                      GitHubActor.AsNode.self,
                      GitHubActor.AsUser.self,
                      GitHubIssueDetailsQuery.Data.Repository.Issue.TimelineItems.Node.AsClosedEvent.Actor.self
                    ] }
                    static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                      GitHubIssueDetailsQuery.Data.Repository.Issue.TimelineItems.Node.AsClosedEvent.Actor.self,
                      GitHubIssueDetailsQuery.Data.Repository.Issue.TimelineItems.Node.AsClosedEvent.Actor.AsUser.self,
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

                  /// Repository.Issue.TimelineItems.Node.AsClosedEvent.Actor.AsOrganization
                  nonisolated struct AsOrganization: GitHubAPI.InlineFragment, ApolloAPI.CompositeInlineFragment {
                    let __data: DataDict
                    init(_dataDict: DataDict) { __data = _dataDict }

                    typealias RootEntityType = GitHubIssueDetailsQuery.Data.Repository.Issue.TimelineItems.Node.AsClosedEvent.Actor
                    static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.Organization }
                    static var __mergedSources: [any ApolloAPI.SelectionSet.Type] { [
                      GitHubActor.self,
                      GitHubActor.AsNode.self,
                      GitHubActor.AsOrganization.self,
                      GitHubIssueDetailsQuery.Data.Repository.Issue.TimelineItems.Node.AsClosedEvent.Actor.self
                    ] }
                    static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                      GitHubIssueDetailsQuery.Data.Repository.Issue.TimelineItems.Node.AsClosedEvent.Actor.self,
                      GitHubIssueDetailsQuery.Data.Repository.Issue.TimelineItems.Node.AsClosedEvent.Actor.AsOrganization.self,
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

              /// Repository.Issue.TimelineItems.Node.AsReopenedEvent
              nonisolated struct AsReopenedEvent: GitHubAPI.InlineFragment {
                let __data: DataDict
                init(_dataDict: DataDict) { __data = _dataDict }

                typealias RootEntityType = GitHubIssueDetailsQuery.Data.Repository.Issue.TimelineItems.Node
                static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.ReopenedEvent }
                static var __selections: [ApolloAPI.Selection] { [
                  .field("id", GitHubAPI.ID.self),
                  .field("createdAt", GitHubAPI.DateTime.self),
                  .field("actor", Actor?.self),
                ] }
                static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                  GitHubIssueDetailsQuery.Data.Repository.Issue.TimelineItems.Node.self,
                  GitHubIssueDetailsQuery.Data.Repository.Issue.TimelineItems.Node.AsReopenedEvent.self
                ] }

                var id: GitHubAPI.ID { __data["id"] }
                var createdAt: GitHubAPI.DateTime { __data["createdAt"] }
                var actor: Actor? { __data["actor"] }

                /// Repository.Issue.TimelineItems.Node.AsReopenedEvent.Actor
                nonisolated struct Actor: GitHubAPI.SelectionSet {
                  let __data: DataDict
                  init(_dataDict: DataDict) { __data = _dataDict }

                  static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Interfaces.Actor }
                  static var __selections: [ApolloAPI.Selection] { [
                    .field("__typename", String.self),
                    .fragment(GitHubActor.self),
                  ] }
                  static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                    GitHubIssueDetailsQuery.Data.Repository.Issue.TimelineItems.Node.AsReopenedEvent.Actor.self,
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

                  /// Repository.Issue.TimelineItems.Node.AsReopenedEvent.Actor.AsNode
                  nonisolated struct AsNode: GitHubAPI.InlineFragment, ApolloAPI.CompositeInlineFragment {
                    let __data: DataDict
                    init(_dataDict: DataDict) { __data = _dataDict }

                    typealias RootEntityType = GitHubIssueDetailsQuery.Data.Repository.Issue.TimelineItems.Node.AsReopenedEvent.Actor
                    static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Interfaces.Node }
                    static var __mergedSources: [any ApolloAPI.SelectionSet.Type] { [
                      GitHubActor.self,
                      GitHubActor.AsNode.self,
                      GitHubIssueDetailsQuery.Data.Repository.Issue.TimelineItems.Node.AsReopenedEvent.Actor.self
                    ] }
                    static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                      GitHubIssueDetailsQuery.Data.Repository.Issue.TimelineItems.Node.AsReopenedEvent.Actor.self,
                      GitHubIssueDetailsQuery.Data.Repository.Issue.TimelineItems.Node.AsReopenedEvent.Actor.AsNode.self,
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

                  /// Repository.Issue.TimelineItems.Node.AsReopenedEvent.Actor.AsUser
                  nonisolated struct AsUser: GitHubAPI.InlineFragment, ApolloAPI.CompositeInlineFragment {
                    let __data: DataDict
                    init(_dataDict: DataDict) { __data = _dataDict }

                    typealias RootEntityType = GitHubIssueDetailsQuery.Data.Repository.Issue.TimelineItems.Node.AsReopenedEvent.Actor
                    static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.User }
                    static var __mergedSources: [any ApolloAPI.SelectionSet.Type] { [
                      GitHubActor.self,
                      GitHubActor.AsNode.self,
                      GitHubActor.AsUser.self,
                      GitHubIssueDetailsQuery.Data.Repository.Issue.TimelineItems.Node.AsReopenedEvent.Actor.self
                    ] }
                    static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                      GitHubIssueDetailsQuery.Data.Repository.Issue.TimelineItems.Node.AsReopenedEvent.Actor.self,
                      GitHubIssueDetailsQuery.Data.Repository.Issue.TimelineItems.Node.AsReopenedEvent.Actor.AsUser.self,
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

                  /// Repository.Issue.TimelineItems.Node.AsReopenedEvent.Actor.AsOrganization
                  nonisolated struct AsOrganization: GitHubAPI.InlineFragment, ApolloAPI.CompositeInlineFragment {
                    let __data: DataDict
                    init(_dataDict: DataDict) { __data = _dataDict }

                    typealias RootEntityType = GitHubIssueDetailsQuery.Data.Repository.Issue.TimelineItems.Node.AsReopenedEvent.Actor
                    static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.Organization }
                    static var __mergedSources: [any ApolloAPI.SelectionSet.Type] { [
                      GitHubActor.self,
                      GitHubActor.AsNode.self,
                      GitHubActor.AsOrganization.self,
                      GitHubIssueDetailsQuery.Data.Repository.Issue.TimelineItems.Node.AsReopenedEvent.Actor.self
                    ] }
                    static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                      GitHubIssueDetailsQuery.Data.Repository.Issue.TimelineItems.Node.AsReopenedEvent.Actor.self,
                      GitHubIssueDetailsQuery.Data.Repository.Issue.TimelineItems.Node.AsReopenedEvent.Actor.AsOrganization.self,
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

              /// Repository.Issue.TimelineItems.Node.AsAssignedEvent
              nonisolated struct AsAssignedEvent: GitHubAPI.InlineFragment {
                let __data: DataDict
                init(_dataDict: DataDict) { __data = _dataDict }

                typealias RootEntityType = GitHubIssueDetailsQuery.Data.Repository.Issue.TimelineItems.Node
                static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.AssignedEvent }
                static var __selections: [ApolloAPI.Selection] { [
                  .field("id", GitHubAPI.ID.self),
                  .field("createdAt", GitHubAPI.DateTime.self),
                  .field("actor", Actor?.self),
                  .field("assignee", Assignee?.self),
                ] }
                static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                  GitHubIssueDetailsQuery.Data.Repository.Issue.TimelineItems.Node.self,
                  GitHubIssueDetailsQuery.Data.Repository.Issue.TimelineItems.Node.AsAssignedEvent.self
                ] }

                var id: GitHubAPI.ID { __data["id"] }
                var createdAt: GitHubAPI.DateTime { __data["createdAt"] }
                var actor: Actor? { __data["actor"] }
                var assignee: Assignee? { __data["assignee"] }

                /// Repository.Issue.TimelineItems.Node.AsAssignedEvent.Actor
                nonisolated struct Actor: GitHubAPI.SelectionSet {
                  let __data: DataDict
                  init(_dataDict: DataDict) { __data = _dataDict }

                  static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Interfaces.Actor }
                  static var __selections: [ApolloAPI.Selection] { [
                    .field("__typename", String.self),
                    .fragment(GitHubActor.self),
                  ] }
                  static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                    GitHubIssueDetailsQuery.Data.Repository.Issue.TimelineItems.Node.AsAssignedEvent.Actor.self,
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

                  /// Repository.Issue.TimelineItems.Node.AsAssignedEvent.Actor.AsNode
                  nonisolated struct AsNode: GitHubAPI.InlineFragment, ApolloAPI.CompositeInlineFragment {
                    let __data: DataDict
                    init(_dataDict: DataDict) { __data = _dataDict }

                    typealias RootEntityType = GitHubIssueDetailsQuery.Data.Repository.Issue.TimelineItems.Node.AsAssignedEvent.Actor
                    static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Interfaces.Node }
                    static var __mergedSources: [any ApolloAPI.SelectionSet.Type] { [
                      GitHubActor.self,
                      GitHubActor.AsNode.self,
                      GitHubIssueDetailsQuery.Data.Repository.Issue.TimelineItems.Node.AsAssignedEvent.Actor.self
                    ] }
                    static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                      GitHubIssueDetailsQuery.Data.Repository.Issue.TimelineItems.Node.AsAssignedEvent.Actor.self,
                      GitHubIssueDetailsQuery.Data.Repository.Issue.TimelineItems.Node.AsAssignedEvent.Actor.AsNode.self,
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

                  /// Repository.Issue.TimelineItems.Node.AsAssignedEvent.Actor.AsUser
                  nonisolated struct AsUser: GitHubAPI.InlineFragment, ApolloAPI.CompositeInlineFragment {
                    let __data: DataDict
                    init(_dataDict: DataDict) { __data = _dataDict }

                    typealias RootEntityType = GitHubIssueDetailsQuery.Data.Repository.Issue.TimelineItems.Node.AsAssignedEvent.Actor
                    static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.User }
                    static var __mergedSources: [any ApolloAPI.SelectionSet.Type] { [
                      GitHubActor.self,
                      GitHubActor.AsNode.self,
                      GitHubActor.AsUser.self,
                      GitHubIssueDetailsQuery.Data.Repository.Issue.TimelineItems.Node.AsAssignedEvent.Actor.self
                    ] }
                    static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                      GitHubIssueDetailsQuery.Data.Repository.Issue.TimelineItems.Node.AsAssignedEvent.Actor.self,
                      GitHubIssueDetailsQuery.Data.Repository.Issue.TimelineItems.Node.AsAssignedEvent.Actor.AsUser.self,
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

                  /// Repository.Issue.TimelineItems.Node.AsAssignedEvent.Actor.AsOrganization
                  nonisolated struct AsOrganization: GitHubAPI.InlineFragment, ApolloAPI.CompositeInlineFragment {
                    let __data: DataDict
                    init(_dataDict: DataDict) { __data = _dataDict }

                    typealias RootEntityType = GitHubIssueDetailsQuery.Data.Repository.Issue.TimelineItems.Node.AsAssignedEvent.Actor
                    static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.Organization }
                    static var __mergedSources: [any ApolloAPI.SelectionSet.Type] { [
                      GitHubActor.self,
                      GitHubActor.AsNode.self,
                      GitHubActor.AsOrganization.self,
                      GitHubIssueDetailsQuery.Data.Repository.Issue.TimelineItems.Node.AsAssignedEvent.Actor.self
                    ] }
                    static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                      GitHubIssueDetailsQuery.Data.Repository.Issue.TimelineItems.Node.AsAssignedEvent.Actor.self,
                      GitHubIssueDetailsQuery.Data.Repository.Issue.TimelineItems.Node.AsAssignedEvent.Actor.AsOrganization.self,
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

                /// Repository.Issue.TimelineItems.Node.AsAssignedEvent.Assignee
                nonisolated struct Assignee: GitHubAPI.SelectionSet {
                  let __data: DataDict
                  init(_dataDict: DataDict) { __data = _dataDict }

                  static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Unions.Assignee }
                  static var __selections: [ApolloAPI.Selection] { [
                    .field("__typename", String.self),
                    .fragment(GitHubAssignee.self),
                  ] }
                  static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                    GitHubIssueDetailsQuery.Data.Repository.Issue.TimelineItems.Node.AsAssignedEvent.Assignee.self
                  ] }

                  var asActor: AsActor? { _asInlineFragment() }
                  var asMannequin: AsMannequin? { _asInlineFragment() }

                  struct Fragments: FragmentContainer {
                    let __data: DataDict
                    init(_dataDict: DataDict) { __data = _dataDict }

                    var gitHubAssignee: GitHubAssignee { _toFragment() }
                  }

                  /// Repository.Issue.TimelineItems.Node.AsAssignedEvent.Assignee.AsActor
                  nonisolated struct AsActor: GitHubAPI.InlineFragment, ApolloAPI.CompositeInlineFragment {
                    let __data: DataDict
                    init(_dataDict: DataDict) { __data = _dataDict }

                    typealias RootEntityType = GitHubIssueDetailsQuery.Data.Repository.Issue.TimelineItems.Node.AsAssignedEvent.Assignee
                    static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Interfaces.Actor }
                    static var __mergedSources: [any ApolloAPI.SelectionSet.Type] { [
                      GitHubAssignee.AsActor.self,
                      GitHubActor.self,
                      GitHubIssueDetailsQuery.Data.Repository.Issue.TimelineItems.Node.AsAssignedEvent.Assignee.self
                    ] }
                    static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                      GitHubIssueDetailsQuery.Data.Repository.Issue.TimelineItems.Node.AsAssignedEvent.Assignee.self,
                      GitHubIssueDetailsQuery.Data.Repository.Issue.TimelineItems.Node.AsAssignedEvent.Assignee.AsActor.self,
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

                  /// Repository.Issue.TimelineItems.Node.AsAssignedEvent.Assignee.AsMannequin
                  nonisolated struct AsMannequin: GitHubAPI.InlineFragment, ApolloAPI.CompositeInlineFragment {
                    let __data: DataDict
                    init(_dataDict: DataDict) { __data = _dataDict }

                    typealias RootEntityType = GitHubIssueDetailsQuery.Data.Repository.Issue.TimelineItems.Node.AsAssignedEvent.Assignee
                    static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.Mannequin }
                    static var __mergedSources: [any ApolloAPI.SelectionSet.Type] { [
                      GitHubAssignee.AsActor.self,
                      GitHubActor.self,
                      GitHubActor.AsNode.self,
                      GitHubAssignee.AsMannequin.self,
                      GitHubIssueDetailsQuery.Data.Repository.Issue.TimelineItems.Node.AsAssignedEvent.Assignee.self
                    ] }
                    static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                      GitHubIssueDetailsQuery.Data.Repository.Issue.TimelineItems.Node.AsAssignedEvent.Assignee.self,
                      GitHubIssueDetailsQuery.Data.Repository.Issue.TimelineItems.Node.AsAssignedEvent.Assignee.AsMannequin.self,
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

              /// Repository.Issue.TimelineItems.Node.AsUnassignedEvent
              nonisolated struct AsUnassignedEvent: GitHubAPI.InlineFragment {
                let __data: DataDict
                init(_dataDict: DataDict) { __data = _dataDict }

                typealias RootEntityType = GitHubIssueDetailsQuery.Data.Repository.Issue.TimelineItems.Node
                static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.UnassignedEvent }
                static var __selections: [ApolloAPI.Selection] { [
                  .field("id", GitHubAPI.ID.self),
                  .field("createdAt", GitHubAPI.DateTime.self),
                  .field("actor", Actor?.self),
                  .field("assignee", Assignee?.self),
                ] }
                static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                  GitHubIssueDetailsQuery.Data.Repository.Issue.TimelineItems.Node.self,
                  GitHubIssueDetailsQuery.Data.Repository.Issue.TimelineItems.Node.AsUnassignedEvent.self
                ] }

                var id: GitHubAPI.ID { __data["id"] }
                var createdAt: GitHubAPI.DateTime { __data["createdAt"] }
                var actor: Actor? { __data["actor"] }
                var assignee: Assignee? { __data["assignee"] }

                /// Repository.Issue.TimelineItems.Node.AsUnassignedEvent.Actor
                nonisolated struct Actor: GitHubAPI.SelectionSet {
                  let __data: DataDict
                  init(_dataDict: DataDict) { __data = _dataDict }

                  static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Interfaces.Actor }
                  static var __selections: [ApolloAPI.Selection] { [
                    .field("__typename", String.self),
                    .fragment(GitHubActor.self),
                  ] }
                  static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                    GitHubIssueDetailsQuery.Data.Repository.Issue.TimelineItems.Node.AsUnassignedEvent.Actor.self,
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

                  /// Repository.Issue.TimelineItems.Node.AsUnassignedEvent.Actor.AsNode
                  nonisolated struct AsNode: GitHubAPI.InlineFragment, ApolloAPI.CompositeInlineFragment {
                    let __data: DataDict
                    init(_dataDict: DataDict) { __data = _dataDict }

                    typealias RootEntityType = GitHubIssueDetailsQuery.Data.Repository.Issue.TimelineItems.Node.AsUnassignedEvent.Actor
                    static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Interfaces.Node }
                    static var __mergedSources: [any ApolloAPI.SelectionSet.Type] { [
                      GitHubActor.self,
                      GitHubActor.AsNode.self,
                      GitHubIssueDetailsQuery.Data.Repository.Issue.TimelineItems.Node.AsUnassignedEvent.Actor.self
                    ] }
                    static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                      GitHubIssueDetailsQuery.Data.Repository.Issue.TimelineItems.Node.AsUnassignedEvent.Actor.self,
                      GitHubIssueDetailsQuery.Data.Repository.Issue.TimelineItems.Node.AsUnassignedEvent.Actor.AsNode.self,
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

                  /// Repository.Issue.TimelineItems.Node.AsUnassignedEvent.Actor.AsUser
                  nonisolated struct AsUser: GitHubAPI.InlineFragment, ApolloAPI.CompositeInlineFragment {
                    let __data: DataDict
                    init(_dataDict: DataDict) { __data = _dataDict }

                    typealias RootEntityType = GitHubIssueDetailsQuery.Data.Repository.Issue.TimelineItems.Node.AsUnassignedEvent.Actor
                    static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.User }
                    static var __mergedSources: [any ApolloAPI.SelectionSet.Type] { [
                      GitHubActor.self,
                      GitHubActor.AsNode.self,
                      GitHubActor.AsUser.self,
                      GitHubIssueDetailsQuery.Data.Repository.Issue.TimelineItems.Node.AsUnassignedEvent.Actor.self
                    ] }
                    static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                      GitHubIssueDetailsQuery.Data.Repository.Issue.TimelineItems.Node.AsUnassignedEvent.Actor.self,
                      GitHubIssueDetailsQuery.Data.Repository.Issue.TimelineItems.Node.AsUnassignedEvent.Actor.AsUser.self,
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

                  /// Repository.Issue.TimelineItems.Node.AsUnassignedEvent.Actor.AsOrganization
                  nonisolated struct AsOrganization: GitHubAPI.InlineFragment, ApolloAPI.CompositeInlineFragment {
                    let __data: DataDict
                    init(_dataDict: DataDict) { __data = _dataDict }

                    typealias RootEntityType = GitHubIssueDetailsQuery.Data.Repository.Issue.TimelineItems.Node.AsUnassignedEvent.Actor
                    static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.Organization }
                    static var __mergedSources: [any ApolloAPI.SelectionSet.Type] { [
                      GitHubActor.self,
                      GitHubActor.AsNode.self,
                      GitHubActor.AsOrganization.self,
                      GitHubIssueDetailsQuery.Data.Repository.Issue.TimelineItems.Node.AsUnassignedEvent.Actor.self
                    ] }
                    static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                      GitHubIssueDetailsQuery.Data.Repository.Issue.TimelineItems.Node.AsUnassignedEvent.Actor.self,
                      GitHubIssueDetailsQuery.Data.Repository.Issue.TimelineItems.Node.AsUnassignedEvent.Actor.AsOrganization.self,
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

                /// Repository.Issue.TimelineItems.Node.AsUnassignedEvent.Assignee
                nonisolated struct Assignee: GitHubAPI.SelectionSet {
                  let __data: DataDict
                  init(_dataDict: DataDict) { __data = _dataDict }

                  static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Unions.Assignee }
                  static var __selections: [ApolloAPI.Selection] { [
                    .field("__typename", String.self),
                    .fragment(GitHubAssignee.self),
                  ] }
                  static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                    GitHubIssueDetailsQuery.Data.Repository.Issue.TimelineItems.Node.AsUnassignedEvent.Assignee.self
                  ] }

                  var asActor: AsActor? { _asInlineFragment() }
                  var asMannequin: AsMannequin? { _asInlineFragment() }

                  struct Fragments: FragmentContainer {
                    let __data: DataDict
                    init(_dataDict: DataDict) { __data = _dataDict }

                    var gitHubAssignee: GitHubAssignee { _toFragment() }
                  }

                  /// Repository.Issue.TimelineItems.Node.AsUnassignedEvent.Assignee.AsActor
                  nonisolated struct AsActor: GitHubAPI.InlineFragment, ApolloAPI.CompositeInlineFragment {
                    let __data: DataDict
                    init(_dataDict: DataDict) { __data = _dataDict }

                    typealias RootEntityType = GitHubIssueDetailsQuery.Data.Repository.Issue.TimelineItems.Node.AsUnassignedEvent.Assignee
                    static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Interfaces.Actor }
                    static var __mergedSources: [any ApolloAPI.SelectionSet.Type] { [
                      GitHubAssignee.AsActor.self,
                      GitHubActor.self,
                      GitHubIssueDetailsQuery.Data.Repository.Issue.TimelineItems.Node.AsUnassignedEvent.Assignee.self
                    ] }
                    static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                      GitHubIssueDetailsQuery.Data.Repository.Issue.TimelineItems.Node.AsUnassignedEvent.Assignee.self,
                      GitHubIssueDetailsQuery.Data.Repository.Issue.TimelineItems.Node.AsUnassignedEvent.Assignee.AsActor.self,
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

                  /// Repository.Issue.TimelineItems.Node.AsUnassignedEvent.Assignee.AsMannequin
                  nonisolated struct AsMannequin: GitHubAPI.InlineFragment, ApolloAPI.CompositeInlineFragment {
                    let __data: DataDict
                    init(_dataDict: DataDict) { __data = _dataDict }

                    typealias RootEntityType = GitHubIssueDetailsQuery.Data.Repository.Issue.TimelineItems.Node.AsUnassignedEvent.Assignee
                    static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.Mannequin }
                    static var __mergedSources: [any ApolloAPI.SelectionSet.Type] { [
                      GitHubAssignee.AsActor.self,
                      GitHubActor.self,
                      GitHubActor.AsNode.self,
                      GitHubAssignee.AsMannequin.self,
                      GitHubIssueDetailsQuery.Data.Repository.Issue.TimelineItems.Node.AsUnassignedEvent.Assignee.self
                    ] }
                    static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                      GitHubIssueDetailsQuery.Data.Repository.Issue.TimelineItems.Node.AsUnassignedEvent.Assignee.self,
                      GitHubIssueDetailsQuery.Data.Repository.Issue.TimelineItems.Node.AsUnassignedEvent.Assignee.AsMannequin.self,
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

              /// Repository.Issue.TimelineItems.Node.AsLabeledEvent
              nonisolated struct AsLabeledEvent: GitHubAPI.InlineFragment {
                let __data: DataDict
                init(_dataDict: DataDict) { __data = _dataDict }

                typealias RootEntityType = GitHubIssueDetailsQuery.Data.Repository.Issue.TimelineItems.Node
                static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.LabeledEvent }
                static var __selections: [ApolloAPI.Selection] { [
                  .field("id", GitHubAPI.ID.self),
                  .field("createdAt", GitHubAPI.DateTime.self),
                  .field("actor", Actor?.self),
                  .field("label", Label.self),
                ] }
                static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                  GitHubIssueDetailsQuery.Data.Repository.Issue.TimelineItems.Node.self,
                  GitHubIssueDetailsQuery.Data.Repository.Issue.TimelineItems.Node.AsLabeledEvent.self
                ] }

                var id: GitHubAPI.ID { __data["id"] }
                var createdAt: GitHubAPI.DateTime { __data["createdAt"] }
                var actor: Actor? { __data["actor"] }
                var label: Label { __data["label"] }

                /// Repository.Issue.TimelineItems.Node.AsLabeledEvent.Actor
                nonisolated struct Actor: GitHubAPI.SelectionSet {
                  let __data: DataDict
                  init(_dataDict: DataDict) { __data = _dataDict }

                  static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Interfaces.Actor }
                  static var __selections: [ApolloAPI.Selection] { [
                    .field("__typename", String.self),
                    .fragment(GitHubActor.self),
                  ] }
                  static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                    GitHubIssueDetailsQuery.Data.Repository.Issue.TimelineItems.Node.AsLabeledEvent.Actor.self,
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

                  /// Repository.Issue.TimelineItems.Node.AsLabeledEvent.Actor.AsNode
                  nonisolated struct AsNode: GitHubAPI.InlineFragment, ApolloAPI.CompositeInlineFragment {
                    let __data: DataDict
                    init(_dataDict: DataDict) { __data = _dataDict }

                    typealias RootEntityType = GitHubIssueDetailsQuery.Data.Repository.Issue.TimelineItems.Node.AsLabeledEvent.Actor
                    static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Interfaces.Node }
                    static var __mergedSources: [any ApolloAPI.SelectionSet.Type] { [
                      GitHubActor.self,
                      GitHubActor.AsNode.self,
                      GitHubIssueDetailsQuery.Data.Repository.Issue.TimelineItems.Node.AsLabeledEvent.Actor.self
                    ] }
                    static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                      GitHubIssueDetailsQuery.Data.Repository.Issue.TimelineItems.Node.AsLabeledEvent.Actor.self,
                      GitHubIssueDetailsQuery.Data.Repository.Issue.TimelineItems.Node.AsLabeledEvent.Actor.AsNode.self,
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

                  /// Repository.Issue.TimelineItems.Node.AsLabeledEvent.Actor.AsUser
                  nonisolated struct AsUser: GitHubAPI.InlineFragment, ApolloAPI.CompositeInlineFragment {
                    let __data: DataDict
                    init(_dataDict: DataDict) { __data = _dataDict }

                    typealias RootEntityType = GitHubIssueDetailsQuery.Data.Repository.Issue.TimelineItems.Node.AsLabeledEvent.Actor
                    static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.User }
                    static var __mergedSources: [any ApolloAPI.SelectionSet.Type] { [
                      GitHubActor.self,
                      GitHubActor.AsNode.self,
                      GitHubActor.AsUser.self,
                      GitHubIssueDetailsQuery.Data.Repository.Issue.TimelineItems.Node.AsLabeledEvent.Actor.self
                    ] }
                    static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                      GitHubIssueDetailsQuery.Data.Repository.Issue.TimelineItems.Node.AsLabeledEvent.Actor.self,
                      GitHubIssueDetailsQuery.Data.Repository.Issue.TimelineItems.Node.AsLabeledEvent.Actor.AsUser.self,
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

                  /// Repository.Issue.TimelineItems.Node.AsLabeledEvent.Actor.AsOrganization
                  nonisolated struct AsOrganization: GitHubAPI.InlineFragment, ApolloAPI.CompositeInlineFragment {
                    let __data: DataDict
                    init(_dataDict: DataDict) { __data = _dataDict }

                    typealias RootEntityType = GitHubIssueDetailsQuery.Data.Repository.Issue.TimelineItems.Node.AsLabeledEvent.Actor
                    static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.Organization }
                    static var __mergedSources: [any ApolloAPI.SelectionSet.Type] { [
                      GitHubActor.self,
                      GitHubActor.AsNode.self,
                      GitHubActor.AsOrganization.self,
                      GitHubIssueDetailsQuery.Data.Repository.Issue.TimelineItems.Node.AsLabeledEvent.Actor.self
                    ] }
                    static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                      GitHubIssueDetailsQuery.Data.Repository.Issue.TimelineItems.Node.AsLabeledEvent.Actor.self,
                      GitHubIssueDetailsQuery.Data.Repository.Issue.TimelineItems.Node.AsLabeledEvent.Actor.AsOrganization.self,
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

                /// Repository.Issue.TimelineItems.Node.AsLabeledEvent.Label
                nonisolated struct Label: GitHubAPI.SelectionSet {
                  let __data: DataDict
                  init(_dataDict: DataDict) { __data = _dataDict }

                  static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.Label }
                  static var __selections: [ApolloAPI.Selection] { [
                    .field("__typename", String.self),
                    .fragment(GitHubLabel.self),
                  ] }
                  static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                    GitHubIssueDetailsQuery.Data.Repository.Issue.TimelineItems.Node.AsLabeledEvent.Label.self,
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

              /// Repository.Issue.TimelineItems.Node.AsUnlabeledEvent
              nonisolated struct AsUnlabeledEvent: GitHubAPI.InlineFragment {
                let __data: DataDict
                init(_dataDict: DataDict) { __data = _dataDict }

                typealias RootEntityType = GitHubIssueDetailsQuery.Data.Repository.Issue.TimelineItems.Node
                static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.UnlabeledEvent }
                static var __selections: [ApolloAPI.Selection] { [
                  .field("id", GitHubAPI.ID.self),
                  .field("createdAt", GitHubAPI.DateTime.self),
                  .field("actor", Actor?.self),
                  .field("label", Label.self),
                ] }
                static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                  GitHubIssueDetailsQuery.Data.Repository.Issue.TimelineItems.Node.self,
                  GitHubIssueDetailsQuery.Data.Repository.Issue.TimelineItems.Node.AsUnlabeledEvent.self
                ] }

                var id: GitHubAPI.ID { __data["id"] }
                var createdAt: GitHubAPI.DateTime { __data["createdAt"] }
                var actor: Actor? { __data["actor"] }
                var label: Label { __data["label"] }

                /// Repository.Issue.TimelineItems.Node.AsUnlabeledEvent.Actor
                nonisolated struct Actor: GitHubAPI.SelectionSet {
                  let __data: DataDict
                  init(_dataDict: DataDict) { __data = _dataDict }

                  static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Interfaces.Actor }
                  static var __selections: [ApolloAPI.Selection] { [
                    .field("__typename", String.self),
                    .fragment(GitHubActor.self),
                  ] }
                  static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                    GitHubIssueDetailsQuery.Data.Repository.Issue.TimelineItems.Node.AsUnlabeledEvent.Actor.self,
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

                  /// Repository.Issue.TimelineItems.Node.AsUnlabeledEvent.Actor.AsNode
                  nonisolated struct AsNode: GitHubAPI.InlineFragment, ApolloAPI.CompositeInlineFragment {
                    let __data: DataDict
                    init(_dataDict: DataDict) { __data = _dataDict }

                    typealias RootEntityType = GitHubIssueDetailsQuery.Data.Repository.Issue.TimelineItems.Node.AsUnlabeledEvent.Actor
                    static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Interfaces.Node }
                    static var __mergedSources: [any ApolloAPI.SelectionSet.Type] { [
                      GitHubActor.self,
                      GitHubActor.AsNode.self,
                      GitHubIssueDetailsQuery.Data.Repository.Issue.TimelineItems.Node.AsUnlabeledEvent.Actor.self
                    ] }
                    static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                      GitHubIssueDetailsQuery.Data.Repository.Issue.TimelineItems.Node.AsUnlabeledEvent.Actor.self,
                      GitHubIssueDetailsQuery.Data.Repository.Issue.TimelineItems.Node.AsUnlabeledEvent.Actor.AsNode.self,
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

                  /// Repository.Issue.TimelineItems.Node.AsUnlabeledEvent.Actor.AsUser
                  nonisolated struct AsUser: GitHubAPI.InlineFragment, ApolloAPI.CompositeInlineFragment {
                    let __data: DataDict
                    init(_dataDict: DataDict) { __data = _dataDict }

                    typealias RootEntityType = GitHubIssueDetailsQuery.Data.Repository.Issue.TimelineItems.Node.AsUnlabeledEvent.Actor
                    static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.User }
                    static var __mergedSources: [any ApolloAPI.SelectionSet.Type] { [
                      GitHubActor.self,
                      GitHubActor.AsNode.self,
                      GitHubActor.AsUser.self,
                      GitHubIssueDetailsQuery.Data.Repository.Issue.TimelineItems.Node.AsUnlabeledEvent.Actor.self
                    ] }
                    static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                      GitHubIssueDetailsQuery.Data.Repository.Issue.TimelineItems.Node.AsUnlabeledEvent.Actor.self,
                      GitHubIssueDetailsQuery.Data.Repository.Issue.TimelineItems.Node.AsUnlabeledEvent.Actor.AsUser.self,
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

                  /// Repository.Issue.TimelineItems.Node.AsUnlabeledEvent.Actor.AsOrganization
                  nonisolated struct AsOrganization: GitHubAPI.InlineFragment, ApolloAPI.CompositeInlineFragment {
                    let __data: DataDict
                    init(_dataDict: DataDict) { __data = _dataDict }

                    typealias RootEntityType = GitHubIssueDetailsQuery.Data.Repository.Issue.TimelineItems.Node.AsUnlabeledEvent.Actor
                    static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.Organization }
                    static var __mergedSources: [any ApolloAPI.SelectionSet.Type] { [
                      GitHubActor.self,
                      GitHubActor.AsNode.self,
                      GitHubActor.AsOrganization.self,
                      GitHubIssueDetailsQuery.Data.Repository.Issue.TimelineItems.Node.AsUnlabeledEvent.Actor.self
                    ] }
                    static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                      GitHubIssueDetailsQuery.Data.Repository.Issue.TimelineItems.Node.AsUnlabeledEvent.Actor.self,
                      GitHubIssueDetailsQuery.Data.Repository.Issue.TimelineItems.Node.AsUnlabeledEvent.Actor.AsOrganization.self,
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

                /// Repository.Issue.TimelineItems.Node.AsUnlabeledEvent.Label
                nonisolated struct Label: GitHubAPI.SelectionSet {
                  let __data: DataDict
                  init(_dataDict: DataDict) { __data = _dataDict }

                  static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.Label }
                  static var __selections: [ApolloAPI.Selection] { [
                    .field("__typename", String.self),
                    .fragment(GitHubLabel.self),
                  ] }
                  static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                    GitHubIssueDetailsQuery.Data.Repository.Issue.TimelineItems.Node.AsUnlabeledEvent.Label.self,
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

              /// Repository.Issue.TimelineItems.Node.AsMilestonedEvent
              nonisolated struct AsMilestonedEvent: GitHubAPI.InlineFragment {
                let __data: DataDict
                init(_dataDict: DataDict) { __data = _dataDict }

                typealias RootEntityType = GitHubIssueDetailsQuery.Data.Repository.Issue.TimelineItems.Node
                static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.MilestonedEvent }
                static var __selections: [ApolloAPI.Selection] { [
                  .field("id", GitHubAPI.ID.self),
                  .field("createdAt", GitHubAPI.DateTime.self),
                  .field("milestoneTitle", String.self),
                  .field("actor", Actor?.self),
                ] }
                static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                  GitHubIssueDetailsQuery.Data.Repository.Issue.TimelineItems.Node.self,
                  GitHubIssueDetailsQuery.Data.Repository.Issue.TimelineItems.Node.AsMilestonedEvent.self
                ] }

                var id: GitHubAPI.ID { __data["id"] }
                var createdAt: GitHubAPI.DateTime { __data["createdAt"] }
                var milestoneTitle: String { __data["milestoneTitle"] }
                var actor: Actor? { __data["actor"] }

                /// Repository.Issue.TimelineItems.Node.AsMilestonedEvent.Actor
                nonisolated struct Actor: GitHubAPI.SelectionSet {
                  let __data: DataDict
                  init(_dataDict: DataDict) { __data = _dataDict }

                  static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Interfaces.Actor }
                  static var __selections: [ApolloAPI.Selection] { [
                    .field("__typename", String.self),
                    .fragment(GitHubActor.self),
                  ] }
                  static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                    GitHubIssueDetailsQuery.Data.Repository.Issue.TimelineItems.Node.AsMilestonedEvent.Actor.self,
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

                  /// Repository.Issue.TimelineItems.Node.AsMilestonedEvent.Actor.AsNode
                  nonisolated struct AsNode: GitHubAPI.InlineFragment, ApolloAPI.CompositeInlineFragment {
                    let __data: DataDict
                    init(_dataDict: DataDict) { __data = _dataDict }

                    typealias RootEntityType = GitHubIssueDetailsQuery.Data.Repository.Issue.TimelineItems.Node.AsMilestonedEvent.Actor
                    static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Interfaces.Node }
                    static var __mergedSources: [any ApolloAPI.SelectionSet.Type] { [
                      GitHubActor.self,
                      GitHubActor.AsNode.self,
                      GitHubIssueDetailsQuery.Data.Repository.Issue.TimelineItems.Node.AsMilestonedEvent.Actor.self
                    ] }
                    static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                      GitHubIssueDetailsQuery.Data.Repository.Issue.TimelineItems.Node.AsMilestonedEvent.Actor.self,
                      GitHubIssueDetailsQuery.Data.Repository.Issue.TimelineItems.Node.AsMilestonedEvent.Actor.AsNode.self,
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

                  /// Repository.Issue.TimelineItems.Node.AsMilestonedEvent.Actor.AsUser
                  nonisolated struct AsUser: GitHubAPI.InlineFragment, ApolloAPI.CompositeInlineFragment {
                    let __data: DataDict
                    init(_dataDict: DataDict) { __data = _dataDict }

                    typealias RootEntityType = GitHubIssueDetailsQuery.Data.Repository.Issue.TimelineItems.Node.AsMilestonedEvent.Actor
                    static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.User }
                    static var __mergedSources: [any ApolloAPI.SelectionSet.Type] { [
                      GitHubActor.self,
                      GitHubActor.AsNode.self,
                      GitHubActor.AsUser.self,
                      GitHubIssueDetailsQuery.Data.Repository.Issue.TimelineItems.Node.AsMilestonedEvent.Actor.self
                    ] }
                    static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                      GitHubIssueDetailsQuery.Data.Repository.Issue.TimelineItems.Node.AsMilestonedEvent.Actor.self,
                      GitHubIssueDetailsQuery.Data.Repository.Issue.TimelineItems.Node.AsMilestonedEvent.Actor.AsUser.self,
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

                  /// Repository.Issue.TimelineItems.Node.AsMilestonedEvent.Actor.AsOrganization
                  nonisolated struct AsOrganization: GitHubAPI.InlineFragment, ApolloAPI.CompositeInlineFragment {
                    let __data: DataDict
                    init(_dataDict: DataDict) { __data = _dataDict }

                    typealias RootEntityType = GitHubIssueDetailsQuery.Data.Repository.Issue.TimelineItems.Node.AsMilestonedEvent.Actor
                    static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.Organization }
                    static var __mergedSources: [any ApolloAPI.SelectionSet.Type] { [
                      GitHubActor.self,
                      GitHubActor.AsNode.self,
                      GitHubActor.AsOrganization.self,
                      GitHubIssueDetailsQuery.Data.Repository.Issue.TimelineItems.Node.AsMilestonedEvent.Actor.self
                    ] }
                    static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                      GitHubIssueDetailsQuery.Data.Repository.Issue.TimelineItems.Node.AsMilestonedEvent.Actor.self,
                      GitHubIssueDetailsQuery.Data.Repository.Issue.TimelineItems.Node.AsMilestonedEvent.Actor.AsOrganization.self,
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

              /// Repository.Issue.TimelineItems.Node.AsDemilestonedEvent
              nonisolated struct AsDemilestonedEvent: GitHubAPI.InlineFragment {
                let __data: DataDict
                init(_dataDict: DataDict) { __data = _dataDict }

                typealias RootEntityType = GitHubIssueDetailsQuery.Data.Repository.Issue.TimelineItems.Node
                static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.DemilestonedEvent }
                static var __selections: [ApolloAPI.Selection] { [
                  .field("id", GitHubAPI.ID.self),
                  .field("createdAt", GitHubAPI.DateTime.self),
                  .field("milestoneTitle", String.self),
                  .field("actor", Actor?.self),
                ] }
                static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                  GitHubIssueDetailsQuery.Data.Repository.Issue.TimelineItems.Node.self,
                  GitHubIssueDetailsQuery.Data.Repository.Issue.TimelineItems.Node.AsDemilestonedEvent.self
                ] }

                var id: GitHubAPI.ID { __data["id"] }
                var createdAt: GitHubAPI.DateTime { __data["createdAt"] }
                var milestoneTitle: String { __data["milestoneTitle"] }
                var actor: Actor? { __data["actor"] }

                /// Repository.Issue.TimelineItems.Node.AsDemilestonedEvent.Actor
                nonisolated struct Actor: GitHubAPI.SelectionSet {
                  let __data: DataDict
                  init(_dataDict: DataDict) { __data = _dataDict }

                  static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Interfaces.Actor }
                  static var __selections: [ApolloAPI.Selection] { [
                    .field("__typename", String.self),
                    .fragment(GitHubActor.self),
                  ] }
                  static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                    GitHubIssueDetailsQuery.Data.Repository.Issue.TimelineItems.Node.AsDemilestonedEvent.Actor.self,
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

                  /// Repository.Issue.TimelineItems.Node.AsDemilestonedEvent.Actor.AsNode
                  nonisolated struct AsNode: GitHubAPI.InlineFragment, ApolloAPI.CompositeInlineFragment {
                    let __data: DataDict
                    init(_dataDict: DataDict) { __data = _dataDict }

                    typealias RootEntityType = GitHubIssueDetailsQuery.Data.Repository.Issue.TimelineItems.Node.AsDemilestonedEvent.Actor
                    static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Interfaces.Node }
                    static var __mergedSources: [any ApolloAPI.SelectionSet.Type] { [
                      GitHubActor.self,
                      GitHubActor.AsNode.self,
                      GitHubIssueDetailsQuery.Data.Repository.Issue.TimelineItems.Node.AsDemilestonedEvent.Actor.self
                    ] }
                    static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                      GitHubIssueDetailsQuery.Data.Repository.Issue.TimelineItems.Node.AsDemilestonedEvent.Actor.self,
                      GitHubIssueDetailsQuery.Data.Repository.Issue.TimelineItems.Node.AsDemilestonedEvent.Actor.AsNode.self,
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

                  /// Repository.Issue.TimelineItems.Node.AsDemilestonedEvent.Actor.AsUser
                  nonisolated struct AsUser: GitHubAPI.InlineFragment, ApolloAPI.CompositeInlineFragment {
                    let __data: DataDict
                    init(_dataDict: DataDict) { __data = _dataDict }

                    typealias RootEntityType = GitHubIssueDetailsQuery.Data.Repository.Issue.TimelineItems.Node.AsDemilestonedEvent.Actor
                    static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.User }
                    static var __mergedSources: [any ApolloAPI.SelectionSet.Type] { [
                      GitHubActor.self,
                      GitHubActor.AsNode.self,
                      GitHubActor.AsUser.self,
                      GitHubIssueDetailsQuery.Data.Repository.Issue.TimelineItems.Node.AsDemilestonedEvent.Actor.self
                    ] }
                    static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                      GitHubIssueDetailsQuery.Data.Repository.Issue.TimelineItems.Node.AsDemilestonedEvent.Actor.self,
                      GitHubIssueDetailsQuery.Data.Repository.Issue.TimelineItems.Node.AsDemilestonedEvent.Actor.AsUser.self,
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

                  /// Repository.Issue.TimelineItems.Node.AsDemilestonedEvent.Actor.AsOrganization
                  nonisolated struct AsOrganization: GitHubAPI.InlineFragment, ApolloAPI.CompositeInlineFragment {
                    let __data: DataDict
                    init(_dataDict: DataDict) { __data = _dataDict }

                    typealias RootEntityType = GitHubIssueDetailsQuery.Data.Repository.Issue.TimelineItems.Node.AsDemilestonedEvent.Actor
                    static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.Organization }
                    static var __mergedSources: [any ApolloAPI.SelectionSet.Type] { [
                      GitHubActor.self,
                      GitHubActor.AsNode.self,
                      GitHubActor.AsOrganization.self,
                      GitHubIssueDetailsQuery.Data.Repository.Issue.TimelineItems.Node.AsDemilestonedEvent.Actor.self
                    ] }
                    static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                      GitHubIssueDetailsQuery.Data.Repository.Issue.TimelineItems.Node.AsDemilestonedEvent.Actor.self,
                      GitHubIssueDetailsQuery.Data.Repository.Issue.TimelineItems.Node.AsDemilestonedEvent.Actor.AsOrganization.self,
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

              /// Repository.Issue.TimelineItems.Node.AsRenamedTitleEvent
              nonisolated struct AsRenamedTitleEvent: GitHubAPI.InlineFragment {
                let __data: DataDict
                init(_dataDict: DataDict) { __data = _dataDict }

                typealias RootEntityType = GitHubIssueDetailsQuery.Data.Repository.Issue.TimelineItems.Node
                static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.RenamedTitleEvent }
                static var __selections: [ApolloAPI.Selection] { [
                  .field("id", GitHubAPI.ID.self),
                  .field("createdAt", GitHubAPI.DateTime.self),
                  .field("previousTitle", String.self),
                  .field("currentTitle", String.self),
                  .field("actor", Actor?.self),
                ] }
                static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                  GitHubIssueDetailsQuery.Data.Repository.Issue.TimelineItems.Node.self,
                  GitHubIssueDetailsQuery.Data.Repository.Issue.TimelineItems.Node.AsRenamedTitleEvent.self
                ] }

                var id: GitHubAPI.ID { __data["id"] }
                var createdAt: GitHubAPI.DateTime { __data["createdAt"] }
                var previousTitle: String { __data["previousTitle"] }
                var currentTitle: String { __data["currentTitle"] }
                var actor: Actor? { __data["actor"] }

                /// Repository.Issue.TimelineItems.Node.AsRenamedTitleEvent.Actor
                nonisolated struct Actor: GitHubAPI.SelectionSet {
                  let __data: DataDict
                  init(_dataDict: DataDict) { __data = _dataDict }

                  static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Interfaces.Actor }
                  static var __selections: [ApolloAPI.Selection] { [
                    .field("__typename", String.self),
                    .fragment(GitHubActor.self),
                  ] }
                  static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                    GitHubIssueDetailsQuery.Data.Repository.Issue.TimelineItems.Node.AsRenamedTitleEvent.Actor.self,
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

                  /// Repository.Issue.TimelineItems.Node.AsRenamedTitleEvent.Actor.AsNode
                  nonisolated struct AsNode: GitHubAPI.InlineFragment, ApolloAPI.CompositeInlineFragment {
                    let __data: DataDict
                    init(_dataDict: DataDict) { __data = _dataDict }

                    typealias RootEntityType = GitHubIssueDetailsQuery.Data.Repository.Issue.TimelineItems.Node.AsRenamedTitleEvent.Actor
                    static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Interfaces.Node }
                    static var __mergedSources: [any ApolloAPI.SelectionSet.Type] { [
                      GitHubActor.self,
                      GitHubActor.AsNode.self,
                      GitHubIssueDetailsQuery.Data.Repository.Issue.TimelineItems.Node.AsRenamedTitleEvent.Actor.self
                    ] }
                    static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                      GitHubIssueDetailsQuery.Data.Repository.Issue.TimelineItems.Node.AsRenamedTitleEvent.Actor.self,
                      GitHubIssueDetailsQuery.Data.Repository.Issue.TimelineItems.Node.AsRenamedTitleEvent.Actor.AsNode.self,
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

                  /// Repository.Issue.TimelineItems.Node.AsRenamedTitleEvent.Actor.AsUser
                  nonisolated struct AsUser: GitHubAPI.InlineFragment, ApolloAPI.CompositeInlineFragment {
                    let __data: DataDict
                    init(_dataDict: DataDict) { __data = _dataDict }

                    typealias RootEntityType = GitHubIssueDetailsQuery.Data.Repository.Issue.TimelineItems.Node.AsRenamedTitleEvent.Actor
                    static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.User }
                    static var __mergedSources: [any ApolloAPI.SelectionSet.Type] { [
                      GitHubActor.self,
                      GitHubActor.AsNode.self,
                      GitHubActor.AsUser.self,
                      GitHubIssueDetailsQuery.Data.Repository.Issue.TimelineItems.Node.AsRenamedTitleEvent.Actor.self
                    ] }
                    static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                      GitHubIssueDetailsQuery.Data.Repository.Issue.TimelineItems.Node.AsRenamedTitleEvent.Actor.self,
                      GitHubIssueDetailsQuery.Data.Repository.Issue.TimelineItems.Node.AsRenamedTitleEvent.Actor.AsUser.self,
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

                  /// Repository.Issue.TimelineItems.Node.AsRenamedTitleEvent.Actor.AsOrganization
                  nonisolated struct AsOrganization: GitHubAPI.InlineFragment, ApolloAPI.CompositeInlineFragment {
                    let __data: DataDict
                    init(_dataDict: DataDict) { __data = _dataDict }

                    typealias RootEntityType = GitHubIssueDetailsQuery.Data.Repository.Issue.TimelineItems.Node.AsRenamedTitleEvent.Actor
                    static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.Organization }
                    static var __mergedSources: [any ApolloAPI.SelectionSet.Type] { [
                      GitHubActor.self,
                      GitHubActor.AsNode.self,
                      GitHubActor.AsOrganization.self,
                      GitHubIssueDetailsQuery.Data.Repository.Issue.TimelineItems.Node.AsRenamedTitleEvent.Actor.self
                    ] }
                    static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                      GitHubIssueDetailsQuery.Data.Repository.Issue.TimelineItems.Node.AsRenamedTitleEvent.Actor.self,
                      GitHubIssueDetailsQuery.Data.Repository.Issue.TimelineItems.Node.AsRenamedTitleEvent.Actor.AsOrganization.self,
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

              /// Repository.Issue.TimelineItems.Node.AsCrossReferencedEvent
              nonisolated struct AsCrossReferencedEvent: GitHubAPI.InlineFragment {
                let __data: DataDict
                init(_dataDict: DataDict) { __data = _dataDict }

                typealias RootEntityType = GitHubIssueDetailsQuery.Data.Repository.Issue.TimelineItems.Node
                static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.CrossReferencedEvent }
                static var __selections: [ApolloAPI.Selection] { [
                  .field("id", GitHubAPI.ID.self),
                  .field("createdAt", GitHubAPI.DateTime.self),
                  .field("actor", Actor?.self),
                  .field("source", Source.self),
                ] }
                static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                  GitHubIssueDetailsQuery.Data.Repository.Issue.TimelineItems.Node.self,
                  GitHubIssueDetailsQuery.Data.Repository.Issue.TimelineItems.Node.AsCrossReferencedEvent.self
                ] }

                var id: GitHubAPI.ID { __data["id"] }
                var createdAt: GitHubAPI.DateTime { __data["createdAt"] }
                var actor: Actor? { __data["actor"] }
                var source: Source { __data["source"] }

                /// Repository.Issue.TimelineItems.Node.AsCrossReferencedEvent.Actor
                nonisolated struct Actor: GitHubAPI.SelectionSet {
                  let __data: DataDict
                  init(_dataDict: DataDict) { __data = _dataDict }

                  static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Interfaces.Actor }
                  static var __selections: [ApolloAPI.Selection] { [
                    .field("__typename", String.self),
                    .fragment(GitHubActor.self),
                  ] }
                  static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                    GitHubIssueDetailsQuery.Data.Repository.Issue.TimelineItems.Node.AsCrossReferencedEvent.Actor.self,
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

                  /// Repository.Issue.TimelineItems.Node.AsCrossReferencedEvent.Actor.AsNode
                  nonisolated struct AsNode: GitHubAPI.InlineFragment, ApolloAPI.CompositeInlineFragment {
                    let __data: DataDict
                    init(_dataDict: DataDict) { __data = _dataDict }

                    typealias RootEntityType = GitHubIssueDetailsQuery.Data.Repository.Issue.TimelineItems.Node.AsCrossReferencedEvent.Actor
                    static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Interfaces.Node }
                    static var __mergedSources: [any ApolloAPI.SelectionSet.Type] { [
                      GitHubActor.self,
                      GitHubActor.AsNode.self,
                      GitHubIssueDetailsQuery.Data.Repository.Issue.TimelineItems.Node.AsCrossReferencedEvent.Actor.self
                    ] }
                    static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                      GitHubIssueDetailsQuery.Data.Repository.Issue.TimelineItems.Node.AsCrossReferencedEvent.Actor.self,
                      GitHubIssueDetailsQuery.Data.Repository.Issue.TimelineItems.Node.AsCrossReferencedEvent.Actor.AsNode.self,
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

                  /// Repository.Issue.TimelineItems.Node.AsCrossReferencedEvent.Actor.AsUser
                  nonisolated struct AsUser: GitHubAPI.InlineFragment, ApolloAPI.CompositeInlineFragment {
                    let __data: DataDict
                    init(_dataDict: DataDict) { __data = _dataDict }

                    typealias RootEntityType = GitHubIssueDetailsQuery.Data.Repository.Issue.TimelineItems.Node.AsCrossReferencedEvent.Actor
                    static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.User }
                    static var __mergedSources: [any ApolloAPI.SelectionSet.Type] { [
                      GitHubActor.self,
                      GitHubActor.AsNode.self,
                      GitHubActor.AsUser.self,
                      GitHubIssueDetailsQuery.Data.Repository.Issue.TimelineItems.Node.AsCrossReferencedEvent.Actor.self
                    ] }
                    static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                      GitHubIssueDetailsQuery.Data.Repository.Issue.TimelineItems.Node.AsCrossReferencedEvent.Actor.self,
                      GitHubIssueDetailsQuery.Data.Repository.Issue.TimelineItems.Node.AsCrossReferencedEvent.Actor.AsUser.self,
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

                  /// Repository.Issue.TimelineItems.Node.AsCrossReferencedEvent.Actor.AsOrganization
                  nonisolated struct AsOrganization: GitHubAPI.InlineFragment, ApolloAPI.CompositeInlineFragment {
                    let __data: DataDict
                    init(_dataDict: DataDict) { __data = _dataDict }

                    typealias RootEntityType = GitHubIssueDetailsQuery.Data.Repository.Issue.TimelineItems.Node.AsCrossReferencedEvent.Actor
                    static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.Organization }
                    static var __mergedSources: [any ApolloAPI.SelectionSet.Type] { [
                      GitHubActor.self,
                      GitHubActor.AsNode.self,
                      GitHubActor.AsOrganization.self,
                      GitHubIssueDetailsQuery.Data.Repository.Issue.TimelineItems.Node.AsCrossReferencedEvent.Actor.self
                    ] }
                    static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                      GitHubIssueDetailsQuery.Data.Repository.Issue.TimelineItems.Node.AsCrossReferencedEvent.Actor.self,
                      GitHubIssueDetailsQuery.Data.Repository.Issue.TimelineItems.Node.AsCrossReferencedEvent.Actor.AsOrganization.self,
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

                /// Repository.Issue.TimelineItems.Node.AsCrossReferencedEvent.Source
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
                    GitHubIssueDetailsQuery.Data.Repository.Issue.TimelineItems.Node.AsCrossReferencedEvent.Source.self
                  ] }

                  var asPullRequest: AsPullRequest? { _asInlineFragment() }
                  var asIssue: AsIssue? { _asInlineFragment() }

                  /// Repository.Issue.TimelineItems.Node.AsCrossReferencedEvent.Source.AsPullRequest
                  nonisolated struct AsPullRequest: GitHubAPI.InlineFragment {
                    let __data: DataDict
                    init(_dataDict: DataDict) { __data = _dataDict }

                    typealias RootEntityType = GitHubIssueDetailsQuery.Data.Repository.Issue.TimelineItems.Node.AsCrossReferencedEvent.Source
                    static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.PullRequest }
                    static var __selections: [ApolloAPI.Selection] { [
                      .field("number", Int.self),
                      .field("state", alias: "pullRequestState", GraphQLEnum<GitHubAPI.PullRequestState>.self),
                      .field("title", String.self),
                      .field("repository", Repository.self),
                    ] }
                    static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                      GitHubIssueDetailsQuery.Data.Repository.Issue.TimelineItems.Node.AsCrossReferencedEvent.Source.self,
                      GitHubIssueDetailsQuery.Data.Repository.Issue.TimelineItems.Node.AsCrossReferencedEvent.Source.AsPullRequest.self
                    ] }

                    var number: Int { __data["number"] }
                    var pullRequestState: GraphQLEnum<GitHubAPI.PullRequestState> { __data["pullRequestState"] }
                    var title: String { __data["title"] }
                    var repository: Repository { __data["repository"] }

                    /// Repository.Issue.TimelineItems.Node.AsCrossReferencedEvent.Source.AsPullRequest.Repository
                    nonisolated struct Repository: GitHubAPI.SelectionSet {
                      let __data: DataDict
                      init(_dataDict: DataDict) { __data = _dataDict }

                      static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.Repository }
                      static var __selections: [ApolloAPI.Selection] { [
                        .field("__typename", String.self),
                        .fragment(GitHubRepositoryIdentity.self),
                      ] }
                      static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                        GitHubIssueDetailsQuery.Data.Repository.Issue.TimelineItems.Node.AsCrossReferencedEvent.Source.AsPullRequest.Repository.self,
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

                  /// Repository.Issue.TimelineItems.Node.AsCrossReferencedEvent.Source.AsIssue
                  nonisolated struct AsIssue: GitHubAPI.InlineFragment {
                    let __data: DataDict
                    init(_dataDict: DataDict) { __data = _dataDict }

                    typealias RootEntityType = GitHubIssueDetailsQuery.Data.Repository.Issue.TimelineItems.Node.AsCrossReferencedEvent.Source
                    static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.Issue }
                    static var __selections: [ApolloAPI.Selection] { [
                      .field("number", Int.self),
                      .field("state", alias: "issueState", GraphQLEnum<GitHubAPI.IssueState>.self),
                      .field("title", String.self),
                      .field("repository", Repository.self),
                    ] }
                    static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                      GitHubIssueDetailsQuery.Data.Repository.Issue.TimelineItems.Node.AsCrossReferencedEvent.Source.self,
                      GitHubIssueDetailsQuery.Data.Repository.Issue.TimelineItems.Node.AsCrossReferencedEvent.Source.AsIssue.self
                    ] }

                    var number: Int { __data["number"] }
                    var issueState: GraphQLEnum<GitHubAPI.IssueState> { __data["issueState"] }
                    var title: String { __data["title"] }
                    var repository: Repository { __data["repository"] }

                    /// Repository.Issue.TimelineItems.Node.AsCrossReferencedEvent.Source.AsIssue.Repository
                    nonisolated struct Repository: GitHubAPI.SelectionSet {
                      let __data: DataDict
                      init(_dataDict: DataDict) { __data = _dataDict }

                      static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.Repository }
                      static var __selections: [ApolloAPI.Selection] { [
                        .field("__typename", String.self),
                        .fragment(GitHubRepositoryIdentity.self),
                      ] }
                      static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                        GitHubIssueDetailsQuery.Data.Repository.Issue.TimelineItems.Node.AsCrossReferencedEvent.Source.AsIssue.Repository.self,
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

          typealias Author = GitHubIssueSummary.Author

          typealias Labels = GitHubIssueSummary.Labels
        }
      }
    }
  }

}
