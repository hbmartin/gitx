@testable import ForgeKit
import Foundation

enum TestSupport {
    static func repository(
        kind: ForgeKind = .github,
        host: String? = nil,
        port: Int? = nil,
        owner: String = "acme",
        name: String = "widgets"
    ) throws -> ForgeRepositoryIdentity {
        let selectedHost: String
        if let host {
            selectedHost = host
        } else {
            selectedHost = switch kind {
            case .github: "github.com"
            case .gitLab: "gitlab.com"
            case .bitbucket: "bitbucket.org"
            }
        }
        return try ForgeRepositoryIdentity(
            forge: ForgeIdentity(kind: kind, origin: ForgeOrigin(host: selectedHost, port: port)),
            owner: owner,
            name: name
        )
    }

    static let commit = try! ForgeCommitID("abc1234")
    static let main = try! ForgeRefName("main")
    static let feature = try! ForgeRefName("feature/naïve")
}
