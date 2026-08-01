#if DEBUG
    import AppKit
    import ForgeKit

    /// Objective-C-compatible entry points that let the app-hosted test bundle
    /// execute the app module's internal pure-Swift Markdown and avatar boundaries.
    @MainActor
    @objc(PBForgeMarkdownAvatarProductHarness)
    // Objective-C XCTest reaches this harness through its explicit runtime name.
    // swiftlint:disable:next unused_declaration
    final class ForgeMarkdownAvatarProductHarness: NSObject {
        private final class Router: ForgeMarkdownNavigationRouting {
            var activations = 0
            var browserEscapes = 0

            func activateMarkdownLink(_: ForgeMarkdownLinkTarget) {
                activations += 1
            }

            func openMarkdownLinkInBrowser(_: URL) {
                browserEscapes += 1
            }
        }

        @objc static func markdownProof() -> UInt64 {
            autoreleasepool {
                makeMarkdownProof()
            }
        }

        private static func makeMarkdownProof() -> UInt64 {
            let heading = ForgeMarkdownHeadingID(rawValue: "overview")
            guard let external = try? ForgeHTTPSLink("https://example.com/path") else {
                return 0
            }
            let document = ForgeMarkdownDocument(blocks: [
                .heading(level: 1, identifier: heading, content: [.text("Overview")]),
                .paragraph([
                    .text("Plain "),
                    .emphasis([.text("emphasis")]),
                    .strong([.text("strong")]),
                    .strikethrough([.text("removed")]),
                    .softBreak,
                    .inlineCode("value"),
                    .lineBreak,
                    .link(label: [.text("external")], target: .https(external)),
                    .imagePlaceholder(altText: "diagram"),
                ]),
                .blockQuote([.paragraph([.text("Quoted")])]),
                .unorderedList([
                    ForgeMarkdownListItem(taskState: .checked, blocks: [.paragraph([.text("Done")])]),
                    ForgeMarkdownListItem(taskState: .unchecked, blocks: [.paragraph([.text("Todo")])]),
                    ForgeMarkdownListItem(taskState: nil, blocks: [.paragraph([.text("Bullet")])]),
                ]),
                .orderedList(start: UInt.max, items: [
                    ForgeMarkdownListItem(taskState: nil, blocks: [.paragraph([.text("Last")])]),
                    ForgeMarkdownListItem(taskState: nil, blocks: [.paragraph([.text("Overflow")])]),
                ]),
                .table(ForgeMarkdownTable(
                    columnAlignments: [.left, .center, .right],
                    header: [cell("Name"), cell("Status"), cell("Value")],
                    rows: [[cell("A"), cell("Ready"), cell("1")]]
                )),
                .thematicBreak,
                .codeBlock(language: "swift", code: "let answer = 42"),
                .codeBlock(language: nil, code: "plain code\n"),
            ])
            let rendered = ForgeMarkdownNativeRenderer().render(document)
            let valueRange = (rendered.attributedString.string as NSString).range(of: "Value")
            let tableParagraph = valueRange.location == NSNotFound
                ? nil
                : rendered.attributedString.attribute(
                    .paragraphStyle,
                    at: valueRange.location,
                    effectiveRange: nil
                ) as? NSParagraphStyle
            let router = Router()
            let view = ForgeMarkdownNativeView(document: navigationDocument(), navigationRouter: router)
            view.translatesAutoresizingMaskIntoConstraints = true
            view.frame = NSRect(x: 0, y: 0, width: 640, height: 260)
            view.layoutSubtreeIfNeeded()
            let browserMenuOpened = exerciseBrowserMenu(in: view)
            var activatedLinks = 0
            view.textView.attributedString().enumerateAttribute(
                .link,
                in: NSRange(location: 0, length: view.textView.string.utf16.count)
            ) { value, _, _ in
                if let value, view.textView(view.textView, clickedOnLink: value, at: 0) {
                    activatedLinks += 1
                }
            }
            let missingLinkWasActivated = view.activateLink(
                URL(string: "x-gitx-markdown-link://missing") as Any
            )
            let nativeText = view.textView.string
            view.display(document)
            let conditions = [
                rendered.attributedString.string.contains("▧ Image: diagram"),
                nativeText.contains("▧ Image: secret"),
                rendered.headingRanges.count == 1,
                rendered.linkTargets.count == 1,
                activatedLinks == 2,
                router.activations == 1,
                router.browserEscapes == 1,
                browserMenuOpened,
                view.window == nil,
                !missingLinkWasActivated,
                [
                    ForgeAvatarLoadingError.disabled,
                    .invalidResponse,
                    .decodingFailed,
                ].compactMap(\.errorDescription).count == 3,
                view.accessibilityIdentifier() == "ForgeMarkdownNativeView",
                view.textView.string.contains("▧ Image: diagram"),
                tableParagraph?.tabStops.map(\.alignment) == [.left, .center, .right],
            ]
            return conditions.enumerated().reduce(into: UInt64(0)) { proof, condition in
                if condition.element {
                    proof |= UInt64(1) << UInt64(condition.offset)
                }
            }
        }

        @objc static func requestProof() -> UInt64 {
            autoreleasepool {
                makeRequestProof()
            }
        }

        private static func makeRequestProof() -> UInt64 {
            guard let avatarURL = try? ForgeAvatarURL(
                "https://avatars.githubusercontent.com/u/1?v=4"
            ) else {
                return 0
            }
            let configuration = ForgeAvatarNetworkTransport.secureConfiguration()
            let request = ForgeAvatarNetworkTransport.request(for: avatarURL)
            let delegate = ForgeAvatarRedirectDelegate()
            let session = URLSession(configuration: .ephemeral)
            let task = session.dataTask(with: request)
            let response = HTTPURLResponse(
                url: avatarURL.url,
                statusCode: 302,
                httpVersion: nil,
                headerFields: nil
            )
            let acceptedRedirect = HarnessRedirectResult()
            let rejectedRedirect = HarnessRedirectResult()
            if let response,
               let acceptedURL = URL(string: "https://avatars.githubusercontent.com/u/2"),
               let rejectedURL = URL(string: "https://evil.example/avatar.png")
            {
                delegate.urlSession(
                    session,
                    task: task,
                    willPerformHTTPRedirection: response,
                    newRequest: URLRequest(url: acceptedURL)
                ) { acceptedRedirect.value = $0 }
                delegate.urlSession(
                    session,
                    task: task,
                    willPerformHTTPRedirection: response,
                    newRequest: URLRequest(url: rejectedURL)
                ) { rejectedRedirect.value = $0 }
            }
            session.invalidateAndCancel()
            let conditions = [
                configuration.httpCookieStorage == nil,
                !configuration.httpShouldSetCookies,
                configuration.urlCredentialStorage == nil,
                configuration.urlCache == nil,
                request.value(forHTTPHeaderField: "Authorization") == nil,
                request.value(forHTTPHeaderField: "Cookie") == nil,
                request.value(forHTTPHeaderField: "Referer") == nil,
                acceptedRedirect.value?.url?.host == "avatars.githubusercontent.com",
                rejectedRedirect.value == nil,
            ]
            return conditions.enumerated().reduce(into: UInt64(0)) { proof, condition in
                if condition.element {
                    proof |= UInt64(1) << UInt64(condition.offset)
                }
            }
        }

        @objc(validateAvatarData:declaredMediaType:maximumPixels:expectedWidth:expectedHeight:)
        // Objective-C XCTest invokes this explicit runtime selector.
        // swiftlint:disable:next unused_declaration
        static func validateAvatarData(
            _ data: Data,
            declaredMediaType: String,
            maximumPixels: Int,
            expectedWidth: Int,
            expectedHeight: Int
        ) -> Bool {
            guard let mediaType = ForgeAvatarMediaType(rawValue: declaredMediaType) else {
                return false
            }
            guard let image = try? ForgeAvatarImageDecoder().decode(
                ForgeAvatarPayload(data: data, mediaType: mediaType),
                maximumPixels: maximumPixels
            ) else {
                return false
            }
            return image.size == NSSize(width: expectedWidth, height: expectedHeight)
        }

        @objc static func avatarFallbackProof() -> UInt64 {
            let view = ForgeAvatarView(frame: NSRect(x: 0, y: 0, width: 42, height: 42))
            view.configure(displayName: "Ada Lovelace", avatarURL: URL(string: "file:///etc/passwd"))
            let conditions = [
                ForgeAvatarView.initials(for: "Ada Lovelace") == "AL",
                ForgeAvatarView.initials(for: "octocat") == "O",
                ForgeAvatarView.initials(for: "  ") == "?",
                view.initials == "AL",
                view.accessibilityLabel()?.contains("initials AL") == true,
            ]
            return conditions.enumerated().reduce(into: UInt64(0)) { proof, condition in
                if condition.element {
                    proof |= UInt64(1) << UInt64(condition.offset)
                }
            }
        }

        @objc(loaderProofWithCompletion:)
        // Objective-C XCTest invokes this explicit runtime selector.
        // swiftlint:disable:next unused_declaration
        static func loaderProof(completion: @escaping (UInt64) -> Void) {
            Task {
                completion(await makeLoaderProof())
            }
        }

        @objc(sidebarAttentionProofWithCompletion:)
        // Objective-C XCTest invokes this explicit runtime selector.
        // swiftlint:disable:next unused_declaration
        static func sidebarAttentionProof(completion: @escaping (UInt64) -> Void) {
            Task {
                completion(await makeSidebarAttentionProof())
            }
        }

        @objc(applicationStartupFailureProofWithCompletion:)
        // Objective-C XCTest invokes this explicit runtime selector.
        // swiftlint:disable:next unused_declaration
        static func applicationStartupFailureProof(completion: @escaping (UInt64) -> Void) {
            Task {
                completion(await makeApplicationStartupFailureProof())
            }
        }

        private static func makeApplicationStartupFailureProof() async -> UInt64 {
            let originalComposition = ApplicationComposition.shared
            let defaultsName = "GitXApplicationStartupFailureHarness-\(UUID().uuidString)"
            guard let defaults = UserDefaults(suiteName: defaultsName) else { return 0 }
            defaults.removePersistentDomain(forName: defaultsName)
            defer {
                ApplicationComposition.setSharedComposition(originalComposition)
                defaults.removePersistentDomain(forName: defaultsName)
            }
            let probe = HarnessStartupFailureProbe()
            let loader = ForgeApplicationServiceLoader {
                probe.recordInvocation()
                throw HarnessStartupFailure.expected
            }
            let composition = ApplicationComposition(
                userDefaults: defaults,
                forgeServices: loader,
                automaticallyStartsForgeServices: true
            )

            ApplicationComposition.setSharedComposition(composition)
            for _ in 0 ..< 1000 {
                await Task.yield()
                if probe.invocationCount != 0 {
                    break
                }
            }
            guard probe.invocationCount == 1 else { return 0 }
            await Task.yield()
            return 1
        }

        private static func makeSidebarAttentionProof() async -> UInt64 {
            let originalComposition = ApplicationComposition.shared
            let originalPollingPreset = ApplicationSettings.attentionPollingPreset
            ApplicationSettings.attentionPollingPreset = .manual
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("GitXSidebarAttentionHarness-\(UUID().uuidString)", isDirectory: true)
            let repositoryURL = root.appendingPathComponent("repository", isDirectory: true)
            let defaultsName = "GitXSidebarAttentionHarness-\(UUID().uuidString)"
            guard let defaults = UserDefaults(suiteName: defaultsName) else { return 0 }
            defaults.removePersistentDomain(forName: defaultsName)
            defer {
                ApplicationComposition.setSharedComposition(originalComposition)
                ApplicationSettings.attentionPollingPreset = originalPollingPreset
                defaults.removePersistentDomain(forName: defaultsName)
                try? FileManager.default.removeItem(at: root)
            }

            var sidebar: PBGitSidebarController?
            var services: ForgeApplicationServices?
            do {
                try FileManager.default.createDirectory(at: repositoryURL, withIntermediateDirectories: true)
                guard runGit(["init", "--quiet", "--initial-branch=main"], in: repositoryURL),
                      runGit(
                          ["remote", "add", "origin", "https://github.com/hbmartin/gitx.git"],
                          in: repositoryURL
                      )
                else {
                    return 0
                }

                let madeServices = try await ForgeApplicationServiceFactory.make(
                    forgeDirectory: root.appendingPathComponent("forge", isDirectory: true),
                    bindingCleaner: ForgeRepositoryBindingAccountCleaner(userDefaults: defaults),
                    keychain: HarnessForgeKeychain(),
                    cliRunner: HarnessForgeCLIRunner()
                )
                services = madeServices
                let forge = try ForgeIdentity(kind: .github, origin: ForgeOrigin(host: "github.com"))
                let accountID = try ForgeAccountID(forge: forge, value: "sidebar-attention-account")
                let account = try await madeServices.addAccountCoordinator.addPersonalAccessToken(
                    accountID: accountID,
                    login: "sidebar-user",
                    credentialID: ForgeCredentialID("sidebar-attention-pat"),
                    kind: .fineGrained,
                    token: Data("sidebar-token".utf8),
                    expiresAt: nil
                )
                let alternateAccountID = try ForgeAccountID(
                    forge: forge,
                    value: "sidebar-attention-alternate-account"
                )
                let alternateAccount = try await madeServices.addAccountCoordinator.addPersonalAccessToken(
                    accountID: alternateAccountID,
                    login: "zz-alternate-user",
                    credentialID: ForgeCredentialID("sidebar-attention-alternate-pat"),
                    kind: .fineGrained,
                    token: Data("sidebar-alternate-token".utf8),
                    expiresAt: nil
                )
                ApplicationComposition.setSharedComposition(ApplicationComposition(
                    userDefaults: defaults,
                    forgeServices: ForgeApplicationServiceLoader { madeServices },
                    automaticallyStartsForgeServices: false
                ))

                let repository = try PBGitRepository(url: repositoryURL)
                let identity = try ForgeRepositoryIdentity(
                    forge: forge,
                    owner: "hbmartin",
                    name: "gitx"
                )
                let binding = try ForgeRepositoryBinding(
                    localRemoteName: "origin",
                    primaryRepository: identity,
                    preferredAccount: accountID
                )
                ApplicationComposition.shared.repositoryViewState(for: repository)
                    .forgeRepositoryBinding = binding
                let sessionBehavior = try await exerciseAttentionSession(
                    account: account,
                    repositoryIdentity: identity,
                    repositoryObject: repository,
                    services: madeServices
                )
                let unboundCollaborationBehavior = try exerciseUnboundCollaboration(
                    at: root.appendingPathComponent("unbound", isDirectory: true),
                    destinationRepository: identity
                )
                let windowController = PBGitWindowController()
                windowController.repository = repository
                let boundCollaborationProof = await exerciseBoundCollaboration(
                    repository: repository,
                    windowController: windowController,
                    identity: identity,
                    account: account,
                    alternateAccount: alternateAccount,
                    services: madeServices,
                    binding: binding
                )
                guard let madeSidebar = PBGitSidebarController(
                    repository: repository,
                    superController: windowController
                ) else {
                    await madeServices.refreshCoordinator?.invalidate()
                    await madeServices.database?.close()
                    return 0
                }
                sidebar = madeSidebar
                _ = madeSidebar.view

                let authenticated = await waitForSidebarItem(titled: "Attention", in: madeSidebar)
                let roots = madeSidebar.items.compactMap { $0 as? PBSourceViewItem }
                guard authenticated,
                      let attention = sidebarItem(titled: "Attention", in: roots),
                      let pullRequests = sidebarItem(titled: "Pull Requests", in: roots),
                      let outline = madeSidebar.sourceView,
                      let tableColumn = outline.tableColumns.first
                else {
                    madeSidebar.closeView()
                    await madeServices.refreshCoordinator?.invalidate()
                    await madeServices.database?.close()
                    return 0
                }

                NotificationCenter.default.post(
                    name: .repositoryAttentionUnseenDidChange,
                    object: repository,
                    userInfo: [RepositoryAttentionNotificationKey.count: 3]
                )
                let attentionCell = madeSidebar.outlineView(
                    outline,
                    viewFor: tableColumn,
                    item: attention
                ) as? NSTableCellView
                let attentionBadge = attentionCell?.subviews.first {
                    $0.identifier?.rawValue == "PBForgeAttentionBadgeIdentifier"
                } as? NSTextField
                let pullRequestCell = madeSidebar.outlineView(
                    outline,
                    viewFor: tableColumn,
                    item: pullRequests
                ) as? NSTableCellView
                let pullRequestBadge = pullRequestCell?.subviews.first {
                    $0.identifier?.rawValue == "PBForgeAttentionBadgeIdentifier"
                } as? NSTextField

                NotificationCenter.default.post(
                    name: .repositoryAttentionUnseenDidChange,
                    object: repository,
                    userInfo: [RepositoryAttentionNotificationKey.count: -4]
                )
                let emptyCell = madeSidebar.outlineView(
                    outline,
                    viewFor: tableColumn,
                    item: attention
                ) as? NSTableCellView
                let emptyBadge = emptyCell?.subviews.first {
                    $0.identifier?.rawValue == "PBForgeAttentionBadgeIdentifier"
                } as? NSTextField
                let conditions = [
                    authenticated,
                    attention.icon != nil,
                    attentionCell?.accessibilityIdentifier() == "RepositoryForgeSidebarItem",
                    attentionCell?.accessibilityLabel() == "Attention, 3 unseen Attention items",
                    attentionBadge?.stringValue == "3",
                    attentionBadge?.isHidden == false,
                    attentionBadge?.accessibilityLabel() == "Attention, 3 unseen Attention items",
                    pullRequestBadge?.isHidden == true,
                    emptyBadge?.isHidden == true,
                    emptyCell?.accessibilityLabel() == "Attention, No unseen Attention items",
                    sessionBehavior,
                    unboundCollaborationBehavior,
                    boundCollaborationProof.baseline,
                    boundCollaborationProof.collaborationCooldown,
                    boundCollaborationProof.toolbarCooldown,
                ]
                let proof = conditions.enumerated().reduce(into: UInt64(0)) { proof, condition in
                    if condition.element {
                        proof |= UInt64(1) << UInt64(condition.offset)
                    }
                }
                madeSidebar.closeView()
                await madeServices.refreshCoordinator?.invalidate()
                await madeServices.database?.close()
                return proof
            } catch {
                sidebar?.closeView()
                await services?.refreshCoordinator?.invalidate()
                await services?.database?.close()
                return 0
            }
        }

        private static func makeLoaderProof() async -> UInt64 {
            guard let cachedURL = try? ForgeAvatarURL("https://avatars.githubusercontent.com/u/71"),
                  let fetchedURL = try? ForgeAvatarURL("https://avatars.githubusercontent.com/u/72"),
                  let cancelledURL = try? ForgeAvatarURL("https://avatars.githubusercontent.com/u/73")
            else {
                return 0
            }
            let cachedPayload = ForgeAvatarPayload(data: Data([7, 1]), mediaType: .jpeg)
            let fetchedPayload = ForgeAvatarPayload(data: Data([7, 2]), mediaType: .png)
            let backing = HarnessBackingStore(entries: [cachedURL: cachedPayload])
            let transport = HarnessTransport(payload: fetchedPayload)
            let loader = ForgeAvatarLoader(
                transport: transport,
                backingStore: backing,
                cacheByteLimit: 3
            )

            let fromBacking = try? await loader.load(cachedURL)
            let fromNetwork = try? await loader.load(fetchedURL)
            let fromMemory = try? await loader.load(fetchedURL)
            let bounded = await loader.statistics()
            let fetchCount = await transport.fetchCount
            let stored = await backing.storedPayload(for: fetchedURL)

            let controlled = HarnessControlledTransport(payload: fetchedPayload)
            let coalescingLoader = ForgeAvatarLoader(transport: controlled)
            let first = Task { try await coalescingLoader.load(cancelledURL) }
            await controlled.waitUntilStarted()
            let second = Task { try await coalescingLoader.load(cancelledURL) }
            let joined = await waitForWaiters(2, in: coalescingLoader)
            first.cancel()
            let firstCancelled: Bool
            do {
                _ = try await first.value
                firstCancelled = false
            } catch is CancellationError {
                firstCancelled = true
            } catch {
                firstCancelled = false
            }
            await controlled.complete()
            let secondSucceeded = (try? await second.value) == fetchedPayload
            let sharedFetchCount = await controlled.fetchCount

            await loader.setLoadingEnabled(false)
            let disabled: Bool
            do {
                _ = try await loader.load(cachedURL)
                disabled = false
            } catch ForgeAvatarLoadingError.disabled {
                disabled = true
            } catch {
                disabled = false
            }
            let purges = await backing.purgeCount
            await loader.setLoadingEnabled(true)
            await loader.purge()
            let sqliteBackingSucceeded = await sqliteBackingProof(avatarURL: cachedURL)
            let networkTransportSucceeded = await networkTransportProof()
            let offMainDecodeSucceeded = await offMainDecodeProof()

            let conditions = [
                fromBacking == cachedPayload,
                fromNetwork == fetchedPayload,
                fromMemory == fetchedPayload,
                fetchCount == 1,
                stored == fetchedPayload,
                bounded.cachedItems == 1,
                bounded.cachedBytes == 2,
                joined,
                firstCancelled,
                secondSucceeded,
                sharedFetchCount == 1,
                disabled,
                purges == 1,
                sqliteBackingSucceeded,
                networkTransportSucceeded,
                offMainDecodeSucceeded,
            ]
            return conditions.enumerated().reduce(into: UInt64(0)) { proof, condition in
                if condition.element {
                    proof |= UInt64(1) << UInt64(condition.offset)
                }
            }
        }

        private static func offMainDecodeProof() async -> Bool {
            guard let bitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: 4,
                pixelsHigh: 3,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            ),
                let data = bitmap.representation(using: .png, properties: [:]),
                let decoded = try? await ForgeAvatarImageDecoder().decodeOffMain(
                    ForgeAvatarPayload(data: data, mediaType: .png),
                    maximumPixels: 12
                )
            else {
                return false
            }
            return !decoded.wasDecodedOnMainThread
                && decoded.size == NSSize(width: 4, height: 3)
                && decoded.makeImage().representations.count == 1
        }

        private static func networkTransportProof() async -> Bool {
            let configuration = ForgeAvatarNetworkTransport.secureConfiguration()
            configuration.protocolClasses = [HarnessAvatarURLProtocol.self]
            let transport = ForgeAvatarNetworkTransport(configuration: configuration)
            guard let successURL = try? ForgeAvatarURL(
                "https://avatars.githubusercontent.com/u/81?result=success"
            ),
                let plainURL = try? ForgeAvatarURL(
                    "https://avatars.githubusercontent.com/u/82?result=plain"
                ),
                let failureURL = try? ForgeAvatarURL(
                    "https://avatars.githubusercontent.com/u/83?result=failure"
                )
            else {
                return false
            }

            let payload = try? await transport.fetch(successURL)
            let rejectedPlainResponse: Bool
            do {
                _ = try await transport.fetch(plainURL)
                rejectedPlainResponse = false
            } catch ForgeAvatarLoadingError.invalidResponse {
                rejectedPlainResponse = true
            } catch {
                rejectedPlainResponse = false
            }
            let rejectedStatus: Bool
            do {
                _ = try await transport.fetch(failureURL)
                rejectedStatus = false
            } catch ForgeAvatarPolicyError.unsuccessfulResponse {
                rejectedStatus = true
            } catch {
                rejectedStatus = false
            }
            return payload?.mediaType == .png
                && payload?.data.count == HarnessAvatarURLProtocol.payloadByteCount
                && rejectedPlainResponse
                && rejectedStatus
        }

        private static func sqliteBackingProof(avatarURL: ForgeAvatarURL) async -> Bool {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("GitXAvatarHarness-\(UUID().uuidString)", isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let store = try ForgeSQLiteStore(configuration: ForgeSQLiteConfiguration(
                    databaseURL: directory.appendingPathComponent("forge.sqlite3"),
                    recoveryDirectoryURL: directory.appendingPathComponent("recovery", isDirectory: true)
                ))
                let backing = ForgeSQLiteAvatarBackingStore(
                    store: store,
                    clock: { Date(timeIntervalSince1970: 1_700_000_000) }
                )
                var roundTrips = true
                for mediaType in ForgeAvatarMediaType.allCases {
                    let payload = ForgeAvatarPayload(
                        data: Data([8, UInt8(mediaType.rawValue.count)]),
                        mediaType: mediaType
                    )
                    try await backing.store(payload, for: avatarURL, owners: [.anonymous])
                    let roundTripPayload = try await backing.payload(for: avatarURL, owner: .anonymous)
                    roundTrips = roundTrips && roundTripPayload == payload
                }
                try await backing.purge()
                let wasPurged = try await backing.payload(for: avatarURL, owner: .anonymous) == nil
                await store.close()
                try? FileManager.default.removeItem(at: directory)
                return roundTrips && wasPurged
            } catch {
                try? FileManager.default.removeItem(at: directory)
                return false
            }
        }

        private static func waitForWaiters(_ count: Int, in loader: ForgeAvatarLoader) async -> Bool {
            for _ in 0 ..< 1000 {
                if await loader.statistics().activeWaiters == count {
                    return true
                }
                await Task.yield()
            }
            return false
        }

        private static func waitForSidebarItem(
            titled title: String,
            in sidebar: PBGitSidebarController
        ) async -> Bool {
            let deadline = ContinuousClock.now.advanced(by: .seconds(10))
            while ContinuousClock.now < deadline {
                let roots = sidebar.items.compactMap { $0 as? PBSourceViewItem }
                if sidebarItem(titled: title, in: roots) != nil {
                    return true
                }
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
            return false
        }

        private static func exerciseAttentionSession(
            account: ForgeAccount,
            repositoryIdentity: ForgeRepositoryIdentity,
            repositoryObject: PBGitRepository,
            services: ForgeApplicationServices
        ) async throws -> Bool {
            guard let database = services.database else { return false }
            let persistence = ForgeSQLiteAttentionPersistence(store: database)
            let watchKey = try ForgeWatchedRepositoryKey(
                accountID: account.id,
                repository: repositoryIdentity
            )
            let eventDate = Date(timeIntervalSince1970: 1_700_000_000)
            let issue = try ForgeIssueSummary(
                repository: repositoryIdentity,
                number: ForgeItemNumber(88),
                state: .open,
                title: "App-hosted Attention session",
                author: .unavailable(.notRequested),
                createdAt: eventDate,
                updatedAt: eventDate,
                labels: .available([])
            )
            let itemID = try ForgeAttentionItemID(
                accountID: account.id,
                repository: repositoryIdentity,
                kind: .assignment,
                subjectID: ForgeAttentionSubjectID("sidebar-attention-session")
            )
            let item = try ForgeAttentionItem(
                id: itemID,
                destination: .issue(repositoryIdentity, issue.number),
                becameActionableAt: eventDate
            )
            let record = try ForgeAttentionRecord(
                item: item,
                sourceIdentifier: ForgeAttentionSubjectID("sidebar-attention-source"),
                sourceOccurredAt: eventDate
            )
            let entry = try ForgeAttentionInboxEntry(record: record, subject: .issue(issue))
            let watchedRepository = ForgeWatchedRepository(
                key: watchKey,
                addedAt: eventDate,
                source: .repositoryOpened
            )
            try await persistence.persist(ForgeAttentionReconciliation(
                watchedRepository: watchedRepository,
                records: [record],
                entries: [entry],
                newlyActionable: [item],
                resolved: [],
                fetchedAt: eventDate,
                completeness: .complete
            ))

            let originalPollingPreset = ApplicationSettings.attentionPollingPreset
            ApplicationSettings.attentionPollingPreset = .manual
            defer { ApplicationSettings.attentionPollingPreset = originalPollingPreset }
            let enrollmentIdentity = try ForgeRepositoryIdentity(
                forge: repositoryIdentity.forge,
                owner: repositoryIdentity.owner,
                name: "gitx-attention-enrollment"
            )
            let enrollmentKey = try ForgeWatchedRepositoryKey(
                accountID: account.id,
                repository: enrollmentIdentity
            )
            let enrollmentSession = try RepositoryAttentionSession(
                account: account,
                repositoryIdentity: enrollmentIdentity,
                repositoryObject: repositoryObject,
                services: services
            )
            enrollmentSession.start()
            var enrolledOpenedRepository = false
            for _ in 0 ..< 100 where !enrolledOpenedRepository {
                enrolledOpenedRepository = try await persistence.watchedRepositories(accountID: account.id)
                    .contains { $0.key == enrollmentKey }
                if !enrolledOpenedRepository {
                    try await Task.sleep(nanoseconds: 10_000_000)
                }
            }
            await enrollmentSession.waitForCurrentPollingCycleForProductProof()
            enrollmentSession.stop()
            let session = try RepositoryAttentionSession(
                account: account,
                repositoryIdentity: repositoryIdentity,
                repositoryObject: repositoryObject,
                services: services
            )
            session.start()
            session.start()
            defer { session.stop() }
            NotificationCenter.default.post(name: .forgeAttentionPreferencesDidChange, object: nil)
            let unseen = ForgeAttentionViewState(
                scope: .currentRepository,
                visibility: .unseenOnly,
                sortOrder: .newestFirst
            )
            let active = ForgeAttentionViewState(
                scope: .all,
                visibility: .active,
                sortOrder: .oldestFirst
            )
            let initial = try await session.entries(state: unseen)
            NotificationCenter.default.post(
                name: .forgeAttentionAlertAction,
                object: nil,
                userInfo: [
                    RepositoryAttentionNotificationKey.itemID: itemID,
                    RepositoryAttentionNotificationKey.action: ForgeAttentionAlertAction.markSeen,
                ]
            )
            var alertMarkedSeen = false
            for _ in 0 ..< 100 where !alertMarkedSeen {
                alertMarkedSeen = try await session.entries(state: unseen).isEmpty
                if !alertMarkedSeen {
                    try await Task.sleep(nanoseconds: 10_000_000)
                }
            }
            try await session.markUnseen(itemID)
            var alertOpenedItem: ForgeAttentionItemID?
            session.onOpenAttentionItem = { alertOpenedItem = $0 }
            NotificationCenter.default.post(
                name: .forgeAttentionAlertAction,
                object: nil,
                userInfo: [
                    RepositoryAttentionNotificationKey.itemID: itemID,
                    RepositoryAttentionNotificationKey.action: ForgeAttentionAlertAction.open,
                ]
            )
            for _ in 0 ..< 100 where alertOpenedItem == nil {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            try await session.markUnseen(itemID)
            try await session.markOpen(itemID)
            let afterOpen = try await session.entries(state: unseen)
            let activeAfterOpen = try await session.entries(state: active)
            try await session.markUnseen(itemID)
            let afterMarkUnseen = try await session.entries(state: unseen)
            try await session.markAllSeen(state: unseen)
            let afterCurrentMarkAll = try await session.entries(state: unseen)
            try await session.markUnseen(itemID)
            try await session.markAllSeen(state: ForgeAttentionViewState(
                scope: .all,
                visibility: .unseenOnly,
                sortOrder: .newestFirst
            ))
            let afterAccountMarkAll = try await session.entries(state: unseen)
            _ = try session.makeReadService(for: repositoryIdentity)
            try await services.accountStore.removeAccount(account.id)
            await session.refreshNow()
            let refreshFailureWasActionable = session.lastRefreshErrorDescription != nil
            _ = try await services.accountStore.addPersonalAccessToken(
                accountID: account.id,
                login: account.login,
                credentialID: account.currentCredential.reference.credentialID,
                kind: .fineGrained,
                token: Data("sidebar-token".utf8),
                expiresAt: account.currentCredential.expiresAt
            )
            session.stop()
            session.stop()
            return initial.map(\.record.item.id) == [itemID]
                && enrolledOpenedRepository
                && alertMarkedSeen
                && alertOpenedItem == itemID
                && afterOpen.isEmpty
                && activeAfterOpen.map(\.record.item.id) == [itemID]
                && afterMarkUnseen.map(\.record.item.id) == [itemID]
                && afterCurrentMarkAll.isEmpty
                && afterAccountMarkAll.isEmpty
                && refreshFailureWasActionable
        }

        private static func exerciseUnboundCollaboration(
            at repositoryURL: URL,
            destinationRepository: ForgeRepositoryIdentity
        ) throws -> Bool {
            try FileManager.default.createDirectory(at: repositoryURL, withIntermediateDirectories: true)
            guard runGit(["init", "--quiet", "--initial-branch=main"], in: repositoryURL) else {
                return false
            }
            let repository = try PBGitRepository(url: repositoryURL)
            let windowController = PBGitWindowController()
            windowController.repository = repository
            guard let controller = RepositoryForgeCollaborationController(
                repository: repository,
                superController: windowController
            ) else {
                return false
            }
            let view = controller.view
            controller.prepare()
            controller.prepare()
            controller.updateView()
            controller.show(.issues)
            controller.refresh(nil)
            controller.show(.attention)
            controller.refresh(nil)
            let nativeOpen = try controller.openNative(
                .issue(destinationRepository, ForgeItemNumber(99))
            )
            _ = controller.perform(NSSelectorFromString("continuePublicly:"), with: nil)
            _ = controller.perform(NSSelectorFromString("openBoundRepositoryInBrowser:"), with: nil)
            NotificationCenter.default.post(
                name: .forgeAccountsDidChange,
                object: nil
            )
            controller.repositoryBindingDidChange()
            let gateway = descendant(identifier: "ForgeCollaborationGateway", in: view)
            let status = descendant(identifier: "ForgeCollaborationAccountStatus", in: view)
                as? NSTextField
            let firstResponder = controller.firstResponder()
            let conditions = [
                view.accessibilityIdentifier() == "RepositoryForgeCollaboration",
                gateway != nil,
                status?.stringValue == "Resolving repository access…",
                firstResponder != nil,
                !nativeOpen,
            ]
            controller.closeView()
            return conditions.allSatisfy { $0 }
        }

        private static func exerciseBoundCollaboration(
            repository: PBGitRepository,
            windowController: PBGitWindowController,
            identity: ForgeRepositoryIdentity,
            account: ForgeAccount,
            alternateAccount: ForgeAccount,
            services: ForgeApplicationServices,
            binding: ForgeRepositoryBinding
        ) async -> (baseline: Bool, collaborationCooldown: Bool, toolbarCooldown: Bool) {
            guard let controller = RepositoryForgeCollaborationController(
                repository: repository,
                superController: windowController
            ) else {
                return (false, false, false)
            }
            let view = controller.view
            controller.prepare()
            controller.updateView()
            guard await waitForCollaborationStatus("Using @sidebar-user", in: view) else {
                controller.closeView()
                return (false, false, false)
            }

            let authenticated = controller.currentAccountLogin == account.login && controller.includesAttention
            let sidebarRepositories = controller.sidebarRepositories
            controller.show(.pullRequests)
            controller.refresh(nil)
            let openedPullRequest = (try? controller.openNative(.pullRequest(identity, ForgeItemNumber(71)))) == true
            controller.show(.issues)
            controller.refresh(nil)
            let openedIssue = (try? controller.openNative(.issue(identity, ForgeItemNumber(72)))) == true
            let rejectedCommit = controller.openNative(.commit(
                identity,
                try! ForgeCommitID("0123456789012345678901234567890123456789")
            ))
            controller.show(.attention)
            controller.refresh(nil)
            let mountedAttention = await waitForDescendant(identifier: "ForgeAttentionTable", in: view)

            let settings = ApplicationComposition.shared.repositoryViewState(for: repository)
            let choiceBinding = try? ForgeRepositoryBinding(
                localRemoteName: binding.localRemoteName,
                primaryRepository: identity
            )
            settings.forgeRepositoryBinding = choiceBinding
            controller.repositoryBindingDidChange()
            let choice = await waitForCollaborationStatus("Account choice required", in: view)
            let accountPopup = descendant(identifier: "ForgeCollaborationAccount", in: view) as? NSPopUpButton
            accountPopup?.selectItem(at: 0)
            if let accountPopup, let action = accountPopup.action {
                _ = NSApp.sendAction(action, to: accountPopup.target, from: accountPopup)
            }
            let selectedAccount = await waitForCollaborationStatus("Using @sidebar-user", in: view)

            settings.forgeRepositoryBinding = choiceBinding
            controller.repositoryBindingDidChange()
            _ = await waitForCollaborationStatus("Account choice required", in: view)
            let publicButton = descendant(
                identifier: "ForgeCollaborationContinuePublicly",
                in: view
            ) as? NSButton
            publicButton?.performClick(nil)
            let publicAccess = await waitForCollaborationStatus(
                "Public read-only — no polling or mutations",
                in: view
            )
            controller.show(.attention)
            let anonymousAttentionGateway = descendant(identifier: "ForgeCollaborationGateway", in: view) != nil
            controller.show(.issues)
            controller.refresh(nil)

            let gitLabForge = try? ForgeIdentity(kind: .gitLab, origin: ForgeOrigin(host: "gitlab.com"))
            let gitLabIdentity = try? gitLabForge.map {
                try ForgeRepositoryIdentity(forge: $0, owner: "example", name: "project")
            }
            if let gitLabIdentity {
                settings.forgeRepositoryBinding = try? ForgeRepositoryBinding(
                    localRemoteName: "origin",
                    primaryRepository: gitLabIdentity
                )
                controller.repositoryBindingDidChange()
            }
            let browserOnly = await waitForCollaborationStatus("Browser links only", in: view)
            let browserButton = descendant(
                identifier: "ForgeCollaborationOpenRepositoryInBrowser",
                in: view
            ) != nil

            settings.forgeRepositoryBinding = binding
            controller.repositoryBindingDidChange()
            _ = await waitForCollaborationStatus("Using @sidebar-user", in: view)
            NotificationCenter.default.post(name: .forgeAccountsDidChange, object: nil)
            _ = await waitForCollaborationStatus("Using @sidebar-user", in: view)
            let cooldownProof = await exerciseCredentialCooldownAccountRebinding(
                controller: controller,
                view: view,
                repository: repository,
                windowController: windowController,
                services: services,
                account: account,
                alternateAccount: alternateAccount,
                binding: binding
            )
            controller.closeView()
            let baseline = authenticated &&
                !sidebarRepositories.isEmpty &&
                openedPullRequest &&
                openedIssue &&
                !rejectedCommit &&
                mountedAttention &&
                choice &&
                selectedAccount &&
                publicAccess &&
                anonymousAttentionGateway &&
                browserOnly &&
                browserButton
            return (baseline, cooldownProof.collaboration, cooldownProof.toolbar)
        }

        private static func exerciseCredentialCooldownAccountRebinding(
            controller: RepositoryForgeCollaborationController,
            view: NSView,
            repository: PBGitRepository,
            windowController: PBGitWindowController,
            services: ForgeApplicationServices,
            account: ForgeAccount,
            alternateAccount: ForgeAccount,
            binding: ForgeRepositoryBinding
        ) async -> (collaboration: Bool, toolbar: Bool) {
            guard let collaborationPopup = descendant(
                identifier: "ForgeCollaborationAccount",
                in: view
            ) as? NSPopUpButton else {
                return (false, false)
            }
            let settings = ApplicationComposition.shared.repositoryViewState(for: repository)
            let toolbarController = RepositoryToolbarController(windowController: windowController)
            let toolbar = NSToolbar(identifier: "GitX.Repository.CredentialCooldownProof")
            guard let accountItem = toolbarController.toolbar(
                toolbar,
                itemForItemIdentifier: NSToolbarItem.Identifier("GitX.Toolbar.ForgeAccount"),
                willBeInsertedIntoToolbar: true
            ),
                let accountStack = accountItem.view as? NSStackView,
                let toolbarPopup = accountStack.arrangedSubviews.compactMap({ $0 as? NSPopUpButton }).first(where: {
                    $0.accessibilityIdentifier() == "GitX.Toolbar.ForgeAccount"
                })
            else {
                return (false, false)
            }

            let notificationCounter = HarnessNotificationCounter()
            let notificationObserver = NotificationCenter.default.addObserver(
                forName: .forgeAccountsDidChange,
                object: repository,
                queue: nil
            ) { _ in
                notificationCounter.increment()
            }
            defer { NotificationCenter.default.removeObserver(notificationObserver) }

            controller.repositoryBindingDidChange()
            let toolbarReceivedAccounts = await waitForCondition {
                toolbarPopup.menu?.items.contains(where: {
                    $0.accessibilityIdentifier()
                        == "GitX.Toolbar.ForgeAccount.Choice.\(alternateAccount.id.value)"
                }) == true
            }
            guard toolbarReceivedAccounts else { return (false, false) }

            func collaborationSelectionIsRestored() -> Bool {
                collaborationPopup.selectedItem?.representedObject as? String == account.id.value
            }

            func toolbarSelectionIsRestored() -> Bool {
                let currentIdentifier = "GitX.Toolbar.ForgeAccount.Choice.\(account.id.value)"
                let alternateIdentifier = "GitX.Toolbar.ForgeAccount.Choice.\(alternateAccount.id.value)"
                return toolbarPopup.menu?.items.first(where: {
                    $0.accessibilityIdentifier() == currentIdentifier
                })?.state == .on && toolbarPopup.menu?.items.first(where: {
                    $0.accessibilityIdentifier() == alternateIdentifier
                })?.state == .off
            }

            func forceCollaborationSelection() async -> Bool {
                guard let destinationIndex = collaborationPopup.itemArray.firstIndex(where: {
                    $0.representedObject as? String == alternateAccount.id.value
                }), let action = collaborationPopup.action else {
                    return false
                }
                collaborationPopup.selectItem(at: destinationIndex)
                let delivered = NSApp.sendAction(
                    action,
                    to: collaborationPopup.target,
                    from: collaborationPopup
                )
                await controller.waitForAccountSelectionForProductProof()
                return delivered &&
                    settings.forgeRepositoryBinding == binding &&
                    notificationCounter.value == 0 &&
                    collaborationSelectionIsRestored()
            }

            func forceToolbarSelection() async -> Bool {
                let identifier = "GitX.Toolbar.ForgeAccount.Choice.\(alternateAccount.id.value)"
                guard let item = toolbarPopup.menu?.items.first(where: {
                    $0.accessibilityIdentifier() == identifier
                }), !item.isEnabled, let action = item.action else {
                    return false
                }
                let delivered = NSApp.sendAction(action, to: item.target, from: item)
                await toolbarController.waitForForgeAccountSelectionForProductProof()
                return delivered &&
                    settings.forgeRepositoryBinding == binding &&
                    notificationCounter.value == 0 &&
                    toolbarSelectionIsRestored()
            }

            let credential = account.currentCredential.reference
            let sessionGate = services.githubMutationState.sessionGate
            let waitingDeadline = Date().addingTimeInterval(60)
            await sessionGate.recordCooldown(for: credential, until: waitingDeadline)
            let waitingHelp = "Account changes are paused until GitHub’s rate-limit window ends."
            let waitingControlsDisabled = await waitForCondition {
                !collaborationPopup.isEnabled &&
                    collaborationPopup.accessibilityHelp() == waitingHelp &&
                    !toolbarPopup.isEnabled &&
                    toolbarPopup.accessibilityHelp() == waitingHelp
            }
            let waitingState = await services.credentialCooldowns.retainedState(
                for: credential,
                at: Date()
            )
            let collaborationWaitingRefused = await forceCollaborationSelection()
            let toolbarWaitingRefused = await forceToolbarSelection()

            await sessionGate.recordCooldown(for: credential, until: nil)
            let elapsedDeadline = Date().addingTimeInterval(-60)
            await sessionGate.recordCooldown(for: credential, until: elapsedDeadline)
            let retryPendingHelp = "Account changes are paused until a successful GitHub retry completes."
            let retryPendingControlsDisabled = await waitForCondition {
                !collaborationPopup.isEnabled &&
                    collaborationPopup.accessibilityHelp() == retryPendingHelp &&
                    !toolbarPopup.isEnabled &&
                    toolbarPopup.accessibilityHelp() == retryPendingHelp
            }
            let retryPendingState = await services.credentialCooldowns.retainedState(
                for: credential,
                at: Date()
            )
            let collaborationRetryPendingRefused = await forceCollaborationSelection()
            let toolbarRetryPendingRefused = await forceToolbarSelection()

            var successfulRetryClearedState = false
            if case let .allowed(permit) = await sessionGate.admitRequest(for: credential, at: Date()) {
                await sessionGate.recordSuccessfulRequest(permit)
                let clearedState = await services.credentialCooldowns.retainedState(
                    for: credential,
                    at: Date()
                )
                successfulRetryClearedState = clearedState == .none
            }
            if !successfulRetryClearedState {
                await sessionGate.recordCooldown(for: credential, until: nil)
            }
            let controlsReenabled = await waitForCondition {
                collaborationPopup.isEnabled &&
                    toolbarPopup.isEnabled &&
                    collaborationSelectionIsRestored() &&
                    toolbarSelectionIsRestored()
            }

            let waitingStateMatched = waitingState == .waiting(until: waitingDeadline)
            let retryPendingStateMatched = retryPendingState == .retryPending(deadline: elapsedDeadline)
            let sharedStateBehavior = waitingControlsDisabled &&
                retryPendingControlsDisabled &&
                waitingStateMatched &&
                retryPendingStateMatched &&
                successfulRetryClearedState &&
                controlsReenabled &&
                settings.forgeRepositoryBinding == binding &&
                notificationCounter.value == 0
            return (
                sharedStateBehavior && collaborationWaitingRefused && collaborationRetryPendingRefused,
                sharedStateBehavior && toolbarWaitingRefused && toolbarRetryPendingRefused
            )
        }

        private static func waitForCollaborationStatus(_ value: String, in view: NSView) async -> Bool {
            let deadline = ContinuousClock.now.advanced(by: .seconds(10))
            while ContinuousClock.now < deadline {
                let status = descendant(
                    identifier: "ForgeCollaborationAccountStatus",
                    in: view
                ) as? NSTextField
                if status?.stringValue == value {
                    return true
                }
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
            return false
        }

        private static func waitForCondition(
            _ condition: @escaping @MainActor () -> Bool
        ) async -> Bool {
            let deadline = ContinuousClock.now.advanced(by: .seconds(10))
            while ContinuousClock.now < deadline {
                if condition() {
                    return true
                }
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
            return false
        }

        private static func waitForDescendant(identifier: String, in view: NSView) async -> Bool {
            let deadline = ContinuousClock.now.advanced(by: .seconds(10))
            while ContinuousClock.now < deadline {
                if descendant(identifier: identifier, in: view) != nil {
                    return true
                }
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
            return false
        }

        private static func descendant(identifier: String, in root: NSView) -> NSView? {
            if root.identifier?.rawValue == identifier || root.accessibilityIdentifier() == identifier {
                return root
            }
            for subview in root.subviews {
                if let match = descendant(identifier: identifier, in: subview) {
                    return match
                }
            }
            return nil
        }

        private static func sidebarItem(
            titled title: String,
            in roots: [PBSourceViewItem]
        ) -> PBSourceViewItem? {
            for item in roots {
                if item.title == title {
                    return item
                }
                if let match = sidebarItem(titled: title, in: item.sortedChildren) {
                    return match
                }
            }
            return nil
        }

        private static func runGit(_ arguments: [String], in directory: URL) -> Bool {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["-C", directory.path] + arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                process.waitUntilExit()
                return process.terminationStatus == 0
            } catch {
                return false
            }
        }

        private static func navigationDocument() -> ForgeMarkdownDocument {
            guard let origin = try? ForgeOrigin(host: "github.com"),
                  let repository = try? ForgeRepositoryIdentity(
                      forge: ForgeIdentity(kind: .github, origin: origin),
                      owner: "example",
                      name: "repo"
                  ),
                  let branch = try? ForgeRefName("main")
            else {
                return ForgeMarkdownDocument(blocks: [])
            }
            let context = ForgeMarkdownContext(
                repository: repository,
                location: .repository(defaultBranch: .branch(branch))
            )
            return ForgeMarkdownSanitizer().sanitize(
                "# Details\n![secret](file:///etc/passwd) " +
                    "[PR](https://github.com/example/repo/pull/7) [top](#details)",
                context: context
            )
        }

        private static func cell(_ text: String) -> ForgeMarkdownTableCell {
            ForgeMarkdownTableCell(columnSpan: 1, rowSpan: 1, content: [.text(text)])
        }

        private static func exerciseBrowserMenu(in view: ForgeMarkdownNativeView) -> Bool {
            guard let layoutManager = view.textView.layoutManager,
                  let textContainer = view.textView.textContainer
            else {
                return false
            }
            layoutManager.ensureLayout(for: textContainer)
            let characterRange = (view.textView.string as NSString).range(of: "PR")
            guard characterRange.location != NSNotFound else { return false }
            let glyphRange = layoutManager.glyphRange(forCharacterRange: characterRange, actualCharacterRange: nil)
            let glyphRect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
            let textPoint = NSPoint(
                x: view.textView.textContainerOrigin.x + glyphRect.midX,
                y: view.textView.textContainerOrigin.y + glyphRect.midY
            )
            let windowPoint = view.textView.convert(textPoint, to: nil)
            guard let event = NSEvent.mouseEvent(
                with: .rightMouseDown,
                location: windowPoint,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: view.window?.windowNumber ?? 0,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: 1
            ),
                let item = view.markdownMenu(for: event, fallback: NSMenu())?
                .item(withTitle: "Open in Browser"),
                let action = item.action
            else {
                return false
            }
            return NSApp.sendAction(action, to: item.target, from: item)
        }

        private actor HarnessTransport: ForgeAvatarTransport {
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

        private actor HarnessBackingStore: ForgeAvatarBackingStore {
            private var entries: [ForgeAvatarURL: ForgeAvatarPayload]
            private(set) var purgeCount = 0

            init(entries: [ForgeAvatarURL: ForgeAvatarPayload]) {
                self.entries = entries
            }

            func payload(
                for avatarURL: ForgeAvatarURL,
                owner _: ForgeAvatarCacheOwner
            ) async throws -> ForgeAvatarPayload? {
                entries[avatarURL]
            }

            func store(
                _ payload: ForgeAvatarPayload,
                for avatarURL: ForgeAvatarURL,
                owners _: Set<ForgeAvatarCacheOwner>
            ) async throws {
                entries[avatarURL] = payload
            }

            func associate(_: ForgeAvatarCacheOwner, with _: ForgeAvatarURL) async throws {}

            func purge() async throws {
                purgeCount += 1
                entries.removeAll()
            }

            func storedPayload(for avatarURL: ForgeAvatarURL) -> ForgeAvatarPayload? {
                entries[avatarURL]
            }
        }

        private actor HarnessControlledTransport: ForgeAvatarTransport {
            let payload: ForgeAvatarPayload
            private(set) var fetchCount = 0
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

            private func cancel() {
                continuation?.resume(throwing: CancellationError())
                continuation = nil
            }
        }

        // swift6-safety-justification: The lock serializes the harness's in-memory credential state.
        private final nonisolated class HarnessForgeKeychain: ForgeCredentialKeychain, @unchecked Sendable {
            private let lock = NSLock()
            private var storage: [String: Data] = [:]

            func data(for accountKey: String) throws -> Data? {
                lock.lock()
                defer { lock.unlock() }
                return storage[accountKey]
            }

            func allItems() throws -> [ForgeKeychainItem] {
                lock.lock()
                defer { lock.unlock() }
                return storage.map(ForgeKeychainItem.init(accountKey:data:))
            }

            func replace(_ data: Data, for accountKey: String) throws {
                lock.lock()
                storage[accountKey] = data
                lock.unlock()
            }

            func remove(accountKey: String) throws {
                lock.lock()
                storage.removeValue(forKey: accountKey)
                lock.unlock()
            }
        }

        // swift6-safety-justification: The lock serializes notification delivery from any posting thread.
        private final nonisolated class HarnessNotificationCounter: @unchecked Sendable {
            private let lock = NSLock()
            private var count = 0

            var value: Int {
                lock.lock()
                defer { lock.unlock() }
                return count
            }

            func increment() {
                lock.lock()
                count += 1
                lock.unlock()
            }
        }

        private actor HarnessForgeCLIRunner: ForgeCLICommandRunning {
            func run(_: ForgeCLICommand) async throws -> ForgeCLICommandResult {
                throw ForgeCLIBrokerError.commandLaunchFailed
            }
        }

        private enum HarnessStartupFailure: Error {
            case expected
        }

        // swift6-safety-justification: The lock serializes the startup-failure invocation count.
        private final nonisolated class HarnessStartupFailureProbe: @unchecked Sendable {
            private let lock = NSLock()
            private var count = 0

            var invocationCount: Int {
                lock.lock()
                defer { lock.unlock() }
                return count
            }

            func recordInvocation() {
                lock.lock()
                count += 1
                lock.unlock()
            }
        }

        // swift6-safety-justification: URLSession creates one instance per immutable harness request.
        private final nonisolated class HarnessAvatarURLProtocol: URLProtocol, @unchecked Sendable {
            static let payloadByteCount = 16 * 1024 + 1

            override class func canInit(with request: URLRequest) -> Bool {
                request.url?.host == "avatars.githubusercontent.com"
            }

            override class func canonicalRequest(for request: URLRequest) -> URLRequest {
                request
            }

            override func startLoading() {
                guard let url = request.url else {
                    client?.urlProtocol(self, didFailWithError: ForgeAvatarLoadingError.invalidResponse)
                    return
                }
                let result = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                    .queryItems?.first(where: { $0.name == "result" })?.value
                if result == "plain" {
                    client?.urlProtocol(
                        self,
                        didReceive: URLResponse(
                            url: url,
                            mimeType: ForgeAvatarMediaType.png.rawValue,
                            expectedContentLength: Self.payloadByteCount,
                            textEncodingName: nil
                        ),
                        cacheStoragePolicy: .notAllowed
                    )
                    client?.urlProtocolDidFinishLoading(self)
                    return
                }
                let statusCode = result == "failure" ? 500 : 200
                guard let response = HTTPURLResponse(
                    url: url,
                    statusCode: statusCode,
                    httpVersion: "HTTP/1.1",
                    headerFields: [
                        "Content-Type": ForgeAvatarMediaType.png.rawValue,
                        "Content-Length": String(Self.payloadByteCount),
                    ]
                ) else {
                    client?.urlProtocol(self, didFailWithError: ForgeAvatarLoadingError.invalidResponse)
                    return
                }
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: Data(repeating: 8, count: Self.payloadByteCount))
                client?.urlProtocolDidFinishLoading(self)
            }

            override func stopLoading() {}
        }
    }

    // swift6-safety-justification: Every access to the sole mutable value is serialized by the private lock.
    private final nonisolated class HarnessRedirectResult: @unchecked Sendable {
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

#endif
