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
            guard let path = relativePath(for: file) else { return nil }
            return workingDirectoryURL.appendingPathComponent(path)
        }
        logger.debug("Normalized selected workspace paths")
        return urls
    }

    private func relativePath(for file: Any) -> String? {
        if let path = file as? String {
            return path
        }
        guard let object = file as? NSObject, object.responds(to: NSSelectorFromString("path")) else { return nil }
        var path = object.value(forKey: "path") as? String
        if object.responds(to: NSSelectorFromString("rawPath")), let identity = object.value(forKey: "rawPath") {
            if object.responds(to: NSSelectorFromString("fullPath")) {
                path = object.value(forKey: "fullPath") as? String
            }
            guard let bytes = identity as? Data, !bytes.isEmpty, !bytes.contains(0),
                  let path, String(data: bytes, encoding: .utf8) == path, Data(path.utf8) == bytes
            else {
                logger.notice("Rejected workspace path with unavailable or mismatched raw filename identity")
                return nil
            }
            return path
        }
        return path
    }

    @objc(revealURLsFromRepresentedObject:)
    func revealURLs(from representedObject: Any?) -> [URL] {
        if let selected = selectedURLs(from: representedObject), !selected.isEmpty {
            return selected
        }
        return [repository.workingDirectoryURL() ?? repository.gitURL()].compactMap { $0 }
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

    @objc var hasWorkingDirectory: Bool {
        repository.workingDirectoryURL() != nil
    }

    @objc var hasRevealTarget: Bool {
        repository.workingDirectoryURL() != nil || repository.gitURL() != nil
    }

    @objc(openRepositoryInTerminal)
    func openRepositoryInTerminal() {
        guard let workingDirectoryURL = repository.workingDirectoryURL() else { return }
        logger.debug("Opening repository in terminal")
        TerminalLauncher.shared.open(directory: workingDirectoryURL, presenting: NSApp.keyWindow)
    }
}

// swiftlint:enable unused_declaration
