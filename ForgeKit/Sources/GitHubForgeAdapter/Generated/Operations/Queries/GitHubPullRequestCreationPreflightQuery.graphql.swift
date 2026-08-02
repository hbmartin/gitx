// @generated
// This file was automatically generated and should not be edited.

import ApolloAPI
@_spi(Execution) @_spi(Unsafe) import ApolloAPI

extension GitHubAPI {
  nonisolated struct GitHubPullRequestCreationPreflightQuery: GraphQLQuery {
    static let operationName: String = "GitHubPullRequestCreationPreflight"
    static let operationDocument: ApolloAPI.OperationDocument = .init(
      definition: .init(
        #"query GitHubPullRequestCreationPreflight($owner: String!, $name: String!, $headOwner: String!, $headName: String!, $baseRefName: String!, $headRefName: String!, $after: String) { repository(owner: $owner, name: $name) { __typename ...GitHubRepositoryIdentity id pullRequests( first: 100 after: $after states: [OPEN] baseRefName: $baseRefName headRefName: $headRefName ) { __typename totalCount pageInfo { __typename ...GitHubPageInfo } nodes { __typename ...GitHubPullRequestMutationSnapshot id number title body state isDraft createdAt updatedAt closedAt mergedAt headRefName headRefOid headRepository { __typename ...GitHubRepositoryIdentity } baseRefName baseRefOid baseRepository { __typename ...GitHubRepositoryIdentity } } } } headRepository: repository(owner: $headOwner, name: $headName) { __typename ...GitHubRepositoryIdentity id } }"#,
        fragments: [GitHubPageInfo.self, GitHubPullRequestMutationSnapshot.self, GitHubRepositoryIdentity.self]
      ))

    public var owner: String
    public var name: String
    public var headOwner: String
    public var headName: String
    public var baseRefName: String
    public var headRefName: String
    public var after: GraphQLNullable<String>

    public init(
      owner: String,
      name: String,
      headOwner: String,
      headName: String,
      baseRefName: String,
      headRefName: String,
      after: GraphQLNullable<String>
    ) {
      self.owner = owner
      self.name = name
      self.headOwner = headOwner
      self.headName = headName
      self.baseRefName = baseRefName
      self.headRefName = headRefName
      self.after = after
    }

    @_spi(Unsafe) public var __variables: Variables? { [
      "owner": owner,
      "name": name,
      "headOwner": headOwner,
      "headName": headName,
      "baseRefName": baseRefName,
      "headRefName": headRefName,
      "after": after
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
        .field("repository", alias: "headRepository", HeadRepository?.self, arguments: [
          "owner": .variable("headOwner"),
          "name": .variable("headName")
        ]),
      ] }
      static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
        GitHubPullRequestCreationPreflightQuery.Data.self
      ] }

      var repository: Repository? { __data["repository"] }
      var headRepository: HeadRepository? { __data["headRepository"] }

      /// Repository
      nonisolated struct Repository: GitHubAPI.SelectionSet {
        let __data: DataDict
        init(_dataDict: DataDict) { __data = _dataDict }

        static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.Repository }
        static var __selections: [ApolloAPI.Selection] { [
          .field("__typename", String.self),
          .field("id", GitHubAPI.ID.self),
          .field("pullRequests", PullRequests.self, arguments: [
            "first": 100,
            "after": .variable("after"),
            "states": ["OPEN"],
            "baseRefName": .variable("baseRefName"),
            "headRefName": .variable("headRefName")
          ]),
          .fragment(GitHubRepositoryIdentity.self),
        ] }
        static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
          GitHubPullRequestCreationPreflightQuery.Data.Repository.self,
          GitHubRepositoryIdentity.self
        ] }

        var id: GitHubAPI.ID { __data["id"] }
        var pullRequests: PullRequests { __data["pullRequests"] }
        var name: String { __data["name"] }
        var nameWithOwner: String { __data["nameWithOwner"] }
        var owner: Owner { __data["owner"] }

        struct Fragments: FragmentContainer {
          let __data: DataDict
          init(_dataDict: DataDict) { __data = _dataDict }

          var gitHubRepositoryIdentity: GitHubRepositoryIdentity { _toFragment() }
        }

        /// Repository.PullRequests
        nonisolated struct PullRequests: GitHubAPI.SelectionSet {
          let __data: DataDict
          init(_dataDict: DataDict) { __data = _dataDict }

          static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.PullRequestConnection }
          static var __selections: [ApolloAPI.Selection] { [
            .field("__typename", String.self),
            .field("totalCount", Int.self),
            .field("pageInfo", PageInfo.self),
            .field("nodes", [Node?]?.self),
          ] }
          static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
            GitHubPullRequestCreationPreflightQuery.Data.Repository.PullRequests.self
          ] }

          var totalCount: Int { __data["totalCount"] }
          var pageInfo: PageInfo { __data["pageInfo"] }
          var nodes: [Node?]? { __data["nodes"] }

          /// Repository.PullRequests.PageInfo
          nonisolated struct PageInfo: GitHubAPI.SelectionSet {
            let __data: DataDict
            init(_dataDict: DataDict) { __data = _dataDict }

            static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.PageInfo }
            static var __selections: [ApolloAPI.Selection] { [
              .field("__typename", String.self),
              .fragment(GitHubPageInfo.self),
            ] }
            static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
              GitHubPullRequestCreationPreflightQuery.Data.Repository.PullRequests.PageInfo.self,
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

          /// Repository.PullRequests.Node
          nonisolated struct Node: GitHubAPI.SelectionSet {
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
              .fragment(GitHubPullRequestMutationSnapshot.self),
            ] }
            static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
              GitHubPullRequestCreationPreflightQuery.Data.Repository.PullRequests.Node.self
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

            struct Fragments: FragmentContainer {
              let __data: DataDict
              init(_dataDict: DataDict) { __data = _dataDict }

              var gitHubPullRequestMutationSnapshot: GitHubPullRequestMutationSnapshot { _toFragment() }
            }

            /// Repository.PullRequests.Node.HeadRepository
            nonisolated struct HeadRepository: GitHubAPI.SelectionSet {
              let __data: DataDict
              init(_dataDict: DataDict) { __data = _dataDict }

              static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.Repository }
              static var __selections: [ApolloAPI.Selection] { [
                .field("__typename", String.self),
                .fragment(GitHubRepositoryIdentity.self),
              ] }
              static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                GitHubPullRequestCreationPreflightQuery.Data.Repository.PullRequests.Node.HeadRepository.self,
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

            /// Repository.PullRequests.Node.BaseRepository
            nonisolated struct BaseRepository: GitHubAPI.SelectionSet {
              let __data: DataDict
              init(_dataDict: DataDict) { __data = _dataDict }

              static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.Repository }
              static var __selections: [ApolloAPI.Selection] { [
                .field("__typename", String.self),
                .fragment(GitHubRepositoryIdentity.self),
              ] }
              static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
                GitHubPullRequestCreationPreflightQuery.Data.Repository.PullRequests.Node.BaseRepository.self,
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

        typealias Owner = GitHubRepositoryIdentity.Owner
      }

      /// HeadRepository
      nonisolated struct HeadRepository: GitHubAPI.SelectionSet {
        let __data: DataDict
        init(_dataDict: DataDict) { __data = _dataDict }

        static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.Repository }
        static var __selections: [ApolloAPI.Selection] { [
          .field("__typename", String.self),
          .field("id", GitHubAPI.ID.self),
          .fragment(GitHubRepositoryIdentity.self),
        ] }
        static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
          GitHubPullRequestCreationPreflightQuery.Data.HeadRepository.self,
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
