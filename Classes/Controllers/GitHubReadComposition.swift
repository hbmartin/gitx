import ForgeKit
import Foundation
import GitHubForgeAdapter
import OSLog

nonisolated enum ForgeGitHubReadCompositionError: Error, Equatable, LocalizedError, Sendable {
    case githubDotComCredentialRequired

    var errorDescription: String? {
        switch self {
        case .githubDotComCredentialRequired:
            "GitHub reads require a GitHub.com Credential."
        }
    }
}

/// Resolves authentication from the one Keychain-backed current Credential
/// for each request. It never consults GitHub CLI or another account.
final nonisolated class ForgeGitHubReadCredentialAuthority: GitHubReadCredentialAuthority, Sendable,
    CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable
{
    typealias NowProvider = @Sendable () -> Date

    private let accountStore: ForgeAccountStore
    private let now: NowProvider
    private let logger = Logger(subsystem: "com.gitx.gitx", category: "GitHubReadAuthority")

    init(
        accountStore: ForgeAccountStore,
        now: @escaping NowProvider = { Date() }
    ) {
        self.accountStore = accountStore
        self.now = now
    }

    func currentAuthentication(
        for expectedCredential: ForgeCredentialReference
    ) async throws -> GitHubReadAuthentication? {
        try Task.checkCancellation()
        guard Self.isGitHubDotCom(expectedCredential.accountID.forge) else {
            logger.error("Rejected non-GitHub.com read Credential")
            return nil
        }
        guard let envelope = try await accountStore.credential(for: expectedCredential.accountID) else {
            logger.notice("GitHub read Credential is unavailable")
            return nil
        }
        let account = envelope.account
        let credential = account.currentCredential
        try Task.checkCancellation()
        guard credential.reference == expectedCredential else {
            logger.notice("GitHub read Credential reference is no longer current")
            return nil
        }
        guard credential.expiresAt.map({ $0 > now() }) ?? true else {
            logger.notice("GitHub read Credential is expired")
            return nil
        }
        let accessToken = try envelope.secrets.withUnsafeAccessTokenBytes {
            try GitHubSecret(utf8Bytes: $0)
        }
        logger.debug("Resolved exact GitHub read Credential from Keychain authority")
        return try GitHubReadAuthentication(
            account: account,
            credential: credential,
            accessToken: accessToken
        )
    }

    var description: String {
        "GitHub read Credential authority (secrets redacted)"
    }

    var debugDescription: String {
        description
    }

    var customMirror: Mirror {
        Mirror(self, children: [:])
    }

    func credentialChange(
        for expectedCredential: ForgeCredentialReference
    ) async throws -> ForgeAccountCredentialChange {
        guard Self.isGitHubDotCom(expectedCredential.accountID.forge) else {
            throw ForgeGitHubReadCompositionError.githubDotComCredentialRequired
        }
        return try await accountStore.credentialChange(for: expectedCredential.accountID)
    }

    fileprivate static func isGitHubDotCom(_ forge: ForgeIdentity) -> Bool {
        guard forge.kind == .github else { return false }
        let origin = forge.origin.url
        return origin.scheme == "https" &&
            origin.host?.lowercased() == "github.com" &&
            origin.user == nil &&
            origin.password == nil &&
            origin.port == nil &&
            (origin.path.isEmpty || origin.path == "/") &&
            origin.query == nil &&
            origin.fragment == nil
    }
}

/// Produces an uncached adapter bound to one exact Credential reference. The
/// adapter re-enters the authority before every request, so retained adapters
/// see same-generation token rotation and fail closed after replacement or
/// removal.
final nonisolated class ForgeGitHubReadAdapterFactory: Sendable,
    CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable
{
    private let credentialAuthority: ForgeGitHubReadCredentialAuthority
    private let logger = Logger(subsystem: "com.gitx.gitx", category: "GitHubReadComposition")

    init(credentialAuthority: ForgeGitHubReadCredentialAuthority) {
        self.credentialAuthority = credentialAuthority
    }

    func makeAdapter(
        for expectedCredential: ForgeCredentialReference,
        sessionConfiguration: URLSessionConfiguration = .default
    ) throws -> GitHubReadAdapter {
        guard ForgeGitHubReadCredentialAuthority.isGitHubDotCom(expectedCredential.accountID.forge) else {
            logger.error("Rejected adapter creation for non-GitHub.com Credential")
            throw ForgeGitHubReadCompositionError.githubDotComCredentialRequired
        }
        logger.debug("Created exact-reference GitHub read adapter")
        return GitHubReadAdapter(
            expectedCredential: expectedCredential,
            credentialAuthority: credentialAuthority,
            sessionConfiguration: sessionConfiguration
        )
    }

    func credentialChange(
        for expectedCredential: ForgeCredentialReference
    ) async throws -> ForgeAccountCredentialChange {
        try await credentialAuthority.credentialChange(for: expectedCredential)
    }

    var description: String {
        "Exact-reference GitHub read adapter factory (secrets redacted)"
    }

    var debugDescription: String {
        description
    }

    var customMirror: Mirror {
        Mirror(self, children: [:])
    }
}
