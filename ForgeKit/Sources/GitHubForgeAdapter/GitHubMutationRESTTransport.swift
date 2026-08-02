import Foundation

struct GitHubMutationHTTPResponse: Sendable {
    let statusCode: Int
    let headers: [String: String]
    let data: Data
}

protocol GitHubMutationHTTPClient: Sendable {
    func execute(_ request: URLRequest) async throws -> GitHubMutationHTTPResponse
}

// swift6-safety-justification: The client owns one immutable thread-safe URLSession and no mutable state.
final class GitHubMutationURLSessionClient: GitHubMutationHTTPClient, @unchecked Sendable {
    static let maximumResponseBytes = 1_048_576

    private let session: URLSession

    init(configuration: URLSessionConfiguration) {
        let isolated = configuration.copy() as! URLSessionConfiguration
        isolated.httpCookieStorage = nil
        isolated.httpShouldSetCookies = false
        isolated.urlCredentialStorage = nil
        isolated.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        isolated.urlCache = nil
        session = URLSession(
            configuration: isolated,
            delegate: GitHubAnonymousRedirectRejector(),
            delegateQueue: nil
        )
    }

    func execute(_ request: URLRequest) async throws -> GitHubMutationHTTPResponse {
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw GitHubMutationError.transportFailure
        }
        var data = Data()
        if (1 ... 65536).contains(response.expectedContentLength) {
            data.reserveCapacity(Int(response.expectedContentLength))
        }
        for try await byte in bytes {
            guard data.count < Self.maximumResponseBytes else {
                throw GitHubMutationError.outcomeUnknown(
                    GitHubHTTPMetadataParser.metadata(from: response, receivedAt: Date())
                )
            }
            data.append(byte)
        }
        let headers = response.allHeaderFields.reduce(into: [String: String]()) { result, entry in
            guard let key = entry.key as? String else { return }
            result[key] = String(describing: entry.value)
        }
        return GitHubMutationHTTPResponse(
            statusCode: response.statusCode,
            headers: headers,
            data: data
        )
    }
}
