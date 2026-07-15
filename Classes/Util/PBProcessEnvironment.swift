import Foundation

@objc(PBProcessEnvironment)
final class PBProcessEnvironment: NSObject {
    @objc(preparedEnvironment:homeDirectory:)
    static func preparedEnvironment(
        _ environment: [String: String],
        homeDirectory: String
    ) -> [String: String] {
        var prepared = environment
        var pathEntries = environment["PATH", default: ""]
            .split(separator: ":")
            .map(String.init)

        let systemAndPackageManagerPaths = [
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/opt/local/bin",
            "/sw/bin",
        ]
        pathEntries.append(contentsOf: systemAndPackageManagerPaths)

        if !homeDirectory.isEmpty {
            let homePath = homeDirectory as NSString
            pathEntries.append(homePath.appendingPathComponent(".local/bin"))
            pathEntries.append(homePath.appendingPathComponent("bin"))
        }

        var seen = Set<String>()
        prepared["PATH"] = pathEntries
            .filter { seen.insert($0).inserted }
            .joined(separator: ":")
        return prepared
    }
}
