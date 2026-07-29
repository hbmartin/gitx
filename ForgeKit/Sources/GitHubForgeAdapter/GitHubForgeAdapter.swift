import ForgeKit

/// The authenticated transport is added in Milestone 1. This declaration
/// establishes the adapter target and its one-way dependency on ForgeKit.
public enum GitHubForgeAdapterMetadata: Sendable {
    public static var forgeKind: ForgeKind {
        .github
    }

    public static var publicHost: String {
        "github.com"
    }
}
