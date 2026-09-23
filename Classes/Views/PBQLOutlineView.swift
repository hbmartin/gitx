import AppKit

// SwiftLint analyze misclassifies this import; Logger and privacy interpolation require it at compile time.
// swiftlint:disable:next unused_import
import OSLog
import UniformTypeIdentifiers

private nonisolated let quickLookFilePromiseLogger = Logger(
    subsystem: "com.gitx.gitx",
    category: "QuickLookFilePromise"
)

// swift6-safety-justification: The payload is immutable after construction and AppKit reads it only on the delegate's serial promise queue.
private final class QuickLookFilePromisePayload: NSObject, @unchecked Sendable {
    nonisolated let descriptor: QuickLookExportDescriptor

    init(descriptor: QuickLookExportDescriptor) {
        self.descriptor = descriptor
    }

    nonisolated var fileName: String {
        descriptor.fileName
    }
}

@objc(PBQLOutlineView)
// The Quick Look outline is instantiated by MainMenu.xib through its Objective-C runtime name.
// swiftlint:disable:next unused_declaration
class QuickLookOutlineView: NSOutlineView, NSOutlineViewDataSource, NSFilePromiseProviderDelegate {
    @IBOutlet weak var controller: PBGitHistoryController?

    private nonisolated let filePromiseQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "com.gitx.gitx.quick-look-file-promises"
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = 1
        return queue
    }()

    private nonisolated let filePromiseExporter = QuickLookFilePromiseExporter()

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
        let payload = QuickLookFilePromisePayload(descriptor: QuickLookExportDescriptor.make(tree: tree))
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

        do {
            try filePromiseExporter.export(payload.descriptor, to: url)
            completionHandler(nil)
        } catch {
            quickLookFilePromiseLogger.error(
                "Failed to export promised item to \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            completionHandler(error)
        }
    }

    nonisolated func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue {
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
