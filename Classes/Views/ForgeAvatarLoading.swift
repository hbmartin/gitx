import AppKit
import ForgeKit
import ImageIO
import OSLog // swiftlint:disable:this unused_import
import UniformTypeIdentifiers

nonisolated struct ForgeAvatarPayload: Equatable, Sendable {
    let data: Data
    let mediaType: ForgeAvatarMediaType
}

nonisolated protocol ForgeAvatarTransport: Sendable {
    func fetch(_ avatarURL: ForgeAvatarURL) async throws -> ForgeAvatarPayload
}

nonisolated enum ForgeAvatarLoadingError: Error, Equatable, LocalizedError {
    case disabled
    case accountRemoved
    case invalidResponse
    case decodingFailed

    var errorDescription: String? {
        switch self {
        case .disabled: "Avatar loading is disabled."
        case .accountRemoved: "The Forge Account for this avatar was removed."
        case .invalidResponse: "The avatar server returned an invalid response."
        case .decodingFailed: "The avatar image could not be decoded safely."
        }
    }
}

nonisolated enum ForgeAvatarLoadingPreferenceNotification {
    static let enabledUserInfoKey = "enabled"

    @MainActor
    static func post(enabled: Bool) {
        NotificationCenter.default.post(
            name: .forgeAvatarLoadingDidChange,
            object: nil,
            userInfo: [enabledUserInfoKey: enabled]
        )
    }
}

// swift6-safety-justification: The delegate is stateless; every callback validates only its arguments.
final nonisolated class ForgeAvatarRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _: URLSession,
        task _: URLSessionTask,
        willPerformHTTPRedirection _: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        guard let url = request.url,
              let validated = try? ForgeAvatarURL(url)
        else {
            completionHandler(nil)
            return
        }
        completionHandler(ForgeAvatarNetworkTransport.request(for: validated))
    }

    func urlSession(
        _: URLSession,
        task _: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              challenge.previousFailureCount == 0
        else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        completionHandler(.performDefaultHandling, nil)
    }
}

// swift6-safety-justification: The copied configuration is private, immutable, and used to create per-call sessions.
final nonisolated class ForgeAvatarNetworkTransport: ForgeAvatarTransport, @unchecked Sendable {
    private let configuration: URLSessionConfiguration

    init(configuration: URLSessionConfiguration = ForgeAvatarNetworkTransport.secureConfiguration()) {
        self.configuration = configuration.copy() as? URLSessionConfiguration ?? Self.secureConfiguration()
    }

    func fetch(_ avatarURL: ForgeAvatarURL) async throws -> ForgeAvatarPayload {
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        let (bytes, response) = try await session.bytes(
            for: Self.request(for: avatarURL),
            delegate: ForgeAvatarRedirectDelegate()
        )
        guard let response = response as? HTTPURLResponse,
              let finalURL = response.url
        else {
            throw ForgeAvatarLoadingError.invalidResponse
        }
        let metadata = try ForgeAvatarResponseMetadata(
            finalURL: finalURL,
            statusCode: response.statusCode,
            contentType: response.value(forHTTPHeaderField: "Content-Type"),
            expectedByteCount: response.expectedContentLength
        )
        var accumulator = try ForgeAvatarByteAccumulator(
            expectedByteCount: metadata.expectedByteCount
        )
        var chunk: [UInt8] = []
        chunk.reserveCapacity(16 * 1024)
        for try await byte in bytes {
            try Task.checkCancellation()
            chunk.append(byte)
            if chunk.count == chunk.capacity {
                try accumulator.append(Data(chunk))
                chunk.removeAll(keepingCapacity: true)
            }
        }
        if !chunk.isEmpty {
            try accumulator.append(Data(chunk))
        }
        return ForgeAvatarPayload(data: accumulator.data, mediaType: metadata.mediaType)
    }

    static func secureConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpAdditionalHeaders = [:]
        return configuration
    }

    static func request(for avatarURL: ForgeAvatarURL) -> URLRequest {
        var request = URLRequest(
            url: avatarURL.url,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 30
        )
        request.httpMethod = "GET"
        request.httpShouldHandleCookies = false
        request.setValue(ForgeAvatarMediaType.acceptHeader, forHTTPHeaderField: "Accept")
        request.setValue(nil, forHTTPHeaderField: "Authorization")
        request.setValue(nil, forHTTPHeaderField: "Cookie")
        request.setValue(nil, forHTTPHeaderField: "Referer")
        return request
    }
}

/// ImageIO's immutable first-frame result can cross back to the main actor;
/// AppKit image construction remains main-actor-only.
// swift6-safety-justification: CGImage is immutable, retained by this value, and never mutated after ImageIO returns it.
nonisolated struct ForgeAvatarDecodedImage: @unchecked Sendable {
    let cgImage: CGImage
    let wasDecodedOnMainThread: Bool

    var size: NSSize {
        NSSize(width: cgImage.width, height: cgImage.height)
    }

    @MainActor
    func makeImage() -> NSImage {
        NSImage(cgImage: cgImage, size: size)
    }
}

nonisolated struct ForgeAvatarImageDecoder: Sendable {
    func decode(
        _ payload: ForgeAvatarPayload,
        maximumPixels: Int = ForgeAvatarSecurityConstants.maximumDecodedPixels
    ) throws -> ForgeAvatarDecodedImage {
        try Task.checkCancellation()
        let wasDecodedOnMainThread = Thread.isMainThread
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(payload.data as CFData, options),
              CGImageSourceGetCount(source) > 0,
              let sourceType = CGImageSourceGetType(source) as String?,
              mediaType(for: sourceType) == payload.mediaType,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, options) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber
        else {
            throw ForgeAvatarPolicyError.mediaTypeMismatch
        }
        _ = try ForgeAvatarDecodedDimensions(
            width: width.intValue,
            height: height.intValue,
            maximumPixels: maximumPixels
        )
        try Task.checkCancellation()
        let decodeOptions = [
            kCGImageSourceShouldCache: true,
            kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, decodeOptions) else {
            throw ForgeAvatarLoadingError.decodingFailed
        }
        // Constructing from one CGImage deliberately discards every animated
        // frame after index zero for GIF and WebP payloads.
        try Task.checkCancellation()
        return ForgeAvatarDecodedImage(
            cgImage: image,
            wasDecodedOnMainThread: wasDecodedOnMainThread
        )
    }

    func decodeOffMain(
        _ payload: ForgeAvatarPayload,
        maximumPixels: Int = ForgeAvatarSecurityConstants.maximumDecodedPixels
    ) async throws -> ForgeAvatarDecodedImage {
        let task = Task.detached(priority: .utility) {
            try decode(payload, maximumPixels: maximumPixels)
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func mediaType(for typeIdentifier: String) -> ForgeAvatarMediaType? {
        switch typeIdentifier {
        case UTType.png.identifier: .png
        case UTType.jpeg.identifier: .jpeg
        case UTType.gif.identifier: .gif
        case UTType.webP.identifier: .webP
        default: nil
        }
    }
}

nonisolated protocol ForgeAvatarBackingStore: Sendable {
    func payload(
        for avatarURL: ForgeAvatarURL,
        owner: ForgeAvatarCacheOwner
    ) async throws -> ForgeAvatarPayload?
    func store(
        _ payload: ForgeAvatarPayload,
        for avatarURL: ForgeAvatarURL,
        owners: Set<ForgeAvatarCacheOwner>
    ) async throws
    func associate(_ owner: ForgeAvatarCacheOwner, with avatarURL: ForgeAvatarURL) async throws
    func purge() async throws
}

/// Explicit no-op disk tier for callers that only need the bounded memory front cache.
/// Milestone 1 application composition must replace this with
/// `ForgeSQLiteAvatarBackingStore` and cover read-through, write-through, and purge.
nonisolated struct ForgeAvatarMemoryOnlyBackingStore: ForgeAvatarBackingStore {
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
    func purge() async throws {}
}

/// A narrow adapter from the avatar loader to ForgeKit's shared disposable SQLite
/// cache. SQLite remains the authoritative 25 MiB avatar sub-cap inside the global
/// 250 MiB LRU; the loader's identically bounded dictionary is only a memory front.
nonisolated struct ForgeSQLiteAvatarBackingStore: ForgeAvatarBackingStore {
    private let store: ForgeSQLiteStore
    private let clock: @Sendable () -> Date

    init(store: ForgeSQLiteStore, clock: @escaping @Sendable () -> Date = Date.init) {
        self.store = store
        self.clock = clock
    }

    func payload(
        for avatarURL: ForgeAvatarURL,
        owner: ForgeAvatarCacheOwner
    ) async throws -> ForgeAvatarPayload? {
        let key = ForgeAvatarCacheKey(canonicalURL: avatarURL.url)
        guard let entry = try await store.avatarCacheEntry(
            for: key,
            owner: owner,
            accessedAt: clock()
        ) else {
            return nil
        }
        do {
            return try Self.decode(entry.payload)
        } catch {
            _ = try? await store.removeAvatarCacheEntry(key)
            throw error
        }
    }

    func store(
        _ payload: ForgeAvatarPayload,
        for avatarURL: ForgeAvatarURL,
        owners: Set<ForgeAvatarCacheOwner>
    ) async throws {
        let encoded = Self.encode(payload)
        let now = clock()
        let record = try ForgeDisposableCacheRecord(
            key: .avatar(ForgeAvatarCacheKey(canonicalURL: avatarURL.url)),
            byteCount: UInt64(encoded.count),
            fetchedAt: now,
            lastAccessedAt: now
        )
        try await store.putAvatarCacheEntry(
            ForgeSQLiteCacheEntry(record: record, payload: encoded),
            owners: owners
        )
        try await store.enforceCacheLimits()
    }

    func associate(_ owner: ForgeAvatarCacheOwner, with avatarURL: ForgeAvatarURL) async throws {
        try await store.associateAvatarCacheEntry(
            ForgeAvatarCacheKey(canonicalURL: avatarURL.url),
            owner: owner
        )
    }

    func purge() async throws {
        _ = try await store.removeAllAvatarCacheEntries()
    }

    private static func encode(_ payload: ForgeAvatarPayload) -> Data {
        var encoded = Data([storageCode(for: payload.mediaType)])
        encoded.append(payload.data)
        return encoded
    }

    private static func decode(_ encoded: Data) throws -> ForgeAvatarPayload {
        guard let code = encoded.first,
              let mediaType = mediaType(for: code),
              encoded.count - 1 <= ForgeAvatarSecurityConstants.maximumResponseBytes
        else {
            throw ForgeAvatarLoadingError.decodingFailed
        }
        return ForgeAvatarPayload(data: Data(encoded.dropFirst()), mediaType: mediaType)
    }

    private static func storageCode(for mediaType: ForgeAvatarMediaType) -> UInt8 {
        switch mediaType {
        case .png: 1
        case .jpeg: 2
        case .gif: 3
        case .webP: 4
        }
    }

    private static func mediaType(for storageCode: UInt8) -> ForgeAvatarMediaType? {
        switch storageCode {
        case 1: .png
        case 2: .jpeg
        case 3: .gif
        case 4: .webP
        default: nil
        }
    }
}

/// A single buffered worker preserves preference-write order while allowing the
/// synchronous Objective-C-visible setting to update without blocking the caller.
final nonisolated class ForgeAvatarLoadingPreferenceCoordinator: Sendable {
    private enum Command: Sendable {
        case update(Bool)
        case barrier(CheckedContinuation<Void, Never>)
    }

    static let shared = ForgeAvatarLoadingPreferenceCoordinator(
        apply: { enabled in
            await ForgeAvatarLoader.shared.setLoadingEnabled(enabled)
        },
        willApply: { enabled in
            guard !enabled else { return }
            await MainActor.run {
                ForgeAvatarLoadingPreferenceNotification.post(enabled: enabled)
            }
        },
        didApply: { enabled in
            guard enabled else { return }
            await MainActor.run {
                ForgeAvatarLoadingPreferenceNotification.post(enabled: enabled)
            }
        }
    )

    private let continuation: AsyncStream<Command>.Continuation
    private let worker: Task<Void, Never>

    init(
        apply: @escaping @Sendable (Bool) async -> Void,
        willApply: @escaping @Sendable (Bool) async -> Void = { _ in },
        didApply: @escaping @Sendable (Bool) async -> Void = { _ in }
    ) {
        let (stream, continuation) = AsyncStream<Command>.makeStream()
        self.continuation = continuation
        worker = Task {
            for await command in stream {
                guard !Task.isCancelled else { break }
                switch command {
                case let .update(enabled):
                    await willApply(enabled)
                    guard !Task.isCancelled else { break }
                    await apply(enabled)
                    guard !Task.isCancelled else { break }
                    await didApply(enabled)
                case let .barrier(barrier):
                    barrier.resume()
                }
            }
        }
    }

    deinit {
        continuation.finish()
        worker.cancel()
    }

    func submit(_ enabled: Bool) {
        continuation.yield(.update(enabled))
    }

    // Exercised from the app-hosted test target, which SwiftLint analyzes separately.
    // swiftlint:disable:next unused_declaration
    func flush() async {
        await withCheckedContinuation { barrier in
            continuation.yield(.barrier(barrier))
        }
    }
}

actor ForgeAvatarLoader {
    /// Application composition installs the shared Forge SQLite adapter before
    /// product surfaces request avatars. Recovery mode retains the explicit
    /// memory-only tier.
    static let shared = ForgeAvatarLoader(
        transport: ForgeAvatarNetworkTransport(),
        backingStore: ForgeAvatarMemoryOnlyBackingStore(),
        loadingEnabled: false,
        requiresBackingStoreInstallation: true
    )

    private struct CacheEntry {
        let payload: ForgeAvatarPayload
        var lastAccess: UInt64
    }

    private struct ActiveRequest {
        let id: UUID
        var task: Task<Void, Never>?
        var waiters: [UUID: Waiter]
    }

    private struct Waiter {
        let owner: ForgeAvatarCacheOwner
        let continuation: CheckedContinuation<ForgeAvatarPayload, Error>
    }

    private static let logger = Logger(subsystem: "com.gitx.gitx", category: "ForgeAvatarCache")
    private let transport: any ForgeAvatarTransport
    private var backingStore: any ForgeAvatarBackingStore
    private let cacheByteLimit: Int
    private var loadingEnabled = true
    private var backingStoreInstalled: Bool
    private var loadingAuthorityWasUpdated = false
    private var cache: [ForgeAvatarURL: CacheEntry] = [:]
    private var accessSequence: UInt64 = 0
    private var active: [ForgeAvatarURL: ActiveRequest] = [:]
    private var discardedRequestCompletions = 0
    private var backingStoreFailures = 0
    private var removedAccounts: Set<ForgeAccountID> = []

    init(
        transport: any ForgeAvatarTransport,
        backingStore: any ForgeAvatarBackingStore = ForgeAvatarMemoryOnlyBackingStore(),
        cacheByteLimit: Int = Int(ForgePolicyConstants.avatarCacheByteLimit),
        loadingEnabled: Bool = true,
        requiresBackingStoreInstallation: Bool = false
    ) {
        self.transport = transport
        self.backingStore = backingStore
        self.cacheByteLimit = max(cacheByteLimit, 0)
        self.loadingEnabled = loadingEnabled
        backingStoreInstalled = !requiresBackingStoreInstallation
    }

    func load(
        _ avatarURL: ForgeAvatarURL,
        owner: ForgeAvatarCacheOwner = .anonymous
    ) async throws -> ForgeAvatarPayload {
        try Task.checkCancellation()
        guard loadingEnabled, backingStoreInstalled else { throw ForgeAvatarLoadingError.disabled }
        try validate(owner)
        if let payload = cache[avatarURL]?.payload {
            do {
                try await backingStore.associate(owner, with: avatarURL)
            } catch {
                backingStoreFailures += 1
                Self.logger.error("Failed to persist structured avatar owner attribution")
            }
            try Task.checkCancellation()
            guard loadingEnabled, backingStoreInstalled else { throw ForgeAvatarLoadingError.disabled }
            try validate(owner)
            guard var entry = cache[avatarURL] else { return payload }
            accessSequence &+= 1
            entry.lastAccess = accessSequence
            cache[avatarURL] = entry
            return payload
        }
        let waiterID = UUID()
        let payload = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                registerWaiter(continuation, id: waiterID, owner: owner, for: avatarURL)
            }
        } onCancel: {
            Task { await self.cancelWaiter(id: waiterID, for: avatarURL) }
        }
        try Task.checkCancellation()
        return payload
    }

    func installBackingStore(
        _ backingStore: any ForgeAvatarBackingStore,
        loadingEnabled: Bool
    ) async throws {
        cancelActiveRequests(with: CancellationError())
        cache.removeAll()
        self.backingStore = backingStore
        backingStoreInstalled = true
        if !loadingAuthorityWasUpdated {
            self.loadingEnabled = loadingEnabled
        }
        if !self.loadingEnabled {
            do {
                try await backingStore.purge()
            } catch {
                backingStoreFailures += 1
                Self.logger.error("Failed to purge disabled structured avatar persistence during composition")
                throw error
            }
        }
        Self.logger.notice("Installed structured avatar persistence backing store")
    }

    func setLoadingEnabled(_ enabled: Bool) async {
        loadingAuthorityWasUpdated = true
        loadingEnabled = enabled
        guard !enabled else { return }
        cancelActiveRequests(with: ForgeAvatarLoadingError.disabled)
        cache.removeAll()
        do {
            try await backingStore.purge()
            Self.logger.info("Purged structured avatar memory and disposable backing caches")
        } catch {
            backingStoreFailures += 1
            Self.logger.error("Failed to purge the structured avatar disposable backing cache")
        }
    }

    func purge() async {
        cancelActiveRequests(with: CancellationError())
        cache.removeAll()
        do {
            try await backingStore.purge()
        } catch {
            backingStoreFailures += 1
            Self.logger.error("Failed to purge the structured avatar disposable backing cache")
        }
    }

    func invalidateForAccountRemoval(_ accountID: ForgeAccountID) {
        removedAccounts.insert(accountID)
        cancelActiveRequests(with: CancellationError())
        cache.removeAll()
        Self.logger.notice("Invalidated structured avatar memory for Forge Account removal")
    }

    func restoreAfterAccountAddition(_ accountID: ForgeAccountID) {
        removedAccounts.remove(accountID)
        Self.logger.notice("Restored structured avatar authority for an added Forge Account")
    }

    func statistics() -> (
        cachedItems: Int,
        cachedBytes: Int,
        activeRequests: Int,
        activeWaiters: Int,
        discardedRequestCompletions: Int,
        backingStoreFailures: Int,
        enabled: Bool
    ) {
        (
            cache.count,
            cache.values.reduce(0) { $0 + $1.payload.data.count },
            active.count,
            active.values.reduce(0) { $0 + $1.waiters.count },
            discardedRequestCompletions,
            backingStoreFailures,
            loadingEnabled && backingStoreInstalled
        )
    }

    private func registerWaiter(
        _ continuation: CheckedContinuation<ForgeAvatarPayload, Error>,
        id: UUID,
        owner: ForgeAvatarCacheOwner,
        for avatarURL: ForgeAvatarURL
    ) {
        guard loadingEnabled, backingStoreInstalled else {
            continuation.resume(throwing: ForgeAvatarLoadingError.disabled)
            return
        }
        do {
            try validate(owner)
        } catch {
            continuation.resume(throwing: error)
            return
        }
        if var request = active[avatarURL] {
            request.waiters[id] = Waiter(owner: owner, continuation: continuation)
            active[avatarURL] = request
            return
        }

        let requestID = UUID()
        active[avatarURL] = ActiveRequest(
            id: requestID,
            task: nil,
            waiters: [id: Waiter(owner: owner, continuation: continuation)]
        )
        let task = Task { [backingStore, transport] in
            do {
                let storedPayload: ForgeAvatarPayload?
                do {
                    storedPayload = try await backingStore.payload(for: avatarURL, owner: owner)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    self.recordBackingStoreFailure()
                    Self.logger.error("Structured avatar backing lookup failed; retrying from the approved host")
                    storedPayload = nil
                }

                let payload: ForgeAvatarPayload
                var persistedOwners: Set<ForgeAvatarCacheOwner>?
                if let storedPayload,
                   storedPayload.data.count <= ForgeAvatarSecurityConstants.maximumResponseBytes
                {
                    payload = storedPayload
                    persistedOwners = [owner]
                    Self.logger.debug("Loaded a structured avatar from the disposable backing cache")
                } else {
                    payload = try await transport.fetch(avatarURL)
                    try Task.checkCancellation()
                    guard payload.data.count <= ForgeAvatarSecurityConstants.maximumResponseBytes else {
                        throw ForgeAvatarPolicyError.responseTooLarge
                    }
                    do {
                        let owners = self.requestOwners(id: requestID, for: avatarURL)
                        try Task.checkCancellation()
                        guard !owners.isEmpty else { throw CancellationError() }
                        try await backingStore.store(payload, for: avatarURL, owners: owners)
                        persistedOwners = owners
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        self.recordBackingStoreFailure()
                        Self.logger.error("Failed to store a structured avatar in the disposable backing cache")
                    }
                }
                try Task.checkCancellation()
                if var persistedOwners {
                    while !self.completeRequestIfOwnersPersisted(
                        id: requestID,
                        for: avatarURL,
                        owners: persistedOwners,
                        payload: payload
                    ) {
                        let missingOwners = self.requestOwners(
                            id: requestID,
                            for: avatarURL
                        ).subtracting(persistedOwners)
                        for additionalOwner in missingOwners {
                            do {
                                try await backingStore.associate(additionalOwner, with: avatarURL)
                            } catch is CancellationError {
                                throw CancellationError()
                            } catch {
                                self.recordBackingStoreFailure()
                                Self.logger.error("Failed to persist late structured avatar attribution")
                            }
                        }
                        persistedOwners.formUnion(missingOwners)
                    }
                    return
                }
                self.completeRequest(
                    id: requestID,
                    for: avatarURL,
                    result: .success(payload)
                )
            } catch {
                self.completeRequest(
                    id: requestID,
                    for: avatarURL,
                    result: .failure(error)
                )
            }
        }
        active[avatarURL]?.task = task
    }

    private func cancelWaiter(id: UUID, for avatarURL: ForgeAvatarURL) {
        guard var request = active[avatarURL],
              let waiter = request.waiters.removeValue(forKey: id)
        else { return }
        waiter.continuation.resume(throwing: CancellationError())
        if request.waiters.isEmpty {
            active[avatarURL] = nil
            request.task?.cancel()
        } else {
            active[avatarURL] = request
        }
    }

    private func completeRequest(
        id: UUID,
        for avatarURL: ForgeAvatarURL,
        result: Result<ForgeAvatarPayload, Error>
    ) {
        guard active[avatarURL]?.id == id else {
            discardedRequestCompletions += 1
            Self.logger.debug("Discarded a superseded structured avatar request completion")
            return
        }
        guard let request = active.removeValue(forKey: avatarURL) else { return }
        let resolved: Result<ForgeAvatarPayload, Error>
        switch result {
        case let .success(payload) where loadingEnabled && backingStoreInstalled:
            insert(payload, for: avatarURL)
            resolved = .success(payload)
        case .success:
            resolved = .failure(ForgeAvatarLoadingError.disabled)
        case let .failure(error):
            resolved = .failure(error)
        }
        for waiter in request.waiters.values {
            waiter.continuation.resume(with: resolved)
        }
    }

    private func completeRequestIfOwnersPersisted(
        id: UUID,
        for avatarURL: ForgeAvatarURL,
        owners: Set<ForgeAvatarCacheOwner>,
        payload: ForgeAvatarPayload
    ) -> Bool {
        guard let request = active[avatarURL], request.id == id else { return true }
        let currentOwners = Set(request.waiters.values.map(\.owner))
        guard currentOwners.isSubset(of: owners) else { return false }
        completeRequest(id: id, for: avatarURL, result: .success(payload))
        return true
    }

    private func cancelActiveRequests(with error: Error) {
        let requests = active.values
        active.removeAll()
        for request in requests {
            request.task?.cancel()
            for waiter in request.waiters.values {
                waiter.continuation.resume(throwing: error)
            }
        }
    }

    private func requestOwners(id: UUID, for avatarURL: ForgeAvatarURL) -> Set<ForgeAvatarCacheOwner> {
        guard let request = active[avatarURL], request.id == id else { return [] }
        return Set(request.waiters.values.map(\.owner))
    }

    private func validate(_ owner: ForgeAvatarCacheOwner) throws {
        guard case let .account(accountID) = owner,
              removedAccounts.contains(accountID)
        else { return }
        throw ForgeAvatarLoadingError.accountRemoved
    }

    private func recordBackingStoreFailure() {
        backingStoreFailures += 1
    }

    private func insert(_ payload: ForgeAvatarPayload, for avatarURL: ForgeAvatarURL) {
        guard payload.data.count <= cacheByteLimit else { return }
        accessSequence &+= 1
        cache[avatarURL] = CacheEntry(payload: payload, lastAccess: accessSequence)
        while cache.values.reduce(0, { $0 + $1.payload.data.count }) > cacheByteLimit,
              let leastRecent = cache.min(by: { $0.value.lastAccess < $1.value.lastAccess })?.key
        {
            cache[leastRecent] = nil
        }
    }
}

@MainActor
final class ForgeAvatarView: NSView {
    private let logger = Logger(subsystem: "com.gitx.gitx", category: "ForgeAvatar")
    private let loader: ForgeAvatarLoader
    private let decoder: ForgeAvatarImageDecoder
    private let owner: ForgeAvatarCacheOwner
    private var requestTask: Task<Void, Never>?
    private var image: NSImage?
    private var avatarURL: ForgeAvatarURL?
    private var displayName = ""
    private(set) var initials = "?"
    private var isLoadingEnabled: Bool

    init(
        frame frameRect: NSRect = NSRect(x: 0, y: 0, width: 28, height: 28),
        loader: ForgeAvatarLoader = .shared,
        decoder: ForgeAvatarImageDecoder = ForgeAvatarImageDecoder(),
        owner: ForgeAvatarCacheOwner = .anonymous,
        loadingEnabled: Bool = ApplicationSettings.loadAvatars
    ) {
        self.loader = loader
        self.decoder = decoder
        self.owner = owner
        isLoadingEnabled = loadingEnabled
        super.init(frame: frameRect)
        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityIdentifier("ForgeAvatar")
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(avatarLoadingPreferenceChanged(_:)),
            name: .forgeAvatarLoadingDidChange,
            object: nil
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        requestTask?.cancel()
        NotificationCenter.default.removeObserver(self)
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 28, height: 28)
    }

    func configure(displayName: String, avatarURL: URL?) {
        self.displayName = displayName
        initials = Self.initials(for: displayName)
        self.avatarURL = avatarURL.flatMap { try? ForgeAvatarURL($0) }
        image = nil
        updateAccessibility()
        needsDisplay = true
        refresh()
    }

    /// Lets app-hosted verification wait on the same observable work the view
    /// owns instead of relying on a polling interval or a fixed delay.
    // Exercised from the app-hosted test target, which SwiftLint analyzes separately.
    // swiftlint:disable:next unused_declaration
    func waitForPendingLoad() async {
        await requestTask?.value
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let circle = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(ovalIn: circle)
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        if let image {
            image.draw(
                in: bounds,
                from: .zero,
                operation: .sourceOver,
                fraction: 1,
                respectFlipped: true,
                hints: [.interpolation: NSImageInterpolation.high]
            )
        } else {
            NSGradient(
                starting: NSColor(calibratedWhite: 0.82, alpha: 1),
                ending: NSColor(calibratedWhite: 0.67, alpha: 1)
            )?.draw(in: path, angle: 90)
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: max(10, bounds.height * 0.38), weight: .semibold),
                .foregroundColor: NSColor(calibratedWhite: 0.22, alpha: 1),
            ]
            let value = NSAttributedString(string: initials, attributes: attributes)
            let size = value.size()
            value.draw(at: NSPoint(
                x: bounds.midX - size.width / 2,
                y: bounds.midY - size.height / 2
            ))
        }
        NSGraphicsContext.restoreGraphicsState()
        NSColor(calibratedWhite: 0.42, alpha: 0.8).setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    static func initials(for displayName: String) -> String {
        let words = displayName
            .split(whereSeparator: \Character.isWhitespace)
            .compactMap(\.first)
        let selected = words.count > 1 ? [words[0], words[words.count - 1]] : Array(words.prefix(1))
        let value = String(selected).uppercased()
        return value.isEmpty ? "?" : value
    }

    private func refresh() {
        requestTask?.cancel()
        image = nil
        updateAccessibility()
        needsDisplay = true
        guard isLoadingEnabled, let avatarURL else { return }
        let requestOwner = owner
        requestTask = Task { [weak self, loader, decoder, requestOwner] in
            do {
                let payload = try await loader.load(avatarURL, owner: requestOwner)
                try Task.checkCancellation()
                let decoded = try await decoder.decodeOffMain(payload)
                guard let self, self.avatarURL == avatarURL else { return }
                self.image = decoded.makeImage()
                self.updateAccessibility()
                self.needsDisplay = true
                self.logger.debug("Displayed validated structured avatar")
            } catch is CancellationError {
                self?.logger.debug("Cancelled structured avatar request")
            } catch {
                self?.logger.debug("Structured avatar fell back to initials")
            }
        }
    }

    private func updateAccessibility() {
        let state = image == nil ? "initials \(initials)" : "avatar"
        setAccessibilityLabel("\(displayName.isEmpty ? "Unknown account" : displayName), \(state)")
    }

    @objc private func avatarLoadingPreferenceChanged(_ notification: Notification) {
        isLoadingEnabled = notification.userInfo?[ForgeAvatarLoadingPreferenceNotification.enabledUserInfoKey]
            as? Bool ?? ApplicationSettings.loadAvatars
        refresh()
    }
}
