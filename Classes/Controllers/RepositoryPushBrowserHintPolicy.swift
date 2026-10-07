import ForgeKit
import Foundation

/// Push transport and porcelain records never suggest a browser destination.
nonisolated enum RepositoryPushBrowserHintPolicy {
    static func firstURL(in serverOutput: String) -> URL? {
        for line in serverOutput.components(separatedBy: .newlines) {
            let text = line.trimmingCharacters(in: .whitespaces)
            guard !text.hasPrefix("To "), text != "Done", !text.contains("\t"),
                  let url = ForgeWebURLPolicy.firstHTTPURL(in: text),
                  url.user == nil, url.password == nil
            else { continue }
            return url
        }
        return nil
    }
}
