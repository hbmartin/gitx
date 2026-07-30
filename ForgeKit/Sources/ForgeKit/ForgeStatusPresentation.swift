import Foundation

/// Describes how a repository status surface is authenticated without
/// exposing Credential metadata or secret material to presentation code.
public enum ForgeStatusAccess: Hashable, Sendable {
    case noAccount
    case publicAccess
    case account(login: String)
}

/// The last usable Forge Overlay and any refresh currently replacing it.
public enum ForgeOverlayFreshness: Hashable, Sendable {
    case notLoaded
    case current(fetchedAt: Date)
    case refreshing(cachedAt: Date?)
    case stale(cachedAt: Date?)
}

public enum ForgeUnavailableReason: String, CaseIterable, Hashable, Sendable {
    case sessionDisabled
    case persistentStorageFailure
    case missingInstallation
    case missingRepositoryAccess
    case other
}

/// A user-actionable condition that is intentionally independent of any
/// GitHub transport error or response model.
public enum ForgeStatusDiagnostic: Hashable, Sendable {
    case none
    case offline
    case authenticationRequired
    case rateLimited(until: Date)
    case unavailable(ForgeUnavailableReason)
}

public struct ForgeRepositoryStatusInput: Hashable, Sendable {
    public let repository: ForgeRepositoryIdentity?
    public let access: ForgeStatusAccess
    public let freshness: ForgeOverlayFreshness
    public let diagnostic: ForgeStatusDiagnostic

    public init(
        repository: ForgeRepositoryIdentity?,
        access: ForgeStatusAccess,
        freshness: ForgeOverlayFreshness,
        diagnostic: ForgeStatusDiagnostic
    ) {
        self.repository = repository
        self.access = access
        self.freshness = freshness
        self.diagnostic = diagnostic
    }

    public static let unbound = ForgeRepositoryStatusInput(
        repository: nil,
        access: .noAccount,
        freshness: .notLoaded,
        diagnostic: .none
    )
}

public enum ForgeStatusDetailsAction: String, CaseIterable, Hashable, Sendable {
    case explainOffline
    case authenticate
    case explainRateLimit
    case recoverForgeData
    case configureRepositoryAccess
    case explainUnavailable
}

public struct ForgeRepositoryStatusPresentation: Equatable, Sendable {
    public let repositoryText: String
    public let accountText: String?
    public let freshnessText: String
    public let diagnosticText: String?
    public let accessibilityLabel: String
    public let showsProgress: Bool
    public let isRefreshEnabled: Bool
    public let refreshDisabledReason: String?
    public let rateLimitResetAt: Date?
    public let requiresClockUpdates: Bool
    public let detailsAction: ForgeStatusDetailsAction?
    public let toolbarPersistentFailureText: String?

    public init(
        repositoryText: String,
        accountText: String?,
        freshnessText: String,
        diagnosticText: String?,
        accessibilityLabel: String,
        showsProgress: Bool,
        isRefreshEnabled: Bool,
        refreshDisabledReason: String?,
        rateLimitResetAt: Date?,
        requiresClockUpdates: Bool,
        detailsAction: ForgeStatusDetailsAction?,
        toolbarPersistentFailureText: String?
    ) {
        self.repositoryText = repositoryText
        self.accountText = accountText
        self.freshnessText = freshnessText
        self.diagnosticText = diagnosticText
        self.accessibilityLabel = accessibilityLabel
        self.showsProgress = showsProgress
        self.isRefreshEnabled = isRefreshEnabled
        self.refreshDisabledReason = refreshDisabledReason
        self.rateLimitResetAt = rateLimitResetAt
        self.requiresClockUpdates = requiresClockUpdates
        self.detailsAction = detailsAction
        self.toolbarPersistentFailureText = toolbarPersistentFailureText
    }
}

public enum ForgeRepositoryStatusPresenter {
    public static func present(
        _ input: ForgeRepositoryStatusInput,
        now: Date
    ) -> ForgeRepositoryStatusPresentation {
        guard let repository = input.repository else {
            let diagnostic = diagnosticPresentation(input.diagnostic, now: now)
            let accessibility = [
                "No Forge Repository",
                "local Git remains available",
                diagnostic.text,
            ].compactMap { $0 }.joined(separator: "; ")
            return ForgeRepositoryStatusPresentation(
                repositoryText: "No Forge Repository",
                accountText: nil,
                freshnessText: "Local only",
                diagnosticText: diagnostic.text,
                accessibilityLabel: accessibility,
                showsProgress: false,
                isRefreshEnabled: false,
                refreshDisabledReason: diagnostic.disabledReason ?? "Bind a Forge Repository to refresh its overlay",
                rateLimitResetAt: diagnostic.rateLimitResetAt,
                requiresClockUpdates: diagnostic.requiresClockUpdates,
                detailsAction: diagnostic.detailsAction,
                toolbarPersistentFailureText: diagnostic.toolbarPersistentFailureText
            )
        }

        let repositoryText = "\(repository.owner)/\(repository.name)"
        let accountText = switch input.access {
        case .noAccount: "No Account"
        case .publicAccess: "Public access"
        case let .account(login): login
        }
        let freshness = freshnessPresentation(input.freshness, now: now)
        let diagnostic = diagnosticPresentation(input.diagnostic, now: now)
        let refreshEnabled = !freshness.showsProgress && diagnostic.allowsRefresh
        let accessibility = [repositoryText, accountText, freshness.text, diagnostic.text]
            .compactMap { $0 }
            .joined(separator: "; ")

        return ForgeRepositoryStatusPresentation(
            repositoryText: repositoryText,
            accountText: accountText,
            freshnessText: freshness.text,
            diagnosticText: diagnostic.text,
            accessibilityLabel: accessibility,
            showsProgress: freshness.showsProgress,
            isRefreshEnabled: refreshEnabled,
            refreshDisabledReason: freshness.showsProgress ? "A Forge refresh is already in progress" : diagnostic.disabledReason,
            rateLimitResetAt: diagnostic.rateLimitResetAt,
            requiresClockUpdates: freshness.requiresClockUpdates || diagnostic.requiresClockUpdates,
            detailsAction: diagnostic.detailsAction,
            toolbarPersistentFailureText: diagnostic.toolbarPersistentFailureText
        )
    }

    private static func freshnessPresentation(
        _ freshness: ForgeOverlayFreshness,
        now: Date
    ) -> (text: String, showsProgress: Bool, requiresClockUpdates: Bool) {
        switch freshness {
        case .notLoaded:
            ("Not refreshed", false, false)
        case let .current(fetchedAt):
            ("Updated \(age(from: fetchedAt, to: now))", false, true)
        case let .refreshing(cachedAt):
            (
                cachedAt.map { "Refreshing · cached \(age(from: $0, to: now))" } ?? "Refreshing",
                true,
                cachedAt != nil
            )
        case let .stale(cachedAt):
            (
                cachedAt.map { "Stale · cached \(age(from: $0, to: now))" } ?? "Stale · no cached data",
                false,
                cachedAt != nil
            )
        }
    }

    private static func diagnosticPresentation(
        _ diagnostic: ForgeStatusDiagnostic,
        now: Date
    ) -> (
        text: String?,
        allowsRefresh: Bool,
        disabledReason: String?,
        rateLimitResetAt: Date?,
        requiresClockUpdates: Bool,
        detailsAction: ForgeStatusDetailsAction?,
        toolbarPersistentFailureText: String?
    ) {
        switch diagnostic {
        case .none:
            return (nil, true, nil, nil, false, nil, nil)
        case .offline:
            return ("Offline", true, nil, nil, false, .explainOffline, nil)
        case .authenticationRequired:
            return (
                "Sign In Required",
                false,
                "Sign in before refreshing this Forge Repository",
                nil,
                false,
                .authenticate,
                nil
            )
        case let .rateLimited(until):
            guard until > now else {
                return ("Rate Limit Reset", true, nil, nil, false, .explainRateLimit, nil)
            }
            return (
                "Rate Limited · \(remaining(from: now, until: until))",
                false,
                "Rate limited",
                until,
                true,
                .explainRateLimit,
                nil
            )
        case let .unavailable(reason):
            let action: ForgeStatusDetailsAction = switch reason {
            case .persistentStorageFailure, .sessionDisabled: .recoverForgeData
            case .missingInstallation, .missingRepositoryAccess: .configureRepositoryAccess
            case .other: .explainUnavailable
            }
            let text = switch reason {
            case .missingInstallation: "GitHub App Not Installed"
            case .missingRepositoryAccess: "Repository Access Required"
            case .persistentStorageFailure, .sessionDisabled, .other: "Forge Unavailable"
            }
            let toolbarText: String? = switch reason {
            case .persistentStorageFailure, .sessionDisabled: "Forge Unavailable"
            case .missingInstallation, .missingRepositoryAccess, .other: nil
            }
            return (text, false, "Forge refresh is unavailable", nil, false, action, toolbarText)
        }
    }

    private static func age(from date: Date, to now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 60 {
            return "just now"
        }
        let minutes = Int(seconds / 60)
        if minutes < 60 {
            return "\(minutes)m ago"
        }
        let hours = minutes / 60
        if hours < 24 {
            return "\(hours)h ago"
        }
        return "\(hours / 24)d ago"
    }

    private static func remaining(from now: Date, until deadline: Date) -> String {
        let minutes = max(1, Int(ceil(deadline.timeIntervalSince(now) / 60)))
        guard minutes >= 60 else { return "\(minutes)m remaining" }
        let hours = minutes / 60
        let remainder = minutes % 60
        return remainder == 0 ? "\(hours)h remaining" : "\(hours)h \(remainder)m remaining"
    }
}
