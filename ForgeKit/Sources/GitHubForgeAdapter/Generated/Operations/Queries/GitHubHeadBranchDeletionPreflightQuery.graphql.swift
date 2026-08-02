// @generated
// This file was automatically generated and should not be edited.

import ApolloAPI
@_spi(Execution) @_spi(Unsafe) import ApolloAPI

extension GitHubAPI {
  nonisolated struct GitHubHeadBranchDeletionPreflightQuery: GraphQLQuery {
    static let operationName: String = "GitHubHeadBranchDeletionPreflight"
    static let operationDocument: ApolloAPI.OperationDocument = .init(
      definition: .init(
        #"query GitHubHeadBranchDeletionPreflight($owner: String!, $name: String!, $qualifiedName: String!) { repository(owner: $owner, name: $name) { __typename ...GitHubRepositoryIdentity defaultBranchRef { __typename name } viewerPermission ref(qualifiedName: $qualifiedName) { __typename id name branchProtectionRule { __typename id } target { __typename oid } } } }"#,
        fragments: [GitHubRepositoryIdentity.self]
      ))

    public var owner: String
    public var name: String
    public var qualifiedName: String

    public init(
      owner: String,
      name: String,
      qualifiedName: String
    ) {
      self.owner = owner
      self.name = name
      self.qualifiedName = qualifiedName
    }

    @_spi(Unsafe) public var __variables: Variables? { [
      "owner": owner,
      "name": name,
      "qualifiedName": qualifiedName
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
        GitHubHeadBranchDeletionPreflightQuery.Data.self
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
          .field("viewerPermission", GraphQLEnum<GitHubAPI.RepositoryPermission>?.self),
          .field("ref", Ref?.self, arguments: ["qualifiedName": .variable("qualifiedName")]),
          .fragment(GitHubRepositoryIdentity.self),
        ] }
        static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
          GitHubHeadBranchDeletionPreflightQuery.Data.Repository.self,
          GitHubRepositoryIdentity.self
        ] }

        var defaultBranchRef: DefaultBranchRef? { __data["defaultBranchRef"] }
        var viewerPermission: GraphQLEnum<GitHubAPI.RepositoryPermission>? { __data["viewerPermission"] }
        var ref: Ref? { __data["ref"] }
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
            GitHubHeadBranchDeletionPreflightQuery.Data.Repository.DefaultBranchRef.self
          ] }

          var name: String { __data["name"] }
        }

        /// Repository.Ref
        nonisolated struct Ref: GitHubAPI.SelectionSet {
          let __data: DataDict
          init(_dataDict: DataDict) { __data = _dataDict }

          static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.Ref }
          static var __selections: [ApolloAPI.Selection] { [
            .field("__typename", String.self),
            .field("id", GitHubAPI.ID.self),
            .field("name", String.self),
            .field("branchProtectionRule", BranchProtectionRule?.self),
            .field("target", Target?.self),
          ] }
          static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
            GitHubHeadBranchDeletionPreflightQuery.Data.Repository.Ref.self
          ] }

          var id: GitHubAPI.ID { __data["id"] }
          var name: String { __data["name"] }
          var branchProtectionRule: BranchProtectionRule? { __data["branchProtectionRule"] }
          var target: Target? { __data["target"] }

          /// Repository.Ref.BranchProtectionRule
          nonisolated struct BranchProtectionRule: GitHubAPI.SelectionSet {
            let __data: DataDict
            init(_dataDict: DataDict) { __data = _dataDict }

            static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Objects.BranchProtectionRule }
            static var __selections: [ApolloAPI.Selection] { [
              .field("__typename", String.self),
              .field("id", GitHubAPI.ID.self),
            ] }
            static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
              GitHubHeadBranchDeletionPreflightQuery.Data.Repository.Ref.BranchProtectionRule.self
            ] }

            var id: GitHubAPI.ID { __data["id"] }
          }

          /// Repository.Ref.Target
          nonisolated struct Target: GitHubAPI.SelectionSet {
            let __data: DataDict
            init(_dataDict: DataDict) { __data = _dataDict }

            static var __parentType: any ApolloAPI.ParentType { GitHubAPI.Interfaces.GitObject }
            static var __selections: [ApolloAPI.Selection] { [
              .field("__typename", String.self),
              .field("oid", GitHubAPI.GitObjectID.self),
            ] }
            static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
              GitHubHeadBranchDeletionPreflightQuery.Data.Repository.Ref.Target.self
            ] }

            var oid: GitHubAPI.GitObjectID { __data["oid"] }
          }
        }

        typealias Owner = GitHubRepositoryIdentity.Owner
      }
    }
  }

}
