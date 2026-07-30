import Foundation

/// The app-hosted test target mirrors the app's Objective-C-visible Swift API
/// in GitXTests-Bridging-Header.h instead of importing GitX. These aliases let
/// the production-only pure Swift boundary files compile into the test module
/// for focused decision-level coverage without duplicating product behavior.
typealias ApplicationSettings = PBApplicationSettings

extension Notification.Name {
    static let forgeAvatarLoadingDidChange = Notification.Name(
        "PBForgeAvatarLoadingDidChangeNotification"
    )
}
