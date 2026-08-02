import Foundation

public enum ForgeAccountError: Error, Equatable, LocalizedError, Sendable {
    case invalidCredentialIdentifier
    case invalidCredentialGeneration
    case invalidAccountLogin
    case mismatchedCredentialAccount

    public var errorDescription: String? {
        switch self {
        case .invalidCredentialIdentifier:
            "The Credential identifier is invalid."
        case .invalidCredentialGeneration:
            "The Credential generation is invalid."
        case .invalidAccountLogin:
            "The Forge Account login is invalid."
        case .mismatchedCredentialAccount:
            "The Credential belongs to a different Forge Account."
        }
    }
}

/// A stable, non-secret identifier. Token material and token-derived hashes
/// must never be used as this value.
public struct ForgeCredentialID: Codable, Hashable, Sendable {
    public let value: String

    public init(_ value: String) throws {
        guard ForgePathComponent.isNonemptyPrintable(value) else {
            throw ForgeAccountError.invalidCredentialIdentifier
        }
        self.value = value
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(container.decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}

/// Identifies replacement of a logical Credential. Ordinary access-token
/// refresh and refresh-token rotation retain the same generation.
public struct ForgeCredentialGeneration: Codable, Comparable, Hashable, Sendable {
    public let value: UInt64

    public init(_ value: UInt64) throws {
        guard value > 0 else {
            throw ForgeAccountError.invalidCredentialGeneration
        }
        self.value = value
    }

    public static func < (lhs: ForgeCredentialGeneration, rhs: ForgeCredentialGeneration) -> Bool {
        lhs.value < rhs.value
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(container.decode(UInt64.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}

public enum ForgeCredentialSource: String, Codable, Hashable, Sendable {
    case forgeApplicationDeviceFlow
    case commandLineBroker
    case fineGrainedPersonalAccessToken
    case classicPersonalAccessToken
}

public struct ForgeCredentialReference: Codable, Hashable, Sendable {
    public let accountID: ForgeAccountID
    public let credentialID: ForgeCredentialID
    public let generation: ForgeCredentialGeneration

    public init(
        accountID: ForgeAccountID,
        credentialID: ForgeCredentialID,
        generation: ForgeCredentialGeneration
    ) {
        self.accountID = accountID
        self.credentialID = credentialID
        self.generation = generation
    }
}

/// Safe metadata for the one current Credential. Secret material remains in
/// the credential store and is deliberately absent from this value.
public struct ForgeCredentialMetadata: Codable, Hashable, Sendable {
    public let reference: ForgeCredentialReference
    public let source: ForgeCredentialSource
    public let expiresAt: Date?

    public init(
        reference: ForgeCredentialReference,
        source: ForgeCredentialSource,
        expiresAt: Date? = nil
    ) {
        self.reference = reference
        self.source = source
        self.expiresAt = expiresAt
    }

    /// Token rotation changes expiry metadata, not the logical Credential.
    public func refreshed(expiresAt: Date?) -> ForgeCredentialMetadata {
        ForgeCredentialMetadata(reference: reference, source: source, expiresAt: expiresAt)
    }
}

public struct ForgeAccount: Codable, Hashable, Sendable {
    public let id: ForgeAccountID
    public let login: String
    public let currentCredential: ForgeCredentialMetadata

    public init(
        id: ForgeAccountID,
        login: String,
        currentCredential: ForgeCredentialMetadata
    ) throws {
        guard ForgePathComponent.isNonemptyPrintable(login) else {
            throw ForgeAccountError.invalidAccountLogin
        }
        guard currentCredential.reference.accountID == id else {
            throw ForgeAccountError.mismatchedCredentialAccount
        }
        self.id = id
        self.login = login
        self.currentCredential = currentCredential
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: container.decode(ForgeAccountID.self, forKey: .id),
            login: container.decode(String.self, forKey: .login),
            currentCredential: container.decode(ForgeCredentialMetadata.self, forKey: .currentCredential)
        )
    }
}
