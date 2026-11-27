import AppKit
import GitXCore

// SwiftLint analyze misclassifies this import; Logger requires it at compile time.
// swiftlint:disable:next unused_import
import OSLog

private let lfsWindowLogger = Logger(subsystem: "com.gitx.gitx", category: "LFS")

/// Git LFS details and explicit downloads for the current checkout (ADR 0014).
extension PBGitWindowController {
    /// The newest Git LFS status for this window's checkout.
    var lfsStatusSnapshot: RepositoryLFSStatusSnapshot {
        currentLFSStatusSnapshot
    }

    func showLFSDetails(_ snapshot: RepositoryLFSStatusSnapshot) {
        let sheet = RepositoryLFSDetailsSheet(snapshot: snapshot)
        sheet.present(for: window) { [weak self] downloadAll in
            guard downloadAll else { return }
            // The details sheet is still closing; the confirmation follows it.
            DispatchQueue.main.async { self?.downloadLFS(.all) }
        }
    }

    /// Downloads the Git LFS content of the menu item's represented paths that are not downloaded.
    @objc(downloadLFSContent:)
    func downloadLFSContent(_ sender: Any?) {
        downloadLFSContent(forSelectedPaths: (sender as? NSMenuItem)?.representedObject as? [String] ?? [])
    }

    func downloadLFSContent(forSelectedPaths selected: [String]) {
        let snapshot = lfsStatusSnapshot
        downloadLFS(.paths(LFSDownloadEligibility.paths(selected, summary: snapshot.summary, tool: snapshot.tool)))
    }

    func validateLFSDownload(_ menuItem: NSMenuItem) -> Bool {
        validateLFSDownload(menuItem, selectedPaths: menuItem.representedObject as? [String] ?? [])
    }

    /// Hides the item outside checkouts that use Git LFS; enables it when the selection holds content not downloaded.
    func validateLFSDownload(_ menuItem: NSMenuItem, selectedPaths selected: [String]) -> Bool {
        let snapshot = lfsStatusSnapshot
        menuItem.isHidden = !LFSDownloadEligibility.isOffered(summary: snapshot.summary)
        return !LFSDownloadEligibility.paths(selected, summary: snapshot.summary, tool: snapshot.tool).isEmpty
    }

    func downloadLFS(_ scope: LFSDownloadScope) {
        guard let repository else { return }
        if let active = activeLFSDownload, !active.phase.isFinal {
            lfsWindowLogger.notice("Ignored a Git LFS download request while one is running")
            return
        }
        let plan: LFSDownloadPlan
        switch LFSDownloadPlan.make(scope) {
        case let .success(made):
            plan = made
        case let .failure(issue):
            lfsWindowLogger.notice("Refused a Git LFS download: \(issue.message, privacy: .public)")
            let offersAll = issue != .noPaths
            presentLFSAlert(
                title: NSLocalizedString("The Git LFS content cannot be downloaded", comment: "Git LFS download refused"),
                message: issue.message,
                alternative: offersAll ? NSLocalizedString("Download All…", comment: "Git LFS download refused: download everything") : nil
            ) { [weak self] in
                // The refusal sheet is still closing; the confirmation follows it.
                DispatchQueue.main.async { self?.downloadLFS(.all) }
            }
            return
        }
        let confirmation = RepositoryLFSDownloadConfirmation.alert(for: plan, summary: lfsStatusSnapshot.summary)
        let start: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            // The confirmation sheet is still closing; the progress sheet follows it.
            DispatchQueue.main.async { self?.runLFSDownload(plan, repository: repository) }
        }
        if let window {
            confirmation.beginSheetModal(for: window, completionHandler: start)
        } else {
            start(confirmation.runModal())
        }
    }

    private func runLFSDownload(_ plan: LFSDownloadPlan, repository: PBGitRepository) {
        RepositoryLFSDownloadSheet().run(for: window, operation: { [weak self] update in
            let operation = RepositoryLFSDownloadOperation(repository: repository, plan: plan, update: update)
            self?.activeLFSDownload = operation
            return operation
        }) { [weak self] phase in
            guard let self else { return }
            activeLFSDownload = nil
            refreshAfterLFSDownload()
            switch phase {
            case .finished(.checkedOut):
                AccessibilityNotifier.announce(
                    NSLocalizedString("Git LFS content downloaded", comment: "Git LFS download: success announcement"),
                    from: window as Any
                )
            case .finished(.checkoutDeferred):
                presentLFSAlert(
                    title: NSLocalizedString("Downloaded; checkout deferred", comment: "Git LFS download: checkout deferred"),
                    message: NSLocalizedString(
                        "Half Dark downloaded the content but was quitting, so it did not write it into the working tree. "
                            + "Download it again to finish; nothing will be fetched twice.",
                        comment: "Git LFS download: checkout deferred explanation"
                    )
                )
            case let .failed(message):
                presentLFSAlert(
                    title: NSLocalizedString("The Git LFS download failed", comment: "Git LFS download failure"),
                    message: message
                )
            case .cancelled, .fetching, .finishing:
                break
            }
        }
    }

    /// A warning sheet; with an alternative, its first button runs `choose`.
    private func presentLFSAlert(title: String, message: String, alternative: String? = nil, choose: (() -> Void)? = nil) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        if let alternative {
            alert.addButton(withTitle: alternative).setAccessibilityIdentifier("GitX.LFS.Refused.DownloadAll")
            alert.addButton(withTitle: NSLocalizedString("Cancel", comment: "Git LFS download refused: cancel"))
        }
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            if alternative != nil, response == .alertFirstButtonReturn {
                choose?()
            }
        }
        if let window {
            alert.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(alert.runModal())
        }
    }
}
