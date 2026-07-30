// @generated
// This file was automatically generated and should not be edited.

import ApolloAPI
@_spi(Execution) @_spi(Unsafe) import ApolloAPI

extension GitHubAPI {
  nonisolated struct GitHubRepositoryFactsQuery: GraphQLQuery {
    static let operationName: String = "GitHubRepositoryFacts"
    static let operationDocument: ApolloAPI.OperationDocument = .init(
      definition: .init(
        #"query GitHubRepositoryFacts($owner: String!, $name: String!) { repository(owner: $owner, name: $name) { __typename ...GitHubRepositoryIdentity defaultBranchRef { __typename name } description repositoryTopics(first: 100) { __typename totalCount pageInfo { __typename ...GitHubPageInfo } nodes { __typename topic { __typename name } } } visibility isArchived isFork viewerPermission viewerCanAdminister viewerCanCreateIssues viewerCanUpdateTopics parent { __typename ...GitHubRepositoryIdentity } } }"#,
        fragments: [GitHubPageInfo.self, GitHubRepositoryIdentity.self]
      ))

    public var owner: String
    public var name: String

    public init(
      owner: String,
      name: String
    ) {
      self.owner = owner
      self.name = name
    }

    @_spi(Unsafe) public var __variables: Variables? { [
      "owner": owner,
      "name": name
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
        GitHubRepositoryFactsQuery.Data.self
      ] }

      var repository: Repository? { __data["repository"] }

      /// Repository
      nonisolated struct Repository: GitHubAPI.SelectionSet {
        let __data: DataDict
        init(_dataDict: DataDict) { __data = _dataDict }

        static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.Repository }
        static var __selections: [ApolloAPI.Selection] { [
          .field("__typename", String.self),
          .field("defaultBranchRef", DefaultBranchRef?.self),
          .field("description", String?.self),
          .field("repositoryTopics", RepositoryTopics.self, arguments: ["first": 100]),
          .field("visibility", GraphQLEnum<GitHubAPI.RepositoryVisibility>.self),
          .field("isArchived", Bool.self),
          .field("isFork", Bool.self),
          .field("viewerPermission", GraphQLEnum<GitHubAPI.RepositoryPermission>?.self),
          .field("viewerCanAdminister", Bool.self),
          .field("viewerCanCreateIssues", Bool.self),
          .field("viewerCanUpdateTopics", Bool.self),
          .field("parent", Parent?.self),
          .fragment(GitHubRepositoryIdentity.self),
        ] }
        static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
          GitHubRepositoryFactsQuery.Data.Repository.self,
          GitHubRepositoryIdentity.self
        ] }

        var defaultBranchRef: DefaultBranchRef? { __data["defaultBranchRef"] }
        var description: String? { __data["description"] }
        var repositoryTopics: RepositoryTopics { __data["repositoryTopics"] }
        var visibility: GraphQLEnum<GitHubAPI.RepositoryVisibility> { __data["visibility"] }
        var isArchived: Bool { __data["isArchived"] }
        var isFork: Bool { __data["isFork"] }
        var viewerPermission: GraphQLEnum<GitHubAPI.RepositoryPermission>? { __data["viewerPermission"] }
        var viewerCanAdminister: Bool { __data["viewerCanAdminister"] }
        var viewerCanCreateIssues: Bool { __data["viewerCanCreateIssues"] }
        var viewerCanUpdateTopics: Bool { __data["viewerCanUpdateTopics"] }
        var parent: Parent? { __data["parent"] }
        var id: GitHubAPI.ID { __data["id"] }
        var name: String { __data["name"] }
        var nameWithOwner: String { __data["nameWithOwner"] }
        var owner: Owner { __data["owner"] }

        struct Fragments: FragmentContainer {
          let __data: DataDict
          init(_dataDict: DataDict) { __data = _dataDict }

          var gitHubRepositoryIdentity: GitHubRepositoryIdentity { _toFragment() }
        }

        /// Repository.DefaultBranchRef
        nonisolated struct DefaultBranchRef: GitHubAPI.SelectionSet {
          let __data: DataDict
          init(_dataDict: DataDict) { __data = _dataDict }

          static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.Ref }
          static var __selections: [ApolloAPI.Selection] { [
            .field("__typename", String.self),
            .field("name", String.self),
          ] }
          static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
            GitHubRepositoryFactsQuery.Data.Repository.DefaultBranchRef.self
          ] }

          var name: String { __data["name"] }
        }

        /// Repository.RepositoryTopics
        nonisolated struct RepositoryTopics: GitHubAPI.SelectionSet {
          let __data: DataDict
          init(_dataDict: DataDict) { __data = _dataDict }

          static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.RepositoryTopicConnection }
          static var __selections: [ApolloAPI.Selection] { [
            .field("__typename", String.self),
            .field("totalCount", Int.self),
            .field("pageInfo", PageInfo.self),
            .field("nodes", [Node?]?.self),
          ] }
          static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
            GitHubRepositoryFactsQuery.Data.Repository.RepositoryTopics.self
          ] }

          var totalCount: Int { __data["totalCount"] }
          var pageInfo: PageInfo { __data["pageInfo"] }
          var nodes: [Node?]? { __data["nodes"] }

          /// Repository.RepositoryTopics.PageInfo
          nonisolated struct PageInfo: GitHubAPI.SelectionSet {
            let __data: DataDict
            init(_dataDict: DataDict) { __data = _dataDict }

            static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.PageInfo }
            static var __selections: [ApolloAPI.Selection] { [
              .field("__typename", String.self),
              .fragment(GitHubPageInfo.self),
            ] }
            static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
              GitHubRepositoryFactsQuery.Data.Repository.RepositoryTopics.PageInfo.self,
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

          /// Repository.RepositoryTopics.Node
          nonisolated struct Node: GitHubAPI.SelectionSet {
            let __data: DataDict
            init(_dataDict: DataDict) { __data = _dataDict }

            static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.RepositoryTopic }
            static var __selections: [ApolloAPI.Selection] { [
              .field("__typename", String.self),
              .field("topic", Topic.self),
            ] }
            static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
              GitHubRepositoryFactsQuery.Data.Repository.RepositoryTopics.Node.self
            ] }

            var topic: Topic { __data["topic"] }

            /// Repository.RepositoryTopics.Node.Topic
            nonisolated struct Topic: GitHubAPI.SelectionSet {
              let __data: DataDict
              init(_dataDict: DataDict) { __data = _dataDict }

              static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.Topic }
              static var __selections: [ApolloAPI.Selection] { [
                .field("__typename", String.self),
                .field("name", String.self),
              ] }
              static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                GitHubRepositoryFactsQuery.Data.Repository.RepositoryTopics.Node.Topic.self
              ] }

              var name: String { __data["name"] }
            }
          }
        }

        /// Repository.Parent
        nonisolated struct Parent: GitHubAPI.SelectionSet {
          let __data: DataDict
          init(_dataDict: DataDict) { __data = _dataDict }

          static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.Repository }
          static var __selections: [ApolloAPI.Selection] { [
            .field("__typename", String.self),
            .fragment(GitHubRepositoryIdentity.self),
          ] }
          static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
            GitHubRepositoryFactsQuery.Data.Repository.Parent.self,
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

        typealias Owner = GitHubRepositoryIdentity.Owner
      }
    }
  }

}
