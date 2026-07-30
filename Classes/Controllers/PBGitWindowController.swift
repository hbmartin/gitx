import AppKit
import ForgeKit

/// Owns the repository window's AppKit wiring while routing decisions to focused coordinators.
@objc(PBGitWindowController)
open class PBGitWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation { // swiftlint:disable:this type_body_length
    @objc private dynamic var _sidebarController: PBGitSidebarController? // swiftlint:disable:this identifier_name
    @objc private dynamic var _sidebarViewController: PBGitSidebarController? // swiftlint:disable:this identifier_name
    @objc private dynamic var _historyViewController: PBGitHistoryController? // swiftlint:disable:this identifier_name
    @objc private dynamic weak var contentController: PBViewController?

    private var explicitlyAssignedRepository: PBGitRepository?
    private var focusRefreshCoordinator: RepositoryFocusRefreshCoordinator?
    private var actionContextResolver: RepositoryActionContextResolver?
    private var remoteActionCoordinator: RepositoryRemoteActionCoordinator?
    private var referenceActionCoordinator: RepositoryReferenceActionCoordinator?
    private var stashActionCoordinator: RepositoryStashActionCoordinator?
    private var workspaceActionCoordinator: WorkspaceActionCoordinator?
    private var repositoryForgeCoordinator: RepositoryForgeCoordinator?
    final var repositoryForgeLinkUseCase: RepositoryForgeLinkUseCase?
    private var repositoryToolbarController: RepositoryToolbarController?
    private var repositoryStatusBarController: RepositoryStatusBarController?
    private(set) final var repositoryForgeOverlaySession: RepositoryForgeOverlaySession?
    private var repositoryLocalStatusLoader: RepositoryLocalStatusLoader?
    private var repositoryLocalStatusSnapshot = RepositoryLocalStatusSnapshot.unavailable
    private var initializedContentControllers: NSHashTable<PBViewController>?
    private var contentStatusObservation: NSKeyValueObservation?

    @IBOutlet private weak var sourceListControlsView: NSView?
    @IBOutlet private weak var splitView: NSSplitView? // swiftlint:disable:this unused_declaration
    @IBOutlet private weak var sourceSplitView: NSView?
    @IBOutlet private weak var contentSplitView: NSView?
    @IBOutlet private weak var statusField: NSTextField?
    @IBOutlet private weak var progressIndicator: NSProgressIndicator?
    @IBOutlet private weak var jumpToCheckedOutBranchButton: NSButton?

    @objc public convenience init() {
        self.init(windowNibName: "RepositoryWindow")
    }

    /// Retain the historical setter surface while continuing to derive the active repository from the document.
    @objc open dynamic var repository: PBGitRepository? {
        get { (document as? PBGitRepositoryDocument)?.repository }
        set { explicitlyAssignedRepository = newValue }
    }

    @objc dynamic var historyViewController: PBGitHistoryController? {
        _historyViewController
    }

    @objc dynamic var sidebarViewController: PBGitSidebarController? {
        _sidebarViewController
    }

    private func ensureActionCoordinators() {
        guard let repository else { return }
        if actionContextResolver == nil {
            actionContextResolver = RepositoryActionContextResolver()
        }
        if remoteActionCoordinator == nil {
            remoteActionCoordinator = RepositoryRemoteActionCoordinator(
                repository: repository,
                windowController: self
            )
        }
        if referenceActionCoordinator == nil {
            referenceActionCoordinator = RepositoryReferenceActionCoordinator(
                repository: repository,
                windowController: self
            )
        }
        if stashActionCoordinator == nil {
            stashActionCoordinator = RepositoryStashActionCoordinator(
                repository: repository,
                windowController: self
            )
        }
        if workspaceActionCoordinator == nil {
            workspaceActionCoordinator = WorkspaceActionCoordinator(repository: repository)
        }
    }

    private func ensureFocusRefreshCoordinator() {
        guard focusRefreshCoordinator == nil, let repository else { return }
        focusRefreshCoordinator = RepositoryFocusRefreshCoordinator(
            repository: repository,
            gitExecutablePath: PBGitBinary.path()
        ) { [weak self] in
            guard let self else { return }
            self.refreshLocalRepositoryContent()
        }
    }

    override open func synchronizeWindowTitleWithDocumentName() {
        super.synchronizeWindowTitleWithDocumentName()
        if isWindowLoaded {
            window?.representedURL = repository?.workingDirectoryURL()
        }
    }

    @objc public dynamic func windowWillClose(_ notification: Notification) {
        NotificationCenter.default.removeObserver(self)
        focusRefreshCoordinator?.cancel()
        sidebarViewController?.closeView()
        historyViewController?.closeView()
        _sidebarController = nil
        _historyViewController = nil
        repositoryForgeCoordinator = nil
        repositoryForgeLinkUseCase = nil
        repositoryStatusBarController?.invalidate()
        repositoryForgeOverlaySession?.invalidate()
        repositoryLocalStatusLoader?.cancel()
        repositoryStatusBarController = nil
        repositoryForgeOverlaySession = nil
        repositoryLocalStatusLoader = nil
        repositoryToolbarController = nil
        WelcomeWindowController.shared.showIfNeededAfterDelay()
    }

    @objc public dynamic func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if let action = RepositoryForgeLinkAction(selector: menuItem.action),
           let model = RepositoryForgeLinkMenuPresenter.itemModel(action: action, context: forgeLinkContext)
        {
            RepositoryForgeLinkMenuPresenter.apply(model: model, to: menuItem)
            return model.isEnabled
        }
        if menuItem.action == #selector(revealInFinder(_:)) || menuItem.action == #selector(openInTerminal(_:)) {
            ensureActionCoordinators()
            return workspaceActionCoordinator?.hasWorkingDirectory == true
        }
        if menuItem.action == #selector(showUncommittedChanges(_:)) {
            menuItem.state = isUncommittedChangesSelected ? .on : .off
            return repository?.isBare() != true
        }
        if menuItem.action == #selector(showHistoryView(_:)) {
            menuItem.state = isUncommittedChangesSelected ? .off : .on
            return repository?.isBare() != true
        }
        if menuItem.action == #selector(toggleAmendCommit(_:)) {
            menuItem.state = repository?.index.isAmend == true ? .on : .off
            return repository?.isBare() != true
        }
        if menuItem.action == #selector(toggleRepositoryStatusBar(_:)) {
            menuItem.state = ApplicationSettings.repositoryStatusBarVisible ? .on : .off
            return true
        }
        if menuItem.action == #selector(fetchRemote(_:)) {
            return validateMenuItem(menuItem, remoteTitle: "Fetch “%@”", plainTitle: "Fetch")
        }
        if menuItem.action == #selector(showRepositorySettings(_:)) {
            return repository != nil
        }
        if menuItem.action == #selector(pullRemote(_:)) {
            return validateMenuItem(menuItem, remoteTitle: "Pull From “%@”", plainTitle: "Pull")
        }
        if menuItem.action == #selector(pullRebaseRemote(_:)) {
            return validateMenuItem(
                menuItem,
                remoteTitle: "Pull From “%@” and Rebase",
                plainTitle: "Pull and Rebase"
            )
        }
        return true
    }

    final var forgeLinkContext: RepositoryForgeLinkContext {
        let resolution = forgeCoordinator?.resolveBinding()
        let headRef = repository?.headRef()?.ref()
        let checkedOutRevision: RepositoryForgeLinkRevision?
        if let headRef, headRef.isBranch, let branchName = headRef.branchName {
            checkedOutRevision = .branch(branchName)
        } else if let identifier = repository?.headOID()?.sha {
            checkedOutRevision = .commit(identifier)
        } else {
            checkedOutRevision = nil
        }
        let selectedCommitIdentifiers = (_historyViewController?.selectedCommits ?? []).compactMap { commit in
            commit is PBUncommittedChanges ? nil : commit.sha
        }
        return RepositoryForgeLinkContext(
            providerName: resolution?.providerName,
            isForgeAvailable: resolution?.binding != nil || resolution?.candidates.isEmpty == false,
            checkedOutRevision: checkedOutRevision,
            selectedCommitIdentifiers: selectedCommitIdentifiers
        )
    }

    final var forgeCoordinator: RepositoryForgeCoordinator? {
        if repositoryForgeCoordinator == nil, let repository {
            let coordinator = RepositoryForgeCoordinator(repository: repository)
            repositoryForgeCoordinator = coordinator
            repositoryForgeLinkUseCase = RepositoryForgeLinkUseCase(
                coordinator: coordinator,
                windowController: self
            )
        }
        return repositoryForgeCoordinator
    }

    final var forgeLinkUseCase: RepositoryForgeLinkUseCase? {
        _ = forgeCoordinator
        return repositoryForgeLinkUseCase
    }

    @objc(validateMenuItem:remoteTitle:plainTitle:)
    dynamic func validateMenuItem(_ menuItem: NSMenuItem, remoteTitle: String, plainTitle: String) -> Bool {
        guard let repository, let ref = selectedRef else { return false }
        let remoteRef = try? repository.remoteRef(forBranch: ref)
        if ref.isRemote || remoteRef != nil {
            let displayRef: PBGitRef
            if let remoteRef {
                displayRef = remoteRef
            } else {
                displayRef = ref
            }
            let remoteName: String
            if let name = displayRef.remoteName {
                remoteName = name
            } else {
                remoteName = "(null)"
            }
            menuItem.title = String(format: NSLocalizedString(remoteTitle, comment: ""), remoteName)
            menuItem.representedObject = ref
            return true
        }
        menuItem.title = NSLocalizedString(plainTitle, comment: "")
        return false
    }

    override open func windowDidLoad() {
        super.windowDidLoad()
        ensureActionCoordinators()
        ensureFocusRefreshCoordinator()
        window?.setFrameUsingName("GitX")
        window?.representedURL = repository?.workingDirectoryURL()
        if let repository {
            installRepositoryForgeOverlaySession()
            _sidebarController = PBGitSidebarController(repository: repository, superController: self)
            _historyViewController = PBGitHistoryController(repository: repository, superController: self)
        }
        repositoryToolbarController = RepositoryToolbarController(windowController: self)
        initializedContentControllers = .weakObjects()
        repositoryToolbarController?.install()
        installRepositoryStatusBar()
        if let sidebar = _sidebarController {
            sidebar.view.frame = .zero
            if let sourceSplitView {
                sidebar.view.frame = sourceSplitView.bounds
            }
            sourceSplitView?.addSubview(sidebar.view)
            if let sidebarControls = sidebar.sourceListControlsView {
                sourceListControlsView?.addSubview(sidebarControls)
            }
        }
        statusField?.cell?.backgroundStyle = .raised
        progressIndicator?.usesThreadedAnimation = true
        jumpToCheckedOutBranchButton?.setAccessibilityIdentifier("JumpToCheckedOutBranchButton")
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidBecomeActive(_:)),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(refreshPreferenceDidChange(_:)),
            name: UserDefaults.didChangeNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(repositoryLocalStatusDidChange(_:)),
            name: NSNotification.Name(PBGitIndexIndexUpdated),
            object: repository?.index
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(repositoryRemoteOperationDidSucceed(_:)),
            name: .repositoryRemoteOperationDidSucceed,
            object: repository
        )
        refreshPreferenceDidChange(nil)
        repositoryLocalStatusLoader?.refresh()
    }

    @objc(applicationDidBecomeActive:)
    dynamic func applicationDidBecomeActive(_ notification: Notification) {
        ensureFocusRefreshCoordinator()
        focusRefreshCoordinator?.applicationDidBecomeActive()
        repositoryForgeOverlaySession?.requestRefresh(reason: .applicationActivated)
    }

    @objc(refreshPreferenceDidChange:)
    dynamic func refreshPreferenceDidChange(_ notification: Notification?) {
        ensureFocusRefreshCoordinator()
        focusRefreshCoordinator?.updatePreference(enabled: RepositoryRefreshPolicy.shouldRefreshAfterApplicationActivation())
        repositoryStatusBarController?.setVisible(ApplicationSettings.repositoryStatusBarVisible)
        updateToolbarForgeDiagnostic()
    }

    @objc dynamic func refreshIfRepositoryChangedSinceLastActivation() {
        ensureFocusRefreshCoordinator()
        focusRefreshCoordinator?.applicationDidBecomeActive()
    }

    @objc dynamic func changeContentController(_ controller: PBViewController?) {
        guard let controller, contentController !== controller else { return }
        if let previousController = contentController {
            contentStatusObservation = nil
            previousController.view.isHidden = true
            previousController.view.removeFromSuperview()
        }

        contentController = controller
        if initializedContentControllers == nil {
            initializedContentControllers = .weakObjects()
        }
        let firstMount = initializedContentControllers?.contains(controller) != true
        controller.view.frame = .zero
        if let contentSplitView {
            controller.view.frame = contentSplitView.bounds
        }
        controller.view.autoresizingMask = [.width, .height]
        controller.view.isHidden = false
        contentSplitView?.addSubview(controller.view)
        if firstMount {
            initializedContentControllers?.add(controller)
            controller.updateView()
        }
        if let firstResponder = controller.firstResponder() {
            window?.makeFirstResponder(firstResponder)
        }
        contentStatusObservation = controller.observe(\.status, options: [.initial]) { [weak self] _, _ in
            // swift6-safety-justification: KVO delivery and content-controller mutations are confined to AppKit's main thread.
            MainActor.assumeIsolated {
                self?.updateStatus()
            }
        }
        NSLog(
            "[GitX] Mounted %@ (first mount: %@)",
            NSStringFromClass(type(of: controller)),
            firstMount ? "yes" : "no"
        )
        let forgeActivity: ForgeOverlayActivity = controller === _historyViewController
            ? .affectedViewActive
            : .otherOpenRepository
        repositoryForgeOverlaySession?.setActivity(forgeActivity)
    }

    @IBAction dynamic func showUncommittedChanges(_ sender: Any?) {
        NSLog("[GitX] Showing the Uncommitted Changes row")
        showHistoryView(sender)
        _historyViewController?.selectUncommittedChanges()
    }

    @IBAction dynamic func showHistoryView(_ sender: Any?) {
        NSLog("Switching repository window to History view")
        _sidebarController?.selectCurrentBranch()
        changeContentController(_historyViewController)
    }

    @objc dynamic var isUncommittedChangesSelected: Bool {
        _historyViewController?.uncommittedChangesSelected == true
    }

    @IBAction dynamic func toggleAmendCommit(_ sender: Any?) {
        // Toggling amend refreshes the index against HEAD^, which repopulates indexChanges and pins the
        // Uncommitted Changes row even on a clean tree; the pending selection then lands on it.
        guard let index = repository?.index else { return }
        index.isAmend.toggle()
        showUncommittedChanges(sender)
    }

    @objc dynamic func updateStatus() {
        var displayedStatus = ""
        var busy = false
        if let contentController, let status = contentController.status {
            displayedStatus = status
            busy = contentController.isBusy
        }
        statusField?.stringValue = displayedStatus
        var baseTitle = ""
        if let document = document as? NSDocument {
            baseTitle = document.displayName
        } else if let window {
            baseTitle = window.title
        }
        repositoryToolbarController?.update(status: displayedStatus, busy: busy, baseWindowTitle: baseTitle)
        repositoryStatusBarController?.updateLocal(RepositoryLocalStatusPresenter.present(
            repositoryLocalStatusSnapshot,
            activityText: displayedStatus,
            isBusy: busy
        ))
        if busy {
            progressIndicator?.startAnimation(self)
            progressIndicator?.isHidden = false
        } else {
            progressIndicator?.stopAnimation(self)
            progressIndicator?.isHidden = true
        }
    }

    @objc dynamic func setHistorySearch(_ searchString: String, mode: PBHistorySearchMode) {
        _historyViewController?.setHistorySearch(searchString, mode: mode)
    }

    @objc(selectedURLsFromSender:)
    dynamic func selectedURLs(from sender: Any?) -> [URL]? {
        ensureActionCoordinators()
        return workspaceActionCoordinator?.selectedURLs(from: representedObject(from: sender))
    }

    private func representedObject(from sender: Any?) -> Any? {
        let selector = NSSelectorFromString("representedObject")
        guard let object = sender as? NSObject, object.responds(to: selector) else { return nil }
        return object.perform(selector)?.takeUnretainedValue()
    }

    @objc(openURLs:)
    open dynamic func open(_ fileURLs: [URL]?) {
        ensureActionCoordinators()
        let urls = fileURLs ?? []
        workspaceActionCoordinator?.open(urls)
    }

    @objc(revealURLsInFinder:)
    open dynamic func revealURLs(inFinder fileURLs: [URL]?) {
        ensureActionCoordinators()
        let urls = fileURLs ?? []
        workspaceActionCoordinator?.revealInFinder(urls)
    }

    @objc(refishForSender:refishTypes:)
    dynamic func refish(for sender: Any?, refishTypes types: [String]?) -> PBGitRefish? {
        ensureActionCoordinators()
        guard let repository, let actionContextResolver else { return nil }
        let menuItem = sender as? NSMenuItem
        let selectedCommit = menuItem == nil ? _historyViewController?.selectedCommits.first : nil
        return actionContextResolver.refish(
            representedObject: menuItem?.representedObject,
            selectedCommit: selectedCommit,
            allowedTypes: types,
            repository: repository
        )
    }

    @objc dynamic var selectedRef: PBGitRef? {
        ensureActionCoordinators()
        var sidebarRef: PBGitRef?
        var sidebarRemoteName: String?
        var historyRefs: [PBGitRef]?
        if let sidebarViewController,
           let sidebarSourceView = sidebarViewController.sourceView,
           window?.firstResponder === sidebarSourceView,
           let item = sidebarSourceView.item(atRow: sidebarSourceView.selectedRow) as? PBSourceViewItem
        {
            if let remotes = sidebarViewController.remotes, item.parent === remotes {
                sidebarRemoteName = item.title
            } else {
                sidebarRef = item.ref()
            }
        } else if window?.firstResponder === _historyViewController?.commitList,
                  _historyViewController?.singleCommitSelected == true
        {
            historyRefs = _historyViewController?.selectedCommits.first?.refs.compactMap { $0 as? PBGitRef }
        }
        return actionContextResolver?.selectedRef(
            sidebarRef: sidebarRef,
            sidebarRemoteName: sidebarRemoteName,
            historyRefs: historyRefs
        )
    }

    @objc(performFetchForRef:)
    dynamic func performFetch(for ref: PBGitRef?) {
        ensureActionCoordinators()
        remoteActionCoordinator?.performFetch(for: ref)
    }

    @objc(performPullForBranch:remote:rebase:)
    dynamic func performPull(forBranch branch: PBGitRef, remote: PBGitRef?, rebase: Bool) {
        ensureActionCoordinators()
        remoteActionCoordinator?.performPull(branch: branch, remote: remote, rebase: rebase)
    }

    @objc(performPushForBranch:toRemote:)
    open dynamic func performPush(forBranch branch: PBGitRef?, toRemote remote: PBGitRef?) {
        performPush(forBranch: branch, toRemote: remote, requiresConfirmation: true)
    }

    @objc(performPushForBranch:toRemote:requiresConfirmation:)
    open dynamic func performPush(
        forBranch branch: PBGitRef?,
        toRemote remote: PBGitRef?,
        requiresConfirmation: Bool
    ) {
        ensureActionCoordinators()
        remoteActionCoordinator?.performPush(
            branch: branch,
            remote: remote,
            requiresConfirmation: requiresConfirmation
        )
    }

    @available(*, deprecated, message: "Use addRemote(_:)")
    @IBAction dynamic func showAddRemoteSheet(_ sender: Any?) {
        addRemote(sender)
    }

    @IBAction dynamic func addRemote(_ sender: Any?) {
        ensureActionCoordinators()
        remoteActionCoordinator?.addRemote()
    }

    @IBAction dynamic func fetchRemote(_ sender: Any?) {
        let ref = refish(for: sender, refishTypes: [kGitXBranchType, kGitXRemoteType])
        if let ref = ref as? PBGitRef {
            performFetch(for: ref)
        }
    }

    @IBAction dynamic func fetchAllRemotes(_ sender: Any?) {
        performFetch(for: nil)
    }

    @IBAction dynamic func pullRemote(_ sender: Any?) {
        pull(from: sender, rebase: false)
    }

    @IBAction dynamic func pullRebaseRemote(_ sender: Any?) {
        pull(from: sender, rebase: true)
    }

    @IBAction dynamic func pullDefaultRemote(_ sender: Any?) {
        pull(from: sender, rebase: false)
    }

    @IBAction dynamic func pullRebaseDefaultRemote(_ sender: Any?) {
        pull(from: sender, rebase: true)
    }

    private func pull(from sender: Any?, rebase: Bool) {
        if let ref = refish(for: sender, refishTypes: [kGitXBranchType]) as? PBGitRef {
            performPull(forBranch: ref, remote: nil, rebase: rebase)
        }
    }

    @IBAction dynamic func pushUpdatesToRemote(_ sender: Any?) {
        if let ref = refish(for: sender, refishTypes: [kGitXRemoteType]) as? PBGitRef {
            performPush(forBranch: nil, toRemote: ref.remote())
        }
    }

    @IBAction dynamic func pushDefaultRemoteForRef(_ sender: Any?) {
        if let ref = refish(for: sender, refishTypes: [kGitXBranchType]) as? PBGitRef {
            performPush(forBranch: ref, toRemote: nil)
        }
    }

    @IBAction dynamic func pushToRemote(_ sender: Any?) {
        guard let item = sender as? NSMenuItem,
              let ref = refish(for: item.parent, refishTypes: nil) as? PBGitRef,
              let remote = refish(for: item, refishTypes: [kGitXRemoteType]) as? PBGitRef,
              ReferenceActionPolicy.canPushToNamedRemote(refishType: ref.refishType())
        else { return }
        performPush(forBranch: ref, toRemote: remote)
    }

    @IBAction dynamic func checkout(_ sender: Any?) {
        ensureActionCoordinators()
        referenceActionCoordinator?.checkout(refish(
            for: sender,
            refishTypes: [kGitXBranchType, kGitXRemoteBranchType, kGitXCommitType, kGitXTagType]
        ))
    }

    @IBAction dynamic func merge(_ sender: Any?) {
        ensureActionCoordinators()
        referenceActionCoordinator?.merge(refish(
            for: sender,
            refishTypes: [kGitXBranchType, kGitXRemoteBranchType, kGitXCommitType, kGitXTagType]
        ))
    }

    @IBAction dynamic func rebase(_ sender: Any?) {
        ensureActionCoordinators()
        referenceActionCoordinator?.rebase(on: refish(for: sender, refishTypes: [kGitXCommitType]))
    }

    @IBAction dynamic func rebaseHeadBranch(_ sender: Any?) {
        ensureActionCoordinators()
        referenceActionCoordinator?.rebase(on: refish(
            for: sender,
            refishTypes: [kGitXCommitType, kGitXBranchType, kGitXRemoteBranchType]
        ))
    }

    @IBAction dynamic func cherryPick(_ sender: Any?) {
        ensureActionCoordinators()
        referenceActionCoordinator?.cherryPick(refish(for: sender, refishTypes: [kGitXCommitType]))
    }

    @IBAction dynamic func resetSoft(_ sender: Any?) {
        ensureActionCoordinators()
        referenceActionCoordinator?.resetSoft(
            to: refish(for: sender, refishTypes: [kGitXBranchType, kGitXCommitType])
        )
    }

    @IBAction dynamic func deleteRef(_ sender: Any?) {
        ensureActionCoordinators()
        referenceActionCoordinator?.delete(refish(for: sender, refishTypes: nil) as? PBGitRef)
    }

    @IBAction dynamic func createBranch(_ sender: Any?) {
        ensureActionCoordinators()
        referenceActionCoordinator?.createBranch(
            from: refish(for: sender, refishTypes: nil),
            selectedCommit: _historyViewController?.selectedCommits.first
        )
    }

    @IBAction dynamic func createTag(_ sender: Any?) {
        ensureActionCoordinators()
        referenceActionCoordinator?.createTag(
            from: refish(for: sender, refishTypes: nil),
            selectedCommit: _historyViewController?.selectedCommits.first
        )
    }

    @IBAction dynamic func diffWithHEAD(_ sender: Any?) {
        ensureActionCoordinators()
        referenceActionCoordinator?.showDiffWithHEAD(for: refish(for: sender, refishTypes: nil))
    }

    @IBAction dynamic func stashViewDiff(_ sender: Any?) {
        ensureActionCoordinators()
        let ref = refish(for: sender, refishTypes: [kGitXStashType]) as? PBGitRef
        referenceActionCoordinator?.showStashDiff(ref.flatMap { repository?.stash(for: $0) })
    }

    @IBAction dynamic func showTagInfoSheet(_ sender: Any?) {
        ensureActionCoordinators()
        referenceActionCoordinator?.showTagInfo(
            for: refish(for: sender, refishTypes: [kGitXTagType]) as? PBGitRef
        )
    }

    @IBAction dynamic func stashSave(_ sender: Any?) {
        ensureActionCoordinators()
        stashActionCoordinator?.save(keepIndex: false)
    }

    @IBAction dynamic func stashSaveWithKeepIndex(_ sender: Any?) {
        ensureActionCoordinators()
        stashActionCoordinator?.save(keepIndex: true)
    }

    @IBAction dynamic func stashPop(_ sender: Any?) {
        ensureActionCoordinators()
        stashActionCoordinator?.pop(ref: refish(for: sender, refishTypes: [kGitXStashType]) as? PBGitRef)
    }

    @IBAction dynamic func stashApply(_ sender: Any?) {
        ensureActionCoordinators()
        stashActionCoordinator?.apply(ref: refish(for: sender, refishTypes: [kGitXStashType]) as? PBGitRef)
    }

    @IBAction dynamic func stashDrop(_ sender: Any?) {
        ensureActionCoordinators()
        stashActionCoordinator?.drop(ref: refish(for: sender, refishTypes: [kGitXStashType]) as? PBGitRef)
    }

    @IBAction dynamic func openFiles(_ sender: Any?) {
        open(selectedURLs(from: sender))
    }

    @IBAction dynamic func revealInFinder(_ sender: Any?) {
        var urls: [URL]?
        if let object = sender as? NSObject,
           object.responds(to: NSSelectorFromString("representedObject"))
        {
            urls = selectedURLs(from: sender)
        }
        if urls?.isEmpty != false {
            guard let workingDirectoryURL = repository?.workingDirectoryURL() else { return }
            urls = [workingDirectoryURL]
        }
        revealURLs(inFinder: urls)
    }

    @IBAction dynamic func openInTerminal(_ sender: Any?) {
        ensureActionCoordinators()
        workspaceActionCoordinator?.openRepositoryInTerminal()
    }

    @IBAction dynamic func refresh(_ sender: Any?) {
        refreshLocalRepositoryContent()
        repositoryForgeOverlaySession?.requestManualRefresh()
    }

    private func refreshLocalRepositoryContent() {
        contentController?.refresh(self)
        repositoryLocalStatusLoader?.refresh()
        synchronizeWindowTitleWithDocumentName()
        NSLog("[GitX] Manual refresh synchronized window title: %@", window?.title ?? "")
    }

    @IBAction dynamic func toggleRepositoryStatusBar(_ sender: Any?) {
        ApplicationSettings.repositoryStatusBarVisible.toggle()
        repositoryStatusBarController?.setVisible(ApplicationSettings.repositoryStatusBarVisible)
        updateToolbarForgeDiagnostic()
        NSLog(
            "[GitX] Repository status bar visibility changed: %@",
            ApplicationSettings.repositoryStatusBarVisible ? "visible" : "hidden"
        )
    }

    @objc(repositoryLocalStatusDidChange:)
    private dynamic func repositoryLocalStatusDidChange(_ notification: Notification) {
        repositoryLocalStatusLoader?.refresh()
    }

    @objc(repositoryRemoteOperationDidSucceed:)
    private dynamic func repositoryRemoteOperationDidSucceed(_ notification: Notification) {
        repositoryLocalStatusLoader?.refresh()
        let operation = notification.userInfo?["operation"] as? String
        let reason: ForgeRefreshReason = operation == "push" ? .localPushSucceeded : .localFetchSucceeded
        repositoryForgeOverlaySession?.requestRefresh(reason: reason)
    }

    private func installRepositoryForgeOverlaySession() {
        guard repositoryForgeOverlaySession == nil else { return }
        let binding = forgeCoordinator?.resolveBinding().binding
        let session = RepositoryForgeOverlaySession(
            binding: binding,
            services: ApplicationComposition.shared.forgeServices,
            detailsHandler: { [weak self] action in
                self?.presentForgeStatusDetails(action)
            }
        )
        repositoryForgeOverlaySession = session
        session.start()
    }

    private func installRepositoryStatusBar() {
        guard let splitView, let contentView = window?.contentView, let repository else { return }
        let controller = RepositoryStatusBarController(splitView: splitView, contentView: contentView)
        controller.presentationDidChange = { [weak self] presentation in
            self?.repositoryToolbarController?.updateForgeDiagnostic(
                persistentFailureText: presentation.toolbarPersistentFailureText,
                statusBarVisible: ApplicationSettings.repositoryStatusBarVisible
            )
        }
        repositoryStatusBarController = controller
        controller.install(visible: ApplicationSettings.repositoryStatusBarVisible)
        repositoryLocalStatusLoader = RepositoryLocalStatusLoader(
            repository: repository,
            gitExecutablePath: PBGitBinary.path()
        ) { [weak self] snapshot in
            guard let self else { return }
            self.repositoryLocalStatusSnapshot = snapshot
            self.updateStatus()
        }
        if let repositoryForgeOverlaySession {
            controller.bind(to: repositoryForgeOverlaySession)
        }
    }

    private func updateToolbarForgeDiagnostic() {
        repositoryToolbarController?.updateForgeDiagnostic(
            persistentFailureText: repositoryStatusBarController?.currentForgePresentation.toolbarPersistentFailureText,
            statusBarVisible: ApplicationSettings.repositoryStatusBarVisible
        )
    }

    func presentForgeStatusDetails(
        _ action: ForgeStatusDetailsAction,
        recoveryCopyOverride: ForgeSQLiteRecoveryCopy? = nil,
        revealRecoveryCopy: @escaping (URL) -> Void = {
            NSWorkspace.shared.activateFileViewerSelecting([$0])
        }
    ) {
        let details = RepositoryForgeDiagnosticDetailsPresenter.present(action)
        let alert = NSAlert()
        alert.messageText = details.title
        var message = details.message
        let recoveryCopy = recoveryCopyOverride ?? repositoryForgeOverlaySession?.recoveryCopy
        if action == .recoverForgeData,
           let recoveryCopy
        {
            message += "\n\nRecovery copy: \(recoveryCopy.url.lastPathComponent)"
            alert.addButton(withTitle: "Reveal in Finder")
            alert.addButton(withTitle: "OK")
        } else {
            alert.addButton(withTitle: "OK")
        }
        alert.informativeText = message
        guard let window else { return }
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn,
                  action == .recoverForgeData,
                  self != nil,
                  let recoveryCopy
            else { return }
            revealRecoveryCopy(recoveryCopy.url)
        }
    }

    #if DEBUG
        @objc(presentForgeRecoveryStatusDetailsWithCopyURL:revealHandler:)
        dynamic func presentForgeRecoveryStatusDetails(
            copyURL: URL,
            revealHandler: @escaping (URL) -> Void
        ) {
            presentForgeStatusDetails(
                .recoverForgeData,
                recoveryCopyOverride: ForgeSQLiteRecoveryCopy(url: copyURL, createdAt: Date()),
                revealRecoveryCopy: revealHandler
            )
        }
    #endif

    @objc(showForgeStatusDetails:)
    dynamic func showForgeStatusDetails(_ sender: Any?) {
        repositoryStatusBarController?.requestCurrentDetails()
    }

    @IBAction dynamic func jumpToCheckedOutBranch(_ sender: Any?) {
        NSLog("[GitX] Jumping to the repository's checked-out branch")
        repository?.reloadRefs()
        repository?.readCurrentBranch()
        _sidebarController?.selectCurrentBranch()
    }

    @IBAction dynamic func showRepositorySettings(_ sender: Any?) {
        WindowDialogPresenter.showRepositorySettings(for: self)
    }

    @objc open dynamic func showCommitHookFailedSheet(
        _ messageText: String,
        infoText: String,
        retryHandler: (() -> Void)?
    ) {
        WindowDialogPresenter.showCommitHookFailedSheet(
            messageText,
            infoText: infoText,
            retryHandler: retryHandler,
            for: self
        )
    }

    @objc open dynamic func showMessageSheet(_ messageText: String, infoText: String) {
        WindowDialogPresenter.showMessageSheet(messageText, infoText: infoText, for: self)
    }

    @objc open dynamic func showErrorSheet(_ error: Error) {
        WindowDialogPresenter.showErrorSheet(error, for: self)
    }

    @discardableResult
    @objc open dynamic func confirmDialog(
        _ alert: NSAlert,
        suppressionIdentifier identifier: String?,
        forAction actionBlock: @escaping () -> Void
    ) -> Bool {
        WindowDialogPresenter.confirmDialog(
            alert,
            suppressionIdentifier: identifier,
            for: self,
            action: actionBlock
        )
    }
}
