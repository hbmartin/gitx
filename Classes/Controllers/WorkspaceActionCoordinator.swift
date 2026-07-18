import OSLog // swiftlint:disable:this unused_import

// Objective-C actions call this through GitX-Swift.h.
// swiftlint:disable unused_declaration
@objc(PBWorkspaceActionCoordinator)
final class WorkspaceActionCoordinator: NSObject {
    private unowned let repository: PBGitRepository
    private let logger = Logger(subsystem: "com.gitx.gitx", category: "WorkspaceActionCoordinator")

    @objc(initWithRepository:)
    init(repository: PBGitRepository) {
        self.repository = repository
        super.init()
    }

    @objc(selectedURLsFromRepresentedObject:)
    func selectedURLs(from representedObject: Any?) -> [URL]? {
        guard let selectedFiles = representedObject as? [Any], !selectedFiles.isEmpty,
              let workingDirectoryURL = repository.workingDirectoryURL() else { return nil }
        let urls = selectedFiles.compactMap { file -> URL? in
            let path: Any?
            if let string = file as? String {
                path = string
            } else if let object = file as? NSObject, object.responds(to: NSSelectorFromString("path")) {
                path = object.value(forKey: "path")
            } else {
                path = nil
            }
            guard let path = path as? String else { return nil }
            return workingDirectoryURL.appendingPathComponent(path)
        }
        logger.debug("Normalized selected workspace paths")
        return urls
    }

    @objc(openURLs:)
    func open(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        logger.debug("Opening selected workspace paths")
        var ordinaryURLs: [URL] = []
        for url in urls {
            guard let submodule = try? repository.submodule(atPath: url.path) else {
                ordinaryURLs.append(url)
                continue
            }
            guard let parentURL = submodule.parentRepository.fileURL else {
                ordinaryURLs.append(url)
                continue
            }
            let submoduleURL = parentURL.appendingPathComponent(submodule.path, isDirectory: true)
            RepositoryOpenCoordinator.shared.openKnownRepositories(
                urls: [submoduleURL],
                sourceWindow: NSApp.keyWindow
            ) { _, _ in }
        }

        let configuration = NSWorkspace.OpenConfiguration()
        for url in ordinaryURLs {
            NSWorkspace.shared.open(url, configuration: configuration) { [logger] _, error in
                if error != nil {
                    logger.error("Workspace path open failed")
                }
            }
        }
    }

    @objc(revealURLsInFinder:)
    func revealInFinder(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        logger.debug("Revealing workspace paths in Finder")
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    @objc(openRepositoryInTerminal)
    func openRepositoryInTerminal() {
        guard let workingDirectoryURL = repository.workingDirectoryURL() else { return }
        logger.debug("Opening repository in terminal")
        TerminalLauncher.shared.open(directory: workingDirectoryURL, presenting: NSApp.keyWindow)
    }
}

// swiftlint:enable unused_declaration
