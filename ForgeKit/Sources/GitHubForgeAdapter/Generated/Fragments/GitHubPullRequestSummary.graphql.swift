// @generated
// This file was automatically generated and should not be edited.

import ApolloAPI
@_spi(Execution) @_spi(Unsafe) import ApolloAPI

extension GitHubAPI {
  nonisolated struct GitHubPullRequestSummary: GitHubAPI.SelectionSet, Fragment {
    static var fragmentDefinition: StaticString {
      #"fragment GitHubPullRequestSummary on PullRequest { __typename id number pullRequestState: state isDraft title createdAt updatedAt closedAt mergedAt author { __typename ...GitHubActor } headRefName headRefOid headRepository { __typename ...GitHubRepositoryIdentity } baseRefName baseRefOid baseRepository { __typename ...GitHubRepositoryIdentity } labels(first: 100) { __typename totalCount pageInfo { __typename ...GitHubPageInfo } nodes { __typename ...GitHubLabel } } statusCheckRollup { __typename state } reviewDecision }"#
    }

    let __data: DataDict
    init(_dataDict: DataDict) { __data = _dataDict }

    static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.PullRequest }
    static var __selections: [ApolloAPI.Selection] { [
      .field("__typename", String.self),
      .field("id", GitHubAPI.ID.self),
      .field("number", Int.self),
      .field("state", alias: "pullRequestState", GraphQLEnum<GitHubAPI.PullRequestState>.self),
      .field("isDraft", Bool.self),
      .field("title", String.self),
      .field("createdAt", GitHubAPI.DateTime.self),
      .field("updatedAt", GitHubAPI.DateTime.self),
      .field("closedAt", GitHubAPI.DateTime?.self),
      .field("mergedAt", GitHubAPI.DateTime?.self),
      .field("author", Author?.self),
      .field("headRefName", String.self),
      .field("headRefOid", GitHubAPI.GitObjectID.self),
      .field("headRepository", HeadRepository?.self),
      .field("baseRefName", String.self),
      .field("baseRefOid", GitHubAPI.GitObjectID.self),
      .field("baseRepository", BaseRepository?.self),
      .field("labels", Labels?.self, arguments: ["first": 100]),
      .field("statusCheckRollup", StatusCheckRollup?.self),
      .field("reviewDecision", GraphQLEnum<GitHubAPI.PullRequestReviewDecision>?.self),
    ] }
    static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
      GitHubPullRequestSummary.self
    ] }

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
    var statusCheckRollup: StatusCheckRollup? { __data["statusCheckRollup"] }
    var reviewDecision: GraphQLEnum<GitHubAPI.PullRequestReviewDecision>? { __data["reviewDecision"] }

    /// Author
    nonisolated struct Author: GitHubAPI.SelectionSet {
      let __data: DataDict
      init(_dataDict: DataDict) { __data = _dataDict }

      static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Interfaces.Actor }
      static var __selections: [ApolloAPI.Selection] { [
        .field("__typename", String.self),
        .fragment(GitHubActor.self),
      ] }
      static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
        GitHubPullRequestSummary.Author.self,
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

      /// Author.AsNode
      nonisolated struct AsNode: GitHubAPI.InlineFragment, ApolloAPI.CompositeInlineFragment {
        let __data: DataDict
        init(_dataDict: DataDict) { __data = _dataDict }

        typealias RootEntityType = GitHubPullRequestSummary.Author
        static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Interfaces.Node }
        static var __mergedSources: [any ApolloAPI.SelectionSet.Type] { [
          GitHubPullRequestSummary.Author.self,
          GitHubActor.self,
          GitHubActor.AsNode.self
        ] }
        static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
          GitHubPullRequestSummary.Author.self,
          GitHubPullRequestSummary.Author.AsNode.self,
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

      /// Author.AsUser
      nonisolated struct AsUser: GitHubAPI.InlineFragment, ApolloAPI.CompositeInlineFragment {
        let __data: DataDict
        init(_dataDict: DataDict) { __data = _dataDict }

        typealias RootEntityType = GitHubPullRequestSummary.Author
        static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.User }
        static var __mergedSources: [any ApolloAPI.SelectionSet.Type] { [
          GitHubPullRequestSummary.Author.self,
          GitHubActor.self,
          GitHubActor.AsNode.self,
          GitHubActor.AsUser.self
        ] }
        static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
          GitHubPullRequestSummary.Author.self,
          GitHubPullRequestSummary.Author.AsUser.self,
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

      /// Author.AsOrganization
      nonisolated struct AsOrganization: GitHubAPI.InlineFragment, ApolloAPI.CompositeInlineFragment {
        let __data: DataDict
        init(_dataDict: DataDict) { __data = _dataDict }

        typealias RootEntityType = GitHubPullRequestSummary.Author
        static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.Organization }
        static var __mergedSources: [any ApolloAPI.SelectionSet.Type] { [
          GitHubPullRequestSummary.Author.self,
          GitHubActor.self,
          GitHubActor.AsNode.self,
          GitHubActor.AsOrganization.self
        ] }
        static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
          GitHubPullRequestSummary.Author.self,
          GitHubPullRequestSummary.Author.AsOrganization.self,
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

    /// HeadRepository
    nonisolated struct HeadRepository: GitHubAPI.SelectionSet {
      let __data: DataDict
      init(_dataDict: DataDict) { __data = _dataDict }

      static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.Repository }
      static var __selections: [ApolloAPI.Selection] { [
        .field("__typename", String.self),
        .fragment(GitHubRepositoryIdentity.self),
      ] }
      static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
        GitHubPullRequestSummary.HeadRepository.self,
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

    /// BaseRepository
    nonisolated struct BaseRepository: GitHubAPI.SelectionSet {
      let __data: DataDict
      init(_dataDict: DataDict) { __data = _dataDict }

      static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.Repository }
      static var __selections: [ApolloAPI.Selection] { [
        .field("__typename", String.self),
        .fragment(GitHubRepositoryIdentity.self),
      ] }
      static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
        GitHubPullRequestSummary.BaseRepository.self,
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

    /// Labels
    nonisolated struct Labels: GitHubAPI.SelectionSet {
      let __data: DataDict
      init(_dataDict: DataDict) { __data = _dataDict }

      static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.LabelConnection }
      static var __selections: [ApolloAPI.Selection] { [
        .field("__typename", String.self),
        .field("totalCount", Int.self),
        .field("pageInfo", PageInfo.self),
        .field("nodes", [Node?]?.self),
      ] }
      static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
        GitHubPullRequestSummary.Labels.self
      ] }

      var totalCount: Int { __data["totalCount"] }
      var pageInfo: PageInfo { __data["pageInfo"] }
      var nodes: [Node?]? { __data["nodes"] }

      /// Labels.PageInfo
      nonisolated struct PageInfo: GitHubAPI.SelectionSet {
        let __data: DataDict
        init(_dataDict: DataDict) { __data = _dataDict }

        static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.PageInfo }
        static var __selections: [ApolloAPI.Selection] { [
          .field("__typename", String.self),
          .fragment(GitHubPageInfo.self),
        ] }
        static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
          GitHubPullRequestSummary.Labels.PageInfo.self,
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

      /// Labels.Node
      nonisolated struct Node: GitHubAPI.SelectionSet {
        let __data: DataDict
        init(_dataDict: DataDict) { __data = _dataDict }

        static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.Label }
        static var __selections: [ApolloAPI.Selection] { [
          .field("__typename", String.self),
          .fragment(GitHubLabel.self),
        ] }
        static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
          GitHubPullRequestSummary.Labels.Node.self,
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

    /// StatusCheckRollup
    nonisolated struct StatusCheckRollup: GitHubAPI.SelectionSet {
      let __data: DataDict
      init(_dataDict: DataDict) { __data = _dataDict }

      static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.StatusCheckRollup }
      static var __selections: [ApolloAPI.Selection] { [
        .field("__typename", String.self),
        .field("state", GraphQLEnum<GitHubAPI.StatusState>.self),
      ] }
      static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
        GitHubPullRequestSummary.StatusCheckRollup.self
      ] }

      var state: GraphQLEnum<GitHubAPI.StatusState> { __data["state"] }
    }
  }

}
