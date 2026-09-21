import AppKit
import ObjectiveGit
import UniformTypeIdentifiers

struct RepositoryDocumentOpenState {
    private(set) var pendingOpenCount = 0
    private(set) var successfulRepositoryURLs: Set<URL> = []
    private(set) var explicitLaunchRequestCount = 0
    private(set) var explicitLaunchOpenSucceeded = false

    var hasPendingOpens: Bool {
        pendingOpenCount > 0
    }

    var hasPendingExplicitLaunchOpens: Bool {
        explicitLaunchRequestCount > 0
    }

    mutating func beginOpen() {
        pendingOpenCount += 1
    }

    mutating func beginExplicitLaunchOpen() {
        explicitLaunchRequestCount += 1
        beginOpen()
    }

    mutating func finishOpen(successfulURL: URL? = nil) {
        precondition(pendingOpenCount > 0, "Repository open accounting must remain balanced")
        pendingOpenCount -= 1
        guard let successfulURL else { return }
        successfulRepositoryURLs.insert(successfulURL.standardizedFileURL)
        if explicitLaunchRequestCount > 0 {
            explicitLaunchOpenSucceeded = true
        }
    }

    mutating func finishExplicitLaunchOpen() {
        precondition(explicitLaunchRequestCount > 0, "Explicit launch-open accounting must remain balanced")
        explicitLaunchRequestCount -= 1
        finishOpen()
    }
}

@objc(PBRepositoryDocumentOpenStateModel)
final class RepositoryDocumentOpenStateModel: NSObject {
    private var state = RepositoryDocumentOpenState()

    @objc var pendingOpenCount: Int {
        state.pendingOpenCount
    }

    @objc var hasPendingOpens: Bool {
        state.hasPendingOpens
    }

    @objc var hasPendingExplicitLaunchOpens: Bool {
        state.hasPendingExplicitLaunchOpens
    }

    @objc var explicitLaunchOpenSucceeded: Bool {
        state.explicitLaunchOpenSucceeded
    }

    @objc func beginOpen() {
        state.beginOpen()
    }

    @objc func beginExplicitLaunchOpen() {
        state.beginExplicitLaunchOpen()
    }

    @objc(finishOpenWithSuccessfulURL:)
    func finishOpen(successfulURL: URL? = nil) {
        state.finishOpen(successfulURL: successfulURL)
    }

    @objc func finishExplicitLaunchOpen() {
        state.finishExplicitLaunchOpen()
    }
}

@objc(PBRepositoryDocumentController)
class PBRepositoryDocumentController: NSDocumentController {
    static let opensDidSettleNotification = Notification.Name("PBRepositoryDocumentControllerOpensDidSettle")

    private let openState = RepositoryDocumentOpenStateModel()

    @objc var hasPendingOpens: Bool {
        openState.hasPendingOpens
    }

    @objc var hasPendingExplicitLaunchOpens: Bool {
        openState.hasPendingExplicitLaunchOpens
    }

    @objc var hasSuccessfulExplicitLaunchOpen: Bool {
        openState.explicitLaunchOpenSucceeded
    }

    @objc dynamic class func newOpenPanel() -> NSOpenPanel {
        NSOpenPanel()
    }

    func beginCoordinatedOpen() {
        openState.beginOpen()
        NSLog("[RepositoryOpening] Began coordinated open; pending=%ld", openState.pendingOpenCount)
    }

    func finishCoordinatedOpen() {
        finishOpenAccounting()
    }

    @objc func beginExplicitLaunchOpen() {
        openState.beginExplicitLaunchOpen()
        NSLog("[RepositoryOpening] Began explicit launch open; pending=%ld", openState.pendingOpenCount)
    }

    @objc func finishExplicitLaunchOpen() {
        openState.finishExplicitLaunchOpen()
        didUpdateOpenState()
    }

    override func openDocument(
        withContentsOf url: URL,
        display displayDocument: Bool,
        completionHandler: @escaping (NSDocument?, Bool, (any Error)?) -> Void
    ) {
        openState.beginOpen()
        NSLog("[RepositoryOpening] Opening %@; pending=%ld", url.path, openState.pendingOpenCount)
        super.openDocument(withContentsOf: url, display: displayDocument) { [weak self] document, alreadyOpen, error in
            guard let self else {
                completionHandler(document, alreadyOpen, error)
                return
            }
            if let document {
                let repositoryURL = (document.fileURL ?? url).standardizedFileURL
                openState.finishOpen(successfulURL: repositoryURL)
                RecentRepositoryStore.shared.record(repositoryURL)
                WelcomeWindowController.closeIfShown()
                NSLog("[RepositoryOpening] Opened %@", repositoryURL.path)
            } else {
                openState.finishOpen()
                NSLog("[RepositoryOpening] Open failed for %@: %@", url.path, error?.localizedDescription ?? "cancelled")
            }
            didUpdateOpenState()
            completionHandler(document, alreadyOpen, error)
        }
    }

    private func finishOpenAccounting() {
        openState.finishOpen()
        didUpdateOpenState()
    }

    private func didUpdateOpenState() {
        NSLog("[RepositoryOpening] Settled open; pending=%ld", openState.pendingOpenCount)
        NotificationCenter.default.post(name: Self.opensDidSettleNotification, object: self)
    }

    override func beginOpenPanel(
        _ openPanel: NSOpenPanel,
        forTypes _: [String]?,
        completionHandler: @escaping (Int) -> Void
    ) {
        if let gitContentType = UTType(filenameExtension: "git") {
            openPanel.allowedContentTypes = [gitContentType]
        }
        openPanel.canChooseFiles = true
        openPanel.canChooseDirectories = true
        completionHandler(openPanel.runModal().rawValue)
    }

    override func makeUntitledDocument(ofType typeName: String) throws -> NSDocument {
        let openPanel = Swift.type(of: self).newOpenPanel()
        openPanel.canChooseFiles = false
        openPanel.canChooseDirectories = true
        openPanel.allowsMultipleSelection = false
        openPanel.message = NSLocalizedString(
            "Initialize a repository here:",
            comment: "Message at the top of the repository initialisation file selection dialogue box"
        )
        openPanel.title = NSLocalizedString(
            "New Repository",
            comment: "Title of the repository initialisation file selection dialogue box"
        )
        guard openPanel.runModal() == .OK else {
            throw CocoaError(.userCancelled)
        }

        guard let repositoryURL = openPanel.url else {
            throw CocoaError(.fileReadUnknown)
        }
        _ = try GTRepository.initializeEmpty(atFileURL: repositoryURL, options: nil)
        return try PBGitRepositoryDocument(contentsOf: repositoryURL, ofType: PBGitRepositoryDocumentType)
    }

    override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(newDocument(_:)) {
            return PBGitBinary.path() != nil
        }
        return true
    }
}
