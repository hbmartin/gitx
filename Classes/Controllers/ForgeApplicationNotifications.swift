import Foundation

extension Notification.Name {
    nonisolated static let forgeAccountsDidChange = Notification.Name("PBForgeAccountsDidChangeNotification")
    nonisolated static let forgeAttentionInboxDidChange = Notification.Name("PBForgeAttentionInboxDidChangeNotification")
    nonisolated static let forgeAttentionPreferencesDidChange = Notification.Name(
        "PBForgeAttentionPreferencesDidChangeNotification"
    )
    nonisolated static let repositoryForgeAccountDidChange = Notification.Name(
        "PBRepositoryForgeAccountDidChangeNotification"
    )
    nonisolated static let repositoryAttentionUnseenDidChange = Notification.Name(
        "PBRepositoryAttentionUnseenDidChangeNotification"
    )
    nonisolated static let forgeAttentionAlertAction = Notification.Name(
        "PBForgeAttentionAlertActionNotification"
    )
}

enum RepositoryAttentionNotificationKey {
    static let count = "count"
    static let itemID = "itemID"
    static let action = "action"
}

enum RepositoryForgeAccountNotificationKey {
    static let providerName = "providerName"
    static let login = "login"
    static let isPublic = "isPublic"
    static let accountID = "accountID"
    static let accounts = "accounts"
    static let accountRebindingEnabled = "accountRebindingEnabled"
    static let accountRebindingCooldownDeadline = "accountRebindingCooldownDeadline"
}
