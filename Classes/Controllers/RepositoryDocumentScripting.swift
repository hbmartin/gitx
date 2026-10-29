import Foundation

/// Canonical Git-directory identity is recomputed at each synchronous opening decision.
@MainActor
struct RepositoryGitDirectoryIdentity {
    private var lookups: [URL: URL?] = [:]
    private let findGitDirectory: (URL) -> URL?

    init(findGitDirectory: @escaping (URL) -> URL? = { PBRepositoryFinder.gitDir(for: $0) }) {
        self.findGitDirectory = findGitDirectory
    }

    mutating func discover(for url: URL) -> URL? {
        if let cached = lookups[url] {
            return cached
        }
        let identity = Self.normalized(findGitDirectory(url))
        lookups.updateValue(identity, forKey: url)
        return identity
    }

    static func normalized(_ gitDirectory: URL?) -> URL? {
        gitDirectory?.standardizedFileURL.resolvingSymlinksInPath()
    }
}

/// Captured while Cocoa is executing the event, before discovery can defer the open.
struct RepositoryDocumentOpenIntent {
    let repositoryURL: URL?
    let arguments: [String]

    init(command: NSScriptCommand?) {
        repositoryURL = command?.directParameter as? URL
        arguments = (command?.arguments?["openOptions"] as? [String] ?? []).map { $0 }
    }

    func arguments(for document: PBGitRepositoryDocument) -> [String]? {
        var identities = RepositoryGitDirectoryIdentity()
        return arguments(for: document, identities: &identities)
    }

    func arguments(for document: PBGitRepositoryDocument, identities: inout RepositoryGitDirectoryIdentity) -> [String]? {
        guard !arguments.isEmpty, let repositoryURL,
              let intended = identities.discover(for: repositoryURL),
              intended == RepositoryGitDirectoryIdentity.normalized(document.repository.gitURL()) else { return nil }
        return arguments
    }
}

/// Parsed values keep option interpretation out of the document's AppKit wiring.
nonisolated struct RepositoryScriptOpenOptions: Equatable {
    enum Action: Equatable { case none, commit, history }
    let action: Action
    let branchFilter: Int?
    let revisions: [String]

    init(_ arguments: [String]) {
        guard let first = arguments.first else { action = .none; branchFilter = nil; revisions = []; return }
        if first == "-c" || first == "--commit" {
            action = .commit; branchFilter = nil; revisions = []; return
        }
        action = .history
        switch first {
        case "--all": branchFilter = Int(kGitXAllBranchesFilter.rawValue)
        case "--local": branchFilter = Int(kGitXLocalRemoteBranchesFilter.rawValue)
        case "--branch": branchFilter = Int(kGitXSelectedBranchFilter.rawValue)
        default: branchFilter = nil
        }
        revisions = branchFilter == nil ? arguments : Array(arguments.dropFirst())
    }
}

@objc(PBRepositoryScriptOpenOptions)
final nonisolated class RepositoryScriptOpenOptionsBridge: NSObject {
    private let options: RepositoryScriptOpenOptions
    @objc(initWithArguments:)
    init(arguments: [String]?) {
        options = RepositoryScriptOpenOptions(arguments ?? []); super.init()
    }

    @objc var isEmpty: Bool {
        options.action == .none
    }

    @objc var showsCommit: Bool {
        options.action == .commit
    }

    @objc var branchFilter: NSNumber? {
        options.branchFilter.map(NSNumber.init(value:))
    }

    @objc var revisionArguments: [String] {
        options.revisions
    }
}

/// Weak document ownership and removal before dispatch make queued requests single-use.
@MainActor
@objc(PBRepositoryDocumentScripting)
final class RepositoryDocumentScripting: NSObject {
    private final class Pending: NSObject { var arguments: [[String]] = [] }
    private static let pending = NSMapTable<PBGitRepositoryDocument, Pending>.weakToStrongObjects()

    static func enqueue(_ arguments: [String], for document: PBGitRepositoryDocument) {
        let requests = pending.object(forKey: document) ?? Pending()
        requests.arguments.append(arguments)
        pending.setObject(requests, forKey: document)
    }

    /// Called by the Objective-C document lifecycle through GitX-Swift.h.
    @objc(applyPendingToDocument:)
    static func applyPending(to document: PBGitRepositoryDocument) { // swiftlint:disable:this unused_declaration
        let requests = pending.object(forKey: document)?.arguments ?? []
        pending.removeObject(forKey: document)
        requests.forEach { document.applyGitXOpenArguments($0) }
    }

    /// Called by the Objective-C document lifecycle through GitX-Swift.h.
    @objc(discardPendingForDocument:)
    static func discardPending(for document: PBGitRepositoryDocument) { // swiftlint:disable:this unused_declaration
        pending.removeObject(forKey: document)
    }
}
