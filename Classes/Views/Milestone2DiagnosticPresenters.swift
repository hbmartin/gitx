import AppKit
import ForgeKit

nonisolated struct ForgeMutationControlPresentation: Equatable, Sendable {
    let isVisible: Bool
    let isEnabled: Bool
    let helpText: String?

    static let hidden = ForgeMutationControlPresentation(
        isVisible: false,
        isEnabled: false,
        helpText: nil
    )

    static func checking(action: String) -> ForgeMutationControlPresentation {
        ForgeMutationControlPresentation(
            isVisible: true,
            isEnabled: false,
            helpText: "Checking whether \(action) is available for this GitHub account and repository."
        )
    }

    static func publicReadOnly(action: String) -> ForgeMutationControlPresentation {
        ForgeMutationControlPresentation(
            isVisible: true,
            isEnabled: false,
            helpText: "Sign in with a GitHub account to \(action)."
        )
    }

    static func capability(
        _ capability: ForgeOperationCapability,
        action: String
    ) -> ForgeMutationControlPresentation {
        switch capability {
        case .verified:
            ForgeMutationControlPresentation(
                isVisible: true,
                isEnabled: true,
                helpText: nil
            )
        case .unverifiedWrite:
            ForgeMutationControlPresentation(
                isVisible: true,
                isEnabled: true,
                helpText: "GitHub will verify this fine-grained token’s authority when you confirm \(action)."
            )
        case let .unavailable(reason):
            ForgeMutationControlPresentation(
                isVisible: true,
                isEnabled: false,
                helpText: unavailableHelp(reason: reason, action: action)
            )
        }
    }

    static func unavailable(error: Error, action: String) -> ForgeMutationControlPresentation {
        ForgeMutationControlPresentation(
            isVisible: true,
            isEnabled: false,
            helpText: "\(action.capitalized) is unavailable. \(error.localizedDescription)"
        )
    }

    private static func unavailableHelp(
        reason: ForgeCapabilityUnavailableReason,
        action: String
    ) -> String {
        switch reason {
        case .noCurrentCredential, .credentialUnavailable:
            "Choose a current GitHub account to \(action)."
        case .credentialExpired:
            "Refresh or replace the selected GitHub Credential to \(action)."
        case .missingPermission:
            "The selected GitHub Credential does not grant permission to \(action)."
        case .repositoryAccessDenied:
            "The selected GitHub account cannot access this repository to \(action)."
        case .samlAuthorizationRequired:
            "Authorize the selected GitHub account with the organization before you \(action)."
        case .installationConfigurationRequired:
            "Configure GitHub App access to this repository before you \(action)."
        case .inadequateRepositoryRole:
            "The selected GitHub account’s repository role cannot \(action)."
        case .authorizationEvidenceNotCurrent:
            "Refresh GitHub access before you \(action); stale data cannot authorize a mutation."
        case .knownOperationRestriction:
            "GitHub reports that this repository does not currently allow you to \(action)."
        case .mismatchedForge, .unsupportedProviderOperation,
             .mismatchedCredentialEvidence, .mismatchedRepositoryEvidence,
             .authorizationEvidenceUnavailable:
            "GitX cannot verify the exact GitHub account and repository authority needed to \(action)."
        }
    }
}

/// Shared alert construction keeps diagnostic app-hosted screenshots aligned
/// with the production Push, Sync Fork, and x-gitx presentations.
@MainActor
enum RepositoryPushConfirmationPresenter {
    static func createPullRequestButton(initiallySelected: Bool) -> NSButton {
        let button = NSButton(
            checkboxWithTitle: "Create Pull Request after pushing",
            target: nil,
            action: nil
        )
        button.state = initiallySelected ? .on : .off
        button.setAccessibilityIdentifier("GitX.Push.CreatePullRequest")
        button.setAccessibilityLabel("Create Pull Request after pushing")
        return button
    }

    static func alert(description: String, accessoryView: NSView?) -> NSAlert {
        let lowerDescription = "p" + description.dropFirst()
        let alert = NSAlert()
        alert.messageText = description
        alert.informativeText = "Are you sure you want to \(lowerDescription)?"
        alert.addButton(withTitle: NSLocalizedString("Push", comment: "Push alert - default button"))
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: "Push alert - cancel button"))
        alert.accessoryView = accessoryView
        alert.showsSuppressionButton = true
        return alert
    }
}

@MainActor
enum RepositorySyncForkConfirmationPresenter {
    static func alert(plan: ForgeSyncForkPlan) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = "Sync Fork from Parent?"
        alert.informativeText = "GitHub will update \(plan.branch.value) on the fork, then GitX will fetch \(plan.localFetchRemoteName)/\(plan.branch.value). Your checkout will not be changed."
        alert.addButton(withTitle: "Sync Fork")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.setAccessibilityIdentifier("GitX.SyncFork.Confirm")
        return alert
    }
}

@MainActor
enum ForgeDeepLinkAlertFactory {
    static func checkoutChooser(
        candidates: [(title: String, identifier: String)]
    ) -> (alert: NSAlert, popup: NSPopUpButton) {
        let alert = NSAlert()
        alert.messageText = "Choose an Open Checkout"
        alert.informativeText = "More than one open checkout matches this GitX deep link."
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        for candidate in candidates {
            popup.addItem(withTitle: candidate.title)
            popup.lastItem?.representedObject = candidate.identifier
        }
        popup.setAccessibilityIdentifier("GitX.DeepLink.CheckoutChooser")
        popup.setAccessibilityLabel("Open checkout for GitX deep link")
        alert.accessoryView = popup
        alert.addButton(withTitle: "Open")
        alert.addButton(withTitle: "Cancel")
        return (alert, popup)
    }

    static func missingObject(actions: [ForgeDeepLinkMissingObjectAction]) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = "Git Object Is Not Available Locally"
        alert.informativeText = "GitX will not fetch automatically. Fetch explicitly or open the validated destination in your browser."
        for action in actions {
            let button: NSButton
            switch action {
            case .fetch:
                button = alert.addButton(withTitle: "Fetch")
                button.setAccessibilityIdentifier("GitX.DeepLink.Fetch")
            case .openInBrowser:
                button = alert.addButton(withTitle: "Open in Browser")
                button.setAccessibilityIdentifier("GitX.DeepLink.OpenInBrowser")
            }
        }
        alert.addButton(withTitle: "Cancel")
        return alert
    }

    static func error(_ error: Error) -> NSAlert {
        NSAlert(error: error)
    }
}
