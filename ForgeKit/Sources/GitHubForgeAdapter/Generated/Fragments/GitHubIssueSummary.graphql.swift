// @generated
// This file was automatically generated and should not be edited.

import ApolloAPI
@_spi(Execution) @_spi(Unsafe) import ApolloAPI

extension GitHubAPI {
  nonisolated struct GitHubIssueSummary: GitHubAPI.SelectionSet, Fragment {
    static var fragmentDefinition: StaticString {
      #"fragment GitHubIssueSummary on Issue { __typename id number issueState: state title createdAt updatedAt closedAt author { __typename ...GitHubActor } labels(first: 100) { __typename totalCount pageInfo { __typename ...GitHubPageInfo } nodes { __typename ...GitHubLabel } } }"#
    }

    let __data: DataDict
    init(_dataDict: DataDict) { __data = _dataDict }

    static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.Issue }
    static var __selections: [ApolloAPI.Selection] { [
      .field("__typename", String.self),
      .field("id", GitHubAPI.ID.self),
      .field("number", Int.self),
      .field("state", alias: "issueState", GraphQLEnum<GitHubAPI.IssueState>.self),
      .field("title", String.self),
      .field("createdAt", GitHubAPI.DateTime.self),
      .field("updatedAt", GitHubAPI.DateTime.self),
      .field("closedAt", GitHubAPI.DateTime?.self),
      .field("author", Author?.self),
      .field("labels", Labels?.self, arguments: ["first": 100]),
    ] }
    static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
      GitHubIssueSummary.self
    ] }

    var id: GitHubAPI.ID { __data["id"] }
    var number: Int { __data["number"] }
    var issueState: GraphQLEnum<GitHubAPI.IssueState> { __data["issueState"] }
    var title: String { __data["title"] }
    var createdAt: GitHubAPI.DateTime { __data["createdAt"] }
    var updatedAt: GitHubAPI.DateTime { __data["updatedAt"] }
    var closedAt: GitHubAPI.DateTime? { __data["closedAt"] }
    var author: Author? { __data["author"] }
    var labels: Labels? { __data["labels"] }

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
        GitHubIssueSummary.Author.self,
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

        typealias RootEntityType = GitHubIssueSummary.Author
        static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Interfaces.Node }
        static var __mergedSources: [any ApolloAPI.SelectionSet.Type] { [
          GitHubIssueSummary.Author.self,
          GitHubActor.self,
          GitHubActor.AsNode.self
        ] }
        static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
          GitHubIssueSummary.Author.self,
          GitHubIssueSummary.Author.AsNode.self,
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

        typealias RootEntityType = GitHubIssueSummary.Author
        static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.User }
        static var __mergedSources: [any ApolloAPI.SelectionSet.Type] { [
          GitHubIssueSummary.Author.self,
          GitHubActor.self,
          GitHubActor.AsNode.self,
          GitHubActor.AsUser.self
        ] }
        static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
          GitHubIssueSummary.Author.self,
          GitHubIssueSummary.Author.AsUser.self,
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

        typealias RootEntityType = GitHubIssueSummary.Author
        static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.Organization }
        static var __mergedSources: [any ApolloAPI.SelectionSet.Type] { [
          GitHubIssueSummary.Author.self,
          GitHubActor.self,
          GitHubActor.AsNode.self,
          GitHubActor.AsOrganization.self
        ] }
        static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
          GitHubIssueSummary.Author.self,
          GitHubIssueSummary.Author.AsOrganization.self,
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
        GitHubIssueSummary.Labels.self
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
          GitHubIssueSummary.Labels.PageInfo.self,
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
          GitHubIssueSummary.Labels.Node.self,
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
  }

}
