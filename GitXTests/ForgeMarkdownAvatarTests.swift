import AppKit
import ForgeKit
import ImageIO
import UniformTypeIdentifiers
import XCTest

@MainActor
final class ForgeMarkdownAvatarTests: XCTestCase {
    private final class Router: ForgeMarkdownNavigationRouting {
        var activated: [ForgeMarkdownLinkTarget] = []
        var browserURLs: [URL] = []

        func activateMarkdownLink(_ target: ForgeMarkdownLinkTarget) {
            activated.append(target)
        }

        func openMarkdownLinkInBrowser(_ url: URL) {
            browserURLs.append(url)
        }
    }

    func testRendererCoversEverySanitizedBlockAndInlineWithoutLoadingImages() throws {
        let heading = ForgeMarkdownHeadingID(rawValue: "overview")
        let external = try ForgeMarkdownLinkTarget.https(
            ForgeHTTPSLink("https://example.com/path")
        )
        let document = ForgeMarkdownDocument(blocks: [
            .heading(level: 1, identifier: heading, content: [.text("Overview")]),
            .paragraph([
                .text("Plain "),
                .emphasis([.text("emphasis")]),
                .text(" "),
                .strong([.text("strong")]),
                .text(" "),
                .strikethrough([.text("removed")]),
                .softBreak,
                .inlineCode("value"),
                .lineBreak,
                .link(label: [.text("external")], target: external),
                .text(" "),
                .imagePlaceholder(altText: "diagram"),
            ]),
            .blockQuote([.paragraph([.text("Quoted")])]),
            .unorderedList([
                ForgeMarkdownListItem(taskState: .checked, blocks: [.paragraph([.text("Done")])]),
                ForgeMarkdownListItem(taskState: .unchecked, blocks: [.paragraph([.text("Todo")])]),
                ForgeMarkdownListItem(taskState: nil, blocks: [.paragraph([.text("Bullet")])]),
            ]),
            .orderedList(start: 3, items: [
                ForgeMarkdownListItem(taskState: nil, blocks: [.paragraph([.text("Third")])]),
            ]),
            .table(ForgeMarkdownTable(
                columnAlignments: [.left, .center, .right],
                header: [cell("Name"), cell("Status"), cell("Value")],
                rows: [[cell("A"), cell("Ready"), cell("1")]]
            )),
            .thematicBreak,
            .codeBlock(language: "swift", code: "let answer = 42"),
        ])

        let result = ForgeMarkdownNativeRenderer().render(document)
        let string = result.attributedString.string
        for expected in [
            "Overview", "Plain", "emphasis", "strong", "removed", "value",
            "external", "▧ Image: diagram", "│ Quoted", "☑︎", "☐︎", "•",
            "3.", "Name", "Status", "Value", "SWIFT", "let answer = 42",
        ] {
            XCTAssertTrue(string.contains(expected), expected)
        }
        XCTAssertFalse(string.contains("http"), "The image placeholder and link token must not expose or fetch a source")
        XCTAssertEqual(result.headingRanges[heading].map { (string as NSString).substring(with: $0) }, "Overview")
        XCTAssertEqual(result.linkTargets.values.first, external)

        let strongRange = (string as NSString).range(of: "strong")
        let strongFont = try XCTUnwrap(
            result.attributedString.attribute(.font, at: strongRange.location, effectiveRange: nil) as? NSFont
        )
        XCTAssertTrue(NSFontManager.shared.traits(of: strongFont).contains(.boldFontMask))
        let removedRange = (string as NSString).range(of: "removed")
        XCTAssertNotNil(result.attributedString.attribute(
            .strikethroughStyle,
            at: removedRange.location,
            effectiveRange: nil
        ))
        let valueRange = (string as NSString).range(of: "Value")
        let tableParagraph = try XCTUnwrap(result.attributedString.attribute(
            .paragraphStyle,
            at: valueRange.location,
            effectiveRange: nil
        ) as? NSParagraphStyle)
        XCTAssertEqual(tableParagraph.tabStops.map(\.alignment), [.left, .center, .right])
    }

    func testSanitizerToNativeViewKeepsMarkdownImagesInertAndRoutesLinksExplicitly() throws {
        let repository = try ForgeRepositoryIdentity(
            forge: ForgeIdentity(kind: .github, origin: ForgeOrigin(host: "github.com")),
            owner: "example",
            name: "repo"
        )
        let context = try ForgeMarkdownContext(
            repository: repository,
            location: .repository(defaultBranch: .branch(ForgeRefName("main")))
        )
        let document = ForgeMarkdownSanitizer().sanitize(
            "# Details\n![secret](file:///etc/passwd) [PR](https://github.com/example/repo/pull/7) [top](#details)",
            context: context
        )
        let router = Router()
        let view = ForgeMarkdownNativeView(document: document, navigationRouter: router)
        view.frame = NSRect(x: 0, y: 0, width: 640, height: 260)
        view.layoutSubtreeIfNeeded()

        XCTAssertTrue(view.textView.string.contains("▧ Image: secret"))
        XCTAssertFalse(view.textView.string.contains("file:///etc/passwd"))
        let links = linkURLs(in: view.textView.attributedString())
        XCTAssertEqual(links.count, 2)
        for link in links {
            XCTAssertTrue(view.activateLink(link))
        }
        XCTAssertEqual(router.activated.count, 1)
        guard case let .native(destination) = try XCTUnwrap(router.activated.first) else {
            return XCTFail("Expected the Pull Request link to use the native routing seam")
        }
        XCTAssertEqual(destination.kind, .pullRequest)
        XCTAssertFalse(try view.activateLink(XCTUnwrap(URL(string: "x-gitx-markdown-link://missing"))))
        XCTAssertEqual(view.accessibilityIdentifier(), "ForgeMarkdownNativeView")
        XCTAssertEqual(view.textView.accessibilityIdentifier(), "ForgeMarkdownText")
    }

    func testImageDecoderAcceptsStaticRasterFirstFramesOffMainAndRejectsMismatchAndPixelExcess() async throws {
        let png = try rasterData(type: .png, width: 12, height: 10)
        let decoded = try ForgeAvatarImageDecoder().decode(
            ForgeAvatarPayload(data: png, mediaType: .png),
            maximumPixels: 120
        )
        XCTAssertEqual(decoded.size, NSSize(width: 12, height: 10))
        XCTAssertEqual(decoded.makeImage().representations.count, 1)

        let offMain = try await ForgeAvatarImageDecoder().decodeOffMain(
            ForgeAvatarPayload(data: png, mediaType: .png),
            maximumPixels: 120
        )
        XCTAssertFalse(offMain.wasDecodedOnMainThread)
        XCTAssertEqual(offMain.size, NSSize(width: 12, height: 10))

        XCTAssertThrowsError(try ForgeAvatarImageDecoder().decode(
            ForgeAvatarPayload(data: png, mediaType: .jpeg)
        )) {
            XCTAssertEqual($0 as? ForgeAvatarPolicyError, .mediaTypeMismatch)
        }
        XCTAssertThrowsError(try ForgeAvatarImageDecoder().decode(
            ForgeAvatarPayload(data: png, mediaType: .png),
            maximumPixels: 119
        )) {
            XCTAssertEqual($0 as? ForgeAvatarPolicyError, .decodedImageTooLarge)
        }
        XCTAssertThrowsError(try ForgeAvatarImageDecoder().decode(
            ForgeAvatarPayload(data: Data("<svg/>".utf8), mediaType: .png)
        )) {
            XCTAssertEqual($0 as? ForgeAvatarPolicyError, .mediaTypeMismatch)
        }

        let gif = try animatedGIFData()
        let gifImage = try ForgeAvatarImageDecoder().decode(
            ForgeAvatarPayload(data: gif, mediaType: .gif)
        )
        XCTAssertEqual(
            gifImage.makeImage().representations.count,
            1,
            "Only the first raster frame may survive decoding"
        )
    }

    func testNetworkRequestAndRedirectBoundaryStripAmbientAuthority() throws {
        let avatarURL = try ForgeAvatarURL("https://avatars.githubusercontent.com/u/1?v=4")
        let configuration = ForgeAvatarNetworkTransport.secureConfiguration()
        XCTAssertNil(configuration.httpCookieStorage)
        XCTAssertFalse(configuration.httpShouldSetCookies)
        XCTAssertNil(configuration.urlCredentialStorage)
        XCTAssertNil(configuration.urlCache)

        let request = ForgeAvatarNetworkTransport.request(for: avatarURL)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertFalse(request.httpShouldHandleCookies)
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
        XCTAssertNil(request.value(forHTTPHeaderField: "Referer"))
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), ForgeAvatarMediaType.acceptHeader)

        let delegate = ForgeAvatarRedirectDelegate()
        let session = URLSession(configuration: .ephemeral)
        let task = session.dataTask(with: request)
        let response = try XCTUnwrap(HTTPURLResponse(
            url: avatarURL.url,
            statusCode: 302,
            httpVersion: nil,
            headerFields: nil
        ))
        let accepted = RedirectResult()
        try delegate.urlSession(
            session,
            task: task,
            willPerformHTTPRedirection: response,
            newRequest: URLRequest(url: XCTUnwrap(URL(string: "https://avatars.githubusercontent.com/u/2")))
        ) { accepted.value = $0 }
        XCTAssertEqual(accepted.value?.url?.host, "avatars.githubusercontent.com")
        XCTAssertNil(accepted.value?.value(forHTTPHeaderField: "Cookie"))

        let rejected = RedirectResult()
        try delegate.urlSession(
            session,
            task: task,
            willPerformHTTPRedirection: response,
            newRequest: URLRequest(url: XCTUnwrap(URL(string: "https://evil.example/avatar.png")))
        ) { rejected.value = $0 }
        XCTAssertNil(rejected.value)

        let challenge = URLAuthenticationChallenge(
            protectionSpace: URLProtectionSpace(
                host: "avatars.githubusercontent.com",
                port: 443,
                protocol: "https",
                realm: nil,
                authenticationMethod: NSURLAuthenticationMethodHTTPBasic
            ),
            proposedCredential: URLCredential(
                user: "ambient-user",
                password: "ambient-secret",
                persistence: .forSession
            ),
            previousFailureCount: 0,
            failureResponse: nil,
            error: nil,
            sender: NoOpAuthenticationChallengeSender()
        )
        let authentication = AuthenticationChallengeResult()
        delegate.urlSession(session, task: task, didReceive: challenge) { disposition, credential in
            authentication.record(disposition: disposition, credential: credential)
        }
        XCTAssertEqual(authentication.disposition, .cancelAuthenticationChallenge)
        XCTAssertNil(authentication.credential)
        session.invalidateAndCancel()
    }

    func testLoaderCachesWithinCapAndDisablingPurgesAndCancels() async throws {
        let firstURL = try ForgeAvatarURL("https://avatars.githubusercontent.com/u/1")
        let secondURL = try ForgeAvatarURL("https://avatars.githubusercontent.com/u/2")
        let transport = RecordingAvatarTransport(payload: ForgeAvatarPayload(
            data: Data([1, 2, 3]),
            mediaType: .png
        ))
        let loader = ForgeAvatarLoader(transport: transport, cacheByteLimit: 4)

        _ = try await loader.load(firstURL)
        _ = try await loader.load(firstURL)
        let fetchCount = await transport.fetchCount
        XCTAssertEqual(fetchCount, 1)
        _ = try await loader.load(secondURL)
        let bounded = await loader.statistics()
        XCTAssertEqual(bounded.cachedItems, 1)
        XCTAssertEqual(bounded.cachedBytes, 3)

        await loader.setLoadingEnabled(false)
        let disabled = await loader.statistics()
        XCTAssertEqual(disabled.cachedItems, 0)
        XCTAssertFalse(disabled.enabled)
        await XCTAssertThrowsErrorAsync(try await loader.load(firstURL)) {
            XCTAssertEqual($0 as? ForgeAvatarLoadingError, .disabled)
        }

        let blocking = BlockingAvatarTransport()
        let cancellingLoader = ForgeAvatarLoader(transport: blocking)
        let request = Task { try await cancellingLoader.load(firstURL) }
        await blocking.waitUntilStarted()
        let activeBeforeDisable = await cancellingLoader.statistics().activeRequests
        XCTAssertEqual(activeBeforeDisable, 1)
        await cancellingLoader.setLoadingEnabled(false)
        await XCTAssertThrowsErrorAsync(try await request.value) { error in
            XCTAssertTrue(error is CancellationError || error as? ForgeAvatarLoadingError == .disabled)
        }
        let activeAfterDisable = await cancellingLoader.statistics().activeRequests
        XCTAssertEqual(activeAfterDisable, 0)

        let directlyCancelledTransport = BlockingAvatarTransport()
        let directlyCancelledLoader = ForgeAvatarLoader(transport: directlyCancelledTransport)
        let directlyCancelledRequest = Task { try await directlyCancelledLoader.load(firstURL) }
        await directlyCancelledTransport.waitUntilStarted()
        directlyCancelledRequest.cancel()
        await XCTAssertThrowsErrorAsync(try await directlyCancelledRequest.value) { error in
            XCTAssertTrue(error is CancellationError)
        }
        let activeAfterDirectCancellation = await directlyCancelledLoader.statistics().activeRequests
        XCTAssertEqual(activeAfterDirectCancellation, 0)
    }

    func testLoaderCancellationBelongsToOneWaiterAndOnlyCancelsTransportAfterLastWaiter() async throws {
        let avatarURL = try ForgeAvatarURL("https://avatars.githubusercontent.com/u/41")
        let payload = ForgeAvatarPayload(data: Data([4, 1]), mediaType: .png)
        let transport = ControlledAvatarTransport(payload: payload)
        let loader = ForgeAvatarLoader(transport: transport)

        let first = Task { try await loader.load(avatarURL) }
        await transport.waitUntilStarted()
        let second = Task { try await loader.load(avatarURL) }
        let joinedWaiters = await waitForWaiterCount(2, in: loader)
        XCTAssertTrue(joinedWaiters)

        first.cancel()
        await XCTAssertThrowsErrorAsync(try await first.value) { error in
            XCTAssertTrue(error is CancellationError)
        }
        let cancellationCount = await transport.cancellationCount
        let remainingWaiters = await loader.statistics().activeWaiters
        XCTAssertEqual(cancellationCount, 0)
        XCTAssertEqual(remainingWaiters, 1)

        await transport.complete()
        let secondPayload = try await second.value
        let fetchCount = await transport.fetchCount
        let activeAfterCompletion = await loader.statistics().activeRequests
        XCTAssertEqual(secondPayload, payload)
        XCTAssertEqual(fetchCount, 1)
        XCTAssertEqual(activeAfterCompletion, 0)

        let finalTransport = ControlledAvatarTransport(payload: payload)
        let finalLoader = ForgeAvatarLoader(transport: finalTransport)
        let finalWaiter = Task { try await finalLoader.load(avatarURL) }
        await finalTransport.waitUntilStarted()
        let finalWaiterJoined = await waitForWaiterCount(1, in: finalLoader)
        XCTAssertTrue(finalWaiterJoined)
        finalWaiter.cancel()
        await XCTAssertThrowsErrorAsync(try await finalWaiter.value) { error in
            XCTAssertTrue(error is CancellationError)
        }
        let transportCancelled = await finalTransport.waitForCancellation()
        let finalActiveRequests = await finalLoader.statistics().activeRequests
        XCTAssertTrue(transportCancelled)
        XCTAssertEqual(finalActiveRequests, 0)
    }

    func testCancelledNonCooperativeRequestCannotCompleteAReplacementForTheSameURL() async throws {
        let avatarURL = try ForgeAvatarURL("https://avatars.githubusercontent.com/u/42")
        let oldPayload = ForgeAvatarPayload(data: Data([4, 2]), mediaType: .jpeg)
        let newPayload = ForgeAvatarPayload(data: Data([4, 3]), mediaType: .png)
        let transport = SequencedAvatarTransport()
        let loader = ForgeAvatarLoader(transport: transport)

        let oldWaiter = Task { try await loader.load(avatarURL) }
        let oldFetchStarted = await transport.waitForFetchCount(1)
        XCTAssertTrue(oldFetchStarted)
        oldWaiter.cancel()
        await XCTAssertThrowsErrorAsync(try await oldWaiter.value) { error in
            XCTAssertTrue(error is CancellationError)
        }

        let replacement = Task { try await loader.load(avatarURL) }
        let replacementFetchStarted = await transport.waitForFetchCount(2)
        let replacementJoined = await waitForWaiterCount(1, in: loader)
        XCTAssertTrue(replacementFetchStarted)
        XCTAssertTrue(replacementJoined)
        await transport.completeFetch(at: 0, with: oldPayload)
        let oldCompletionDiscarded = await waitForDiscardedCompletion(in: loader)
        let replacementWaiters = await loader.statistics().activeWaiters
        XCTAssertTrue(oldCompletionDiscarded)
        XCTAssertEqual(replacementWaiters, 1)

        await transport.completeFetch(at: 1, with: newPayload)
        let replacementPayload = try await replacement.value
        XCTAssertEqual(replacementPayload, newPayload)
    }

    func testLoaderReadsThroughWritesThroughAndPurgesDisposableBackingStore() async throws {
        let cachedURL = try ForgeAvatarURL("https://avatars.githubusercontent.com/u/51")
        let fetchedURL = try ForgeAvatarURL("https://avatars.githubusercontent.com/u/52")
        let cachedPayload = ForgeAvatarPayload(data: Data([5, 1]), mediaType: .jpeg)
        let fetchedPayload = ForgeAvatarPayload(data: Data([5, 2]), mediaType: .png)
        let backing = RecordingAvatarBackingStore(entries: [cachedURL: cachedPayload])
        let transport = RecordingAvatarTransport(payload: fetchedPayload)
        let loader = ForgeAvatarLoader(transport: transport, backingStore: backing)

        let loadedFromBacking = try await loader.load(cachedURL)
        let fetchesAfterBackingHit = await transport.fetchCount
        let backingLoads = await backing.loadCount
        XCTAssertEqual(loadedFromBacking, cachedPayload)
        XCTAssertEqual(fetchesAfterBackingHit, 0)
        XCTAssertEqual(backingLoads, 1)

        let loadedFromNetwork = try await loader.load(fetchedURL)
        let fetchesAfterMiss = await transport.fetchCount
        let storedPayload = await backing.storedPayload(for: fetchedURL)
        XCTAssertEqual(loadedFromNetwork, fetchedPayload)
        XCTAssertEqual(fetchesAfterMiss, 1)
        XCTAssertEqual(storedPayload, fetchedPayload)

        await loader.purge()
        let backingPurges = await backing.purgeCount
        let cachedItemsAfterPurge = await loader.statistics().cachedItems
        XCTAssertEqual(backingPurges, 1)
        XCTAssertEqual(cachedItemsAfterPurge, 0)
    }

    func testLoaderTreatsDisposableBackingFailuresAndOversizedEntriesAsNetworkMisses() async throws {
        let avatarURL = try ForgeAvatarURL("https://avatars.githubusercontent.com/u/53")
        let payload = ForgeAvatarPayload(data: Data([5, 3]), mediaType: .gif)
        let transport = RecordingAvatarTransport(payload: payload)
        let failingLoader = ForgeAvatarLoader(
            transport: transport,
            backingStore: FailingAvatarBackingStore()
        )

        let loaded = try await failingLoader.load(avatarURL)
        let failedBackingFetches = await transport.fetchCount
        XCTAssertEqual(loaded, payload)
        XCTAssertEqual(failedBackingFetches, 1)
        await failingLoader.setLoadingEnabled(false)
        let enabledAfterBackingPurgeFailure = await failingLoader.statistics().enabled
        XCTAssertFalse(enabledAfterBackingPurgeFailure)
        let failuresBeforeExplicitPurge = await failingLoader.statistics().backingStoreFailures
        await failingLoader.purge()
        let failuresAfterExplicitPurge = await failingLoader.statistics().backingStoreFailures
        XCTAssertEqual(failuresAfterExplicitPurge, failuresBeforeExplicitPurge + 1)

        let oversized = ForgeAvatarPayload(
            data: Data(repeating: 0, count: ForgeAvatarSecurityConstants.maximumResponseBytes + 1),
            mediaType: .png
        )
        let oversizedBacking = RecordingAvatarBackingStore(entries: [avatarURL: oversized])
        let oversizedTransport = RecordingAvatarTransport(payload: payload)
        let oversizedLoader = ForgeAvatarLoader(
            transport: oversizedTransport,
            backingStore: oversizedBacking,
            cacheByteLimit: 1
        )
        let fallback = try await oversizedLoader.load(avatarURL)
        let oversizedBackingFetches = await oversizedTransport.fetchCount
        let oversizedCachedItems = await oversizedLoader.statistics().cachedItems
        XCTAssertEqual(fallback, payload)
        XCTAssertEqual(oversizedBackingFetches, 1)
        XCTAssertEqual(oversizedCachedItems, 0)

        let oversizedPayloadTransport = RecordingAvatarTransport(payload: oversized)
        let validatingLoader = ForgeAvatarLoader(transport: oversizedPayloadTransport)
        await XCTAssertThrowsErrorAsync(try await validatingLoader.load(avatarURL)) { error in
            XCTAssertEqual(error as? ForgeAvatarPolicyError, .responseTooLarge)
        }
    }

    func testSQLiteAvatarBackingStoreUsesSharedDisposableAvatarPartition() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitXAvatarBacking-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let sqlite = try ForgeSQLiteStore(configuration: ForgeSQLiteConfiguration(
            databaseURL: directory.appendingPathComponent("forge.sqlite3"),
            recoveryDirectoryURL: directory.appendingPathComponent("recovery", isDirectory: true)
        ))
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let backing = ForgeSQLiteAvatarBackingStore(store: sqlite, clock: { now })
        let avatarURL = try ForgeAvatarURL("https://avatars.githubusercontent.com/u/61")
        let repository = try ForgeRepositoryIdentity(
            forge: ForgeIdentity(kind: .github, origin: ForgeOrigin(host: "github.com")),
            owner: "example",
            name: "repo"
        )
        let snapshotKey = try ForgeDisposableCacheKey.snapshot(ForgeCacheRecordKey(
            repositoryPartition: ForgeRepositoryPartitionKey(
                cachePartition: .publicAccess,
                repository: repository
            ),
            kind: .derivedRenderData,
            identity: "avatar-purge-partition-proof"
        ))
        let snapshotPayload = Data([9])
        try await sqlite.putCacheEntry(ForgeSQLiteCacheEntry(
            record: ForgeDisposableCacheRecord(
                key: snapshotKey,
                byteCount: UInt64(snapshotPayload.count),
                fetchedAt: now,
                lastAccessedAt: now
            ),
            payload: snapshotPayload
        ))

        for mediaType in ForgeAvatarMediaType.allCases {
            let payload = ForgeAvatarPayload(data: Data([6, UInt8(mediaType.rawValue.count)]), mediaType: mediaType)
            try await backing.store(payload, for: avatarURL, owners: [.anonymous])
            let loaded = try await backing.payload(for: avatarURL, owner: .anonymous)
            XCTAssertEqual(loaded, payload)
        }
        let forge = repository.forge
        let firstAccount = try ForgeAccountID(forge: forge, value: "sqlite-avatar-first-owner")
        let secondAccount = try ForgeAccountID(forge: forge, value: "sqlite-avatar-second-owner")
        let associatedURL = try ForgeAvatarURL("https://avatars.githubusercontent.com/u/611")
        let associatedPayload = ForgeAvatarPayload(data: Data([6, 11]), mediaType: .png)
        try await backing.store(
            associatedPayload,
            for: associatedURL,
            owners: [.account(firstAccount)]
        )
        try await backing.associate(.account(secondAccount), with: associatedURL)
        let firstRemovalCount = try await sqlite.removeAvatarAssociations(for: firstAccount)
        let secondOwnerPayload = try await backing.payload(
            for: associatedURL,
            owner: .account(secondAccount)
        )
        let secondRemovalCount = try await sqlite.removeAvatarAssociations(for: secondAccount)
        XCTAssertEqual(firstRemovalCount, 0)
        XCTAssertEqual(secondOwnerPayload, associatedPayload)
        XCTAssertEqual(secondRemovalCount, 1)
        let zeroByteURL = try ForgeAvatarURL("https://avatars.githubusercontent.com/u/610")
        let zeroByteKey = ForgeAvatarCacheKey(canonicalURL: zeroByteURL.url)
        let zeroByteRecord = try ForgeDisposableCacheRecord(
            key: .avatar(zeroByteKey),
            byteCount: 0,
            fetchedAt: now,
            lastAccessedAt: now
        )
        try await sqlite.putCacheEntry(ForgeSQLiteCacheEntry(
            record: zeroByteRecord,
            payload: Data()
        ))

        try await backing.purge()
        let purged = try await backing.payload(for: avatarURL, owner: .anonymous)
        let purgedZeroByte = try await sqlite.cacheEntry(for: .avatar(zeroByteKey), accessedAt: now)
        let retainedSnapshot = try await sqlite.cacheEntry(for: snapshotKey, accessedAt: now)
        XCTAssertNil(purged)
        XCTAssertNil(purgedZeroByte)
        XCTAssertEqual(retainedSnapshot?.payload, snapshotPayload)
        await sqlite.close()
    }

    func testSQLiteAvatarBackingStoreDeletesMalformedPayloadAndSurvivesPersistenceFailure() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitXAvatarCorruption-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sqlite = try ForgeSQLiteStore(configuration: ForgeSQLiteConfiguration(
            databaseURL: directory.appendingPathComponent("forge.sqlite3"),
            recoveryDirectoryURL: directory.appendingPathComponent("recovery", isDirectory: true)
        ))
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let backing = ForgeSQLiteAvatarBackingStore(store: sqlite, clock: { now })
        let avatarURL = try ForgeAvatarURL("https://avatars.githubusercontent.com/u/62")
        let cacheKey = ForgeAvatarCacheKey(canonicalURL: avatarURL.url)
        let malformed = Data([0, 6, 2])
        try await sqlite.putAvatarCacheEntry(
            ForgeSQLiteCacheEntry(
                record: ForgeDisposableCacheRecord(
                    key: .avatar(cacheKey),
                    byteCount: UInt64(malformed.count),
                    fetchedAt: now,
                    lastAccessedAt: now
                ),
                payload: malformed
            ),
            owners: [.anonymous]
        )

        await XCTAssertThrowsErrorAsync(
            try await backing.payload(for: avatarURL, owner: .anonymous)
        ) {
            XCTAssertEqual($0 as? ForgeAvatarLoadingError, .decodingFailed)
        }
        let deletedMalformedEntry = try await sqlite.cacheEntry(
            for: .avatar(cacheKey),
            accessedAt: now
        )
        XCTAssertNil(deletedMalformedEntry)

        await sqlite.close()
        let networkPayload = ForgeAvatarPayload(data: Data([6, 2]), mediaType: .png)
        let transport = RecordingAvatarTransport(payload: networkPayload)
        let loader = ForgeAvatarLoader(transport: transport, backingStore: backing)
        let loadedAfterFailure = try await loader.load(avatarURL)
        let fetchesAfterFailure = await transport.fetchCount
        let persistenceFailures = await loader.statistics().backingStoreFailures
        XCTAssertEqual(loadedAfterFailure, networkPayload)
        XCTAssertEqual(fetchesAfterFailure, 1)
        XCTAssertGreaterThanOrEqual(persistenceFailures, 2)
    }

    func testPersistedDisabledInstallPurgesSQLiteBeforeGrantingNoNetworkAuthority() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitXAvatarDisabledPersistence-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sqlite = try ForgeSQLiteStore(configuration: ForgeSQLiteConfiguration(
            databaseURL: directory.appendingPathComponent("forge.sqlite3"),
            recoveryDirectoryURL: directory.appendingPathComponent("recovery", isDirectory: true)
        ))
        let backing = ForgeSQLiteAvatarBackingStore(store: sqlite)
        let avatarURL = try ForgeAvatarURL("https://avatars.githubusercontent.com/u/63")
        let payload = ForgeAvatarPayload(data: Data([6, 3]), mediaType: .jpeg)
        try await backing.store(payload, for: avatarURL, owners: [.anonymous])
        let transport = RecordingAvatarTransport(payload: payload)
        let loader = ForgeAvatarLoader(transport: transport)

        try await loader.installBackingStore(backing, loadingEnabled: false)

        let persisted = try await sqlite.cacheEntry(
            for: .avatar(ForgeAvatarCacheKey(canonicalURL: avatarURL.url)),
            accessedAt: Date()
        )
        XCTAssertNil(persisted)
        await XCTAssertThrowsErrorAsync(try await loader.load(avatarURL)) {
            XCTAssertEqual($0 as? ForgeAvatarLoadingError, .disabled)
        }
        let disabledFetchCount = await transport.fetchCount
        let disabledState = await loader.statistics().enabled
        XCTAssertEqual(disabledFetchCount, 0)
        XCTAssertFalse(disabledState)

        await sqlite.close()
        let failingLoader = ForgeAvatarLoader(transport: transport)
        await XCTAssertThrowsErrorAsync(
            try await failingLoader.installBackingStore(backing, loadingEnabled: false)
        ) { error in
            XCTAssertEqual(error.localizedDescription, ForgeSQLiteError.closed.localizedDescription)
        }
        let failedInstall = await failingLoader.statistics()
        XCTAssertFalse(failedInstall.enabled)
        XCTAssertEqual(failedInstall.backingStoreFailures, 1)
    }

    func testRequiredBackingInstallationFailsClosedAndPreservesNewerPreferenceAuthority() async throws {
        let avatarURL = try ForgeAvatarURL("https://avatars.githubusercontent.com/u/631")
        let payload = ForgeAvatarPayload(data: Data([6, 31]), mediaType: .png)
        let transport = RecordingAvatarTransport(payload: payload)
        let loader = ForgeAvatarLoader(
            transport: transport,
            loadingEnabled: false,
            requiresBackingStoreInstallation: true
        )

        await loader.setLoadingEnabled(true)
        await XCTAssertThrowsErrorAsync(try await loader.load(avatarURL)) { error in
            XCTAssertEqual(error as? ForgeAvatarLoadingError, .disabled)
        }
        let preinstallFetches = await transport.fetchCount
        let preinstallEnabled = await loader.statistics().enabled
        XCTAssertEqual(preinstallFetches, 0)
        XCTAssertFalse(preinstallEnabled)

        try await loader.installBackingStore(
            ForgeAvatarMemoryOnlyBackingStore(),
            loadingEnabled: false
        )
        let loaded = try await loader.load(avatarURL)
        let installedEnabled = await loader.statistics().enabled
        XCTAssertEqual(loaded, payload)
        XCTAssertTrue(installedEnabled)
    }

    func testLoaderPersistsEveryCoalescedOwnerWithoutPuttingAccountIdentityInAvatarBytes() async throws {
        let avatarURL = try ForgeAvatarURL("https://avatars.githubusercontent.com/u/64")
        let payload = ForgeAvatarPayload(data: Data([6, 4]), mediaType: .webP)
        let transport = ControlledAvatarTransport(payload: payload)
        let backing = RecordingAvatarBackingStore()
        let loader = ForgeAvatarLoader(transport: transport, backingStore: backing)
        let forge = try ForgeIdentity(kind: .github, origin: ForgeOrigin(host: "github.com"))
        let firstAccount = try ForgeAccountID(forge: forge, value: "avatar-owner-one")
        let secondAccount = try ForgeAccountID(forge: forge, value: "avatar-owner-two")

        let first = Task { try await loader.load(avatarURL, owner: .account(firstAccount)) }
        await transport.waitUntilStarted()
        let second = Task { try await loader.load(avatarURL, owner: .account(secondAccount)) }
        let coalesced = await waitForWaiterCount(2, in: loader)
        XCTAssertTrue(coalesced)
        await transport.complete()
        let firstPayload = try await first.value
        let secondPayload = try await second.value
        XCTAssertEqual(firstPayload, payload)
        XCTAssertEqual(secondPayload, payload)
        _ = try await loader.load(avatarURL, owner: .anonymous)

        let owners = await backing.ownerSet(for: avatarURL)
        let fetchCount = await transport.fetchCount
        XCTAssertEqual(owners, [.account(firstAccount), .account(secondAccount), .anonymous])
        XCTAssertEqual(fetchCount, 1)
        XCTAssertNil(payload.data.range(of: Data(firstAccount.value.utf8)))
        XCTAssertNil(payload.data.range(of: Data(secondAccount.value.utf8)))
    }

    func testLoaderReconcilesAnOwnerJoiningWhileSQLiteStoreIsSuspended() async throws {
        let avatarURL = try ForgeAvatarURL("https://avatars.githubusercontent.com/u/65")
        let payload = ForgeAvatarPayload(data: Data([6, 5]), mediaType: .png)
        let backing = LateJoinAvatarBackingStore()
        let loader = ForgeAvatarLoader(
            transport: RecordingAvatarTransport(payload: payload),
            backingStore: backing
        )
        let forge = try ForgeIdentity(kind: .github, origin: ForgeOrigin(host: "github.com"))
        let firstAccount = try ForgeAccountID(forge: forge, value: "store-owner-one")
        let lateAccount = try ForgeAccountID(forge: forge, value: "store-owner-late")

        let first = Task { try await loader.load(avatarURL, owner: .account(firstAccount)) }
        await backing.waitUntilStoreStarted()
        let late = Task { try await loader.load(avatarURL, owner: .account(lateAccount)) }
        let joinedDuringStore = await waitForWaiterCount(2, in: loader)
        XCTAssertTrue(joinedDuringStore)
        await backing.releaseStore()

        let firstPayload = try await first.value
        let latePayload = try await late.value
        let owners = await backing.ownerSet(for: avatarURL)
        XCTAssertEqual(firstPayload, payload)
        XCTAssertEqual(latePayload, payload)
        XCTAssertEqual(owners, [.account(firstAccount), .account(lateAccount)])
    }

    func testAvatarPreferenceCoordinatorAppliesRapidUpdatesInSubmissionOrder() async {
        let controller = RecordingAvatarLoadingController()
        let coordinator = ForgeAvatarLoadingPreferenceCoordinator { enabled in
            await controller.setLoadingEnabled(enabled)
        }

        [false, true, false, true].forEach(coordinator.submit)
        await coordinator.flush()

        let values = await controller.values
        XCTAssertEqual(values, [false, true, false, true])
    }

    func testAvatarDisableShowsInitialsBeforeDisposableBackingPurgeCompletes() async throws {
        let payload = try ForgeAvatarPayload(
            data: rasterData(type: .png, width: 24, height: 24),
            mediaType: .png
        )
        let backing = BlockingPurgeAvatarBackingStore()
        let loader = ForgeAvatarLoader(
            transport: RecordingAvatarTransport(payload: payload),
            backingStore: backing
        )
        let view = ForgeAvatarView(loader: loader, loadingEnabled: true)
        view.configure(
            displayName: "Ada Lovelace",
            avatarURL: URL(string: "https://avatars.githubusercontent.com/u/77")
        )
        await view.waitForPendingLoad()
        XCTAssertTrue(view.accessibilityLabel()?.contains(", avatar") == true)

        let coordinator = ForgeAvatarLoadingPreferenceCoordinator(
            apply: { enabled in
                await loader.setLoadingEnabled(enabled)
            },
            willApply: { enabled in
                guard !enabled else { return }
                await MainActor.run {
                    ForgeAvatarLoadingPreferenceNotification.post(enabled: enabled)
                }
            }
        )
        coordinator.submit(false)
        await backing.waitUntilPurgeStarted()

        XCTAssertTrue(view.accessibilityLabel()?.contains("initials AL") == true)
        let purgeFinishedBeforeRelease = await backing.purgeFinished
        XCTAssertFalse(purgeFinishedBeforeRelease)

        await backing.releasePurge()
        await coordinator.flush()
        let purgeFinishedAfterRelease = await backing.purgeFinished
        XCTAssertTrue(purgeFinishedAfterRelease)
    }

    func testPersistedOffStateDisablesLoaderNetworkAuthorityBeforeFirstRequest() async throws {
        let avatarURL = try ForgeAvatarURL("https://avatars.githubusercontent.com/u/78")
        let transport = RecordingAvatarTransport(
            payload: ForgeAvatarPayload(data: Data([7, 8]), mediaType: .png)
        )
        let loader = ForgeAvatarLoader(transport: transport, loadingEnabled: false)

        await XCTAssertThrowsErrorAsync(try await loader.load(avatarURL)) { error in
            XCTAssertEqual(error as? ForgeAvatarLoadingError, .disabled)
        }
        let fetchCount = await transport.fetchCount
        XCTAssertEqual(fetchCount, 0)
    }

    func testLoadAvatarsPreferenceDefaultsOnAndGeneralPaneExposesAccessibleControl() async throws {
        let original = PBApplicationComposition.shared()
        let suite = "GitXTests.ForgeAvatarPreference.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        PBApplicationComposition.setShared(PBApplicationComposition(
            userDefaults: defaults,
            automaticallyStartsForgeServices: false
        ))
        defer {
            PBApplicationComposition.setShared(original)
            defaults.removePersistentDomain(forName: suite)
        }

        XCTAssertTrue(PBApplicationSettings.loadAvatars)
        let notification = expectation(forNotification: .forgeAvatarLoadingDidChange, object: nil)
        PBApplicationSettings.loadAvatars = false
        await fulfillment(of: [notification], timeout: 1)
        XCTAssertFalse(defaults.bool(forKey: "PBLoadForgeAvatars"))

        let pane = PBSettingsViewFactory.generalView(legacyView: NSView())
        let button = try XCTUnwrap(descendants(of: pane).compactMap { $0 as? NSButton }.first {
            $0.accessibilityIdentifier() == "LoadForgeAvatars"
        })
        XCTAssertEqual(button.state, .off)
        XCTAssertEqual(button.accessibilityLabel(), "Load structured GitHub avatars")
        button.performClick(nil)
        await ForgeAvatarLoadingPreferenceCoordinator.shared.flush()
        XCTAssertTrue(PBApplicationSettings.loadAvatars)

        let rapidNotifications = expectation(
            description: "Every causally ordered rapid avatar preference update is observed"
        )
        rapidNotifications.expectedFulfillmentCount = 4
        let notificationValues = AvatarPreferenceNotificationRecorder()
        let observer = NotificationCenter.default.addObserver(
            forName: .forgeAvatarLoadingDidChange,
            object: nil,
            queue: nil
        ) { notification in
            if let enabled = notification.userInfo?[ForgeAvatarLoadingPreferenceNotification.enabledUserInfoKey]
                as? Bool
            {
                notificationValues.append(enabled)
            }
            rapidNotifications.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        PBApplicationSettings.loadAvatars = false
        PBApplicationSettings.loadAvatars = true
        PBApplicationSettings.loadAvatars = false
        PBApplicationSettings.loadAvatars = true
        await fulfillment(of: [rapidNotifications], timeout: 1)
        await ForgeAvatarLoadingPreferenceCoordinator.shared.flush()
        XCTAssertEqual(notificationValues.values, [false, true, false, true])
    }

    func testInitialsFallbackIsImmediateAccessibleAndHasDiagnosticScreenshot() throws {
        XCTAssertEqual(ForgeAvatarView.initials(for: "Ada Lovelace"), "AL")
        XCTAssertEqual(ForgeAvatarView.initials(for: "octocat"), "O")
        XCTAssertEqual(ForgeAvatarView.initials(for: "  "), "?")

        let avatar = ForgeAvatarView(frame: NSRect(x: 0, y: 0, width: 42, height: 42))
        avatar.configure(displayName: "Ada Lovelace", avatarURL: URL(string: "file:///etc/passwd"))
        XCTAssertEqual(avatar.initials, "AL")
        XCTAssertTrue(avatar.accessibilityLabel()?.contains("initials AL") ?? false)

        let markdown = ForgeMarkdownNativeView(document: ForgeMarkdownDocument(blocks: [
            .heading(level: 2, identifier: ForgeMarkdownHeadingID(rawValue: "review"), content: [.text("Review")]),
            .paragraph([
                .text("Native Markdown keeps "),
                .strong([.text("untrusted content")]),
                .text(" readable. "),
                .imagePlaceholder(altText: "architecture diagram"),
            ]),
            .unorderedList([
                ForgeMarkdownListItem(taskState: .checked, blocks: [.paragraph([.text("Sanitized")])]),
                ForgeMarkdownListItem(taskState: .unchecked, blocks: [.paragraph([.text("Review requested")])]),
            ]),
        ]))
        let stack = NSStackView(views: [avatar, markdown])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        stack.frame = NSRect(x: 0, y: 0, width: 680, height: 360)
        markdown.widthAnchor.constraint(equalToConstant: 648).isActive = true
        markdown.heightAnchor.constraint(equalToConstant: 270).isActive = true
        stack.layoutSubtreeIfNeeded()
        try attachScreenshot(of: stack, named: "Forge Markdown and initials avatar diagnostic")
    }

    func testAppModuleProductBoundariesReceiveAppHostedCoverage() async throws {
        XCTAssertEqual(PBForgeMarkdownAvatarProductHarness.markdownProof(), 0b11_1111_1111_1111)
        XCTAssertEqual(PBForgeMarkdownAvatarProductHarness.requestProof(), 0b1_1111_1111)

        let png = try rasterData(type: .png, width: 12, height: 10)
        XCTAssertTrue(PBForgeMarkdownAvatarProductHarness.validateAvatarData(
            png,
            declaredMediaType: ForgeAvatarMediaType.png.rawValue,
            maximumPixels: 120,
            expectedWidth: 12,
            expectedHeight: 10
        ))
        XCTAssertFalse(PBForgeMarkdownAvatarProductHarness.validateAvatarData(
            png,
            declaredMediaType: ForgeAvatarMediaType.jpeg.rawValue,
            maximumPixels: 120,
            expectedWidth: 12,
            expectedHeight: 10
        ))
        XCTAssertEqual(PBForgeMarkdownAvatarProductHarness.avatarFallbackProof(), 0b11111)

        let loaderProof = await PBForgeMarkdownAvatarProductHarness.loaderProof()
        XCTAssertEqual(loaderProof, 0b1111_1111_1111_1111)

        let sidebarAttentionProof = await PBForgeMarkdownAvatarProductHarness.sidebarAttentionProof()
        XCTAssertEqual(sidebarAttentionProof, 0b1_1111_1111_1111)

        let startupFailureProof = await PBForgeMarkdownAvatarProductHarness.applicationStartupFailureProof()
        XCTAssertEqual(startupFailureProof, 1)
    }

    private func cell(_ text: String) -> ForgeMarkdownTableCell {
        ForgeMarkdownTableCell(columnSpan: 1, rowSpan: 1, content: [.text(text)])
    }

    private func linkURLs(in attributedString: NSAttributedString) -> [URL] {
        var links: [URL] = []
        attributedString.enumerateAttribute(
            .link,
            in: NSRange(location: 0, length: attributedString.length)
        ) { value, _, _ in
            if let url = value as? URL, !links.contains(url) {
                links.append(url)
            }
        }
        return links
    }

    private func rasterData(
        type: NSBitmapImageRep.FileType,
        width: Int,
        height: Int
    ) throws -> Data {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSColor.systemBlue.setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: width, height: height)).fill()
        NSGraphicsContext.restoreGraphicsState()
        return try XCTUnwrap(bitmap.representation(using: type, properties: [:]))
    }

    private func animatedGIFData() throws -> Data {
        let png = try rasterData(type: .png, width: 4, height: 4)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(png as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(
            data,
            UTType.gif.identifier as CFString,
            2,
            nil
        ))
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private func descendants(of root: NSView) -> [NSView] {
        root.subviews + root.subviews.flatMap(descendants(of:))
    }

    private func attachScreenshot(of view: NSView, named name: String) throws {
        let representation = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: representation)
        let image = NSImage(size: view.bounds.size)
        image.addRepresentation(representation)
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

// swift6-safety-justification: Every access to the sole mutable value is serialized by the private lock.
private final class RedirectResult: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: URLRequest?

    var value: URLRequest? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
        set {
            lock.lock()
            stored = newValue
            lock.unlock()
        }
    }
}

// swift6-safety-justification: The sender is stateless and exists only to construct a deterministic challenge.
private final class NoOpAuthenticationChallengeSender: NSObject, URLAuthenticationChallengeSender, @unchecked Sendable {
    func use(_: URLCredential, for _: URLAuthenticationChallenge) {}
    func continueWithoutCredential(for _: URLAuthenticationChallenge) {}
    func cancel(_: URLAuthenticationChallenge) {}
}

// swift6-safety-justification: Every access to the two mutable observations is serialized by the private lock.
private final class AuthenticationChallengeResult: @unchecked Sendable {
    private let lock = NSLock()
    private var storedDisposition: URLSession.AuthChallengeDisposition?
    private var storedCredential: URLCredential?

    var disposition: URLSession.AuthChallengeDisposition? {
        lock.withLock { storedDisposition }
    }

    var credential: URLCredential? {
        lock.withLock { storedCredential }
    }

    func record(disposition: URLSession.AuthChallengeDisposition, credential: URLCredential?) {
        lock.withLock {
            storedDisposition = disposition
            storedCredential = credential
        }
    }
}

private actor RecordingAvatarTransport: ForgeAvatarTransport {
    let payload: ForgeAvatarPayload
    private(set) var fetchCount = 0

    init(payload: ForgeAvatarPayload) {
        self.payload = payload
    }

    func fetch(_: ForgeAvatarURL) async throws -> ForgeAvatarPayload {
        fetchCount += 1
        return payload
    }
}

private actor BlockingAvatarTransport: ForgeAvatarTransport {
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []

    func fetch(_: ForgeAvatarURL) async throws -> ForgeAvatarPayload {
        started = true
        startWaiters.forEach { $0.resume() }
        startWaiters.removeAll()
        try await Task.sleep(nanoseconds: 60_000_000_000)
        throw CancellationError()
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }
}

private actor ControlledAvatarTransport: ForgeAvatarTransport {
    let payload: ForgeAvatarPayload
    private(set) var fetchCount = 0
    private(set) var cancellationCount = 0
    private var continuation: CheckedContinuation<ForgeAvatarPayload, Error>?
    private var startWaiters: [CheckedContinuation<Void, Never>] = []

    init(payload: ForgeAvatarPayload) {
        self.payload = payload
    }

    func fetch(_: ForgeAvatarURL) async throws -> ForgeAvatarPayload {
        fetchCount += 1
        startWaiters.forEach { $0.resume() }
        startWaiters.removeAll()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation = $0 }
        } onCancel: {
            Task { await self.cancel() }
        }
    }

    func waitUntilStarted() async {
        guard fetchCount == 0 else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func complete() {
        continuation?.resume(returning: payload)
        continuation = nil
    }

    func waitForCancellation() async -> Bool {
        for _ in 0 ..< 1000 {
            if cancellationCount > 0 {
                return true
            }
            await Task.yield()
        }
        return false
    }

    private func cancel() {
        cancellationCount += 1
        continuation?.resume(throwing: CancellationError())
        continuation = nil
    }
}

private actor SequencedAvatarTransport: ForgeAvatarTransport {
    private(set) var fetchCount = 0
    private var continuations: [CheckedContinuation<ForgeAvatarPayload, Error>] = []

    func fetch(_: ForgeAvatarURL) async throws -> ForgeAvatarPayload {
        fetchCount += 1
        return try await withCheckedThrowingContinuation { continuations.append($0) }
    }

    func waitForFetchCount(_ expected: Int) async -> Bool {
        for _ in 0 ..< 1000 {
            if fetchCount >= expected {
                return true
            }
            await Task.yield()
        }
        return false
    }

    func completeFetch(at index: Int, with payload: ForgeAvatarPayload) {
        continuations[index].resume(returning: payload)
    }
}

private actor RecordingAvatarBackingStore: ForgeAvatarBackingStore {
    private var entries: [ForgeAvatarURL: ForgeAvatarPayload]
    private var owners: [ForgeAvatarURL: Set<ForgeAvatarCacheOwner>] = [:]
    private(set) var loadCount = 0
    private(set) var purgeCount = 0

    init(entries: [ForgeAvatarURL: ForgeAvatarPayload] = [:]) {
        self.entries = entries
    }

    func payload(
        for avatarURL: ForgeAvatarURL,
        owner: ForgeAvatarCacheOwner
    ) async throws -> ForgeAvatarPayload? {
        loadCount += 1
        owners[avatarURL, default: []].insert(owner)
        return entries[avatarURL]
    }

    func store(
        _ payload: ForgeAvatarPayload,
        for avatarURL: ForgeAvatarURL,
        owners: Set<ForgeAvatarCacheOwner>
    ) async throws {
        entries[avatarURL] = payload
        self.owners[avatarURL, default: []].formUnion(owners)
    }

    func associate(_ owner: ForgeAvatarCacheOwner, with avatarURL: ForgeAvatarURL) async throws {
        owners[avatarURL, default: []].insert(owner)
    }

    func purge() async throws {
        purgeCount += 1
        entries.removeAll()
    }

    func storedPayload(for avatarURL: ForgeAvatarURL) -> ForgeAvatarPayload? {
        entries[avatarURL]
    }

    func ownerSet(for avatarURL: ForgeAvatarURL) -> Set<ForgeAvatarCacheOwner> {
        owners[avatarURL] ?? []
    }
}

private actor LateJoinAvatarBackingStore: ForgeAvatarBackingStore {
    private var owners: [ForgeAvatarURL: Set<ForgeAvatarCacheOwner>] = [:]
    private var storeStarted = false
    private var storeReleased = false
    private var storeStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var storeReleaseWaiters: [CheckedContinuation<Void, Never>] = []

    func payload(
        for _: ForgeAvatarURL,
        owner _: ForgeAvatarCacheOwner
    ) async throws -> ForgeAvatarPayload? {
        nil
    }

    func store(
        _: ForgeAvatarPayload,
        for avatarURL: ForgeAvatarURL,
        owners: Set<ForgeAvatarCacheOwner>
    ) async throws {
        self.owners[avatarURL, default: []].formUnion(owners)
        storeStarted = true
        let startWaiters = storeStartWaiters
        storeStartWaiters.removeAll()
        startWaiters.forEach { $0.resume() }
        if !storeReleased {
            await withCheckedContinuation { storeReleaseWaiters.append($0) }
        }
    }

    func associate(_ owner: ForgeAvatarCacheOwner, with avatarURL: ForgeAvatarURL) async throws {
        owners[avatarURL, default: []].insert(owner)
    }

    func purge() async throws {
        owners.removeAll()
    }

    func waitUntilStoreStarted() async {
        if storeStarted {
            return
        }
        await withCheckedContinuation { storeStartWaiters.append($0) }
    }

    func releaseStore() {
        storeReleased = true
        let waiters = storeReleaseWaiters
        storeReleaseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func ownerSet(for avatarURL: ForgeAvatarURL) -> Set<ForgeAvatarCacheOwner> {
        owners[avatarURL] ?? []
    }
}

private actor BlockingPurgeAvatarBackingStore: ForgeAvatarBackingStore {
    private(set) var purgeFinished = false
    private var purgeStarted = false
    private var purgeReleased = false
    private var purgeContinuation: CheckedContinuation<Void, Never>?
    private var startWaiters: [CheckedContinuation<Void, Never>] = []

    func payload(
        for _: ForgeAvatarURL,
        owner _: ForgeAvatarCacheOwner
    ) async throws -> ForgeAvatarPayload? {
        nil
    }

    func store(
        _: ForgeAvatarPayload,
        for _: ForgeAvatarURL,
        owners _: Set<ForgeAvatarCacheOwner>
    ) async throws {}

    func associate(_: ForgeAvatarCacheOwner, with _: ForgeAvatarURL) async throws {}

    func purge() async throws {
        purgeStarted = true
        startWaiters.forEach { $0.resume() }
        startWaiters.removeAll()
        if !purgeReleased {
            await withCheckedContinuation { purgeContinuation = $0 }
        }
        purgeFinished = true
    }

    func waitUntilPurgeStarted() async {
        guard !purgeStarted else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func releasePurge() {
        purgeReleased = true
        purgeContinuation?.resume()
        purgeContinuation = nil
    }
}

// swift6-safety-justification: Every access to the captured notification values is serialized by the private lock.
private final class AvatarPreferenceNotificationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValues: [Bool] = []

    var values: [Bool] {
        lock.withLock { storedValues }
    }

    func append(_ value: Bool) {
        lock.withLock { storedValues.append(value) }
    }
}

private actor RecordingAvatarLoadingController {
    private(set) var values: [Bool] = []

    func setLoadingEnabled(_ enabled: Bool) async {
        values.append(enabled)
    }
}

private struct FailingAvatarBackingStore: ForgeAvatarBackingStore {
    func payload(
        for _: ForgeAvatarURL,
        owner _: ForgeAvatarCacheOwner
    ) async throws -> ForgeAvatarPayload? {
        throw TestAvatarBackingError.failed
    }

    func store(
        _: ForgeAvatarPayload,
        for _: ForgeAvatarURL,
        owners _: Set<ForgeAvatarCacheOwner>
    ) async throws {
        throw TestAvatarBackingError.failed
    }

    func associate(_: ForgeAvatarCacheOwner, with _: ForgeAvatarURL) async throws {
        throw TestAvatarBackingError.failed
    }

    func purge() async throws {
        throw TestAvatarBackingError.failed
    }
}

private enum TestAvatarBackingError: Error {
    case failed
}

private func waitForWaiterCount(_ count: Int, in loader: ForgeAvatarLoader) async -> Bool {
    for _ in 0 ..< 1000 {
        if await loader.statistics().activeWaiters == count {
            return true
        }
        await Task.yield()
    }
    return false
}

private func waitForDiscardedCompletion(in loader: ForgeAvatarLoader) async -> Bool {
    for _ in 0 ..< 1000 {
        if await loader.statistics().discardedRequestCompletions > 0 {
            return true
        }
        await Task.yield()
    }
    return false
}

func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ errorHandler: (Error) -> Void = { _ in },
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected expression to throw", file: file, line: line)
    } catch {
        errorHandler(error)
    }
}
