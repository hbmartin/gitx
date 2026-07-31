import ForgeKit
import Foundation

/// The app-hosted test target mirrors the app's Objective-C-visible Swift API
/// in GitXTests-Bridging-Header.h instead of importing GitX. These aliases let
/// the production-only pure Swift boundary files compile into the test module
/// for focused decision-level coverage without duplicating product behavior.
typealias ApplicationSettings = PBApplicationSettings
// SwiftLint cannot see this alias's use from the separately compiled production source.
// swiftlint:disable:next unused_declaration
typealias DiffCommandOptions = PBDiffCommandOptions

extension PBApplicationSettings {
    static var attentionPollingPreset: ForgeAttentionPollingPreset {
        get { ForgeAttentionPollingPreset(rawValue: attentionPollingPresetRawValue) ?? .defaultValue }
        set { attentionPollingPresetRawValue = newValue.rawValue }
    }

    static var attentionAlertCategories: Set<ForgeAttentionAlertCategory> {
        get { Set(attentionAlertCategoryRawValues.compactMap(ForgeAttentionAlertCategory.init(rawValue:))) }
        set { attentionAlertCategoryRawValues = newValue.map(\.rawValue).sorted() }
    }

    static var attentionPolicy: ForgeAttentionPolicy {
        ForgeAttentionPolicy(
            includesFailedChecksOnAuthoredPullRequests: attentionIncludesFailedChecksOnAuthoredPullRequests,
            includesFailedChecksAwaitingReview: attentionIncludesFailedChecksAwaitingReview
        )
    }

    static var attentionViewState: ForgeAttentionViewState {
        get {
            guard let data = attentionViewStateData,
                  let state = try? JSONDecoder().decode(ForgeAttentionViewState.self, from: data)
            else { return .defaultValue }
            return state
        }
        set { attentionViewStateData = try? JSONEncoder().encode(newValue) }
    }
}

extension Notification.Name {
    static let forgeAvatarLoadingDidChange = Notification.Name(
        "PBForgeAvatarLoadingDidChangeNotification"
    )
}
