// @generated
// This file was automatically generated and should not be edited.

import ApolloAPI
@_spi(Execution) @_spi(Unsafe) import ApolloAPI

extension GitHubAPI {
  nonisolated struct GitHubPullRequestMutationSnapshot: GitHubAPI.SelectionSet, Fragment {
    static var fragmentDefinition: StaticString {
      #"fragment GitHubPullRequestMutationSnapshot on PullRequest { __typename id number title body state isDraft createdAt updatedAt closedAt mergedAt headRefName headRefOid headRepository { __typename ...GitHubRepositoryIdentity } baseRefName baseRefOid baseRepository { __typename ...GitHubRepositoryIdentity } }"#
    }

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
    ] }
    static var __fulfilledFragments: [any ApolloAPI.SelectionSet.Type] { [
      GitHubPullRequestMutationSnapshot.self
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
        GitHubPullRequestMutationSnapshot.HeadRepository.self,
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
        GitHubPullRequestMutationSnapshot.BaseRepository.self,
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
