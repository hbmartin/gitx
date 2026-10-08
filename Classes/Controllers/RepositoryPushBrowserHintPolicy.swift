import Foundation

/// Push transport and porcelain records never suggest a browser destination.
nonisolated enum RepositoryPushBrowserHintPolicy {
    private static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    static func firstURL(in serverOutput: String) -> URL? {
        for line in serverOutput.components(separatedBy: .newlines) {
            let text = line.trimmingCharacters(in: .whitespaces)
            guard text.hasPrefix("remote:"), let detector else { continue }
            let range = NSRange(text.startIndex ..< text.endIndex, in: text)
            for match in detector.matches(in: text, range: range) {
                guard let url = match.url, let scheme = url.scheme?.lowercased(),
                      scheme == "https" || scheme == "http", url.host != nil,
                      url.user == nil, url.password == nil
                else { continue }
                return url
            }
        }
        return nil
    }
}
