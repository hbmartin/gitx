import AppKit
import OSLog
import UniformTypeIdentifiers

private nonisolated let quickLookFilePromiseLogger = Logger(
    subsystem: "com.gitx.gitx",
    category: "QuickLookFilePromise"
)

private final class QuickLookFilePromisePayload: NSObject, @unchecked Sendable {
    /// AppKit invokes promise writes on the delegate's operation queue. The tree
    /// is immutable for the lifetime of a drag and is retained by this payload.
    nonisolated(unsafe) let tree: PBGitTree

    init(tree: PBGitTree) {
        self.tree = tree
    }

    nonisolated var fileName: String {
        (tree.path as NSString).lastPathComponent
    }
}

@objc(PBQLOutlineView)
class QuickLookOutlineView: NSOutlineView, NSOutlineViewDataSource, NSFilePromiseProviderDelegate {
    @IBOutlet weak var controller: PBGitHistoryController?

    private let filePromiseQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "com.gitx.gitx.quick-look-file-promises"
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = 1
        return queue
    }()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        dataSource = self
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        dataSource = self
    }

    override func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        .copy
    }

    override func keyDown(with event: NSEvent) {
        if event.characters == " " {
            guard let controller else { return }
            controller.toggleQLPreviewPanel(self)
            return
        }
        super.keyDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        if event.type == .rightMouseDown {
            let row = row(at: convert(event.locationInWindow, from: nil))
            if row >= 0, !selectedRowIndexes.contains(row) {
                selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            }
        }
        return controller?.contextMenuForTreeView()
    }

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        guard let tree = (item as? NSTreeNode)?.representedObject as? PBGitTree else { return nil }
        let payload = QuickLookFilePromisePayload(tree: tree)
        let provider = NSFilePromiseProvider(fileType: promisedFileType(for: tree), delegate: self)
        provider.userInfo = payload
        return provider
    }

    func filePromiseProvider(
        _ filePromiseProvider: NSFilePromiseProvider,
        fileNameForType fileType: String
    ) -> String {
        payload(for: filePromiseProvider)?.fileName ?? "GitX Export"
    }

    nonisolated func filePromiseProvider(
        _ filePromiseProvider: NSFilePromiseProvider,
        writePromiseTo url: URL,
        completionHandler: @escaping @Sendable (Error?) -> Void
    ) {
        guard let payload = filePromiseProvider.userInfo as? QuickLookFilePromisePayload else {
            quickLookFilePromiseLogger.error("Rejected a Quick Look file promise without repository-tree state")
            completionHandler(NSError(
                domain: NSCocoaErrorDomain,
                code: NSFileWriteUnknownError,
                userInfo: [NSLocalizedDescriptionKey: "GitX could not identify the promised repository item."]
            ))
            return
        }

        let fileManager = FileManager.default
        let stagingURL = url.deletingLastPathComponent()
            .appendingPathComponent(".gitx-file-promise-\(UUID().uuidString)", isDirectory: true)
        do {
            try fileManager.createDirectory(at: stagingURL, withIntermediateDirectories: false)
            defer { try? fileManager.removeItem(at: stagingURL) }

            payload.tree.save(toFolder: stagingURL.path)
            let stagedOutputURL = stagingURL.appendingPathComponent(payload.tree.path)
            guard fileManager.fileExists(atPath: stagedOutputURL.path) else {
                throw NSError(
                    domain: NSCocoaErrorDomain,
                    code: NSFileNoSuchFileError,
                    userInfo: [
                        NSFilePathErrorKey: stagedOutputURL.path,
                        NSLocalizedDescriptionKey: "GitX did not produce the promised file \(payload.fileName).",
                    ]
                )
            }
            try fileManager.moveItem(at: stagedOutputURL, to: url)
            quickLookFilePromiseLogger.info("Exported promised item to \(url.path, privacy: .public)")
            completionHandler(nil)
        } catch {
            try? fileManager.removeItem(at: stagingURL)
            quickLookFilePromiseLogger.error(
                "Failed to export promised item to \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            completionHandler(error)
        }
    }

    func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue {
        filePromiseQueue
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        false
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        NSNull()
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        objectValueFor tableColumn: NSTableColumn?,
        byItem item: Any?
    ) -> Any? {
        nil
    }

    private func promisedFileType(for tree: PBGitTree) -> String {
        guard tree.leaf else { return UTType.directory.identifier }
        let pathExtension = (tree.path as NSString).pathExtension
        guard !pathExtension.isEmpty else { return UTType.data.identifier }
        // UniformTypeIdentifiers synthesizes a dynamic type for every nonempty filename extension.
        return UTType(filenameExtension: pathExtension)!.identifier
    }

    private func payload(for provider: NSFilePromiseProvider) -> QuickLookFilePromisePayload? {
        provider.userInfo as? QuickLookFilePromisePayload
    }
}
