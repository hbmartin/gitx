import Foundation
import OSLog // swiftlint:disable:this unused_import

public enum ForgeAttentionInboxError: Error, Equatable, LocalizedError, Sendable {
    case mismatchedWatch
    case mismatchedViewerForge
    case mismatchedSubject
    case missingWatchedRepository
    case corruptPersistenceRecord
    case duplicateAttentionRecord
    case staleRefreshGeneration

    public var errorDescription: String? {
        switch self {
        case .mismatchedWatch:
            "The Attention snapshot does not belong to the watched repository."
        case .mismatchedViewerForge:
            "The Attention viewer belongs to a different Forge."
        case .mismatchedSubject:
            "The Attention record and display subject do not identify the same item."
        case .missingWatchedRepository:
            "The requested repository is not watched by this Forge Account."
        case .corruptPersistenceRecord:
            "A durable Attention record does not match its canonical persistence identity."
        case .duplicateAttentionRecord:
            "Attention reconciliation received duplicate durable record identities."
        case .staleRefreshGeneration:
            "A newer Attention refresh already committed for this watched repository."
        }
    }
}

/// Durable current-state and acknowledgement watermark for one Attention cause.
/// Display snapshots remain disposable cache data and are deliberately not
/// embedded in this record.
public struct ForgeAttentionRecord: Codable, Hashable, Sendable {
    public let item: ForgeAttentionItem
    public let sourceIdentifier: ForgeAttentionSubjectID
    public let sourceOccurredAt: Date

    public init(
        item: ForgeAttentionItem,
        sourceIdentifier: ForgeAttentionSubjectID,
        sourceOccurredAt: Date
    ) {
        self.item = item
        self.sourceIdentifier = sourceIdentifier
        self.sourceOccurredAt = sourceOccurredAt
    }

    public var expiresAt: Date? {
        switch item.state {
        case .resolved:
            item.lastTransitionAt.addingTimeInterval(ForgePolicyConstants.durableRecordExpiration)
        case .active:
            switch item.seenState {
            case .unseen:
                nil
            case let .seen(at):
                at.addingTimeInterval(ForgePolicyConstants.durableRecordExpiration)
            }
        }
    }

    public func replacing(item: ForgeAttentionItem) -> ForgeAttentionRecord {
        ForgeAttentionRecord(
            item: item,
            sourceIdentifier: sourceIdentifier,
            sourceOccurredAt: sourceOccurredAt
        )
    }

    fileprivate func replacing(
        item: ForgeAttentionItem? = nil,
        sourceIdentifier: ForgeAttentionSubjectID? = nil,
        sourceOccurredAt: Date? = nil
    ) -> ForgeAttentionRecord {
        ForgeAttentionRecord(
            item: item ?? self.item,
            sourceIdentifier: sourceIdentifier ?? self.sourceIdentifier,
            sourceOccurredAt: sourceOccurredAt ?? self.sourceOccurredAt
        )
    }
}

/// A current durable Attention record paired with its disposable list/inspector
/// display snapshot.
public struct ForgeAttentionInboxEntry: Codable, Hashable, Sendable {
    public let record: ForgeAttentionRecord
    public let subject: ForgeRepositoryItem

    public init(record: ForgeAttentionRecord, subject: ForgeRepositoryItem) throws {
        guard record.item.id.repository == subject.repository,
              record.item.destination == subject.destination
        else { throw ForgeAttentionInboxError.mismatchedSubject }
        self.record = record
        self.subject = subject
    }
}

public struct ForgeAttentionRepositorySnapshot: Hashable, Sendable {
    public let watchedRepositoryKey: ForgeWatchedRepositoryKey
    public let viewer: ForgeActor
    public let candidates: [ForgeAttentionCandidate]
    public let fetchedAt: Date
    public let completeness: ForgeSnapshotCompleteness

    public init(
        watchedRepositoryKey: ForgeWatchedRepositoryKey,
        viewer: ForgeActor,
        candidates: [ForgeAttentionCandidate],
        fetchedAt: Date,
        completeness: ForgeSnapshotCompleteness
    ) {
        self.watchedRepositoryKey = watchedRepositoryKey
        self.viewer = viewer
        self.candidates = candidates
        self.fetchedAt = fetchedAt
        self.completeness = completeness
    }
}

public struct ForgeAttentionReconciliation: Hashable, Sendable {
    public let watchedRepository: ForgeWatchedRepository
    public let records: [ForgeAttentionRecord]
    public let entries: [ForgeAttentionInboxEntry]
    public let newlyActionable: [ForgeAttentionItem]
    public let resolved: [ForgeAttentionItem]
    public let fetchedAt: Date
    public let completeness: ForgeSnapshotCompleteness

    public init(
        watchedRepository: ForgeWatchedRepository,
        records: [ForgeAttentionRecord],
        entries: [ForgeAttentionInboxEntry],
        newlyActionable: [ForgeAttentionItem],
        resolved: [ForgeAttentionItem],
        fetchedAt: Date,
        completeness: ForgeSnapshotCompleteness
    ) {
        self.watchedRepository = watchedRepository
        self.records = records
        self.entries = entries
        self.newlyActionable = newlyActionable
        self.resolved = resolved
        self.fetchedAt = fetchedAt
        self.completeness = completeness
    }
}

public enum ForgeAttentionReconciler {
    public static func reconcile(
        _ snapshot: ForgeAttentionRepositorySnapshot,
        watchedRepository: ForgeWatchedRepository,
        existingRecords: [ForgeAttentionRecord],
        policy: ForgeAttentionPolicy = .defaultValue
    ) throws -> ForgeAttentionReconciliation {
        guard snapshot.watchedRepositoryKey == watchedRepository.key else {
            throw ForgeAttentionInboxError.mismatchedWatch
        }
        guard snapshot.viewer.id.forge == watchedRepository.key.repository.forge else {
            throw ForgeAttentionInboxError.mismatchedViewerForge
        }

        let baselineAlreadyEstablished = watchedRepository.baselineEstablishedAt != nil
        var derived: [ForgeAttentionItemID: DerivedCause] = [:]
        var subjects: [ForgeAttentionSubjectID: ForgeRepositoryItem] = [:]
        for candidate in snapshot.candidates where candidate.item.repository == watchedRepository.key.repository {
            subjects[candidate.subjectID] = candidate.item
            for cause in try causes(
                from: candidate,
                snapshot: snapshot,
                watchedRepository: watchedRepository,
                policy: policy
            ) {
                guard let previous = derived[cause.id] else {
                    derived[cause.id] = cause
                    continue
                }
                if cause.occurredAt > previous.occurredAt
                    || (cause.occurredAt == previous.occurredAt
                        && cause.sourceIdentifier.value > previous.sourceIdentifier.value)
                {
                    derived[cause.id] = cause
                }
            }
        }

        var existingByID: [ForgeAttentionItemID: ForgeAttentionRecord] = [:]
        existingByID.reserveCapacity(existingRecords.count)
        for record in existingRecords {
            guard existingByID.updateValue(record, forKey: record.item.id) == nil else {
                throw ForgeAttentionInboxError.duplicateAttentionRecord
            }
        }
        var records: [ForgeAttentionRecord] = []
        var newlyActionable: [ForgeAttentionItem] = []
        var resolved: [ForgeAttentionItem] = []

        for cause in derived.values {
            let record: ForgeAttentionRecord
            if let existing = existingByID[cause.id] {
                if existing.item.state == .resolved {
                    let item = try existing.item.reactivating(at: snapshot.fetchedAt)
                    record = ForgeAttentionRecord(
                        item: item,
                        sourceIdentifier: cause.sourceIdentifier,
                        sourceOccurredAt: cause.occurredAt
                    )
                    if baselineAlreadyEstablished {
                        newlyActionable.append(item)
                    }
                } else if cause.sourceIdentifier != existing.sourceIdentifier,
                          cause.occurredAt > existing.sourceOccurredAt
                {
                    let item = try existing.item.noticingNewAction(at: snapshot.fetchedAt)
                    record = ForgeAttentionRecord(
                        item: item,
                        sourceIdentifier: cause.sourceIdentifier,
                        sourceOccurredAt: cause.occurredAt
                    )
                    if baselineAlreadyEstablished {
                        newlyActionable.append(item)
                    }
                } else {
                    record = existing.replacing(
                        sourceOccurredAt: max(existing.sourceOccurredAt, cause.occurredAt)
                    )
                }
            } else {
                let item = try ForgeAttentionItem(
                    id: cause.id,
                    destination: cause.destination,
                    authoredPullRequestFailedCheck: cause.authoredPullRequestFailedCheck,
                    becameActionableAt: snapshot.fetchedAt
                )
                record = ForgeAttentionRecord(
                    item: item,
                    sourceIdentifier: cause.sourceIdentifier,
                    sourceOccurredAt: cause.occurredAt
                )
                if baselineAlreadyEstablished {
                    newlyActionable.append(item)
                }
            }
            records.append(record)
        }

        for existing in existingRecords where derived[existing.item.id] == nil {
            if snapshot.completeness == .complete, existing.item.state == .active {
                let item = try existing.item.resolving(at: snapshot.fetchedAt)
                records.append(existing.replacing(item: item))
                resolved.append(item)
            } else {
                records.append(existing)
            }
        }

        records.sort(by: recordSort)
        newlyActionable.sort(by: itemSort)
        resolved.sort(by: itemSort)
        let entries = try records.compactMap { record -> ForgeAttentionInboxEntry? in
            guard record.item.state == .active,
                  let subject = subjects[record.item.id.subjectID]
            else { return nil }
            return try ForgeAttentionInboxEntry(record: record, subject: subject)
        }
        let isComplete = snapshot.completeness == .complete
        return ForgeAttentionReconciliation(
            watchedRepository: watchedRepository.recordingSuccessfulPoll(
                at: snapshot.fetchedAt,
                establishesBaseline: isComplete
            ),
            records: records,
            entries: entries,
            newlyActionable: newlyActionable,
            resolved: resolved,
            fetchedAt: snapshot.fetchedAt,
            completeness: snapshot.completeness
        )
    }

    private struct DerivedCause {
        let id: ForgeAttentionItemID
        let destination: ForgeDestination
        let sourceIdentifier: ForgeAttentionSubjectID
        let occurredAt: Date
        let authoredPullRequestFailedCheck: Bool
    }

    private static func causes(
        from candidate: ForgeAttentionCandidate,
        snapshot: ForgeAttentionRepositorySnapshot,
        watchedRepository: ForgeWatchedRepository,
        policy: ForgeAttentionPolicy
    ) throws -> [DerivedCause] {
        let viewer = snapshot.viewer
        let destination = candidate.item.destination
        let subjectUpdatedAt: Date
        let subjectAuthor: ForgeActor?
        let authoredByViewer: Bool
        let failedCheck: Bool
        switch candidate.item {
        case let .pullRequest(summary):
            subjectUpdatedAt = summary.updatedAt
            subjectAuthor = actor(in: summary.author)
            authoredByViewer = subjectAuthor?.id == viewer.id
            if case let .available(rollup) = summary.checkRollup {
                failedCheck = rollup == .failed
            } else {
                failedCheck = false
            }
        case let .issue(summary):
            subjectUpdatedAt = summary.updatedAt
            subjectAuthor = actor(in: summary.author)
            authoredByViewer = subjectAuthor?.id == viewer.id
            failedCheck = false
        }

        var signals: [(ForgeAttentionDerivation, ForgeAttentionSubjectID, Date)] = []
        if case let .available(reviewers) = candidate.requestedReviewers,
           reviewers.contains(where: { participant in
               if case let .actor(actor) = participant {
                   return actor.id == viewer.id
               }
               return false
           }),
           let derivation = ForgeAttentionDerivationPolicy.derive(
               ForgeAttentionSignal(watchedRepositoryKey: watchedRepository.key, event: .reviewRequested),
               watchedRepository: watchedRepository,
               policy: policy
           )
        {
            try signals.append((derivation, ForgeAttentionSubjectID("review-request-\(candidate.subjectID.value)"), subjectUpdatedAt))
        }
        if case let .available(assignees) = candidate.assignees,
           assignees.contains(where: { $0.id == viewer.id }),
           let derivation = ForgeAttentionDerivationPolicy.derive(
               ForgeAttentionSignal(watchedRepositoryKey: watchedRepository.key, event: .assigned),
               watchedRepository: watchedRepository,
               policy: policy
           )
        {
            try signals.append((derivation, ForgeAttentionSubjectID("assignment-\(candidate.subjectID.value)"), subjectUpdatedAt))
        }
        if failedCheck,
           let derivation = ForgeAttentionDerivationPolicy.derive(
               ForgeAttentionSignal(
                   watchedRepositoryKey: watchedRepository.key,
                   event: .checkFailed(
                       authoredByAccount: authoredByViewer,
                       awaitingAccountReview: isAwaitingReview(candidate, viewer: viewer)
                   )
               ),
               watchedRepository: watchedRepository,
               policy: policy
           )
        {
            try signals.append((derivation, ForgeAttentionSubjectID("failed-check-\(candidate.subjectID.value)"), subjectUpdatedAt))
        }

        if case let .available(body) = candidate.bodyMarkdown,
           containsMention(body, login: viewer.login),
           let derivation = mentionDerivation(watchedRepository: watchedRepository)
        {
            try signals.append((derivation, ForgeAttentionSubjectID("body-\(candidate.subjectID.value)"), subjectUpdatedAt))
        }

        let participated = accountParticipated(candidate, viewer: viewer, subjectAuthor: subjectAuthor)
        if case let .available(activities) = candidate.activities {
            for activity in activities {
                let author = actor(in: activity.author)
                let authorIsViewer = author?.id == viewer.id
                if !authorIsViewer,
                   containsMention(activity.bodyMarkdown, login: viewer.login),
                   let derivation = mentionDerivation(watchedRepository: watchedRepository)
                {
                    try signals.append((derivation, ForgeAttentionSubjectID(activity.id.value), activity.occurredAt))
                }
                guard activity.kind == .conversationComment || activity.kind == .reviewReply,
                      let author,
                      let derivation = ForgeAttentionDerivationPolicy.derive(
                          ForgeAttentionSignal(
                              watchedRepositoryKey: watchedRepository.key,
                              event: .reply(
                                  actorIsAccount: authorIsViewer,
                                  actorIsBot: author.kind == .bot,
                                  accountParticipated: participated
                              )
                          ),
                          watchedRepository: watchedRepository,
                          policy: policy
                      )
                else { continue }
                try signals.append((derivation, ForgeAttentionSubjectID(activity.id.value), activity.occurredAt))
            }
        }

        if case let .available(threads) = candidate.reviewThreads {
            for thread in threads {
                guard case let .available(page) = thread.comments else { continue }
                for comment in page.items {
                    let author = actor(in: comment.author)
                    let authorIsViewer = author?.id == viewer.id
                    if !authorIsViewer,
                       containsMention(comment.bodyMarkdown, login: viewer.login),
                       let derivation = mentionDerivation(watchedRepository: watchedRepository)
                    {
                        try signals.append((derivation, ForgeAttentionSubjectID(comment.id.value), comment.createdAt))
                    }
                    guard comment.replyToID != nil,
                          let author,
                          let derivation = ForgeAttentionDerivationPolicy.derive(
                              ForgeAttentionSignal(
                                  watchedRepositoryKey: watchedRepository.key,
                                  event: .reply(
                                      actorIsAccount: authorIsViewer,
                                      actorIsBot: author.kind == .bot,
                                      accountParticipated: participated
                                  )
                              ),
                              watchedRepository: watchedRepository,
                              policy: policy
                          )
                    else { continue }
                    try signals.append((derivation, ForgeAttentionSubjectID(comment.id.value), comment.createdAt))
                }
            }
        }

        return try signals.map { derivation, sourceIdentifier, occurredAt in
            try DerivedCause(
                id: ForgeAttentionItemID(
                    accountID: watchedRepository.key.accountID,
                    repository: watchedRepository.key.repository,
                    kind: derivation.kind,
                    subjectID: candidate.subjectID
                ),
                destination: destination,
                sourceIdentifier: sourceIdentifier,
                occurredAt: occurredAt,
                authoredPullRequestFailedCheck: derivation.authoredPullRequestFailedCheck
            )
        }
    }

    private static func mentionDerivation(
        watchedRepository: ForgeWatchedRepository
    ) -> ForgeAttentionDerivation? {
        ForgeAttentionDerivationPolicy.derive(
            ForgeAttentionSignal(watchedRepositoryKey: watchedRepository.key, event: .mention(actorIsAccount: false)),
            watchedRepository: watchedRepository
        )
    }

    private static func isAwaitingReview(_ candidate: ForgeAttentionCandidate, viewer: ForgeActor) -> Bool {
        guard case let .available(reviewers) = candidate.requestedReviewers else { return false }
        return reviewers.contains { participant in
            if case let .actor(actor) = participant {
                return actor.id == viewer.id
            }
            return false
        }
    }

    private static func accountParticipated(
        _ candidate: ForgeAttentionCandidate,
        viewer: ForgeActor,
        subjectAuthor: ForgeActor?
    ) -> Bool {
        if subjectAuthor?.id == viewer.id {
            return true
        }
        if case let .available(participants) = candidate.participants,
           participants.contains(where: { $0.id == viewer.id })
        {
            return true
        }
        return false
    }

    private static func actor(in section: ForgeReadSection<ForgeAuthor>) -> ForgeActor? {
        guard case let .available(author) = section,
              case let .actor(actor) = author
        else { return nil }
        return actor
    }

    private static func containsMention(_ text: String, login: String) -> Bool {
        let foldedText = text.lowercased()
        let needle = "@\(login.lowercased())"
        var searchStart = foldedText.startIndex
        while searchStart < foldedText.endIndex,
              let range = foldedText.range(of: needle, range: searchStart ..< foldedText.endIndex)
        {
            let beforeValid: Bool
            if range.lowerBound == foldedText.startIndex {
                beforeValid = true
            } else {
                let before = foldedText[foldedText.index(before: range.lowerBound)]
                beforeValid = !isLoginCharacter(before)
            }
            let afterValid: Bool
            if range.upperBound == foldedText.endIndex {
                afterValid = true
            } else {
                afterValid = !isLoginCharacter(foldedText[range.upperBound])
            }
            if beforeValid, afterValid {
                return true
            }
            searchStart = range.upperBound
        }
        return false
    }

    private static func isLoginCharacter(_ character: Character) -> Bool {
        character == "-" || character.isASCII && (character.isLetter || character.isNumber)
    }

    private static func recordSort(_ lhs: ForgeAttentionRecord, _ rhs: ForgeAttentionRecord) -> Bool {
        itemSort(lhs.item, rhs.item)
    }

    private static func itemSort(_ lhs: ForgeAttentionItem, _ rhs: ForgeAttentionItem) -> Bool {
        if lhs.lastTransitionAt != rhs.lastTransitionAt {
            return lhs.lastTransitionAt > rhs.lastTransitionAt
        }
        if lhs.id.subjectID.value != rhs.id.subjectID.value {
            return lhs.id.subjectID.value < rhs.id.subjectID.value
        }
        return lhs.id.kind.rawValue < rhs.id.kind.rawValue
    }
}

public enum ForgeAttentionViewScope: String, CaseIterable, Codable, Hashable, Sendable {
    case currentRepository
    case all
}

public enum ForgeAttentionSortOrder: String, CaseIterable, Codable, Hashable, Sendable {
    case newestFirst
    case oldestFirst
}

public enum ForgeAttentionColumn: String, CaseIterable, Codable, Hashable, Sendable {
    case kind
    case repository
    case number
    case title
    case author
    case updated
}

public struct ForgeAttentionViewState: Codable, Hashable, Sendable {
    public let scope: ForgeAttentionViewScope
    public let visibility: ForgeAttentionVisibility
    public let sortOrder: ForgeAttentionSortOrder
    public let kinds: Set<ForgeAttentionKind>
    public let columns: Set<ForgeAttentionColumn>

    public init(
        scope: ForgeAttentionViewScope = .currentRepository,
        visibility: ForgeAttentionVisibility = .unseenOnly,
        sortOrder: ForgeAttentionSortOrder = .newestFirst,
        kinds: Set<ForgeAttentionKind> = Set(ForgeAttentionKind.allCases),
        columns: Set<ForgeAttentionColumn> = [.kind, .repository, .number, .title, .author, .updated]
    ) {
        self.scope = scope
        self.visibility = visibility
        self.sortOrder = sortOrder
        self.kinds = kinds
        self.columns = columns
    }

    public static let defaultValue = ForgeAttentionViewState()
}

public struct ForgeAttentionInboxQuery: Hashable, Sendable {
    public let accountID: ForgeAccountID
    public let currentRepository: ForgeRepositoryIdentity?
    public let state: ForgeAttentionViewState

    public init(
        accountID: ForgeAccountID,
        currentRepository: ForgeRepositoryIdentity?,
        state: ForgeAttentionViewState = .defaultValue
    ) {
        self.accountID = accountID
        self.currentRepository = currentRepository
        self.state = state
    }

    public func applying(to entries: [ForgeAttentionInboxEntry]) -> [ForgeAttentionInboxEntry] {
        entries.filter { entry in
            guard entry.record.item.id.accountID == accountID,
                  entry.record.item.state == .active,
                  state.kinds.contains(entry.record.item.id.kind)
            else { return false }
            if state.scope == .currentRepository,
               entry.record.item.id.repository != currentRepository
            {
                return false
            }
            switch state.visibility {
            case .unseenOnly:
                return entry.record.item.seenState == .unseen
            case .active, .all:
                return true
            }
        }.sorted { lhs, rhs in
            if lhs.record.item.lastTransitionAt != rhs.record.item.lastTransitionAt {
                switch state.sortOrder {
                case .newestFirst:
                    return lhs.record.item.lastTransitionAt > rhs.record.item.lastTransitionAt
                case .oldestFirst:
                    return lhs.record.item.lastTransitionAt < rhs.record.item.lastTransitionAt
                }
            }
            return stableEntryKey(lhs) < stableEntryKey(rhs)
        }
    }

    private func stableEntryKey(_ entry: ForgeAttentionInboxEntry) -> String {
        let item = entry.record.item
        return "\(item.id.repository.canonicalKey)|\(item.id.subjectID.value)|\(item.id.kind.rawValue)"
    }
}

public enum ForgeAttentionPollingActivity: String, Codable, Hashable, Sendable {
    case activeOrOpen
    case background
}

public struct ForgeAttentionPollingTarget: Hashable, Sendable {
    public let watchedRepository: ForgeWatchedRepository
    public let activity: ForgeAttentionPollingActivity
    public let targetInterval: TimeInterval

    public init(
        watchedRepository: ForgeWatchedRepository,
        activity: ForgeAttentionPollingActivity,
        targetInterval: TimeInterval
    ) {
        self.watchedRepository = watchedRepository
        self.activity = activity
        self.targetInterval = targetInterval
    }
}

struct ForgeAttentionPollingBackoff: Hashable, Sendable {
    let consecutiveFailures: Int
    let delay: TimeInterval
    let retryAt: Date
}

public struct ForgeAttentionPollingScheduler: Sendable {
    private static let maximumBackoff: TimeInterval = 60 * 60
    private static let maximumTrackedFailureCount = 64

    public let preset: ForgeAttentionPollingPreset
    private var cursor = ForgeAttentionPollingCursor()
    private var failureBackoffs: [ForgeWatchedRepositoryKey: ForgeAttentionPollingBackoff] = [:]

    public init(preset: ForgeAttentionPollingPreset = .defaultValue) {
        self.preset = preset
    }

    public func nextTarget(
        watchedRepositories: [ForgeWatchedRepository],
        activeOrOpenRepositories: Set<ForgeWatchedRepositoryKey>,
        at date: Date
    ) -> ForgeAttentionPollingTarget? {
        guard let activeInterval = preset.activeInterval,
              let backgroundInterval = preset.backgroundInterval
        else { return nil }
        let ordered = watchedRepositories.sorted { $0.key.schedulingKey < $1.key.schedulingKey }
        guard !ordered.isEmpty else { return nil }
        let startIndex: Int
        if let last = cursor.lastPolled,
           let index = ordered.firstIndex(where: { $0.key == last })
        {
            startIndex = (index + 1) % ordered.count
        } else {
            startIndex = 0
        }
        for offset in ordered.indices {
            let watch = ordered[(startIndex + offset) % ordered.count]
            if let backoff = failureBackoffs[watch.key], date < backoff.retryAt {
                continue
            }
            let activity: ForgeAttentionPollingActivity = activeOrOpenRepositories.contains(watch.key)
                ? .activeOrOpen
                : .background
            let interval = activity == .activeOrOpen ? activeInterval : backgroundInterval
            if watch.lastSuccessfulPollAt.map({ date.timeIntervalSince($0) >= interval }) ?? true {
                return ForgeAttentionPollingTarget(
                    watchedRepository: watch,
                    activity: activity,
                    targetInterval: interval
                )
            }
        }
        return nil
    }

    public mutating func recordSelection(_ target: ForgeAttentionPollingTarget) {
        cursor = ForgeAttentionPollingCursor(lastPolled: target.watchedRepository.key)
    }

    @discardableResult
    mutating func recordFailure(
        _ target: ForgeAttentionPollingTarget,
        at date: Date
    ) -> ForgeAttentionPollingBackoff {
        let previousBackoff = failureBackoffs[target.watchedRepository.key]
        let previousCount = previousBackoff?.consecutiveFailures ?? 0
        let failureCount = min(previousCount + 1, Self.maximumTrackedFailureCount)
        let maximumDelay = max(Self.maximumBackoff, target.targetInterval)
        let targetDelay = max(target.targetInterval, 1)
        let delay = if let previousBackoff {
            min(max(targetDelay, previousBackoff.delay * 2), maximumDelay)
        } else {
            min(targetDelay, maximumDelay)
        }
        let backoff = ForgeAttentionPollingBackoff(
            consecutiveFailures: failureCount,
            delay: delay,
            retryAt: date.addingTimeInterval(delay)
        )
        failureBackoffs[target.watchedRepository.key] = backoff
        return backoff
    }

    mutating func recordSuccess(for key: ForgeWatchedRepositoryKey) {
        failureBackoffs.removeValue(forKey: key)
    }
}

public actor ForgeSQLiteAttentionPersistence {
    private struct PersistenceBatch: Sendable {
        let watchedRepository: ForgeSQLiteDurableRecord
        let records: [ForgeSQLiteDurableRecord]
        let cacheEntries: [ForgeSQLiteCacheEntry]
    }

    private let store: ForgeSQLiteStore
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(store: ForgeSQLiteStore) {
        self.store = store
        encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        decoder = JSONDecoder()
    }

    public func save(_ watchedRepository: ForgeWatchedRepository) async throws {
        try await store.saveDurableRecord(Self.durableRecord(for: watchedRepository, encoder: encoder))
    }

    public func save(_ records: [ForgeAttentionRecord]) async throws {
        for record in records {
            try await save(record)
        }
    }

    /// Atomically persists a complete reconciliation, creating its watched-repository row when absent.
    ///
    /// This method intentionally has upsert semantics for bootstrap and import callers. Repository refreshes use
    /// the package's guarded reconciliation path so a concurrent unwatch cannot be recreated.
    public func persist(_ reconciliation: ForgeAttentionReconciliation) async throws {
        try await store.updateAttention(reconciliation.watchedRepository.key) { state in
            let mergedWatch: ForgeWatchedRepository
            if let watchedRow = state.watchedRepository {
                let currentWatch = try Self.validatedWatch(
                    watchedRow,
                    expectedKey: reconciliation.watchedRepository.key
                )
                guard currentWatch.lastSuccessfulPollAt.map({ reconciliation.fetchedAt > $0 }) != false else {
                    throw ForgeAttentionInboxError.staleRefreshGeneration
                }
                mergedWatch = ForgeWatchedRepository(
                    key: currentWatch.key,
                    addedAt: currentWatch.addedAt,
                    source: currentWatch.source,
                    includesBotReplies: currentWatch.includesBotReplies,
                    baselineEstablishedAt: currentWatch.baselineEstablishedAt ??
                        reconciliation.watchedRepository.baselineEstablishedAt,
                    lastSuccessfulPollAt: reconciliation.watchedRepository.lastSuccessfulPollAt
                )
            } else {
                mergedWatch = reconciliation.watchedRepository
            }
            let batch = try Self.persistenceBatch(for: ForgeAttentionReconciliation(
                watchedRepository: mergedWatch,
                records: reconciliation.records,
                entries: reconciliation.entries,
                newlyActionable: reconciliation.newlyActionable,
                resolved: reconciliation.resolved,
                fetchedAt: reconciliation.fetchedAt,
                completeness: reconciliation.completeness
            ))
            return ForgeSQLiteAttentionTransactionUpdate(
                watchedRepository: batch.watchedRepository,
                records: batch.records,
                cacheEntries: batch.cacheEntries,
                result: ()
            )
        }
    }

    @discardableResult
    public func setIncludesBotReplies(
        _ includesBotReplies: Bool,
        for key: ForgeWatchedRepositoryKey
    ) async throws -> ForgeWatchedRepository {
        try await store.updateAttention(key) { state in
            guard let watchedRow = state.watchedRepository else {
                throw ForgeAttentionInboxError.missingWatchedRepository
            }
            let current = try Self.validatedWatch(watchedRow, expectedKey: key)
            let updated = ForgeWatchedRepository(
                key: current.key,
                addedAt: current.addedAt,
                source: current.source,
                includesBotReplies: includesBotReplies,
                baselineEstablishedAt: current.baselineEstablishedAt,
                lastSuccessfulPollAt: current.lastSuccessfulPollAt
            )
            return try ForgeSQLiteAttentionTransactionUpdate(
                watchedRepository: Self.durableRecord(for: updated),
                result: updated
            )
        }
    }

    func reconcileAndPersist(
        _ snapshot: ForgeAttentionRepositorySnapshot,
        policy: ForgeAttentionPolicy
    ) async throws -> ForgeAttentionReconciliation {
        try await store.updateAttention(snapshot.watchedRepositoryKey) { state in
            guard let watchedRow = state.watchedRepository else {
                throw ForgeAttentionInboxError.missingWatchedRepository
            }
            let watch = try Self.validatedWatch(watchedRow, expectedKey: snapshot.watchedRepositoryKey)
            guard watch.lastSuccessfulPollAt.map({ snapshot.fetchedAt > $0 }) != false else {
                throw ForgeAttentionInboxError.staleRefreshGeneration
            }
            let existing = try Self.validatedRecords(state.records, at: snapshot.fetchedAt)
            let reconciliation = try ForgeAttentionReconciler.reconcile(
                snapshot,
                watchedRepository: watch,
                existingRecords: existing,
                policy: policy
            )
            let batch = try Self.persistenceBatch(for: reconciliation)
            return ForgeSQLiteAttentionTransactionUpdate(
                watchedRepository: batch.watchedRepository,
                records: batch.records,
                cacheEntries: batch.cacheEntries,
                result: reconciliation
            )
        }
    }

    public func watchedRepositories(accountID: ForgeAccountID) async throws -> [ForgeWatchedRepository] {
        let rows = try await store.durableRecords(kind: .watchedRepository, accountID: accountID)
        return try rows.map { row in
            let watch = try decoder.decode(ForgeWatchedRepository.self, from: row.payload)
            guard watch.key.accountID == row.accountID,
                  watch.key.repository == row.repository,
                  try ForgeSQLiteStore.encodedKey(watch.key) == row.key
            else { throw ForgeAttentionInboxError.corruptPersistenceRecord }
            return watch
        }.sorted { $0.key.schedulingKey < $1.key.schedulingKey }
    }

    public func records(
        accountID: ForgeAccountID,
        repository: ForgeRepositoryIdentity? = nil,
        at date: Date
    ) async throws -> [ForgeAttentionRecord] {
        let rows = try await store.durableRecords(
            kind: .attention,
            accountID: accountID,
            repository: repository
        )
        return try rows.compactMap { row in
            let record = try validatedRecord(row)
            return record.item.isExpired(at: date) ? nil : record
        }.sorted {
            if $0.item.lastTransitionAt != $1.item.lastTransitionAt {
                return $0.item.lastTransitionAt > $1.item.lastTransitionAt
            }
            return $0.item.id.subjectID.value < $1.item.id.subjectID.value
        }
    }

    public func record(_ itemID: ForgeAttentionItemID) async throws -> ForgeAttentionRecord? {
        let key = try ForgeSQLiteStore.encodedKey(itemID)
        guard let row = try await store.durableRecord(
            kind: .attention,
            accountID: itemID.accountID,
            repository: itemID.repository,
            key: key
        ) else { return nil }
        return try validatedRecord(row)
    }

    /// Loads current durable state with its last disposable display snapshot.
    /// Missing/evicted snapshots simply omit a row and can be rebuilt by the
    /// next successful provider refresh.
    public func cachedEntries(
        query: ForgeAttentionInboxQuery,
        at date: Date
    ) async throws -> [ForgeAttentionInboxEntry] {
        let repository = query.state.scope == .currentRepository ? query.currentRepository : nil
        let durable = try await records(
            accountID: query.accountID,
            repository: repository,
            at: date
        )
        let cacheKeys = try durable.map { try Self.cacheKey(for: $0.item.id) }
        let cachedRecords = try await store.cacheEntries(for: cacheKeys, accessedAt: date)
        var entries: [ForgeAttentionInboxEntry] = []
        for (record, cachedRecord) in zip(durable, cachedRecords) {
            guard let cached = cachedRecord else { continue }
            let previous = try decoder.decode(ForgeAttentionInboxEntry.self, from: cached.payload)
            guard previous.record.item.id == record.item.id else {
                throw ForgeAttentionInboxError.corruptPersistenceRecord
            }
            try entries.append(ForgeAttentionInboxEntry(record: record, subject: previous.subject))
        }
        return query.applying(to: entries)
    }

    public func open(_ itemID: ForgeAttentionItemID, at date: Date) async throws -> ForgeAttentionRecord? {
        try await update(itemID) { try $0.opening(at: date) }
    }

    public func markSeen(_ itemID: ForgeAttentionItemID, at date: Date) async throws -> ForgeAttentionRecord? {
        try await update(itemID) { try $0.markingSeen(at: date) }
    }

    public func markUnseen(_ itemID: ForgeAttentionItemID, at date: Date) async throws -> ForgeAttentionRecord? {
        try await update(itemID) { try $0.markingUnseen(at: date) }
    }

    @discardableResult
    public func markAllSeen(
        query: ForgeAttentionQuery,
        at date: Date
    ) async throws -> [ForgeAttentionRecord] {
        let keys: [ForgeWatchedRepositoryKey]
        switch query.scope {
        case let .all(value):
            let rows = try await store.durableRecords(kind: .attention, accountID: value)
            keys = try Set(rows.map(\.repository)).map {
                try ForgeWatchedRepositoryKey(accountID: value, repository: $0)
            }.sorted { $0.schedulingKey < $1.schedulingKey }
        case let .currentRepository(key):
            keys = [key]
        }

        var allUpdated: [ForgeAttentionRecord] = []
        for key in keys {
            let updated = try await store.updateAttention(key) { state in
                if let watchedRow = state.watchedRepository {
                    _ = try Self.validatedWatch(watchedRow, expectedKey: key)
                }
                let current = try Self.validatedRecords(state.records, at: date)
                let transformed = try query.markingAllSeen(current.map(\.item), at: date)
                let selected = Set(query.applying(to: current.map(\.item)).map(\.id))
                let byID = Dictionary(uniqueKeysWithValues: transformed.map { ($0.id, $0) })
                let updated = current.compactMap { record -> ForgeAttentionRecord? in
                    guard selected.contains(record.item.id), let item = byID[record.item.id] else { return nil }
                    return record.replacing(item: item)
                }
                return try ForgeSQLiteAttentionTransactionUpdate(
                    records: updated.map { try Self.durableRecord(for: $0) },
                    result: updated
                )
            }
            allUpdated.append(contentsOf: updated)
        }
        return allUpdated
    }

    @discardableResult
    public func removeExpired(at date: Date) async throws -> Int {
        try await store.removeExpiredDurableRecords(kind: .attention, at: date)
    }

    public func removeWatchedRepository(_ key: ForgeWatchedRepositoryKey) async throws {
        try await store.updateAttention(key) { _ in
            ForgeSQLiteAttentionTransactionUpdate(
                removesWatchedRepository: true,
                result: ()
            )
        }
    }

    private func save(_ record: ForgeAttentionRecord) async throws {
        try await store.saveDurableRecord(ForgeSQLiteDurableRecord(
            kind: .attention,
            accountID: record.item.id.accountID,
            repository: record.item.id.repository,
            key: ForgeSQLiteStore.encodedKey(record.item.id),
            payload: encoder.encode(record),
            lastActivityAt: record.item.lastUpdatedAt,
            expiresAt: record.expiresAt
        ))
    }

    private func update(
        _ itemID: ForgeAttentionItemID,
        transform: @escaping @Sendable (ForgeAttentionItem) throws -> ForgeAttentionItem
    ) async throws -> ForgeAttentionRecord? {
        let key = try ForgeWatchedRepositoryKey(
            accountID: itemID.accountID,
            repository: itemID.repository
        )
        let recordKey = try ForgeSQLiteStore.encodedKey(itemID)
        return try await store.updateAttention(key) { state in
            if let watchedRow = state.watchedRepository {
                _ = try Self.validatedWatch(watchedRow, expectedKey: key)
            }
            guard let row = state.records.first(where: { $0.key == recordKey }) else {
                return ForgeSQLiteAttentionTransactionUpdate<ForgeAttentionRecord?>(result: nil)
            }
            let current = try Self.validatedRecord(row)
            let updated = try current.replacing(item: transform(current.item))
            return try ForgeSQLiteAttentionTransactionUpdate(
                records: [Self.durableRecord(for: updated)],
                result: updated
            )
        }
    }

    private func validatedRecord(_ row: ForgeSQLiteDurableRecord) throws -> ForgeAttentionRecord {
        let record = try decoder.decode(ForgeAttentionRecord.self, from: row.payload)
        guard record.item.id.accountID == row.accountID,
              record.item.id.repository == row.repository,
              try ForgeSQLiteStore.encodedKey(record.item.id) == row.key
        else { throw ForgeAttentionInboxError.corruptPersistenceRecord }
        return record
    }

    private nonisolated static func validatedWatch(
        _ row: ForgeSQLiteDurableRecord,
        expectedKey: ForgeWatchedRepositoryKey
    ) throws -> ForgeWatchedRepository {
        let watch = try JSONDecoder().decode(ForgeWatchedRepository.self, from: row.payload)
        let encodedKey = try ForgeSQLiteStore.encodedKey(expectedKey)
        guard row.kind == .watchedRepository,
              watch.key == expectedKey,
              row.accountID == expectedKey.accountID,
              row.repository == expectedKey.repository,
              row.key == encodedKey
        else { throw ForgeAttentionInboxError.corruptPersistenceRecord }
        return watch
    }

    private nonisolated static func validatedRecord(
        _ row: ForgeSQLiteDurableRecord
    ) throws -> ForgeAttentionRecord {
        let record = try JSONDecoder().decode(ForgeAttentionRecord.self, from: row.payload)
        guard row.kind == .attention,
              record.item.id.accountID == row.accountID,
              record.item.id.repository == row.repository,
              try ForgeSQLiteStore.encodedKey(record.item.id) == row.key
        else { throw ForgeAttentionInboxError.corruptPersistenceRecord }
        return record
    }

    private nonisolated static func validatedRecords(
        _ rows: [ForgeSQLiteDurableRecord],
        at date: Date
    ) throws -> [ForgeAttentionRecord] {
        try rows.compactMap { row in
            let record = try validatedRecord(row)
            return record.item.isExpired(at: date) ? nil : record
        }.sorted {
            if $0.item.lastTransitionAt != $1.item.lastTransitionAt {
                return $0.item.lastTransitionAt > $1.item.lastTransitionAt
            }
            return $0.item.id.subjectID.value < $1.item.id.subjectID.value
        }
    }

    private nonisolated static func persistenceBatch(
        for reconciliation: ForgeAttentionReconciliation
    ) throws -> PersistenceBatch {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let watch = reconciliation.watchedRepository
        let watchedRepository = try ForgeSQLiteDurableRecord(
            kind: .watchedRepository,
            accountID: watch.key.accountID,
            repository: watch.key.repository,
            key: ForgeSQLiteStore.encodedKey(watch.key),
            payload: encoder.encode(watch),
            lastActivityAt: watch.lastSuccessfulPollAt ?? watch.addedAt
        )
        let records = try reconciliation.records.map { try durableRecord(for: $0, encoder: encoder) }
        let cacheEntries = try reconciliation.entries.map { entry in
            let payload = try encoder.encode(entry)
            let cacheRecord = try ForgeDisposableCacheRecord(
                key: cacheKey(for: entry.record.item.id),
                byteCount: UInt64(payload.count),
                fetchedAt: reconciliation.fetchedAt,
                lastAccessedAt: reconciliation.fetchedAt,
                completeness: reconciliation.completeness
            )
            return try ForgeSQLiteCacheEntry(record: cacheRecord, payload: payload)
        }
        return PersistenceBatch(
            watchedRepository: watchedRepository,
            records: records,
            cacheEntries: cacheEntries
        )
    }

    private nonisolated static func durableRecord(
        for watchedRepository: ForgeWatchedRepository,
        encoder: JSONEncoder? = nil
    ) throws -> ForgeSQLiteDurableRecord {
        let encoder = encoder ?? {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            return encoder
        }()
        return try ForgeSQLiteDurableRecord(
            kind: .watchedRepository,
            accountID: watchedRepository.key.accountID,
            repository: watchedRepository.key.repository,
            key: ForgeSQLiteStore.encodedKey(watchedRepository.key),
            payload: encoder.encode(watchedRepository),
            lastActivityAt: watchedRepository.lastSuccessfulPollAt ?? watchedRepository.addedAt
        )
    }

    private nonisolated static func durableRecord(
        for record: ForgeAttentionRecord,
        encoder: JSONEncoder? = nil
    ) throws -> ForgeSQLiteDurableRecord {
        let encoder = encoder ?? {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            return encoder
        }()
        return try ForgeSQLiteDurableRecord(
            kind: .attention,
            accountID: record.item.id.accountID,
            repository: record.item.id.repository,
            key: ForgeSQLiteStore.encodedKey(record.item.id),
            payload: encoder.encode(record),
            lastActivityAt: record.item.lastUpdatedAt,
            expiresAt: record.expiresAt
        )
    }

    private nonisolated static func cacheKey(for itemID: ForgeAttentionItemID) throws -> ForgeDisposableCacheKey {
        let partition = try ForgeRepositoryPartitionKey(
            cachePartition: .account(itemID.accountID),
            repository: itemID.repository
        )
        let identity = try ForgeSQLiteStore.encodedKey(itemID).base64EncodedString()
        return .snapshot(ForgeCacheRecordKey(
            repositoryPartition: partition,
            kind: .derivedRenderData,
            identity: "attention:\(identity)"
        ))
    }
}

public enum ForgeAttentionSystemAuthorization: String, Codable, Hashable, Sendable {
    case notDetermined
    case denied
    case authorized
}

public struct ForgeAttentionAlert: Hashable, Sendable {
    public let itemID: ForgeAttentionItemID
    public let destination: ForgeDestination
    public let category: ForgeAttentionAlertCategory
    public let actions: [ForgeAttentionAlertAction]

    public init(
        itemID: ForgeAttentionItemID,
        destination: ForgeDestination,
        category: ForgeAttentionAlertCategory,
        actions: [ForgeAttentionAlertAction]
    ) {
        self.itemID = itemID
        self.destination = destination
        self.category = category
        self.actions = actions
    }
}

public protocol ForgeAttentionAlertDelivering: Sendable {
    func authorizationStatus() async -> ForgeAttentionSystemAuthorization
    func requestAuthorization() async -> Bool
    func deliver(_ alert: ForgeAttentionAlert) async
}

public protocol ForgeAttentionSnapshotFetching: Sendable {
    func snapshot(for watchedRepository: ForgeWatchedRepository) async throws -> ForgeAttentionRepositorySnapshot
}

public actor ForgeAttentionInboxCoordinator {
    private static let logger = Logger(subsystem: "com.gitx.ForgeKit", category: "AttentionInbox")

    private let persistence: ForgeSQLiteAttentionPersistence
    private let fetcher: any ForgeAttentionSnapshotFetching
    private let alertDelivery: any ForgeAttentionAlertDelivering
    private let attentionPolicy: ForgeAttentionPolicy
    private let now: @Sendable () -> Date
    private var enabledAlertCategories: Set<ForgeAttentionAlertCategory>
    private var scheduler: ForgeAttentionPollingScheduler

    public init(
        persistence: ForgeSQLiteAttentionPersistence,
        fetcher: any ForgeAttentionSnapshotFetching,
        alertDelivery: any ForgeAttentionAlertDelivering,
        attentionPolicy: ForgeAttentionPolicy = .defaultValue,
        enabledAlertCategories: Set<ForgeAttentionAlertCategory> = [],
        pollingPreset: ForgeAttentionPollingPreset = .defaultValue,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.persistence = persistence
        self.fetcher = fetcher
        self.alertDelivery = alertDelivery
        self.attentionPolicy = attentionPolicy
        self.now = now
        self.enabledAlertCategories = enabledAlertCategories
        scheduler = ForgeAttentionPollingScheduler(preset: pollingPreset)
    }

    @discardableResult
    public func updateAlertCategories(_ updated: Set<ForgeAttentionAlertCategory>) async -> Bool {
        let previous = enabledAlertCategories
        enabledAlertCategories = updated
        guard ForgeAttentionAlertPolicy.shouldRequestSystemPermission(previous: previous, updated: updated) else {
            return false
        }
        _ = await alertDelivery.requestAuthorization()
        return true
    }

    public func refresh(_ key: ForgeWatchedRepositoryKey) async throws -> ForgeAttentionReconciliation {
        let watches = try await persistence.watchedRepositories(accountID: key.accountID)
        guard let watch = watches.first(where: { $0.key == key }) else {
            throw ForgeAttentionInboxError.missingWatchedRepository
        }
        let reconciliation = try await refreshWatchedRepository(watch)
        scheduler.recordSuccess(for: key)
        return reconciliation
    }

    /// Refreshes an account's entire watch set as one manual operation. A
    /// provider failure for one repository does not prevent later watches
    /// from being reconciled and persisted.
    public func refreshAllWatched(accountID: ForgeAccountID) async throws -> [ForgeAttentionReconciliation] {
        let watches = try await persistence.watchedRepositories(accountID: accountID)
        var reconciliations: [ForgeAttentionReconciliation] = []
        var firstFailure: (any Error)?
        for watch in watches {
            try Task.checkCancellation()
            do {
                try reconciliations.append(await refreshWatchedRepository(watch))
                scheduler.recordSuccess(for: watch.key)
            } catch let error as CancellationError {
                throw error
            } catch {
                try Task.checkCancellation()
                if firstFailure == nil {
                    firstFailure = error
                }
            }
        }
        try Task.checkCancellation()
        if let firstFailure {
            throw firstFailure
        }
        return reconciliations
    }

    private func refreshWatchedRepository(
        _ watch: ForgeWatchedRepository
    ) async throws -> ForgeAttentionReconciliation {
        let snapshot = try await fetcher.snapshot(for: watch)
        let reconciliation = try await persistence.reconcileAndPersist(
            snapshot,
            policy: attentionPolicy
        )
        await deliverAlerts(
            for: reconciliation.newlyActionable,
            baselineAlreadyEstablished: reconciliation.watchedRepository.baselineEstablishedAt != nil
        )
        Self.logger.info(
            "Reconciled Attention for one watched repository: \(reconciliation.records.count) current records, \(reconciliation.newlyActionable.count) new transitions"
        )
        return reconciliation
    }

    public func handle(
        action: ForgeAttentionAlertAction,
        itemID: ForgeAttentionItemID,
        at date: Date
    ) async throws -> ForgeDestination? {
        switch action {
        case .open:
            return try await persistence.open(itemID, at: date)?.item.destination
        case .markSeen:
            _ = try await persistence.markSeen(itemID, at: date)
            return nil
        }
    }

    public func refreshNextDue(
        accountID: ForgeAccountID,
        activeOrOpenRepositories: Set<ForgeWatchedRepositoryKey>,
        at requestedDate: Date? = nil
    ) async throws -> ForgeAttentionReconciliation? {
        let date = requestedDate ?? now()
        let watches = try await persistence.watchedRepositories(accountID: accountID)
        guard let target = scheduler.nextTarget(
            watchedRepositories: watches,
            activeOrOpenRepositories: activeOrOpenRepositories,
            at: date
        ) else { return nil }
        // Move the fairness cursor before network work so a failing repository
        // cannot starve the remainder of an account's watch set.
        scheduler.recordSelection(target)
        do {
            return try await refresh(target.watchedRepository.key)
        } catch let error as CancellationError {
            throw error
        } catch {
            let backoff = scheduler.recordFailure(target, at: date)
            Self.logger.error(
                "Scheduled Attention refresh failed; deferring this repository for \(backoff.delay, privacy: .public) seconds after \(backoff.consecutiveFailures, privacy: .public) consecutive failures"
            )
            throw error
        }
    }

    private func deliverAlerts(
        for items: [ForgeAttentionItem],
        baselineAlreadyEstablished: Bool
    ) async {
        let authorization = await alertDelivery.authorizationStatus()
        for item in items {
            let decision = ForgeAttentionAlertPolicy.decision(
                forNewlyActionable: item,
                baselineAlreadyEstablished: baselineAlreadyEstablished,
                applicationIsRunning: true,
                enabledCategories: enabledAlertCategories,
                systemPermissionGranted: authorization == .authorized
            )
            guard case let .deliver(category, actions) = decision else { continue }
            await alertDelivery.deliver(ForgeAttentionAlert(
                itemID: item.id,
                destination: item.destination,
                category: category,
                actions: actions
            ))
        }
    }
}
