import AppKit
import ForgeKit
import Foundation

nonisolated enum ForgeRecoveryAlertAction: Equatable, Sendable {
    case retry
    case resetForgeData
    case notNow
    case revealInFinder
    case deleteNow

    init?(response: NSApplication.ModalResponse) {
        switch response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue {
        case 0: self = .retry
        case 1: self = .resetForgeData
        case 2: self = .notNow
        case 3: self = .revealInFinder
        case 4: self = .deleteNow
        default: return nil
        }
    }
}

nonisolated struct ForgeRecoveryAlertPresentation: Equatable, Sendable {
    let title: String
    let message: String
    let buttonTitles: [String]

    static func make(recoveryCopies: [ForgeSQLiteRecoveryCopy]) -> Self {
        let copies = recoveryCopies.sorted { $0.createdAt < $1.createdAt }
        let retainedCopyList = copies.isEmpty
            ? "No retained recovery copies are currently available."
            : copies.map { "• \($0.url.lastPathComponent)" }.joined(separator: "\n")
        return Self(
            title: "Forge Data Unavailable",
            message: """
            GitX could not open its Forge database. Local Git remains fully available.

            GitX will retry automatically on the next launch. Retry attempts to salvage durable drafts, watched choices, seen state, and unknown mutation outcomes. Disposable Forge snapshots are rebuilt.

            Retained recovery copies (automatically deleted after 30 days):
            \(retainedCopyList)

            Reveal in Finder and Delete Now apply to the selected recovery copy. Delete Now permanently removes that file without moving it to the Trash and may remove the last copy of unrecovered drafts. This is normal filesystem deletion, not secure erase.
            """,
            buttonTitles: ["Retry", "Reset Forge Data…", "Not Now", "Reveal in Finder", "Delete Now"]
        )
    }
}

enum RepositoryHeadStatus: Equatable, Sendable {
    case branch(name: String, unborn: Bool)
    case detached(commit: String?)
    case unknown
}

enum RepositoryGitOperation: String, CaseIterable, Equatable, Sendable {
    case rebase
    case merge
    case cherryPick
    case revert
    case bisect
    case applyMailbox

    var displayText: String {
        switch self {
        case .rebase: "Rebase in progress"
        case .merge: "Merge in progress"
        case .cherryPick: "Cherry-pick in progress"
        case .revert: "Revert in progress"
        case .bisect: "Bisect in progress"
        case .applyMailbox: "Applying patches"
        }
    }
}

struct RepositoryWorkingStateCounts: Equatable, Sendable {
    var staged = 0
    var unstaged = 0
    var untracked = 0
    var conflicts = 0
}

struct RepositoryLocalStatusSnapshot: Equatable, Sendable {
    let head: RepositoryHeadStatus
    let ahead: Int
    let behind: Int
    let counts: RepositoryWorkingStateCounts
    let operation: RepositoryGitOperation?

    static let unavailable = RepositoryLocalStatusSnapshot(
        head: .unknown,
        ahead: 0,
        behind: 0,
        counts: RepositoryWorkingStateCounts(),
        operation: nil
    )
}

struct RepositoryLocalStatusPresentation: Equatable, Sendable {
    let branchText: String
    let aheadBehindText: String?
    let countsText: String
    let operationText: String?
    let accessibilityLabel: String
    let showsProgress: Bool
}

enum RepositoryPorcelainStatusParser {
    static func parse(_ data: Data, operation: RepositoryGitOperation?) -> RepositoryLocalStatusSnapshot? {
        guard let output = String(data: data, encoding: .utf8) else { return nil }
        let records = output.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
        var headName: String?
        var objectID: String?
        var ahead = 0
        var behind = 0
        var counts = RepositoryWorkingStateCounts()
        var skipRenameSource = false

        for record in records {
            if skipRenameSource {
                skipRenameSource = false
                continue
            }
            if record.hasPrefix("# branch.head ") {
                headName = String(record.dropFirst("# branch.head ".count))
                continue
            }
            if record.hasPrefix("# branch.oid ") {
                objectID = String(record.dropFirst("# branch.oid ".count))
                continue
            }
            if record.hasPrefix("# branch.ab ") {
                let fields = record.split(separator: " ")
                for field in fields.dropFirst(2) {
                    if field.first == "+" {
                        ahead = Int(field.dropFirst()) ?? 0
                    } else if field.first == "-" {
                        behind = Int(field.dropFirst()) ?? 0
                    }
                }
                continue
            }
            if record.hasPrefix("u ") {
                counts.conflicts += 1
                continue
            }
            if record.hasPrefix("? ") {
                counts.untracked += 1
                continue
            }
            guard record.hasPrefix("1 ") || record.hasPrefix("2 ") else { continue }
            let fields = record.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard fields.count >= 2, fields[1].count == 2 else { continue }
            let status = Array(fields[1])
            if status[0] != "." {
                counts.staged += 1
            }
            if status[1] != "." {
                counts.unstaged += 1
            }
            if record.hasPrefix("2 ") {
                skipRenameSource = true
            }
        }

        let head: RepositoryHeadStatus
        if objectID == "(initial)", let headName, headName != "(detached)" {
            head = .branch(name: headName, unborn: true)
        } else if headName == "(detached)" {
            let shortID = objectID.flatMap { $0 == "(initial)" ? nil : String($0.prefix(8)) }
            head = .detached(commit: shortID)
        } else if let headName, !headName.isEmpty {
            head = .branch(name: headName, unborn: false)
        } else {
            head = .unknown
        }
        return RepositoryLocalStatusSnapshot(
            head: head,
            ahead: max(0, ahead),
            behind: max(0, behind),
            counts: counts,
            operation: operation
        )
    }
}

enum RepositoryGitOperationDetector {
    static func detect(gitDirectory: URL, fileExists: (String) -> Bool) -> RepositoryGitOperation? {
        func exists(_ component: String) -> Bool {
            fileExists(gitDirectory.appendingPathComponent(component).path)
        }
        if exists("rebase-merge") {
            return .rebase
        }
        if exists("rebase-apply") {
            return exists("rebase-apply/applying") ? .applyMailbox : .rebase
        }
        if exists("MERGE_HEAD") {
            return .merge
        }
        if exists("CHERRY_PICK_HEAD") {
            return .cherryPick
        }
        if exists("REVERT_HEAD") {
            return .revert
        }
        if exists("BISECT_LOG") {
            return .bisect
        }
        return nil
    }
}

enum RepositoryLocalStatusPresenter {
    static func present(
        _ snapshot: RepositoryLocalStatusSnapshot,
        activityText: String?,
        isBusy: Bool
    ) -> RepositoryLocalStatusPresentation {
        let branchText = switch snapshot.head {
        case let .branch(name, unborn): unborn ? "\(name) (unborn)" : name
        case let .detached(commit): commit.map { "Detached at \($0)" } ?? "Detached HEAD"
        case .unknown: "Repository"
        }
        let aheadBehindText: String? = if snapshot.ahead == 0, snapshot.behind == 0 {
            nil
        } else {
            [snapshot.ahead > 0 ? "↑\(snapshot.ahead)" : nil, snapshot.behind > 0 ? "↓\(snapshot.behind)" : nil]
                .compactMap { $0 }
                .joined(separator: " ")
        }
        let countParts = [
            snapshot.counts.staged > 0 ? "\(snapshot.counts.staged) staged" : nil,
            snapshot.counts.unstaged > 0 ? "\(snapshot.counts.unstaged) unstaged" : nil,
            snapshot.counts.untracked > 0 ? "\(snapshot.counts.untracked) untracked" : nil,
            snapshot.counts.conflicts > 0 ? "\(snapshot.counts.conflicts) conflicts" : nil,
        ].compactMap { $0 }
        let countsText = countParts.isEmpty ? "Clean" : countParts.joined(separator: " · ")
        let nonemptyActivity = activityText?.trimmingCharacters(in: .whitespacesAndNewlines)
        let operationText = nonemptyActivity?.isEmpty == false ? nonemptyActivity : snapshot.operation?.displayText
        let accessibility = [branchText, aheadBehindText, countsText, operationText]
            .compactMap { $0 }
            .joined(separator: "; ")
        return RepositoryLocalStatusPresentation(
            branchText: branchText,
            aheadBehindText: aheadBehindText,
            countsText: countsText,
            operationText: operationText,
            accessibilityLabel: accessibility,
            showsProgress: isBusy
        )
    }
}

struct RepositoryStatusBarLayout: Equatable, Sendable {
    let showsAheadBehind: Bool
    let showsLocalCounts: Bool
    let showsForgeAccount: Bool
    let showsForgeFreshness: Bool

    static func presentation(forWidth width: CGFloat) -> RepositoryStatusBarLayout {
        RepositoryStatusBarLayout(
            showsAheadBehind: width >= 760,
            showsLocalCounts: width >= 900,
            showsForgeAccount: width >= 820,
            showsForgeFreshness: width >= 680
        )
    }
}

struct RepositoryForgeAccountControlPresentation: Equatable {
    let providerName: String
    let login: String?
    let isPublic: Bool
    let persistentFailureText: String?
    let isStatusBarVisible: Bool

    var title: String {
        if let login {
            return "@\(login)"
        }
        return isPublic ? "Public" : providerName
    }

    var avatarInitials: String {
        if let login {
            return String(login.prefix(2)).uppercased()
        }
        return isPublic ? "P" : String(providerName.prefix(1)).uppercased()
    }

    var toolTip: String {
        if let login {
            return "\(providerName) account @\(login) — Manage Accounts"
        }
        if isPublic {
            return "Public \(providerName) access — Manage Accounts"
        }
        return "Configure a \(providerName) account"
    }

    var accessibilityLabel: String {
        if let login {
            return "\(providerName) account, \(login)"
        }
        if isPublic {
            return "Public \(providerName) access"
        }
        return "\(providerName) account"
    }

    var showsPersistentFailure: Bool {
        !isStatusBarVisible && persistentFailureText != nil
    }
}

struct RepositoryForgeAccountRebindingPresentation: Equatable, Sendable {
    let isEnabled: Bool
    let helpText: String

    static func present(
        isEnabled: Bool,
        cooldownDeadline: Date?,
        now: Date
    ) -> RepositoryForgeAccountRebindingPresentation {
        guard !isEnabled else {
            return RepositoryForgeAccountRebindingPresentation(
                isEnabled: true,
                helpText: "Choose the account for this repository or manage accounts"
            )
        }
        if let cooldownDeadline, now < cooldownDeadline {
            return RepositoryForgeAccountRebindingPresentation(
                isEnabled: false,
                helpText: "Account changes are paused until GitHub’s rate-limit window ends."
            )
        }
        return RepositoryForgeAccountRebindingPresentation(
            isEnabled: false,
            helpText: "Account changes are paused until a successful GitHub retry completes."
        )
    }
}

struct RepositoryForgeAccountChoice: Equatable, Sendable {
    private static let accountIDKey = "accountID"
    private static let loginKey = "login"

    let id: ForgeAccountID
    let login: String

    var notificationValue: [String: Any] {
        [
            Self.accountIDKey: id,
            Self.loginKey: login,
        ]
    }

    static func notificationChoices(from value: Any?) -> [RepositoryForgeAccountChoice] {
        guard let values = value as? [[String: Any]] else { return [] }
        return values.compactMap { value in
            guard let id = value[Self.accountIDKey] as? ForgeAccountID,
                  let login = value[Self.loginKey] as? String
            else { return nil }
            return RepositoryForgeAccountChoice(id: id, login: login)
        }
    }

    var avatarURL: URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "avatars.githubusercontent.com"
        components.path = "/\(login)"
        components.queryItems = [URLQueryItem(name: "size", value: "64")]
        return components.url
    }
}

enum RepositoryForgeAccountSelection {
    static func updating(
        _ binding: ForgeRepositoryBinding,
        preferredAccount: ForgeAccountID
    ) throws -> ForgeRepositoryBinding {
        try ForgeRepositoryBinding(
            localRemoteName: binding.localRemoteName,
            primaryRepository: binding.primaryRepository,
            preferredAccount: preferredAccount
        )
    }
}

enum RepositoryForgeAccountsPreferencesRouting {
    static let selectedPaneDefaultsKey = "PBGitXPreferenceViewIdentifier"
    static let accountsPaneIdentifier = "Accounts"

    static func prepare() {
        UserDefaults.standard.set(accountsPaneIdentifier, forKey: selectedPaneDefaultsKey)
    }
}

struct RepositoryForgeDiagnosticDetails: Equatable, Sendable {
    let title: String
    let message: String
}

enum RepositoryForgeDiagnosticDetailsPresenter {
    static func present(_ action: ForgeStatusDetailsAction) -> RepositoryForgeDiagnosticDetails {
        let title = switch action {
        case .explainOffline: "Forge is Offline"
        case .authenticate: "Sign In Required"
        case .explainRateLimit: "GitHub Rate Limit"
        case .recoverForgeData: "Forge Data Unavailable"
        case .configureRepositoryAccess: "Repository Access Required"
        case .explainUnavailable: "Forge Unavailable"
        }
        let message = switch action {
        case .explainOffline: "Local Git remains available. Reconnect to refresh the cached Forge Overlay."
        case .authenticate: "Choose a Forge Account in Settings, then refresh this repository."
        case .explainRateLimit: "Cached data remains visible. Forge requests resume after GitHub's reset time."
        case .recoverForgeData: "Open Settings to retry recovery or reset Forge data. Local Git is unaffected."
        case .configureRepositoryAccess: "Configure the GitHub App installation and repository selection, then retry."
        case .explainUnavailable: "The Forge Overlay is unavailable. Local Git remains fully usable."
        }
        return RepositoryForgeDiagnosticDetails(title: title, message: message)
    }
}
