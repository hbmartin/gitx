import ForgeKit
import Security
import XCTest

final class ForgeCredentialStoreTests: XCTestCase {
    func testSystemSecurityClientForwardsReadOnlyGenericPasswordQuery() {
        let uniqueValue = "com.gitx.tests.missing.\(UUID().uuidString)"
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: uniqueValue,
            kSecAttrAccount as String: uniqueValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        let response = SystemForgeSecurityItemClient().copyMatching(query)

        XCTAssertEqual(response.status, errSecItemNotFound)
        XCTAssertNil(response.result)
    }

    func testPATStorageListsOnlySafeMetadataAndRedactsSecretSurfaces() async throws {
        let keychain = InMemoryForgeCredentialKeychain()
        let store = ForgeAccountStore(keychain: keychain)
        let accountID = try makeAccountID("node-1")
        let account = try await store.addPersonalAccessToken(
            accountID: accountID,
            login: "octocat",
            credentialID: ForgeCredentialID("pat-1"),
            kind: .fineGrained,
            token: Data("github_pat_secret-value".utf8),
            expiresAt: Date(timeIntervalSince1970: 1000)
        )

        XCTAssertEqual(account.currentCredential.source, .fineGrainedPersonalAccessToken)
        XCTAssertEqual(account.currentCredential.reference.generation, try ForgeCredentialGeneration(1))
        let accounts = try await store.accounts()
        XCTAssertEqual(accounts, [account])

        let storedCredential = try await store.credential(for: accountID)
        let envelope = try XCTUnwrap(storedCredential)
        XCTAssertEqual(
            envelope.secrets.withUnsafeAccessTokenBytes { Data($0) },
            Data("github_pat_secret-value".utf8)
        )
        XCTAssertNil(envelope.secrets.withUnsafeRefreshTokenBytes { Data($0) })
        XCTAssertFalse(String(describing: envelope).contains("secret-value"))
        XCTAssertFalse(String(reflecting: envelope).contains("secret-value"))
        XCTAssertTrue(envelope.customMirror.children.isEmpty)
        XCTAssertFalse(try String(decoding: JSONEncoder().encode(account), as: UTF8.self).contains("secret-value"))
        XCTAssertEqual(keychain.count, 1, "one current Credential is stored per Forge Account")

        let rawItem = ForgeKeychainItem(accountKey: "safe-account", data: Data("encoded-secret-value".utf8))
        XCTAssertFalse(String(describing: rawItem).contains("encoded-secret-value"))
        XCTAssertFalse(String(reflecting: rawItem).contains("encoded-secret-value"))
        XCTAssertTrue(rawItem.customMirror.children.isEmpty)
    }

    func testSafeAuthorizationEvidencePersistsRotatesInvalidatesAndNeverLeaksTokenMaterial() async throws {
        let keychain = InMemoryForgeCredentialKeychain()
        let store = ForgeAccountStore(keychain: keychain)
        let accountID = try makeAccountID("node-evidence")
        let account = try await store.addPersonalAccessToken(
            accountID: accountID,
            login: "octocat",
            credentialID: ForgeCredentialID("pat-evidence"),
            kind: .classic,
            token: Data("classic-secret".utf8),
            expiresAt: nil,
            authorizationEvidence: .githubClassicScopes(["repo", "read:org"])
        )
        var stored = try await store.credential(for: accountID)
        var envelope = try XCTUnwrap(stored)
        XCTAssertEqual(envelope.authorizationEvidence, .githubClassicScopes(["repo", "read:org"]))
        XCTAssertFalse(try String(decoding: JSONEncoder().encode(envelope), as: UTF8.self).contains("classic-secret"))

        try await store.clearAuthorizationEvidence(for: account.currentCredential.reference)
        stored = try await store.credential(for: accountID)
        envelope = try XCTUnwrap(stored)
        XCTAssertNil(envelope.authorizationEvidence)
        let clearedChange = try await store.credentialChange(for: accountID)
        XCTAssertEqual(clearedChange.revision, 2)

        try await store.updateAuthorizationEvidence(
            .githubClassicScopes(["public_repo"]),
            for: account.currentCredential.reference
        )
        let replacement = try await store.replaceCredential(
            expectedReference: account.currentCredential.reference,
            credentialID: ForgeCredentialID("fine-replacement"),
            source: .fineGrainedPersonalAccessToken,
            expiresAt: nil,
            secrets: ForgeCredentialSecretMaterial(accessToken: Data("fine-secret".utf8))
        )
        stored = try await store.credential(for: accountID)
        envelope = try XCTUnwrap(stored)
        XCTAssertNil(envelope.authorizationEvidence, "replacement must invalidate evidence from the prior generation")
        XCTAssertEqual(replacement.currentCredential.reference.generation, try ForgeCredentialGeneration(2))
    }

    func testRefreshRotationRetainsGenerationAndReplacementAdvancesItExactly() async throws {
        let keychain = InMemoryForgeCredentialKeychain()
        let store = ForgeAccountStore(keychain: keychain)
        let accountID = try makeAccountID("node-1")
        let original = try await store.addAccount(
            accountID: accountID,
            login: "octocat",
            credentialID: ForgeCredentialID("app-credential"),
            source: .forgeApplicationDeviceFlow,
            expiresAt: Date(timeIntervalSince1970: 100),
            secrets: rotatingSecrets(access: "access-1", refresh: "refresh-1", refreshExpiry: 200)
        )
        let addedChange = try await store.credentialChange(for: accountID)
        XCTAssertEqual(
            addedChange,
            ForgeAccountCredentialChange(
                accountID: accountID,
                currentReference: original.currentCredential.reference,
                revision: 1
            )
        )

        let rotated = try await store.rotateCredential(
            expectedReference: original.currentCredential.reference,
            expiresAt: Date(timeIntervalSince1970: 150),
            secrets: rotatingSecrets(access: "access-2", refresh: "refresh-2", refreshExpiry: 250)
        )
        XCTAssertEqual(rotated.currentCredential.reference, original.currentCredential.reference)
        XCTAssertEqual(rotated.currentCredential.expiresAt, Date(timeIntervalSince1970: 150))
        let rotatedChange = try await store.credentialChange(for: accountID)
        XCTAssertEqual(rotatedChange.revision, 2)
        let storedRotatedCredential = try await store.credential(for: accountID)
        let rotatedEnvelope = try XCTUnwrap(storedRotatedCredential)
        XCTAssertEqual(
            rotatedEnvelope.secrets.withUnsafeRefreshTokenBytes { Data($0) },
            Data("refresh-2".utf8)
        )

        let replacement = try await store.replaceCredential(
            expectedReference: original.currentCredential.reference,
            credentialID: ForgeCredentialID("classic-pat"),
            source: .classicPersonalAccessToken,
            expiresAt: nil,
            secrets: ForgeCredentialSecretMaterial(accessToken: Data("pat-2".utf8))
        )
        XCTAssertEqual(replacement.currentCredential.reference.generation, try ForgeCredentialGeneration(2))
        XCTAssertEqual(replacement.currentCredential.source, .classicPersonalAccessToken)
        let replacementChange = try await store.credentialChange(for: accountID)
        XCTAssertEqual(
            replacementChange,
            ForgeAccountCredentialChange(
                accountID: accountID,
                currentReference: replacement.currentCredential.reference,
                revision: 3
            )
        )

        do {
            _ = try await store.replaceCredential(
                expectedReference: original.currentCredential.reference,
                credentialID: ForgeCredentialID("stale-pat"),
                source: .classicPersonalAccessToken,
                expiresAt: nil,
                secrets: ForgeCredentialSecretMaterial(accessToken: Data("stale".utf8))
            )
            XCTFail("a stale Credential reference must never replace the current Credential")
        } catch {
            XCTAssertEqual(error as? ForgeCredentialStoreError, .credentialReferenceMismatch)
        }

        do {
            _ = try await store.rotateCredential(
                expectedReference: original.currentCredential.reference,
                expiresAt: Date(timeIntervalSince1970: 175),
                secrets: rotatingSecrets(access: "access-3", refresh: "refresh-3", refreshExpiry: 300)
            )
            XCTFail("a replaced Credential reference must never rotate the current Credential")
        } catch {
            XCTAssertEqual(error as? ForgeCredentialStoreError, .credentialReferenceMismatch)
        }
        let retainedChange = try await store.credentialChange(for: accountID)
        XCTAssertEqual(retainedChange.revision, 3)

        try await store.removeAccount(accountID)
        let removedChange = try await store.credentialChange(for: accountID)
        XCTAssertEqual(
            removedChange,
            ForgeAccountCredentialChange(accountID: accountID, currentReference: nil, revision: 4)
        )
    }

    func testAccountStoreRejectsDuplicateCrossAccountMalformedAndInvalidSecretShapes() async throws {
        let keychain = InMemoryForgeCredentialKeychain()
        let store = ForgeAccountStore(keychain: keychain)
        let firstID = try makeAccountID("node-1")
        let secondID = try makeAccountID("node-2")
        _ = try await store.addPersonalAccessToken(
            accountID: firstID,
            login: "octocat",
            credentialID: ForgeCredentialID("pat-1"),
            kind: .classic,
            token: Data("token-1".utf8),
            expiresAt: nil
        )

        do {
            _ = try await store.addPersonalAccessToken(
                accountID: firstID,
                login: "duplicate",
                credentialID: ForgeCredentialID("pat-2"),
                kind: .classic,
                token: Data("token-2".utf8),
                expiresAt: nil
            )
            XCTFail("duplicate accounts must use explicit Credential replacement")
        } catch {
            XCTAssertEqual(error as? ForgeCredentialStoreError, .accountAlreadyExists)
        }

        XCTAssertThrowsError(try ForgeCredentialSecretMaterial(accessToken: Data())) {
            XCTAssertEqual($0 as? ForgeCredentialStoreError, .invalidSecretMaterial)
        }
        let accessOnly = try ForgeCredentialSecretMaterial(accessToken: Data("access".utf8))
        do {
            _ = try await store.addAccount(
                accountID: secondID,
                login: "hubot",
                credentialID: ForgeCredentialID("app"),
                source: .forgeApplicationDeviceFlow,
                expiresAt: Date(timeIntervalSince1970: 100),
                secrets: accessOnly
            )
            XCTFail("device-flow credentials require a rotating refresh token")
        } catch {
            XCTAssertEqual(error as? ForgeCredentialStoreError, .invalidCredentialSecretShape)
        }

        let firstKey = try ForgeAccountStore.keychainAccountKey(for: firstID)
        let secondKey = try ForgeAccountStore.keychainAccountKey(for: secondID)
        try keychain.setRaw(XCTUnwrap(keychain.rawValue(for: firstKey)), for: secondKey)
        do {
            _ = try await store.credential(for: secondID)
            XCTFail("a valid envelope under another account key must fail closed")
        } catch {
            XCTAssertEqual(error as? ForgeCredentialStoreError, .storedAccountMismatch)
        }
        do {
            _ = try await store.accounts()
            XCTFail("account listing must validate each envelope against its Keychain account key")
        } catch {
            XCTAssertEqual(error as? ForgeCredentialStoreError, .storedAccountMismatch)
        }
    }

    func testAccountStoreFailsClosedForMissingMalformedWrongSourceAndKeychainFailures() async throws {
        let keychain = InMemoryForgeCredentialKeychain()
        let store = ForgeAccountStore(keychain: keychain)
        let accountID = try makeAccountID("node-1")
        let missingReference = try ForgeCredentialReference(
            accountID: accountID,
            credentialID: ForgeCredentialID("missing"),
            generation: ForgeCredentialGeneration(1)
        )
        do {
            _ = try await store.rotateCredential(
                expectedReference: missingReference,
                expiresAt: nil,
                secrets: rotatingSecrets(access: "access", refresh: "refresh", refreshExpiry: 100)
            )
            XCTFail("a missing account cannot be rotated")
        } catch {
            XCTAssertEqual(error as? ForgeCredentialStoreError, .accountNotFound)
        }

        let account = try await store.addPersonalAccessToken(
            accountID: accountID,
            login: "octocat",
            credentialID: ForgeCredentialID("pat"),
            kind: .classic,
            token: Data("token".utf8),
            expiresAt: nil
        )
        do {
            _ = try await store.rotateCredential(
                expectedReference: account.currentCredential.reference,
                expiresAt: nil,
                secrets: rotatingSecrets(access: "access", refresh: "refresh", refreshExpiry: 100)
            )
            XCTFail("a PAT cannot be rotated as a device-flow Credential")
        } catch {
            XCTAssertEqual(error as? ForgeCredentialStoreError, .credentialSourceMismatch)
        }

        let malformedID = try makeAccountID("malformed")
        try keychain.setRaw(Data("not-json".utf8), for: ForgeAccountStore.keychainAccountKey(for: malformedID))
        do {
            _ = try await store.credential(for: malformedID)
            XCTFail("malformed Keychain data must fail closed")
        } catch {
            XCTAssertEqual(error as? ForgeCredentialStoreError, .malformedStoredCredential)
        }

        XCTAssertThrowsError(try ForgeCredentialSecretMaterial(accessToken: Data("line\nbreak".utf8))) {
            XCTAssertEqual($0 as? ForgeCredentialStoreError, .invalidSecretMaterial)
        }
        XCTAssertThrowsError(try ForgeCredentialSecretMaterial(
            accessToken: Data("access".utf8),
            refreshToken: Data("refresh".utf8)
        )) {
            XCTAssertEqual($0 as? ForgeCredentialStoreError, .invalidCredentialSecretShape)
        }

        keychain.failure = .authorizationFailed(operation: .list)
        do {
            _ = try await store.accounts()
            XCTFail("Keychain authorization errors must retain their safe classification")
        } catch {
            XCTAssertEqual(
                error as? ForgeCredentialStoreError,
                .keychain(.authorizationFailed(operation: .list))
            )
        }
    }

    func testSecurityKeychainUsesGenericPasswordsAndMapsOSStatusWithoutSecrets() {
        let query = SecurityForgeCredentialKeychain.genericPasswordQuery(
            service: "com.gitx.tests",
            accountKey: "safe-account"
        )
        XCTAssertEqual(query[kSecClass as String] as? String, kSecClassGenericPassword as String)
        XCTAssertEqual(query[kSecAttrService as String] as? String, "com.gitx.tests")
        XCTAssertEqual(query[kSecAttrAccount as String] as? String, "safe-account")

        XCTAssertEqual(
            ForgeKeychainError(operation: .read, status: errSecInteractionNotAllowed),
            .interactionNotAllowed(operation: .read)
        )
        XCTAssertEqual(
            ForgeKeychainError(operation: .write, status: errSecAuthFailed),
            .authorizationFailed(operation: .write)
        )
        let unexpected = ForgeKeychainError(operation: .list, status: -4242)
        XCTAssertEqual(unexpected, .unexpectedStatus(operation: .list, status: -4242))
        XCTAssertFalse(unexpected.localizedDescription.contains("secret"))
        XCTAssertFalse(String(reflecting: unexpected).contains("safe-account"))
    }

    func testSecurityKeychainAdapterHandlesReadListAtomicReplaceAndIdempotentRemoval() throws {
        let client = StubForgeSecurityItemClient()
        let keychain = SecurityForgeCredentialKeychain(service: "com.gitx.tests", client: client)

        client.enqueueCopy(status: errSecItemNotFound)
        XCTAssertNil(try keychain.data(for: "account"))
        client.enqueueCopy(status: errSecSuccess, result: Data("token-envelope".utf8))
        XCTAssertEqual(try keychain.data(for: "account"), Data("token-envelope".utf8))
        client.enqueueCopy(status: errSecSuccess, result: "not-data")
        XCTAssertThrowsError(try keychain.data(for: "account")) {
            XCTAssertEqual($0 as? ForgeKeychainError, .unexpectedStatus(operation: .read, status: errSecDecode))
        }
        client.enqueueCopy(status: errSecAuthFailed)
        XCTAssertThrowsError(try keychain.data(for: "account")) {
            XCTAssertEqual($0 as? ForgeKeychainError, .authorizationFailed(operation: .read))
        }

        client.enqueueCopy(status: errSecItemNotFound)
        XCTAssertEqual(try keychain.allItems(), [])
        client.enqueueCopy(status: errSecSuccess, result: [[
            kSecAttrAccount as String: "account",
            kSecValueData as String: Data("envelope".utf8),
        ]])
        XCTAssertEqual(
            try keychain.allItems(),
            [ForgeKeychainItem(accountKey: "account", data: Data("envelope".utf8))]
        )
        client.enqueueCopy(status: errSecSuccess, result: [[kSecAttrAccount as String: "missing-data"]])
        XCTAssertThrowsError(try keychain.allItems()) {
            XCTAssertEqual($0 as? ForgeKeychainError, .unexpectedStatus(operation: .list, status: errSecDecode))
        }
        client.enqueueCopy(status: errSecSuccess, result: "not-an-array")
        XCTAssertThrowsError(try keychain.allItems()) {
            XCTAssertEqual($0 as? ForgeKeychainError, .unexpectedStatus(operation: .list, status: errSecDecode))
        }

        client.enqueueUpdate(errSecSuccess)
        try keychain.replace(Data("updated".utf8), for: "account")
        client.enqueueUpdate(errSecItemNotFound)
        client.enqueueAdd(errSecSuccess)
        try keychain.replace(Data("inserted".utf8), for: "account")
        let insertedAttributes = try XCTUnwrap(client.addedAttributes.last)
        XCTAssertEqual(insertedAttributes[kSecValueData as String] as? Data, Data("inserted".utf8))
        XCTAssertEqual(
            insertedAttributes[kSecAttrAccessible as String] as? String,
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String
        )
        client.enqueueUpdate(errSecItemNotFound)
        client.enqueueAdd(errSecDuplicateItem)
        client.enqueueUpdate(errSecSuccess)
        try keychain.replace(Data("raced".utf8), for: "account")
        client.enqueueUpdate(errSecInteractionNotAllowed)
        XCTAssertThrowsError(try keychain.replace(Data("blocked".utf8), for: "account")) {
            XCTAssertEqual($0 as? ForgeKeychainError, .interactionNotAllowed(operation: .write))
        }

        client.enqueueDelete(errSecItemNotFound)
        try keychain.remove(accountKey: "absent")
        client.enqueueDelete(errSecSuccess)
        try keychain.remove(accountKey: "account")
        client.enqueueDelete(-4242)
        XCTAssertThrowsError(try keychain.remove(accountKey: "account")) {
            XCTAssertEqual($0 as? ForgeKeychainError, .unexpectedStatus(operation: .remove, status: -4242))
        }
    }

    func testAccessTokenExpiryRejectsNonfiniteWritesAndDecodedEnvelopes() async throws {
        let store = ForgeAccountStore(keychain: InMemoryForgeCredentialKeychain())
        let accountID = try makeAccountID("node-1")
        do {
            _ = try await store.addPersonalAccessToken(
                accountID: accountID,
                login: "octocat",
                credentialID: ForgeCredentialID("pat-1"),
                kind: .classic,
                token: Data("token".utf8),
                expiresAt: Date(timeIntervalSinceReferenceDate: .infinity)
            )
            XCTFail("nonfinite access-token expiry metadata must fail closed")
        } catch {
            XCTAssertEqual(error as? ForgeCredentialStoreError, .invalidSecretMaterial)
        }

        let reference = try ForgeCredentialReference(
            accountID: accountID,
            credentialID: ForgeCredentialID("pat-1"),
            generation: ForgeCredentialGeneration(1)
        )
        let finiteEnvelope = try ForgeStoredCredentialEnvelope(
            account: ForgeAccount(
                id: accountID,
                login: "octocat",
                currentCredential: ForgeCredentialMetadata(
                    reference: reference,
                    source: .classicPersonalAccessToken,
                    expiresAt: Date(timeIntervalSinceReferenceDate: 42)
                )
            ),
            secrets: ForgeCredentialSecretMaterial(accessToken: Data("token".utf8))
        )
        let encoder = JSONEncoder()
        let finiteJSON = try String(decoding: encoder.encode(finiteEnvelope), as: UTF8.self)
        let nonfiniteJSON = finiteJSON.replacingOccurrences(of: "\"expiresAt\":42", with: "\"expiresAt\":\"Infinity\"")
        XCTAssertNotEqual(finiteJSON, nonfiniteJSON)
        let decoder = JSONDecoder()
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(
            positiveInfinity: "Infinity",
            negativeInfinity: "-Infinity",
            nan: "NaN"
        )
        XCTAssertThrowsError(try decoder.decode(ForgeStoredCredentialEnvelope.self, from: Data(nonfiniteJSON.utf8))) {
            XCTAssertEqual($0 as? ForgeCredentialStoreError, .invalidSecretMaterial)
        }

        let deviceAccountID = try makeAccountID("device-node")
        do {
            _ = try await store.addAccount(
                accountID: deviceAccountID,
                login: "device-user",
                credentialID: ForgeCredentialID("device-credential"),
                source: .forgeApplicationDeviceFlow,
                expiresAt: nil,
                secrets: rotatingSecrets(access: "access", refresh: "refresh", refreshExpiry: 100)
            )
            XCTFail("device-flow credentials require an access-token expiry")
        } catch {
            XCTAssertEqual(error as? ForgeCredentialStoreError, .invalidCredentialSecretShape)
        }

        let deviceReference = try ForgeCredentialReference(
            accountID: deviceAccountID,
            credentialID: ForgeCredentialID("device-credential"),
            generation: ForgeCredentialGeneration(1)
        )
        let finiteDeviceEnvelope = try ForgeStoredCredentialEnvelope(
            account: ForgeAccount(
                id: deviceAccountID,
                login: "device-user",
                currentCredential: ForgeCredentialMetadata(
                    reference: deviceReference,
                    source: .forgeApplicationDeviceFlow,
                    expiresAt: Date(timeIntervalSinceReferenceDate: 42)
                )
            ),
            secrets: rotatingSecrets(access: "access", refresh: "refresh", refreshExpiry: 100)
        )
        var deviceObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoder.encode(finiteDeviceEnvelope)) as? [String: Any]
        )
        var encodedAccount = try XCTUnwrap(deviceObject["account"] as? [String: Any])
        var encodedCredential = try XCTUnwrap(encodedAccount["currentCredential"] as? [String: Any])
        XCTAssertNotNil(encodedCredential.removeValue(forKey: "expiresAt"))
        encodedAccount["currentCredential"] = encodedCredential
        deviceObject["account"] = encodedAccount
        let missingExpiryData = try JSONSerialization.data(withJSONObject: deviceObject)
        XCTAssertThrowsError(try JSONDecoder().decode(ForgeStoredCredentialEnvelope.self, from: missingExpiryData)) {
            XCTAssertEqual($0 as? ForgeCredentialStoreError, .invalidCredentialSecretShape)
        }
    }

    func testSecretValidationAndErrorDescriptionsCoverEveryFailClosedClassification() throws {
        let storeErrors: [ForgeCredentialStoreError] = [
            .accountAlreadyExists,
            .accountNotFound,
            .credentialReferenceMismatch,
            .credentialSourceMismatch,
            .generationExhausted,
            .invalidCredentialSecretShape,
            .invalidSecretMaterial,
            .malformedStoredCredential,
            .storedAccountMismatch,
            .keychain(.authorizationFailed(operation: .read)),
        ]
        for error in storeErrors {
            XCTAssertFalse(error.localizedDescription.isEmpty)
            XCTAssertFalse(error.localizedDescription.contains("private-token"))
        }
        let keychainErrors: [ForgeKeychainError] = [
            .interactionNotAllowed(operation: .read),
            .authorizationFailed(operation: .write),
            .unexpectedStatus(operation: .remove, status: -42),
        ]
        for error in keychainErrors {
            XCTAssertFalse(error.localizedDescription.isEmpty)
        }

        let secrets = try rotatingSecrets(access: "private-token", refresh: "refresh-token", refreshExpiry: 100)
        XCTAssertFalse(String(describing: secrets).contains("private-token"))
        XCTAssertFalse(String(reflecting: secrets).contains("refresh-token"))
        XCTAssertTrue(secrets.customMirror.children.isEmpty)
        XCTAssertThrowsError(try ForgeCredentialSecretMaterial(
            accessToken: Data("access".utf8),
            refreshToken: Data([0x7F]),
            refreshTokenExpiresAt: Date(timeIntervalSinceReferenceDate: 1)
        )) {
            XCTAssertEqual($0 as? ForgeCredentialStoreError, .invalidSecretMaterial)
        }
        XCTAssertThrowsError(try ForgeCredentialSecretMaterial(
            accessToken: Data("access".utf8),
            refreshToken: Data("refresh".utf8),
            refreshTokenExpiresAt: Date(timeIntervalSinceReferenceDate: .infinity)
        )) {
            XCTAssertEqual($0 as? ForgeCredentialStoreError, .invalidSecretMaterial)
        }

        let accountID = try makeAccountID("pat-with-refresh")
        let reference = try ForgeCredentialReference(
            accountID: accountID,
            credentialID: ForgeCredentialID("pat"),
            generation: ForgeCredentialGeneration(1)
        )
        XCTAssertThrowsError(try ForgeStoredCredentialEnvelope(
            account: ForgeAccount(
                id: accountID,
                login: "octocat",
                currentCredential: ForgeCredentialMetadata(
                    reference: reference,
                    source: .classicPersonalAccessToken
                )
            ),
            secrets: secrets
        )) {
            XCTAssertEqual($0 as? ForgeCredentialStoreError, .invalidCredentialSecretShape)
        }
    }

    func testAccountListingSortsDeterministicallyAndReplacementRejectsGenerationOverflow() async throws {
        let keychain = InMemoryForgeCredentialKeychain()
        let store = ForgeAccountStore(keychain: keychain)
        let laterID = try makeAccountID("later-node")
        let earlierID = try makeAccountID("earlier-node")
        _ = try await store.addPersonalAccessToken(
            accountID: laterID,
            login: "zebra",
            credentialID: ForgeCredentialID("later"),
            kind: .classic,
            token: Data("later-token".utf8),
            expiresAt: nil
        )
        _ = try await store.addPersonalAccessToken(
            accountID: earlierID,
            login: "alpha",
            credentialID: ForgeCredentialID("earlier"),
            kind: .classic,
            token: Data("earlier-token".utf8),
            expiresAt: nil
        )
        let accounts = try await store.accounts()
        XCTAssertEqual(accounts.map(\.login), ["alpha", "zebra"])

        let overflowID = try makeAccountID("overflow-node")
        let overflowReference = try ForgeCredentialReference(
            accountID: overflowID,
            credentialID: ForgeCredentialID("overflow"),
            generation: ForgeCredentialGeneration(UInt64.max)
        )
        let overflowEnvelope = try ForgeStoredCredentialEnvelope(
            account: ForgeAccount(
                id: overflowID,
                login: "overflow",
                currentCredential: ForgeCredentialMetadata(
                    reference: overflowReference,
                    source: .classicPersonalAccessToken
                )
            ),
            secrets: ForgeCredentialSecretMaterial(accessToken: Data("overflow-token".utf8))
        )
        try keychain.setRaw(
            JSONEncoder().encode(overflowEnvelope),
            for: ForgeAccountStore.keychainAccountKey(for: overflowID)
        )
        do {
            _ = try await store.replaceCredential(
                expectedReference: overflowReference,
                credentialID: ForgeCredentialID("replacement"),
                source: .classicPersonalAccessToken,
                expiresAt: nil,
                secrets: ForgeCredentialSecretMaterial(accessToken: Data("replacement-token".utf8))
            )
            XCTFail("Credential generation must never wrap to zero")
        } catch {
            XCTAssertEqual(error as? ForgeCredentialStoreError, .generationExhausted)
        }
    }

    func testDecodedEnvelopePreservesTypedSecretValidationFailure() async throws {
        let keychain = InMemoryForgeCredentialKeychain()
        let store = ForgeAccountStore(keychain: keychain)
        let accountID = try makeAccountID("decoded-invalid-secret")
        let reference = try ForgeCredentialReference(
            accountID: accountID,
            credentialID: ForgeCredentialID("pat"),
            generation: ForgeCredentialGeneration(1)
        )
        let envelope = try ForgeStoredCredentialEnvelope(
            account: ForgeAccount(
                id: accountID,
                login: "octocat",
                currentCredential: ForgeCredentialMetadata(
                    reference: reference,
                    source: .classicPersonalAccessToken
                )
            ),
            secrets: ForgeCredentialSecretMaterial(accessToken: Data("valid-token".utf8))
        )
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(envelope)) as? [String: Any]
        )
        var secrets = try XCTUnwrap(object["secrets"] as? [String: Any])
        secrets["accessToken"] = ""
        object["secrets"] = secrets
        try keychain.setRaw(
            JSONSerialization.data(withJSONObject: object),
            for: ForgeAccountStore.keychainAccountKey(for: accountID)
        )

        do {
            _ = try await store.credential(for: accountID)
            XCTFail("decoded invalid secret material must keep its safe typed classification")
        } catch {
            XCTAssertEqual(error as? ForgeCredentialStoreError, .invalidSecretMaterial)
        }
    }

    private func makeAccountID(_ value: String) throws -> ForgeAccountID {
        try ForgeAccountID(
            forge: ForgeIdentity(kind: .github, origin: ForgeOrigin(host: "github.com")),
            value: value
        )
    }

    private func rotatingSecrets(
        access: String,
        refresh: String,
        refreshExpiry: TimeInterval
    ) throws -> ForgeCredentialSecretMaterial {
        try ForgeCredentialSecretMaterial(
            accessToken: Data(access.utf8),
            refreshToken: Data(refresh.utf8),
            refreshTokenExpiresAt: Date(timeIntervalSince1970: refreshExpiry)
        )
    }
}

// swift6-safety-justification: The lock serializes all in-memory Keychain test-double state.
private final nonisolated class InMemoryForgeCredentialKeychain: ForgeCredentialKeychain, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: Data] = [:]
    private(set) var accessThreads: [Bool] = []
    var failure: ForgeKeychainError?

    var count: Int {
        lock.withLock { storage.count }
    }

    func data(for accountKey: String) throws -> Data? {
        try lock.withLock {
            accessThreads.append(Thread.isMainThread)
            if let failure {
                throw failure
            }
            return storage[accountKey]
        }
    }

    func allItems() throws -> [ForgeKeychainItem] {
        try lock.withLock {
            accessThreads.append(Thread.isMainThread)
            if let failure {
                throw failure
            }
            return storage.map(ForgeKeychainItem.init(accountKey:data:))
        }
    }

    func replace(_ data: Data, for accountKey: String) throws {
        try lock.withLock {
            accessThreads.append(Thread.isMainThread)
            if let failure {
                throw failure
            }
            storage[accountKey] = data
        }
    }

    func remove(accountKey: String) throws {
        try lock.withLock {
            accessThreads.append(Thread.isMainThread)
            if let failure {
                throw failure
            }
            storage.removeValue(forKey: accountKey)
        }
    }

    func rawValue(for accountKey: String) -> Data? {
        lock.withLock { storage[accountKey] }
    }

    func setRaw(_ data: Data, for accountKey: String) {
        lock.withLock { storage[accountKey] = data }
    }
}

// swift6-safety-justification: The lock serializes every queued Security response and captured addition.
private final nonisolated class StubForgeSecurityItemClient: ForgeSecurityItemCalling, @unchecked Sendable {
    private let lock = NSLock()
    private var copyResponses: [(OSStatus, Any?)] = []
    private var updateStatuses: [OSStatus] = []
    private var addStatuses: [OSStatus] = []
    private var deleteStatuses: [OSStatus] = []
    private var additions: [[String: Any]] = []

    var addedAttributes: [[String: Any]] {
        lock.withLock { additions }
    }

    func enqueueCopy(status: OSStatus, result: Any? = nil) {
        lock.withLock { copyResponses.append((status, result)) }
    }

    func enqueueUpdate(_ status: OSStatus) {
        lock.withLock { updateStatuses.append(status) }
    }

    func enqueueAdd(_ status: OSStatus) {
        lock.withLock { addStatuses.append(status) }
    }

    func enqueueDelete(_ status: OSStatus) {
        lock.withLock { deleteStatuses.append(status) }
    }

    func copyMatching(_ query: [String: Any]) -> (status: OSStatus, result: Any?) {
        lock.withLock { copyResponses.removeFirst() }
    }

    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus {
        lock.withLock { updateStatuses.removeFirst() }
    }

    func add(_ attributes: [String: Any]) -> OSStatus {
        lock.withLock {
            additions.append(attributes)
            return addStatuses.removeFirst()
        }
    }

    func delete(_ query: [String: Any]) -> OSStatus {
        lock.withLock { deleteStatuses.removeFirst() }
    }
}

private extension NSLock {
    func withLock<Result>(_ body: () throws -> Result) rethrows -> Result {
        lock()
        defer { unlock() }
        return try body()
    }
}
