import Apollo
import Foundation

// swift6-safety-justification: NSLock serializes every access to the mutable
// response metadata captured across Apollo interceptor tasks.
final class GitHubResponseMetadataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: GitHubResponseMetadata?

    func record(_ response: HTTPURLResponse) {
        let parsed = GitHubHTTPMetadataParser.metadata(from: response, receivedAt: Date())
        lock.withLock {
            value = parsed
        }
    }

    func take() -> GitHubResponseMetadata? {
        lock.withLock { value }
    }
}

private struct GitHubMetadataInterceptor: HTTPInterceptor {
    let box: GitHubResponseMetadataBox

    func intercept(
        request: URLRequest,
        next: NextHTTPInterceptorFunction
    ) async throws -> HTTPResponse {
        let response = try await next(request)
        box.record(response.response)
        return response
    }
}

private struct GitHubInterceptorProvider: InterceptorProvider {
    let box: GitHubResponseMetadataBox

    func httpInterceptors<Operation>(for _: Operation) -> [any HTTPInterceptor] {
        [ResponseCodeInterceptor(), GitHubMetadataInterceptor(box: box)]
    }
}

enum GitHubGraphQLTransportFactory {
    static func makeClient(
        accessToken: GitHubSecret,
        sessionConfiguration: URLSessionConfiguration,
        metadataBox: GitHubResponseMetadataBox,
        store: ApolloStore
    ) -> ApolloClient {
        let session = URLSession(configuration: sessionConfiguration)
        var headers = [
            "Accept": "application/vnd.github+json",
            "User-Agent": "GitX-ForgeKit",
            "X-GitHub-Api-Version": "2022-11-28",
        ]
        headers["Authorization"] = accessToken.withUnsafeUTF8Bytes {
            "Bearer \(String(decoding: $0, as: UTF8.self))"
        }
        let transport = RequestChainNetworkTransport(
            urlSession: session,
            interceptorProvider: GitHubInterceptorProvider(box: metadataBox),
            store: store,
            endpointURL: URL(string: "https://api.github.com/graphql")!,
            additionalHeaders: headers
        )
        return ApolloClient(networkTransport: transport, store: store)
    }
}

enum GitHubHTTPMetadataParser {
    static func metadata(from response: HTTPURLResponse, receivedAt: Date) -> GitHubResponseMetadata {
        let headers = response.allHeaderFields.reduce(into: [String: String]()) { result, entry in
            guard let name = entry.key as? String, let value = entry.value as? String else { return }
            result[name] = value
        }
        let rateLimit = GitHubRateLimitParser.parse(
            statusCode: response.statusCode,
            headers: headers,
            receivedAt: receivedAt
        )
        let authorizationFailure = GitHubRESTAuthorizationParser.parse(
            statusCode: response.statusCode,
            headers: headers,
            body: Data(),
            installationConfigurationURL: nil
        )
        let saml: GitHubSAMLMetadata?
        if case let .samlAuthorizationRequired(url) = authorizationFailure {
            saml = GitHubSAMLMetadata(authorizationURL: url)
        } else {
            saml = nil
        }
        return GitHubResponseMetadata(
            statusCode: response.statusCode,
            requestID: nonempty(response.value(forHTTPHeaderField: "X-GitHub-Request-Id")),
            rateLimit: rateLimit,
            saml: saml
        )
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
