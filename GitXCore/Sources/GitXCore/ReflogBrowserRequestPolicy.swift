public enum ReflogBrowserRequestKind {
    case page, details, preview, mutation
}

public struct ReflogBrowserRequestPolicy {
    public var active: ReflogBrowserRequestKind?
    public private(set) var stale = true
    public private(set) var revision: UInt64 = 0
    private var needsRefresh = false
    private var failedRefreshRevision: UInt64?

    public init() {}

    public var permitsSelection: Bool {
        active == nil || active == .details
    }

    public var permitsRecovery: Bool {
        active == nil && !stale
    }

    public var shouldRefresh: Bool {
        active == nil && needsRefresh && failedRefreshRevision != revision
    }

    public mutating func repositoryDidChange() {
        revision &+= 1
        beginRefresh()
    }

    public mutating func beginRefresh() {
        stale = true
        needsRefresh = true
    }

    public mutating func refreshSucceeded() {
        stale = false
        needsRefresh = false
        failedRefreshRevision = nil
    }

    public mutating func refreshFailed() {
        failedRefreshRevision = revision
    }

    public func permitsResetPreview(at revision: UInt64) -> Bool {
        self.revision == revision && permitsRecovery
    }

    public func permits(_ request: ReflogBrowserRequestKind) -> Bool {
        guard active != .mutation else { return false }
        return request != .details || active == nil || active == .details
    }
}
