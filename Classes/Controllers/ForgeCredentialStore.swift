import ForgeKit
import Foundation
import OSLog
import Security

nonisolated enum ForgeKeychainOperation: String, Equatable, Sendable {
    case read
    case list
    case write
    case remove
}

nonisolated enum ForgeKeychainError: Error, Equatable, LocalizedError, Sendable {
    case interactionNotAllowed(operation: ForgeKeychainOperation)
    case authorizationFailed(operation: ForgeKeychainOperation)
    case unexpectedStatus(operation: ForgeKeychainOperation, status: OSStatus)

    init(operation: ForgeKeychainOperation, status: OSStatus) {
        switch status {
        case errSecInteractionNotAllowed:
            self = .interactionNotAllowed(operation: operation)
        case errSecAuthFailed:
            self = .authorizationFailed(operation: operation)
        default:
            self = .unexpectedStatus(operation: operation, status: status)
        }
    }

    var errorDescription: String? {
        switch self {
        case let .interactionNotAllowed(operation):
            "Credential \(operation.rawValue) requires an unlocked Keychain."
        case let .authorizationFailed(operation):
            "Credential \(operation.rawValue) was not authorized by the Keychain."
        case let .unexpectedStatus(operation, status):
            "Credential \(operation.rawValue) failed with Keychain status \(status)."
        }
    }
}

nonisolated struct ForgeKeychainItem: Equatable, Sendable,
    CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable
{
    let accountKey: String
    let data: Data

    var description: String {
        "<redacted Forge Keychain item>"
    }

    var debugDescription: String {
        description
    }

    var customMirror: Mirror {
        Mirror(self, children: [:])
    }
}

nonisolated protocol ForgeCredentialKeychain: Sendable {
    func data(for accountKey: String) throws -> Data?
    func allItems() throws -> [ForgeKeychainItem]
    func replace(_ data: Data, for accountKey: String) throws
    func remove(accountKey: String) throws
}

nonisolated protocol ForgeSecurityItemCalling: Sendable {
    func copyMatching(_ query: [String: Any]) -> (status: OSStatus, result: Any?)
    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus
    func add(_ attributes: [String: Any]) -> OSStatus
    func delete(_ query: [String: Any]) -> OSStatus
}

nonisolated struct SystemForgeSecurityItemClient: ForgeSecurityItemCalling {
    func copyMatching(_ query: [String: Any]) -> (status: OSStatus, result: Any?) {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return (status, result)
    }

    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus {
        SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    }

    func add(_ attributes: [String: Any]) -> OSStatus {
        SecItemAdd(attributes as CFDictionary, nil)
    }

    func delete(_ query: [String: Any]) -> OSStatus {
        SecItemDelete(query as CFDictionary)
    }
}

// swift6-safety-justification: The adapter has immutable state and delegates to the thread-safe Security framework.
final nonisolated class SecurityForgeCredentialKeychain: ForgeCredentialKeychain, @unchecked Sendable {
    static let defaultService = "com.gitx.gitx.forge-credentials.v1"

    private let service: String
    private let client: any ForgeSecurityItemCalling
    private let logger = Logger(subsystem: "com.gitx.gitx", category: "ForgeKeychain")

    init(
        service: String = SecurityForgeCredentialKeychain.defaultService,
        client: any ForgeSecurityItemCalling = SystemForgeSecurityItemClient()
    ) {
        self.service = service
        self.client = client
    }

    func data(for accountKey: String) throws -> Data? {
        var query = Self.genericPasswordQuery(service: service, accountKey: accountKey)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let response = client.copyMatching(query)
        let status = response.status
        if status == errSecItemNotFound {
            return nil
        }
        try requireSuccess(status, operation: .read)
        guard let data = response.result as? Data else {
            throw ForgeKeychainError.unexpectedStatus(operation: .read, status: errSecDecode)
        }
        logger.debug("Credential Keychain read completed")
        return data
    }

    func allItems() throws -> [ForgeKeychainItem] {
        var query = Self.genericPasswordQuery(service: service, accountKey: nil)
        query[kSecReturnAttributes as String] = true
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        let response = client.copyMatching(query)
        let status = response.status
        if status == errSecItemNotFound {
            return []
        }
        try requireSuccess(status, operation: .list)
        guard let dictionaries = response.result as? [[String: Any]] else {
            throw ForgeKeychainError.unexpectedStatus(operation: .list, status: errSecDecode)
        }
        let items = try dictionaries.map { dictionary -> ForgeKeychainItem in
            guard let accountKey = dictionary[kSecAttrAccount as String] as? String,
                  let data = dictionary[kSecValueData as String] as? Data
            else {
                throw ForgeKeychainError.unexpectedStatus(operation: .list, status: errSecDecode)
            }
            return ForgeKeychainItem(accountKey: accountKey, data: data)
        }
        logger.debug("Credential Keychain list completed count=\(items.count, privacy: .public)")
        return items
    }

    func replace(_ data: Data, for accountKey: String) throws {
        let query = Self.genericPasswordQuery(service: service, accountKey: accountKey)
        let attributes = [kSecValueData as String: data]
        var status = client.update(query, attributes: attributes)
        if status == errSecItemNotFound {
            var insertion = query
            insertion[kSecValueData as String] = data
            insertion[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = client.add(insertion)
            if status == errSecDuplicateItem {
                status = client.update(query, attributes: attributes)
            }
        }
        try requireSuccess(status, operation: .write)
        logger.notice("Credential Keychain write completed")
    }

    func remove(accountKey: String) throws {
        let status = client.delete(Self.genericPasswordQuery(
            service: service,
            accountKey: accountKey
        ))
        guard status != errSecItemNotFound else {
            return
        }
        try requireSuccess(status, operation: .remove)
        logger.notice("Credential Keychain removal completed")
    }

    static func genericPasswordQuery(service: String, accountKey: String?) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
        ]
        if let accountKey {
            query[kSecAttrAccount as String] = accountKey
        }
        return query
    }

    private func requireSuccess(_ status: OSStatus, operation: ForgeKeychainOperation) throws {
        guard status == errSecSuccess else {
            logger.error(
                "Credential Keychain operation failed operation=\(operation.rawValue, privacy: .public) status=\(status, privacy: .public)"
            )
            throw ForgeKeychainError(operation: operation, status: status)
        }
    }
}

nonisolated enum ForgeCredentialStoreError: Error, Equatable, LocalizedError, Sendable {
    case accountAlreadyExists
    case accountNotFound
    case credentialReferenceMismatch
    case credentialSourceMismatch
    case generationExhausted
    case invalidCredentialSecretShape
    case invalidSecretMaterial
    case malformedStoredCredential
    case storedAccountMismatch
    case keychain(ForgeKeychainError)

    var errorDescription: String? {
        switch self {
        case .accountAlreadyExists:
            "The Forge Account already has a current Credential."
        case .accountNotFound:
            "The Forge Account does not have a stored Credential."
        case .credentialReferenceMismatch:
            "The stored Credential reference does not match the requested reference."
        case .credentialSourceMismatch:
            "The stored Credential cannot be rotated by this authentication flow."
        case .generationExhausted:
            "The Credential replacement generation is exhausted."
        case .invalidCredentialSecretShape:
            "The Credential secret material does not match its authentication source."
        case .invalidSecretMaterial:
            "The Credential secret material is invalid."
        case .malformedStoredCredential:
            "The stored Credential could not be decoded."
        case .storedAccountMismatch:
            "The stored Credential belongs to a different Forge Account."
        case let .keychain(error):
            error.localizedDescription
        }
    }
}

nonisolated struct ForgeCredentialSecretMaterial: Codable, Sendable,
    CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable
{
    private let accessToken: Data
    private let refreshToken: Data?
    let refreshTokenExpiresAt: Date?

    init(accessToken: Data, refreshToken: Data? = nil, refreshTokenExpiresAt: Date? = nil) throws {
        guard Self.isValidSecret(accessToken) else {
            throw ForgeCredentialStoreError.invalidSecretMaterial
        }
        guard (refreshToken == nil) == (refreshTokenExpiresAt == nil) else {
            throw ForgeCredentialStoreError.invalidCredentialSecretShape
        }
        if let refreshToken, !Self.isValidSecret(refreshToken) {
            throw ForgeCredentialStoreError.invalidSecretMaterial
        }
        if let refreshTokenExpiresAt, !refreshTokenExpiresAt.timeIntervalSinceReferenceDate.isFinite {
            throw ForgeCredentialStoreError.invalidSecretMaterial
        }
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.refreshTokenExpiresAt = refreshTokenExpiresAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            accessToken: container.decode(Data.self, forKey: .accessToken),
            refreshToken: container.decodeIfPresent(Data.self, forKey: .refreshToken),
            refreshTokenExpiresAt: container.decodeIfPresent(Date.self, forKey: .refreshTokenExpiresAt)
        )
    }

    func withUnsafeAccessTokenBytes<Result>(_ body: (Data) throws -> Result) rethrows -> Result {
        try body(accessToken)
    }

    func withUnsafeRefreshTokenBytes<Result>(_ body: (Data) throws -> Result) rethrows -> Result? {
        try refreshToken.map(body)
    }

    var hasRefreshToken: Bool {
        refreshToken != nil
    }

    var description: String {
        "<redacted Forge Credential secrets>"
    }

    var debugDescription: String {
        description
    }

    var customMirror: Mirror {
        Mirror(self, children: [:])
    }

    private static func isValidSecret(_ data: Data) -> Bool {
        !data.isEmpty && data.allSatisfy { byte in
            byte >= 0x21 && byte != 0x7F
        }
    }
}

nonisolated struct ForgeStoredCredentialEnvelope: Codable, Sendable,
    CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable
{
    let account: ForgeAccount
    let secrets: ForgeCredentialSecretMaterial

    init(account: ForgeAccount, secrets: ForgeCredentialSecretMaterial) throws {
        if let expiresAt = account.currentCredential.expiresAt,
           !expiresAt.timeIntervalSinceReferenceDate.isFinite
        {
            throw ForgeCredentialStoreError.invalidSecretMaterial
        }
        try Self.validate(
            source: account.currentCredential.source,
            expiresAt: account.currentCredential.expiresAt,
            secrets: secrets
        )
        self.account = account
        self.secrets = secrets
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            account: container.decode(ForgeAccount.self, forKey: .account),
            secrets: container.decode(ForgeCredentialSecretMaterial.self, forKey: .secrets)
        )
    }

    var description: String {
        "<redacted Forge Credential envelope>"
    }

    var debugDescription: String {
        description
    }

    var customMirror: Mirror {
        Mirror(self, children: [:])
    }

    private static func validate(
        source: ForgeCredentialSource,
        expiresAt: Date?,
        secrets: ForgeCredentialSecretMaterial
    ) throws {
        switch source {
        case .forgeApplicationDeviceFlow:
            guard expiresAt != nil, secrets.hasRefreshToken else {
                throw ForgeCredentialStoreError.invalidCredentialSecretShape
            }
        case .commandLineBroker, .fineGrainedPersonalAccessToken, .classicPersonalAccessToken:
            guard !secrets.hasRefreshToken else {
                throw ForgeCredentialStoreError.invalidCredentialSecretShape
            }
        }
    }
}

nonisolated enum ForgePersonalAccessTokenKind: Sendable {
    case fineGrained
    case classic

    var source: ForgeCredentialSource {
        switch self {
        case .fineGrained: .fineGrainedPersonalAccessToken
        case .classic: .classicPersonalAccessToken
        }
    }
}

actor ForgeAccountStore {
    private let keychain: any ForgeCredentialKeychain
    private let logger = Logger(subsystem: "com.gitx.gitx", category: "ForgeAccountStore")

    init(keychain: any ForgeCredentialKeychain) {
        self.keychain = keychain
    }

    func accounts() throws -> [ForgeAccount] {
        let items = try mapKeychainError { try keychain.allItems() }
        let accounts = try items.map { item -> ForgeAccount in
            let envelope = try decodeEnvelope(item.data)
            guard try item.accountKey == (Self.keychainAccountKey(for: envelope.account.id)) else {
                throw ForgeCredentialStoreError.storedAccountMismatch
            }
            return envelope.account
        }
        return accounts.sorted { lhs, rhs in
            let lhsKey = Self.sortKey(for: lhs)
            let rhsKey = Self.sortKey(for: rhs)
            return lhsKey.lexicographicallyPrecedes(rhsKey)
        }
    }

    func credential(for accountID: ForgeAccountID) throws -> ForgeStoredCredentialEnvelope? {
        let key = try Self.keychainAccountKey(for: accountID)
        guard let data = try mapKeychainError({ try keychain.data(for: key) }) else {
            return nil
        }
        let envelope = try decodeEnvelope(data)
        guard envelope.account.id == accountID else {
            throw ForgeCredentialStoreError.storedAccountMismatch
        }
        return envelope
    }

    @discardableResult
    func addPersonalAccessToken(
        accountID: ForgeAccountID,
        login: String,
        credentialID: ForgeCredentialID,
        kind: ForgePersonalAccessTokenKind,
        token: Data,
        expiresAt: Date?
    ) throws -> ForgeAccount {
        try addAccount(
            accountID: accountID,
            login: login,
            credentialID: credentialID,
            source: kind.source,
            expiresAt: expiresAt,
            secrets: ForgeCredentialSecretMaterial(accessToken: token)
        )
    }

    @discardableResult
    func addAccount(
        accountID: ForgeAccountID,
        login: String,
        credentialID: ForgeCredentialID,
        source: ForgeCredentialSource,
        expiresAt: Date?,
        secrets: ForgeCredentialSecretMaterial
    ) throws -> ForgeAccount {
        let key = try Self.keychainAccountKey(for: accountID)
        guard try mapKeychainError({ try keychain.data(for: key) }) == nil else {
            throw ForgeCredentialStoreError.accountAlreadyExists
        }
        let reference = try ForgeCredentialReference(
            accountID: accountID,
            credentialID: credentialID,
            generation: ForgeCredentialGeneration(1)
        )
        let account = try ForgeAccount(
            id: accountID,
            login: login,
            currentCredential: ForgeCredentialMetadata(
                reference: reference,
                source: source,
                expiresAt: expiresAt
            )
        )
        try persist(ForgeStoredCredentialEnvelope(account: account, secrets: secrets), key: key)
        logger.notice("Forge Account Credential added source=\(source.rawValue, privacy: .public)")
        return account
    }

    @discardableResult
    func rotateCredential(
        expectedReference: ForgeCredentialReference,
        expiresAt: Date?,
        secrets: ForgeCredentialSecretMaterial
    ) throws -> ForgeAccount {
        let envelope = try requiredCredential(for: expectedReference.accountID)
        guard envelope.account.currentCredential.reference == expectedReference else {
            throw ForgeCredentialStoreError.credentialReferenceMismatch
        }
        guard envelope.account.currentCredential.source == .forgeApplicationDeviceFlow else {
            throw ForgeCredentialStoreError.credentialSourceMismatch
        }
        let account = try ForgeAccount(
            id: envelope.account.id,
            login: envelope.account.login,
            currentCredential: envelope.account.currentCredential.refreshed(expiresAt: expiresAt)
        )
        let key = try Self.keychainAccountKey(for: account.id)
        try persist(ForgeStoredCredentialEnvelope(account: account, secrets: secrets), key: key)
        logger.notice("Forge Account Credential rotated generation retained")
        return account
    }

    @discardableResult
    func replaceCredential(
        expectedReference: ForgeCredentialReference,
        credentialID: ForgeCredentialID,
        source: ForgeCredentialSource,
        expiresAt: Date?,
        secrets: ForgeCredentialSecretMaterial
    ) throws -> ForgeAccount {
        let accountID = expectedReference.accountID
        let envelope = try requiredCredential(for: accountID)
        guard envelope.account.currentCredential.reference == expectedReference else {
            throw ForgeCredentialStoreError.credentialReferenceMismatch
        }
        let currentGeneration = envelope.account.currentCredential.reference.generation.value
        guard currentGeneration < UInt64.max else {
            throw ForgeCredentialStoreError.generationExhausted
        }
        let reference = try ForgeCredentialReference(
            accountID: accountID,
            credentialID: credentialID,
            generation: ForgeCredentialGeneration(currentGeneration + 1)
        )
        let account = try ForgeAccount(
            id: accountID,
            login: envelope.account.login,
            currentCredential: ForgeCredentialMetadata(
                reference: reference,
                source: source,
                expiresAt: expiresAt
            )
        )
        let key = try Self.keychainAccountKey(for: accountID)
        try persist(ForgeStoredCredentialEnvelope(account: account, secrets: secrets), key: key)
        logger.notice("Forge Account Credential replaced generation advanced")
        return account
    }

    func removeAccount(_ accountID: ForgeAccountID) throws {
        let key = try Self.keychainAccountKey(for: accountID)
        try mapKeychainError { try keychain.remove(accountKey: key) }
        logger.notice("Forge Account Credential removed")
    }

    static func keychainAccountKey(for accountID: ForgeAccountID) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try "forge-account-v1:" + (encoder.encode(accountID)).base64EncodedString()
    }

    private func requiredCredential(for accountID: ForgeAccountID) throws -> ForgeStoredCredentialEnvelope {
        guard let envelope = try credential(for: accountID) else {
            throw ForgeCredentialStoreError.accountNotFound
        }
        return envelope
    }

    private func persist(_ envelope: ForgeStoredCredentialEnvelope, key: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data: Data
        do {
            data = try encoder.encode(envelope)
        } catch {
            throw ForgeCredentialStoreError.malformedStoredCredential
        }
        try mapKeychainError { try keychain.replace(data, for: key) }
    }

    private func decodeEnvelope(_ data: Data) throws -> ForgeStoredCredentialEnvelope {
        do {
            return try JSONDecoder().decode(ForgeStoredCredentialEnvelope.self, from: data)
        } catch let error as ForgeCredentialStoreError {
            throw error
        } catch {
            throw ForgeCredentialStoreError.malformedStoredCredential
        }
    }

    private func mapKeychainError<Result>(_ operation: () throws -> Result) throws -> Result {
        do {
            return try operation()
        } catch let error as ForgeKeychainError {
            throw ForgeCredentialStoreError.keychain(error)
        }
    }

    private static func sortKey(for account: ForgeAccount) -> [String] {
        [
            account.id.forge.kind.rawValue,
            account.id.forge.origin.url.absoluteString,
            account.login,
            account.id.value,
        ]
    }
}
