import AppKit
import Foundation

// SwiftLint analyze misclassifies this import; Logger requires it at compile time.
// swiftlint:disable:next unused_import
import OSLog

private enum MultiCommitDiffPresentation: Int {
    case sequential
    case combined
}

/// Serializes the generation fence and active task exactly as the former
/// `@synchronized(self)` regions did.
// swift6-safety-justification: Every access to the non-Sendable PBTask and generation is serialized by the private lock.
private final nonisolated class WebHistoryRenderState: @unchecked Sendable {
    private let lock = NSLock()
    private var storedGeneration: UInt = 0
    private var storedActiveTask: PBTask?
    private weak var storedRepository: PBGitRepository?

    var generation: UInt {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storedGeneration
        }
        set {
            lock.lock()
            storedGeneration = newValue
            lock.unlock()
        }
    }

    var activeTask: PBTask? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storedActiveTask
        }
        set {
            lock.lock()
            storedActiveTask = newValue
            lock.unlock()
        }
    }

    var repository: PBGitRepository? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storedRepository
        }
        set {
            lock.lock()
            storedRepository = newValue
            lock.unlock()
        }
    }

    func isCurrent(_ generation: UInt) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return generation == storedGeneration
    }

    func beginGeneration() -> (generation: UInt, cancelledTask: PBTask?) {
        lock.lock()
        storedGeneration &+= 1
        let task = storedActiveTask
        storedActiveTask = nil
        let generation = storedGeneration
        lock.unlock()
        return (generation, task)
    }

    func install(_ task: PBTask, for generation: UInt) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard generation == storedGeneration else { return false }
        storedActiveTask = task
        return true
    }

    func clear(_ task: PBTask) {
        lock.lock()
        if storedActiveTask === task {
            storedActiveTask = nil
        }
        lock.unlock()
    }
}

/// An immutable snapshot captured before rendering leaves the main thread.
// swift6-safety-justification: The heterogeneous dictionaries contain only immutable Foundation value snapshots and are never mutated after capture.
private nonisolated struct WebHistoryRenderRequest: @unchecked Sendable {
    let inputs: [CommitRenderInput]
    let imageSources: [[String: Any]]
    let generation: UInt
    let requestedMode: MultiCommitDiffPresentation
    let selectedLayout: Int
}

/// Transfers immutable render output back to the main queue.
// swift6-safety-justification: Sections are newly-created immutable Foundation dictionaries and are not mutated after publication.
private nonisolated struct WebHistoryRenderDelivery: @unchecked Sendable {
    let sections: [[String: Any]]
    let combinedEnabled: Bool
    let mode: MultiCommitDiffPresentation
    let requestedMode: MultiCommitDiffPresentation
    let generation: UInt
}

/// Owns the history diff surface while preserving the Objective-C runtime,
/// nib, responder-chain, queue, cancellation, and delegate contracts.
@objc(PBWebHistoryController)
open class PBWebHistoryController: PBWebController, PBNativeContentViewDelegate {
    private nonisolated static let logger = Logger(subsystem: "com.gitx.gitx", category: "HistoryDiff")
    private nonisolated static let multiCommitDiffPresentationKey = "PBMultiCommitDiffPresentation"
    private nonisolated static let emptyTreeSHA = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"

    @IBOutlet @objc private dynamic weak var historyController: PBGitHistoryController?

    @objc open private(set) dynamic var diff: String?

    @objc private dynamic var presentationControl: NSSegmentedControl?
    @objc private dynamic var layoutControl: NSSegmentedControl?
    @objc private dynamic var displayedCommits: [PBGitCommit] = []
    @objc private dynamic var renderQueue: DispatchQueue?
    private var webCommitsObservation: NSKeyValueObservation?
    private nonisolated let renderState = WebHistoryRenderState()

    /// These computed properties retain the private KVC surface used by the
    /// conversion characterization tests and by legacy debugging tools.
    @objc private dynamic var contentGeneration: UInt {
        get { renderState.generation }
        set { renderState.generation = newValue }
    }

    @objc private dynamic var activeTask: PBTask? {
        get { renderState.activeTask }
        set { renderState.activeTask = newValue }
    }

    override public nonisolated init() {
        super.init()
    }

    override open nonisolated func awakeFromNib() {
        // swift6-safety-justification: AppKit invokes awakeFromNib on the main thread while loading this controller's XIB.
        MainActor.assumeIsolated {
            repository = historyController?.repository
        }
        super.awakeFromNib()
        // swift6-safety-justification: AppKit invokes awakeFromNib on the main thread while loading this controller's XIB.
        MainActor.assumeIsolated {
            finishAwakingFromNib()
        }
    }

    private func finishAwakingFromNib() {
        nativeView.delegate = self
        renderQueue = DispatchQueue(label: "com.gitx.history-render")

        let presentationControl = NSSegmentedControl(
            labels: ["Sequential", "Combined"],
            trackingMode: .selectOne,
            target: self,
            action: #selector(presentationChanged(_:))
        )
        presentationControl.controlSize = .small
        presentationControl.setAccessibilityIdentifier("MultiCommitDiffPresentation")
        presentationControl.selectedSegment = UserDefaults.standard.integer(
            forKey: Self.multiCommitDiffPresentationKey
        )
        self.presentationControl = presentationControl

        let layoutControl = NSSegmentedControl(
            labels: ["Unified", "Side by Side"],
            trackingMode: .selectOne,
            target: self,
            action: #selector(layoutChanged(_:))
        )
        layoutControl.controlSize = .small
        layoutControl.setAccessibilityIdentifier("DiffLayout")
        layoutControl.selectedSegment = ApplicationSettings.diffLayout.rawValue
        self.layoutControl = layoutControl

        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 32))
        accessory.translatesAutoresizingMaskIntoConstraints = false
        presentationControl.translatesAutoresizingMaskIntoConstraints = false
        layoutControl.translatesAutoresizingMaskIntoConstraints = false
        let controls = NSStackView(views: [layoutControl, presentationControl])
        controls.orientation = .horizontal
        controls.spacing = 18
        controls.alignment = .centerY
        controls.translatesAutoresizingMaskIntoConstraints = false
        accessory.addSubview(controls)
        NSLayoutConstraint.activate([
            accessory.heightAnchor.constraint(equalToConstant: 32),
            controls.centerXAnchor.constraint(equalTo: accessory.centerXAnchor),
            controls.centerYAnchor.constraint(equalTo: accessory.centerYAnchor),
        ])
        nativeView.setAccessory(accessory)
        presentationControl.isHidden = true

        if let historyController {
            webCommitsObservation = historyController.observe(\.webCommits, options: []) { [weak self] controller, _ in
                Self.performCommitObservationOnMain { [weak self, weak controller] in
                    guard let self, let controller else { return }
                    changeContent(to: controller.webCommits)
                }
            }
        }
        Self.logger.debug("Installed history diff controls and commit observation")
    }

    private nonisolated static func performCommitObservationOnMain(
        _ body: @escaping @MainActor @Sendable () -> Void
    ) {
        if Thread.isMainThread {
            // swift6-safety-justification: The main-thread check proves synchronous execution is on AppKit's MainActor executor.
            MainActor.assumeIsolated(body)
        } else {
            DispatchQueue.main.async(execute: body)
        }
    }

    override open nonisolated func didLoad() {
        // swift6-safety-justification: PBWebController dispatches didLoad to the main queue after installing its native view.
        MainActor.assumeIsolated {
            changeContent(to: historyController?.webCommits ?? [])
        }
    }

    @objc(oldestFirst:)
    dynamic func oldestFirst(_ commits: [PBGitCommit]) -> [PBGitCommit] {
        // NSArrayController supplies visible newest-first graph order. Reverse
        // that order instead of sorting by authored date so topology wins.
        Array(commits.reversed())
    }

    private func renderInput(for commit: PBGitCommit) -> CommitRenderInput {
        dispatchPrecondition(condition: .onQueue(.main))
        return CommitRenderInput(
            sha: commit.sha,
            parentSHA: commit.parents.first?.sha,
            shortName: commit.shortName(),
            subject: commit.subject,
            author: commit.author,
            authorDate: commit.authorDate
        )
    }

    @objc(renderInputsForCommits:)
    dynamic func renderInputs(for commits: [PBGitCommit]) -> [CommitRenderInput] {
        commits.map(renderInput(for:))
    }

    @objc(imageSourceForRevisions:workingTree:)
    dynamic func imageSource(forRevisions revisions: [String], workingTree: Bool) -> [String: Any] {
        dispatchPrecondition(condition: .onQueue(.main))
        let currentRepository = historyController?.repository
        var source: [String: Any] = [
            PBNativeImageSourceRevisionsKey: revisions,
            PBNativeImageSourceWorkingTreeKey: workingTree,
        ]
        if let workingDirectoryURL = currentRepository?.workingDirectoryURL() {
            source[PBNativeImageSourceWorkingTreeURLKey] = workingDirectoryURL
        }
        if let launchPath = PBGitBinary.path() {
            source[PBNativeImageSourceGitLaunchPathKey] = launchPath
        }
        if let gitDirectory = currentRepository?.gitURL()?.path {
            source[PBNativeImageSourceGitDirectoryKey] = gitDirectory
        }
        if let taskDirectory = currentRepository?.workingDirectory() {
            source[PBNativeImageSourceTaskDirectoryKey] = taskDirectory
        }
        return source
    }

    @objc(isGenerationCurrent:)
    dynamic nonisolated func isGenerationCurrent(_ generation: UInt) -> Bool {
        renderState.isCurrent(generation)
    }

    @objc dynamic func beginContentGeneration() -> UInt {
        renderState.repository = historyController?.repository
        let result = renderState.beginGeneration()
        result.cancelledTask?.terminate()
        if result.cancelledTask != nil {
            Self.logger.debug("Cancelled superseded history diff task")
        }
        return result.generation
    }

    @objc(runGitArguments:generation:error:)
    dynamic nonisolated func runGit(
        arguments: [String],
        generation: UInt,
        error errorPointer: AutoreleasingUnsafeMutablePointer<NSError?>?
    ) -> String? {
        guard let task = renderState.repository?.task(withArguments: arguments) else {
            return nil
        }
        task.timeout = 2 * 60
        guard renderState.install(task, for: generation) else {
            Self.logger.debug("Discarded Git work for a stale history diff generation")
            return nil
        }

        let success: Bool
        do {
            try task.launch()
            success = true
        } catch {
            errorPointer?.pointee = error as NSError
            success = false
            Self.logger.error("Git command failed while rendering history diff")
        }
        renderState.clear(task)
        guard success, isGenerationCurrent(generation) else { return nil }
        return task.standardOutputString() ?? ""
    }

    private nonisolated func diff(for input: CommitRenderInput, generation: UInt) -> String {
        let base = input.parentSHA ?? Self.emptyTreeSHA
        return runGit(
            arguments: diffArguments(withTail: ["--find-renames", "--no-ext-diff", base, input.sha]),
            generation: generation,
            error: nil
        ) ?? ""
    }

    @objc(diffArgumentsWithTail:)
    dynamic nonisolated func diffArguments(withTail tail: [String]) -> [String] {
        ["diff"] + DiffCommandOptions.arguments + tail
    }

    @objc(inputsShareAncestryPath:generation:)
    dynamic nonisolated func inputsShareAncestryPath(_ inputs: [CommitRenderInput], generation: UInt) -> Bool {
        guard inputs.count > 1 else { return true }
        for index in 1 ..< inputs.count {
            let oldSHA = inputs[index - 1].sha
            let newSHA = inputs[index].sha
            let range = "\(oldSHA)..\(newSHA)"
            guard let lineage = runGit(
                arguments: ["rev-list", "--first-parent", "--parents", range],
                generation: generation,
                error: nil
            ), isGenerationCurrent(generation) else { return false }
            let oldestLine = lineage
                .components(separatedBy: .newlines)
                .reversed()
                .first(where: { !$0.isEmpty })
            let nonempty = oldestLine?
                .components(separatedBy: .whitespaces)
                .filter { !$0.isEmpty } ?? []
            guard nonempty.count >= 2, nonempty[1] == oldSHA else { return false }
        }
        return true
    }

    @objc(sequentialSectionsForInputs:imageSources:generation:)
    dynamic nonisolated func sequentialSections(
        for inputs: [CommitRenderInput],
        imageSources: [[String: Any]],
        generation: UInt
    ) -> [[String: Any]]? {
        var sections: [[String: Any]] = []
        sections.reserveCapacity(inputs.count)
        for (index, input) in inputs.enumerated() {
            guard isGenerationCurrent(generation) else { return nil }
            sections.append([
                PBNativeSectionTitleKey: input.title,
                PBNativeSectionTextKey: diff(for: input, generation: generation),
                PBNativeSectionContextKey: "readOnly",
                PBNativeSectionImageSourceKey: imageSources[index],
            ])
        }
        return isGenerationCurrent(generation) ? sections : nil
    }

    @objc(combinedSectionsForInputs:imageSource:generation:)
    dynamic nonisolated func combinedSections(
        for inputs: [CommitRenderInput],
        imageSource: [String: Any],
        generation: UInt
    ) -> [[String: Any]]? {
        guard let oldest = inputs.first, let newest = inputs.last else { return nil }
        let base = oldest.parentSHA ?? Self.emptyTreeSHA
        guard let combined = runGit(
            arguments: diffArguments(withTail: ["--find-renames", "--no-ext-diff", base, newest.sha]),
            generation: generation,
            error: nil
        ), isGenerationCurrent(generation) else { return nil }
        return [[
            PBNativeSectionTitleKey: "Combined Diff — \(oldest.shortName) through \(newest.shortName)",
            PBNativeSectionTextKey: combined,
            PBNativeSectionContextKey: "readOnly",
            PBNativeSectionImageSourceKey: imageSource,
        ]]
    }

    @objc(changeContentTo:)
    dynamic func changeContent(to commits: [PBGitCommit]) {
        let requestedCommits = commits
        let generation = beginContentGeneration()
        displayedCommits = requestedCommits
        presentationControl?.isHidden = requestedCommits.count <= 1
        let selectedLayout = layoutControl?.selectedSegment ?? 0
        guard !requestedCommits.isEmpty else {
            diff = ""
            nativeView.showMessage("No commit selected")
            Self.logger.debug("Cleared history diff because no commit is selected")
            return
        }

        // The Uncommitted Changes row is presented by the staging pane, so
        // this controller renders immutable commits only.
        let inputs = renderInputs(for: oldestFirst(requestedCommits))
        let imageSources = inputs.map {
            imageSource(forRevisions: $0.imageRevisions, workingTree: false)
        }
        let requestedMode: MultiCommitDiffPresentation = presentationControl?.selectedSegment ==
            MultiCommitDiffPresentation.combined.rawValue ? .combined : .sequential
        let request = WebHistoryRenderRequest(
            inputs: inputs,
            imageSources: imageSources,
            generation: generation,
            requestedMode: requestedMode,
            selectedLayout: selectedLayout
        )
        nativeView.showMessage("Loading diff…")
        Self.logger.debug("Scheduled history diff rendering")
        renderQueue!.async { [self, request] in
            let combinedEnabled = request.inputs.count > 1 && inputsShareAncestryPath(
                request.inputs,
                generation: request.generation
            )
            guard isGenerationCurrent(request.generation) else { return }
            let mode = request.requestedMode == .combined && !combinedEnabled
                ? .sequential
                : request.requestedMode
            let generatedSections = mode == .combined
                ? combinedSections(
                    for: request.inputs,
                    imageSource: request.imageSources.last!,
                    generation: request.generation
                )
                : sequentialSections(
                    for: request.inputs,
                    imageSources: request.imageSources,
                    generation: request.generation
                )
            let decoratedSections = sections(
                generatedSections ?? [],
                applyingDiffLayout: request.selectedLayout
            )
            guard isGenerationCurrent(request.generation) else { return }
            let delivery = WebHistoryRenderDelivery(
                sections: decoratedSections,
                combinedEnabled: combinedEnabled,
                mode: mode,
                requestedMode: request.requestedMode,
                generation: request.generation
            )
            DispatchQueue.main.async { [self, delivery] in
                guard isGenerationCurrent(delivery.generation) else { return }
                presentationControl?.setEnabled(
                    delivery.combinedEnabled,
                    forSegment: MultiCommitDiffPresentation.combined.rawValue
                )
                presentationControl?.selectedSegment = delivery.mode.rawValue
                presentationControl?.toolTip = delivery.requestedMode == .combined && !delivery.combinedEnabled
                    ? NSLocalizedString(
                        "Combined Diff requires commits on one ancestry path.",
                        comment: "Explanation shown when selected commits cannot produce one combined diff"
                    )
                    : nil
                diff = delivery.sections
                    .compactMap { $0[PBNativeSectionTextKey] as? String }
                    .joined(separator: "\n")
                nativeView.showDiffSections(delivery.sections)
                Self.logger.debug("Installed history diff rendering")
            }
        }
    }

    override open nonisolated func closeView() {
        // swift6-safety-justification: PBWebController closeView is an AppKit lifecycle entry point called on the main thread.
        MainActor.assumeIsolated {
            _ = beginContentGeneration()
        }
        super.closeView()
    }

    @objc(sections:applyingDiffLayout:)
    dynamic nonisolated func sections(
        _ sections: [[String: Any]],
        applyingDiffLayout layout: Int
    ) -> [[String: Any]] {
        let configuredPatterns: String
        if let repository = renderState.repository {
            configuredPatterns = RepositorySettingsStore(repository: repository)
                .string(forKey: "gitx.diffSuppressionPatterns")
        } else {
            configuredPatterns = ""
        }
        let patterns = configuredPatterns
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        return sections.map { section in
            var copy = section
            copy[PBNativeSectionDiffLayoutKey] = layout
            copy[PBNativeSectionSuppressionPatternsKey] = patterns
            return copy
        }
    }

    @objc(dataForGitObject:imageSource:)
    dynamic nonisolated func data(forGitObject object: String, imageSource: [String: Any]) -> Data? {
        guard let launchPath = imageSource[PBNativeImageSourceGitLaunchPathKey] as? String,
              !launchPath.isEmpty,
              let gitDirectory = imageSource[PBNativeImageSourceGitDirectoryKey] as? String,
              !gitDirectory.isEmpty
        else { return nil }
        let arguments = ["--git-dir=\(gitDirectory)", "show", object]
        let task = PBTask(
            launchPath: launchPath,
            arguments: arguments,
            inDirectory: imageSource[PBNativeImageSourceTaskDirectoryKey] as? String
        )
        do {
            try task.launch()
        } catch {
            Self.logger.error("Git object data load failed")
            return nil
        }
        return task.standardOutputData
    }

    public func nativeContentView(
        _ view: PBNativeContentView,
        imageDataForPath path: String,
        section sectionIndex: UInt,
        imageSource: [String: Any]
    ) -> Data? {
        if imageSource[PBNativeImageSourceWorkingTreeKey] as? Bool == true,
           let workingTreeURL = imageSource[PBNativeImageSourceWorkingTreeURLKey] as? URL,
           let data = try? Data(contentsOf: workingTreeURL.appendingPathComponent(path)),
           !data.isEmpty
        {
            return data
        }
        for revision in imageSource[PBNativeImageSourceRevisionsKey] as? [String] ?? [] {
            let object = revision == ":" ? ":\(path)" : "\(revision):\(path)"
            if let data = data(forGitObject: object, imageSource: imageSource), !data.isEmpty {
                return data
            }
        }
        return nil
    }

    @objc dynamic func presentationChanged(_ sender: NSSegmentedControl) {
        UserDefaults.standard.set(sender.selectedSegment, forKey: Self.multiCommitDiffPresentationKey)
        changeContent(to: displayedCommits)
    }

    @objc dynamic func layoutChanged(_ sender: NSSegmentedControl) {
        let layout = sender.selectedSegment == DiffLayout.sideBySide.rawValue
            ? "side-by-side"
            : "unified"
        Self.logger.info("Changed per-window diff layout to \(layout, privacy: .public)")
        changeContent(to: displayedCommits)
    }

    @objc open dynamic func refreshDisplayedContent() {
        changeContent(to: displayedCommits)
    }

    public func nativeContentView(_ view: PBNativeContentView, selectCommit sha: String) {
        historyController?.selectCommit(GTOID(sha: sha))
    }

    @objc open dynamic func sendKey(_ key: String) {
        if key == "j" {
            nativeView.textView.scrollLineDown(self)
        } else if key == "k" {
            nativeView.textView.scrollLineUp(self)
        }
    }

    @objc open dynamic func scrollPageUp() {
        nativeView.scrollPageUp()
    }

    @objc open dynamic func scrollPageDown() {
        nativeView.scrollPageDown()
    }

    override open nonisolated func preferencesChanged() {
        // swift6-safety-justification: PBWebController delivers preferences changes through the main-thread AppKit notification center.
        MainActor.assumeIsolated {
            changeContent(to: displayedCommits)
        }
    }
}
