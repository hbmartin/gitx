// @generated
// This file was automatically generated and should not be edited.

import ApolloAPI
@_spi(Execution) @_spi(Unsafe) import ApolloAPI

extension GitHubAPI {
  nonisolated struct GitHubSyncForkPreflightQuery: GraphQLQuery {
    static let operationName: String = "GitHubSyncForkPreflight"
    static let operationDocument: ApolloAPI.OperationDocument = .init(
      definition: .init(
        #"query GitHubSyncForkPreflight($owner: String!, $name: String!) { repository(owner: $owner, name: $name) { __typename ...GitHubRepositoryIdentity isFork parent { __typename ...GitHubRepositoryIdentity } } }"#,
        fragments: [GitHubRepositoryIdentity.self]
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
        GitHubSyncForkPreflightQuery.Data.self
      ] }

      var repository: Repository? { __data["repository"] }

      /// Repository
      nonisolated struct Repository: GitHubAPI.SelectionSet {
        let __data: DataDict
        init(_dataDict: DataDict) { __data = _dataDict }

        static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.Repository }
        static var __selections: [ApolloAPI.Selection] { [
          .field("__typename", String.self),
          .field("isFork", Bool.self),
          .field("parent", Parent?.self),
          .fragment(GitHubRepositoryIdentity.self),
        ] }
        static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
          GitHubSyncForkPreflightQuery.Data.Repository.self,
          GitHubRepositoryIdentity.self
        ] }

        var isFork: Bool { __data["isFork"] }
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
            GitHubSyncForkPreflightQuery.Data.Repository.Parent.self,
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
