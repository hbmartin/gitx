import AppKit
import XCTest

#if DEBUG || !GITX_APP_TARGET
    @MainActor
    final class Milestone3DiagnosticPresenterTests: XCTestCase {
        func testReviewJourneyPublishesRepliesResolvesThreadsAndSubmitsFormalReview() throws {
            let fixture = try Milestone3DiagnosticRepositoryFixture()
            defer { fixture.cleanup() }
            let recorder = Milestone3DiagnosticStateRecorder()
            let mounted = mount(.review, fixture: fixture, recorder: recorder)

            XCTAssertEqual(
                try field(Milestone3AccessibilityIdentifier.PullRequest.title, in: mounted.controller).stringValue,
                "Milestone 3 integration review"
            )
            XCTAssertEqual(
                try view(Milestone3AccessibilityIdentifier.Review.outdatedBadge, in: mounted.controller)
                    .accessibilityLabel(),
                "OUTDATED"
            )
            XCTAssertEqual(
                try view(Milestone3AccessibilityIdentifier.Review.minimizedReason, in: mounted.controller)
                    .accessibilityLabel(),
                "MINIMIZED"
            )
            XCTAssertEqual(
                try view(Milestone3AccessibilityIdentifier.Review.deletedTombstone, in: mounted.controller)
                    .accessibilityLabel(),
                "TOMBSTONE"
            )
            XCTAssertEqual(
                try view(Milestone3AccessibilityIdentifier.Review.unavailableTombstone, in: mounted.controller)
                    .accessibilityLabel(),
                "UNAVAILABLE"
            )

            try button(Milestone3AccessibilityIdentifier.Review.publishReply, in: mounted.controller)
                .performClick(nil)
            XCTAssertEqual(recorder.last?.state, "Failure")
            XCTAssertEqual(recorder.last?.label, "A non-empty Review Thread reply is required.")

            let reply = try textView(Milestone3AccessibilityIdentifier.Review.replyBody, in: mounted.controller)
            reply.string = "The native review path looks good."
            try button(Milestone3AccessibilityIdentifier.Review.publishReply, in: mounted.controller)
                .performClick(nil)
            let published = try field(
                Milestone3AccessibilityIdentifier.Review.publishedReply,
                in: mounted.controller
            )
            XCTAssertFalse(published.isHidden)
            XCTAssertEqual(published.stringValue, "Published immediately: The native review path looks good.")
            XCTAssertEqual(reply.string, "")
            XCTAssertEqual(recorder.last?.state, "Review.ReplyPublished")

            let resolve = try button(Milestone3AccessibilityIdentifier.Review.resolve, in: mounted.controller)
            let undo = try button(Milestone3AccessibilityIdentifier.Review.undoResolve, in: mounted.controller)
            resolve.performClick(nil)
            XCTAssertTrue(resolve.isHidden)
            XCTAssertFalse(undo.isHidden)
            XCTAssertEqual(recorder.last?.state, "Review.Resolved")
            undo.performClick(nil)
            XCTAssertFalse(resolve.isHidden)
            XCTAssertTrue(undo.isHidden)
            XCTAssertEqual(recorder.last?.state, "Review.ResolutionUndone")

            try button(Milestone3AccessibilityIdentifier.Review.openFormalReview, in: mounted.controller)
                .performClick(nil)
            let panel = try view(Milestone3AccessibilityIdentifier.Review.formalSheet, in: mounted.controller)
            XCTAssertFalse(panel.isHidden)
            XCTAssertEqual(recorder.last?.state, "Review.FormalReviewPresented")
            let kind = try popUp(Milestone3AccessibilityIdentifier.Review.formalKind, in: mounted.controller)
            let submitReview = try button(
                Milestone3AccessibilityIdentifier.Review.submitFormalReview,
                in: mounted.controller
            )
            submitReview.performClick(nil)
            XCTAssertEqual(recorder.last?.state, "Review.FormalReviewSubmitted")
            XCTAssertEqual(recorder.last?.label, "Approve review submitted without a summary for exact displayed head")

            kind.selectItem(withTitle: "Request Changes")
            let formalBody = try textView(
                Milestone3AccessibilityIdentifier.Review.formalBody,
                in: mounted.controller
            )
            formalBody.string = "Please cover the failure path."
            submitReview.performClick(nil)
            XCTAssertEqual(recorder.last?.state, "Review.FormalReviewSubmitted")
            XCTAssertEqual(
                recorder.last?.label,
                "Request Changes review submitted with a summary for exact displayed head"
            )
            XCTAssertTrue(mounted.window.contentViewController === mounted.controller)
        }

        func testSuggestedChangeJourneyAppliesOneUnstagedEditAndRejectsChangedContext() throws {
            let fixture = try Milestone3DiagnosticRepositoryFixture()
            defer { fixture.cleanup() }
            let recorder = Milestone3DiagnosticStateRecorder()
            let mounted = mount(.suggestedChange, fixture: fixture, recorder: recorder)

            XCTAssertEqual(
                try view(Milestone3AccessibilityIdentifier.SuggestedChange.eligibility, in: mounted.controller)
                    .accessibilityLabel(),
                "EXACT HEAD CHECKED OUT • CONTEXT MATCHED • FILE CLEAN"
            )
            XCTAssertEqual(
                try view(Milestone3AccessibilityIdentifier.SuggestedChange.safety, in: mounted.controller)
                    .accessibilityLabel(),
                "Local edit safety"
            )

            let apply = try button(Milestone3AccessibilityIdentifier.SuggestedChange.apply, in: mounted.controller)
            apply.performClick(nil)
            XCTAssertEqual(recorder.last?.state, "SuggestedChange.Applied")
            XCTAssertEqual(
                try field(Milestone3AccessibilityIdentifier.SuggestedChange.status, in: mounted.controller)
                    .stringValue,
                "Applied as an unstaged local edit. GitX Undo is unavailable."
            )
            XCTAssertEqual(
                try String(contentsOf: fixture.suggestedChangeURL, encoding: .utf8),
                "let answer = 42\n"
            )
            let diff = try fixture.git(["diff", "--", "M3Suggested.swift"])
            XCTAssertTrue(diff.contains("-let answer = 41"))
            XCTAssertTrue(diff.contains("+let answer = 42"))

            apply.performClick(nil)
            XCTAssertEqual(recorder.last?.state, "Failure")
            XCTAssertEqual(recorder.last?.label, "The exact Suggested Change context no longer matches.")
        }

        func testLifecycleJourneyDrivesExplicitTransitionsAndBrowserRouting() throws {
            let fixture = try Milestone3DiagnosticRepositoryFixture()
            defer { fixture.cleanup() }
            let recorder = Milestone3DiagnosticStateRecorder()
            let mounted = mount(.lifecycle, fixture: fixture, recorder: recorder)
            let status = try field(Milestone3AccessibilityIdentifier.Lifecycle.status, in: mounted.controller)

            XCTAssertEqual(status.stringValue, "Draft Pull Request • open • branch update available")
            try button(Milestone3AccessibilityIdentifier.Lifecycle.markReady, in: mounted.controller)
                .performClick(nil)
            XCTAssertEqual(status.stringValue, "Ready for review • open • branch update available")
            XCTAssertEqual(recorder.last?.state, "Lifecycle.Ready")

            try button(Milestone3AccessibilityIdentifier.Lifecycle.updateBranch, in: mounted.controller)
                .performClick(nil)
            XCTAssertEqual(status.stringValue, "Ready for review • open • branch updated explicitly")
            XCTAssertEqual(recorder.last?.state, "Lifecycle.BranchUpdated")

            let close = try button(Milestone3AccessibilityIdentifier.Lifecycle.close, in: mounted.controller)
            let reopen = try button(Milestone3AccessibilityIdentifier.Lifecycle.reopen, in: mounted.controller)
            close.performClick(nil)
            XCTAssertTrue(close.isHidden)
            XCTAssertFalse(reopen.isHidden)
            XCTAssertEqual(status.stringValue, "Pull Request closed")
            reopen.performClick(nil)
            XCTAssertFalse(close.isHidden)
            XCTAssertTrue(reopen.isHidden)
            XCTAssertEqual(status.stringValue, "Pull Request reopened • ready for review")

            try button(
                Milestone3AccessibilityIdentifier.Lifecycle.manageReviewersInBrowser,
                in: mounted.controller
            ).performClick(nil)
            XCTAssertEqual(recorder.last?.state, "Lifecycle.ReviewersBrowserRouted")
            XCTAssertEqual(recorder.last?.label, "Reviewer management routed to the browser")
        }

        func testMergeJourneyRequiresReviewThenSupportsCancelAndExplicitConfirmation() throws {
            let fixture = try Milestone3DiagnosticRepositoryFixture()
            defer { fixture.cleanup() }
            let recorder = Milestone3DiagnosticStateRecorder()
            let mounted = mount(.merge, fixture: fixture, recorder: recorder)
            let method = try popUp(Milestone3AccessibilityIdentifier.Merge.method, in: mounted.controller)
            let status = try field(Milestone3AccessibilityIdentifier.Merge.status, in: mounted.controller)
            let confirmation = try view(Milestone3AccessibilityIdentifier.Merge.confirmation, in: mounted.controller)

            method.selectItem(withTitle: "Squash")
            try sendAction(of: method)
            XCTAssertEqual(recorder.last?.state, "Merge.Method.Squash")
            XCTAssertTrue(confirmation.isHidden)

            try button(Milestone3AccessibilityIdentifier.Merge.review, in: mounted.controller).performClick(nil)
            XCTAssertFalse(confirmation.isHidden)
            XCTAssertEqual(status.stringValue, "Fresh preflight complete. Explicit confirmation required.")
            XCTAssertEqual(
                try field(Milestone3AccessibilityIdentifier.Merge.confirmationSummary, in: mounted.controller)
                    .stringValue,
                "Squash • head 42f00d1 • base main • fresh"
            )
            XCTAssertEqual(recorder.last?.state, "Merge.ConfirmationPresented")

            try button(Milestone3AccessibilityIdentifier.Merge.cancel, in: mounted.controller).performClick(nil)
            XCTAssertTrue(confirmation.isHidden)
            XCTAssertEqual(status.stringValue, "Merge confirmation cancelled.")
            XCTAssertEqual(recorder.last?.state, "Merge.Cancelled")

            try button(Milestone3AccessibilityIdentifier.Merge.review, in: mounted.controller).performClick(nil)
            try button(Milestone3AccessibilityIdentifier.Merge.confirm, in: mounted.controller).performClick(nil)
            XCTAssertTrue(confirmation.isHidden)
            XCTAssertEqual(status.stringValue, "Merged successfully using Squash. Local checkout unchanged.")
            XCTAssertEqual(recorder.last?.state, "Merge.Succeeded")
            XCTAssertEqual(recorder.last?.label, "Pull Request merged using Squash; local checkout unchanged")
        }

        func testQueueAndDeleteJourneyKeepsQueuePreferenceAndDeletionSeparate() throws {
            let fixture = try Milestone3DiagnosticRepositoryFixture()
            defer { fixture.cleanup() }
            let recorder = Milestone3DiagnosticStateRecorder()
            let mounted = mount(.queueDelete, fixture: fixture, recorder: recorder)
            let status = try field(Milestone3AccessibilityIdentifier.Queue.status, in: mounted.controller)
            let enter = try button(Milestone3AccessibilityIdentifier.Queue.enter, in: mounted.controller)
            let leave = try button(Milestone3AccessibilityIdentifier.Queue.leave, in: mounted.controller)
            let preference = try button(
                Milestone3AccessibilityIdentifier.BranchDeletion.preference,
                in: mounted.controller
            )
            let delete = try button(Milestone3AccessibilityIdentifier.BranchDeletion.delete, in: mounted.controller)

            XCTAssertTrue(enter.isEnabled)
            XCTAssertFalse(leave.isEnabled)
            XCTAssertFalse(preference.isEnabled)
            XCTAssertFalse(delete.isEnabled)

            enter.performClick(nil)
            XCTAssertFalse(enter.isEnabled)
            XCTAssertTrue(leave.isEnabled)
            XCTAssertEqual(status.stringValue, "Queued for merge • no branch deletion scheduled")
            XCTAssertEqual(recorder.last?.state, "Queue.Entered")
            leave.performClick(nil)
            XCTAssertTrue(enter.isEnabled)
            XCTAssertFalse(leave.isEnabled)
            XCTAssertEqual(recorder.last?.state, "Queue.Left")

            try button(Milestone3AccessibilityIdentifier.Queue.observeMerge, in: mounted.controller)
                .performClick(nil)
            XCTAssertTrue(preference.isEnabled)
            XCTAssertTrue(delete.isEnabled)
            XCTAssertEqual(status.stringValue, "Merge observed • branch deletion remains separate")
            XCTAssertEqual(recorder.last?.state, "Queue.MergeObserved")

            preference.state = .on
            try sendAction(of: preference)
            XCTAssertEqual(recorder.last?.state, "BranchDeletion.Preference.Selected")
            preference.state = .off
            try sendAction(of: preference)
            XCTAssertEqual(recorder.last?.state, "BranchDeletion.Preference.Cleared")

            delete.performClick(nil)
            XCTAssertFalse(delete.isEnabled)
            XCTAssertEqual(status.stringValue, "Merged • head branch deleted by separate mutation")
            XCTAssertEqual(recorder.last?.state, "BranchDeletion.Deleted")
        }

        func testPostMergeJourneyFetchesWithoutCheckoutThenSwitchesBaseExplicitly() throws {
            let fixture = try Milestone3DiagnosticRepositoryFixture()
            defer { fixture.cleanup() }
            let recorder = Milestone3DiagnosticStateRecorder()
            let mounted = mount(.postMerge, fixture: fixture, recorder: recorder)
            let status = try field(Milestone3AccessibilityIdentifier.PostMerge.status, in: mounted.controller)
            let checkout = try button(
                Milestone3AccessibilityIdentifier.PostMerge.checkoutBase,
                in: mounted.controller
            )

            XCTAssertEqual(try fixture.currentBranch(), "feature/milestone-3")
            XCTAssertFalse(checkout.isEnabled)
            try button(Milestone3AccessibilityIdentifier.PostMerge.fetch, in: mounted.controller)
                .performClick(nil)
            XCTAssertEqual(try fixture.currentBranch(), "feature/milestone-3")
            XCTAssertEqual(status.stringValue, "Base fetched • local checkout still unchanged")
            XCTAssertTrue(checkout.isEnabled)
            XCTAssertEqual(recorder.last?.state, "PostMerge.Fetched")

            checkout.performClick(nil)
            XCTAssertEqual(try fixture.currentBranch(), "main")
            XCTAssertEqual(status.stringValue, "Base checked out explicitly • current branch main")
            XCTAssertFalse(checkout.isEnabled)
            XCTAssertEqual(recorder.last?.state, "PostMerge.BaseCheckedOut")
        }

        func testProductProofHarnessMarksARepositoryWindowReady() throws {
            let fixture = try Milestone3DiagnosticRepositoryFixture()
            defer { fixture.cleanup() }
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 900, height: 620),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            let windowController = PBGitWindowController(window: window)
            windowController.repository = fixture.repository

            let proof = Milestone3UITestHarness.runProductProof(
                for: windowController,
                environment: ["GITX_M3_SCENARIO": Milestone3DiagnosticJourney.lifecycle.rawValue]
            )
            withExtendedLifetime(proof) {
                XCTAssertNotNil(descendant(
                    Milestone3AccessibilityIdentifier.harnessState("Ready.lifecycle"),
                    in: window.contentView
                ))
            }
        }

        func testProductProofHarnessDoesNotRetainItsRepositoryWindowController() throws {
            let fixture = try Milestone3DiagnosticRepositoryFixture()
            defer { fixture.cleanup() }
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 900, height: 620),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            var windowController: PBGitWindowController? = PBGitWindowController(window: window)
            windowController?.repository = fixture.repository
            weak var releasedWindowController: PBGitWindowController?
            releasedWindowController = windowController

            let proof = try Milestone3UITestHarness.runProductProof(
                for: XCTUnwrap(windowController),
                environment: ["GITX_M3_SCENARIO": Milestone3DiagnosticJourney.lifecycle.rawValue]
            )
            windowController = nil

            XCTAssertNil(
                releasedWindowController,
                "The window owns an installed harness; the harness must not retain the window in return"
            )
            withExtendedLifetime(proof) {}
        }

        private func mount(
            _ journey: Milestone3DiagnosticJourney,
            fixture: Milestone3DiagnosticRepositoryFixture,
            recorder: Milestone3DiagnosticStateRecorder
        ) -> (controller: Milestone3DiagnosticViewController, window: NSWindow) {
            let controller = Milestone3DiagnosticViewController(
                journey: journey,
                repository: fixture.repository,
                stateHandler: recorder.record
            )
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.contentViewController = controller
            controller.view.frame = window.contentView?.bounds ?? .zero
            window.layoutIfNeeded()
            return (controller, window)
        }

        private func view(
            _ identifier: String,
            in controller: NSViewController,
            file: StaticString = #filePath,
            line: UInt = #line
        ) throws -> NSView {
            try XCTUnwrap(descendant(identifier, in: controller.view), file: file, line: line)
        }

        private func button(
            _ identifier: String,
            in controller: NSViewController,
            file: StaticString = #filePath,
            line: UInt = #line
        ) throws -> NSButton {
            try XCTUnwrap(view(identifier, in: controller, file: file, line: line) as? NSButton, file: file, line: line)
        }

        private func field(
            _ identifier: String,
            in controller: NSViewController,
            file: StaticString = #filePath,
            line: UInt = #line
        ) throws -> NSTextField {
            try XCTUnwrap(
                view(identifier, in: controller, file: file, line: line) as? NSTextField,
                file: file,
                line: line
            )
        }

        private func textView(
            _ identifier: String,
            in controller: NSViewController,
            file: StaticString = #filePath,
            line: UInt = #line
        ) throws -> NSTextView {
            try XCTUnwrap(
                view(identifier, in: controller, file: file, line: line) as? NSTextView,
                file: file,
                line: line
            )
        }

        private func popUp(
            _ identifier: String,
            in controller: NSViewController,
            file: StaticString = #filePath,
            line: UInt = #line
        ) throws -> NSPopUpButton {
            try XCTUnwrap(
                view(identifier, in: controller, file: file, line: line) as? NSPopUpButton,
                file: file,
                line: line
            )
        }

        private func sendAction(
            of control: NSControl,
            file: StaticString = #filePath,
            line: UInt = #line
        ) throws {
            let action = try XCTUnwrap(control.action, file: file, line: line)
            XCTAssertTrue(NSApp.sendAction(action, to: control.target, from: control), file: file, line: line)
        }

        private func descendant(_ identifier: String, in root: NSView?) -> NSView? {
            guard let root else { return nil }
            if root.accessibilityIdentifier() == identifier {
                return root
            }
            return root.subviews.lazy.compactMap { self.descendant(identifier, in: $0) }.first
        }
    }

    @MainActor
    private final class Milestone3DiagnosticStateRecorder {
        struct Event: Equatable {
            let state: String
            let label: String
        }

        private(set) var events: [Event] = []
        var last: Event? {
            events.last
        }

        func record(state: String, label: String) {
            events.append(Event(state: state, label: label))
        }
    }

    @MainActor
    private final class Milestone3DiagnosticRepositoryFixture {
        let directory: URL
        let repository: PBGitRepository

        var suggestedChangeURL: URL {
            directory.appendingPathComponent("M3Suggested.swift")
        }

        init() throws {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("GitX-M3-Diagnostic-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            _ = try Self.runGit(["init", "--quiet", "--initial-branch=main"], in: directory)
            _ = try Self.runGit(["config", "user.name", "GitX Tests"], in: directory)
            _ = try Self.runGit(["config", "user.email", "gitx-tests@example.invalid"], in: directory)
            let suggestedChangeURL = directory.appendingPathComponent("M3Suggested.swift")
            try "let answer = 41\n".write(to: suggestedChangeURL, atomically: true, encoding: .utf8)
            try "Milestone 3 diagnostic fixture\n".write(
                to: directory.appendingPathComponent("README.md"),
                atomically: true,
                encoding: .utf8
            )
            _ = try Self.runGit(["add", "M3Suggested.swift", "README.md"], in: directory)
            _ = try Self.runGit(["commit", "--quiet", "-m", "Diagnostic fixture"], in: directory)
            _ = try Self.runGit(["switch", "--quiet", "-c", "feature/milestone-3"], in: directory)
            repository = try PBGitRepository(url: directory)
        }

        func cleanup() {
            try? FileManager.default.removeItem(at: directory)
        }

        func currentBranch() throws -> String {
            try git(["branch", "--show-current"]).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        @discardableResult
        func git(_ arguments: [String]) throws -> String {
            try Self.runGit(arguments, in: directory)
        }

        private static func runGit(_ arguments: [String], in directory: URL) throws -> String {
            let process = Process()
            let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = arguments
            process.currentDirectoryURL = directory
            process.standardOutput = pipe
            process.standardError = pipe
            try process.run()
            process.waitUntilExit()
            let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            guard process.terminationStatus == 0 else {
                throw Milestone3DiagnosticRepositoryFixtureError.git(arguments: arguments, output: output)
            }
            return output
        }
    }

    private enum Milestone3DiagnosticRepositoryFixtureError: LocalizedError {
        case git(arguments: [String], output: String)

        var errorDescription: String? {
            switch self {
            case let .git(arguments, output):
                "git \(arguments.joined(separator: " ")) failed: \(output)"
            }
        }
    }
#endif
