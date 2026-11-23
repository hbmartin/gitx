public enum ReflogBrowserRequestKind {
    case page, details, preview, mutation
}

public struct ReflogBrowserRequestPolicy {
    public var active: ReflogBrowserRequestKind?
    public var stale = true

    public init() {}

    public var permitsSelection: Bool {
        active == nil || active == .details
    }

    public var permitsRecovery: Bool {
        active == nil && !stale
    }

    public func permits(_ request: ReflogBrowserRequestKind) -> Bool {
        guard active != .mutation else { return false }
        return request != .details || active == nil || active == .details
    }
}
