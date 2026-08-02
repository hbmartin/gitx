import AppKit
import Foundation
import OSLog // swiftlint:disable:this unused_import

#if DEBUG || !GITX_APP_TARGET
    /// The Milestone 3 overlay and deterministic diagnostics share this one
    /// accessibility namespace so production wiring can adopt the same contract.
    enum Milestone3AccessibilityIdentifier {
        static let diagnosticRoot = "GitX.M3.Diagnostic.Root"
        static let diagnosticScrollView = "GitX.M3.Diagnostic.ScrollView"
        static let nativeDestination = "GitX.M3.NativePullRequestDestination"
        static let productionScrollView = "GitX.M3.Production.ScrollView"
        static let harnessStarting = "GitX.M3.Harness.Starting"

        static func harnessState(_ state: String) -> String {
            "GitX.M3.Harness.\(state)"
        }

        enum PullRequest {
            static let eyebrow = "GitX.M3.PullRequest.Eyebrow"
            static let title = "GitX.M3.PullRequest.Title"
            static let headBinding = "GitX.M3.PullRequest.HeadBinding"
        }

        enum Review {
            static let activeThread = "GitX.M3.Review.Thread.Active"
            static let outdatedThread = "GitX.M3.Review.Thread.Outdated"
            static let minimizedThread = "GitX.M3.Review.Thread.Minimized"
            static let deletedThread = "GitX.M3.Review.Thread.Deleted"
            static let unavailableThread = "GitX.M3.Review.Thread.Unavailable"
            static let replyBody = "GitX.M3.Review.ReplyBody"
            static let publishReply = "GitX.M3.Review.PublishReply"
            static let publishedReply = "GitX.M3.Review.PublishedReply"
            static let resolve = "GitX.M3.Review.Resolve"
            static let undoResolve = "GitX.M3.Review.UndoResolve"
            static let openFormalReview = "GitX.M3.Review.OpenFormalReview"
            static let formalSheet = "GitX.M3.Review.FormalSheet"
            static let formalKind = "GitX.M3.Review.FormalKind"
            static let formalBody = "GitX.M3.Review.FormalBody"
            static let submitFormalReview = "GitX.M3.Review.SubmitFormalReview"
            static let outdatedBadge = "GitX.M3.Review.OutdatedBadge"
            static let minimizedReason = "GitX.M3.Review.MinimizedReason"
            static let deletedTombstone = "GitX.M3.Review.DeletedTombstone"
            static let unavailableTombstone = "GitX.M3.Review.UnavailableTombstone"
        }

        enum SuggestedChange {
            static let card = "GitX.M3.SuggestedChange.Card"
            static let patch = "GitX.M3.SuggestedChange.Patch"
            static let eligibility = "GitX.M3.SuggestedChange.Eligibility"
            static let apply = "GitX.M3.SuggestedChange.Apply"
            static let status = "GitX.M3.SuggestedChange.Status"
            static let safety = "GitX.M3.SuggestedChange.Safety"
        }

        enum Lifecycle {
            static let actions = "GitX.M3.Lifecycle.Actions"
            static let status = "GitX.M3.Lifecycle.Status"
            static let markReady = "GitX.M3.Lifecycle.MarkReady"
            static let updateBranch = "GitX.M3.Lifecycle.UpdateBranch"
            static let close = "GitX.M3.Lifecycle.Close"
            static let reopen = "GitX.M3.Lifecycle.Reopen"
            static let reviewers = "GitX.M3.Lifecycle.Reviewers"
            static let manageReviewersInBrowser = "GitX.M3.Lifecycle.ManageReviewersInBrowser"
        }

        enum Merge {
            static let form = "GitX.M3.Merge.Form"
            static let method = "GitX.M3.Merge.Method"
            static let title = "GitX.M3.Merge.Title"
            static let message = "GitX.M3.Merge.Message"
            static let rebaseSummary = "GitX.M3.Merge.RebaseSummary"
            static let blockerWarning = "GitX.M3.Merge.BlockerWarning"
            static let review = "GitX.M3.Merge.Review"
            static let status = "GitX.M3.Merge.Status"
            static let confirmation = "GitX.M3.Merge.Confirmation"
            static let confirmationSummary = "GitX.M3.Merge.ConfirmationSummary"
            static let confirm = "GitX.M3.Merge.Confirm"
            static let cancel = "GitX.M3.Merge.Cancel"
        }

        enum Queue {
            static let actions = "GitX.M3.Queue.Actions"
            static let status = "GitX.M3.Queue.Status"
            static let enter = "GitX.M3.Queue.Enter"
            static let leave = "GitX.M3.Queue.Leave"
            static let observeMerge = "GitX.M3.Queue.ObserveMerge"
        }

        enum BranchDeletion {
            static let actions = "GitX.M3.BranchDeletion.Actions"
            static let preference = "GitX.M3.BranchDeletion.Preference"
            static let delete = "GitX.M3.BranchDeletion.Delete"
        }

        enum PostMerge {
            static let actions = "GitX.M3.PostMerge.Actions"
            static let status = "GitX.M3.PostMerge.Status"
            static let fetch = "GitX.M3.PostMerge.Fetch"
            static let checkoutBase = "GitX.M3.PostMerge.CheckoutBase"
            static let diagnostics = "GitX.M3.PostMerge.Diagnostics"
            static let branch = "GitX.M3.PostMerge.Branch"
        }
    }

    enum Milestone3DiagnosticJourney: String, CaseIterable, Sendable {
        case review
        case suggestedChange = "suggested-change"
        case lifecycle
        case merge
        case queueDelete = "queue-delete"
        case postMerge = "post-merge"
    }

    /// A deterministic, credential-free presentation of the six Milestone 3
    /// workflows retained for focused app-hosted diagnostics and supplemental
    /// screenshots. Launched UI journeys mount the production review controller.
    @MainActor
    // Referenced from the app-hosted test target, which SwiftLint's app compilation cannot discover.
    // swiftlint:disable:next unused_declaration
    final class Milestone3DiagnosticViewController: NSViewController {
        typealias StateHandler = (_ state: String, _ label: String) -> Void

        private let journey: Milestone3DiagnosticJourney
        private let repository: PBGitRepository
        private let stateHandler: StateHandler
        private let logger = Logger(subsystem: "com.gitx.gitx", category: "Milestone3Diagnostics")

        private let contentStack = NSStackView()
        private var replyBody: NSTextView?
        private var publishedReply: NSTextField?
        private var resolveButton: NSButton?
        private var undoResolutionButton: NSButton?
        private var formalReviewPanel: NSView?
        private var formalReviewKind: NSPopUpButton?
        private var formalReviewBody: NSTextView?
        private var suggestedChangeStatus: NSTextField?
        private var lifecycleStatus: NSTextField?
        private var closeButton: NSButton?
        private var reopenButton: NSButton?
        private var mergeMethod: NSPopUpButton?
        private var mergeConfirmation: NSView?
        private var mergeConfirmationSummary: NSTextField?
        private var mergeStatus: NSTextField?
        private var queueStatus: NSTextField?
        private var enterQueueButton: NSButton?
        private var leaveQueueButton: NSButton?
        private var deletePreference: NSButton?
        private var deleteBranchButton: NSButton?
        private var postMergeStatus: NSTextField?
        private var checkoutBaseButton: NSButton?

        init(
            journey: Milestone3DiagnosticJourney,
            repository: PBGitRepository,
            stateHandler: @escaping StateHandler
        ) {
            self.journey = journey
            self.repository = repository
            self.stateHandler = stateHandler
            super.init(nibName: nil, bundle: nil)
        }

        @available(*, unavailable)
        required init?(coder _: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func loadView() {
            let background = Milestone3SnowLeopardBackgroundView()
            background.setAccessibilityElement(true)
            background.setAccessibilityRole(.group)
            background.setAccessibilityIdentifier(Milestone3AccessibilityIdentifier.diagnosticRoot)
            background.setAccessibilityLabel("Milestone 3 native Pull Request diagnostics")

            let scrollView = NSScrollView()
            scrollView.drawsBackground = false
            scrollView.hasVerticalScroller = true
            scrollView.autohidesScrollers = true
            scrollView.translatesAutoresizingMaskIntoConstraints = false
            scrollView.setAccessibilityIdentifier(Milestone3AccessibilityIdentifier.diagnosticScrollView)

            contentStack.orientation = .vertical
            contentStack.alignment = .leading
            contentStack.spacing = 10
            contentStack.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 22, right: 20)
            contentStack.translatesAutoresizingMaskIntoConstraints = false

            let documentView = NSView()
            documentView.translatesAutoresizingMaskIntoConstraints = false
            documentView.addSubview(contentStack)
            scrollView.documentView = documentView
            background.addSubview(scrollView)

            NSLayoutConstraint.activate([
                scrollView.leadingAnchor.constraint(equalTo: background.leadingAnchor),
                scrollView.trailingAnchor.constraint(equalTo: background.trailingAnchor),
                scrollView.topAnchor.constraint(equalTo: background.topAnchor),
                scrollView.bottomAnchor.constraint(equalTo: background.bottomAnchor),
                documentView.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
                documentView.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
                documentView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
                documentView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
                contentStack.leadingAnchor.constraint(equalTo: documentView.leadingAnchor),
                contentStack.trailingAnchor.constraint(equalTo: documentView.trailingAnchor),
                contentStack.topAnchor.constraint(equalTo: documentView.topAnchor),
                contentStack.bottomAnchor.constraint(equalTo: documentView.bottomAnchor),
            ])

            view = background
            buildHeader()
            switch journey {
            case .review:
                buildReviewJourney()
            case .suggestedChange:
                buildSuggestedChangeJourney()
            case .lifecycle:
                buildLifecycleJourney()
            case .merge:
                buildMergeJourney()
            case .queueDelete:
                buildQueueDeleteJourney()
            case .postMerge:
                buildPostMergeJourney()
            }
        }

        private func buildHeader() {
            let eyebrow = label(
                "GITHUB PULL REQUEST #42  •  NATIVE REVIEW",
                identifier: Milestone3AccessibilityIdentifier.PullRequest.eyebrow,
                style: .eyebrow
            )
            let title = label(
                "Milestone 3 integration review",
                identifier: Milestone3AccessibilityIdentifier.PullRequest.title,
                style: .title
            )
            let metadata = label(
                "feature/milestone-3 → main  •  head 42f00d1  •  fresh from GitHub",
                identifier: Milestone3AccessibilityIdentifier.PullRequest.headBinding,
                style: .secondary
            )
            contentStack.addArrangedSubview(eyebrow)
            contentStack.addArrangedSubview(title)
            contentStack.addArrangedSubview(metadata)
        }

        private func buildReviewJourney() {
            let reply = textEditor(
                identifier: Milestone3AccessibilityIdentifier.Review.replyBody,
                label: "Reply body",
                placeholder: "Reply inside this Review Thread…",
                height: 48
            )
            replyBody = reply.textView
            let publish = button(
                "Publish Reply",
                identifier: Milestone3AccessibilityIdentifier.Review.publishReply,
                action: #selector(publishReply)
            )
            let resolve = button(
                "Resolve Thread",
                identifier: Milestone3AccessibilityIdentifier.Review.resolve,
                action: #selector(resolveThread)
            )
            resolveButton = resolve
            let undo = button(
                "Undo Resolve",
                identifier: Milestone3AccessibilityIdentifier.Review.undoResolve,
                action: #selector(undoResolveThread)
            )
            undo.isHidden = true
            undoResolutionButton = undo
            let published = label(
                "",
                identifier: Milestone3AccessibilityIdentifier.Review.publishedReply,
                style: .success
            )
            published.isHidden = true
            publishedReply = published

            let threadControls = horizontal([publish, resolve, undo])
            contentStack.addArrangedSubview(card(
                identifier: Milestone3AccessibilityIdentifier.Review.activeThread,
                title: "Active thread • Sources/AppDelegate.swift:18–20",
                subtitle: "Expanded range anchor • 👍 2  •  👀 1",
                views: [reply.scrollView, threadControls, published]
            ))

            let formalButton = button(
                "Submit Formal Review…",
                identifier: Milestone3AccessibilityIdentifier.Review.openFormalReview,
                action: #selector(openFormalReview)
            )
            contentStack.addArrangedSubview(formalButton)
            buildFormalReviewPanel()

            contentStack.addArrangedSubview(card(
                identifier: Milestone3AccessibilityIdentifier.Review.outdatedThread,
                title: "Outdated thread • Sources/Parser.swift:73",
                subtitle: "Best-effort exact local location: line 79. Server anchor remains unchanged.",
                views: [badge(
                    "OUTDATED",
                    identifier: Milestone3AccessibilityIdentifier.Review.outdatedBadge
                )]
            ))
            contentStack.addArrangedSubview(card(
                identifier: Milestone3AccessibilityIdentifier.Review.minimizedThread,
                title: "Minimized comment",
                subtitle: "Reason: off-topic • Expand to read on GitHub",
                views: [badge(
                    "MINIMIZED",
                    identifier: Milestone3AccessibilityIdentifier.Review.minimizedReason
                )]
            ))
            contentStack.addArrangedSubview(card(
                identifier: Milestone3AccessibilityIdentifier.Review.deletedThread,
                title: "Deleted comment",
                subtitle: "This published review comment was deleted on GitHub.",
                views: [badge(
                    "TOMBSTONE",
                    identifier: Milestone3AccessibilityIdentifier.Review.deletedTombstone
                )]
            ))
            contentStack.addArrangedSubview(card(
                identifier: Milestone3AccessibilityIdentifier.Review.unavailableThread,
                title: "Comment unavailable",
                subtitle: "GitHub did not return this comment. Refresh to reconcile the thread.",
                views: [badge(
                    "UNAVAILABLE",
                    identifier: Milestone3AccessibilityIdentifier.Review.unavailableTombstone
                )]
            ))
        }

        private func buildFormalReviewPanel() {
            let kind = NSPopUpButton(frame: .zero, pullsDown: false)
            kind.addItems(withTitles: ["Approve", "Comment", "Request Changes"])
            kind.setAccessibilityIdentifier(Milestone3AccessibilityIdentifier.Review.formalKind)
            kind.setAccessibilityLabel("Formal review kind")
            formalReviewKind = kind
            let body = textEditor(
                identifier: Milestone3AccessibilityIdentifier.Review.formalBody,
                label: "Formal review body",
                placeholder: "Optional review summary…",
                height: 44
            )
            formalReviewBody = body.textView
            let submit = button(
                "Submit Review",
                identifier: Milestone3AccessibilityIdentifier.Review.submitFormalReview,
                action: #selector(submitFormalReview)
            )
            let panel = card(
                identifier: Milestone3AccessibilityIdentifier.Review.formalSheet,
                title: "Formal Review • bound to head 42f00d1",
                subtitle: "A changed head stops submission and requires refreshed confirmation.",
                views: [kind, body.scrollView, submit]
            )
            panel.isHidden = true
            formalReviewPanel = panel
            contentStack.addArrangedSubview(panel)
        }

        private func buildSuggestedChangeJourney() {
            let source = label(
                "- let answer = 41\n+ let answer = 42",
                identifier: Milestone3AccessibilityIdentifier.SuggestedChange.patch,
                style: .code
            )
            let eligibility = badge(
                "EXACT HEAD CHECKED OUT • CONTEXT MATCHED • FILE CLEAN",
                identifier: Milestone3AccessibilityIdentifier.SuggestedChange.eligibility
            )
            let apply = button(
                "Apply Suggested Change",
                identifier: Milestone3AccessibilityIdentifier.SuggestedChange.apply,
                action: #selector(applySuggestedChange)
            )
            let status = label(
                "Ready to apply one suggestion as an unstaged local edit.",
                identifier: Milestone3AccessibilityIdentifier.SuggestedChange.status,
                style: .secondary
            )
            suggestedChangeStatus = status
            contentStack.addArrangedSubview(card(
                identifier: Milestone3AccessibilityIdentifier.SuggestedChange.card,
                title: "Suggested change • M3Suggested.swift:1",
                subtitle: "Original context matches the displayed Pull Request head.",
                views: [eligibility, source, apply, status]
            ))
            contentStack.addArrangedSubview(card(
                identifier: Milestone3AccessibilityIdentifier.SuggestedChange.safety,
                title: "Local edit safety",
                subtitle: "GitX has no Undo for an applied suggestion. Review the unstaged diff before committing.",
                views: []
            ))
        }

        private func buildLifecycleJourney() {
            let status = label(
                "Draft Pull Request • open • branch update available",
                identifier: Milestone3AccessibilityIdentifier.Lifecycle.status,
                style: .status
            )
            lifecycleStatus = status
            let ready = button(
                "Mark Ready for Review",
                identifier: Milestone3AccessibilityIdentifier.Lifecycle.markReady,
                action: #selector(markReady)
            )
            let update = button(
                "Update Branch…",
                identifier: Milestone3AccessibilityIdentifier.Lifecycle.updateBranch,
                action: #selector(updateBranch)
            )
            let close = button(
                "Close Pull Request",
                identifier: Milestone3AccessibilityIdentifier.Lifecycle.close,
                action: #selector(closePullRequest)
            )
            closeButton = close
            let reopen = button(
                "Reopen Pull Request",
                identifier: Milestone3AccessibilityIdentifier.Lifecycle.reopen,
                action: #selector(reopenPullRequest)
            )
            reopen.isHidden = true
            reopenButton = reopen
            contentStack.addArrangedSubview(card(
                identifier: Milestone3AccessibilityIdentifier.Lifecycle.actions,
                title: "Pull Request lifecycle",
                subtitle: "Update Branch is explicit, separate from Merge, and never automatic.",
                views: [status, horizontal([ready, update, close, reopen])]
            ))
            let reviewer = button(
                "Manage Reviewers in Browser…",
                identifier: Milestone3AccessibilityIdentifier.Lifecycle.manageReviewersInBrowser,
                action: #selector(routeReviewerManagement)
            )
            contentStack.addArrangedSubview(card(
                identifier: Milestone3AccessibilityIdentifier.Lifecycle.reviewers,
                title: "Reviewers • read-only",
                subtitle: "Ada approved • Grace requested • Core team pending",
                views: [reviewer]
            ))
        }

        private func buildMergeJourney() {
            let method = NSPopUpButton(frame: .zero, pullsDown: false)
            method.addItems(withTitles: ["Merge", "Squash", "Rebase"])
            method.setAccessibilityIdentifier(Milestone3AccessibilityIdentifier.Merge.method)
            method.setAccessibilityLabel("Merge method")
            method.target = self
            method.action = #selector(mergeMethodChanged)
            mergeMethod = method
            let title = editableField(
                "Milestone 3 integration review (#42)",
                identifier: Milestone3AccessibilityIdentifier.Merge.title,
                label: "Merge title"
            )
            let message = textEditor(
                identifier: Milestone3AccessibilityIdentifier.Merge.message,
                label: "Merge message",
                placeholder: "Reviewed natively in GitX.",
                height: 46
            )
            message.textView.string = "Reviewed natively in GitX."
            let rebaseSummary = label(
                "Rebase summary is read-only: 3 commits will be replayed onto main.",
                identifier: Milestone3AccessibilityIdentifier.Merge.rebaseSummary,
                style: .secondary
            )
            let warning = label(
                "Warning: one advisory check is pending. GitHub remains authoritative.",
                identifier: Milestone3AccessibilityIdentifier.Merge.blockerWarning,
                style: .warning
            )
            let review = button(
                "Review Merge…",
                identifier: Milestone3AccessibilityIdentifier.Merge.review,
                action: #selector(reviewMerge)
            )
            let status = label(
                "Ready for fresh preflight.",
                identifier: Milestone3AccessibilityIdentifier.Merge.status,
                style: .status
            )
            mergeStatus = status
            contentStack.addArrangedSubview(card(
                identifier: Milestone3AccessibilityIdentifier.Merge.form,
                title: "Merge Pull Request",
                subtitle: "Refetch immediately before confirmation • head/base must remain unchanged.",
                views: [method, title, message.scrollView, rebaseSummary, warning, review, status]
            ))
            buildMergeConfirmation()
        }

        private func buildMergeConfirmation() {
            let summary = label(
                "",
                identifier: Milestone3AccessibilityIdentifier.Merge.confirmationSummary,
                style: .status
            )
            mergeConfirmationSummary = summary
            let confirm = button(
                "Confirm Merge",
                identifier: Milestone3AccessibilityIdentifier.Merge.confirm,
                action: #selector(confirmMerge)
            )
            let cancel = button(
                "Cancel",
                identifier: Milestone3AccessibilityIdentifier.Merge.cancel,
                action: #selector(cancelMerge)
            )
            let confirmation = card(
                identifier: Milestone3AccessibilityIdentifier.Merge.confirmation,
                title: "Confirm fresh merge preflight",
                subtitle: "Open, non-draft, viewer can merge, enabled method, unchanged head/base.",
                views: [summary, horizontal([confirm, cancel])]
            )
            confirmation.isHidden = true
            mergeConfirmation = confirmation
            contentStack.addArrangedSubview(confirmation)
        }

        private func buildQueueDeleteJourney() {
            let status = label(
                "Not queued • Pull Request open",
                identifier: Milestone3AccessibilityIdentifier.Queue.status,
                style: .status
            )
            queueStatus = status
            let enter = button(
                "Enter Merge Queue",
                identifier: Milestone3AccessibilityIdentifier.Queue.enter,
                action: #selector(enterMergeQueue)
            )
            enterQueueButton = enter
            let leave = button(
                "Leave Merge Queue",
                identifier: Milestone3AccessibilityIdentifier.Queue.leave,
                action: #selector(leaveMergeQueue)
            )
            leave.isEnabled = false
            leaveQueueButton = leave
            contentStack.addArrangedSubview(card(
                identifier: Milestone3AccessibilityIdentifier.Queue.actions,
                title: "Merge Queue",
                subtitle: "Queueing is explicit. Auto-merge and automatic queueing are not offered.",
                views: [status, horizontal([enter, leave])]
            ))

            let preference = NSButton(
                checkboxWithTitle: "Delete head branch after merge",
                target: self,
                action: #selector(deletePreferenceChanged)
            )
            preference.state = .off
            preference.isEnabled = false
            preference.setAccessibilityIdentifier(Milestone3AccessibilityIdentifier.BranchDeletion.preference)
            preference.setAccessibilityLabel("Delete head branch after merge")
            deletePreference = preference
            let observe = button(
                "Observe Merge Result",
                identifier: Milestone3AccessibilityIdentifier.Queue.observeMerge,
                action: #selector(observeMerge)
            )
            let delete = button(
                "Delete Head Branch",
                identifier: Milestone3AccessibilityIdentifier.BranchDeletion.delete,
                action: #selector(deleteHeadBranch)
            )
            delete.isEnabled = false
            deleteBranchButton = delete
            contentStack.addArrangedSubview(card(
                identifier: Milestone3AccessibilityIdentifier.BranchDeletion.actions,
                title: "Post-merge branch deletion",
                subtitle: "Same repository • non-default • non-protected • safe local checkout.",
                views: [preference, horizontal([observe, delete])]
            ))
        }

        private func buildPostMergeJourney() {
            let status = label(
                "Merged on GitHub • local checkout unchanged",
                identifier: Milestone3AccessibilityIdentifier.PostMerge.status,
                style: .status
            )
            postMergeStatus = status
            let fetch = button(
                "Fetch Base",
                identifier: Milestone3AccessibilityIdentifier.PostMerge.fetch,
                action: #selector(fetchBase)
            )
            let checkout = button(
                "Check Out Base",
                identifier: Milestone3AccessibilityIdentifier.PostMerge.checkoutBase,
                action: #selector(checkoutBase)
            )
            checkout.isEnabled = false
            checkoutBaseButton = checkout
            contentStack.addArrangedSubview(card(
                identifier: Milestone3AccessibilityIdentifier.PostMerge.actions,
                title: "Merged Pull Request",
                subtitle: "GitX never changes the local checkout automatically.",
                views: [status, horizontal([fetch, checkout])]
            ))
            contentStack.addArrangedSubview(card(
                identifier: Milestone3AccessibilityIdentifier.PostMerge.diagnostics,
                title: "Local repository",
                subtitle: "Fetch and Check Out Base are separate, explicit actions.",
                views: [badge(
                    "CURRENT CHECKOUT: feature/milestone-3",
                    identifier: Milestone3AccessibilityIdentifier.PostMerge.branch
                )]
            ))
        }

        @objc private func publishReply() {
            let body = replyBody?.string.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !body.isEmpty else {
                emitFailure("A non-empty Review Thread reply is required.")
                return
            }
            publishedReply?.stringValue = "Published immediately: \(body)"
            publishedReply?.isHidden = false
            replyBody?.string = ""
            emit("Review.ReplyPublished", "Review Thread reply published immediately")
        }

        @objc private func resolveThread() {
            resolveButton?.isHidden = true
            undoResolutionButton?.isHidden = false
            emit("Review.Resolved", "Review Thread resolved; Undo is available briefly")
        }

        @objc private func undoResolveThread() {
            resolveButton?.isHidden = false
            undoResolutionButton?.isHidden = true
            emit("Review.ResolutionUndone", "Review Thread resolution undone")
        }

        @objc private func openFormalReview() {
            formalReviewPanel?.isHidden = false
            emit("Review.FormalReviewPresented", "Formal review sheet bound to displayed head")
        }

        @objc private func submitFormalReview() {
            let kind = formalReviewKind?.titleOfSelectedItem ?? "Comment"
            let body = formalReviewBody?.string.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let suffix = body.isEmpty ? "without a summary" : "with a summary"
            emit("Review.FormalReviewSubmitted", "\(kind) review submitted \(suffix) for exact displayed head")
        }

        @objc private func applySuggestedChange() {
            guard let workingDirectory = repository.workingDirectoryURL() else {
                emitFailure("The deterministic working directory is unavailable.")
                return
            }
            let fileURL = workingDirectory.appendingPathComponent("M3Suggested.swift")
            do {
                let original = try String(contentsOf: fileURL, encoding: .utf8)
                guard original.contains("let answer = 41") else {
                    emitFailure("The exact Suggested Change context no longer matches.")
                    return
                }
                let updated = original.replacingOccurrences(of: "let answer = 41", with: "let answer = 42")
                try updated.write(to: fileURL, atomically: true, encoding: .utf8)
                suggestedChangeStatus?.stringValue = "Applied as an unstaged local edit. GitX Undo is unavailable."
                emit("SuggestedChange.Applied", "Suggested Change applied as one unstaged local edit")
            } catch {
                emitFailure(error.localizedDescription)
            }
        }

        @objc private func markReady() {
            lifecycleStatus?.stringValue = "Ready for review • open • branch update available"
            emit("Lifecycle.Ready", "Draft Pull Request marked ready for review")
        }

        @objc private func updateBranch() {
            lifecycleStatus?.stringValue = "Ready for review • open • branch updated explicitly"
            emit("Lifecycle.BranchUpdated", "Pull Request branch updated explicitly")
        }

        @objc private func closePullRequest() {
            lifecycleStatus?.stringValue = "Pull Request closed"
            closeButton?.isHidden = true
            reopenButton?.isHidden = false
            emit("Lifecycle.Closed", "Pull Request closed")
        }

        @objc private func reopenPullRequest() {
            lifecycleStatus?.stringValue = "Pull Request reopened • ready for review"
            closeButton?.isHidden = false
            reopenButton?.isHidden = true
            emit("Lifecycle.Reopened", "Pull Request reopened")
        }

        @objc private func routeReviewerManagement() {
            emit("Lifecycle.ReviewersBrowserRouted", "Reviewer management routed to the browser")
        }

        @objc private func mergeMethodChanged() {
            let method = mergeMethod?.titleOfSelectedItem ?? "Merge"
            emit("Merge.Method.\(method)", "\(method) selected as the enabled merge method")
        }

        @objc private func reviewMerge() {
            let method = mergeMethod?.titleOfSelectedItem ?? "Merge"
            mergeConfirmationSummary?.stringValue = "\(method) • head 42f00d1 • base main • fresh"
            mergeConfirmation?.isHidden = false
            mergeStatus?.stringValue = "Fresh preflight complete. Explicit confirmation required."
            emit("Merge.ConfirmationPresented", "Fresh \(method) confirmation presented")
        }

        @objc private func confirmMerge() {
            let method = mergeMethod?.titleOfSelectedItem ?? "Merge"
            mergeConfirmation?.isHidden = true
            mergeStatus?.stringValue = "Merged successfully using \(method). Local checkout unchanged."
            emit("Merge.Succeeded", "Pull Request merged using \(method); local checkout unchanged")
        }

        @objc private func cancelMerge() {
            mergeConfirmation?.isHidden = true
            mergeStatus?.stringValue = "Merge confirmation cancelled."
            emit("Merge.Cancelled", "Merge confirmation cancelled")
        }

        @objc private func enterMergeQueue() {
            queueStatus?.stringValue = "Queued for merge • no branch deletion scheduled"
            enterQueueButton?.isEnabled = false
            leaveQueueButton?.isEnabled = true
            emit("Queue.Entered", "Pull Request entered the merge queue explicitly")
        }

        @objc private func leaveMergeQueue() {
            queueStatus?.stringValue = "Left merge queue • Pull Request open"
            enterQueueButton?.isEnabled = true
            leaveQueueButton?.isEnabled = false
            emit("Queue.Left", "Pull Request left the merge queue explicitly")
        }

        @objc private func observeMerge() {
            queueStatus?.stringValue = "Merge observed • branch deletion remains separate"
            deletePreference?.isEnabled = true
            deleteBranchButton?.isEnabled = true
            emit("Queue.MergeObserved", "Merge observed without scheduling branch deletion")
        }

        @objc private func deletePreferenceChanged() {
            let selected = deletePreference?.state == .on
            emit(
                "BranchDeletion.Preference.\(selected ? "Selected" : "Cleared")",
                selected ? "Delete-after-merge preference selected" : "Delete-after-merge preference cleared"
            )
        }

        @objc private func deleteHeadBranch() {
            queueStatus?.stringValue = "Merged • head branch deleted by separate mutation"
            deleteBranchButton?.isEnabled = false
            emit("BranchDeletion.Deleted", "Head branch deleted as a separate explicit mutation")
        }

        @objc private func fetchBase() {
            do {
                let remotes = try repository.outputOfTask(withArguments: ["remote"])
                    .split(whereSeparator: \.isNewline)
                    .map(String.init)
                if remotes.contains("origin") {
                    _ = try repository.outputOfTask(withArguments: ["fetch", "--no-tags", "origin", "main"])
                } else {
                    _ = try repository.outputOfTask(withArguments: ["rev-parse", "--verify", "main^{commit}"])
                }
                postMergeStatus?.stringValue = "Base fetched • local checkout still unchanged"
                checkoutBaseButton?.isEnabled = true
                emit("PostMerge.Fetched", "Base branch fetched without changing local checkout")
            } catch {
                emitFailure(error.localizedDescription)
            }
        }

        @objc private func checkoutBase() {
            do {
                _ = try repository.outputOfTask(withArguments: ["switch", "main"])
                postMergeStatus?.stringValue = "Base checked out explicitly • current branch main"
                checkoutBaseButton?.isEnabled = false
                emit("PostMerge.BaseCheckedOut", "Base branch checked out after explicit confirmation")
            } catch {
                emitFailure(error.localizedDescription)
            }
        }

        private func emit(_ state: String, _ label: String) {
            logger.notice("Milestone 3 diagnostic state=\(state, privacy: .public)")
            stateHandler(state, label)
        }

        private func emitFailure(_ message: String) {
            logger.error("Milestone 3 diagnostic failure=\(message, privacy: .public)")
            stateHandler("Failure", message)
        }
    }

    @MainActor
    private extension Milestone3DiagnosticViewController {
        enum LabelStyle {
            case title
            case eyebrow
            case secondary
            case status
            case success
            case warning
            case code
        }

        func label(_ value: String, identifier: String, style: LabelStyle) -> NSTextField {
            let field = NSTextField(wrappingLabelWithString: value)
            field.setAccessibilityIdentifier(identifier)
            field.setAccessibilityLabel(value)
            switch style {
            case .title:
                field.font = NSFont.systemFont(ofSize: 22, weight: .semibold)
                field.textColor = NSColor(calibratedWhite: 0.12, alpha: 1)
            case .eyebrow:
                field.font = NSFont.systemFont(ofSize: 10, weight: .bold)
                field.textColor = NSColor(calibratedRed: 0.18, green: 0.32, blue: 0.48, alpha: 1)
            case .secondary:
                field.font = NSFont.systemFont(ofSize: 11)
                field.textColor = .secondaryLabelColor
            case .status:
                field.font = NSFont.systemFont(ofSize: 12, weight: .medium)
                field.textColor = NSColor(calibratedRed: 0.12, green: 0.28, blue: 0.42, alpha: 1)
            case .success:
                field.font = NSFont.systemFont(ofSize: 11, weight: .medium)
                field.textColor = NSColor(calibratedRed: 0.08, green: 0.42, blue: 0.18, alpha: 1)
            case .warning:
                field.font = NSFont.systemFont(ofSize: 11, weight: .medium)
                field.textColor = NSColor(calibratedRed: 0.58, green: 0.29, blue: 0.02, alpha: 1)
            case .code:
                field.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
                field.textColor = NSColor(calibratedWhite: 0.16, alpha: 1)
            }
            field.maximumNumberOfLines = 0
            return field
        }

        func badge(_ value: String, identifier: String) -> NSTextField {
            let field = NSTextField(labelWithString: value)
            field.font = NSFont.systemFont(ofSize: 9, weight: .bold)
            field.textColor = NSColor(calibratedRed: 0.20, green: 0.32, blue: 0.44, alpha: 1)
            field.drawsBackground = true
            field.backgroundColor = NSColor(calibratedRed: 0.86, green: 0.91, blue: 0.96, alpha: 1)
            field.isBezeled = true
            field.bezelStyle = .roundedBezel
            field.setAccessibilityIdentifier(identifier)
            field.setAccessibilityLabel(value)
            return field
        }

        func button(_ title: String, identifier: String, action: Selector) -> NSButton {
            let control = NSButton(title: title, target: self, action: action)
            control.bezelStyle = .rounded
            control.controlSize = .regular
            control.setAccessibilityIdentifier(identifier)
            control.setAccessibilityLabel(title)
            return control
        }

        func editableField(_ value: String, identifier: String, label: String) -> NSTextField {
            let field = NSTextField(string: value)
            field.bezelStyle = .roundedBezel
            field.setAccessibilityIdentifier(identifier)
            field.setAccessibilityLabel(label)
            return field
        }

        func textEditor(
            identifier: String,
            label: String,
            placeholder: String,
            height: CGFloat
        ) -> (scrollView: NSScrollView, textView: NSTextView) {
            let textView = NSTextView()
            textView.font = NSFont.systemFont(ofSize: 12)
            textView.isRichText = false
            textView.isAutomaticQuoteSubstitutionEnabled = false
            textView.isAutomaticDashSubstitutionEnabled = false
            textView.setAccessibilityIdentifier(identifier)
            textView.setAccessibilityLabel(label)
            textView.setAccessibilityPlaceholderValue(placeholder)
            let scrollView = NSScrollView()
            scrollView.hasVerticalScroller = true
            scrollView.autohidesScrollers = true
            scrollView.borderType = .bezelBorder
            scrollView.documentView = textView
            scrollView.heightAnchor.constraint(equalToConstant: height).isActive = true
            return (scrollView, textView)
        }

        func horizontal(_ views: [NSView]) -> NSStackView {
            let stack = NSStackView(views: views)
            stack.orientation = .horizontal
            stack.alignment = .centerY
            stack.spacing = 8
            return stack
        }

        func card(
            identifier: String,
            title: String,
            subtitle: String,
            views: [NSView]
        ) -> NSStackView {
            let stack = NSStackView()
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 6
            stack.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
            stack.wantsLayer = true
            stack.layer?.backgroundColor = NSColor(calibratedWhite: 0.96, alpha: 0.98).cgColor
            stack.layer?.borderColor = NSColor(calibratedWhite: 0.63, alpha: 1).cgColor
            stack.layer?.borderWidth = 1
            stack.layer?.cornerRadius = 5
            stack.setAccessibilityElement(true)
            stack.setAccessibilityRole(.group)
            stack.setAccessibilityIdentifier(identifier)
            stack.setAccessibilityLabel(title)
            let heading = label(title, identifier: "\(identifier).Title", style: .status)
            let details = label(subtitle, identifier: "\(identifier).Details", style: .secondary)
            stack.addArrangedSubview(heading)
            stack.addArrangedSubview(details)
            for view in views {
                stack.addArrangedSubview(view)
                view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24).isActive = true
            }
            // The card is returned to its caller before it joins contentStack,
            // so only activate constraints whose anchors already share this
            // local hierarchy. Intrinsic content expands beyond this floor.
            stack.widthAnchor.constraint(greaterThanOrEqualToConstant: 620).isActive = true
            return stack
        }
    }

    private final class Milestone3SnowLeopardBackgroundView: NSView {
        override func draw(_ dirtyRect: NSRect) {
            super.draw(dirtyRect)
            let gradient = NSGradient(
                starting: NSColor(calibratedWhite: 0.92, alpha: 1),
                ending: NSColor(calibratedWhite: 0.78, alpha: 1)
            )
            gradient?.draw(in: bounds, angle: -90)
            NSColor(calibratedWhite: 1, alpha: 0.58).setStroke()
            let highlight = NSBezierPath()
            highlight.move(to: NSPoint(x: bounds.minX, y: bounds.maxY - 1))
            highlight.line(to: NSPoint(x: bounds.maxX, y: bounds.maxY - 1))
            highlight.stroke()
        }
    }
#endif
