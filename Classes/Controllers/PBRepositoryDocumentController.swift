import AppKit
import ObjectiveGit

@objc(PBRepositoryDocumentController)
class PBRepositoryDocumentController: NSDocumentController {
    @objc dynamic class func newOpenPanel() -> NSOpenPanel {
        NSOpenPanel()
    }

    override func beginOpenPanel(
        _ openPanel: NSOpenPanel,
        forTypes _: [String]?,
        completionHandler: @escaping (Int) -> Void
    ) {
        openPanel.canChooseFiles = true
        openPanel.canChooseDirectories = true
        openPanel.perform(NSSelectorFromString("setAllowedFileTypes:"), with: ["git"])
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

        let repositoryURL = openPanel.url!
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
