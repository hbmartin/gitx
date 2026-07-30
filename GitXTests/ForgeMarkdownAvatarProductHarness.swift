#if DEBUG
    import AppKit
    import ForgeKit

    /// Objective-C-compatible entry points that let the app-hosted test bundle
    /// execute the app module's internal pure-Swift Markdown and avatar boundaries.
    @MainActor
    @objc(PBForgeMarkdownAvatarProductHarness)
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
        static func loaderProof(completion: @escaping (UInt64) -> Void) {
            Task {
                completion(await makeLoaderProof())
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
